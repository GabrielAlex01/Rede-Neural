# Modelagem da rede neural no MySQL

O MySQL Server executa a inferência, registra o desempenho e evolui os genomas. MySQL Workbench é o cliente usado para instalar, consultar e administrar o schema; FastAPI não implementa a lógica neural nem o treinamento.

## Instalação segura no MySQL Workbench

Os arquivos `00_create_database.sql` e `tests/00_create_test_database.sql` são bootstraps de desenvolvimento com nomes fixos (`npc_neural_game` e `npc_neural_game_test`). Eles executam `CREATE DATABASE IF NOT EXISTS` e `USE` para esses nomes; **não os execute** ao instalar nos schemas locais já criados, pois podem selecionar bancos existentes com esses nomes.

Para este ambiente, use somente `neural_doom_local_game_20261024` e `neural_doom_local_sql_test_20261024`. Antes de instalar, confirme no Workbench que a conexão é o MySQL Server 8.0 na porta 3306, que ambos os nomes existem e que cada schema tem zero tabelas e zero rotinas. Não prossiga se algum nome estiver ausente ou contiver objetos.

Os oito arquivos de instalação abaixo não contêm `USE` nem nomes de schema qualificados; eles operam no schema padrão da aba SQL atual. Para **cada arquivo**, selecione o schema de destino no painel **SCHEMAS** do Workbench e execute `SELECT DATABASE();` na mesma aba. Só execute o arquivo quando o resultado for exatamente o schema esperado. Repita a conferência ao alternar entre jogo e testes.

No schema `neural_doom_local_game_20261024`, execute uma vez, nesta ordem:

1. `schema.sql`
2. `02_io_mapping.sql`
3. `03_seed_architecture.sql`
4. `04_genome_initialization.sql`
5. `05_neural_inference.sql`
6. `06_combat_telemetry.sql`
7. `07_genetic_evolution.sql`
8. `08_configurable_architectures.sql`

Crie a população inicial uma vez, por exemplo com 8 indivíduos:

```sql
CALL sp_nn_create_initial_population('npc_teste_4_6_4', 8);
```

A procedure exige ao menos dois indivíduos, valida topologia/mapeamentos/conexões, gera pesos e biases aleatórios em `[-1, 1]` e não sobrescreve genomas existentes. Pesos iniciais aleatórios não representam treinamento concluído.

No schema `neural_doom_local_sql_test_20261024`, instale os mesmos sete arquivos, na mesma ordem, mas **não crie população manualmente**. A suíte SQL cria os genomas e grava fixtures sintéticas nesse schema.

## Topologia e representação

`nn_architecture` → `nn_layer` → `nn_neuron` → `nn_synapse` define a estrutura. A MLP de referência `npc_teste_4_6_4` tem 4 neurônios de entrada, 6 ocultos (ReLU), 4 de saída (sigmoid), conexões completas entre camadas vizinhas (48 sinapses) e biases nos 10 neurônios não-input. `sp_nn_create_configurable_architecture(nome, JSON_ARRAY(...), ativação)` monta MLPs densas com 3–8 camadas, até 512 neurônios por camada e até 120000 pesos+biases. No engine atual, a primeira e a última largura precisam ser 4: existem somente quatro entradas reais mapeadas e quatro ações.

Exemplos para o schema de teste (use nomes únicos e crie uma população para cada topologia):

```sql
CALL sp_nn_create_configurable_architecture('npc_exp_4_32_4', JSON_ARRAY(4,32,4), 'relu');
CALL sp_nn_create_configurable_architecture('npc_exp_4_64_32_64_4', JSON_ARRAY(4,64,32,64,4), 'relu');
CALL sp_nn_create_configurable_architecture('npc_exp_4_128_64_128_4', JSON_ARRAY(4,128,64,128,4), 'relu');
CALL sp_nn_create_initial_population('npc_exp_4_64_32_64_4', 8);
```

`tests/06_configurable_architectures.sql` cobre também camadas de 256 e 512 neurônios, contagem de pesos/biases e forward pass profundo com pesos conhecidos. Entradas 12/16 ainda não são habilitadas: o jogo só envia `HEALTH_RATIO`, `PLAYER_DISTANCE_RATIO`, `PLAYER_VISIBLE` e `HEALTH_DELTA`. A ampliação depende de instrumentar e validar outras observações reais no engine; não use valores duplicados ou artificiais.

