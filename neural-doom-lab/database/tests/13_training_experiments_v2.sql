-- Synthetic SQL fixture for the isolated SQL-test schema only.
-- This validates topology/population isolation and session association,
-- not DOOM behavior or learning.
DROP PROCEDURE IF EXISTS test_nn_training_experiments_v2;
DELIMITER $$
CREATE PROCEDURE test_nn_training_experiments_v2()
BEGIN
    DECLARE v_experiment_id CHAR(36) DEFAULT NULL;
    DECLARE v_experiment_id_retry CHAR(36) DEFAULT NULL;
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_genome_id INT DEFAULT NULL;
    DECLARE v_session_id CHAR(36) DEFAULT UUID();
    DECLARE v_ack_token CHAR(36) DEFAULT NULL;
    DECLARE v_population_count INT DEFAULT 0;
    DECLARE v_member_count INT DEFAULT 0;
    DECLARE v_parameter_count INT DEFAULT 0;
    DECLARE v_input_mapping_count INT DEFAULT 0;
    DECLARE v_output_mapping_count INT DEFAULT 0;
    DECLARE v_session_experiment_id CHAR(36) DEFAULT NULL;
    DECLARE v_session_generation INT DEFAULT NULL;
    DECLARE v_conflict_rejected INT DEFAULT 0;
    DECLARE v_architectures_before INT DEFAULT 0;
    DECLARE v_architectures_after INT DEFAULT 0;
    DECLARE v_genomes_before INT DEFAULT 0;
    DECLARE v_genomes_after INT DEFAULT 0;
    DECLARE v_expected_architecture_delta INT DEFAULT 0;
    DECLARE v_expected_genome_delta INT DEFAULT 0;
    DECLARE v_experiment_existed_before INT DEFAULT 0;

    IF DATABASE() <> 'neural_doom_local_sql_test_20261024' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Este teste só pode rodar no schema SQL de testes isolado';
    END IF;

    SELECT COUNT(*) INTO v_architectures_before FROM nn_architecture;
    SELECT COUNT(*) INTO v_genomes_before FROM nn_genome;
    SELECT COUNT(*) INTO v_experiment_existed_before
    FROM nn_training_experiment_v2
    WHERE experiment_name = 'sql_v2_create_20261031';
    IF v_experiment_existed_before = 0 THEN
        SET v_expected_architecture_delta = 1;
        SET v_expected_genome_delta = 4;
    END IF;

    CALL sp_nn_create_genetic_experiment_v2(
        'sql_v2_create_20261031', 'sql_v2_create_20261031_h6',
        JSON_ARRAY(4, 6, 4), 'relu', 2026103101, 4, 0.050000, 2, 1,
        'fixture SQL sintética: teste de criação e associação', v_experiment_id
    );
    CALL sp_nn_create_genetic_experiment_v2(
        'sql_v2_create_20261031', 'sql_v2_create_20261031_h6',
        JSON_ARRAY(4, 6, 4), 'relu', 2026103101, 4, 0.050000, 2, 1,
        'fixture SQL sintética: teste de criação e associação', v_experiment_id_retry
    );

    SELECT architecture_id INTO v_architecture_id
    FROM nn_training_experiment_v2 WHERE experiment_id = v_experiment_id;
    SELECT COUNT(*) INTO v_population_count
    FROM nn_genome WHERE architecture_id = v_architecture_id AND geracao = 0;
    SELECT COUNT(*) INTO v_member_count
    FROM nn_training_experiment_genome_v2
    WHERE experiment_id = v_experiment_id AND generation = 0;
    SELECT
        (SELECT COUNT(*) FROM nn_synapse synapse
         JOIN nn_neuron source_neuron ON source_neuron.id = synapse.from_neuron_id
         JOIN nn_layer source_layer ON source_layer.id = source_neuron.layer_id
         JOIN nn_neuron target_neuron ON target_neuron.id = synapse.to_neuron_id
         JOIN nn_layer target_layer ON target_layer.id = target_neuron.layer_id
         WHERE source_layer.architecture_id = v_architecture_id
           AND target_layer.architecture_id = v_architecture_id)
        +
        (SELECT COUNT(*) FROM nn_neuron neuron
         JOIN nn_layer layer ON layer.id = neuron.layer_id
         WHERE layer.architecture_id = v_architecture_id
           AND layer.tipo IN ('hidden','output'))
    INTO v_parameter_count;
    SELECT COUNT(*) INTO v_input_mapping_count
    FROM nn_layer layer
    JOIN nn_neuron neuron ON neuron.layer_id = layer.id
    JOIN nn_neuron_io io ON io.neuron_id = neuron.id
    WHERE layer.architecture_id = v_architecture_id AND layer.tipo = 'input';
    SELECT COUNT(*) INTO v_output_mapping_count
    FROM nn_layer layer
    JOIN nn_neuron neuron ON neuron.layer_id = layer.id
    JOIN nn_neuron_io io ON io.neuron_id = neuron.id
    WHERE layer.architecture_id = v_architecture_id AND layer.tipo = 'output';

    SELECT MIN(genome_id) INTO v_genome_id
    FROM nn_training_experiment_genome_v2
    WHERE experiment_id = v_experiment_id AND generation = 0;
    INSERT INTO nn_engine_session (session_id, architecture_id)
    VALUES (v_session_id, v_architecture_id);
    INSERT INTO nn_session_npc (
        session_id, engine_npc_id, npc_type, genome_id, max_health, last_health
    ) VALUES (
        v_session_id, 'training-v2-create-fixture', 1, v_genome_id, 100, 100
    );
    CALL sp_nn_mark_session_v2(v_session_id);
    CALL sp_nn_register_training_session_v2(v_session_id);
    SELECT experiment_id, generation
      INTO v_session_experiment_id, v_session_generation
    FROM nn_training_experiment_session_v2 WHERE session_id = v_session_id;
    CALL sp_nn_finish_session_training_v2(v_session_id, v_ack_token);
    CALL sp_nn_confirm_training_ack_v2(v_session_id, v_ack_token);

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_conflict_rejected = 1;
        CALL sp_nn_create_genetic_experiment_v2(
            'sql_v2_create_20261031', 'sql_v2_create_20261031_h6',
            JSON_ARRAY(4, 32, 4), 'relu', 2026103101, 4, 0.050000, 2, 1,
            'fixture SQL sintética: configuração conflitante', v_experiment_id_retry
        );
    END;

    SELECT COUNT(*) INTO v_architectures_after FROM nn_architecture;
    SELECT COUNT(*) INTO v_genomes_after FROM nn_genome;

    IF v_experiment_id IS NULL OR v_experiment_id <> v_experiment_id_retry
       OR v_population_count <> 4 OR v_member_count <> 4
       OR v_parameter_count <> 58
       OR v_input_mapping_count <> 4 OR v_output_mapping_count <> 4
       OR v_session_experiment_id <> v_experiment_id OR v_session_generation <> 0
       OR v_ack_token IS NULL OR v_conflict_rejected <> 1
       OR v_architectures_after <> v_architectures_before + v_expected_architecture_delta
       OR v_genomes_after <> v_genomes_before + v_expected_genome_delta THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Criação/idempotência/topologia/associação do experimento v2 falhou';
    END IF;
END$$
CALL test_nn_training_experiments_v2()$$
DROP PROCEDURE test_nn_training_experiments_v2$$
DELIMITER ;

SELECT 'OK: fixture SQL de experimento v2 isolou arquitetura/população e associou a sessão; não é evidência de combate.' AS result;
