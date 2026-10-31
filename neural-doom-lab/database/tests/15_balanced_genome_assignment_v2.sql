-- Synthetic SQL-only fixture. It verifies balanced v2 roster assignment and
-- must never be reported as real game or learning evidence.
DROP PROCEDURE IF EXISTS test_nn_balanced_genome_assignment_v2;
DELIMITER $$
CREATE PROCEDURE test_nn_balanced_genome_assignment_v2()
BEGIN
    DECLARE v_suffix CHAR(8) DEFAULT NULL;
    DECLARE v_experiment_name VARCHAR(80) DEFAULT NULL;
    DECLARE v_architecture_name VARCHAR(50) DEFAULT NULL;
    DECLARE v_experiment_id CHAR(36) DEFAULT NULL;
    DECLARE v_session_id CHAR(36) DEFAULT NULL;
    DECLARE v_ack_token CHAR(36) DEFAULT NULL;
    DECLARE v_run_id BIGINT DEFAULT NULL;
    DECLARE v_action VARCHAR(16) DEFAULT NULL;
    DECLARE v_confidence DOUBLE DEFAULT NULL;
    DECLARE v_session_index INT DEFAULT 0;
    DECLARE v_npc_index INT DEFAULT 0;
    DECLARE v_npc_id VARCHAR(64) DEFAULT NULL;
    DECLARE v_distinct_genomes INT DEFAULT 0;
    DECLARE v_under_evaluated_genomes INT DEFAULT 0;
    DECLARE v_ack_count INT DEFAULT 0;
    DECLARE v_bad_rosters INT DEFAULT 0;
    DECLARE v_member_count INT DEFAULT 0;
    DECLARE v_score_count INT DEFAULT 0;
    DECLARE v_generation_status VARCHAR(16) DEFAULT NULL;
    DECLARE v_generation_one_members INT DEFAULT 0;
    DECLARE v_decisions INT DEFAULT 0;

    IF DATABASE() <> 'neural_doom_local_sql_test_20261024' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Este teste só pode rodar no schema SQL de testes isolado';
    END IF;

    SET v_suffix = LEFT(REPLACE(UUID(), '-', ''), 8);
    SET v_experiment_name = CONCAT('sql_v2_roster_', v_suffix);
    SET v_architecture_name = CONCAT('sql_v2_roster_', v_suffix);

    CALL sp_nn_create_genetic_experiment_v2(
        v_experiment_name, v_architecture_name, JSON_ARRAY(4, 6, 4), 'relu',
        2026103115, 8, 0.050000, 2, 1,
        'fixture SQL sintética: distribuição de roster; não é partida',
        v_experiment_id
    );

    -- Each isolated synthetic session contains only three NPCs. After each
    -- ACK the next session must prioritize genotypes with fewer trusted runs.
    WHILE v_session_index < 3 DO
        SET v_session_id = UUID();
        SET v_ack_token = NULL;
        SET v_npc_index = 0;
        WHILE v_npc_index < 3 DO
            SET v_npc_id = CONCAT(
                'roster-', v_suffix, '-', v_session_index, '-', v_npc_index
            );
            CALL sp_nn_decide_for_architecture(
                v_architecture_name, v_session_id, v_npc_id, 1,
                100, 100, 512, 1, 0,
                v_run_id, v_action, v_confidence
            );
            IF v_run_id IS NULL OR v_action NOT IN ('IDLE', 'CHASE', 'ATTACK', 'FLEE') THEN
                SIGNAL SQLSTATE '45001'
                    SET MESSAGE_TEXT = 'Decisão SQL sintética para atribuição v2 falhou';
            END IF;
            SET v_decisions = v_decisions + 1;

            IF v_npc_index = 0 THEN
                CALL sp_nn_mark_session_v2(v_session_id);
                CALL sp_nn_register_training_session_v2(v_session_id);
            END IF;
            CALL sp_nn_record_combat_event(
                UUID(), v_session_id, v_npc_id, 'PLAYER_DAMAGE', 10
            );
            SET v_npc_index = v_npc_index + 1;
        END WHILE;

        CALL sp_nn_finish_session_training_v2(v_session_id, v_ack_token);
        CALL sp_nn_confirm_training_ack_v2(v_session_id, v_ack_token);
        SET v_session_index = v_session_index + 1;
    END WHILE;

    SELECT COUNT(DISTINCT member.genome_id) INTO v_distinct_genomes
    FROM nn_training_experiment_genome_v2 member
    JOIN nn_training_experiment_session_v2 session_v2
      ON session_v2.experiment_id = member.experiment_id
     AND session_v2.generation = member.generation
    JOIN nn_session_npc npc ON npc.session_id = session_v2.session_id
                          AND npc.genome_id = member.genome_id
    WHERE member.experiment_id = v_experiment_id AND member.generation = 0;

    SELECT COUNT(*) INTO v_under_evaluated_genomes
    FROM nn_training_experiment_genome_v2 member
    WHERE member.experiment_id = v_experiment_id AND member.generation = 0
      AND (
          SELECT COUNT(DISTINCT evaluation.session_id)
          FROM nn_genome_evaluation_training_v2 evaluation
          JOIN nn_training_experiment_session_v2 session_v2
            ON session_v2.session_id = evaluation.session_id
          JOIN nn_training_session_completion_v2 completion
            ON completion.session_id = evaluation.session_id
           AND completion.ack_confirmed_at IS NOT NULL
           AND completion.fitness_version = 'combat_outcome_v2_1'
          WHERE session_v2.experiment_id = member.experiment_id
            AND session_v2.generation = member.generation
            AND evaluation.genome_id = member.genome_id
            AND evaluation.attribution_version = 'neural_attack_provenance_v2'
            AND evaluation.fitness_version = 'combat_outcome_v2_1'
      ) < 1;

    SELECT COUNT(*) INTO v_ack_count
    FROM nn_training_experiment_session_v2 session_v2
    JOIN nn_training_session_completion_v2 completion
      ON completion.session_id = session_v2.session_id
     AND completion.ack_confirmed_at IS NOT NULL
    WHERE session_v2.experiment_id = v_experiment_id AND session_v2.generation = 0;

    SELECT COUNT(*) INTO v_bad_rosters
    FROM (
        SELECT session_v2.session_id
        FROM nn_training_experiment_session_v2 session_v2
        LEFT JOIN nn_session_npc npc ON npc.session_id = session_v2.session_id
        WHERE session_v2.experiment_id = v_experiment_id AND session_v2.generation = 0
        GROUP BY session_v2.session_id
        HAVING COUNT(npc.engine_npc_id) <> 3
    ) bad_roster;

    SELECT COUNT(*) INTO v_member_count
    FROM nn_training_experiment_genome_v2
    WHERE experiment_id = v_experiment_id AND generation = 0;
    IF v_distinct_genomes <> 8 OR v_under_evaluated_genomes <> 0
       OR v_ack_count <> 3 OR v_bad_rosters <> 0 OR v_member_count <> 8
       OR v_decisions <> 9 THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Rosters parciais não foram balanceados por avaliações ACK-confirmadas';
    END IF;

    CALL sp_nn_evolve_training_experiment_v2(v_experiment_id, 0, 2);
    SELECT status INTO v_generation_status
    FROM nn_training_generation_v2
    WHERE experiment_id = v_experiment_id AND generation = 0;
    SELECT COUNT(*) INTO v_score_count
    FROM nn_training_genome_score_v2
    WHERE experiment_id = v_experiment_id AND generation = 0;
    SELECT COUNT(*) INTO v_generation_one_members
    FROM nn_training_experiment_genome_v2
    WHERE experiment_id = v_experiment_id AND generation = 1;

    IF v_generation_status <> 'EVOLVED' OR v_score_count <> 8
       OR v_generation_one_members <> 8 THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Rosters balanceados não produziram evolução v2 completa';
    END IF;

    SELECT 'OK: 3 rosters SQL sintéticos de 3 NPCs cobriram 8 genomas e liberaram evolução; não são partidas.' AS result;
END$$

CALL test_nn_balanced_genome_assignment_v2()$$
DROP PROCEDURE test_nn_balanced_genome_assignment_v2$$
DELIMITER ;
