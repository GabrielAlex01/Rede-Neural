-- Read APIs for the interactive frontend laboratory.
-- This migration adds procedures only; it does not change tables, genomes,
-- evaluations, or existing procedures. Run only in the isolated Neural Doom
-- schemas already used by the project.

SELECT VERSION() AS mysql_version, DATABASE() AS selected_schema;

DROP PROCEDURE IF EXISTS sp_nn_lab_list_architectures;
DROP PROCEDURE IF EXISTS sp_nn_lab_architecture_layers;
DROP PROCEDURE IF EXISTS sp_nn_lab_list_genomes;
DROP PROCEDURE IF EXISTS sp_nn_lab_run_activations;
DROP PROCEDURE IF EXISTS sp_nn_lab_genome_weights;

DELIMITER $$

CREATE PROCEDURE sp_nn_lab_list_architectures()
BEGIN
    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Laboratório permitido somente nos schemas isolados Neural Doom';
    END IF;

    SELECT a.id AS architecture_id,
           a.nome AS architecture_name,
           a.n_entradas AS input_count,
           a.n_saidas AS output_count,
           COALESCE((
               SELECT GROUP_CONCAT(
                   (SELECT COUNT(*) FROM nn_neuron n WHERE n.layer_id = l.id)
                   ORDER BY l.ordem SEPARATOR ' -> '
               )
               FROM nn_layer l
               WHERE l.architecture_id = a.id
           ), '') AS topology,
           (SELECT COUNT(*) FROM nn_layer l WHERE l.architecture_id = a.id) AS layer_count,
           (SELECT COUNT(*) FROM nn_neuron n JOIN nn_layer l ON l.id = n.layer_id
            WHERE l.architecture_id = a.id) AS neuron_count,
           (SELECT COUNT(*) FROM nn_synapse s
            JOIN nn_neuron source_neuron ON source_neuron.id = s.from_neuron_id
            JOIN nn_layer source_layer ON source_layer.id = source_neuron.layer_id
            WHERE source_layer.architecture_id = a.id) AS weight_count,
           (SELECT COUNT(*) FROM nn_neuron n JOIN nn_layer l ON l.id = n.layer_id
            WHERE l.architecture_id = a.id AND l.tipo IN ('hidden', 'output')) AS bias_count,
           (SELECT COUNT(*) FROM nn_genome g WHERE g.architecture_id = a.id) AS genome_count,
           (SELECT COUNT(DISTINCT g.geracao) FROM nn_genome g WHERE g.architecture_id = a.id) AS generation_count,
           (SELECT MAX(g.geracao) FROM nn_genome g WHERE g.architecture_id = a.id) AS latest_generation,
           CASE WHEN training.experiment_count IS NOT NULL
                THEN training.active_generation
                ELSE (SELECT MAX(g.geracao) FROM nn_genome g WHERE g.architecture_id = a.id)
           END AS playable_generation,
           CASE
             WHEN a.n_entradas <> 4 OR a.n_saidas <> 4 THEN 0
             WHEN training.experiment_count IS NULL THEN EXISTS (
                 SELECT 1 FROM nn_genome g
                 WHERE g.architecture_id = a.id
                   AND g.geracao = (SELECT MAX(latest.geracao)
                                    FROM nn_genome latest
                                    WHERE latest.architecture_id = a.id)
             )
             WHEN training.experiment_count = 1
              AND training.evaluating_generation_count = 1
              AND EXISTS (
                  SELECT 1 FROM nn_training_experiment_genome_v2 member
                  WHERE member.experiment_id = training.experiment_id
                    AND member.generation = training.active_generation
              ) THEN 1
             ELSE 0
           END AS playable
    FROM nn_architecture a
    LEFT JOIN (
        SELECT experiment.architecture_id,
               COUNT(DISTINCT experiment.experiment_id) AS experiment_count,
               MAX(experiment.experiment_id) AS experiment_id,
               COUNT(generation.generation) AS evaluating_generation_count,
               MAX(generation.generation) AS active_generation
        FROM nn_training_experiment_v2 experiment
        LEFT JOIN nn_training_generation_v2 generation
          ON generation.experiment_id = experiment.experiment_id
         AND generation.status = 'EVALUATING'
        GROUP BY experiment.architecture_id
    ) training ON training.architecture_id = a.id
    ORDER BY a.nome;
END$$

CREATE PROCEDURE sp_nn_lab_architecture_layers(IN p_architecture_id INT)
BEGIN
    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Laboratório permitido somente nos schemas isolados Neural Doom';
    END IF;
    IF p_architecture_id IS NULL OR p_architecture_id < 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID de arquitetura inválido';
    END IF;

    SELECT l.ordem AS layer_order,
           l.tipo AS layer_type,
           COUNT(n.id) AS neuron_count,
           GROUP_CONCAT(DISTINCT n.funcao_ativacao ORDER BY n.funcao_ativacao) AS activations,
           GROUP_CONCAT(io.nome ORDER BY n.posicao SEPARATOR ', ') AS io_names
    FROM nn_layer l
    LEFT JOIN nn_neuron n ON n.layer_id = l.id
    LEFT JOIN nn_neuron_io io ON io.neuron_id = n.id
    WHERE l.architecture_id = p_architecture_id
    GROUP BY l.id, l.ordem, l.tipo
    ORDER BY l.ordem;
END$$

