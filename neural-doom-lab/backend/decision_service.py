from __future__ import annotations

import math
import json
import os
import re
import threading
import time
import uuid
from dataclasses import dataclass
from typing import Any, Protocol


VALID_ACTIONS = {"IDLE", "CHASE", "ATTACK", "FLEE"}
COMBAT_EVENT_TYPES = {"PLAYER_DAMAGE", "PLAYER_KILL", "NPC_DAMAGE", "NPC_DEATH"}
ALLOWED_DATABASES = {
    "neural_doom_local_game_20261024",
    "neural_doom_local_sql_test_20261024",
}


class DecisionError(RuntimeError):
    """A falha impede a consulta segura ao MySQL."""


class InvalidRequest(ValueError):
    """O estado recebido do engine não pode ser usado na rede."""


class ConnectionPool(Protocol):
    def get_connection(self) -> Any: ...


class DecisionService(Protocol):
    def check_health(self) -> None: ...
    def decide(self, session_id: Any, npc: Any, architecture_name: Any = None) -> dict[str, Any]: ...
    def record_combat_event(self, session_id: Any, event: Any) -> None: ...
    def close_session(self, session_id: Any) -> str | None: ...
    def confirm_training_ack(self, session_id: Any, ack_token: Any) -> None: ...


@dataclass(frozen=True)
class NpcObservation:
    engine_npc_id: str
    npc_type: int
    health: int
    max_health: int
    player_distance: float
    player_visible: int
    current_state: int
    attribution_version: str


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
    attribution_version = npc.get("attribution_version")
    if attribution_version != "neural_attack_provenance_v2":
        raise InvalidRequest("versão de atribuição do engine ausente ou incompatível")

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
        attribution_version=attribution_version,
    )


