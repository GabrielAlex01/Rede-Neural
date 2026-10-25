-- Sessões e decisões mantêm separados os IDs do engine e os IDs do banco.
CREATE TABLE IF NOT EXISTS nn_engine_session (
    session_id CHAR(36) PRIMARY KEY,
    architecture_id INT NOT NULL,
    criada_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    encerrada_em TIMESTAMP NULL,
    FOREIGN KEY (architecture_id) REFERENCES nn_architecture(id),
    INDEX idx_nn_session_architecture (architecture_id, criada_em)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_session_npc (
    session_id CHAR(36) NOT NULL,
    engine_npc_id VARCHAR(64) NOT NULL,
    npc_type SMALLINT UNSIGNED NOT NULL,
    genome_id INT NOT NULL,
    max_health INT UNSIGNED NOT NULL,
    last_health INT NOT NULL,
    criado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    atualizado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (session_id, engine_npc_id),
    FOREIGN KEY (session_id) REFERENCES nn_engine_session(session_id) ON DELETE CASCADE,
    FOREIGN KEY (genome_id) REFERENCES nn_genome(id),
    INDEX idx_nn_session_npc_genome (genome_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_decision_run (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    session_id CHAR(36) NOT NULL,
    engine_npc_id VARCHAR(64) NOT NULL,
    genome_id INT NOT NULL,
    health INT NOT NULL,
    max_health INT UNSIGNED NOT NULL,
    player_distance DOUBLE NOT NULL,
    player_visible TINYINT(1) NOT NULL,
    current_state INT NOT NULL,
    health_ratio DOUBLE NOT NULL,
    player_distance_ratio DOUBLE NOT NULL,
    health_delta DOUBLE NOT NULL,
    action ENUM('IDLE','CHASE','ATTACK','FLEE') NULL,
    confidence DOUBLE NULL,
    criado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (session_id, engine_npc_id)
        REFERENCES nn_session_npc(session_id, engine_npc_id) ON DELETE CASCADE,
    FOREIGN KEY (genome_id) REFERENCES nn_genome(id),
    INDEX idx_nn_decision_session (session_id, criado_em),
    INDEX idx_nn_decision_genome (genome_id, criado_em)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_decision_activation (
    run_id BIGINT NOT NULL,
    neuron_id INT NOT NULL,
    valor DOUBLE NOT NULL,
    PRIMARY KEY (run_id, neuron_id),
    FOREIGN KEY (run_id) REFERENCES nn_decision_run(id) ON DELETE CASCADE,
    FOREIGN KEY (neuron_id) REFERENCES nn_neuron(id) ON DELETE CASCADE
) ENGINE=InnoDB;

DROP FUNCTION IF EXISTS fn_nn_activate;
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_nn_decide_for_architecture$$
DROP PROCEDURE IF EXISTS sp_nn_decide$$
CREATE PROCEDURE sp_nn_decide_for_architecture(
    IN p_architecture_name VARCHAR(50),
    IN p_session_id CHAR(36),
    IN p_engine_npc_id VARCHAR(64),
    IN p_npc_type SMALLINT UNSIGNED,
    IN p_health INT,
    IN p_max_health INT,
    IN p_player_distance DOUBLE,
    IN p_player_visible TINYINT,
    IN p_current_state INT,
    OUT p_run_id BIGINT,
    OUT p_action VARCHAR(16),
    OUT p_confidence DOUBLE
)
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_expected_inputs INT DEFAULT 0;
    DECLARE v_expected_outputs INT DEFAULT 0;
    DECLARE v_expected_weights INT DEFAULT 0;
    DECLARE v_actual_weights INT DEFAULT 0;
    DECLARE v_expected_biases INT DEFAULT 0;
    DECLARE v_actual_biases INT DEFAULT 0;
    DECLARE v_session_architecture INT DEFAULT NULL;
    DECLARE v_session_ended TIMESTAMP DEFAULT NULL;
    DECLARE v_npc_count INT DEFAULT 0;
    DECLARE v_population_count INT DEFAULT 0;
    DECLARE v_generation INT DEFAULT NULL;
    DECLARE v_genome_id INT DEFAULT NULL;
    DECLARE v_genome_offset INT DEFAULT 0;
    DECLARE v_previous_health INT DEFAULT 0;
    DECLARE v_roster_count INT DEFAULT 0;
    DECLARE v_input_count INT DEFAULT 0;
    DECLARE v_layer_order INT DEFAULT 1;
    DECLARE v_max_layer_order INT DEFAULT 0;
    DECLARE v_layer_count INT DEFAULT 0;
    DECLARE v_first_layer_order INT DEFAULT NULL;
    DECLARE v_invalid_layer_types INT DEFAULT 0;
    DECLARE v_expected_layer_neurons INT DEFAULT 0;
    DECLARE v_inserted_activations INT DEFAULT 0;
    DECLARE v_health_ratio DOUBLE DEFAULT 0;
    DECLARE v_distance_ratio DOUBLE DEFAULT 0;
    DECLARE v_health_delta DOUBLE DEFAULT 0;
    DECLARE v_output_name VARCHAR(50) DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_architecture_name IS NULL OR CHAR_LENGTH(TRIM(p_architecture_name)) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Nome da arquitetura inválido';
    END IF;
    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
    END IF;
    IF p_engine_npc_id IS NULL OR CHAR_LENGTH(TRIM(p_engine_npc_id)) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID do NPC do engine inválido';
    END IF;
    IF p_health IS NULL OR p_max_health IS NULL OR p_max_health <= 0
       OR p_health < 0 OR p_health > p_max_health THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vida do NPC fora do intervalo válido';
    END IF;
    IF p_player_distance IS NULL OR p_player_distance < 0 OR p_player_distance > 10000000 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Distância do jogador inválida';
    END IF;
    IF p_player_visible IS NULL OR p_player_visible NOT IN (0, 1)
       OR p_current_state IS NULL OR p_current_state < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Estado do jogador ou NPC inválido';
    END IF;

    SELECT id, n_entradas, n_saidas
    INTO v_architecture_id, v_expected_inputs, v_expected_outputs
    FROM nn_architecture
    WHERE nome = p_architecture_name;

    IF v_architecture_id IS NULL OR v_expected_inputs <> 4 OR v_expected_outputs <> 4 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Arquitetura ausente ou incompatível com as quatro entradas/saídas do engine';
    END IF;

    START TRANSACTION;

    SELECT COUNT(*) INTO v_npc_count
    FROM nn_engine_session
    WHERE session_id = p_session_id;

    IF v_npc_count = 0 THEN
        INSERT INTO nn_engine_session (session_id, architecture_id)
        VALUES (p_session_id, v_architecture_id);
    ELSE
        SELECT architecture_id, encerrada_em
        INTO v_session_architecture, v_session_ended
        FROM nn_engine_session
        WHERE session_id = p_session_id
        FOR UPDATE;

        IF v_session_architecture <> v_architecture_id OR v_session_ended IS NOT NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão encerrada ou associada a outra arquitetura';
        END IF;
    END IF;

    SELECT COUNT(*) INTO v_roster_count
    FROM nn_session_npc
    WHERE session_id = p_session_id AND engine_npc_id = p_engine_npc_id;

    IF v_roster_count = 0 THEN
        SELECT COALESCE(MAX(geracao), 0) INTO v_generation
        FROM nn_genome
        WHERE architecture_id = v_architecture_id;

        SELECT COUNT(*) INTO v_population_count
        FROM nn_genome
        WHERE architecture_id = v_architecture_id AND geracao = v_generation;

        IF v_population_count = 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A arquitetura não possui genomas';
        END IF;

        SELECT COUNT(*) INTO v_npc_count
        FROM nn_session_npc
        WHERE session_id = p_session_id;

        SELECT id INTO v_genome_id
        FROM nn_genome
        WHERE architecture_id = v_architecture_id AND geracao = v_generation
        ORDER BY fitness DESC, id
        LIMIT v_npc_count, 1;

        IF v_genome_id IS NULL THEN
            SET v_genome_offset = MOD(v_npc_count, v_population_count);
            SELECT id INTO v_genome_id
            FROM nn_genome
            WHERE architecture_id = v_architecture_id AND geracao = v_generation
            ORDER BY fitness DESC, id
            LIMIT v_genome_offset, 1;
        END IF;

        INSERT INTO nn_session_npc (
            session_id, engine_npc_id, npc_type, genome_id, max_health, last_health
        ) VALUES (
            p_session_id, p_engine_npc_id, p_npc_type, v_genome_id, p_max_health, p_health
        );
        SET v_previous_health = p_health;
    ELSE
        SELECT genome_id, last_health, max_health
        INTO v_genome_id, v_previous_health, v_npc_count
        FROM nn_session_npc
        WHERE session_id = p_session_id AND engine_npc_id = p_engine_npc_id
        FOR UPDATE;

        IF v_npc_count <> p_max_health THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vida máxima do NPC mudou durante a sessão';
        END IF;

        UPDATE nn_session_npc
        SET last_health = p_health
        WHERE session_id = p_session_id AND engine_npc_id = p_engine_npc_id;
    END IF;

    SELECT COALESCE(SUM(origem.quantidade * destino.quantidade), 0)
    INTO v_expected_weights
    FROM (
        SELECT l.ordem, COUNT(n.id) AS quantidade
        FROM nn_layer l
        JOIN nn_neuron n ON n.layer_id = l.id
        WHERE l.architecture_id = v_architecture_id
        GROUP BY l.id, l.ordem
    ) AS origem
    JOIN (
        SELECT l.ordem, COUNT(n.id) AS quantidade
        FROM nn_layer l
        JOIN nn_neuron n ON n.layer_id = l.id
        WHERE l.architecture_id = v_architecture_id
        GROUP BY l.id, l.ordem
    ) AS destino ON destino.ordem = origem.ordem + 1;
    SELECT COUNT(*) INTO v_actual_weights
    FROM nn_genome_weight w
    JOIN nn_synapse s ON s.id = w.synapse_id
    JOIN nn_neuron origem ON origem.id = s.from_neuron_id
    JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
    JOIN nn_neuron destino ON destino.id = s.to_neuron_id
    JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
    WHERE w.genome_id = v_genome_id
      AND camada_origem.architecture_id = v_architecture_id
      AND camada_destino.architecture_id = v_architecture_id;

    SELECT COUNT(*) INTO v_expected_biases
    FROM nn_neuron n
    JOIN nn_layer l ON l.id = n.layer_id
    WHERE l.architecture_id = v_architecture_id AND l.tipo IN ('hidden','output');
    SELECT COUNT(*) INTO v_actual_biases
    FROM nn_genome_bias b
    JOIN nn_neuron n ON n.id = b.neuron_id
    JOIN nn_layer l ON l.id = n.layer_id
    WHERE b.genome_id = v_genome_id
      AND l.architecture_id = v_architecture_id
      AND l.tipo IN ('hidden','output');

    IF v_actual_weights <> v_expected_weights OR v_actual_biases <> v_expected_biases THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'O genoma não possui todos os pesos e biases da arquitetura';
    END IF;

    SET v_health_ratio = LEAST(GREATEST(p_health / p_max_health, 0), 1);
    SET v_distance_ratio = LEAST(GREATEST(p_player_distance / 2048, 0), 1);
    SET v_health_delta = LEAST(GREATEST((v_previous_health - p_health) / p_max_health, -1), 1);

    SELECT MAX(ordem) INTO v_max_layer_order
    FROM nn_layer
    WHERE architecture_id = v_architecture_id;

    SELECT COUNT(*), MIN(ordem)
    INTO v_layer_count, v_first_layer_order
    FROM nn_layer
    WHERE architecture_id = v_architecture_id;

    SELECT COUNT(*) INTO v_invalid_layer_types
    FROM nn_layer
    WHERE architecture_id = v_architecture_id
      AND (
          (ordem = 0 AND tipo <> 'input')
          OR (ordem = v_max_layer_order AND tipo <> 'output')
          OR (ordem > 0 AND ordem < v_max_layer_order AND tipo <> 'hidden')
      );

    IF v_max_layer_order < 2 OR v_first_layer_order <> 0
       OR v_layer_count <> v_max_layer_order + 1
       OR v_invalid_layer_types <> 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A arquitetura possui camadas ausentes, fora de ordem ou com tipos incompatíveis';
    END IF;

    INSERT INTO nn_decision_run (
        session_id, engine_npc_id, genome_id, health, max_health,
        player_distance, player_visible, current_state,
        health_ratio, player_distance_ratio, health_delta
    ) VALUES (
        p_session_id, p_engine_npc_id, v_genome_id, p_health, p_max_health,
        p_player_distance, p_player_visible, p_current_state,
        v_health_ratio, v_distance_ratio, v_health_delta
    );
    SET p_run_id = LAST_INSERT_ID();

    INSERT INTO nn_decision_activation (run_id, neuron_id, valor)
    SELECT p_run_id, n.id,
        CASE io.nome
            WHEN 'HEALTH_RATIO' THEN v_health_ratio
            WHEN 'PLAYER_DISTANCE_RATIO' THEN v_distance_ratio
            WHEN 'PLAYER_VISIBLE' THEN p_player_visible
            WHEN 'HEALTH_DELTA' THEN v_health_delta
        END
    FROM nn_layer l
    JOIN nn_neuron n ON n.layer_id = l.id
    JOIN nn_neuron_io io ON io.neuron_id = n.id
    WHERE l.architecture_id = v_architecture_id
      AND l.tipo = 'input'
      AND io.nome IN ('HEALTH_RATIO','PLAYER_DISTANCE_RATIO','PLAYER_VISIBLE','HEALTH_DELTA');
    SET v_input_count = ROW_COUNT();

    IF v_input_count <> v_expected_inputs THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Mapeamento de entradas da arquitetura inválido';
    END IF;

    SET v_layer_order = 1;
    WHILE v_layer_order <= v_max_layer_order DO
        SELECT COUNT(*) INTO v_expected_layer_neurons
        FROM nn_layer l
        JOIN nn_neuron n ON n.layer_id = l.id
        WHERE l.architecture_id = v_architecture_id AND l.ordem = v_layer_order;

        IF v_expected_layer_neurons = 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Camada da rede sem neurônios';
        END IF;

        INSERT INTO nn_decision_activation (run_id, neuron_id, valor)
        SELECT p_run_id, destino.id,
            CASE destino.funcao_ativacao
                WHEN 'sigmoid' THEN
                    CASE
                        WHEN COALESCE(SUM(peso.peso * ativacao.valor), 0) + COALESCE(bias.bias, 0) >= 40 THEN 1
                        WHEN COALESCE(SUM(peso.peso * ativacao.valor), 0) + COALESCE(bias.bias, 0) <= -40 THEN 0
                        ELSE 1 / (1 + EXP(-(COALESCE(SUM(peso.peso * ativacao.valor), 0) + COALESCE(bias.bias, 0))))
                    END
                WHEN 'relu' THEN GREATEST(
                    COALESCE(SUM(peso.peso * ativacao.valor), 0) + COALESCE(bias.bias, 0),
                    0
                )
                WHEN 'tanh' THEN
                    CASE
                        WHEN COALESCE(SUM(peso.peso * ativacao.valor), 0) + COALESCE(bias.bias, 0) >= 20 THEN 1
                        WHEN COALESCE(SUM(peso.peso * ativacao.valor), 0) + COALESCE(bias.bias, 0) <= -20 THEN -1
                        ELSE (
                            EXP(2 * (COALESCE(SUM(peso.peso * ativacao.valor), 0) + COALESCE(bias.bias, 0))) - 1
                        ) / (
                            EXP(2 * (COALESCE(SUM(peso.peso * ativacao.valor), 0) + COALESCE(bias.bias, 0))) + 1
                        )
                    END
            END
        FROM nn_layer camada_destino
        JOIN nn_neuron destino ON destino.layer_id = camada_destino.id
        LEFT JOIN nn_genome_bias bias
            ON bias.genome_id = v_genome_id AND bias.neuron_id = destino.id
        LEFT JOIN nn_synapse sinapse ON sinapse.to_neuron_id = destino.id
        LEFT JOIN nn_genome_weight peso
            ON peso.genome_id = v_genome_id AND peso.synapse_id = sinapse.id
        LEFT JOIN nn_decision_activation ativacao
            ON ativacao.run_id = p_run_id AND ativacao.neuron_id = sinapse.from_neuron_id
        WHERE camada_destino.architecture_id = v_architecture_id
          AND camada_destino.ordem = v_layer_order
        GROUP BY destino.id, destino.funcao_ativacao, bias.bias;
        SET v_inserted_activations = ROW_COUNT();

        IF v_inserted_activations <> v_expected_layer_neurons THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pesos, biases ou conexões da camada estão incompletos';
        END IF;

        SET v_layer_order = v_layer_order + 1;
    END WHILE;

    SELECT io.nome, ativacao.valor
    INTO v_output_name, p_confidence
    FROM nn_layer l
    JOIN nn_neuron n ON n.layer_id = l.id
    JOIN nn_neuron_io io ON io.neuron_id = n.id
    JOIN nn_decision_activation ativacao ON ativacao.neuron_id = n.id AND ativacao.run_id = p_run_id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'output'
    ORDER BY ativacao.valor DESC, n.posicao ASC
    LIMIT 1;

    IF v_output_name NOT IN ('IDLE','CHASE','ATTACK','FLEE') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Mapeamento de saídas da arquitetura inválido';
    END IF;

    SET p_action = v_output_name;
    UPDATE nn_decision_run
    SET action = p_action, confidence = p_confidence
    WHERE id = p_run_id;

    COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_nn_decide$$
CREATE PROCEDURE sp_nn_decide(
    IN p_session_id CHAR(36),
    IN p_engine_npc_id VARCHAR(64),
    IN p_npc_type SMALLINT UNSIGNED,
    IN p_health INT,
    IN p_max_health INT,
    IN p_player_distance DOUBLE,
    IN p_player_visible TINYINT,
    IN p_current_state INT,
    OUT p_run_id BIGINT,
    OUT p_action VARCHAR(16),
    OUT p_confidence DOUBLE
)
BEGIN
    CALL sp_nn_decide_for_architecture(
        'npc_teste_4_6_4', p_session_id, p_engine_npc_id, p_npc_type,
        p_health, p_max_health, p_player_distance, p_player_visible,
        p_current_state, p_run_id, p_action, p_confidence
    );
END$$
DELIMITER ;
