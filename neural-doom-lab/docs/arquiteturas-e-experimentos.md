# Arquiteturas e experimentos reproduzíveis

Esta página distingue quatro coisas que não devem ser confundidas: capacidade do código SQL, arquiteturas criadas numa instalação nova, genomas disponíveis e partidas reais. Os dados do schema de testes são fixtures; não são populações de jogo nem evidência de comportamento ou aprendizado.

## O que a implementação suporta

`sp_nn_create_configurable_architecture` aceita topologias densas com 3 a 8 camadas, 1 a 512 neurônios em cada camada, exatamente 4 entradas e 4 saídas e até 120.000 parâmetros treináveis (pesos e biases). As quatro entradas reais do engine são `HEALTH_RATIO`, `PLAYER_DISTANCE_RATIO`, `PLAYER_VISIBLE` e `HEALTH_DELTA`; as saídas são `IDLE`, `CHASE`, `ATTACK` e `FLEE`. A ativação oculta configurável é `sigmoid`, `relu` ou `tanh`. Isso é capacidade geral da implementação; não significa que toda topologia possível tenha sido jogada ou tenha latência adequada.

## As sete topologias dos experimentos

Os parâmetros abaixo contam pesos e biases. “Instalação limpa” descreve os registros e populações criados automaticamente pelo instalador portátil atual. A instalação cria cinco **nomes** de arquitetura, mas só quatro topologias distintas: `npc_teste_4_6_4` e `genetic_v2_ref46_20261031` são duas arquiteturas independentes de mesma forma.

| Topologia | Parâmetros | Instalação limpa | Partidas automatizadas e resultados observados | Evolução genética |
|---|---:|---|---|---|
| `4 → 6 → 4` | 58 | Sim: demo `npc_teste_4_6_4` (8 genomas) e referência v2 `genetic_v2_ref46_20261031` (8 genomas iniciais) | Sim, no Freedoom/Edge headless. Na referência v2, fitness médio G0 `-9,5510` e G1 `-12,1563`; ações e combate variaram entre sessões. | Legada G0→G1 e v2 G0→G1 concluídas. A média v2 caiu; não comprova aprendizado. |
| `4 → 32 → 4` | 292 | Sim: `genetic_v2_h32_20261031` (8 genomas iniciais) | Sim. Duas sessões direcionadas G1 selecionaram `ATTACK` sem visibilidade; todas as ofertas ATTACK foram rejeitadas e não houve dano ao jogador nessas duas sessões. | Legada G0→G1 e v2 G0→G1 concluídas. A média v2 foi de `-18,5875` para `0,0729`, mas só houve duas avaliações por genoma e condições do jogo não pareadas. |
| `4 → 64 → 4` | 580 | Sim: `genetic_v2_h64_20261031` (8 genomas iniciais) | Sim. Quatro sessões G1, 2.505 decisões SQL, todas `FLEE`; nenhum `ATTACK`. É uma limitação observada, não conclusão para toda nova partida. | Legada G0→G1 e v2 G0→G1 concluídas. A média v2 caiu de `-15,2250` para `-29,6084`; não comprova aprendizado. |
| `4 → 64 → 32 → 64 → 4` | 4.772 | Sim: `genetic_v2_deep6464_20261031` (8 genomas iniciais) | Sim com o alias legado G1: duas partidas headless registraram 49 de dano ao jogador no total e nenhuma morte de NPC; RTT médio/P95 foi `73,5/108,2 ms` e `337,0/676,2 ms`. | Legada G0→G1 concluída. No experimento v2, G0 segue `EVALUATING` e a leitura atual do schema mostra zero avaliações persistidas; não houve evolução v2. |
| `4 → 128 → 64 → 128 → 4` | 17.732 | Não. É criada pelo seed opcional abaixo. | Sim, apenas uma avaliação real por genoma em G0, interrompida por latência. Média/P95 observados: `952,9/1.375,3 ms`; fallback `22,83%`; nenhuma oferta ATTACK aplicada na rodada documentada. | Não evoluída; a cobertura planejada de duas avaliações por genoma não foi atingida. |
| `4 → 256 → 128 → 64 → 4` | 42.692 | Não. É criada pelo seed opcional abaixo. | Sim, apenas uma avaliação real por genoma em G0, interrompida por latência. Média/P95: `2.084,5/3.552,4 ms`; fallback `72,50%`. Foram observadas 19 ofertas ATTACK aplicadas no conjunto documentado. | Não evoluída; a cobertura planejada não foi atingida. Latência impede recomendá-la para jogo normal nesta máquina. |
| `4 → 512 → 4` | 4.612 | Não. É criada pelo seed opcional abaixo. | Sim. A rodada original teve média de `325,2 ms`, P95 entre `427,1–700,5 ms` e fallback `4,22%`; uma partida posterior teve RTT médio/P95 de `2.224/4.118 ms`, fallback `66,6%`, 12 ofertas ATTACK aceitas, 48 de dano e uma eliminação. A latência é variável. | Evolução legada G0→G1 concluída uma vez. Não foi incluída na evolução v2. Não é recomendação de arquitetura. |

