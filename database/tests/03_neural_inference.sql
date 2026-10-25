-- Use somente no banco descartável de testes depois de 04_genome_initialization.sql.
-- O genoma de pesos fixos abaixo é um fixture matemático, não um resultado de jogo.
UPDATE nn_genome_weight
SET peso = 0
WHERE genome_id = 1;

UPDATE nn_genome_bias b
JOIN nn_neuron n ON n.id = b.neuron_id
JOIN nn_layer l ON l.id = n.layer_id
SET b.bias = CASE n.posicao
    WHEN 0 THEN -3
    WHEN 1 THEN -2
    WHEN 2 THEN 4
    WHEN 3 THEN -1
END
WHERE b.genome_id = 1 AND l.tipo = 'output';

UPDATE nn_genome_bias b
JOIN nn_neuron n ON n.id = b.neuron_id
JOIN nn_layer l ON l.id = n.layer_id
SET b.bias = 0
WHERE b.genome_id = 1 AND l.tipo = 'hidden';

DROP PROCEDURE IF EXISTS test_assert_nn_inference;
DELIMITER $$
CREATE PROCEDURE test_assert_nn_inference()
BEGIN
    DECLARE v_run_id BIGINT DEFAULT 0;
    DECLARE v_action VARCHAR(16) DEFAULT NULL;
    DECLARE v_confidence DOUBLE DEFAULT 0;
    DECLARE v_activations INT DEFAULT 0;
    DECLARE v_health_ratio DOUBLE DEFAULT -1;
    DECLARE v_distance_ratio DOUBLE DEFAULT -1;
    DECLARE v_visible DOUBLE DEFAULT -1;
    DECLARE v_health_delta DOUBLE DEFAULT -1;
    DECLARE v_second_run BIGINT DEFAULT 0;
    DECLARE v_invalid_rejected TINYINT DEFAULT 0;
    DECLARE v_same_engine_id_sessions INT DEFAULT 0;
    DECLARE v_session_genomes INT DEFAULT 0;

    IF ABS(fn_nn_activate(0, 'sigmoid') - 0.5) > 0.000001
       OR fn_nn_activate(-2, 'relu') <> 0
       OR ABS(fn_nn_activate(0, 'tanh')) > 0.000001 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Função de ativação não retornou o valor conhecido';
    END IF;

    CALL sp_nn_decide(
        '11111111-1111-4111-8111-111111111111', 'npc-um', 1,
        80, 100, 2048, 1, 42, v_run_id, v_action, v_confidence
    );

    SELECT COUNT(*) INTO v_activations
    FROM nn_decision_activation WHERE run_id = v_run_id;
    SELECT health_ratio, player_distance_ratio, health_delta
    INTO v_health_ratio, v_distance_ratio, v_health_delta
    FROM nn_decision_run WHERE id = v_run_id;
    SELECT valor INTO v_visible
    FROM nn_decision_activation a
    JOIN nn_neuron_io io ON io.neuron_id = a.neuron_id
    WHERE a.run_id = v_run_id AND io.nome = 'PLAYER_VISIBLE';

    IF v_action <> 'ATTACK' OR ABS(v_confidence - 0.98201379) > 0.00001
       OR v_activations <> 14 OR ABS(v_health_ratio - 0.8) > 0.000001
       OR ABS(v_distance_ratio - 1) > 0.000001 OR v_visible <> 1
       OR v_health_delta <> 0 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Forward pass, normalização ou escolha de saída incorretos';
    END IF;

    CALL sp_nn_decide(
        '11111111-1111-4111-8111-111111111111', 'npc-um', 1,
        70, 100, 1024, 0, 42, v_second_run, v_action, v_confidence
    );
    SELECT health_delta INTO v_health_delta
    FROM nn_decision_run WHERE id = v_second_run;

    IF ABS(v_health_delta - 0.1) > 0.000001 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Variação de vida entre decisões incorreta';
    END IF;

    CALL sp_nn_decide(
        '22222222-2222-4222-8222-222222222222', 'npc-um', 1,
        80, 100, 128, 1, 42, v_run_id, v_action, v_confidence
    );
    SELECT COUNT(*) INTO v_same_engine_id_sessions
    FROM nn_session_npc
    WHERE engine_npc_id = 'npc-um';
    IF v_same_engine_id_sessions <> 2 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'IDs de engine iguais foram confundidos entre sessões';
    END IF;

    CALL sp_nn_decide(
        '11111111-1111-4111-8111-111111111111', 'npc-dois', 2,
        100, 100, 512, 0, 7, v_run_id, v_action, v_confidence
    );
    SELECT COUNT(DISTINCT genome_id) INTO v_session_genomes
    FROM nn_session_npc
    WHERE session_id = '11111111-1111-4111-8111-111111111111';
    IF v_session_genomes <> 2 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'NPCs da sessão não receberam genomas separados';
    END IF;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_invalid_rejected = 1;
        CALL sp_nn_decide(
            '11111111-1111-4111-8111-111111111111', 'npc-invalido', 1,
            80, 0, 100, 1, 42, v_run_id, v_action, v_confidence
        );
    END;

    IF v_invalid_rejected = 0 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Vida máxima igual a zero deveria ser rejeitada';
    END IF;
END$$
DELIMITER ;

CALL test_assert_nn_inference();
DROP PROCEDURE test_assert_nn_inference;

SELECT 'OK: ativações, normalização, forward pass, escolha da maior saída e entradas inválidas.' AS resultado;
