from copy import deepcopy
import time
import unittest

from fastapi.testclient import TestClient

from backend.action_metrics import InvalidActionMetrics, is_monotonic_snapshot, validate_action_metrics
from backend.decision_service import DatabaseDecisionService, DecisionError, validate_observation
from backend.main import _validate_architecture_payload, create_app


SESSION_ID = "11111111-1111-4111-8111-111111111111"
ACK_TOKEN = "22222222-2222-4222-8222-222222222222"
NPC = {
    "npc_id": 3052044,
    "npc_type": 12,
    "health": 80,
    "max_health": 100,
    "player_distance": 3010,
    "player_visible": True,
    "current_state": 482,
    "attribution_version": "neural_attack_provenance_v2",
}
ACTION_METRICS = {
    "opportunities": 4,
    "sql_decisions": 2,
    "invalid_sql_responses": 0,
    "sent_to_engine": 3,
    "applied": 2,
    "rejected": 1,
    "fallback": 1,
    "actions": {
        "IDLE": {"selected": 0, "sent_to_engine": 0, "applied": 0, "rejected": 0},
        "CHASE": {"selected": 2, "sent_to_engine": 2, "applied": 2, "rejected": 0},
        "ATTACK": {"selected": 0, "sent_to_engine": 1, "applied": 0, "rejected": 1},
        "FLEE": {"selected": 0, "sent_to_engine": 0, "applied": 0, "rejected": 0},
    },
    "fallback_reasons": {"backend_offline": 0, "waiting_for_mysql": 1},
}


class StubService:
    def __init__(self, result=None, error=None, close_error=None, delay_seconds=0, ack_token=ACK_TOKEN, health_error=None):
        self.result = result or {"run_id": 17, "action": "CHASE", "confidence": 0.75}
        self.error = error
        self.close_error = close_error
        self.delay_seconds = delay_seconds
        self.ack_token = ack_token
        self.health_error = health_error
        self.calls = []
        self.events = []
        self.closed_sessions = []
        self.confirmed_acks = []

    def check_health(self):
        if self.health_error:
            raise self.health_error

    def decide(self, session_id, npc, architecture_name=None):
        validate_observation(session_id, npc)
        self.calls.append((session_id, npc, architecture_name))
        if self.delay_seconds:
            time.sleep(self.delay_seconds)
        if self.error:
            raise self.error
        return self.result

    def record_combat_event(self, session_id, event):
        self.events.append((session_id, event))

    def close_session(self, session_id):
        if self.close_error:
            raise self.close_error
        self.closed_sessions.append(session_id)
        return self.ack_token

    def confirm_training_ack(self, session_id, ack_token):
        self.confirmed_acks.append((session_id, ack_token))


class LabStubService(StubService):
    configured_architecture_name = "lab_4_64_4"

    def list_lab_architectures(self):
        return [{
            "architecture_id": 8,
            "architecture_name": "lab_4_64_4",
            "topology": "4 -> 64 -> 4",
            "genome_count": 2,
        }]

    def list_lab_architecture_layers(self, architecture_id):
        return [{"layer_order": 0, "layer_type": "input", "neuron_count": 4}]

    def list_lab_genomes(self, architecture_id, generation, limit, offset):
        return [{"genome_id": 81, "generation": generation or 0, "fitness": 0}]

    def get_lab_run_activations(self, run_id, layer_order, limit, offset):
        return [{"run_id": run_id, "layer_order": layer_order, "activation": 0.5}]

    def get_lab_genome_weights(self, genome_id, target_layer_order, target_position, limit, offset):
        return [{"genome_id": genome_id, "weight": 0.25}]

    def create_lab_architecture(self, architecture_name, topology, hidden_activation):
        return [{"architecture_id": 99, "architecture_name": architecture_name}]

    def create_lab_population(self, architecture_name, population_size, seed):
        return [{"genome_id": index + 1} for index in range(population_size)]


