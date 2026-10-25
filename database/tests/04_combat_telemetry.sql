-- Eventos de fixture usados somente para verificar as procedures no banco de testes.
SET @test_session_id = UUID();
SET @test_event_1 = UUID();
SET @test_event_2 = UUID();
SET @test_event_3 = UUID();
SET @test_event_4 = UUID();
SET @test_event_5 = UUID();
SET @test_event_6 = UUID();
SET @test_event_7 = UUID();

CALL sp_nn_decide(@test_session_id, 'fixture-1', 1, 100, 100, 400, 1, 10, @run, @action, @confidence);
CALL sp_nn_decide(@test_session_id, 'fixture-2', 2, 100, 100, 800, 1, 20, @run, @action, @confidence);
CALL sp_nn_decide(@test_session_id, 'fixture-3', 3, 100, 100, 1200, 0, 30, @run, @action, @confidence);
CALL sp_nn_decide(@test_session_id, 'fixture-4', 4, 100, 100, 1600, 0, 40, @run, @action, @confidence);

CALL sp_nn_record_combat_event(@test_event_1, @test_session_id, 'fixture-1', 'PLAYER_DAMAGE', 20);
CALL sp_nn_record_combat_event(@test_event_2, @test_session_id, 'fixture-1', 'NPC_DAMAGE', 8);
CALL sp_nn_record_combat_event(@test_event_3, @test_session_id, 'fixture-2', 'PLAYER_DAMAGE', 10);
CALL sp_nn_record_combat_event(@test_event_4, @test_session_id, 'fixture-2', 'PLAYER_KILL', 1);
CALL sp_nn_record_combat_event(@test_event_5, @test_session_id, 'fixture-2', 'NPC_DAMAGE', 40);
CALL sp_nn_record_combat_event(@test_event_6, @test_session_id, 'fixture-2', 'NPC_DEATH', 1);
CALL sp_nn_record_combat_event(@test_event_7, @test_session_id, 'fixture-3', 'PLAYER_DAMAGE', 5);
CALL sp_nn_record_combat_event(@test_event_1, @test_session_id, 'fixture-1', 'PLAYER_DAMAGE', 999);

DROP PROCEDURE IF EXISTS test_assert_combat_evaluation;
DELIMITER $$
CREATE PROCEDURE test_assert_combat_evaluation(IN p_session_id CHAR(36))
BEGIN
    DECLARE v_events INT DEFAULT 0;
    DECLARE v_evaluations INT DEFAULT 0;
    DECLARE v_generation_complete TINYINT DEFAULT 0;
    DECLARE v_population INT DEFAULT 0;
    DECLARE v_genome_1 INT DEFAULT 0;
    DECLARE v_genome_2 INT DEFAULT 0;
    DECLARE v_genome_1_damage BIGINT DEFAULT 0;
    DECLARE v_genome_2_kills INT DEFAULT 0;
    DECLARE v_genome_2_deaths INT DEFAULT 0;
    DECLARE v_closed TIMESTAMP DEFAULT NULL;
    DECLARE v_late_event_rejected TINYINT DEFAULT 0;

    SELECT COUNT(*) INTO v_events
    FROM nn_combat_event WHERE session_id = p_session_id;
    IF v_events <> 7 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Evento repetido foi contado mais de uma vez';
    END IF;

    CALL sp_nn_finish_session(p_session_id);

    SELECT COUNT(*) INTO v_evaluations
    FROM nn_genome_evaluation WHERE session_id = p_session_id;
    SELECT completa, tamanho_populacao INTO v_generation_complete, v_population
    FROM nn_generation_summary
    WHERE architecture_id = (SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4')
      AND geracao = 0;
    SELECT genome_id INTO v_genome_1
    FROM nn_session_npc
    WHERE session_id = p_session_id AND engine_npc_id = 'fixture-1';
    SELECT genome_id INTO v_genome_2
    FROM nn_session_npc
    WHERE session_id = p_session_id AND engine_npc_id = 'fixture-2';
    SELECT damage_to_player INTO v_genome_1_damage
    FROM nn_genome_evaluation WHERE session_id = p_session_id AND genome_id = v_genome_1;
    SELECT player_kills, npc_deaths INTO v_genome_2_kills, v_genome_2_deaths
    FROM nn_genome_evaluation WHERE session_id = p_session_id AND genome_id = v_genome_2;
    SELECT encerrada_em INTO v_closed
    FROM nn_engine_session WHERE session_id = p_session_id;

    IF v_evaluations <> 4 OR v_generation_complete <> 1 OR v_population <> 4
       OR v_genome_1_damage <> 20 OR v_genome_2_kills <> 1 OR v_genome_2_deaths <> 1
       OR v_closed IS NULL THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Eventos não foram agregados corretamente por genoma';
    END IF;

    CALL sp_nn_finish_session(p_session_id);
    SELECT COUNT(*) INTO v_evaluations
    FROM nn_genome_evaluation WHERE session_id = p_session_id;
    IF v_evaluations <> 4 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Avaliar a mesma sessão duplicou os resultados';
    END IF;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_late_event_rejected = 1;
        CALL sp_nn_record_combat_event(
            UUID(),
            p_session_id, 'fixture-1', 'PLAYER_DAMAGE', 1
        );
    END;
    IF v_late_event_rejected = 0 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Sessão encerrada aceitou novo evento';
    END IF;
END$$
DELIMITER ;

CALL test_assert_combat_evaluation(@test_session_id);
DROP PROCEDURE test_assert_combat_evaluation;

SELECT 'OK: telemetria idempotente, avaliação agregada por genoma e resumo de geração.' AS resultado;