CREATE PROCEDURE sp_nn_lab_list_genomes(
    IN p_architecture_id INT,
    IN p_generation INT,
    IN p_limit INT,
    IN p_offset INT
)
BEGIN
    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Laboratório permitido somente nos schemas isolados Neural Doom';
    END IF;
    IF p_architecture_id IS NULL OR p_architecture_id < 1
       OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100
       OR p_offset IS NULL OR p_offset < 0 OR p_offset > 1000000
       OR (p_generation IS NOT NULL AND p_generation < 0) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Página de genomas inválida';
    END IF;

    SELECT g.id AS genome_id,
           g.architecture_id,
           g.geracao AS generation,
           g.fitness,
           g.origem AS origin,
           g.pai1_id AS parent1_id,
           g.pai2_id AS parent2_id,
           g.criado_em AS created_at,
           (SELECT COUNT(*) FROM nn_genome_evaluation_v2 e
            WHERE e.genome_id = g.id) AS real_evaluation_count,
           (SELECT MAX(e.fitness) FROM nn_genome_evaluation_v2 e
            WHERE e.genome_id = g.id) AS best_real_fitness
    FROM nn_genome g
    WHERE g.architecture_id = p_architecture_id
      AND (p_generation IS NULL OR g.geracao = p_generation)
    ORDER BY g.geracao, g.fitness DESC, g.id
    LIMIT p_limit OFFSET p_offset;
END$$

CREATE PROCEDURE sp_nn_lab_run_activations(
    IN p_run_id BIGINT,
    IN p_layer_order INT,
    IN p_limit INT,
    IN p_offset INT
)
BEGIN
    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Laboratório permitido somente nos schemas isolados Neural Doom';
    END IF;
    IF p_run_id IS NULL OR p_run_id < 1
       OR p_layer_order IS NULL OR p_layer_order < 0 OR p_layer_order > 7
       OR p_limit IS NULL OR p_limit < 1 OR p_limit > 256
       OR p_offset IS NULL OR p_offset < 0 OR p_offset > 1000000 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Página de ativações inválida';
    END IF;

    SELECT r.id AS run_id,
           r.session_id,
           r.engine_npc_id AS npc_id,
           a.id AS architecture_id,
           a.nome AS architecture_name,
           g.id AS genome_id,
           g.geracao AS generation,
           r.health,
           r.max_health,
           r.player_distance,
           r.player_visible,
           r.current_state,
           r.health_ratio,
           r.player_distance_ratio,
           r.health_delta,
           r.action,
           r.confidence,
           r.criado_em AS created_at,
           l.ordem AS layer_order,
           l.tipo AS layer_type,
           n.posicao AS neuron_position,
           io.nome AS io_name,
           da.valor AS activation,
           COUNT(*) OVER() AS layer_total_neurons
    FROM nn_decision_run r
    JOIN nn_session_npc sn ON sn.session_id = r.session_id
                           AND sn.engine_npc_id = r.engine_npc_id
    JOIN nn_genome g ON g.id = r.genome_id AND g.id = sn.genome_id
    JOIN nn_architecture a ON a.id = g.architecture_id
    JOIN nn_layer l ON l.architecture_id = a.id AND l.ordem = p_layer_order
    JOIN nn_neuron n ON n.layer_id = l.id
    JOIN nn_decision_activation da ON da.run_id = r.id AND da.neuron_id = n.id
    LEFT JOIN nn_neuron_io io ON io.neuron_id = n.id
    WHERE r.id = p_run_id
    ORDER BY n.posicao
    LIMIT p_limit OFFSET p_offset;
END$$

CREATE PROCEDURE sp_nn_lab_genome_weights(
    IN p_genome_id INT,
    IN p_target_layer_order INT,
    IN p_target_position INT,
    IN p_limit INT,
    IN p_offset INT
)
BEGIN
    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Laboratório permitido somente nos schemas isolados Neural Doom';
    END IF;
    IF p_genome_id IS NULL OR p_genome_id < 1
       OR p_target_layer_order IS NULL OR p_target_layer_order < 1 OR p_target_layer_order > 7
       OR p_target_position IS NULL OR p_target_position < 0
       OR p_limit IS NULL OR p_limit < 1 OR p_limit > 200
       OR p_offset IS NULL OR p_offset < 0 OR p_offset > 1000000 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Página de pesos inválida';
    END IF;

    SELECT g.id AS genome_id,
           g.geracao AS generation,
           a.id AS architecture_id,
           a.nome AS architecture_name,
           source_layer.ordem AS source_layer_order,
           source_neuron.posicao AS source_position,
           target_layer.ordem AS target_layer_order,
           target_neuron.posicao AS target_position,
           target_io.nome AS target_io_name,
           w.peso AS weight,
           target_bias.bias AS target_bias,
           COUNT(*) OVER() AS incoming_weight_count
    FROM nn_genome g
    JOIN nn_architecture a ON a.id = g.architecture_id
    JOIN nn_layer target_layer ON target_layer.architecture_id = a.id
                              AND target_layer.ordem = p_target_layer_order
    JOIN nn_neuron target_neuron ON target_neuron.layer_id = target_layer.id
                                AND target_neuron.posicao = p_target_position
    JOIN nn_synapse s ON s.to_neuron_id = target_neuron.id
    JOIN nn_genome_weight w ON w.synapse_id = s.id AND w.genome_id = g.id
    LEFT JOIN nn_genome_bias target_bias
      ON target_bias.genome_id = g.id AND target_bias.neuron_id = target_neuron.id
    JOIN nn_neuron source_neuron ON source_neuron.id = s.from_neuron_id
    JOIN nn_layer source_layer ON source_layer.id = source_neuron.layer_id
                              AND source_layer.architecture_id = a.id
                              AND source_layer.ordem = target_layer.ordem - 1
    LEFT JOIN nn_neuron_io target_io ON target_io.neuron_id = target_neuron.id
    WHERE g.id = p_genome_id
    ORDER BY source_neuron.posicao
    LIMIT p_limit OFFSET p_offset;
END$$

DELIMITER ;