As partidas citadas foram automatizadas em Edge headless, Freedoom 2 MAP01/skill 2, com controles fixos. Relatórios anteriores chamavam este mapa de E1M1; a configuração do engine registra `startmap: 1` e `startepisode: 1` com o IWAD Freedoom 2, portanto a designação correta é MAP01. Os rótulos foram corrigidos sem alterar métricas. Não foram partidas humanas e não fixam o RNG interno do Freedoom. A atribuição/fitness das avaliações legadas ocorreu antes da correção de proveniência e deve ser tratada como histórica; não a use para afirmar aprendizado. Os valores v2 são de avaliações reais com ACK confirmado, mas as amostras são pequenas e não pareadas. O único aumento de média observado em H32 não é evidência suficiente de melhora genética. Ver também [`experimentos-2026-10-25.md`](experimentos-2026-10-25.md), [`experimentos-geneticos-v2-2026-10-31.md`](experimentos-geneticos-v2-2026-10-31.md) e [`avaliacao-proveniencia-v2-2026-10-31.md`](avaliacao-proveniencia-v2-2026-10-31.md).

## O que uma instalação nova prepara

O instalador portátil aplica quatro experimentos v2 e uma população demo. Por isso aparecem cinco nomes de arquitetura: demo 4→6→4, referência v2 4→6→4, H32, H64 e profunda 64→32→64. Os aliases legados `auto_20261025_*` das sete topologias são mantidos fora do fluxo padrão para não acrescentar, sem opção explícita, as populações e os pesos dos experimentos históricos.

O schema de jogo local consultado em MySQL 8.0.46 tinha 12 nomes de arquitetura, cobrindo as sete topologias: os oito aliases demo/legados e quatro aliases v2. Havia 112 genomas no total. Nos aliases legados, as populações eram de quatro genomas por geração; 128 e 256 tinham só G0, com uma avaliação real por genoma e sem evolução. Em v2, referência/H32/H64 tinham 8 membros em G0 e 8 em G1; a profunda tinha 8 em G0. Essa é a fotografia do schema local consultado, não o conteúdo garantido de todo clone novo.

Para criar de forma opcional os aliases e populações históricas de **todas as sete** arquiteturas, sem tocar nos aliases/genomas v2, execute uma vez `neural-doom-lab/database/core/11_prepare_autonomous_architecture_experiments.sql` a partir da raiz do clone. Ele usa as seeds `2026102501`–`2026102507`, população 4, ReLU, mutação 5%, duas gerações planejadas e duas avaliações por genoma. A procedure verifica a configuração; uma repetição exata não duplica nem sobrescreve arquiteturas, experimentos ou genomas, e nomes/topologias conflitantes falham. O arquivo recria sua própria procedure auxiliar `sp_nn_prepare_autonomous_experiment_20261025`. As arquiteturas 128 e 256 têm mais pesos e podem tornar a criação mais demorada.

PowerShell, da raiz do repositório de trabalho:

```powershell
Get-Content -Raw neural-doom-lab/database/core/11_prepare_autonomous_architecture_experiments.sql |
  & "$env:ProgramFiles\MySQL\MySQL Server 8.0\bin\mysql.exe" `
    --login-path=neural-doom-installer-20261024 `
    --protocol=TCP --host=127.0.0.1 --port=3306 `
    --database=neural_doom_local_game_20261024 --batch --raw
