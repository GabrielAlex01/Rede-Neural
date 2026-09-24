# Mock AI backend

Minimal FastAPI WebSocket service for the browser AI bridge.

## Run

```powershell
python -m pip install -r backend/requirements.txt
python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
```

The WebSocket endpoint is `ws://127.0.0.1:8000/ws/ai`. A health check is
available at `http://127.0.0.1:8000/health`.

## Request

```json
{
  "type": "npc_state",
  "request_id": "3052044-1720000000000-1",
  "npc": {
    "npc_id": 3052044,
    "npc_type": 12,
    "health": 150,
    "position": { "x": 128, "y": 256 },
    "angle": 1073741824,
    "player_distance": 3010,
    "player_visible": true,
    "current_state": 482
  }
}
```

## Response

```json
{
  "type": "npc_action",
  "request_id": "3052044-1720000000000-1",
  "npc_id": 3052044,
  "action": "CHASE"
}
```

Valid actions are `IDLE`, `CHASE`, `ATTACK`, and `FLEE`. Missing, invalid,
late, or unavailable responses cause the game to continue with `ORIGINAL_AI`.
