-- Fixtures SQL do laboratório: cria somente um exemplo pequeno, idempotente,
-- no schema de testes e exercita as procedures paginadas de leitura.
-- Isso valida a API SQL; não representa partida ou aprendizagem real.

DROP PROCEDURE IF EXISTS test_nn_lab_api_ensure_fixture;
DELIMITER $$
CREATE PROCEDURE test_nn_lab_api_ensure_fixture()
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_topology TEXT DEFAULT NULL;
    DECLARE v_genomes INT DEFAULT 0;

    IF DATABASE() <> 'neural_doom_local_sql_test_20261024' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Fixture 16 permitido somente no schema neural_doom_local_sql_test_20261024';
    END IF;

    SELECT id INTO v_architecture_id
    FROM nn_architecture WHERE nome = 'lab_api_fixture_4_2_4';

    IF v_architecture_id IS NULL THEN
        CALL sp_nn_create_configurable_architecture(
            'lab_api_fixture_4_2_4', JSON_ARRAY(4, 2, 4), 'relu'
        );
        SELECT id INTO v_architecture_id
        FROM nn_architecture WHERE nome = 'lab_api_fixture_4_2_4';
    END IF;

    SELECT GROUP_CONCAT(neuron_count ORDER BY layer_order SEPARATOR ' -> ')
    INTO v_topology
    FROM (
        SELECT l.ordem AS layer_order, COUNT(n.id) AS neuron_count
        FROM nn_layer l
        JOIN nn_neuron n ON n.layer_id = l.id
        WHERE l.architecture_id = v_architecture_id
        GROUP BY l.id, l.ordem
    ) layer_widths;

    IF v_topology <> '4 -> 2 -> 4' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A arquitetura fixture existente tem topologia diferente; preservada';
    END IF;

    SELECT COUNT(*) INTO v_genomes
    FROM nn_genome WHERE architecture_id = v_architecture_id;
    IF v_genomes = 0 THEN
        CALL sp_nn_create_seeded_population('lab_api_fixture_4_2_4', 2, 161031);
    END IF;
    IF v_genomes > 0 AND v_genomes < 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'População fixture parcial já existe; preservada para inspeção';
    END IF;
END$$
DELIMITER ;

CALL test_nn_lab_api_ensure_fixture();
DROP PROCEDURE test_nn_lab_api_ensure_fixture;

SET @lab_fixture_architecture_id = (
    SELECT id FROM nn_architecture WHERE nome = 'lab_api_fixture_4_2_4'
);
SET @lab_fixture_genome_id = (
    SELECT id FROM nn_genome
    WHERE architecture_id = @lab_fixture_architecture_id AND geracao = 0
    ORDER BY id LIMIT 1
);
SET @lab_fixture_session_id = UUID();
SET @lab_fixture_run_id = 0;
SET @lab_fixture_action = NULL;
SET @lab_fixture_confidence = 0;

CALL sp_nn_lab_list_architectures();
CALL sp_nn_lab_architecture_layers(@lab_fixture_architecture_id);
CALL sp_nn_lab_list_genomes(@lab_fixture_architecture_id, 0, 10, 0);
CALL sp_nn_decide_for_architecture(
    'lab_api_fixture_4_2_4', @lab_fixture_session_id, 'sql-fixture-npc',
    1, 80, 100, 300, 1, 0,
    @lab_fixture_run_id, @lab_fixture_action, @lab_fixture_confidence
);
CALL sp_nn_lab_run_activations(@lab_fixture_run_id, 0, 16, 0);
CALL sp_nn_lab_run_activations(@lab_fixture_run_id, 1, 16, 0);
CALL sp_nn_lab_run_activations(@lab_fixture_run_id, 2, 16, 0);
CALL sp_nn_lab_genome_weights(@lab_fixture_genome_id, 1, 0, 16, 0);

SELECT 'fixture_sql_only' AS evidence_type,
       @lab_fixture_session_id AS session_id,
       @lab_fixture_run_id AS run_id,
       @lab_fixture_action AS action,
       @lab_fixture_confidence AS confidence,
       (SELECT COUNT(*) FROM nn_decision_activation WHERE run_id = @lab_fixture_run_id) AS persisted_activations;
