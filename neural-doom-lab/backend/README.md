# Backend FastAPI ↔ MySQL

O serviço é uma ponte entre o cliente WebSocket do jogo e as procedures do MySQL. Não contém heurística de decisão neural nem código de treinamento. O mock de desenvolvimento fica no frontend e precisa ser selecionado explicitamente como `Local mock`.

## Configuração local

Na pasta `neural-doom-lab`, instale os pacotes:

```powershell
python -m pip install -r backend/requirements.txt
python -m pip install -r backend/requirements-test.txt
```

Copie `backend/.env.example` para `backend/.env` e configure a conexão do MySQL Server. O backend carrega esse arquivo ao iniciar. Não versione `.env` nem coloque credenciais nos comandos/commits.

O schema configurado precisa conter os scripts de `database/` e uma população inicial. A conta de aplicação pode receber `EXECUTE` somente nas procedures necessárias:

- `sp_nn_decide`
- `sp_nn_decide_for_architecture` (necessária apenas quando `NN_ARCHITECTURE_NAME` seleciona uma arquitetura experimental)
- `sp_nn_record_combat_event`
- `sp_nn_mark_session_v2`
- `sp_nn_finish_session_v2`

Depois de instalar os scripts base, execute `database/migrations/12_attack_provenance_v2.sql` uma vez em cada schema isolado (`neural_doom_local_sql_test_20261024` e `neural_doom_local_game_20261024`), selecionando o schema correspondente antes de abrir o script no Workbench. A migration recusa qualquer outro schema e cria somente tabelas/procedures novas; não precisa de `ALTER` e não reescreve sessões, avaliações nem fitness antigos. A conta da aplicação precisa de `EXECUTE` nas duas procedures v2.

O engine corrigido envia `attribution_version=neural_attack_provenance_v2`. O backend rejeita observações sem esse marcador, para que um bundle antigo não seja avaliado como se tivesse proveniência de ataque. O encerramento usa `sp_nn_finish_session_v2`; o ACK só é positivo depois que a avaliação v2 foi persistida. Resultados novos ficam em `nn_genome_evaluation_v2` e `nn_generation_summary_v2`, sem atualizar `nn_genome.fitness` ou os resumos legados.

Use uma conta de administração separada no MySQL Workbench para criar schema, população e novas gerações.

## Executar

Na raiz `neural-doom-lab`:

```powershell
python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
```

- Health check: `http://127.0.0.1:8000/health`
- WebSocket: `ws://127.0.0.1:8000/ws/ai`

O backend encaminha `npc_state` para `sp_nn_decide` ou `sp_nn_decide_for_architecture`, marca a sessão v2 após uma decisão SQL e encaminha `combat_event` para `sp_nn_record_combat_event`. `session_end` usa `sp_nn_finish_session_v2`. Procedures executam fora do event loop; decisões têm limite de 1,5 segundo. Erro de validação/MySQL, timeout ou saída inválida resulta em `INVALID`; o engine mantém `ORIGINAL_AI`.

Cada requisição `npc_state` tem `session_id` UUID e observação de NPC, incluindo `npc_id`, tipo, HP atual/máximo, distância, visibilidade e estado bruto para diagnóstico. Por padrão, o backend continua usando `sp_nn_decide` e a arquitetura `npc_teste_4_6_4`. Para um experimento, instale os scripts atualizados `04_genome_initialization.sql`, `07_genetic_evolution.sql`, `08_configurable_architectures.sql` e `09_training_experiments.sql`, depois reexecute `05_neural_inference.sql`; crie a arquitetura/experimento no MySQL e configure `NN_ARCHITECTURE_NAME` em `backend/.env`. O nome é enviado como parâmetro SQL, sem interpolação. O banco registra as quatro entradas normalizadas, todas as ativações e associa a sessão ao experimento. O ID de NPC do engine não é um ID de genoma.

## Testes

```powershell
python -m unittest discover -s backend -p "test_*.py" -v
```

Os testes unitários usam serviços/conexões de fixture; não substituem uma integração com MySQL nem uma partida. A suíte SQL reproduzível fica em `database/tests/` e deve ser executada em schema de teste separado. Não interprete eventos de fixtures como desempenho real.
