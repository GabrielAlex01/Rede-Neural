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

O Workbench administra o servidor; é o MySQL Server que executa as procedures e a rede neural. No Windows, use a conexão local já configurada para o serviço `MySQL80` (`127.0.0.1`, porta `3306`). Confira no editor do Workbench, sem alterar conexões ou credenciais salvas:

```sql
SELECT VERSION() AS mysql_version, @@port AS mysql_port;
```

Não use a instância `MySQL84` na porta `3307` para esta configuração. Os nomes dos dois bootstraps existentes são fixos: `database/00_create_database.sql` seleciona `npc_neural_game`, e `database/tests/00_create_test_database.sql` seleciona `npc_neural_game_test`. Para preservar qualquer schema existente, **não execute esses dois arquivos**. Crie schemas locais novos e exclusivos pelo Workbench.

Primeiro verifique que os nomes escolhidos ainda não existem. Se qualquer consulta retornar linha, não reutilize aquele schema: escolha um nome novo. Exemplo para esta configuração:

```sql
SELECT SCHEMA_NAME
FROM INFORMATION_SCHEMA.SCHEMATA
WHERE SCHEMA_NAME IN (
    'neural_doom_local_game_20261024',
    'neural_doom_local_sql_test_20261024'
);
```

Somente se o resultado estiver vazio, crie os dois schemas:

```sql
CREATE DATABASE `neural_doom_local_game_20261024`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE `neural_doom_local_sql_test_20261024`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```

No Workbench, defina `neural_doom_local_game_20261024` como schema padrão e execute uma vez, nesta ordem, os arquivos da raiz do repositório: `database/schema.sql`, `database/02_io_mapping.sql`, `database/03_seed_architecture.sql`, `database/04_genome_initialization.sql`, `database/05_neural_inference.sql`, `database/06_combat_telemetry.sql` e `database/07_genetic_evolution.sql`. Em seguida, crie a população inicial uma única vez, por exemplo:

```sql
CALL sp_nn_create_initial_population('npc_teste_4_6_4', 8);
```

Para os testes SQL, selecione `neural_doom_local_sql_test_20261024`, instale nele os mesmos sete arquivos, mas **não crie população antes da suíte**. Execute `database/tests/01_assert_architecture.sql`, `02_genome_initialization.sql`, `03_neural_inference.sql`, `04_combat_telemetry.sql` e `05_genetic_evolution.sql`, nessa ordem. Essa suíte grava fixtures e avaliações sintéticas; ela nunca deve rodar no schema de jogo. Para repeti-la, crie e selecione outro schema novo e vazio; não apague nem reutilize schemas existentes.

Crie uma conta de aplicação local pelo painel **Administration → Users and Privileges** do Workbench, com uma senha escolhida localmente, host `127.0.0.1` e permissão `EXECUTE` somente no schema de jogo acima. Não compartilhe a senha nem coloque-a em comandos, logs ou commits. A conta administrativa usada para instalar e evoluir o banco deve permanecer separada da conta do backend.

## Configurar e iniciar

Instale as dependências:

```powershell
cd neural-doom-lab
python -m pip install -r backend/requirements.txt
python -m pip install -r backend/requirements-test.txt
cd frontend
npm install
```

Preencha `backend/.env` com a conta de aplicação criada no Workbench. O arquivo local já tem host `127.0.0.1`, porta `3306` e o nome do schema de jogo ilustrativo; informe o usuário e a senha somente no arquivo local, que é ignorado pelo Git. Não copie credenciais do Workbench nem as envie no chat. A conta do backend precisa executar `sp_nn_decide`, `sp_nn_record_combat_event` e `sp_nn_finish_session`.

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
7. O painel **NPC atual → Resumo da sessão** distingue saídas SQL selecionadas, ações entregues ao engine, aplicadas, rejeitadas e oportunidades em que ocorreu fallback. O backend recebe snapshots cumulativos e devolve a contagem no ACK de encerramento; o resumo também é escrito no terminal do backend. `ATTACK` selecionada não significa ataque executado: somente o contador **aplicadas** confirma que o engine aceitou a ação; dano real continua sendo confirmado pelos eventos de combate SQL.

O jogo não garante que todos os genomas da população apareçam em cada mapa. A sessão atribui genomas em ordem por NPC; `nn_generation_summary.completa` indica se a geração inteira tem avaliações. Uma rede aleatória pode agir mal e não deve ser apresentada como já treinada.

## Consultar inferência e combate

Execute no Workbench, depois de selecionar o schema local isolado (exemplo: `neural_doom_local_game_20261024`):

```sql
SELECT r.id AS run_id, r.criado_em, s.session_id, s.engine_npc_id,
       s.genome_id, r.health, r.max_health, r.player_distance,
       r.player_visible, r.health_ratio, r.player_distance_ratio,
       r.health_delta, r.action, r.confidence
FROM nn_decision_run r
JOIN nn_session_npc s
  ON s.session_id = r.session_id AND s.engine_npc_id = r.engine_npc_id
ORDER BY r.id DESC LIMIT 50;

SELECT r.session_id, r.engine_npc_id, r.action, COUNT(*) AS decisoes_sql,
       MIN(r.confidence) AS confianca_minima, MAX(r.confidence) AS confianca_maxima
FROM nn_decision_run r
GROUP BY r.session_id, r.engine_npc_id, r.action
ORDER BY MAX(r.id) DESC LIMIT 100;

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

As ativações de uma decisão ficam em `nn_decision_activation` (ligadas por `run_id`). Os eventos `PLAYER_DAMAGE`, `PLAYER_KILL`, `NPC_DAMAGE` e `NPC_DEATH` são telemetria de combate real do engine para NPCs neural-controlados; eles comprovam efeitos reais, mas não são uma associação causal a uma decisão `ATTACK` específica. O painel/ACK do backend distingue seleção SQL, entrega, aplicação, rejeição e fallback. A fórmula atual é `dano ao jogador + 100 × abates - 0,25 × dano recebido - 50 × mortes do NPC + segundos de sobrevivência / 60`.

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
