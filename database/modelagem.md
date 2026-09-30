# Modelagem do Banco — Rede Neural em MySQL para IA de NPCs

Schema completo em `schema.sql`, dividido em 4 blocos.

## Bloco 1 — Estrutura da rede (topologia)
`nn_architecture` → `nn_layer` → `nn_neuron` → `nn_synapse`

Define o "formato" do cérebro (quantas camadas, quantos neurônios, quais conexões existem), sem nenhum peso ainda. É compartilhado entre todos os NPCs do mesmo tipo.

## Mapeamento de entradas e saídas
`nn_neuron` → `nn_neuron_io`

O script `02_io_mapping.sql` cria a tabela `nn_neuron_io`, usada somente para dar significado aos neurônios de entrada e saída. O tipo do neurônio não é repetido nessa tabela, pois já é definido por `nn_layer.tipo`.

Entradas mapeadas:

- `HEALTH`
- `PLAYER_DISTANCE`
- `PLAYER_VISIBLE`
- `CURRENT_STATE`

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

1. Jogo cria uma linha em `nn_run`.
2. Insere valores de entrada (distância do jogador, HP, etc.) como ativações da camada 0.
3. Stored procedure (a implementar) percorre `nn_layer` em ordem, calculando cada `nn_neuron` a partir de `nn_synapse` + `nn_genome_weight`/`nn_genome_bias` do genoma daquele NPC.
4. Última camada = decisão (ex: atacar/perseguir/fugir).
5. Jogo aplica a decisão em `npc_instance`.
6. Ao fim da partida/vida do NPC, calcula-se `fitness` do genoma para alimentar a próxima geração.

## Pendências (próxima etapa)

- Genoma inicial com pesos e biases
- Forward pass e decisão da rede
- Cálculo de fitness
- Crossover e mutação
- Integração da rede com o backend/Doom
