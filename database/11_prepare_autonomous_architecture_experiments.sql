-- Use apenas no schema isolado do jogo. Não executa CREATE DATABASE nem apaga dados.
USE neural_doom_local_game_20261024;

DROP PROCEDURE IF EXISTS sp_nn_prepare_autonomous_experiment_20261025;
DELIMITER $$
CREATE PROCEDURE sp_nn_prepare_autonomous_experiment_20261025(
    IN p_architecture_name VARCHAR(50),
    IN p_experiment_name VARCHAR(80),
    IN p_topology JSON,
    IN p_seed BIGINT UNSIGNED,
    IN p_condition_label VARCHAR(120)
)
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_layer_count INT DEFAULT 0;
    DECLARE v_topology_mismatches INT DEFAULT 0;
    DECLARE v_activation_mismatches INT DEFAULT 0;
    DECLARE v_genome_count INT DEFAULT 0;
    DECLARE v_conflict_count INT DEFAULT 0;
    DECLARE v_match_count INT DEFAULT 0;

    IF DATABASE() <> 'neural_doom_local_game_20261024' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Selecione exclusivamente neural_doom_local_game_20261024';
    END IF;

    IF p_seed > 4294967295 OR p_topology IS NULL OR JSON_TYPE(p_topology) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Semente ou topologia inválida';
    END IF;

    SELECT id INTO v_architecture_id
    FROM nn_architecture WHERE nome = p_architecture_name;

    IF v_architecture_id IS NULL THEN
        CALL sp_nn_create_configurable_architecture(
            p_architecture_name, p_topology, 'relu'
        );
        SELECT id INTO v_architecture_id
        FROM nn_architecture WHERE nome = p_architecture_name;
    END IF;

    SELECT COUNT(*) INTO v_layer_count
    FROM nn_layer WHERE architecture_id = v_architecture_id;

    SELECT COUNT(*) INTO v_topology_mismatches
    FROM JSON_TABLE(
        p_topology,
        '$[*]' COLUMNS (
            layer_order FOR ORDINALITY,
            expected_width INT PATH '$'
        )
    ) AS expected
    LEFT JOIN nn_layer layer
      ON layer.architecture_id = v_architecture_id
     AND layer.ordem = expected.layer_order - 1
    WHERE layer.id IS NULL
       OR (SELECT COUNT(*) FROM nn_neuron neuron WHERE neuron.layer_id = layer.id)
          <> expected.expected_width;

    IF v_layer_count <> JSON_LENGTH(p_topology) OR v_topology_mismatches <> 0
       OR (SELECT n_entradas FROM nn_architecture WHERE id = v_architecture_id) <> 4
       OR (SELECT n_saidas FROM nn_architecture WHERE id = v_architecture_id) <> 4 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A arquitetura existente não corresponde à topologia solicitada';
    END IF;

    SELECT COUNT(*) INTO v_activation_mismatches
    FROM nn_layer layer
    JOIN nn_neuron neuron ON neuron.layer_id = layer.id
    WHERE layer.architecture_id = v_architecture_id
      AND layer.tipo = 'hidden'
      AND neuron.funcao_ativacao <> 'relu';
    IF v_activation_mismatches <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A arquitetura existente não usa ReLU nas camadas ocultas';
    END IF;

    SELECT COUNT(*) INTO v_match_count
    FROM nn_training_experiment
    WHERE nome = p_experiment_name
      AND architecture_id = v_architecture_id
      AND seed = p_seed
      AND population_size = 4
      AND mutation_rate = 0.05
      AND planned_generations = 2
      AND evaluations_per_genome = 2
      AND condition_label = p_condition_label;

    SELECT COUNT(*) INTO v_conflict_count
    FROM nn_training_experiment
    WHERE nome = p_experiment_name OR architecture_id = v_architecture_id;

    IF v_match_count = 1 THEN
        SELECT 'EXPERIMENTO EXISTENTE, CONFIGURAÇÃO CONFERIDA' AS status,
               p_experiment_name AS experiment_name,
               p_architecture_name AS architecture_name;
    ELSEIF v_conflict_count <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Nome ou arquitetura já associado a outro experimento; nada foi alterado';
    ELSE
        SELECT COUNT(*) INTO v_genome_count
        FROM nn_genome WHERE architecture_id = v_architecture_id;
        IF v_genome_count <> 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Arquitetura já possui genomas sem este experimento; nada foi alterado';
        END IF;

        CALL sp_nn_create_training_experiment(
            p_experiment_name,
            p_architecture_name,
            p_seed,
            4,
            0.05,
            2,
            2,
            p_condition_label
        );
    END IF;
END$$
DELIMITER ;

CALL sp_nn_prepare_autonomous_experiment_20261025(
    'auto_20261025_ref46', 'auto_20261025_ref_4_6_4',
    JSON_ARRAY(4, 6, 4), 2026102501,
    'Freedoom2 E1M1 skill 2, 75s, Edge isolado, controles fixos'
);
CALL sp_nn_prepare_autonomous_experiment_20261025(
    'auto_20261025_h32', 'auto_20261025_h32_4_32_4',
    JSON_ARRAY(4, 32, 4), 2026102502,
    'Freedoom2 E1M1 skill 2, 75s, Edge isolado, controles fixos'
);
CALL sp_nn_prepare_autonomous_experiment_20261025(
    'auto_20261025_h64', 'auto_20261025_h64_4_64_4',
    JSON_ARRAY(4, 64, 4), 2026102503,
    'Freedoom2 E1M1 skill 2, 75s, Edge isolado, controles fixos'
);
CALL sp_nn_prepare_autonomous_experiment_20261025(
    'auto_20261025_deep6464', 'auto_20261025_deep_4_64_32_64_4',
    JSON_ARRAY(4, 64, 32, 64, 4), 2026102504,
    'Freedoom2 E1M1 skill 2, 75s, Edge isolado, controles fixos'
);
CALL sp_nn_prepare_autonomous_experiment_20261025(
    'auto_20261025_deep12864128', 'auto_20261025_128_64_128',
    JSON_ARRAY(4, 128, 64, 128, 4), 2026102505,
    'Freedoom2 E1M1 skill 2, 75s, Edge isolado, controles fixos'
);
CALL sp_nn_prepare_autonomous_experiment_20261025(
    'auto_20261025_deep25612864', 'auto_20261025_256_128_64',
    JSON_ARRAY(4, 256, 128, 64, 4), 2026102506,
    'Freedoom2 E1M1 skill 2, 75s, Edge isolado, controles fixos'
);
CALL sp_nn_prepare_autonomous_experiment_20261025(
    'auto_20261025_h512', 'auto_20261025_512_4_512_4',
    JSON_ARRAY(4, 512, 4), 2026102507,
    'Freedoom2 E1M1 skill 2, 75s, Edge isolado, controles fixos'
);