class FakeCursor:
    def __init__(self, outputs, ack_token=ACK_TOKEN):
        self.outputs = outputs
        self.ack_token = ack_token
        self.procedure = None
        self.parameters = None
        self.calls = []
        self.closed = False
        self.description = None
        self.result_rows = []
        self.executed = None

    def callproc(self, procedure, parameters):
        self.procedure = procedure
        self.parameters = parameters
        self.calls.append((procedure, parameters))
        if procedure in {"sp_nn_decide", "sp_nn_decide_for_architecture"}:
            return (*parameters[:-3], *self.outputs)
        if procedure == "sp_nn_finish_session_training_v2":
            return (parameters[0], self.ack_token)
        return parameters

    def close(self):
        self.closed = True

    def execute(self, statement, parameters=()):
        self.executed = (statement, parameters)
        self.description = (("architecture_id",), ("architecture_name",))
        self.result_rows = [(42, "lab_4_8_4")]

    def fetchall(self):
        return self.result_rows

    def nextset(self):
        self.description = None
        return False


class FakeConnection:
    def __init__(self, cursor):
        self.fake_cursor = cursor
        self.committed = False
        self.rolled_back = False
        self.closed = False

    def cursor(self, **_kwargs):
        return self.fake_cursor

    def commit(self):
        self.committed = True

    def rollback(self):
        self.rolled_back = True

    def close(self):
        self.closed = True


class FakePool:
    def __init__(self, connection):
        self.connection = connection

    def get_connection(self):
        return self.connection


