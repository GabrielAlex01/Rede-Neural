from copy import deepcopy
import time
import unittest

from fastapi.testclient import TestClient

from backend.action_metrics import InvalidActionMetrics, is_monotonic_snapshot, validate_action_metrics
from backend.decision_service import DatabaseDecisionService, DecisionError, validate_observation
from backend.main import create_app


SESSION_ID = "11111111-1111-4111-8111-111111111111"
NPC = {
    "npc_id": 3052044,
    "npc_type": 12,
    "health": 80,
    "max_health": 100,
    "player_distance": 3010,
    "player_visible": True,
    "current_state": 482,
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
    def __init__(self, result=None, error=None, delay_seconds=0):
        self.result = result or {"run_id": 17, "action": "CHASE", "confidence": 0.75}
        self.error = error
        self.delay_seconds = delay_seconds
        self.calls = []
        self.events = []
        self.closed_sessions = []

    def decide(self, session_id, npc):
        validate_observation(session_id, npc)
        self.calls.append((session_id, npc))
        if self.delay_seconds:
            time.sleep(self.delay_seconds)
        if self.error:
            raise self.error
        return self.result

    def record_combat_event(self, session_id, event):
        self.events.append((session_id, event))

    def close_session(self, session_id):
        self.closed_sessions.append(session_id)


class FakeCursor:
    def __init__(self, outputs):
        self.outputs = outputs
        self.procedure = None
        self.parameters = None
        self.closed = False

    def callproc(self, procedure, parameters):
        self.procedure = procedure
        self.parameters = parameters
        return (*parameters[:8], *self.outputs)

    def close(self):
        self.closed = True


class FakeConnection:
    def __init__(self, cursor):
        self.fake_cursor = cursor
        self.committed = False
        self.rolled_back = False
        self.closed = False

    def cursor(self):
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
    def test_observation_is_validated_without_python_policy(self):
        session_id, observation = validate_observation(SESSION_ID, NPC)
        self.assertEqual(session_id, SESSION_ID)
        self.assertEqual(observation.engine_npc_id, "3052044")
        self.assertEqual(observation.max_health, 100)
        self.assertEqual(observation.player_visible, 1)

    def test_invalid_health_is_rejected_before_sql(self):
        with self.assertRaises(ValueError):
            validate_observation(SESSION_ID, {**NPC, "health": 101})

    def test_decision_is_returned_by_mysql_procedure(self):
        cursor = FakeCursor((41, "ATTACK", 0.982))
        connection = FakeConnection(cursor)
        service = DatabaseDecisionService(FakePool(connection))

        decision = service.decide(SESSION_ID, NPC)

        self.assertEqual(cursor.procedure, "sp_nn_decide")
        self.assertEqual(cursor.parameters[0], SESSION_ID)
        self.assertEqual(cursor.parameters[1], "3052044")
        self.assertEqual(cursor.parameters[4], 100)
        self.assertEqual(decision, {"run_id": 41, "action": "ATTACK", "confidence": 0.982})
        self.assertTrue(connection.committed)
        self.assertTrue(cursor.closed)
        self.assertTrue(connection.closed)

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

        service.close_session(SESSION_ID)

        self.assertEqual(cursor.procedure, "sp_nn_finish_session")
        self.assertEqual(cursor.parameters[0], SESSION_ID)
        self.assertTrue(connection.committed)


class WebSocketBridgeTests(unittest.TestCase):
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

        self.assertTrue(event_response["stored"])
        self.assertEqual(service.events, [(SESSION_ID, event)])
        self.assertTrue(session_response["closed"])
        self.assertEqual(session_response["session_id"], SESSION_ID)
        self.assertEqual(service.closed_sessions, [SESSION_ID])

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

        self.assertTrue(metrics_ack["accepted"])
        self.assertEqual(end_ack["action_metrics"], ACTION_METRICS)
        self.assertTrue(end_ack["closed"])
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
