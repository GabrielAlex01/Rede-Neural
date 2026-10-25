# Modelagem do Banco — Rede Neural em MySQL para IA de NPCs

O schema está dividido em quatro blocos. Execute `00_create_database.sql` para
a instalação principal e selecione o schema desejado antes de executar os
demais arquivos. A suíte usa `npc_neural_game_test` e não apaga dados.

## Bloco 1 — Estrutura da rede (topologia)
`nn_architecture` → `nn_layer` → `nn_neuron` → `nn_synapse`

Define o "formato" do cérebro (quantas camadas, quantos neurônios, quais conexões existem), sem nenhum peso ainda. É compartilhado entre todos os NPCs do mesmo tipo.

## Mapeamento de entradas e saídas
`nn_neuron` → `nn_neuron_io`

O script `02_io_mapping.sql` cria `nn_neuron_io`. O tipo do neurônio continua
definido em `nn_layer.tipo`.

Entradas da MLP inicial:

- `HEALTH_RATIO`: HP atual / HP máximo informado pelo engine, limitada a
  `[0, 1]` pelo SQL.
- `PLAYER_DISTANCE_RATIO`: distância em unidades do mapa / 2048, limitada a
  `[0, 1]` pelo SQL. O bridge usa `P_AproxDistance` e remove o fator fixo do
  Chocolate Doom antes de enviar o valor.
- `PLAYER_VISIBLE`: resultado booleano de `P_CheckSight`, convertido para `0`
  ou `1`.
- `HEALTH_DELTA`: diferença entre o HP observado agora e na decisão anterior,
  dividida pelo HP máximo e limitada a `[-1, 1]`. Na primeira observação vale 0.

O campo `current_state` recebido pelo bridge é o índice de `actor->state` em
`states`. Esse índice identifica um estado interno do engine e não é uma
grandeza contínua; ele fica disponível para diagnóstico e não é entrada da rede.

Saídas mapeadas:

- `IDLE`
- `CHASE`
- `ATTACK`
- `FLEE`

## Arquitetura inicial de teste

O script `03_seed_architecture.sql` cria a arquitetura `npc_teste_4_6_4`, organizada em:

- 4 neurônios de entrada
- 6 neurônios ocultos com ReLU
- 4 neurônios de saída com sigmoid

As conexões são criadas somente entre camadas vizinhas e de forma completa, resultando em 48 sinapses. A camada de entrada apenas recebe os valores; a função de ativação armazenada nela não deve fazer parte do processamento futuro.

Os scripts de mapeamento e arquitetura foram mantidos separados de `schema.sql`.

## Bloco 2 — Genoma (pesos individuais)
`nn_genome` → `nn_genome_weight` / `nn_genome_bias`

Cada NPC tem seu próprio conjunto de pesos e bias rodando sobre a mesma topologia do Bloco 1. `nn_genome` guarda também `fitness`, `geracao` e os pais (`pai1_id`/`pai2_id`), para permitir evolução genética (crossover/mutação) em vez de backpropagation — que é inviável em SQL puro.

## Bloco 3 — Entidades do jogo
`game_level`, `level_wall`, `npc_type`, `npc_instance`, `player_state`

`npc_instance` é a ponte entre o mundo do jogo e a rede neural: cada instância aponta para um `genome_id` específico.

## Bloco 4 — Execução (forward pass)
`nn_run` → `nn_run_activation`

Cada vez que um NPC precisa decidir uma ação, cria-se um `nn_run`. As ativações de cada neurônio (entrada, ocultas e saída) daquela decisão específica ficam em `nn_run_activation`.

## Fluxo de uma decisão de NPC

1. O engine envia estado com sessão, identificador do ator, tipo do NPC, HP,
   HP máximo, distância, visibilidade e o índice de estado bruto.
2. O FastAPI valida o contrato e encaminha a chamada ao MySQL.
3. O SQL associa sessão/NPC/genoma, normaliza as quatro entradas, calcula as
   ativações da rede e registra o `nn_run`.
4. O maior valor da camada de saída escolhe `IDLE`, `CHASE`, `ATTACK` ou `FLEE`.
5. O engine aplica a ação e informa se ela foi aceita; erro ou resposta atrasada
   mantém a IA original.
6. Eventos de combate observados no engine alimentam fitness e evolução; uma
   decisão ou um peso diferente, sozinhos, não comprovam treinamento.

## Instalação e testes

1. Execute `tests/00_create_test_database.sql` para selecionar o banco de teste.
2. No mesmo schema, execute `schema.sql`, `02_io_mapping.sql` e
   `03_seed_architecture.sql`.
3. Execute `tests/01_assert_architecture.sql`. O teste verifica as contagens,
   as conexões e que `CURRENT_STATE` não está mapeado como entrada.

O seed pode ser executado novamente sem duplicar a arquitetura, camadas,
neurônios, mapeamentos ou sinapses. A rede usa pesos aleatórios até que exista
fitness calculado com eventos reais; pesos aleatórios não significam treinamento.
