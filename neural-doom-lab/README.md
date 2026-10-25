# Neural Doom Lab

Freedoom 2 no navegador com NPCs que recebem decisões calculadas por uma MLP no MySQL. O FastAPI faz a ponte WebSocket; não escolhe ações nem executa treinamento. O modo `Local mock` existe somente para desenvolvimento. Os pesos iniciais são aleatórios e só há avaliação de desempenho depois de uma partida com eventos reais.

## Estrutura

- `frontend/`: interface, cliente WebSocket e Chocolate Doom/WebAssembly.
- `backend/`: serviço FastAPI e conexão com MySQL.
- `engine/`: patch do bridge C e script para recompilar o engine.
- `licenses/`: licenças e avisos de terceiros.
- `LICENSE`: licença do projeto.

## Requisitos

- Windows 10/11, MySQL Server 8.0+ e MySQL Workbench 8.0+.
- Python 3.10+ e Node.js/npm.
- O bundle inclui Freedoom 2. Não use nem distribua IWADs proprietários.

## Banco pelo MySQL Workbench

Abra uma conexão local ao MySQL Server. O Workbench é o cliente de administração; o servidor MySQL é quem executa as procedures e a rede neural.

1. Abra e execute `database/00_create_database.sql` na raiz do repositório.
2. Selecione o schema `npc_neural_game` no painel **SCHEMAS**.
3. Execute, nessa ordem, `database/schema.sql`, `database/02_io_mapping.sql`, `database/03_seed_architecture.sql`, `database/04_genome_initialization.sql`, `database/05_neural_inference.sql`, `database/06_combat_telemetry.sql` e `database/07_genetic_evolution.sql`.
4. Crie a população inicial uma única vez. Por exemplo, 8 genomas:

   ```sql
   CALL sp_nn_create_initial_population('npc_teste_4_6_4', 8);
   ```

   A procedure não sobrescreve uma população existente. Não execute scripts de teste no schema de produção.

Para uma instalação de teste isolada, execute `database/tests/00_create_test_database.sql`, selecione `npc_neural_game_test` e instale nele os mesmos scripts do passo 3. Rode os testes, na ordem: `01_assert_architecture.sql`, `02_genome_initialization.sql`, `03_neural_inference.sql`, `04_combat_telemetry.sql` e `05_genetic_evolution.sql`. Os testes de telemetria e evolução inserem fixtures sintéticas apenas no schema de teste; esses valores não são resultados de jogo. Os scripts não removem schemas nem dados automaticamente. Para repetir a suíte, use outro schema de teste vazio.

## Configurar e iniciar

Instale as dependências:

```powershell
cd neural-doom-lab
python -m pip install -r backend/requirements.txt
python -m pip install -r backend/requirements-test.txt
cd frontend
npm install
```

Crie `backend/.env` a partir de `backend/.env.example` e preencha as credenciais locais. Não versione esse arquivo. O exemplo usa `npc_neural_game`; para outra instância, ajuste host, porta e schema. O usuário do backend precisa executar `sp_nn_decide`, `sp_nn_record_combat_event` e `sp_nn_finish_session`. Prefira uma conta local dedicada com apenas essas permissões; use outra conta administrativa no Workbench para instalar scripts, inicializar populações e evoluir gerações.

Terminal 1, na pasta `neural-doom-lab`:

```powershell
python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
```

Terminal 2:

```powershell
cd neural-doom-lab/frontend
npm run dev
```

Abra a URL local impressa pelo Vite. A verificação HTTP do backend fica em `http://127.0.0.1:8000/health`.

## Jogar contra os NPCs

1. Confirme que o MySQL está ativo, que a população foi criada e que o backend iniciou sem erro.
2. Na página, selecione **Modo de operação: `EXTERNAL_AI`** e **Fonte de decisão: `MySQL neural (via backend)`**. `Local mock` não consulta o banco.
3. Clique em **Play** e, no menu do Freedoom, inicie a partida. O indicador de conexão deve mostrar `Connected`.
4. Controles exibidos pela interface: mover com WASD/setas, atirar com Ctrl, usar/abrir com Espaço, correr com Shift. Fullscreen e pointer look são opcionais.
5. Se o backend ou o MySQL estiver indisponível, a decisão externa é rejeitada e o NPC permanece na IA original. A resposta precisa chegar dentro do limite de 1,5 s; decisões ausentes/atrasadas usam fallback.
6. Ao terminar, selecione `ORIGINAL_AI` para encerrar e avaliar a sessão. O fechamento automático ao sair da página é uma tentativa adicional; trocar para `ORIGINAL_AI` com WebSocket conectado é o caminho confiável para aguardar o envio.

