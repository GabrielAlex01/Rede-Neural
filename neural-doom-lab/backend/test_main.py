import unittest

from fastapi.testclient import TestClient

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


class StubService:
    def __init__(self, result=None, error=None):
        self.result = result or {"run_id": 17, "action": "CHASE", "confidence": 0.75}
        self.error = error
        self.calls = []

    def decide(self, session_id, npc):
        validate_observation(session_id, npc)
        self.calls.append((session_id, npc))
        if self.error:
            raise self.error
        return self.result


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
