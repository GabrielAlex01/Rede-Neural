import asyncio
import logging
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

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


def create_app(service: DecisionService | None = None) -> FastAPI:
    app = FastAPI(title="Neural Doom Lab MySQL Bridge")
    app.state.decision_service = service or DatabaseDecisionService.from_environment()

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok", "decision_source": "mysql"}

    @app.websocket("/ws/ai")
    async def ai_bridge(websocket: WebSocket) -> None:
        await websocket.accept()

        try:
            while True:
                message = await websocket.receive_json()
                request_id = message.get("request_id") if isinstance(message, dict) else None
                npc = message.get("npc") if isinstance(message, dict) else None
                session_id = message.get("session_id") if isinstance(message, dict) else None

                if (
                    not isinstance(message, dict)
                    or message.get("type") != "npc_state"
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
