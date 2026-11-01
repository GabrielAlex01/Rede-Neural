-- Valida metadados/requisitos do orquestrador. Eventos deste teste são fixtures,
-- exclusivamente para testar a evolução; não são evidência de aprendizado.
DROP PROCEDURE IF EXISTS test_ensure_training_experiment;
DELIMITER $$
CREATE PROCEDURE test_ensure_training_experiment()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM nn_architecture WHERE nome = 'npc_exp_training_smoke'
    ) THEN
        CALL sp_nn_create_configurable_architecture(
            'npc_exp_training_smoke', JSON_ARRAY(4, 2, 4), 'relu'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM nn_training_experiment WHERE nome = 'repro_meta_smoke'
    ) THEN
        CALL sp_nn_create_training_experiment(
            'repro_meta_smoke', 'npc_exp_training_smoke', 123, 2,
            0.25, 1, 2, 'fixture-only SQL reproducibility check'
        );
    END IF;
END$$
DELIMITER ;

CALL test_ensure_training_experiment();
DROP PROCEDURE test_ensure_training_experiment;
SET @training_experiment_id = (
    SELECT experiment_id FROM nn_training_experiment
    WHERE nome = 'repro_meta_smoke'
);

DROP PROCEDURE IF EXISTS test_run_training_experiment_session;
DELIMITER $$
CREATE PROCEDURE test_run_training_experiment_session(IN p_npc_prefix VARCHAR(40))
BEGIN
    DECLARE v_session_id CHAR(36) DEFAULT NULL;
    DECLARE v_run_id BIGINT DEFAULT 0;
    DECLARE v_action VARCHAR(16) DEFAULT NULL;
    DECLARE v_confidence DOUBLE DEFAULT 0;

    SET v_session_id = UUID();
    CALL sp_nn_decide_for_architecture(
        'npc_exp_training_smoke', v_session_id,
        CONCAT(p_npc_prefix, '-1'), 1, 100, 100, 512, 1, 0,
        v_run_id, v_action, v_confidence
    );
    CALL sp_nn_decide_for_architecture(
        'npc_exp_training_smoke', v_session_id,
        CONCAT(p_npc_prefix, '-2'), 1, 100, 100, 512, 1, 0,
        v_run_id, v_action, v_confidence
    );
    CALL sp_nn_record_combat_event(
        UUID(), v_session_id, CONCAT(p_npc_prefix, '-1'), 'PLAYER_DAMAGE', 10
    );
    CALL sp_nn_record_combat_event(
        UUID(), v_session_id, CONCAT(p_npc_prefix, '-2'), 'PLAYER_DAMAGE', 20
    );
    CALL sp_nn_finish_session(v_session_id);
END$$
DELIMITER ;

CALL test_run_training_experiment_session('smoke-first');

DROP PROCEDURE IF EXISTS test_assert_training_experiment_requirements;
DELIMITER $$
CREATE PROCEDURE test_assert_training_experiment_requirements()
BEGIN
    DECLARE v_session_count INT DEFAULT 0;
    DECLARE v_incomplete_genomes INT DEFAULT 0;
    DECLARE v_rejected INT DEFAULT 0;
    DECLARE v_children INT DEFAULT 0;
    DECLARE v_generation_seed BIGINT UNSIGNED DEFAULT NULL;

    SELECT COUNT(*) INTO v_session_count
    FROM nn_training_experiment_session
    WHERE experiment_id = @training_experiment_id;
    SELECT COUNT(*) INTO v_incomplete_genomes
    FROM nn_genome genoma
    WHERE genoma.architecture_id = (
        SELECT architecture_id FROM nn_training_experiment
        WHERE experiment_id = @training_experiment_id
    )
      AND genoma.geracao = 0
      AND (
          SELECT COUNT(*)
          FROM nn_genome_evaluation avaliacao
          JOIN nn_training_experiment_session sessao
            ON sessao.session_id = avaliacao.session_id
          WHERE sessao.experiment_id = @training_experiment_id
            AND avaliacao.genome_id = genoma.id
      ) < 2;

    IF v_session_count <> 1 OR v_incomplete_genomes <> 2 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Sessão/avaliações incompletas não foram registradas corretamente';
    END IF;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_rejected = 1;
        CALL sp_nn_evolve_training_experiment(@training_experiment_id, 0, 2);
    END;
    IF v_rejected = 0 OR EXISTS (
        SELECT 1 FROM nn_genome genoma
        JOIN nn_training_experiment experimento
          ON experimento.architecture_id = genoma.architecture_id
        WHERE experimento.experiment_id = @training_experiment_id
          AND genoma.geracao = 1
    ) THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Evolução aconteceu antes do número de avaliações configurado';
    END IF;
END$$
DELIMITER ;

CALL test_assert_training_experiment_requirements();
DROP PROCEDURE test_assert_training_experiment_requirements;
CALL test_run_training_experiment_session('smoke-second');
DROP PROCEDURE test_run_training_experiment_session;

CALL sp_nn_evolve_training_experiment(@training_experiment_id, 0, 2);

DROP PROCEDURE IF EXISTS test_assert_training_experiment_history;
DELIMITER $$
CREATE PROCEDURE test_assert_training_experiment_history()
BEGIN
    DECLARE v_sessions INT DEFAULT 0;
    DECLARE v_genomes INT DEFAULT 0;
    DECLARE v_children INT DEFAULT 0;
    DECLARE v_seed BIGINT UNSIGNED DEFAULT NULL;

    SELECT COUNT(*) INTO v_sessions
    FROM nn_training_experiment_session
    WHERE experiment_id = @training_experiment_id;
    SELECT COUNT(*) INTO v_genomes
    FROM nn_genome_evaluation avaliacao
    JOIN nn_training_experiment_session sessao
      ON sessao.session_id = avaliacao.session_id
    JOIN nn_genome genoma ON genoma.id = avaliacao.genome_id
    JOIN nn_training_experiment experimento
      ON experimento.architecture_id = genoma.architecture_id
    WHERE sessao.experiment_id = @training_experiment_id
      AND genoma.geracao = 0;
    SELECT COUNT(*) INTO v_children
    FROM nn_genome genoma
    JOIN nn_training_experiment experimento
      ON experimento.architecture_id = genoma.architecture_id
    WHERE experimento.experiment_id = @training_experiment_id
      AND genoma.geracao = 1;
    SELECT seed INTO v_seed
    FROM nn_training_experiment_generation
    WHERE experiment_id = @training_experiment_id AND geracao = 1;

    IF v_sessions <> 2 OR v_genomes <> 4 OR v_children <> 2
       OR v_seed IS NULL OR v_seed <> 124
       OR NOT EXISTS (
           SELECT 1 FROM nn_generation_summary resumo
           JOIN nn_training_experiment experimento
             ON experimento.architecture_id = resumo.architecture_id
           WHERE experimento.experiment_id = @training_experiment_id
             AND resumo.geracao = 1 AND resumo.tamanho_populacao = 2
       ) THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Histórico, semente derivada ou avaliação de geração incorretos';
    END IF;
END$$
DELIMITER ;

CALL test_assert_training_experiment_history();
DROP PROCEDURE test_assert_training_experiment_history;

SELECT 'OK: seed/parâmetros registrados, sessões associadas, avaliações repetidas exigidas e evolução SQL reproduzível. Fixtures não comprovam aprendizado.' AS resultado;
