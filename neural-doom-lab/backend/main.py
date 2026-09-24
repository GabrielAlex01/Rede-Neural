from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect


app = FastAPI(title="Doom Neural AI Mock Bridge")

VALID_ACTIONS = {"IDLE", "CHASE", "ATTACK", "FLEE"}


def choose_mock_action(npc: dict[str, Any]) -> str:
    """Small deterministic policy that can later be replaced by a model."""
    if npc.get("health", 100) <= 20:
        return "FLEE"

    if npc.get("player_visible") and npc.get("player_distance", 999999) <= 128:
        return "ATTACK"

    return "CHASE"


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.websocket("/ws/ai")
async def ai_bridge(websocket: WebSocket) -> None:
    await websocket.accept()

    try:
        while True:
            message = await websocket.receive_json()
            request_id = message.get("request_id")
            npc = message.get("npc")

            if message.get("type") != "npc_state" or not request_id or not isinstance(npc, dict):
                await websocket.send_json(
                    {
                        "type": "npc_action",
                        "request_id": request_id,
                        "npc_id": npc.get("npc_id") if isinstance(npc, dict) else None,
                        "action": "INVALID",
                    }
                )
                continue

            action = choose_mock_action(npc)
            assert action in VALID_ACTIONS

            print(
                f"NPC {npc.get('npc_id')} received: "
                f"state={npc.get('current_state')} -> action={action}",
                flush=True,
            )
            await websocket.send_json(
                {
                    "type": "npc_action",
                    "request_id": request_id,
                    "npc_id": npc.get("npc_id"),
                    "action": action,
                }
            )
    except WebSocketDisconnect:
        print("Frontend disconnected.", flush=True)
