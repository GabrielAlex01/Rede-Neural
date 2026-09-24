# Neural Doom Lab

O Neural Doom Lab executa Freedoom 2 no navegador e permite que decisões dos NPCs sejam fornecidas por um serviço externo via WebSocket. O projeto não inclui dados proprietários do DOOM.

## 1. Estrutura

```text
neural-doom-lab/
├── frontend/
├── backend/
├── licenses/
├── LICENSE
└── README.md
```

- `frontend/`: jogo no navegador, interface e cliente WebSocket. O engine WebAssembly já compilado está em `frontend/public/engine/`.
- `backend/`: servidor FastAPI mock que futuramente receberá a rede neural.
- `licenses/`: licenças e avisos dos componentes de terceiros.

## 2. Requisitos

- Node.js
- npm
- Python 3
- pip

## 3. Instalação do frontend

Partindo da pasta `neural-doom-lab`:

```powershell
cd frontend
npm install
```

Normalmente, `npm install` só precisa ser executado novamente quando as dependências do frontend mudarem.

## 4. Instalação do backend

Partindo da raiz `neural-doom-lab`:

```powershell
python -m pip install -r backend/requirements.txt
```

## 5. Como executar

Use dois terminais.

### Terminal 1 — Backend

Na raiz `neural-doom-lab`:

```powershell
python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
```

### Terminal 2 — Frontend

```powershell
cd frontend
npm run dev
```

Abra no navegador a URL exibida pelo Vite.

## 6. Uso

1. Inicie o backend.
2. Inicie o frontend.
3. Abra a URL exibida pelo Vite.
4. Clique em **Play**.
5. Selecione `EXTERNAL_AI` em **Controle da IA**.
6. Mantenha `WebSocket backend (mock)` como fonte de decisão.
7. Verifique se **Conexão** mostra `Connected` e se o painel do NPC passa a exibir as decisões recebidas.

## 7. Próximas execuções

Depois que as dependências estiverem instaladas, normalmente bastam estes comandos.

Backend, partindo da raiz:

```powershell
python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
```

Frontend:

```powershell
cd frontend
npm run dev
```

## 8. WebSocket

Endpoint utilizado pelo frontend:

```text
ws://127.0.0.1:8000/ws/ai
```

Fluxo atual:

```text
Freedoom/WASM
→ frontend
→ WebSocket
→ backend
→ decisão
→ frontend
→ NPC
```

## 9. Contrato atual

O frontend envia uma mensagem `npc_state`:

```json
{
  "type": "npc_state",
  "request_id": "...",
  "npc": {
    "npc_id": 3052044,
    "npc_type": 12,
    "health": 150,
    "position": {
      "x": 128,
      "y": 256
    },
    "angle": 1073741824,
    "player_distance": 3010,
    "player_visible": true,
    "current_state": 482
  }
}
```

O backend responde com uma mensagem `npc_action`:

```json
{
  "type": "npc_action",
  "request_id": "...",
  "npc_id": 3052044,
  "action": "CHASE"
}
```

Ações aceitas:

- `IDLE`
- `CHASE`
- `ATTACK`
- `FLEE`

Respostas ausentes, atrasadas ou inválidas fazem o frontend retornar ao `ORIGINAL_AI` para aquela decisão.

## 10. Integração com a rede neural

O backend atual é apenas um mock. A lógica que deve ser substituída pelos colegas está em:

```text
backend/main.py
```

Função atual:

```python
choose_mock_action(npc)
```

A função recebe o dicionário com o estado do NPC e retorna uma das ações aceitas. A futura implementação deve substituir apenas essa decisão, preservando o endpoint `/ws/ai` e o formato das mensagens.

Fluxo futuro:

```text
estado do NPC
→ rede neural
→ ação
→ resposta WebSocket
```

Não é necessário alterar o navegador para conectar a rede neural se o backend continuar respeitando o contrato atual.

## 11. Fallback

- `EXTERNAL_AI` com o backend online: usa a decisão externa válida.
- Backend offline ou resposta inválida: usa `ORIGINAL_AI` como fallback.
- Interromper o backend com `Ctrl+C` não derruba o jogo; ele continua utilizando a IA original.

## Build de produção

Dentro de `frontend/`:

```powershell
npm run build
```

O resultado é criado em `frontend/dist/` e não deve ser versionado.

## Licenças

Consulte `LICENSE` e a pasta `licenses/` para as licenças do projeto, Chocolate Doom, Freedoom, Emscripten e SDL2.