class DecisionServiceTests(unittest.TestCase):
    def test_topology_validation_keeps_real_io_and_sql_parameter_limit(self):
        name, topology, activation = _validate_architecture_payload({
            "architecture_name": "lab_4_64_4",
            "topology": [4, 64, 4],
            "hidden_activation": "relu",
        })
        self.assertEqual((name, topology, activation), ("lab_4_64_4", [4, 64, 4], "relu"))
        with self.assertRaises(Exception):
            _validate_architecture_payload({
                "architecture_name": "lab_invalid_io",
                "topology": [5, 64, 4],
            })
        with self.assertRaises(Exception):
            _validate_architecture_payload({
                "architecture_name": "lab_too_large",
                "topology": [4, 512, 512, 4],
            })

    def test_observation_is_validated_without_python_policy(self):
        session_id, observation = validate_observation(SESSION_ID, NPC)
        self.assertEqual(session_id, SESSION_ID)
        self.assertEqual(observation.engine_npc_id, "3052044")
        self.assertEqual(observation.max_health, 100)
        self.assertEqual(observation.player_visible, 1)

    def test_invalid_health_is_rejected_before_sql(self):
        with self.assertRaises(ValueError):
            validate_observation(SESSION_ID, {**NPC, "health": 101})

    def test_missing_provenance_marker_is_rejected_before_sql(self):
        observation = {key: value for key, value in NPC.items() if key != "attribution_version"}
        with self.assertRaises(ValueError):
            validate_observation(SESSION_ID, observation)

    def test_decision_is_returned_by_mysql_procedure(self):
        cursor = FakeCursor((41, "ATTACK", 0.982))
        connection = FakeConnection(cursor)
        service = DatabaseDecisionService(FakePool(connection))

        decision = service.decide(SESSION_ID, NPC)

        self.assertEqual(cursor.calls[0][0], "sp_nn_decide")
        self.assertEqual(cursor.calls[0][1][0], SESSION_ID)
        self.assertEqual(cursor.calls[0][1][1], "3052044")
        self.assertEqual(cursor.calls[0][1][4], 100)
        self.assertEqual(cursor.calls[1], ("sp_nn_mark_session_v2", (SESSION_ID,)))
        self.assertEqual(cursor.calls[2], ("sp_nn_register_training_session_v2", (SESSION_ID,)))
        self.assertEqual(decision["run_id"], 41)
        self.assertEqual(decision["action"], "ATTACK")
        self.assertAlmostEqual(decision["confidence"], 0.982)
        self.assertEqual(decision["architecture_name"], "npc_teste_4_6_4")
        self.assertGreaterEqual(decision["database_round_trip_ms"], decision["mysql_inference_ms"])
        self.assertTrue(connection.committed)
        self.assertTrue(cursor.closed)
        self.assertTrue(connection.closed)

    def test_configured_architecture_is_passed_as_a_sql_parameter(self):
        cursor = FakeCursor((52, "FLEE", 0.81))
        service = DatabaseDecisionService(
            FakePool(FakeConnection(cursor)),
            architecture_name="npc_teste_4_64_32_64_4",
        )

        decision = service.decide(SESSION_ID, NPC)

        self.assertEqual(cursor.calls[0][0], "sp_nn_decide_for_architecture")
        self.assertEqual(cursor.calls[0][1][0], "npc_teste_4_64_32_64_4")
        self.assertEqual(cursor.calls[0][1][1], SESSION_ID)
        self.assertEqual(cursor.calls[1][0], "sp_nn_mark_session_v2")
        self.assertEqual(cursor.calls[2][0], "sp_nn_register_training_session_v2")
        self.assertEqual(decision["run_id"], 52)
        self.assertEqual(decision["action"], "FLEE")
        self.assertEqual(decision["architecture_name"], "npc_teste_4_64_32_64_4")

    def test_session_selected_architecture_overrides_default_as_bound_sql_parameter(self):
        cursor = FakeCursor((53, "FLEE", 0.82))
        service = DatabaseDecisionService(FakePool(FakeConnection(cursor)))

        decision = service.decide(SESSION_ID, NPC, "lab_4_32_4")

        self.assertEqual(cursor.calls[0][0], "sp_nn_decide_for_architecture")
        self.assertEqual(cursor.calls[0][1][0], "lab_4_32_4")
        self.assertEqual(decision["architecture_name"], "lab_4_32_4")

    def test_lab_reads_and_writes_use_fixed_procedures_and_bound_parameters(self):
        cursor = FakeCursor(())
        service = DatabaseDecisionService(FakePool(FakeConnection(cursor)))

        rows = service.list_lab_architectures()
        self.assertEqual(rows, [{"architecture_id": 42, "architecture_name": "lab_4_8_4"}])
        self.assertEqual(cursor.executed, ("CALL sp_nn_lab_list_architectures()", ()))

        service.create_lab_architecture("lab_4_8_4", [4, 8, 4], "relu")
        statement, parameters = cursor.executed
        self.assertEqual(statement, "CALL sp_nn_create_configurable_architecture(%s, %s, %s)")
        self.assertEqual(parameters, ("lab_4_8_4", "[4, 8, 4]", "relu"))

        service.create_lab_population("lab_4_8_4", 4, 12345)
        self.assertEqual(
            cursor.executed,
            ("CALL sp_nn_create_seeded_population(%s, %s, %s)", ("lab_4_8_4", 4, 12345)),
        )

    def test_training_session_is_registered_once_per_backend_process(self):
        cursor = FakeCursor((52, "CHASE", 0.81))
        connection = FakeConnection(cursor)
        service = DatabaseDecisionService(FakePool(connection))

        service.decide(SESSION_ID, NPC)
        service.decide(SESSION_ID, NPC)

        registrations = [
            call for call in cursor.calls
            if call[0] == "sp_nn_register_training_session_v2"
        ]
        self.assertEqual(len(registrations), 1)

    def test_invalid_mysql_action_is_rejected(self):
        cursor = FakeCursor((41, "invented", 0.5))
        connection = FakeConnection(cursor)
        service = DatabaseDecisionService(FakePool(connection))

        with self.assertRaises(DecisionError):
            service.decide(SESSION_ID, NPC)

    def test_combat_telemetry_is_sent_to_sql_procedure(self):
        cursor = FakeCursor(())
        connection = FakeConnection(cursor)
        service = DatabaseDecisionService(FakePool(connection))
        event = {
            "event_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
            "npc_id": 3052044,
            "event_type": "PLAYER_DAMAGE",
            "value": 12,
        }

        service.record_combat_event(SESSION_ID, event)

        self.assertEqual(cursor.procedure, "sp_nn_record_combat_event")
        self.assertEqual(cursor.parameters[0], event["event_id"])
        self.assertEqual(cursor.parameters[2], "3052044")
        self.assertEqual(cursor.parameters[3], "PLAYER_DAMAGE")
        self.assertTrue(connection.committed)

    def test_session_close_is_sent_to_sql_procedure(self):
        cursor = FakeCursor(())
        connection = FakeConnection(cursor)
        service = DatabaseDecisionService(FakePool(connection))

        ack_token = service.close_session(SESSION_ID)

        self.assertEqual(cursor.procedure, "sp_nn_finish_session_training_v2")
        self.assertEqual(cursor.parameters, (SESSION_ID, None))
        self.assertEqual(ack_token, ACK_TOKEN)
        self.assertTrue(connection.committed)

    def test_ack_receipt_is_sent_to_mysql_procedure(self):
        cursor = FakeCursor(())
        connection = FakeConnection(cursor)
        service = DatabaseDecisionService(FakePool(connection))

        service.confirm_training_ack(SESSION_ID, ACK_TOKEN)

        self.assertEqual(cursor.procedure, "sp_nn_confirm_training_ack_v2")
        self.assertEqual(cursor.parameters, (SESSION_ID, ACK_TOKEN))
        self.assertTrue(connection.committed)

    def test_malformed_ack_token_is_rejected_before_mysql(self):
        cursor = FakeCursor(())
        service = DatabaseDecisionService(FakePool(FakeConnection(cursor)))

        with self.assertRaises(ValueError):
            service.confirm_training_ack(SESSION_ID, "not-a-uuid")

        self.assertEqual(cursor.calls, [])


