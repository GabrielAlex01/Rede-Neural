from __future__ import annotations

import math
import os
import threading
import uuid
from dataclasses import dataclass
from typing import Any, Protocol


VALID_ACTIONS = {"IDLE", "CHASE", "ATTACK", "FLEE"}
COMBAT_EVENT_TYPES = {"PLAYER_DAMAGE", "PLAYER_KILL", "NPC_DAMAGE", "NPC_DEATH"}


class DecisionError(RuntimeError):
    """A falha impede a consulta segura ao MySQL."""


class InvalidRequest(ValueError):
    """O estado recebido do engine não pode ser usado na rede."""


class ConnectionPool(Protocol):
    def get_connection(self) -> Any: ...


class DecisionService(Protocol):
    def decide(self, session_id: Any, npc: Any) -> dict[str, Any]: ...
    def record_combat_event(self, session_id: Any, event: Any) -> None: ...
    def close_session(self, session_id: Any) -> None: ...


@dataclass(frozen=True)
class NpcObservation:
    engine_npc_id: str
    npc_type: int
    health: int
    max_health: int
    player_distance: float
    player_visible: int
    current_state: int


def _integer(value: Any, field: str, *, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise InvalidRequest(f"{field} fora do intervalo permitido")
    return value


def validate_observation(session_id: Any, npc: Any) -> tuple[str, NpcObservation]:
    if not isinstance(session_id, str):
        raise InvalidRequest("session_id ausente")
    try:
        parsed_session_id = uuid.UUID(session_id)
    except (ValueError, AttributeError) as exc:
        raise InvalidRequest("session_id inválido") from exc

    if not isinstance(npc, dict):
        raise InvalidRequest("npc precisa ser um objeto")

    npc_id = npc.get("npc_id")
    if isinstance(npc_id, bool) or not isinstance(npc_id, (str, int)):
        raise InvalidRequest("npc_id inválido")
    engine_npc_id = str(npc_id).strip()
    if not engine_npc_id or len(engine_npc_id) > 64 or (isinstance(npc_id, int) and npc_id < 0):
        raise InvalidRequest("npc_id inválido")

    npc_type = _integer(npc.get("npc_type"), "npc_type", minimum=0, maximum=65535)
    max_health = _integer(npc.get("max_health"), "max_health", minimum=1, maximum=2_147_483_647)
    health = _integer(npc.get("health"), "health", minimum=0, maximum=max_health)
    current_state = _integer(npc.get("current_state"), "current_state", minimum=0, maximum=2_147_483_647)

    visible = npc.get("player_visible")
    if isinstance(visible, bool):
        player_visible = int(visible)
    elif isinstance(visible, int) and visible in (0, 1):
        player_visible = visible
    else:
        raise InvalidRequest("player_visible precisa ser booleano")

    distance = npc.get("player_distance")
    if isinstance(distance, bool) or not isinstance(distance, (int, float)):
        raise InvalidRequest("player_distance precisa ser numérico")
    player_distance = float(distance)
    if not math.isfinite(player_distance) or not 0 <= player_distance <= 10_000_000:
        raise InvalidRequest("player_distance fora do intervalo permitido")

    return str(parsed_session_id), NpcObservation(
        engine_npc_id=engine_npc_id,
        npc_type=npc_type,
        health=health,
        max_health=max_health,
        player_distance=player_distance,
        player_visible=player_visible,
        current_state=current_state,
    )


class DatabaseDecisionService:
    def __init__(self, pool: ConnectionPool | None = None):
        self._pool = pool
        self._pool_lock = threading.Lock()

    @classmethod
    def from_environment(cls) -> DatabaseDecisionService:
        return cls()

    def _get_pool(self) -> ConnectionPool:
        if self._pool is not None:
            return self._pool

        with self._pool_lock:
            if self._pool is not None:
                return self._pool

            try:
                import mysql.connector.pooling

                host = os.environ.get("NN_DB_HOST", "127.0.0.1")
                port = int(os.environ.get("NN_DB_PORT", "3306"))
                user = os.environ["NN_DB_USER"]
                password = os.environ["NN_DB_PASSWORD"]
                database = os.environ.get("NN_DB_NAME", "npc_neural_game")
                self._pool = mysql.connector.pooling.MySQLConnectionPool(
                    pool_name="neural_doom_pool",
                    pool_size=5,
                    host=host,
                    port=port,
                    user=user,
                    password=password,
                    database=database,
                    connection_timeout=3,
                    read_timeout=3,
                    write_timeout=3,
                    autocommit=False,
                )
            except (KeyError, ValueError) as exc:
                raise DecisionError("Configure NN_DB_USER, NN_DB_PASSWORD e NN_DB_NAME") from exc
            except Exception as exc:
                raise DecisionError("Não foi possível inicializar o pool MySQL") from exc

            return self._pool

    def decide(self, session_id: Any, npc: Any) -> dict[str, Any]:
        canonical_session_id, observation = validate_observation(session_id, npc)
        connection = None
        cursor = None

        try:
            connection = self._get_pool().get_connection()
            cursor = connection.cursor()
            result = cursor.callproc(
                "sp_nn_decide",
                (
                    canonical_session_id,
                    observation.engine_npc_id,
                    observation.npc_type,
                    observation.health,
                    observation.max_health,
                    observation.player_distance,
                    observation.player_visible,
                    observation.current_state,
                    0,
                    "",
                    0.0,
                ),
            )
            connection.commit()
        except InvalidRequest:
            raise
        except Exception as exc:
            if connection is not None:
                try:
                    connection.rollback()
                except Exception:
                    pass
            raise DecisionError("A procedure de decisão MySQL falhou") from exc
        finally:
            if cursor is not None:
                cursor.close()
            if connection is not None:
                connection.close()

        run_id, action, confidence = result[8], result[9], result[10]
        if action not in VALID_ACTIONS or not isinstance(run_id, int) or confidence is None:
            raise DecisionError("A procedure MySQL retornou uma decisão inválida")

        return {
            "run_id": run_id,
            "action": action,
            "confidence": float(confidence),
        }

    def record_combat_event(self, session_id: Any, event: Any) -> None:
        if not isinstance(event, dict):
            raise InvalidRequest("combat_event precisa ser um objeto")
        try:
            canonical_session_id = str(uuid.UUID(session_id))
            event_id = str(uuid.UUID(event.get("event_id")))
        except (ValueError, TypeError, AttributeError) as exc:
            raise InvalidRequest("ID do evento ou da sessão inválido") from exc

        npc_id = event.get("npc_id")
        if isinstance(npc_id, bool) or not isinstance(npc_id, (str, int)):
            raise InvalidRequest("npc_id inválido")
        engine_npc_id = str(npc_id).strip()
        if not engine_npc_id or len(engine_npc_id) > 64 or (isinstance(npc_id, int) and npc_id < 0):
            raise InvalidRequest("npc_id inválido")

        event_type = event.get("event_type")
        if not isinstance(event_type, str) or event_type not in COMBAT_EVENT_TYPES:
            raise InvalidRequest("event_type inválido")
        value = event.get("value")
        if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 2_147_483_647:
            raise InvalidRequest("value fora do intervalo permitido")
        if event_type in {"PLAYER_KILL", "NPC_DEATH"} and value != 1:
            raise InvalidRequest("eventos de morte devem ter valor 1")

        connection = None
        cursor = None
        try:
            connection = self._get_pool().get_connection()
            cursor = connection.cursor()
            cursor.callproc(
                "sp_nn_record_combat_event",
                (event_id, canonical_session_id, engine_npc_id, event_type, value),
            )
            connection.commit()
        except Exception as exc:
            if connection is not None:
                try:
                    connection.rollback()
                except Exception:
                    pass
            raise DecisionError("O registro do evento MySQL falhou") from exc
        finally:
            if cursor is not None:
                cursor.close()
            if connection is not None:
                connection.close()

    def close_session(self, session_id: Any) -> None:
        try:
            canonical_session_id = str(uuid.UUID(session_id))
        except (ValueError, TypeError, AttributeError) as exc:
            raise InvalidRequest("ID da sessão inválido") from exc

        connection = None
        cursor = None
        try:
            connection = self._get_pool().get_connection()
            cursor = connection.cursor()
            cursor.callproc("sp_nn_finish_session", (canonical_session_id,))
            connection.commit()
        except Exception as exc:
            if connection is not None:
                try:
                    connection.rollback()
                except Exception:
                    pass
            raise DecisionError("O encerramento da sessão MySQL falhou") from exc
        finally:
            if cursor is not None:
                cursor.close()
            if connection is not None:
                connection.close()
