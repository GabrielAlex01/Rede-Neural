# Backend FastAPI ↔ MySQL

O serviço é uma ponte entre o cliente WebSocket do jogo e as procedures do MySQL. Não contém heurística de decisão neural nem código de treinamento. O mock de desenvolvimento fica no frontend e precisa ser selecionado explicitamente como `Local mock`.

## Configuração local

Na pasta `neural-doom-lab`, instale os pacotes:

```powershell
python -m pip install -r backend/requirements.txt
python -m pip install -r backend/requirements-test.txt
```

Copie `backend/.env.example` para `backend/.env` e configure a conexão do MySQL Server. O backend carrega esse arquivo ao iniciar. Não versione `.env` nem coloque credenciais nos comandos/commits.

O schema configurado precisa conter os scripts de `database/` e uma população inicial. A conta de aplicação pode receber `EXECUTE` somente nestas procedures:

- `sp_nn_decide`
- `sp_nn_record_combat_event`
- `sp_nn_finish_session`

Use uma conta de administração separada no MySQL Workbench para criar schema, população e novas gerações.

## Executar

Na raiz `neural-doom-lab`:

```powershell
python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
```

- Health check: `http://127.0.0.1:8000/health`
- WebSocket: `ws://127.0.0.1:8000/ws/ai`

O backend encaminha `npc_state` para `sp_nn_decide`, `combat_event` para `sp_nn_record_combat_event` e `session_end` para `sp_nn_finish_session`. Procedures executam fora do event loop; decisões têm limite de 1,5 segundo. Erro de validação/MySQL, timeout ou saída inválida resulta em `INVALID`; o engine mantém `ORIGINAL_AI`.

Cada requisição `npc_state` tem `session_id` UUID e observação de NPC, incluindo `npc_id`, tipo, HP atual/máximo, distância, visibilidade e estado bruto para diagnóstico. O banco registra as quatro entradas normalizadas e todas as ativações. O ID de NPC do engine não é um ID de genoma.

## Testes

```powershell
python -m unittest discover -s backend -p "test_*.py" -v
```

Os testes unitários usam serviços/conexões de fixture; não substituem uma integração com MySQL nem uma partida. A suíte SQL reproduzível fica em `database/tests/` e deve ser executada em schema de teste separado. Não interprete eventos de fixtures como desempenho real.
