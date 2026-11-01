-- Isolated SQL fixture: validates safe selection and locking in the test schema.
-- It creates uniquely named fixture architecture/genomes only in the SQL-test schema.
DELIMITER $$
DROP PROCEDURE IF EXISTS test_nn_lab_playable_selection$$
CREATE PROCEDURE test_nn_lab_playable_selection()
BEGIN
    DECLARE v_schema VARCHAR(64) DEFAULT DATABASE();
    DECLARE v_name VARCHAR(50) DEFAULT NULL;
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_first_genome_id INT DEFAULT NULL;
    DECLARE v_second_genome_id INT DEFAULT NULL;
    DECLARE v_session_id CHAR(36) DEFAULT NULL;
    DECLARE v_run_id BIGINT DEFAULT NULL;
    DECLARE v_action VARCHAR(16) DEFAULT NULL;
    DECLARE v_confidence DOUBLE DEFAULT NULL;
    DECLARE v_decision_genome_id INT DEFAULT NULL;
    DECLARE v_rejected_change TINYINT DEFAULT 0;

    IF v_schema <> 'neural_doom_local_sql_test_20261024' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Fixture permitido somente no schema SQL-test isolado';
    END IF;

    SET v_name = CONCAT('fixture_select_', REPLACE(UUID(), '-', ''));
    SET v_session_id = UUID();
    CALL sp_nn_create_configurable_architecture(v_name, JSON_ARRAY(4, 2, 4), 'relu');
    CALL sp_nn_create_seeded_population(v_name, 2, 20261101);

    SELECT id INTO v_architecture_id FROM nn_architecture WHERE nome = v_name;
    SELECT MIN(id), MAX(id)
      INTO v_first_genome_id, v_second_genome_id
    FROM nn_genome
    WHERE architecture_id = v_architecture_id AND geracao = 0;

    IF v_first_genome_id IS NULL OR v_second_genome_id IS NULL
       OR v_first_genome_id = v_second_genome_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A população fixture não contém dois genomas';
    END IF;

    CALL sp_nn_select_session_genome_v2(
        v_name, v_session_id, 'fixture-npc-1', 12, 80, 100, v_first_genome_id
    );
    CALL sp_nn_decide_for_architecture(
        v_name, v_session_id, 'fixture-npc-1', 12, 80, 100, 300, 1, 482,
        v_run_id, v_action, v_confidence
    );
    SELECT genome_id INTO v_decision_genome_id
    FROM nn_decision_run WHERE id = v_run_id;
    IF v_decision_genome_id <> v_first_genome_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A decisão SQL não usou o genoma fixado';
    END IF;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_rejected_change = 1;
        CALL sp_nn_select_session_genome_v2(
            v_name, v_session_id, 'fixture-npc-1', 12, 80, 100, v_second_genome_id
        );
    END;
    IF v_rejected_change <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'O procedimento aceitou trocar genoma no NPC já atribuído';
    END IF;

    SELECT 'PASS' AS result,
           v_name AS fixture_architecture,
           v_first_genome_id AS selected_genome,
           v_run_id AS decision_run_id,
           v_action AS calculated_action;
END$$
CALL test_nn_lab_playable_selection()$$
DROP PROCEDURE test_nn_lab_playable_selection$$
DELIMITER ;
