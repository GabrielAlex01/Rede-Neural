-- Synthetic SQL fixture for the isolated SQL-test schema only.
-- This checks versioning/ACK behavior; it is not gameplay or learning evidence.
DROP PROCEDURE IF EXISTS test_nn_training_integrity_v2;
DELIMITER $$
CREATE PROCEDURE test_nn_training_integrity_v2()
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_genome_id INT DEFAULT NULL;
    DECLARE v_session_id CHAR(36) DEFAULT UUID();
    DECLARE v_unregistered_session_id CHAR(36) DEFAULT UUID();
    DECLARE v_ack_token CHAR(36) DEFAULT NULL;
    DECLARE v_ack_token_retry CHAR(36) DEFAULT NULL;
    DECLARE v_unregistered_ack CHAR(36) DEFAULT 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    DECLARE v_wrong_ack_rejected INT DEFAULT 0;
    DECLARE v_registration_retroactive_rejected INT DEFAULT 0;
    DECLARE v_fitness DECIMAL(14,4) DEFAULT NULL;
    DECLARE v_expected_fitness DECIMAL(14,4) DEFAULT NULL;
    DECLARE v_source_rows BIGINT DEFAULT 0;
    DECLARE v_training_rows BIGINT DEFAULT 0;
    DECLARE v_training_rows_before BIGINT DEFAULT 0;
    DECLARE v_legacy_rows_before BIGINT DEFAULT 0;
    DECLARE v_legacy_rows_after BIGINT DEFAULT 0;
    DECLARE v_legacy_fitness_before DECIMAL(10,4) DEFAULT NULL;
    DECLARE v_legacy_fitness_after DECIMAL(10,4) DEFAULT NULL;
    DECLARE v_ack_confirmed INT DEFAULT 0;

    IF DATABASE() <> 'neural_doom_local_sql_test_20261024' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Este teste só pode rodar no schema SQL de testes isolado';
    END IF;

    SELECT id INTO v_architecture_id
    FROM nn_architecture WHERE nome = 'npc_teste_4_6_4';
    SELECT id, fitness INTO v_genome_id, v_legacy_fitness_before
    FROM nn_genome
    WHERE architecture_id = v_architecture_id
    ORDER BY geracao DESC, id
    LIMIT 1;
    IF v_architecture_id IS NULL OR v_genome_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Fixture SQL de arquitetura/genoma ausente';
    END IF;

    SELECT COUNT(*) INTO v_training_rows_before
    FROM nn_genome_evaluation_training_v2;
    SELECT COUNT(*) INTO v_legacy_rows_before
    FROM nn_genome_evaluation WHERE genome_id = v_genome_id;

    INSERT INTO nn_engine_session (session_id, architecture_id)
    VALUES (v_session_id, v_architecture_id);
    INSERT INTO nn_session_npc (
        session_id, engine_npc_id, npc_type, genome_id, max_health, last_health
    ) VALUES (v_session_id, 'training-integrity-sql-fixture', 1, v_genome_id, 100, 100);
    CALL sp_nn_mark_session_v2(v_session_id);
    CALL sp_nn_register_training_session_v2(v_session_id);

    CALL sp_nn_record_combat_event(UUID(), v_session_id, 'training-integrity-sql-fixture', 'PLAYER_DAMAGE', 37);
    CALL sp_nn_record_combat_event(UUID(), v_session_id, 'training-integrity-sql-fixture', 'PLAYER_KILL', 1);
    CALL sp_nn_record_combat_event(UUID(), v_session_id, 'training-integrity-sql-fixture', 'NPC_DAMAGE', 12);
    CALL sp_nn_record_combat_event(UUID(), v_session_id, 'training-integrity-sql-fixture', 'NPC_DEATH', 1);

    CALL sp_nn_finish_session_training_v2(v_session_id, v_ack_token);
    CALL sp_nn_finish_session_training_v2(v_session_id, v_ack_token_retry);

    SELECT COUNT(*), MAX(e.fitness), MAX(CAST(
        e.damage_to_player + (e.player_kills * 100.0)
        - (e.damage_received * 0.25) - (e.npc_deaths * 50.0)
        + (e.survival_seconds / 60.0) AS DECIMAL(14,4)
    )) INTO v_training_rows, v_fitness, v_expected_fitness
    FROM nn_genome_evaluation_training_v2 e
    WHERE e.session_id = v_session_id
      AND e.genome_id = v_genome_id
      AND e.attribution_version = 'neural_attack_provenance_v2'
      AND e.fitness_version = 'combat_outcome_v2_1';

    SELECT COUNT(*) INTO v_source_rows
    FROM nn_genome_evaluation_v2
    WHERE session_id = v_session_id AND genome_id = v_genome_id;
    SELECT COUNT(*) INTO v_legacy_rows_after
    FROM nn_genome_evaluation WHERE genome_id = v_genome_id;
    SELECT fitness INTO v_legacy_fitness_after
    FROM nn_genome WHERE id = v_genome_id;

    IF v_ack_token IS NULL OR v_ack_token <> v_ack_token_retry
       OR v_training_rows <> 1 OR v_source_rows <> 1
       OR v_fitness <> v_expected_fitness
       OR v_legacy_rows_after <> v_legacy_rows_before
       OR v_legacy_fitness_after <> v_legacy_fitness_before THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Versionamento/ACK SQL falhou ou alterou referência legada';
    END IF;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_wrong_ack_rejected = 1;
        CALL sp_nn_confirm_training_ack_v2(v_session_id, UUID());
    END;
    IF v_wrong_ack_rejected <> 1 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Token incorreto de ACK não foi rejeitado';
    END IF;

    CALL sp_nn_confirm_training_ack_v2(v_session_id, v_ack_token);
    SELECT COUNT(*) INTO v_ack_confirmed
    FROM nn_training_session_completion_v2
    WHERE session_id = v_session_id
      AND ack_token = v_ack_token
      AND ack_confirmed_at IS NOT NULL
      AND evaluation_count = 1;

    -- An already ended v2 session cannot be registered retroactively.
    INSERT INTO nn_engine_session (session_id, architecture_id)
    VALUES (v_unregistered_session_id, v_architecture_id);
    INSERT INTO nn_session_npc (
        session_id, engine_npc_id, npc_type, genome_id, max_health, last_health
    ) VALUES (v_unregistered_session_id, 'training-retroactive-sql-fixture', 1, v_genome_id, 100, 100);
    CALL sp_nn_mark_session_v2(v_unregistered_session_id);
    CALL sp_nn_finish_session_training_v2(v_unregistered_session_id, v_unregistered_ack);
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_registration_retroactive_rejected = 1;
        CALL sp_nn_register_training_session_v2(v_unregistered_session_id);
    END;

    SELECT COUNT(*) INTO v_training_rows
    FROM nn_genome_evaluation_training_v2
    WHERE session_id = v_unregistered_session_id;

    IF v_unregistered_ack IS NOT NULL
       OR v_ack_confirmed <> 1 OR v_registration_retroactive_rejected <> 1
       OR v_training_rows <> 0 THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'ACK válido ou proteção contra classificação retroativa falhou';
    END IF;

    SELECT COUNT(*) INTO v_training_rows
    FROM nn_genome_evaluation_training_v2;
    IF v_training_rows <> v_training_rows_before + 1 THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Avaliações históricas foram alteradas ou fixture não foi isolada';
    END IF;
END$$
CALL test_nn_training_integrity_v2()$$
DROP PROCEDURE test_nn_training_integrity_v2$$
DELIMITER ;

SELECT 'OK: fixture SQL sintética concluiu versionamento, bloqueio retroativo e ACK; não é evidência de combate.' AS resultado;
