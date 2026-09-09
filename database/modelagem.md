# Modelagem do Banco — Rede Neural em MySQL para IA de NPCs

Schema completo em `schema.sql`, dividido em 4 blocos.

## Bloco 1 — Estrutura da rede (topologia)
`nn_architecture` → `nn_layer` → `nn_neuron` → `nn_synapse`

Define o "formato" do cérebro (quantas camadas, quantos neurônios, quais conexões existem), sem nenhum peso ainda. É compartilhado entre todos os NPCs do mesmo tipo.

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

- Stored procedures: `forward_pass()`, `criar_genoma_aleatorio()`, `avaliar_fitness()`, `crossover()`, `mutar()`
- Seed data: uma arquitetura de teste e um nível simples com paredes
- Integração com a engine do jogo (loop principal, renderização, input)
