-- Cria MLPs densas configuráveis. A versão atual do engine fornece quatro
-- entradas reais e espera as quatro ações já existentes.
DROP PROCEDURE IF EXISTS sp_nn_create_configurable_architecture;
DELIMITER $$
CREATE PROCEDURE sp_nn_create_configurable_architecture(
    IN p_architecture_name VARCHAR(50),
    IN p_topology JSON,
    IN p_hidden_activation VARCHAR(10)
)
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_layer_count INT DEFAULT 0;
    DECLARE v_layer_index INT DEFAULT 0;
    DECLARE v_neuron_index INT DEFAULT 0;
    DECLARE v_layer_id INT DEFAULT NULL;
    DECLARE v_layer_width INT DEFAULT 0;
    DECLARE v_previous_width INT DEFAULT 0;
    DECLARE v_input_width INT DEFAULT 0;
    DECLARE v_output_width INT DEFAULT 0;
    DECLARE v_parameter_count BIGINT DEFAULT 0;
    DECLARE v_json_type VARCHAR(16) DEFAULT NULL;
    DECLARE v_json_path VARCHAR(32) DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_architecture_name IS NULL OR CHAR_LENGTH(TRIM(p_architecture_name)) = 0
       OR p_topology IS NULL OR JSON_TYPE(p_topology) <> 'ARRAY'
       OR p_hidden_activation IS NULL
       OR p_hidden_activation NOT IN ('sigmoid', 'relu', 'tanh') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Nome, topologia ou ativação inválidos';
    END IF;

    SET v_layer_count = JSON_LENGTH(p_topology);
    IF v_layer_count < 3 OR v_layer_count > 8 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A topologia precisa ter de 3 a 8 camadas';
    END IF;

    WHILE v_layer_index < v_layer_count DO
        SET v_json_path = CONCAT('$[', v_layer_index, ']');
        SET v_json_type = JSON_TYPE(JSON_EXTRACT(p_topology, v_json_path));
        IF COALESCE(v_json_type, '') <> 'INTEGER' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cada largura da topologia precisa ser um inteiro';
        END IF;

        SET v_layer_width = CAST(JSON_UNQUOTE(JSON_EXTRACT(p_topology, v_json_path)) AS SIGNED);
        IF v_layer_width < 1 OR v_layer_width > 512 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cada camada deve ter de 1 a 512 neurônios';
        END IF;

        IF v_layer_index = 0 THEN
            SET v_input_width = v_layer_width;
        ELSE
            SET v_parameter_count = v_parameter_count + (v_previous_width * v_layer_width);
            SET v_parameter_count = v_parameter_count + v_layer_width;
        END IF;
        IF v_layer_index = v_layer_count - 1 THEN
            SET v_output_width = v_layer_width;
        END IF;

        SET v_previous_width = v_layer_width;
        SET v_layer_index = v_layer_index + 1;
    END WHILE;

    IF v_input_width <> 4 OR v_output_width <> 4 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'O engine atual exige 4 entradas reais e 4 saídas de ação';
    END IF;
    IF v_parameter_count > 120000 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Topologia acima do limite experimental de 120000 pesos e biases';
    END IF;

    IF EXISTS (SELECT 1 FROM nn_architecture WHERE nome = p_architecture_name) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A arquitetura já existe e não será sobrescrita';
    END IF;

    START TRANSACTION;

    INSERT INTO nn_architecture (nome, n_entradas, n_saidas)
    VALUES (p_architecture_name, v_input_width, v_output_width);
    SET v_architecture_id = LAST_INSERT_ID();

    SET v_layer_index = 0;
    WHILE v_layer_index < v_layer_count DO
        SET v_layer_width = CAST(JSON_UNQUOTE(
            JSON_EXTRACT(p_topology, CONCAT('$[', v_layer_index, ']'))
        ) AS UNSIGNED);

        INSERT INTO nn_layer (architecture_id, ordem, tipo)
        VALUES (
            v_architecture_id,
            v_layer_index,
            CASE
                WHEN v_layer_index = 0 THEN 'input'
                WHEN v_layer_index = v_layer_count - 1 THEN 'output'
                ELSE 'hidden'
            END
        );
        SET v_layer_id = LAST_INSERT_ID();

        SET v_neuron_index = 0;
        WHILE v_neuron_index < v_layer_width DO
            INSERT INTO nn_neuron (layer_id, posicao, funcao_ativacao)
            VALUES (
                v_layer_id,
                v_neuron_index,
                CASE
                    WHEN v_layer_index = 0 THEN 'sigmoid'
                    WHEN v_layer_index = v_layer_count - 1 THEN 'sigmoid'
                    ELSE p_hidden_activation
                END
            );
            SET v_neuron_index = v_neuron_index + 1;
        END WHILE;

        SET v_layer_index = v_layer_index + 1;
    END WHILE;

    INSERT INTO nn_neuron_io (neuron_id, nome, descricao)
    SELECT n.id,
        CASE n.posicao
            WHEN 0 THEN 'HEALTH_RATIO'
            WHEN 1 THEN 'PLAYER_DISTANCE_RATIO'
            WHEN 2 THEN 'PLAYER_VISIBLE'
            WHEN 3 THEN 'HEALTH_DELTA'
        END,
        CASE n.posicao
            WHEN 0 THEN 'Vida atual dividida pela vida máxima informada pelo engine'
            WHEN 1 THEN 'Distância real do jogador normalizada no SQL por 2048'
            WHEN 2 THEN 'Visibilidade real do jogador verificada pelo engine'
            WHEN 3 THEN 'Variação de vida observada entre decisões reais'
        END
    FROM nn_layer l
    JOIN nn_neuron n ON n.layer_id = l.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'input';

    INSERT INTO nn_neuron_io (neuron_id, nome, descricao)
    SELECT n.id,
        CASE n.posicao
            WHEN 0 THEN 'IDLE'
            WHEN 1 THEN 'CHASE'
            WHEN 2 THEN 'ATTACK'
            WHEN 3 THEN 'FLEE'
        END,
        CASE n.posicao
            WHEN 0 THEN 'Manter o comportamento atual'
            WHEN 1 THEN 'Perseguir o jogador'
            WHEN 2 THEN 'Atacar o jogador'
            WHEN 3 THEN 'Fugir do jogador'
        END
    FROM nn_layer l
    JOIN nn_neuron n ON n.layer_id = l.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'output';

    INSERT INTO nn_synapse (from_neuron_id, to_neuron_id)
    SELECT origem.id, destino.id
    FROM nn_layer camada_origem
    JOIN nn_layer camada_destino
      ON camada_destino.architecture_id = camada_origem.architecture_id
     AND camada_destino.ordem = camada_origem.ordem + 1
    JOIN nn_neuron origem ON origem.layer_id = camada_origem.id
    JOIN nn_neuron destino ON destino.layer_id = camada_destino.id
    WHERE camada_origem.architecture_id = v_architecture_id;

    COMMIT;

    SELECT v_architecture_id AS architecture_id,
           p_architecture_name AS architecture_name,
           v_layer_count AS layer_count,
           v_parameter_count AS trainable_parameters;
END$$
DELIMITER ;
