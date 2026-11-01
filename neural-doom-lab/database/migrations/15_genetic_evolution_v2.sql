-- MySQL-only selection/reproduction for isolated v2 experiments.
-- It reads only fitness_version='combat_outcome_v2_1' with a confirmed ACK.
-- Legacy fitness, summaries and evolution procedures are never modified.
SELECT VERSION() AS mysql_version, DATABASE() AS selected_schema;

DROP PROCEDURE IF EXISTS sp_nn_assert_genetic_evolution_schema_v2;
DELIMITER $$
CREATE PROCEDURE sp_nn_assert_genetic_evolution_schema_v2()
BEGIN
    DECLARE v_required_tables INT DEFAULT 0;
    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Migration permitida somente nos dois schemas isolados Neural Doom';
    END IF;
    SELECT COUNT(*) INTO v_required_tables
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name IN (
          'nn_training_experiment_v2', 'nn_training_generation_v2',
          'nn_training_experiment_genome_v2', 'nn_training_experiment_session_v2',
          'nn_training_genome_score_v2', 'nn_genome_evaluation_training_v2',
          'nn_training_session_completion_v2'
      );
    IF v_required_tables <> 7 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Instale a migration 14_genetic_experiments_v2.sql primeiro';
    END IF;
END$$
CALL sp_nn_assert_genetic_evolution_schema_v2()$$
DROP PROCEDURE sp_nn_assert_genetic_evolution_schema_v2$$
DELIMITER ;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_nn_evolve_training_experiment_v2$$
CREATE PROCEDURE sp_nn_evolve_training_experiment_v2(
    IN p_experiment_id CHAR(36),
    IN p_source_generation INT,
    IN p_elite_count INT
)
BEGIN
    DECLARE v_already_done TINYINT DEFAULT 0;
    evolve_generation: BEGIN
        DECLARE v_experiment_count INT DEFAULT 0;
        DECLARE v_architecture_id INT DEFAULT NULL;
        DECLARE v_population_size INT DEFAULT 0;
        DECLARE v_evaluations_per_genome INT DEFAULT 0;
        DECLARE v_planned_generations INT DEFAULT 0;
        DECLARE v_base_seed BIGINT UNSIGNED DEFAULT 0;
        DECLARE v_generation_seed BIGINT UNSIGNED DEFAULT 0;
        DECLARE v_mutation_rate DECIMAL(7,6) DEFAULT 0;
        DECLARE v_generation_status VARCHAR(16) DEFAULT NULL;
        DECLARE v_previous_elite_count SMALLINT UNSIGNED DEFAULT NULL;
        DECLARE v_source_generation_count INT DEFAULT 0;
        DECLARE v_population_member_count INT DEFAULT 0;
        DECLARE v_incomplete_session_count INT DEFAULT 0;
        DECLARE v_invalid_session_count INT DEFAULT 0;
        DECLARE v_incomplete_genome_count INT DEFAULT 0;
        DECLARE v_scored_genome_count INT DEFAULT 0;
        DECLARE v_score_evaluation_count INT DEFAULT 0;
        DECLARE v_fitness_mean DECIMAL(14,4) DEFAULT NULL;
        DECLARE v_best_fitness DECIMAL(14,4) DEFAULT NULL;
        DECLARE v_worst_fitness DECIMAL(14,4) DEFAULT NULL;
        DECLARE v_will_create_children TINYINT DEFAULT 0;
        DECLARE v_child_index INT DEFAULT 0;
        DECLARE v_child_id INT DEFAULT NULL;
        DECLARE v_parent1_id INT DEFAULT NULL;
        DECLARE v_parent2_id INT DEFAULT NULL;
        DECLARE v_parent1_offset INT DEFAULT 0;
        DECLARE v_parent2_offset INT DEFAULT 0;
        DECLARE v_parent_weight_count INT DEFAULT 0;
        DECLARE v_parent_bias_count INT DEFAULT 0;
        DECLARE v_inserted_weight_count INT DEFAULT 0;
        DECLARE v_inserted_bias_count INT DEFAULT 0;
        DECLARE v_mutated_gene_count INT DEFAULT 0;
        DECLARE v_child_count INT DEFAULT 0;
        DECLARE v_child_member_count INT DEFAULT 0;

        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            DROP TEMPORARY TABLE IF EXISTS tmp_nn_training_v2_ranked;
            DROP TEMPORARY TABLE IF EXISTS tmp_nn_training_v2_scores;
            DROP TEMPORARY TABLE IF EXISTS tmp_nn_training_v2_elite;
            ROLLBACK;
            RESIGNAL;
        END;

        IF DATABASE() NOT IN (
            'neural_doom_local_game_20261024',
            'neural_doom_local_sql_test_20261024'
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Evolução permitida somente nos dois schemas isolados Neural Doom';
        END IF;
        IF p_experiment_id IS NULL OR IS_UUID(p_experiment_id) <> 1
           OR p_source_generation IS NULL OR p_source_generation < 0
           OR p_elite_count IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Parâmetros de evolução genética v2 inválidos';
        END IF;

        START TRANSACTION;
        SELECT COUNT(*) INTO v_experiment_count
        FROM nn_training_experiment_v2
        WHERE experiment_id = p_experiment_id;
        IF v_experiment_count <> 1 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Experimento v2 não encontrado';
        END IF;
        SELECT architecture_id, population_size, evaluations_per_genome,
               planned_generations, seed, mutation_rate
          INTO v_architecture_id, v_population_size, v_evaluations_per_genome,
               v_planned_generations, v_base_seed, v_mutation_rate
        FROM nn_training_experiment_v2
        WHERE experiment_id = p_experiment_id;
        IF p_source_generation >= v_planned_generations THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Geração fora do plano do experimento v2';
        END IF;
        IF p_elite_count < 2 OR p_elite_count > v_population_size THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Elite precisa conter de 2 a população completa';
        END IF;

        SELECT COUNT(*) INTO v_source_generation_count
        FROM nn_training_generation_v2
        WHERE experiment_id = p_experiment_id
          AND generation = p_source_generation;
        IF v_source_generation_count <> 1 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Registro da geração v2 não encontrado';
        END IF;
        SELECT status, elite_count INTO v_generation_status, v_previous_elite_count
        FROM nn_training_generation_v2
        WHERE experiment_id = p_experiment_id
          AND generation = p_source_generation
        FOR UPDATE;

        IF v_generation_status IN ('EVOLVED', 'COMPLETE') THEN
            IF v_previous_elite_count <> p_elite_count THEN
                SIGNAL SQLSTATE '45000'
                    SET MESSAGE_TEXT = 'Geração já concluída com outro tamanho de elite';
            END IF;
            COMMIT;
            SET v_already_done = 1;
            LEAVE evolve_generation;
        END IF;
        IF v_generation_status <> 'EVALUATING' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Geração v2 não pode ser evoluída neste estado';
        END IF;

        SELECT COUNT(*) INTO v_population_member_count
        FROM nn_training_experiment_genome_v2
        WHERE experiment_id = p_experiment_id
          AND generation = p_source_generation;
        IF v_population_member_count <> v_population_size THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Tamanho da população v2 não corresponde ao experimento';
        END IF;

        SELECT COUNT(*) INTO v_incomplete_session_count
        FROM nn_training_experiment_session_v2 session_v2
        LEFT JOIN nn_training_session_completion_v2 completion
          ON completion.session_id = session_v2.session_id
        WHERE session_v2.experiment_id = p_experiment_id
          AND session_v2.generation = p_source_generation
          AND (
              completion.session_id IS NULL
              OR completion.ack_confirmed_at IS NULL
              OR completion.fitness_version <> 'combat_outcome_v2_1'
              OR completion.evaluation_count = 0
          );
        IF v_incomplete_session_count <> 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Há sessões sem avaliação ou ACK confirmado; evolução v2 bloqueada';
        END IF;

        SELECT COUNT(*) INTO v_invalid_session_count
        FROM nn_training_experiment_session_v2 session_v2
        JOIN nn_training_session_completion_v2 completion
          ON completion.session_id = session_v2.session_id
        WHERE session_v2.experiment_id = p_experiment_id
          AND session_v2.generation = p_source_generation
          AND (
              completion.evaluation_count <> (
                  SELECT COUNT(*)
                  FROM nn_genome_evaluation_training_v2 evaluation
                  WHERE evaluation.session_id = session_v2.session_id
                    AND evaluation.fitness_version = 'combat_outcome_v2_1'
              )
              OR EXISTS (
                  SELECT 1
                  FROM nn_genome_evaluation_training_v2 evaluation
                  LEFT JOIN nn_training_experiment_genome_v2 member
                    ON member.experiment_id = session_v2.experiment_id
                   AND member.generation = session_v2.generation
                   AND member.genome_id = evaluation.genome_id
                  WHERE evaluation.session_id = session_v2.session_id
                    AND (
                        evaluation.attribution_version <> 'neural_attack_provenance_v2'
                        OR evaluation.fitness_version <> 'combat_outcome_v2_1'
                        OR member.genome_id IS NULL
                    )
              )
          );
        IF v_invalid_session_count <> 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Sessão contém avaliações fora da geração/versão v2 esperada';
        END IF;

        SELECT COUNT(*) INTO v_incomplete_genome_count
        FROM (
            SELECT member.genome_id,
                   COUNT(DISTINCT evaluation.session_id) AS trusted_evaluations
            FROM nn_training_experiment_genome_v2 member
            LEFT JOIN nn_training_experiment_session_v2 session_v2
              ON session_v2.experiment_id = member.experiment_id
             AND session_v2.generation = member.generation
            LEFT JOIN nn_training_session_completion_v2 completion
              ON completion.session_id = session_v2.session_id
             AND completion.fitness_version = 'combat_outcome_v2_1'
             AND completion.ack_confirmed_at IS NOT NULL
            LEFT JOIN nn_genome_evaluation_training_v2 evaluation
              ON evaluation.session_id = session_v2.session_id
             AND evaluation.genome_id = member.genome_id
             AND evaluation.attribution_version = 'neural_attack_provenance_v2'
             AND evaluation.fitness_version = 'combat_outcome_v2_1'
            WHERE member.experiment_id = p_experiment_id
              AND member.generation = p_source_generation
            GROUP BY member.genome_id
            HAVING trusted_evaluations < v_evaluations_per_genome
        ) incomplete;
        IF v_incomplete_genome_count <> 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Todos os genomas precisam do número configurado de avaliações com ACK';
        END IF;

        DROP TEMPORARY TABLE IF EXISTS tmp_nn_training_v2_ranked;
        CREATE TEMPORARY TABLE tmp_nn_training_v2_ranked (
            genome_id INT NOT NULL,
            session_id CHAR(36) NOT NULL,
            evaluation_rank INT UNSIGNED NOT NULL,
            fitness DECIMAL(14,4) NOT NULL,
            damage_to_player BIGINT UNSIGNED NOT NULL,
            player_kills INT UNSIGNED NOT NULL,
            damage_received BIGINT UNSIGNED NOT NULL,
            npc_deaths INT UNSIGNED NOT NULL,
            survival_seconds BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (genome_id, evaluation_rank),
            KEY idx_tmp_nn_training_v2_ranked_session (session_id)
        ) ENGINE=InnoDB;

        INSERT INTO tmp_nn_training_v2_ranked (
            genome_id, session_id, evaluation_rank, fitness,
            damage_to_player, player_kills, damage_received,
            npc_deaths, survival_seconds
        )
        SELECT evaluation.genome_id, evaluation.session_id,
               ROW_NUMBER() OVER (
                   PARTITION BY evaluation.genome_id
                   ORDER BY completion.completed_at, evaluation.session_id
               ) AS evaluation_rank,
               evaluation.fitness, evaluation.damage_to_player,
               evaluation.player_kills, evaluation.damage_received,
               evaluation.npc_deaths, evaluation.survival_seconds
        FROM nn_genome_evaluation_training_v2 evaluation
        JOIN nn_training_experiment_session_v2 session_v2
          ON session_v2.session_id = evaluation.session_id
         AND session_v2.experiment_id = p_experiment_id
         AND session_v2.generation = p_source_generation
        JOIN nn_training_session_completion_v2 completion
          ON completion.session_id = evaluation.session_id
         AND completion.fitness_version = 'combat_outcome_v2_1'
         AND completion.ack_confirmed_at IS NOT NULL
        JOIN nn_training_experiment_genome_v2 member
          ON member.experiment_id = p_experiment_id
         AND member.generation = p_source_generation
         AND member.genome_id = evaluation.genome_id
        WHERE evaluation.attribution_version = 'neural_attack_provenance_v2'
          AND evaluation.fitness_version = 'combat_outcome_v2_1';

        DROP TEMPORARY TABLE IF EXISTS tmp_nn_training_v2_scores;
        CREATE TEMPORARY TABLE tmp_nn_training_v2_scores (
            genome_id INT PRIMARY KEY,
            evaluations_used SMALLINT UNSIGNED NOT NULL,
            fitness_mean DECIMAL(14,4) NOT NULL,
            fitness_best DECIMAL(14,4) NOT NULL,
            fitness_worst DECIMAL(14,4) NOT NULL,
            damage_to_player BIGINT UNSIGNED NOT NULL,
            player_kills INT UNSIGNED NOT NULL,
            damage_received BIGINT UNSIGNED NOT NULL,
            npc_deaths INT UNSIGNED NOT NULL,
            survival_seconds BIGINT UNSIGNED NOT NULL
        ) ENGINE=InnoDB;

        INSERT INTO tmp_nn_training_v2_scores (
            genome_id, evaluations_used, fitness_mean, fitness_best,
            fitness_worst, damage_to_player, player_kills, damage_received,
            npc_deaths, survival_seconds
        )
        SELECT genome_id, COUNT(*), CAST(AVG(fitness) AS DECIMAL(14,4)),
               MAX(fitness), MIN(fitness), SUM(damage_to_player),
               SUM(player_kills), SUM(damage_received), SUM(npc_deaths),
               SUM(survival_seconds)
        FROM tmp_nn_training_v2_ranked
        WHERE evaluation_rank <= v_evaluations_per_genome
        GROUP BY genome_id;

        SELECT COUNT(*), COALESCE(SUM(evaluations_used), 0),
               AVG(fitness_mean), MAX(fitness_mean), MIN(fitness_mean)
          INTO v_scored_genome_count, v_score_evaluation_count,
               v_fitness_mean, v_best_fitness, v_worst_fitness
        FROM tmp_nn_training_v2_scores;
        IF v_scored_genome_count <> v_population_size
           OR v_score_evaluation_count <> v_population_size * v_evaluations_per_genome THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Resumo v2 não contém todas as avaliações configuradas';
        END IF;

        INSERT INTO nn_training_genome_score_v2 (
            experiment_id, generation, genome_id, evaluations_used,
            fitness_mean, fitness_best, fitness_worst, damage_to_player,
            player_kills, damage_received, npc_deaths, survival_seconds
        )
        SELECT p_experiment_id, p_source_generation, genome_id,
               evaluations_used, fitness_mean, fitness_best, fitness_worst,
               damage_to_player, player_kills, damage_received, npc_deaths,
               survival_seconds
        FROM tmp_nn_training_v2_scores;

        SET v_will_create_children = (p_source_generation + 1 < v_planned_generations);
        SET v_generation_seed = MOD(v_base_seed + p_source_generation + 1, 4294967296);

        IF v_will_create_children = 1 THEN
            DROP TEMPORARY TABLE IF EXISTS tmp_nn_training_v2_elite;
            CREATE TEMPORARY TABLE tmp_nn_training_v2_elite (
                position INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                genome_id INT NOT NULL,
                fitness_mean DECIMAL(14,4) NOT NULL,
                UNIQUE KEY uq_tmp_nn_training_v2_elite_genome (genome_id)
            ) ENGINE=MEMORY;
            INSERT INTO tmp_nn_training_v2_elite (genome_id, fitness_mean)
            SELECT genome_id, fitness_mean
            FROM tmp_nn_training_v2_scores
            ORDER BY fitness_mean DESC, genome_id ASC
            LIMIT p_elite_count;

            INSERT INTO nn_training_generation_v2 (
                experiment_id, generation, seed, mutation_rate, status,
                population_size, evaluations_per_genome
            ) VALUES (
                p_experiment_id, p_source_generation + 1,
                v_generation_seed, v_mutation_rate, 'EVALUATING',
                v_population_size, v_evaluations_per_genome
            );

            SET v_child_index = 0;
            WHILE v_child_index < v_population_size DO
                SET v_parent1_offset = MOD(CRC32(CONCAT(
                    v_generation_seed, ':', p_source_generation, ':', v_child_index, ':P1'
                )), p_elite_count);
                SET v_parent2_offset = MOD(CRC32(CONCAT(
                    v_generation_seed, ':', p_source_generation, ':', v_child_index, ':P2'
                )), p_elite_count - 1);

                SELECT genome_id INTO v_parent1_id
                FROM tmp_nn_training_v2_elite
                ORDER BY fitness_mean DESC, genome_id ASC
                LIMIT v_parent1_offset, 1;
                SELECT genome_id INTO v_parent2_id
                FROM tmp_nn_training_v2_elite
                WHERE genome_id <> v_parent1_id
                ORDER BY fitness_mean DESC, genome_id ASC
                LIMIT v_parent2_offset, 1;

                INSERT INTO nn_genome (
                    architecture_id, geracao, fitness, origem, pai1_id, pai2_id
                ) VALUES (
                    v_architecture_id, p_source_generation + 1,
                    0, 'crossover', v_parent1_id, v_parent2_id
                );
                SET v_child_id = LAST_INSERT_ID();

                SELECT COUNT(*) INTO v_parent_weight_count
                FROM nn_genome_weight WHERE genome_id = v_parent1_id;
                SELECT COUNT(*) INTO v_parent_bias_count
                FROM nn_genome_bias WHERE genome_id = v_parent1_id;

                INSERT INTO nn_genome_weight (genome_id, synapse_id, peso)
                SELECT v_child_id, parent1.synapse_id,
                    CAST(LEAST(1.0, GREATEST(-1.0,
                        CASE
                            WHEN (CRC32(CONCAT(
                                v_generation_seed, ':', p_source_generation, ':', v_child_index,
                                ':W:M:', source_layer.ordem, ':', source_neuron.posicao,
                                ':', target_layer.ordem, ':', target_neuron.posicao
                            )) / 4294967295.0) < v_mutation_rate THEN
                                (CASE WHEN MOD(CRC32(CONCAT(
                                    v_generation_seed, ':', p_source_generation, ':', v_child_index,
                                    ':W:P:', source_layer.ordem, ':', source_neuron.posicao,
                                    ':', target_layer.ordem, ':', target_neuron.posicao
                                )), 2) = 0 THEN parent1.peso ELSE parent2.peso END)
                                + (CRC32(CONCAT(
                                    v_generation_seed, ':', p_source_generation, ':', v_child_index,
                                    ':W:D:', source_layer.ordem, ':', source_neuron.posicao,
                                    ':', target_layer.ordem, ':', target_neuron.posicao
                                )) / 4294967295.0 * 0.5 - 0.25)
                            ELSE CASE WHEN MOD(CRC32(CONCAT(
                                v_generation_seed, ':', p_source_generation, ':', v_child_index,
                                ':W:P:', source_layer.ordem, ':', source_neuron.posicao,
                                ':', target_layer.ordem, ':', target_neuron.posicao
                            )), 2) = 0 THEN parent1.peso ELSE parent2.peso END
                        END
                    )) AS DECIMAL(12,8))
                FROM nn_genome_weight parent1
                JOIN nn_genome_weight parent2
                  ON parent2.synapse_id = parent1.synapse_id
                JOIN nn_synapse synapse ON synapse.id = parent1.synapse_id
                JOIN nn_neuron source_neuron ON source_neuron.id = synapse.from_neuron_id
                JOIN nn_layer source_layer ON source_layer.id = source_neuron.layer_id
                JOIN nn_neuron target_neuron ON target_neuron.id = synapse.to_neuron_id
                JOIN nn_layer target_layer ON target_layer.id = target_neuron.layer_id
                WHERE parent1.genome_id = v_parent1_id
                  AND parent2.genome_id = v_parent2_id;
                SET v_inserted_weight_count = ROW_COUNT();

                INSERT INTO nn_genome_bias (genome_id, neuron_id, bias)
                SELECT v_child_id, parent1.neuron_id,
                    CAST(LEAST(1.0, GREATEST(-1.0,
                        CASE
                            WHEN (CRC32(CONCAT(
                                v_generation_seed, ':', p_source_generation, ':', v_child_index,
                                ':B:M:', layer.ordem, ':', neuron.posicao
                            )) / 4294967295.0) < v_mutation_rate THEN
                                (CASE WHEN MOD(CRC32(CONCAT(
                                    v_generation_seed, ':', p_source_generation, ':', v_child_index,
                                    ':B:P:', layer.ordem, ':', neuron.posicao
                                )), 2) = 0 THEN parent1.bias ELSE parent2.bias END)
                                + (CRC32(CONCAT(
                                    v_generation_seed, ':', p_source_generation, ':', v_child_index,
                                    ':B:D:', layer.ordem, ':', neuron.posicao
                                )) / 4294967295.0 * 0.5 - 0.25)
                            ELSE CASE WHEN MOD(CRC32(CONCAT(
                                v_generation_seed, ':', p_source_generation, ':', v_child_index,
                                ':B:P:', layer.ordem, ':', neuron.posicao
                            )), 2) = 0 THEN parent1.bias ELSE parent2.bias END
                        END
                    )) AS DECIMAL(12,8))
                FROM nn_genome_bias parent1
                JOIN nn_genome_bias parent2
                  ON parent2.neuron_id = parent1.neuron_id
                JOIN nn_neuron neuron ON neuron.id = parent1.neuron_id
                JOIN nn_layer layer ON layer.id = neuron.layer_id
                WHERE parent1.genome_id = v_parent1_id
                  AND parent2.genome_id = v_parent2_id;
                SET v_inserted_bias_count = ROW_COUNT();

                IF v_inserted_weight_count <> v_parent_weight_count
                   OR v_inserted_bias_count <> v_parent_bias_count THEN
                    SIGNAL SQLSTATE '45000'
                        SET MESSAGE_TEXT = 'Crossover não copiou todos os pesos e biases dos pais';
                END IF;

                SELECT
                    (SELECT COUNT(*)
                     FROM nn_genome_weight child_weight
                     JOIN nn_genome_weight parent1_weight
                       ON parent1_weight.genome_id = v_parent1_id
                      AND parent1_weight.synapse_id = child_weight.synapse_id
                     JOIN nn_genome_weight parent2_weight
                       ON parent2_weight.genome_id = v_parent2_id
                      AND parent2_weight.synapse_id = child_weight.synapse_id
                     WHERE child_weight.genome_id = v_child_id
                       AND NOT (child_weight.peso <=> parent1_weight.peso)
                       AND NOT (child_weight.peso <=> parent2_weight.peso))
                    +
                    (SELECT COUNT(*)
                     FROM nn_genome_bias child_bias
                     JOIN nn_genome_bias parent1_bias
                       ON parent1_bias.genome_id = v_parent1_id
                      AND parent1_bias.neuron_id = child_bias.neuron_id
                     JOIN nn_genome_bias parent2_bias
                       ON parent2_bias.genome_id = v_parent2_id
                      AND parent2_bias.neuron_id = child_bias.neuron_id
                     WHERE child_bias.genome_id = v_child_id
                       AND NOT (child_bias.bias <=> parent1_bias.bias)
                       AND NOT (child_bias.bias <=> parent2_bias.bias))
                INTO v_mutated_gene_count;
                IF v_mutated_gene_count > 0 THEN
                    UPDATE nn_genome
                    SET origem = 'mutacao'
                    WHERE id = v_child_id;
                END IF;

                INSERT INTO nn_training_experiment_genome_v2 (
                    experiment_id, generation, genome_id,
                    parent1_genome_id, parent2_genome_id
                ) VALUES (
                    p_experiment_id, p_source_generation + 1,
                    v_child_id, v_parent1_id, v_parent2_id
                );
                SET v_child_index = v_child_index + 1;
            END WHILE;

            SELECT COUNT(*) INTO v_child_count
            FROM nn_genome
            WHERE architecture_id = v_architecture_id
              AND geracao = p_source_generation + 1;
            SELECT COUNT(*) INTO v_child_member_count
            FROM nn_training_experiment_genome_v2
            WHERE experiment_id = p_experiment_id
              AND generation = p_source_generation + 1;
            IF v_child_count <> v_population_size
               OR v_child_member_count <> v_population_size THEN
                SIGNAL SQLSTATE '45000'
                    SET MESSAGE_TEXT = 'A geração filha não preservou o tamanho da população';
            END IF;
        END IF;

        UPDATE nn_training_generation_v2
        SET status = CASE WHEN v_will_create_children = 1 THEN 'EVOLVED' ELSE 'COMPLETE' END,
            elite_count = p_elite_count,
            evaluated_genomes = v_scored_genome_count,
            evaluation_count = v_score_evaluation_count,
            fitness_mean = v_fitness_mean,
            best_fitness = v_best_fitness,
            worst_fitness = v_worst_fitness,
            completed_at = CURRENT_TIMESTAMP(6)
        WHERE experiment_id = p_experiment_id
          AND generation = p_source_generation;

        DROP TEMPORARY TABLE IF EXISTS tmp_nn_training_v2_ranked;
        DROP TEMPORARY TABLE IF EXISTS tmp_nn_training_v2_scores;
        DROP TEMPORARY TABLE IF EXISTS tmp_nn_training_v2_elite;
        COMMIT;
    END evolve_generation;

    SELECT experiment_id, generation, status, seed, elite_count,
           population_size, evaluations_per_genome, evaluated_genomes,
           evaluation_count, fitness_mean, best_fitness, worst_fitness,
           completed_at, v_already_done AS already_completed
    FROM nn_training_generation_v2
    WHERE experiment_id = p_experiment_id AND generation = p_source_generation;
END$$
DELIMITER ;

SELECT 'OK: evolução v2 consome somente fitness versionado com ACK confirmado; fitness legado não é alterado.' AS result;
