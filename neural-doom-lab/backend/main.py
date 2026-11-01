import asyncio
import ipaddress
import logging
import os
import re
from pathlib import Path
from urllib.parse import urlsplit
from uuid import UUID

from dotenv import load_dotenv
from fastapi import Body, FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from backend.action_metrics import (
    InvalidActionMetrics,
    format_action_metrics,
    is_monotonic_snapshot,
    validate_action_metrics,
)
from backend.decision_service import (
    DatabaseDecisionService,
    DecisionError,
    DecisionService,
    InvalidRequest,
)


load_dotenv(Path(__file__).with_name(".env"))
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("neural_doom")

VALID_ACTIONS = {"IDLE", "CHASE", "ATTACK", "FLEE"}
MAX_TRACKED_METRIC_SESSIONS = 128
MAX_ARCHITECTURE_NAME_LENGTH = 50
LOCAL_ADMIN_ORIGINS = {
    origin.strip().rstrip("/")
    for origin in os.environ.get(
        "NN_LAB_ALLOWED_ORIGINS",
        "http://127.0.0.1:5173,http://localhost:5173",
    ).split(",")
    if origin.strip()
}


def _is_local_admin_request(request: Request) -> bool:
    client_host = request.client.host if request.client else ""
    try:
        if not ipaddress.ip_address(client_host).is_loopback:
            return False
    except ValueError:
        return False

    origin = request.headers.get("origin", "").rstrip("/")
    if origin not in LOCAL_ADMIN_ORIGINS:
        return False
    origin_host = urlsplit(origin).hostname
    request_host = request.url.hostname
    return bool(origin_host and request_host and origin_host.lower() == request_host.lower())


def _validate_architecture_payload(payload: object) -> tuple[str, list[int], str]:
    if not isinstance(payload, dict):
        raise HTTPException(status_code=422, detail="invalid_architecture_payload")
    name = payload.get("architecture_name")
    topology = payload.get("topology")
    activation = payload.get("hidden_activation", "relu")
    if (
        not isinstance(name, str)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,49}", name)
        or len(name) > MAX_ARCHITECTURE_NAME_LENGTH
    ):
        raise HTTPException(status_code=422, detail="invalid_architecture_name")
    if (
        not isinstance(topology, list)
        or not 3 <= len(topology) <= 8
        or any(isinstance(width, bool) or not isinstance(width, int) or not 1 <= width <= 512 for width in topology)
        or topology[0] != 4
        or topology[-1] != 4
    ):
        raise HTTPException(status_code=422, detail="invalid_topology_requires_4_inputs_and_outputs")
    parameters = sum(topology[index - 1] * topology[index] + topology[index] for index in range(1, len(topology)))
    if parameters > 120_000:
        raise HTTPException(status_code=422, detail="topology_exceeds_120000_trainable_parameters")
    if activation not in {"sigmoid", "relu", "tanh"}:
        raise HTTPException(status_code=422, detail="invalid_hidden_activation")
    return name, topology, activation