```

O script contém `USE neural_doom_local_game_20261024` e guarda explícita para esse schema. Ele só prepara o banco de jogo; não cria schemas, não roda partidas, não evolui uma geração e não deve ser usado no schema de testes. Confira a instância e `SELECT DATABASE()` antes. Não execute `database/00_create_database.sql` nem `database/tests/00_create_test_database.sql` para esta instalação: são bootstraps antigos que criam/selecionam `npc_neural_game` e `npc_neural_game_test`, fora dos dois schemas Neural Doom. As migrations 12–16 aceitam somente `neural_doom_local_game_20261024` ou `neural_doom_local_sql_test_20261024`; o instalador escolhe explicitamente o destino e registra o checksum de cada etapa.

## Selecionar uma arquitetura para os NPCs

O backend usa a variável `NN_ARCHITECTURE_NAME` como nome SQL parametrizado. O nome precisa existir e ter uma população/genomas compatíveis. Após instalar o seed opcional, qualquer um destes aliases seleciona a topologia da tabela:

| Topologia | Alias legado opcional |
|---|---|
| `4 → 6 → 4` | `auto_20261025_ref46` |
| `4 → 32 → 4` | `auto_20261025_h32` |
| `4 → 64 → 4` | `auto_20261025_h64` |
| `4 → 64 → 32 → 64 → 4` | `auto_20261025_deep6464` |
| `4 → 128 → 64 → 128 → 4` | `auto_20261025_deep12864128` |
| `4 → 256 → 128 → 64 → 4` | `auto_20261025_deep25612864` |
| `4 → 512 → 4` | `auto_20261025_h512` |

No Windows, altere apenas `NN_ARCHITECTURE_NAME` em `neural-doom-lab/backend/.env` para o alias desejado e reinicie o backend. Os aliases `genetic_v2_ref46_20261031`, `genetic_v2_h32_20261031`, `genetic_v2_h64_20261031` e `genetic_v2_deep6464_20261031` também podem ser selecionados; eles pertencem aos experimentos v2 instalados por padrão. Não renomeie nem copie genomas entre arquiteturas. A configuração do jogo fica local e ignorada pelo Git.

## Consultas somente de leitura no MySQL Workbench

Conecte a `127.0.0.1:3306`, selecione `neural_doom_local_game_20261024` e confira antes:

```sql
SELECT VERSION() AS mysql_version, @@port AS mysql_port, DATABASE() AS schema_name;
```

Arquiteturas e número de neurônios por camada (o `GROUP BY` evita multiplicar camadas/neurônios):

```sql
SELECT a.id, a.nome,
       GROUP_CONCAT(layer_size.neurons ORDER BY l.ordem SEPARATOR ' -> ') AS topologia,
       (SELECT COUNT(*) FROM nn_genome g WHERE g.architecture_id = a.id) AS genomas
FROM nn_architecture a
JOIN nn_layer l ON l.architecture_id = a.id
JOIN (
    SELECT layer_id, COUNT(*) AS neurons
    FROM nn_neuron
    GROUP BY layer_id
) layer_size ON layer_size.layer_id = l.id
GROUP BY a.id, a.nome
ORDER BY a.id;
```

Camadas, neurônios, ativação e mapeamento das quatro entradas/saídas:

```sql
SELECT a.nome AS arquitetura, l.ordem, l.tipo, n.posicao,
       n.funcao_ativacao, io.nome AS entrada_ou_acao, io.descricao
FROM nn_architecture a
JOIN nn_layer l ON l.architecture_id = a.id
JOIN nn_neuron n ON n.layer_id = l.id
LEFT JOIN nn_neuron_io io ON io.neuron_id = n.id
WHERE a.nome = 'auto_20261025_h64'
ORDER BY l.ordem, n.posicao;
```

Quantidade de sinapses por par de camadas:

```sql
SELECT a.nome AS arquitetura, source_layer.ordem AS camada_origem,
       target_layer.ordem AS camada_destino, COUNT(*) AS sinapses
