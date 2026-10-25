-- Verifica que o ACK de encerramento não pode ser positivo sem dados avaliáveis.
SET @empty_session_id = '50000000-0000-4000-8000-000000000010';
INSERT IGNORE INTO nn_engine_session (session_id, architecture_id)
SELECT @empty_session_id, id
FROM nn_architecture
WHERE nome = 'npc_teste_4_6_4';

DROP PROCEDURE IF EXISTS test_finish_session_requires_evaluation;
DELIMITER $$
CREATE PROCEDURE test_finish_session_requires_evaluation()
BEGIN
    DECLARE v_missing_rejected TINYINT DEFAULT 0;
    DECLARE v_empty_rejected TINYINT DEFAULT 0;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_missing_rejected = 1;
        CALL sp_nn_finish_session(UUID());
    END;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_empty_rejected = 1;
        CALL sp_nn_finish_session(@empty_session_id);
    END;

    IF v_missing_rejected <> 1 OR v_empty_rejected <> 1 THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Sessão ausente/vazia recebeu encerramento positivo';
    END IF;

    IF EXISTS (
        SELECT 1 FROM nn_engine_session
        WHERE session_id = @empty_session_id AND encerrada_em IS NOT NULL
    ) OR EXISTS (
        SELECT 1 FROM nn_genome_evaluation WHERE session_id = @empty_session_id
    ) THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Uma sessão vazia foi encerrada ou avaliada';
    END IF;

END$$
DELIMITER ;

CALL test_finish_session_requires_evaluation();
DROP PROCEDURE test_finish_session_requires_evaluation;

SELECT 'OK: encerramento desconhecido ou sem NPC avaliável não recebe ACK positivo.' AS resultado;