class WebSocketBridgeTests(unittest.TestCase):
    def test_health_checks_mysql_and_does_not_expose_connection_error(self):
        healthy = TestClient(create_app(StubService()))
        self.assertEqual(healthy.get("/health").status_code, 200)

        unavailable = TestClient(create_app(StubService(health_error=DecisionError("private connection details"))))
        response = unavailable.get("/health")
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("private connection details", response.text)

    def test_lab_read_api_returns_mysql_catalog_and_mutations_require_local_origin(self):
        client = TestClient(create_app(LabStubService()))
        catalog = client.get("/api/lab/architectures")
        self.assertEqual(catalog.status_code, 200)
        self.assertEqual(catalog.json()["configured_default"], "lab_4_64_4")
        self.assertEqual(catalog.json()["architectures"][0]["topology"], "4 -> 64 -> 4")
        layers = client.get("/api/lab/architectures/8/layers")
        self.assertEqual(layers.status_code, 200)
        self.assertEqual(layers.json()["layers"][0]["neuron_count"], 4)

        mutation = client.post(
            "/api/lab/architectures",
            headers={"Origin": "http://127.0.0.1:5173"},
            json={"architecture_name": "lab_4_8_4", "topology": [4, 8, 4]},
        )
        self.assertEqual(mutation.status_code, 403)

    def test_local_same_origin_can_create_architecture_and_empty_population(self):
        service = LabStubService()
        service.list_lab_architectures = lambda: [{
            "architecture_id": 8,
            "architecture_name": "lab_4_64_4",
            "topology": "4 -> 64 -> 4",
            "genome_count": 0,
        }]
        client = TestClient(
            create_app(service),
            base_url="http://127.0.0.1:8000",
            client=("127.0.0.1", 50000),
        )

        architecture = client.post(
            "/api/lab/architectures",
            headers={"Origin": "http://127.0.0.1:5173"},
            json={"architecture_name": "lab_4_8_4", "topology": [4, 8, 4]},
        )
        population = client.post(
            "/api/lab/architectures/lab_4_64_4/population",
            headers={"Origin": "http://127.0.0.1:5173"},
            json={"population_size": 4, "seed": 12345},
        )

        self.assertEqual(architecture.status_code, 200)
        self.assertEqual(architecture.json()["created"][0]["architecture_name"], "lab_4_8_4")
        self.assertEqual(population.status_code, 200)
        self.assertEqual(population.json()["population_size"], 4)

    def test_returns_action_and_preserves_request_and_npc_ids(self):
        service = StubService()
        client = TestClient(create_app(service))

        with client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({
                "type": "npc_state",
                "request_id": "req-1",
                "session_id": SESSION_ID,
                "npc": NPC,
            })
            response = websocket.receive_json()

        self.assertEqual(response["request_id"], "req-1")
        self.assertEqual(response["npc_id"], NPC["npc_id"])
        self.assertEqual(response["action"], "CHASE")
        self.assertEqual(response["run_id"], 17)
        self.assertEqual(service.calls[0][0], SESSION_ID)

    def test_selected_architecture_is_stable_for_the_lifetime_of_a_session(self):
        service = StubService()
        client = TestClient(create_app(service))
        with client.websocket_connect("/ws/ai") as websocket:
            for request_id, architecture in (("arch-1", "lab_4_32_4"), ("arch-2", "lab_4_64_4")):
                websocket.send_json({
                    "type": "npc_state",
                    "request_id": request_id,
                    "session_id": SESSION_ID,
                    "architecture_name": architecture,
                    "npc": NPC,
                })
                responses = []
                while True:
                    response = websocket.receive_json()
                    if response.get("request_id") == request_id:
                        responses.append(response)
                        break
                if request_id == "arch-1":
                    self.assertEqual(responses[0]["action"], "CHASE")
                else:
                    self.assertEqual(responses[0]["reason"], "architecture_locked_for_session")
        self.assertEqual(service.calls[0][2], "lab_4_32_4")
        self.assertEqual(len(service.calls), 1)

    def test_mysql_failure_returns_invalid_for_engine_fallback(self):
        client = TestClient(create_app(StubService(error=DecisionError("offline"))))

        with client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({
                "type": "npc_state",
                "request_id": "req-offline",
                "session_id": SESSION_ID,
                "npc": NPC,
            })
            response = websocket.receive_json()

        self.assertEqual(response["action"], "INVALID")
        self.assertEqual(response["reason"], "mysql_unavailable")

    def test_slow_mysql_decision_returns_invalid_at_deadline(self):
        client = TestClient(create_app(StubService(delay_seconds=2.0)))

        started_at = time.perf_counter()
        with client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({
                "type": "npc_state",
                "request_id": "req-slow",
                "session_id": SESSION_ID,
                "npc": NPC,
            })
            response = websocket.receive_json()
            response_elapsed = time.perf_counter() - started_at

        self.assertEqual(response["action"], "INVALID")
        self.assertEqual(response["reason"], "mysql_unavailable")
        self.assertGreaterEqual(response_elapsed, 1.4)
        self.assertLess(response_elapsed, 1.9)

    def test_invalid_service_result_returns_invalid(self):
        invalid_result = {"run_id": 17, "action": ["ATTACK"], "confidence": 0.75}
        client = TestClient(create_app(StubService(result=invalid_result)))

        with client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({
                "type": "npc_state",
                "request_id": "req-bad-result",
                "session_id": SESSION_ID,
                "npc": NPC,
            })
            response = websocket.receive_json()

        self.assertEqual(response["action"], "INVALID")
        self.assertEqual(response["reason"], "invalid_database_result")

    def test_combat_event_and_session_end_are_forwarded(self):
        service = StubService()
        client = TestClient(create_app(service))
        event = {
            "event_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
            "npc_id": 3052044,
            "event_type": "PLAYER_DAMAGE",
            "value": 12,
        }

        with client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({
                "type": "combat_event",
                "session_id": SESSION_ID,
                "event": event,
            })
            event_response = websocket.receive_json()
            websocket.send_json({"type": "session_end", "session_id": SESSION_ID})
            session_response = websocket.receive_json()
            websocket.send_json({
                "type": "session_end_ack_receipt",
                "session_id": SESSION_ID,
                "ack_token": session_response["ack_token"],
            })
            receipt_response = websocket.receive_json()

        self.assertTrue(event_response["stored"])
        self.assertEqual(service.events, [(SESSION_ID, event)])
        self.assertTrue(session_response["closed"])
        self.assertTrue(session_response["training_evaluation_complete"])
        self.assertEqual(session_response["ack_token"], ACK_TOKEN)
        self.assertEqual(session_response["session_id"], SESSION_ID)
        self.assertEqual(service.closed_sessions, [SESSION_ID])
        self.assertTrue(receipt_response["confirmed"])
        self.assertEqual(service.confirmed_acks, [(SESSION_ID, ACK_TOKEN)])

    def test_session_end_is_not_acknowledged_closed_when_mysql_rejects_it(self):
        service = StubService(close_error=DecisionError("session missing"))
        client = TestClient(create_app(service))

        with client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({"type": "session_end", "session_id": SESSION_ID})
            response = websocket.receive_json()

        self.assertFalse(response["closed"])
        self.assertIsNone(response["ack_token"])
        self.assertEqual(response["session_id"], SESSION_ID)
        self.assertEqual(service.closed_sessions, [])

    def test_action_metrics_are_acknowledged_and_returned_with_session_end(self):
        service = StubService()
        app = create_app(service)
        client = TestClient(app)

        with client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({
                "type": "action_metrics",
                "session_id": SESSION_ID,
                "metrics": ACTION_METRICS,
            })
            metrics_ack = websocket.receive_json()
            websocket.send_json({"type": "session_end", "session_id": SESSION_ID})
            end_ack = websocket.receive_json()
            websocket.send_json({
                "type": "session_end_ack_receipt",
                "session_id": SESSION_ID,
                "ack_token": end_ack["ack_token"],
            })
            receipt_ack = websocket.receive_json()

        self.assertTrue(metrics_ack["accepted"])
        self.assertEqual(end_ack["action_metrics"], ACTION_METRICS)
        self.assertTrue(end_ack["closed"])
        self.assertTrue(receipt_ack["confirmed"])
        self.assertNotIn(SESSION_ID, app.state.action_metrics)

    def test_action_metrics_reject_inconsistent_and_stale_snapshots(self):
        invalid = {**ACTION_METRICS, "applied": 3}
        with self.assertRaises(InvalidActionMetrics):
            validate_action_metrics(invalid)

        previous = validate_action_metrics(ACTION_METRICS)
        older = deepcopy(ACTION_METRICS)
        older.update({"opportunities": 3, "sql_decisions": 1, "sent_to_engine": 2, "applied": 1})
        older["actions"]["CHASE"].update({"selected": 1, "sent_to_engine": 1, "applied": 1})
        older["actions"]["ATTACK"].update({"selected": 0, "sent_to_engine": 1, "rejected": 1})
        self.assertFalse(is_monotonic_snapshot(validate_action_metrics(older), previous))

        client = TestClient(create_app(StubService()))
        with client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({
                "type": "action_metrics",
                "session_id": SESSION_ID,
                "metrics": ACTION_METRICS,
            })
            latest_response = websocket.receive_json()
            websocket.send_json({
                "type": "action_metrics",
                "session_id": SESSION_ID,
                "metrics": older,
            })
            stale_response = websocket.receive_json()
        self.assertTrue(latest_response["accepted"])
        self.assertFalse(stale_response["accepted"])

        invalid_client = TestClient(create_app(StubService()))
        with invalid_client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({
                "type": "action_metrics",
                "session_id": SESSION_ID,
                "metrics": invalid,
            })
            invalid_response = websocket.receive_json()
        self.assertFalse(invalid_response["accepted"])

    def test_malformed_observation_returns_invalid(self):
        service = StubService()
        client = TestClient(create_app(service))

        with client.websocket_connect("/ws/ai") as websocket:
            websocket.send_json({
                "type": "npc_state",
                "request_id": "req-invalid",
                "session_id": SESSION_ID,
                "npc": {**NPC, "max_health": 0},
            })
            response = websocket.receive_json()

        self.assertEqual(response["action"], "INVALID")
        self.assertEqual(response["reason"], "invalid_request")
        self.assertEqual(len(service.calls), 0)


if __name__ == "__main__":
    unittest.main()