FROM nn_architecture a
JOIN nn_layer source_layer ON source_layer.architecture_id = a.id
JOIN nn_neuron source_neuron ON source_neuron.layer_id = source_layer.id
JOIN nn_synapse s ON s.from_neuron_id = source_neuron.id
JOIN nn_neuron target_neuron ON target_neuron.id = s.to_neuron_id
JOIN nn_layer target_layer ON target_layer.id = target_neuron.layer_id
WHERE a.nome = 'auto_20261025_h64'
GROUP BY a.nome, source_layer.ordem, target_layer.ordem
ORDER BY source_layer.ordem, target_layer.ordem;
```

Genomas por arquitetura e geração, incluindo origem, pais e fitness legado:

```sql
SELECT a.nome AS arquitetura, g.geracao, g.id AS genome_id,
       g.origem, g.pai1_id, g.pai2_id, g.fitness,
       COUNT(e.id) AS avaliacoes_legadas
FROM nn_architecture a
JOIN nn_genome g ON g.architecture_id = a.id
LEFT JOIN nn_genome_evaluation e ON e.genome_id = g.id
WHERE a.nome = 'auto_20261025_h64'
GROUP BY a.nome, g.geracao, g.id, g.origem, g.pai1_id, g.pai2_id, g.fitness
ORDER BY g.geracao, g.id;
```

Pesos de um genoma (substitua `GENOME_ID` por um ID da consulta anterior; remova `LIMIT` para exportar tudo):

```sql
SELECT w.genome_id, source_layer.ordem AS camada_origem,
       source_neuron.posicao AS neuronio_origem,
       target_layer.ordem AS camada_destino,
       target_neuron.posicao AS neuronio_destino, w.peso
FROM nn_genome_weight w
JOIN nn_synapse s ON s.id = w.synapse_id
JOIN nn_neuron source_neuron ON source_neuron.id = s.from_neuron_id
JOIN nn_layer source_layer ON source_layer.id = source_neuron.layer_id
JOIN nn_neuron target_neuron ON target_neuron.id = s.to_neuron_id
JOIN nn_layer target_layer ON target_layer.id = target_neuron.layer_id
WHERE w.genome_id = GENOME_ID
ORDER BY source_layer.ordem, source_neuron.posicao,
         target_layer.ordem, target_neuron.posicao
LIMIT 100;
```

Biases do genoma:

```sql
SELECT b.genome_id, l.ordem AS camada, n.posicao AS neuronio, b.bias
FROM nn_genome_bias b
JOIN nn_neuron n ON n.id = b.neuron_id
JOIN nn_layer l ON l.id = n.layer_id
WHERE b.genome_id = GENOME_ID
ORDER BY l.ordem, n.posicao;
```

Resumo das gerações do fluxo legado (os valores de fitness antigos têm a limitação de proveniência descrita acima):

```sql
SELECT architecture.nome AS arquitetura, summary.geracao,
       summary.tamanho_populacao, summary.individuos_avaliados,
       summary.fitness_medio, summary.melhor_fitness,
       summary.pior_fitness, summary.completa
FROM nn_generation_summary summary
JOIN nn_architecture architecture ON architecture.id = summary.architecture_id
ORDER BY architecture.nome, summary.geracao;
```

Resumo das gerações e avaliações da evolução v2:

```sql
SELECT experiment.experiment_name, architecture.nome AS arquitetura,
       generation.generation, generation.status,
       generation.evaluated_genomes, generation.evaluation_count,
       generation.fitness_mean, generation.best_fitness, generation.worst_fitness
FROM nn_training_experiment_v2 experiment
JOIN nn_architecture architecture ON architecture.id = experiment.architecture_id
JOIN nn_training_generation_v2 generation
  ON generation.experiment_id = experiment.experiment_id
ORDER BY experiment.experiment_name, generation.generation;

SELECT score.experiment_id, score.generation, score.genome_id,
       score.evaluations_used, score.fitness_mean, score.fitness_best,
       score.damage_to_player, score.player_kills, score.damage_received,
       score.npc_deaths, score.survival_seconds
FROM nn_training_genome_score_v2 score
ORDER BY score.experiment_id, score.generation, score.genome_id;
```

Os nomes `nn_genome_evaluation`/`nn_generation_summary` guardam o fluxo legado; `nn_genome_evaluation_training_v2` e `nn_training_genome_score_v2` guardam o v2. Não compare nem interprete fitness legado como prova de aprendizado. A tabela de score v2 só usa avaliações reais com ACK confirmado; ainda assim, são necessárias repetições controladas antes de declarar melhora.