`nn_neuron_io` mapeia as entradas e saídas; o tipo da camada continua em `nn_layer.tipo`.

Entradas calculadas no SQL:

- `HEALTH_RATIO`: HP atual / HP máximo informado pelo engine, limitada a `[0, 1]`.
- `PLAYER_DISTANCE_RATIO`: distância aproximada em unidades do mapa / 2048, limitada a `[0, 1]`. O bridge converte `P_AproxDistance` de fixed-point.
- `PLAYER_VISIBLE`: resultado de `P_CheckSight`, representado como `0` ou `1`.
- `HEALTH_DELTA`: `(HP observado na decisão anterior - HP atual) / HP máximo`, limitada a `[-1, 1]`. Na primeira decisão daquele NPC naquela sessão, vale `0`.

`current_state` é o índice interno de `actor->state` em `states`. Ele não é contínuo e serve apenas para diagnóstico; não participa do forward pass. `HEALTH_DELTA` usa HP real observado, não estado simulado: cada nova decisão compara o HP atual com o último valor persistido em `nn_session_npc.last_health`. Dano ocorrido entre duas decisões é agregado nessa diferença. Um NPC morto não recebe novas decisões; o engine comunica `NPC_DEATH` uma vez. Cada partida recebe novo UUID de sessão e cada ator spawnado tem ID monotônico novo; assim a primeira amostra começa com delta zero e não herda o HP da partida anterior. Um reinício da página cria outro engine e sessão.

O estado de um mobj é associado ao seu genoma por `nn_engine_session` e `nn_session_npc`, usando `(session_id, engine_npc_id)` como chave. O ID do engine não é o ID MySQL do genoma. Uma sessão percorre a geração mais recente em ordem de fitness/ID e distribui os genomas pelos NPCs; se surgirem mais NPCs que indivíduos, a seleção dá a volta na população.

## Inferência em SQL

`sp_nn_decide_for_architecture` valida entrada, sessão e topologia, associa o NPC a um genoma, normaliza as quatro entradas e calcula cada camada oculta em ordem com expressões `CASE` SQL. Registra `nn_decision_run` e `nn_decision_activation` e retorna a ação de maior valor (`IDLE`, `CHASE`, `ATTACK` ou `FLEE`) e confiança. `sp_nn_decide` permanece como wrapper compatível para `npc_teste_4_6_4`. A expressão inline evita exigir o privilégio global `SUPER` ou alterar `log_bin_trust_function_creators` em servidores MySQL com binary logging habilitado. Cada run representa uma decisão solicitada pelo engine; somente a telemetria do engine comprova que ela foi aceita/aplicada.

Ativações, pesos e decisões podem ser consultados por `run_id`:

```sql
SELECT r.id, r.session_id, r.engine_npc_id, r.genome_id, r.action,
       r.confidence, a.neuron_id, a.valor
FROM nn_decision_run r
JOIN nn_decision_activation a ON a.run_id = r.id
ORDER BY r.id DESC, a.neuron_id;
```

## Engine, eventos e avaliação

O bridge C reproduzível está em `neural-doom-lab/engine/neural-ai-bridge.patch`, sobre o commit fixo de Chocolate Doom documentado em `neural-doom-lab/engine/README.md`. O código compilado chama o cliente WebSocket JavaScript, que encaminha observações ao FastAPI; o backend só valida e chama procedures MySQL. O engine só marca um NPC como controlado pela rede depois de aplicar uma ação externa válida. Se decisão atrasar, for inválida ou o serviço falhar, ele executa a IA original.

`p_inter.c` envia os eventos observados pelo engine:

- `PLAYER_DAMAGE`: dano aplicado ao jogador por NPC controlado pela rede.
- `PLAYER_KILL`: NPC controlado pela rede elimina o jogador.
- `NPC_DAMAGE`: dano efetivo recebido pelo NPC controlado.
- `NPC_DEATH`: morte do NPC controlado.