def create_app(service: DecisionService | None = None) -> FastAPI:
    app = FastAPI(title="Neural Doom Lab MySQL Bridge")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=sorted(LOCAL_ADMIN_ORIGINS),
        allow_credentials=False,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["Content-Type"],
    )
    app.state.decision_service = service or DatabaseDecisionService.from_environment()
    app.state.action_metrics = {}
    app.state.session_architectures = {}
    app.state.lab_population_lock = asyncio.Lock()

    @app.get("/health")
    async def health() -> dict[str, str]:
        check_database = getattr(app.state.decision_service, "check_health", None)
        if check_database is not None:
            try:
                await asyncio.wait_for(asyncio.to_thread(check_database), timeout=4.0)
            except (DecisionError, asyncio.TimeoutError):
                raise HTTPException(status_code=503, detail="mysql_unavailable") from None
        return {"status": "ok", "decision_source": "mysql"}

    @app.get("/api/lab/architectures")
    async def lab_architectures() -> dict[str, object]:
        try:
            architectures = await asyncio.wait_for(
                asyncio.to_thread(app.state.decision_service.list_lab_architectures),
                timeout=4.0,
            )
        except (AttributeError, DecisionError, asyncio.TimeoutError):
            raise HTTPException(status_code=503, detail="neural_lab_unavailable") from None
        configured_default = getattr(
            app.state.decision_service, "configured_architecture_name", None
        )
        return {"architectures": architectures, "configured_default": configured_default}

    @app.get("/api/lab/architectures/{architecture_id}/layers")
    async def lab_architecture_layers(architecture_id: int) -> dict[str, object]:
        if architecture_id < 1:
            raise HTTPException(status_code=422, detail="invalid_architecture_id")
        try:
            layers = await asyncio.wait_for(
                asyncio.to_thread(
                    app.state.decision_service.list_lab_architecture_layers,
                    architecture_id,
                ),
                timeout=4.0,
            )
        except (AttributeError, DecisionError, asyncio.TimeoutError):
            raise HTTPException(status_code=503, detail="neural_lab_unavailable") from None
        return {"layers": layers}

    @app.get("/api/lab/architectures/{architecture_id}/genomes")
    async def lab_architecture_genomes(
        architecture_id: int,
        generation: int | None = Query(default=None, ge=0),
        limit: int = Query(default=50, ge=1, le=100),
        offset: int = Query(default=0, ge=0, le=1_000_000),
    ) -> dict[str, object]:
        if architecture_id < 1:
            raise HTTPException(status_code=422, detail="invalid_architecture_id")
        try:
            genomes = await asyncio.wait_for(
                asyncio.to_thread(
                    app.state.decision_service.list_lab_genomes,
                    architecture_id,
                    generation,
                    limit,
                    offset,
                ),
                timeout=4.0,
            )
        except (AttributeError, DecisionError, asyncio.TimeoutError):
            raise HTTPException(status_code=503, detail="neural_lab_unavailable") from None
        return {"genomes": genomes, "limit": limit, "offset": offset}

    @app.get("/api/lab/runs/{run_id}/activations")
    async def lab_run_activations(
        run_id: int,
        layer_order: int = Query(ge=0, le=7),
        limit: int = Query(default=128, ge=1, le=256),
        offset: int = Query(default=0, ge=0, le=1_000_000),
    ) -> dict[str, object]:
        if run_id < 1:
            raise HTTPException(status_code=422, detail="invalid_run_id")
        try:
            activations = await asyncio.wait_for(
                asyncio.to_thread(
                    app.state.decision_service.get_lab_run_activations,
                    run_id,
                    layer_order,
                    limit,
                    offset,
                ),
                timeout=4.0,
            )
        except (AttributeError, DecisionError, asyncio.TimeoutError):
            raise HTTPException(status_code=503, detail="neural_lab_unavailable") from None
        if not activations:
            raise HTTPException(status_code=404, detail="run_or_layer_not_found")
        return {"activations": activations, "limit": limit, "offset": offset}

    @app.get("/api/lab/genomes/{genome_id}/weights")
    async def lab_genome_weights(
        genome_id: int,
        layer_order: int = Query(ge=1, le=7),
        target_position: int = Query(ge=0),
        limit: int = Query(default=128, ge=1, le=200),
        offset: int = Query(default=0, ge=0, le=1_000_000),
    ) -> dict[str, object]:
        if genome_id < 1:
            raise HTTPException(status_code=422, detail="invalid_genome_id")
        try:
            weights = await asyncio.wait_for(
                asyncio.to_thread(
                    app.state.decision_service.get_lab_genome_weights,
                    genome_id,
                    layer_order,
                    target_position,
                    limit,
                    offset,
                ),
                timeout=4.0,
            )
        except (AttributeError, DecisionError, asyncio.TimeoutError):
            raise HTTPException(status_code=503, detail="neural_lab_unavailable") from None
        return {"weights": weights, "limit": limit, "offset": offset}

    @app.post("/api/lab/architectures")
    async def create_lab_architecture(
        request: Request,
        payload: object = Body(...),
    ) -> dict[str, object]:
        if not _is_local_admin_request(request):
            raise HTTPException(status_code=403, detail="local_same_origin_admin_required")
        name, topology, activation = _validate_architecture_payload(payload)
        try:
            created = await asyncio.wait_for(
                asyncio.to_thread(
                    app.state.decision_service.create_lab_architecture,
                    name,
                    topology,
                    activation,
                ),
                timeout=15.0,
            )
        except (AttributeError, DecisionError, asyncio.TimeoutError):
            raise HTTPException(status_code=409, detail="architecture_not_created_check_existing_name") from None
        return {"created": created}

    @app.post("/api/lab/architectures/{architecture_name}/population")
    async def create_lab_population(
        request: Request,
        architecture_name: str,
        payload: object = Body(...),
    ) -> dict[str, object]:
        if not _is_local_admin_request(request):
            raise HTTPException(status_code=403, detail="local_same_origin_admin_required")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,49}", architecture_name):
            raise HTTPException(status_code=422, detail="invalid_architecture_name")
        if not isinstance(payload, dict):
            raise HTTPException(status_code=422, detail="invalid_population_payload")
        size = payload.get("population_size")
        seed = payload.get("seed")
        if isinstance(size, bool) or not isinstance(size, int) or not 2 <= size <= 100:
            raise HTTPException(status_code=422, detail="population_size_must_be_2_to_100")
        if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed <= 4_294_967_295:
            raise HTTPException(status_code=422, detail="seed_must_be_unsigned_32_bit_integer")
        service = app.state.decision_service
        try:
            async with app.state.lab_population_lock:
                architectures = await asyncio.wait_for(
                    asyncio.to_thread(service.list_lab_architectures), timeout=4.0
                )
                architecture = next(
                    (item for item in architectures if item.get("architecture_name") == architecture_name),
                    None,
                )
                if architecture is None:
                    raise HTTPException(status_code=404, detail="architecture_not_found")
                if int(architecture.get("genome_count", 0)) > 0:
                    raise HTTPException(status_code=409, detail="population_already_exists_preserved")
                genomes = await asyncio.wait_for(
                    asyncio.to_thread(
                        service.create_lab_population,
                        architecture_name,
                        size,
                        seed,
                    ),
                    timeout=30.0,
                )
        except HTTPException:
            raise
        except (AttributeError, DecisionError, asyncio.TimeoutError):
            raise HTTPException(status_code=409, detail="population_not_created_check_existing_data") from None
        return {"seed": seed, "population_size": len(genomes), "genomes": genomes}

    @app.websocket("/ws/ai")
    async def ai_bridge(websocket: WebSocket) -> None:
        await websocket.accept()

        try:
            while True:
                message = await websocket.receive_json()
                if not isinstance(message, dict):
                    await websocket.send_json({
                        "type": "npc_action",
                        "request_id": None,
                        "npc_id": None,
                        "action": "INVALID",
                        "reason": "invalid_request",
                    })
                    continue

                request_id = message.get("request_id") if isinstance(message, dict) else None
                npc = message.get("npc") if isinstance(message, dict) else None
                session_id = message.get("session_id") if isinstance(message, dict) else None

                if message.get("type") == "action_metrics":
                    try:
                        canonical_session_id = str(UUID(session_id))
                        metrics = validate_action_metrics(message.get("metrics"))
                        previous = app.state.action_metrics.get(canonical_session_id)
                        if not is_monotonic_snapshot(metrics, previous):
                            raise InvalidActionMetrics("snapshot desatualizado")
                        if previous is None and len(app.state.action_metrics) >= MAX_TRACKED_METRIC_SESSIONS:
                            raise InvalidActionMetrics("limite de sessões de métricas atingido")
                    except (InvalidActionMetrics, ValueError, TypeError, AttributeError):
                        await websocket.send_json({
                            "type": "action_metrics_ack",
                            "session_id": session_id,
                            "accepted": False,
                        })
                    else:
                        app.state.action_metrics[canonical_session_id] = metrics
                        await websocket.send_json({
                            "type": "action_metrics_ack",
                            "session_id": canonical_session_id,
                            "accepted": True,
                        })
                    continue

                if message.get("type") == "combat_event":
                    event = message.get("event")
                    try:
                        await asyncio.wait_for(
                            asyncio.to_thread(
                                app.state.decision_service.record_combat_event,
                                session_id,
                                event,
                            ),
                            timeout=1.5,
                        )
                        stored = True
                        reason = None
                    except (InvalidRequest, asyncio.TimeoutError):
                        stored = False
                        reason = "invalid_event_or_mysql_unavailable"
                    except DecisionError as exc:
                        logger.warning("Combat event was not stored: %s", exc)
                        stored = False
                        reason = "mysql_unavailable"

                    await websocket.send_json({
                        "type": "combat_event_ack",
                        "event_id": event.get("event_id") if isinstance(event, dict) else None,
                        "stored": stored,
                        "reason": reason,
                    })
                    continue

                if message.get("type") == "session_end":
                    ack_token = None
                    try:
                        ack_token = await asyncio.wait_for(
                            asyncio.to_thread(
                                app.state.decision_service.close_session,
                                session_id,
                            ),
                            timeout=1.5,
                        )
                        closed = True
                    except (InvalidRequest, DecisionError, asyncio.TimeoutError):
                        closed = False
                    try:
                        canonical_session_id = str(UUID(session_id))
                    except (ValueError, TypeError, AttributeError):
                        canonical_session_id = None
                    if closed and canonical_session_id is not None:
                        app.state.session_architectures.pop(canonical_session_id, None)
                    metrics = app.state.action_metrics.get(canonical_session_id)
                    await websocket.send_json({
                        "type": "session_end_ack",
                        "session_id": session_id,
                        "closed": closed,
                        "training_evaluation_complete": ack_token is not None,
                        "ack_token": ack_token,
                        "action_metrics": metrics,
                    })
                    if closed and canonical_session_id is not None:
                        if metrics is not None:
                            logger.info(
                                "Neural action outcomes for session %s: %s",
                                canonical_session_id,
                                format_action_metrics(metrics),
                            )
                        app.state.action_metrics.pop(canonical_session_id, None)
                    continue

                if message.get("type") == "session_end_ack_receipt":
                    try:
                        await asyncio.wait_for(
                            asyncio.to_thread(
                                app.state.decision_service.confirm_training_ack,
                                session_id,
                                message.get("ack_token"),
                            ),
                            timeout=1.5,
                        )
                        confirmed = True
                    except (InvalidRequest, DecisionError, asyncio.TimeoutError):
                        confirmed = False
                    await websocket.send_json({
                        "type": "session_end_ack_receipt_ack",
                        "session_id": session_id,
                        "confirmed": confirmed,
                    })
                    continue

                if (
                    message.get("type") != "npc_state"
                    or not isinstance(request_id, str)
                    or not request_id.strip()
                    or not isinstance(npc, dict)
                ):
                    await websocket.send_json(
                        {
                            "type": "npc_action",
                            "request_id": request_id,
                            "npc_id": npc.get("npc_id") if isinstance(npc, dict) else None,
                            "action": "INVALID",
                            "reason": "invalid_request",
                        }
                    )
                    continue

                try:
                    canonical_session_id = str(UUID(session_id))
                except (ValueError, TypeError, AttributeError):
                    await websocket.send_json({
                        "type": "npc_action",
                        "request_id": request_id,
                        "npc_id": npc.get("npc_id"),
                        "action": "INVALID",
                        "reason": "invalid_request",
                    })
                    continue

                requested_architecture = message.get("architecture_name")
                if requested_architecture is not None and (
                    not isinstance(requested_architecture, str)
                    or not requested_architecture.strip()
                    or len(requested_architecture.strip()) > MAX_ARCHITECTURE_NAME_LENGTH
                ):
                    await websocket.send_json({
                        "type": "npc_action",
                        "request_id": request_id,
                        "npc_id": npc.get("npc_id"),
                        "action": "INVALID",
                        "reason": "invalid_architecture_selection",
                    })
                    continue
                if isinstance(requested_architecture, str):
                    requested_architecture = requested_architecture.strip()
                previous_architecture = app.state.session_architectures.get(canonical_session_id)
                if (
                    previous_architecture is not None
                    and requested_architecture is not None
                    and previous_architecture != requested_architecture
                ):
                    await websocket.send_json({
                        "type": "npc_action",
                        "request_id": request_id,
                        "npc_id": npc.get("npc_id"),
                        "action": "INVALID",
                        "reason": "architecture_locked_for_session",
                    })
                    continue
                selected_architecture = requested_architecture or previous_architecture

                try:
                    decision = await asyncio.wait_for(
                        asyncio.to_thread(
                            app.state.decision_service.decide,
                            session_id,
                            npc,
                            selected_architecture,
                        ),
                        timeout=1.5,
                    )
                except asyncio.TimeoutError:
                    logger.warning("MySQL decision exceeded the WebSocket response deadline")
                    decision = None
                    reason = "mysql_unavailable"
                except InvalidRequest as exc:
                    logger.info("Rejected invalid NPC state: %s", exc)
                    decision = None
                    reason = "invalid_request"
                except DecisionError as exc:
                    logger.warning("MySQL decision unavailable: %s", exc)
                    decision = None
                    reason = "mysql_unavailable"
                except Exception:
                    logger.exception("Unexpected error while requesting a MySQL decision")
                    decision = None
                    reason = "decision_error"

                if decision is None:
                    await websocket.send_json(
                        {
                            "type": "npc_action",
                            "request_id": request_id,
                            "npc_id": npc.get("npc_id"),
                            "action": "INVALID",
                            "reason": reason,
                        }
                    )
                    continue

                action = decision.get("action")
                run_id = decision.get("run_id")
                confidence = decision.get("confidence")
                if (
                    not isinstance(action, str)
                    or action not in VALID_ACTIONS
                    or isinstance(run_id, bool)
                    or not isinstance(run_id, int)
                    or run_id <= 0
                    or isinstance(confidence, bool)
                    or not isinstance(confidence, (int, float))
                    or not 0 <= confidence <= 1
                ):
                    await websocket.send_json(
                        {
                            "type": "npc_action",
                            "request_id": request_id,
                            "npc_id": npc.get("npc_id"),
                            "action": "INVALID",
                            "reason": "invalid_database_result",
                        }
                    )
                    continue

                effective_architecture = decision.get("architecture_name") or selected_architecture
                if effective_architecture is not None:
                    if (
                        canonical_session_id not in app.state.session_architectures
                        and len(app.state.session_architectures) >= MAX_TRACKED_METRIC_SESSIONS
                    ):
                        await websocket.send_json({
                            "type": "npc_action",
                            "request_id": request_id,
                            "npc_id": npc.get("npc_id"),
                            "action": "INVALID",
                            "reason": "session_architecture_limit_reached",
                        })
                        continue
                    app.state.session_architectures[canonical_session_id] = effective_architecture

                await websocket.send_json(
                    {
                        "type": "npc_action",
                        "request_id": request_id,
                        "npc_id": npc.get("npc_id"),
                        "action": action,
                        "run_id": run_id,
                        "confidence": confidence,
                        "architecture_name": effective_architecture,
                        "mysql_inference_ms": decision.get("mysql_inference_ms"),
                        "database_round_trip_ms": decision.get("database_round_trip_ms"),
                    }
                )
        except WebSocketDisconnect:
            logger.info("Frontend disconnected from the MySQL bridge")

    return app


app = create_app()