class DatabaseDecisionService:
    def __init__(self, pool: ConnectionPool | None = None, architecture_name: str | None = None):
        self._pool = pool
        self._pool_lock = threading.Lock()
        self._training_sessions_lock = threading.Lock()
        self._training_sessions: dict[str, None] = {}
        selected_architecture = architecture_name or os.environ.get("NN_ARCHITECTURE_NAME")
        self._architecture_name = selected_architecture.strip() if selected_architecture else None
        if self._architecture_name == "":
            self._architecture_name = None

    @property
    def configured_architecture_name(self) -> str | None:
        return self._architecture_name

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
                database = os.environ.get("NN_DB_NAME", "neural_doom_local_game_20261024")
                if database not in ALLOWED_DATABASES:
                    raise DecisionError("NN_DB_NAME precisa apontar para um schema isolado Neural Doom")
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

    def check_health(self) -> None:
        connection = None
        cursor = None
        try:
            connection = self._get_pool().get_connection()
            cursor = connection.cursor()
            cursor.execute("SELECT 1")
            result = cursor.fetchone()
            if not result or result[0] != 1:
                raise DecisionError("MySQL não confirmou a consulta de saúde")
        except DecisionError:
            raise
        except Exception as exc:
            raise DecisionError("MySQL indisponível") from exc
        finally:
            if cursor is not None:
                cursor.close()
            if connection is not None:
                connection.close()

    def decide(
        self,
        session_id: Any,
        npc: Any,
        architecture_name: Any = None,
    ) -> dict[str, Any]:
        canonical_session_id, observation = validate_observation(session_id, npc)
        if architecture_name is not None:
            if (
                not isinstance(architecture_name, str)
                or not architecture_name.strip()
                or len(architecture_name.strip()) > 50
            ):
                raise InvalidRequest("architecture_name inválido")
            requested_architecture = architecture_name.strip()
        else:
            requested_architecture = self._architecture_name
        effective_architecture = requested_architecture or "npc_teste_4_6_4"
        connection = None
        cursor = None
        started_at = time.perf_counter()
        inference_ms = None

        try:
            connection = self._get_pool().get_connection()
            cursor = connection.cursor()
            parameters = (
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
            )
            if architecture_name is not None or (
                requested_architecture and requested_architecture != "npc_teste_4_6_4"
            ):
                procedure = "sp_nn_decide_for_architecture"
                parameters = (effective_architecture, *parameters)
            else:
                procedure = "sp_nn_decide"
            inference_started = time.perf_counter()
            result = cursor.callproc(procedure, parameters)
            inference_ms = (time.perf_counter() - inference_started) * 1000
            cursor.callproc("sp_nn_mark_session_v2", (canonical_session_id,))
            with self._training_sessions_lock:
                if canonical_session_id not in self._training_sessions:
                    cursor.callproc(
                        "sp_nn_register_training_session_v2",
                        (canonical_session_id,),
                    )
                    connection.commit()
                    self._training_sessions[canonical_session_id] = None
                    if len(self._training_sessions) > 512:
                        oldest_session = next(iter(self._training_sessions))
                        self._training_sessions.pop(oldest_session, None)
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

        output_offset = len(result) - 3
        run_id, action, confidence = result[output_offset:]
        if action not in VALID_ACTIONS or not isinstance(run_id, int) or confidence is None:
            raise DecisionError("A procedure MySQL retornou uma decisão inválida")

        return {
            "run_id": run_id,
            "action": action,
            "confidence": float(confidence),
            "architecture_name": effective_architecture,
            "mysql_inference_ms": inference_ms,
            "database_round_trip_ms": (time.perf_counter() - started_at) * 1000,
        }

    @staticmethod
    def _result_sets(cursor: Any) -> list[list[dict[str, Any]]]:
        result_sets: list[list[dict[str, Any]]] = []
        while True:
            if getattr(cursor, "description", None):
                column_names = [column[0] for column in cursor.description]
                rows = cursor.fetchall()
                if rows and isinstance(rows[0], dict):
                    result_sets.append(rows)
                else:
                    result_sets.append([
                        dict(zip(column_names, row, strict=False)) for row in rows
                    ])
            nextset = getattr(cursor, "nextset", None)
            if nextset is None or not nextset():
                break
        return result_sets

    def _call_lab_procedure(
        self,
        procedure: str,
        parameters: tuple[Any, ...] = (),
        *,
        commit: bool = False,
    ) -> list[dict[str, Any]]:
        # Procedure names are internal constants at every call site; all values
        # remain bound parameters, including architecture and genome selectors.
        connection = None
        cursor = None
        try:
            connection = self._get_pool().get_connection()
            try:
                cursor = connection.cursor(dictionary=True)
            except TypeError:
                cursor = connection.cursor()
            placeholders = ", ".join(["%s"] * len(parameters))
            cursor.execute(f"CALL {procedure}({placeholders})", parameters)
            result_sets = self._result_sets(cursor)
            if commit:
                connection.commit()
            return result_sets[0] if result_sets else []
        except Exception as exc:
            if connection is not None:
                try:
                    connection.rollback()
                except Exception:
                    pass
            if isinstance(exc, DecisionError):
                raise
            raise DecisionError("A operação do laboratório MySQL falhou") from exc
        finally:
            if cursor is not None:
                cursor.close()
            if connection is not None:
                connection.close()

    def list_lab_architectures(self) -> list[dict[str, Any]]:
        return self._call_lab_procedure("sp_nn_lab_list_architectures")

    def list_lab_architecture_layers(self, architecture_id: int) -> list[dict[str, Any]]:
        return self._call_lab_procedure(
            "sp_nn_lab_architecture_layers", (architecture_id,)
        )

    def list_lab_genomes(
        self,
        architecture_id: int,
        generation: int | None,
        limit: int,
        offset: int,
    ) -> list[dict[str, Any]]:
        return self._call_lab_procedure(
            "sp_nn_lab_list_genomes", (architecture_id, generation, limit, offset)
        )

    def get_lab_run_activations(
        self,
        run_id: int,
        layer_order: int,
        limit: int,
        offset: int,
    ) -> list[dict[str, Any]]:
        return self._call_lab_procedure(
            "sp_nn_lab_run_activations", (run_id, layer_order, limit, offset)
        )

    def get_lab_genome_weights(
        self,
        genome_id: int,
        target_layer_order: int,
        target_position: int,
        limit: int,
        offset: int,
    ) -> list[dict[str, Any]]:
        return self._call_lab_procedure(
            "sp_nn_lab_genome_weights",
            (genome_id, target_layer_order, target_position, limit, offset),
        )

    def create_lab_architecture(
        self,
        architecture_name: str,
        topology: list[int],
        hidden_activation: str,
    ) -> list[dict[str, Any]]:
        return self._call_lab_procedure(
            "sp_nn_create_configurable_architecture",
            (architecture_name, json.dumps(topology), hidden_activation),
            commit=True,
        )

    def create_lab_population(
        self,
        architecture_name: str,
        population_size: int,
        seed: int,
    ) -> list[dict[str, Any]]:
        return self._call_lab_procedure(
            "sp_nn_create_seeded_population",
            (architecture_name, population_size, seed),
            commit=True,
        )

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

    def close_session(self, session_id: Any) -> str | None:
        try:
            canonical_session_id = str(uuid.UUID(session_id))
        except (ValueError, TypeError, AttributeError) as exc:
            raise InvalidRequest("ID da sessão inválido") from exc

        connection = None
        cursor = None
        try:
            connection = self._get_pool().get_connection()
            cursor = connection.cursor()
            result = cursor.callproc(
                "sp_nn_finish_session_training_v2",
                (canonical_session_id, None),
            )
            connection.commit()
            ack_token = result[-1] if result else None
            with self._training_sessions_lock:
                self._training_sessions.pop(canonical_session_id, None)
            return str(ack_token) if ack_token is not None else None
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

    def confirm_training_ack(self, session_id: Any, ack_token: Any) -> None:
        try:
            canonical_session_id = str(uuid.UUID(session_id))
            canonical_ack_token = str(uuid.UUID(ack_token))
        except (ValueError, TypeError, AttributeError) as exc:
            raise InvalidRequest("ID da sessão ou token de ACK inválido") from exc

        connection = None
        cursor = None
        try:
            connection = self._get_pool().get_connection()
            cursor = connection.cursor()
            cursor.callproc(
                "sp_nn_confirm_training_ack_v2",
                (canonical_session_id, canonical_ack_token),
            )
            connection.commit()
        except Exception as exc:
            if connection is not None:
                try:
                    connection.rollback()
                except Exception:
                    pass
            raise DecisionError("A confirmação de ACK de treinamento falhou") from exc
        finally:
            if cursor is not None:
                cursor.close()
            if connection is not None:
                connection.close()
