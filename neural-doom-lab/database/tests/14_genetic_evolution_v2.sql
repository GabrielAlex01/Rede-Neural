-- Synthetic SQL fixtures for the isolated SQL-test schema only.
-- They validate ACK gating, score selection, seeded crossover and lineage;
-- they are not gameplay or learning evidence.
DROP PROCEDURE IF EXISTS test_nn_training_v2_make_session;
DROP PROCEDURE IF EXISTS test_nn_genetic_evolution_v2;
DELIMITER $$
CREATE PROCEDURE test_nn_training_v2_make_session(
    IN p_experiment_id CHAR(36),
    IN p_generation INT,
    IN p_close_immediately TINYINT,
    OUT p_session_id CHAR(36),
    OUT p_ack_token CHAR(36)
)
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_population_size INT DEFAULT 0;
    DECLARE v_genome_id INT DEFAULT NULL;
    DECLARE v_npc_index INT DEFAULT 0;
    DECLARE v_npc_id VARCHAR(64) DEFAULT NULL;
    DECLARE v_damage INT DEFAULT 0;

    SELECT architecture_id, population_size
      INTO v_architecture_id, v_population_size
    FROM nn_training_experiment_v2
    WHERE experiment_id = p_experiment_id;
    SET p_session_id = UUID();
    SET p_ack_token = NULL;

    INSERT INTO nn_engine_session (session_id, architecture_id)
    VALUES (p_session_id, v_architecture_id);

    WHILE v_npc_index < v_population_size DO
        SELECT genome_id INTO v_genome_id
        FROM nn_training_experiment_genome_v2
        WHERE experiment_id = p_experiment_id
          AND generation = p_generation
        ORDER BY genome_id
        LIMIT v_npc_index, 1;
        SET v_npc_id = CONCAT(
            'v2-fixture-', LEFT(p_experiment_id, 8), '-g', p_generation,
            '-n', v_npc_index, '-', LEFT(p_session_id, 8)
        );
        SET v_damage = CASE WHEN p_generation = 0
            THEN 100 - (v_npc_index * 20)
            ELSE 80 - (v_npc_index * 10)
        END;
        INSERT INTO nn_session_npc (
            session_id, engine_npc_id, npc_type, genome_id, max_health, last_health
        ) VALUES (
            p_session_id, v_npc_id, 1, v_genome_id, 100, 100
        );
        CALL sp_nn_record_combat_event(
            UUID(), p_session_id, v_npc_id, 'PLAYER_DAMAGE', v_damage
        );
        SET v_npc_index = v_npc_index + 1;
    END WHILE;

    CALL sp_nn_mark_session_v2(p_session_id);
    CALL sp_nn_register_training_session_v2(p_session_id);
    IF p_close_immediately = 1 THEN
        CALL sp_nn_finish_session_training_v2(p_session_id, p_ack_token);
        CALL sp_nn_confirm_training_ack_v2(p_session_id, p_ack_token);
    END IF;
END$$

