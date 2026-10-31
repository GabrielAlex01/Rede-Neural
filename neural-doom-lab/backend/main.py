import asyncio
import logging
from pathlib import Path
from uuid import UUID

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect

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


def create_app(service: DecisionService | None = None) -> FastAPI:
    app = FastAPI(title="Neural Doom Lab MySQL Bridge")
    app.state.decision_service = service or DatabaseDecisionService.from_environment()
    app.state.action_metrics = {}

    @app.get("/health")
    async def health() -> dict[str, str]:
        check_database = getattr(app.state.decision_service, "check_health", None)
        if check_database is not None:
            try:
                await asyncio.wait_for(asyncio.to_thread(check_database), timeout=4.0)
            except (DecisionError, asyncio.TimeoutError):
                raise HTTPException(status_code=503, detail="mysql_unavailable") from None
        return {"status": "ok", "decision_source": "mysql"}

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
                    decision = await asyncio.wait_for(
                        asyncio.to_thread(
                            app.state.decision_service.decide,
                            session_id,
                            npc,
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

                await websocket.send_json(
                    {
                        "type": "npc_action",
                        "request_id": request_id,
                        "npc_id": npc.get("npc_id"),
                        "action": action,
                        "run_id": run_id,
                        "confidence": confidence,
                    }
                )
        except WebSocketDisconnect:
            logger.info("Frontend disconnected from the MySQL bridge")

    return app


app = create_app()
