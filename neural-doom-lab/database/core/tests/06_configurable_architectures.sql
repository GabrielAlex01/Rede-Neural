-- Execute uma vez em um schema SQL de testes instalado com scripts 01–08.
-- Os fixtures abaixo validam matemática/topologia; não representam treino ou jogo real.
DROP PROCEDURE IF EXISTS test_ensure_configurable_architecture;
DELIMITER $$
CREATE PROCEDURE test_ensure_configurable_architecture(
    IN p_name VARCHAR(50), IN p_topology JSON, IN p_activation VARCHAR(10)
)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM nn_architecture WHERE nome = p_name) THEN
        CALL sp_nn_create_configurable_architecture(p_name, p_topology, p_activation);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM nn_genome g JOIN nn_architecture a ON a.id = g.architecture_id
        WHERE a.nome = p_name
    ) THEN
        CALL sp_nn_create_initial_population(p_name, 2);
    END IF;
END$$
DELIMITER ;

CALL test_ensure_configurable_architecture('npc_exp_4_32_4', JSON_ARRAY(4, 32, 4), 'relu');
CALL test_ensure_configurable_architecture('npc_exp_4_64_4', JSON_ARRAY(4, 64, 4), 'relu');
CALL test_ensure_configurable_architecture('npc_exp_4_64_32_64_4', JSON_ARRAY(4, 64, 32, 64, 4), 'relu');
CALL test_ensure_configurable_architecture('npc_exp_4_128_64_128_4', JSON_ARRAY(4, 128, 64, 128, 4), 'relu');
CALL test_ensure_configurable_architecture('npc_exp_4_256_128_64_4', JSON_ARRAY(4, 256, 128, 64, 4), 'relu');
CALL test_ensure_configurable_architecture('npc_exp_4_512_4', JSON_ARRAY(4, 512, 4), 'relu');
CALL test_ensure_configurable_architecture('npc_exp_known_deep', JSON_ARRAY(4, 2, 2, 2, 4), 'relu');
CALL test_ensure_configurable_architecture('npc_exp_known_tanh', JSON_ARRAY(4, 1, 4), 'tanh');
DROP PROCEDURE test_ensure_configurable_architecture;

DROP PROCEDURE IF EXISTS test_reject_invalid_configurable_architectures;
DELIMITER $$
CREATE PROCEDURE test_reject_invalid_configurable_architectures()
BEGIN
    DECLARE v_rejected INT DEFAULT 0;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_rejected = 1;
        CALL sp_nn_create_configurable_architecture(
            'npc_exp_invalid_inputs', JSON_ARRAY(5, 8, 4), 'relu'
        );
    END;
    IF v_rejected = 0 OR EXISTS (
        SELECT 1 FROM nn_architecture WHERE nome = 'npc_exp_invalid_inputs'
    ) THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Topologia sem entradas observáveis foi aceita';
    END IF;

    SET v_rejected = 0;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_rejected = 1;
        CALL sp_nn_create_configurable_architecture(
            'npc_exp_over_limit', JSON_ARRAY(4, 512, 512, 4), 'relu'
        );
    END;
    IF v_rejected = 0 OR EXISTS (
        SELECT 1 FROM nn_architecture WHERE nome = 'npc_exp_over_limit'
    ) THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Limite experimental de parâmetros não foi aplicado';
    END IF;

    SET v_rejected = 0;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_rejected = 1;
        CALL sp_nn_create_configurable_architecture(
            'npc_exp_4_32_4', JSON_ARRAY(4, 32, 4), 'relu'
        );
    END;
    IF v_rejected = 0 OR (
        SELECT COUNT(*) FROM nn_architecture WHERE nome = 'npc_exp_4_32_4'
    ) <> 1 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Criação duplicada sobrescreveu arquitetura existente';
    END IF;
END$$
DELIMITER ;

CALL test_reject_invalid_configurable_architectures();
DROP PROCEDURE test_reject_invalid_configurable_architectures;

DROP TEMPORARY TABLE IF EXISTS tmp_nn_expected_architecture;
CREATE TEMPORARY TABLE tmp_nn_expected_architecture (
    nome VARCHAR(50) PRIMARY KEY,
    camadas INT NOT NULL,
    neuronios INT NOT NULL,
    sinapses INT NOT NULL,
    pesos_por_genoma INT NOT NULL,
    biases_por_genoma INT NOT NULL
) ENGINE=MEMORY;