CREATE PROCEDURE test_nn_genetic_evolution_v2()
BEGIN
    DECLARE v_suffix CHAR(8) DEFAULT NULL;
    DECLARE v_exp_name_a VARCHAR(80) DEFAULT NULL;
    DECLARE v_exp_name_b VARCHAR(80) DEFAULT NULL;
    DECLARE v_arch_name_a VARCHAR(50) DEFAULT NULL;
    DECLARE v_arch_name_b VARCHAR(50) DEFAULT NULL;
    DECLARE v_condition VARCHAR(120) DEFAULT 'fixture SQL sintética: crossover reproduzível';
    DECLARE v_experiment_a CHAR(36) DEFAULT NULL;
    DECLARE v_experiment_b CHAR(36) DEFAULT NULL;
    DECLARE v_session_a CHAR(36) DEFAULT NULL;
    DECLARE v_session_b CHAR(36) DEFAULT NULL;
    DECLARE v_pending_ack CHAR(36) DEFAULT NULL;
    DECLARE v_ack_b CHAR(36) DEFAULT NULL;
    DECLARE v_ack_final_a CHAR(36) DEFAULT NULL;
    DECLARE v_ack_final_b CHAR(36) DEFAULT NULL;
    DECLARE v_untrusted_session CHAR(36) DEFAULT NULL;
    DECLARE v_token CHAR(36) DEFAULT NULL;
    DECLARE v_architecture_a INT DEFAULT NULL;
    DECLARE v_untrusted_genome INT DEFAULT NULL;
    DECLARE v_reference_genome INT DEFAULT NULL;
    DECLARE v_reference_fitness_before DECIMAL(10,4) DEFAULT NULL;
    DECLARE v_reference_fitness_after DECIMAL(10,4) DEFAULT NULL;
    DECLARE v_legacy_evaluations_before INT DEFAULT 0;
    DECLARE v_legacy_evaluations_after INT DEFAULT 0;
    DECLARE v_evolution_blocked INT DEFAULT 0;
    DECLARE v_pending_generation_status VARCHAR(16) DEFAULT NULL;
    DECLARE v_generation0_status_a VARCHAR(16) DEFAULT NULL;
    DECLARE v_generation0_status_b VARCHAR(16) DEFAULT NULL;
    DECLARE v_generation1_status_a VARCHAR(16) DEFAULT NULL;
    DECLARE v_generation1_status_b VARCHAR(16) DEFAULT NULL;
    DECLARE v_generation0_members_a INT DEFAULT 0;
    DECLARE v_generation1_members_a INT DEFAULT 0;
    DECLARE v_generation1_members_b INT DEFAULT 0;
    DECLARE v_score_count_a INT DEFAULT 0;
    DECLARE v_score_count_b INT DEFAULT 0;
    DECLARE v_untrusted_score DECIMAL(14,4) DEFAULT NULL;
    DECLARE v_bad_parent_count INT DEFAULT 0;
    DECLARE v_bad_gene_count INT DEFAULT 0;
    DECLARE v_nonzero_genome_fitness_count INT DEFAULT 0;
    DECLARE v_signature_pairs INT DEFAULT 0;
    DECLARE v_signature_mismatches INT DEFAULT 0;
    DECLARE v_group_concat_max_len BIGINT DEFAULT 0;

    IF DATABASE() <> 'neural_doom_local_sql_test_20261024' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Este teste só pode rodar no schema SQL de testes isolado';
    END IF;

    SET v_suffix = LEFT(REPLACE(UUID(), '-', ''), 8);
    SET v_untrusted_session = UUID();
    SET v_exp_name_a = CONCAT('sql_v2_evo_a_', v_suffix);
    SET v_exp_name_b = CONCAT('sql_v2_evo_b_', v_suffix);
    SET v_arch_name_a = CONCAT('sqlv2evo_a_', v_suffix);
    SET v_arch_name_b = CONCAT('sqlv2evo_b_', v_suffix);
    SELECT id, fitness INTO v_reference_genome, v_reference_fitness_before
    FROM nn_genome
    WHERE architecture_id = (
        SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4'
    )
    ORDER BY id LIMIT 1;
    SELECT COUNT(*) INTO v_legacy_evaluations_before FROM nn_genome_evaluation;

    CALL sp_nn_create_genetic_experiment_v2(
        v_exp_name_a, v_arch_name_a, JSON_ARRAY(4,6,4), 'relu',
        2026103111, 4, 0.050000, 2, 1, v_condition, v_experiment_a
    );
    CALL sp_nn_create_genetic_experiment_v2(
        v_exp_name_b, v_arch_name_b, JSON_ARRAY(4,6,4), 'relu',
        2026103111, 4, 0.050000, 2, 1, v_condition, v_experiment_b
    );
    SELECT architecture_id INTO v_architecture_a
    FROM nn_training_experiment_v2 WHERE experiment_id = v_experiment_a;
    SELECT MIN(genome_id) INTO v_untrusted_genome
    FROM nn_training_experiment_genome_v2
    WHERE experiment_id = v_experiment_a AND generation = 0;

    -- A raw v2 evaluation with an intentionally large score is not in the
    -- registered experiment and must not influence genetic selection.
    INSERT INTO nn_engine_session (session_id, architecture_id)
    VALUES (v_untrusted_session, v_architecture_a);
    INSERT INTO nn_session_npc (
        session_id, engine_npc_id, npc_type, genome_id, max_health, last_health
    ) VALUES (
        v_untrusted_session, 'v2-unregistered-high-score', 1,
        v_untrusted_genome, 100, 100
    );
    CALL sp_nn_mark_session_v2(v_untrusted_session);
    CALL sp_nn_record_combat_event(
        UUID(), v_untrusted_session, 'v2-unregistered-high-score', 'PLAYER_DAMAGE', 20000
    );
    CALL sp_nn_finish_session_v2(v_untrusted_session);

    -- Keep A open for one call to prove that missing ACKs block evolution.
    CALL test_nn_training_v2_make_session(
        v_experiment_a, 0, 0, v_session_a, v_pending_ack
    );
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_evolution_blocked = 1;
        CALL sp_nn_evolve_training_experiment_v2(v_experiment_a, 0, 2);
    END;
    SELECT status INTO v_pending_generation_status
    FROM nn_training_generation_v2
    WHERE experiment_id = v_experiment_a AND generation = 0;
    IF v_evolution_blocked <> 1 OR v_pending_generation_status <> 'EVALUATING' THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Sessão sem ACK não bloqueou a evolução v2';
    END IF;
    CALL sp_nn_finish_session_training_v2(v_session_a, v_pending_ack);
    CALL sp_nn_confirm_training_ack_v2(v_session_a, v_pending_ack);

    CALL test_nn_training_v2_make_session(
        v_experiment_b, 0, 1, v_session_b, v_ack_b
    );
    CALL sp_nn_evolve_training_experiment_v2(v_experiment_a, 0, 2);
    CALL sp_nn_evolve_training_experiment_v2(v_experiment_b, 0, 2);
    -- A retry must return the stored result instead of duplicating children.
    CALL sp_nn_evolve_training_experiment_v2(v_experiment_a, 0, 2);

    SELECT status INTO v_generation0_status_a
    FROM nn_training_generation_v2
    WHERE experiment_id = v_experiment_a AND generation = 0;
    SELECT status INTO v_generation0_status_b
    FROM nn_training_generation_v2
    WHERE experiment_id = v_experiment_b AND generation = 0;
    SELECT COUNT(*) INTO v_generation0_members_a
    FROM nn_training_experiment_genome_v2
    WHERE experiment_id = v_experiment_a AND generation = 0;
    SELECT COUNT(*) INTO v_generation1_members_a
    FROM nn_training_experiment_genome_v2
    WHERE experiment_id = v_experiment_a AND generation = 1;
    SELECT COUNT(*) INTO v_generation1_members_b
    FROM nn_training_experiment_genome_v2
    WHERE experiment_id = v_experiment_b AND generation = 1;
    SELECT COUNT(*), MAX(fitness_mean) INTO v_score_count_a, v_untrusted_score
    FROM nn_training_genome_score_v2
    WHERE experiment_id = v_experiment_a AND generation = 0;
    SELECT COUNT(*) INTO v_score_count_b
    FROM nn_training_genome_score_v2
    WHERE experiment_id = v_experiment_b AND generation = 0;

    -- The unregistered 20000 event cannot appear in the trusted score.
    SELECT fitness_mean INTO v_untrusted_score
    FROM nn_training_genome_score_v2
    WHERE experiment_id = v_experiment_a
      AND generation = 0 AND genome_id = v_untrusted_genome;

    SELECT COUNT(*) INTO v_bad_parent_count
    FROM nn_training_experiment_genome_v2 child
    JOIN nn_genome child_genome ON child_genome.id = child.genome_id
    LEFT JOIN nn_training_genome_score_v2 parent1_score
      ON parent1_score.experiment_id = child.experiment_id
     AND parent1_score.generation = 0
     AND parent1_score.genome_id = child.parent1_genome_id
    LEFT JOIN nn_training_genome_score_v2 parent2_score
      ON parent2_score.experiment_id = child.experiment_id
     AND parent2_score.generation = 0
     AND parent2_score.genome_id = child.parent2_genome_id
    WHERE child.experiment_id = v_experiment_a
      AND child.generation = 1
      AND (
          child.parent1_genome_id <> child_genome.pai1_id
          OR child.parent2_genome_id <> child_genome.pai2_id
          OR child.parent1_genome_id = child.parent2_genome_id
          OR parent1_score.genome_id IS NULL OR parent2_score.genome_id IS NULL
          OR parent1_score.fitness_mean < (
              SELECT MIN(elite.fitness_mean)
              FROM (
                  SELECT fitness_mean
                  FROM nn_training_genome_score_v2
                  WHERE experiment_id = v_experiment_a AND generation = 0
                  ORDER BY fitness_mean DESC, genome_id ASC LIMIT 2
              ) elite
          )
          OR parent2_score.fitness_mean < (
              SELECT MIN(elite.fitness_mean)
              FROM (
                  SELECT fitness_mean
                  FROM nn_training_genome_score_v2
                  WHERE experiment_id = v_experiment_a AND generation = 0
                  ORDER BY fitness_mean DESC, genome_id ASC LIMIT 2
              ) elite
          )
      );

    SELECT @@SESSION.group_concat_max_len INTO v_group_concat_max_len;
    SET SESSION group_concat_max_len = 100000;
    DROP TEMPORARY TABLE IF EXISTS tmp_nn_v2_gene_signatures;
    CREATE TEMPORARY TABLE tmp_nn_v2_gene_signatures (
        experiment_id CHAR(36) NOT NULL,
        generation INT UNSIGNED NOT NULL,
        child_ordinal INT UNSIGNED NOT NULL,
        signature CHAR(64) NOT NULL,
        PRIMARY KEY (experiment_id, generation, child_ordinal)
    ) ENGINE=InnoDB;
    INSERT INTO tmp_nn_v2_gene_signatures (
        experiment_id, generation, child_ordinal, signature
    )
    SELECT ordered_members.experiment_id, ordered_members.generation,
           ordered_members.child_ordinal,
           SHA2(CONCAT(
               COALESCE((
                   SELECT GROUP_CONCAT(
                       CONCAT(source_layer.ordem, ':', source_neuron.posicao,
                              '>', target_layer.ordem, ':', target_neuron.posicao,
                              '=', CAST(weight.peso AS CHAR))
                       ORDER BY source_layer.ordem, source_neuron.posicao,
                                target_layer.ordem, target_neuron.posicao
                       SEPARATOR ';'
                   )
                   FROM nn_genome_weight weight
                   JOIN nn_synapse synapse ON synapse.id = weight.synapse_id
                   JOIN nn_neuron source_neuron ON source_neuron.id = synapse.from_neuron_id
                   JOIN nn_layer source_layer ON source_layer.id = source_neuron.layer_id
                   JOIN nn_neuron target_neuron ON target_neuron.id = synapse.to_neuron_id
                   JOIN nn_layer target_layer ON target_layer.id = target_neuron.layer_id
                   WHERE weight.genome_id = ordered_members.genome_id
               ), ''), '#',
               COALESCE((
                   SELECT GROUP_CONCAT(
                       CONCAT(layer.ordem, ':', neuron.posicao, '=', CAST(bias.bias AS CHAR))
                       ORDER BY layer.ordem, neuron.posicao SEPARATOR ';'
                   )
                   FROM nn_genome_bias bias
                   JOIN nn_neuron neuron ON neuron.id = bias.neuron_id
                   JOIN nn_layer layer ON layer.id = neuron.layer_id
                   WHERE bias.genome_id = ordered_members.genome_id
               ), '')
           ), 256)
    FROM (
        SELECT experiment_id, generation, genome_id,
               ROW_NUMBER() OVER (
                   PARTITION BY experiment_id, generation ORDER BY genome_id
               ) AS child_ordinal
        FROM nn_training_experiment_genome_v2
        WHERE experiment_id IN (v_experiment_a, v_experiment_b)
          AND generation IN (0, 1)
    ) ordered_members;
    SET SESSION group_concat_max_len = v_group_concat_max_len;

    -- MySQL cannot reopen one temporary table twice in the same query. Copy
    -- experiment B into its own temporary table before comparing signatures.
    DROP TEMPORARY TABLE IF EXISTS tmp_nn_v2_gene_signatures_b;
    CREATE TEMPORARY TABLE tmp_nn_v2_gene_signatures_b (
        generation INT UNSIGNED NOT NULL,
        child_ordinal INT UNSIGNED NOT NULL,
        signature CHAR(64) NOT NULL,
        PRIMARY KEY (generation, child_ordinal)
    ) ENGINE=InnoDB;
    INSERT INTO tmp_nn_v2_gene_signatures_b (
        generation, child_ordinal, signature
    )
    SELECT generation, child_ordinal, signature
    FROM tmp_nn_v2_gene_signatures
    WHERE experiment_id = v_experiment_b;

    SELECT COUNT(*), SUM(signature_a.signature <> signature_b.signature)
      INTO v_signature_pairs, v_signature_mismatches
    FROM tmp_nn_v2_gene_signatures signature_a
    JOIN tmp_nn_v2_gene_signatures_b signature_b
      ON signature_b.generation = signature_a.generation
     AND signature_b.child_ordinal = signature_a.child_ordinal
    WHERE signature_a.experiment_id = v_experiment_a
      ;

    SELECT COUNT(*) INTO v_bad_gene_count
    FROM nn_training_experiment_genome_v2 child
    LEFT JOIN nn_genome_weight weight ON weight.genome_id = child.genome_id
    LEFT JOIN nn_genome_bias bias ON bias.genome_id = child.genome_id
    WHERE child.experiment_id IN (v_experiment_a, v_experiment_b)
      AND child.generation = 1
      AND (
          weight.peso < -1 OR weight.peso > 1
          OR bias.bias < -1 OR bias.bias > 1
      );
    SELECT COUNT(*) INTO v_nonzero_genome_fitness_count
    FROM nn_training_experiment_genome_v2 member
    JOIN nn_genome genome ON genome.id = member.genome_id
    WHERE member.experiment_id IN (v_experiment_a, v_experiment_b)
      AND genome.fitness <> 0;

    -- Evaluate generation 1 and finalize the planned two-generation runs.
    CALL test_nn_training_v2_make_session(
        v_experiment_a, 1, 1, v_session_a, v_ack_final_a
    );
    CALL test_nn_training_v2_make_session(
        v_experiment_b, 1, 1, v_session_b, v_ack_final_b
    );
    CALL sp_nn_evolve_training_experiment_v2(v_experiment_a, 1, 2);
    CALL sp_nn_evolve_training_experiment_v2(v_experiment_b, 1, 2);
    SELECT status INTO v_generation1_status_a
    FROM nn_training_generation_v2
    WHERE experiment_id = v_experiment_a AND generation = 1;
    SELECT status INTO v_generation1_status_b
    FROM nn_training_generation_v2
    WHERE experiment_id = v_experiment_b AND generation = 1;

    SELECT COUNT(*) INTO v_legacy_evaluations_after FROM nn_genome_evaluation;
    SELECT fitness INTO v_reference_fitness_after
    FROM nn_genome WHERE id = v_reference_genome;

    IF v_experiment_a = v_experiment_b OR v_session_a IS NULL OR v_session_b IS NULL
       OR v_evolution_blocked <> 1
       OR v_pending_ack IS NULL OR v_ack_b IS NULL
       OR v_ack_final_a IS NULL OR v_ack_final_b IS NULL
       OR v_generation0_status_a <> 'EVOLVED'
       OR v_generation0_status_b <> 'EVOLVED'
       OR v_generation1_status_a <> 'COMPLETE'
       OR v_generation1_status_b <> 'COMPLETE'
       OR v_generation0_members_a <> 4
       OR v_generation1_members_a <> 4 OR v_generation1_members_b <> 4
       OR v_score_count_a <> 4 OR v_score_count_b <> 4
       OR v_untrusted_score IS NULL OR v_untrusted_score >= 1000
       OR v_bad_parent_count <> 0 OR v_bad_gene_count <> 0
       OR v_nonzero_genome_fitness_count <> 0
       OR v_signature_pairs <> 8 OR v_signature_mismatches <> 0
       OR v_legacy_evaluations_after <> v_legacy_evaluations_before
       OR v_reference_fitness_after <> v_reference_fitness_before THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Evolução v2, gating de ACK, crossover reproduzível ou isolamento legado falhou';
    END IF;

    DROP TEMPORARY TABLE IF EXISTS tmp_nn_v2_gene_signatures;
    DROP TEMPORARY TABLE IF EXISTS tmp_nn_v2_gene_signatures_b;
    SELECT 'OK: fixtures SQL sintéticas passaram ACK gating, seleção, crossover reproduzível, limites e finalização; não são partidas.' AS result;
END$$

CALL test_nn_genetic_evolution_v2()$$
DROP PROCEDURE test_nn_genetic_evolution_v2$$
DROP PROCEDURE test_nn_training_v2_make_session$$
DELIMITER ;
