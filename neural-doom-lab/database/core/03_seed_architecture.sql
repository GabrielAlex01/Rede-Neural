START TRANSACTION;

-- Esta arquitetura pequena serve para validar a montagem da rede antes de criar a execução.
INSERT INTO nn_architecture (nome, n_entradas, n_saidas)
VALUES ('npc_teste_4_6_4', 4, 4)
ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id);

SET @architecture_id = LAST_INSERT_ID();

-- As ordens deixam claro o caminho entrada -> oculta -> saída.
INSERT INTO nn_layer (architecture_id, ordem, tipo)
VALUES
    (@architecture_id, 0, 'input'),
    (@architecture_id, 1, 'hidden'),
    (@architecture_id, 2, 'output')
ON DUPLICATE KEY UPDATE tipo = nn_layer.tipo;

SET @input_layer_id = (
    SELECT id FROM nn_layer
    WHERE architecture_id = @architecture_id AND ordem = 0
);

SET @hidden_layer_id = (
    SELECT id FROM nn_layer
    WHERE architecture_id = @architecture_id AND ordem = 1
);

SET @output_layer_id = (
    SELECT id FROM nn_layer
    WHERE architecture_id = @architecture_id AND ordem = 2
);

-- A camada de entrada apenas recebe os quatro valores usados na decisão.
INSERT INTO nn_neuron (layer_id, posicao)
VALUES
    (@input_layer_id, 0),
    (@input_layer_id, 1),
    (@input_layer_id, 2),
    (@input_layer_id, 3)
ON DUPLICATE KEY UPDATE funcao_ativacao = nn_neuron.funcao_ativacao;

-- A camada oculta começa com seis neurônios ReLU para manter o teste simples.
INSERT INTO nn_neuron (layer_id, posicao, funcao_ativacao)
VALUES
    (@hidden_layer_id, 0, 'relu'),
    (@hidden_layer_id, 1, 'relu'),
    (@hidden_layer_id, 2, 'relu'),
    (@hidden_layer_id, 3, 'relu'),
    (@hidden_layer_id, 4, 'relu'),
    (@hidden_layer_id, 5, 'relu')
ON DUPLICATE KEY UPDATE funcao_ativacao = nn_neuron.funcao_ativacao;

-- Cada saída representa uma ação e usa sigmoid, que já existe no schema atual.
INSERT INTO nn_neuron (layer_id, posicao, funcao_ativacao)
VALUES
    (@output_layer_id, 0, 'sigmoid'),
    (@output_layer_id, 1, 'sigmoid'),
    (@output_layer_id, 2, 'sigmoid'),
    (@output_layer_id, 3, 'sigmoid')
ON DUPLICATE KEY UPDATE funcao_ativacao = nn_neuron.funcao_ativacao;

-- O estado interno do engine é registrado para diagnóstico, mas não entra como
-- grandeza numérica na rede. HEALTH_DELTA usa a variação observada de HP.
INSERT INTO nn_neuron_io (neuron_id, nome, descricao)
VALUES
    ((SELECT id FROM nn_neuron WHERE layer_id = @input_layer_id AND posicao = 0),
     'HEALTH_RATIO', 'Vida atual dividida pela vida máxima informada pelo engine'),
    ((SELECT id FROM nn_neuron WHERE layer_id = @input_layer_id AND posicao = 1),
     'PLAYER_DISTANCE_RATIO', 'Distância em unidades do mapa, normalizada no SQL por 2048'),
    ((SELECT id FROM nn_neuron WHERE layer_id = @input_layer_id AND posicao = 2),
     'PLAYER_VISIBLE', 'Indica se o jogador está visível'),
    ((SELECT id FROM nn_neuron WHERE layer_id = @input_layer_id AND posicao = 3),
     'HEALTH_DELTA', 'Variação observada de vida desde a decisão anterior, normalizada por HP máximo')
ON DUPLICATE KEY UPDATE neuron_id = nn_neuron_io.neuron_id;

-- Nas saídas, cada posição representa uma das ações disponíveis.
INSERT INTO nn_neuron_io (neuron_id, nome, descricao)
VALUES
    ((SELECT id FROM nn_neuron WHERE layer_id = @output_layer_id AND posicao = 0),
     'IDLE', 'Manter o comportamento atual'),
    ((SELECT id FROM nn_neuron WHERE layer_id = @output_layer_id AND posicao = 1),
     'CHASE', 'Perseguir o jogador'),
    ((SELECT id FROM nn_neuron WHERE layer_id = @output_layer_id AND posicao = 2),
     'ATTACK', 'Atacar o jogador'),
    ((SELECT id FROM nn_neuron WHERE layer_id = @output_layer_id AND posicao = 3),
     'FLEE', 'Fugir do jogador')
ON DUPLICATE KEY UPDATE neuron_id = nn_neuron_io.neuron_id;

-- A rede fica totalmente conectada entre camadas vizinhas: 24 + 24 sinapses.
INSERT INTO nn_synapse (from_neuron_id, to_neuron_id)
SELECT origem.id, destino.id
FROM nn_neuron origem
CROSS JOIN nn_neuron destino
WHERE origem.layer_id = @input_layer_id
  AND destino.layer_id = @hidden_layer_id
UNION ALL
SELECT origem.id, destino.id
FROM nn_neuron origem
CROSS JOIN nn_neuron destino
WHERE origem.layer_id = @hidden_layer_id
  AND destino.layer_id = @output_layer_id
ON DUPLICATE KEY UPDATE from_neuron_id = nn_synapse.from_neuron_id;

COMMIT;