INSERT INTO tmp_nn_expected_architecture VALUES
    ('npc_exp_4_32_4', 3, 40, 256, 256, 36),
    ('npc_exp_4_64_4', 3, 72, 512, 512, 68),
    ('npc_exp_4_64_32_64_4', 5, 168, 4608, 4608, 164),
    ('npc_exp_4_128_64_128_4', 5, 328, 17408, 17408, 324),
    ('npc_exp_4_256_128_64_4', 5, 456, 42240, 42240, 452),
    ('npc_exp_4_512_4', 3, 520, 4096, 4096, 516),
    ('npc_exp_known_deep', 5, 14, 24, 24, 10),
    ('npc_exp_known_tanh', 3, 9, 8, 8, 5);

DROP PROCEDURE IF EXISTS test_assert_configurable_architectures;
DELIMITER $$
CREATE PROCEDURE test_assert_configurable_architectures()
BEGIN
    DECLARE v_bad_architectures INT DEFAULT 0;
    DECLARE v_genome_id INT DEFAULT NULL;
    DECLARE v_run_id BIGINT DEFAULT 0;
    DECLARE v_action VARCHAR(16) DEFAULT NULL;
    DECLARE v_confidence DOUBLE DEFAULT 0;
    DECLARE v_activations INT DEFAULT 0;
    DECLARE v_tanh_genome_id INT DEFAULT NULL;
    DECLARE v_tanh_run_id BIGINT DEFAULT 0;
    DECLARE v_tanh_action VARCHAR(16) DEFAULT NULL;
    DECLARE v_tanh_confidence DOUBLE DEFAULT 0;
    DECLARE v_tanh_activations INT DEFAULT 0;
    DECLARE v_baseline_architecture_id INT DEFAULT 0;
    DECLARE v_deep_session_id CHAR(36) DEFAULT NULL;
    DECLARE v_baseline_session_id CHAR(36) DEFAULT NULL;

    SELECT COUNT(*) INTO v_bad_architectures
    FROM tmp_nn_expected_architecture esperado
    LEFT JOIN nn_architecture arquitetura ON arquitetura.nome = esperado.nome
    WHERE arquitetura.id IS NULL
       OR (SELECT COUNT(*) FROM nn_layer camada
           WHERE camada.architecture_id = arquitetura.id) <> esperado.camadas
       OR (SELECT COUNT(*) FROM nn_neuron neuronio
           JOIN nn_layer camada ON camada.id = neuronio.layer_id
           WHERE camada.architecture_id = arquitetura.id) <> esperado.neuronios
       OR (SELECT COUNT(*) FROM nn_synapse sinapse
           JOIN nn_neuron origem ON origem.id = sinapse.from_neuron_id
           JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
           JOIN nn_neuron destino ON destino.id = sinapse.to_neuron_id
           JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
           WHERE camada_origem.architecture_id = arquitetura.id
             AND camada_destino.architecture_id = arquitetura.id) <> esperado.sinapses
       OR (SELECT COUNT(*) FROM nn_neuron_io io
           JOIN nn_neuron neuronio ON neuronio.id = io.neuron_id
           JOIN nn_layer camada ON camada.id = neuronio.layer_id
           WHERE camada.architecture_id = arquitetura.id) <> 8
       OR (SELECT COUNT(*) FROM nn_genome genoma
           WHERE genoma.architecture_id = arquitetura.id AND genoma.geracao = 0) <> 2
       OR EXISTS (
           SELECT 1 FROM nn_genome genoma
           WHERE genoma.architecture_id = arquitetura.id AND genoma.geracao = 0
             AND ((SELECT COUNT(*) FROM nn_genome_weight peso
                   WHERE peso.genome_id = genoma.id) <> esperado.pesos_por_genoma
                  OR (SELECT COUNT(*) FROM nn_genome_bias bias
                      WHERE bias.genome_id = genoma.id) <> esperado.biases_por_genoma)
       );

    IF v_bad_architectures <> 0 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Topologia, conexões, população, pesos ou biases não conferem';
    END IF;

    SELECT genoma.id INTO v_genome_id
    FROM nn_genome genoma
    JOIN nn_architecture arquitetura ON arquitetura.id = genoma.architecture_id
    WHERE arquitetura.nome = 'npc_exp_known_deep' AND genoma.geracao = 0
    ORDER BY genoma.id
    LIMIT 1;

    UPDATE nn_genome_weight SET peso = 0 WHERE genome_id = v_genome_id;
    UPDATE nn_genome_bias SET bias = 0 WHERE genome_id = v_genome_id;

    UPDATE nn_genome_weight peso
    JOIN nn_synapse sinapse ON sinapse.id = peso.synapse_id
    JOIN nn_neuron origem ON origem.id = sinapse.from_neuron_id
    JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
    JOIN nn_neuron destino ON destino.id = sinapse.to_neuron_id
    JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
    SET peso.peso = 1
    WHERE peso.genome_id = v_genome_id
      AND (
          (camada_origem.ordem = 0 AND origem.posicao = 0 AND camada_destino.ordem = 1 AND destino.posicao = 0)
          OR (camada_origem.ordem = 1 AND origem.posicao = 0 AND camada_destino.ordem = 2 AND destino.posicao = 0)
          OR (camada_origem.ordem = 2 AND origem.posicao = 0 AND camada_destino.ordem = 3 AND destino.posicao = 0)
          OR (camada_origem.ordem = 3 AND origem.posicao = 0 AND camada_destino.ordem = 4 AND destino.posicao = 2)
      );

    SET v_deep_session_id = UUID();
    CALL sp_nn_decide_for_architecture(
        'npc_exp_known_deep', v_deep_session_id,
        'known-deep', 1, 80, 100, 0, 0, 7,
        v_run_id, v_action, v_confidence
    );

    SELECT COUNT(*) INTO v_activations
    FROM nn_decision_activation WHERE run_id = v_run_id;
    IF v_action <> 'ATTACK' OR ABS(v_confidence - 0.68997448) > 0.00001
       OR v_activations <> 14 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Forward pass profundo com pesos conhecidos incorreto';
    END IF;

    SELECT genoma.id INTO v_tanh_genome_id
    FROM nn_genome genoma
    JOIN nn_architecture arquitetura ON arquitetura.id = genoma.architecture_id
    WHERE arquitetura.nome = 'npc_exp_known_tanh' AND genoma.geracao = 0
    ORDER BY genoma.id
    LIMIT 1;
    UPDATE nn_genome_weight SET peso = 0 WHERE genome_id = v_tanh_genome_id;
    UPDATE nn_genome_bias SET bias = 0 WHERE genome_id = v_tanh_genome_id;

    UPDATE nn_genome_weight peso
    JOIN nn_synapse sinapse ON sinapse.id = peso.synapse_id
    JOIN nn_neuron origem ON origem.id = sinapse.from_neuron_id
    JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
    JOIN nn_neuron destino ON destino.id = sinapse.to_neuron_id
    JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
    SET peso.peso = 1
    WHERE peso.genome_id = v_tanh_genome_id
      AND camada_origem.ordem = 0 AND origem.posicao = 0
      AND camada_destino.ordem = 1 AND destino.posicao = 0;

    UPDATE nn_genome_weight peso
    JOIN nn_synapse sinapse ON sinapse.id = peso.synapse_id
    JOIN nn_neuron origem ON origem.id = sinapse.from_neuron_id
    JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
    JOIN nn_neuron destino ON destino.id = sinapse.to_neuron_id
    JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
    SET peso.peso = 1
    WHERE peso.genome_id = v_tanh_genome_id
      AND camada_origem.ordem = 1 AND origem.posicao = 0
      AND camada_destino.ordem = 2 AND destino.posicao = 2;

    CALL sp_nn_decide_for_architecture(
        'npc_exp_known_tanh', UUID(), 'known-tanh', 1, 80, 100, 0, 0, 7,
        v_tanh_run_id, v_tanh_action, v_tanh_confidence
    );
    SELECT COUNT(*) INTO v_tanh_activations
    FROM nn_decision_activation WHERE run_id = v_tanh_run_id;
    IF v_tanh_action <> 'ATTACK'
       OR ABS(v_tanh_confidence - (
           1 / (1 + EXP(-((EXP(1.6) - 1) / (EXP(1.6) + 1))))
       )) > 0.00001
       OR v_tanh_activations <> 9 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Forward pass com ativação tanh incorreto';
    END IF;

    SELECT id INTO v_baseline_architecture_id
    FROM nn_architecture WHERE nome = 'npc_teste_4_6_4';
    SET v_baseline_session_id = UUID();
    CALL sp_nn_decide(
        v_baseline_session_id, 'legacy-wrapper', 1, 80, 100, 512, 1, 7,
        v_run_id, v_action, v_confidence
    );
    IF (SELECT architecture_id FROM nn_engine_session
        WHERE session_id = v_baseline_session_id) <> v_baseline_architecture_id THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Wrapper legado deixou de usar a arquitetura 4-6-4';
    END IF;
END$$
DELIMITER ;

CALL test_assert_configurable_architectures();
DROP PROCEDURE test_assert_configurable_architectures;
DROP TEMPORARY TABLE tmp_nn_expected_architecture;

SELECT 'OK: topologias configuráveis até 512 neurônios, limites, forward pass ReLU/tanh conhecido e wrapper 4-6-4 compatível. Fixtures matemáticas não comprovam aprendizado.' AS resultado;
