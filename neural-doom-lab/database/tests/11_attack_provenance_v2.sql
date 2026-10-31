-- Teste sintético restrito ao schema SQL de testes. Não é evidência de combate.
-- Insere uma sessão nova e verifica isolamento do pipeline v2 e do ACK SQL.
DROP PROCEDURE IF EXISTS test_nn_attack_provenance_v2;
DELIMITER $$
CREATE PROCEDURE test_nn_attack_provenance_v2()
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_genome_id INT DEFAULT NULL;
    DECLARE v_session_id CHAR(36) DEFAULT UUID();
    DECLARE v_legacy_eval_count BIGINT DEFAULT 0;
    DECLARE v_legacy_eval_count_after BIGINT DEFAULT 0;
    DECLARE v_legacy_fitness DECIMAL(10,4) DEFAULT 0;
    DECLARE v_legacy_fitness_after DECIMAL(10,4) DEFAULT 0;
    DECLARE v_attribution_version VARCHAR(40) DEFAULT NULL;
    DECLARE v_damage BIGINT DEFAULT 0;
    DECLARE v_kills INT DEFAULT 0;
    DECLARE v_survival BIGINT DEFAULT 0;
    DECLARE v_fitness DECIMAL(14,4) DEFAULT 0;

    IF DATABASE() <> 'neural_doom_local_sql_test_20261024' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Este teste somente pode rodar no schema SQL de testes isolado';
    END IF;

    SELECT id INTO v_architecture_id
    FROM nn_architecture WHERE nome = 'npc_teste_4_6_4';
    SELECT id, fitness INTO v_genome_id, v_legacy_fitness
    FROM nn_genome
    WHERE architecture_id = v_architecture_id
    ORDER BY geracao DESC, id
    LIMIT 1;
    IF v_architecture_id IS NULL OR v_genome_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Fixture SQL de arquitetura/genoma ausente';
    END IF;

    SELECT COUNT(*) INTO v_legacy_eval_count
    FROM nn_genome_evaluation WHERE genome_id = v_genome_id;

    INSERT INTO nn_engine_session (session_id, architecture_id)
    VALUES (v_session_id, v_architecture_id);
    INSERT INTO nn_session_npc (
        session_id, engine_npc_id, npc_type, genome_id, max_health, last_health
    ) VALUES (
        v_session_id, 'sql-v2-fixture-1', 1, v_genome_id, 100, 100
    );
    CALL sp_nn_mark_session_v2(v_session_id);
    SELECT attribution_version INTO v_attribution_version
    FROM nn_engine_session_provenance_v2 WHERE session_id = v_session_id;

    CALL sp_nn_record_combat_event(UUID(), v_session_id, 'sql-v2-fixture-1', 'PLAYER_DAMAGE', 7);
    CALL sp_nn_record_combat_event(UUID(), v_session_id, 'sql-v2-fixture-1', 'PLAYER_KILL', 1);
    CALL sp_nn_record_combat_event(UUID(), v_session_id, 'sql-v2-fixture-1', 'NPC_DAMAGE', 3);
    CALL sp_nn_finish_session_v2(v_session_id);

    SELECT damage_to_player, player_kills, survival_seconds, fitness
    INTO v_damage, v_kills, v_survival, v_fitness
    FROM nn_genome_evaluation_v2
    WHERE session_id = v_session_id AND genome_id = v_genome_id;

    SELECT COUNT(*) INTO v_legacy_eval_count_after
    FROM nn_genome_evaluation WHERE genome_id = v_genome_id;
    SELECT fitness INTO v_legacy_fitness_after
    FROM nn_genome WHERE id = v_genome_id;

    IF v_attribution_version <> 'neural_attack_provenance_v2'
       OR v_damage <> 7 OR v_kills <> 1
       OR ABS(v_fitness - (107 - 0.25 * 3 + v_survival / 60.0)) > 0.0001
       OR v_legacy_eval_count_after <> v_legacy_eval_count
       OR v_legacy_fitness_after <> v_legacy_fitness THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Isolamento v2 ou avaliação da fixture SQL falhou';
    END IF;
END$$
CALL test_nn_attack_provenance_v2()$$
DROP PROCEDURE test_nn_attack_provenance_v2$$
DELIMITER ;

SELECT 'OK: fixture SQL v2 avaliada e dados/fitness legados preservados.' AS resultado;