O jogo não garante que todos os genomas da população apareçam em cada mapa. A sessão atribui genomas em ordem por NPC; `nn_generation_summary.completa` indica se a geração inteira tem avaliações. Uma rede aleatória pode agir mal e não deve ser apresentada como já treinada.

## Consultar inferência e combate

Execute no Workbench, dentro de `npc_neural_game`:

```sql
SELECT r.id AS run_id, r.criado_em, s.session_id, s.engine_npc_id,
       s.genome_id, r.health, r.max_health, r.player_distance,
       r.player_visible, r.health_ratio, r.player_distance_ratio,
       r.health_delta, r.action, r.confidence
FROM nn_decision_run r
JOIN nn_session_npc s
  ON s.session_id = r.session_id AND s.engine_npc_id = r.engine_npc_id
ORDER BY r.id DESC LIMIT 50;

SELECT e.session_id, e.genome_id, e.damage_to_player, e.player_kills,
       e.damage_received, e.npc_deaths, e.survival_seconds, e.fitness
FROM nn_genome_evaluation e
ORDER BY e.avaliado_em DESC, e.genome_id;

SELECT a.geracao, a.tamanho_populacao, a.individuos_avaliados,
       a.fitness_medio, a.melhor_fitness, a.pior_fitness, a.completa
FROM nn_generation_summary a
JOIN nn_architecture n ON n.id = a.architecture_id
WHERE n.nome = 'npc_teste_4_6_4'
ORDER BY a.geracao;
```

As ativações de uma decisão ficam em `nn_decision_activation` (ligadas por `run_id`). Os eventos são `PLAYER_DAMAGE`, `PLAYER_KILL`, `NPC_DAMAGE` e `NPC_DEATH`, enviados pelo engine somente para NPCs que receberam e aplicaram uma ação externa válida. A fórmula atual é `dano ao jogador + 100 × abates - 0,25 × dano recebido - 50 × mortes do NPC + segundos de sobrevivência / 60`.

## Evoluir uma geração

Depois de partidas reais suficientes para avaliar cada genoma da geração, confira `nn_generation_summary.completa = 1`. Então, por exemplo, evolua a geração 0 preservando a elite de 4 indivíduos e usando taxa de mutação de 5%:

```sql
CALL sp_nn_evolve_generation('npc_teste_4_6_4', 0, 4, 0.05);
```

A procedure recusa gerações com indivíduos sem avaliação real e não substitui uma geração que já existe. Os pesos/biases filhos usam crossover e mutação limitados a `[-1, 1]`. O engine seleciona a geração de maior número; avalie os descendentes em jogo antes de afirmar que a nova geração melhorou. Compare fitness médio/melhor/pior e tamanho/indivíduos avaliados no resumo. Um único resultado ou uma diferença de pesos não prova evolução.

## Testes e builds

Backend:

```powershell
cd neural-doom-lab
python -m unittest discover -s backend -p "test_*.py" -v
```

Frontend:

```powershell
cd neural-doom-lab/frontend
npm run build
```

O build web gera `frontend/dist/` localmente; não o versione. Para recompilar o bridge C/WASM, consulte [`engine/README.md`](engine/README.md). Um build bem-sucedido não substitui validação de partida real.

## Arquitetura e limites conhecidos

`HEALTH_RATIO`, `PLAYER_DISTANCE_RATIO`, `PLAYER_VISIBLE` e `HEALTH_DELTA` são as quatro entradas. O índice interno do estado do DOOM é guardado para diagnóstico, não tratado como medida contínua. O MySQL executa forward propagation e escolhe a maior saída entre `IDLE`, `CHASE`, `ATTACK` e `FLEE`; o FastAPI apenas valida, chama procedures e devolve a ação. Para os detalhes do schema e das procedures, veja [`../database/modelagem.md`](../database/modelagem.md).

Os genomas começam aleatórios; não existe backpropagation nem aprendizado supervisionado. A evolução usa fitness de eventos reais no SQL. A jogabilidade completa, incluindo movimento, combate, modo multi-NPC e fallback durante uma partida, ainda deve ser confirmada manualmente no ambiente de apresentação.