Eventos usam UUID idempotente, sessão e ID do NPC. O schema registra-os em `nn_combat_event`. `sp_nn_finish_session` fecha e avalia a sessão quando há NPCs registrados; sem NPC, apenas fecha. Cada combinação de sessão/genoma gera uma linha única em `nn_genome_evaluation`. Sobrevivência é calculada desde o registro do NPC até sua morte ou o fim da sessão.

Fitness atual:

```text
dano ao jogador + 100 × eliminações do jogador
- 0,25 × dano recebido - 50 × mortes do NPC
+ segundos de sobrevivência / 60
```

Esses coeficientes são uma função de pontuação inicial, não uma métrica científica calibrada. Uma avaliação só comprova os eventos efetivamente observados; desconexões podem deixar eventos sem persistência. Scripts de teste usam eventos sintéticos identificados como fixtures e não devem ser usados para alegar aprendizado.

`nn_generation_summary` mantém população, contagem avaliada e fitness médio/melhor/pior. Uma geração é completa se todos os genomas receberam pelo menos uma avaliação. Como cada sessão avalia apenas genomas atribuídos a NPCs que apareceram, repita sessões até a geração ficar completa.

## Evolução genética

`sp_nn_evolve_generation(nome_arquitetura, geração_origem, elite_count, mutation_rate)` exige ao menos duas elites e avaliação de todos os genomas da geração. Seleciona os melhores por fitness, cruza pesos/biases correspondentes e aplica mutações aleatórias limitadas a `[-1, 1]`; não sobrescreve uma geração filha existente. Exemplo após avaliação completa real da geração 0:

```sql
CALL sp_nn_evolve_generation('npc_teste_4_6_4', 0, 4, 0.05);
```

A geração filha só pode ser chamada de melhor depois de jogar partidas com seus próprios genomas e comparar avaliações. O engine usa a geração de número mais alto disponível, portanto não considere filhos recém-criados como treinados antes de avaliá-los.

Consultas de comparação:

```sql
SELECT n.nome, s.geracao, s.tamanho_populacao, s.individuos_avaliados,
       s.fitness_medio, s.melhor_fitness, s.pior_fitness, s.completa
FROM nn_generation_summary s
JOIN nn_architecture n ON n.id = s.architecture_id
WHERE n.nome = 'npc_teste_4_6_4'
ORDER BY s.geracao;

SELECT g.geracao, g.id AS genome_id, g.pai1_id, g.pai2_id,
       g.origem, g.fitness, COUNT(e.id) AS avaliacoes
FROM nn_genome g
LEFT JOIN nn_genome_evaluation e ON e.genome_id = g.id
WHERE g.architecture_id = (
    SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4'
)
GROUP BY g.geracao, g.id, g.pai1_id, g.pai2_id, g.origem, g.fitness
ORDER BY g.geracao, g.fitness DESC, g.id;
```

## Testes reproduzíveis

Com `neural_doom_local_sql_test_20261024` selecionado e confirmado por `SELECT DATABASE();`, execute uma vez, nesta ordem:

1. `tests/01_assert_architecture.sql`
2. `tests/02_genome_initialization.sql`
3. `tests/03_neural_inference.sql`
4. `tests/04_combat_telemetry.sql`
5. `tests/05_genetic_evolution.sql`

Não execute nenhum desses cinco arquivos no schema de jogo. Eles criam e removem procedures auxiliares de teste, ajustam pesos de fixtures e gravam sessões/eventos sintéticos; não removem tabelas ou schemas, mas alteram os dados do schema de teste. `02_genome_initialization.sql` cria quatro genomas. Os testes de inferência fixam pesos conhecidos; telemetria/evolução usam fixtures. Nenhum resultado é dado de uma partida real.

Os scripts de instalação também usam `DROP PROCEDURE/FUNCTION IF EXISTS` para substituir rotinas com os mesmos nomes no schema selecionado. Como os schemas locais foram confirmados vazios, esses comandos não encontram rotinas existentes. Não execute os scripts sobre schemas com dados. Para repetir a suíte, use outro schema de teste vazio já verificado; não apague nem reutilize schemas.
