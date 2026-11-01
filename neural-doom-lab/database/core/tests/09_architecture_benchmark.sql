-- Benchmark de procedimento SQL com observações fixas e oito IDs de NPC.
-- Mede somente o MySQL local; não é partida, concorrência de browser ou aprendizado.
DROP TEMPORARY TABLE IF EXISTS tmp_nn_architecture_latency;
CREATE TEMPORARY TABLE tmp_nn_architecture_latency (
    architecture_name VARCHAR(50) NOT NULL,
    sample_number INT NOT NULL,
    elapsed_microseconds BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (architecture_name, sample_number)
) ENGINE=MEMORY;

DROP PROCEDURE IF EXISTS test_measure_architecture_latency;
DELIMITER $$
CREATE PROCEDURE test_measure_architecture_latency(
    IN p_architecture_name VARCHAR(50),
    IN p_sample_count INT,
    IN p_npc_count INT
)
BEGIN
    DECLARE v_sample INT DEFAULT 0;
    DECLARE v_started_at DATETIME(6) DEFAULT NULL;
    DECLARE v_session_id CHAR(36) DEFAULT NULL;
    DECLARE v_run_id BIGINT DEFAULT 0;
    DECLARE v_action VARCHAR(16) DEFAULT NULL;
    DECLARE v_confidence DOUBLE DEFAULT 0;

    SET v_session_id = UUID();
    WHILE v_sample < p_sample_count DO
        SET v_started_at = NOW(6);
        CALL sp_nn_decide_for_architecture(
            p_architecture_name,
            v_session_id,
            CONCAT('bench-', MOD(v_sample, p_npc_count)),
            1, 80, 100, 900, 1, 0,
            v_run_id, v_action, v_confidence
        );
        INSERT INTO tmp_nn_architecture_latency (
            architecture_name, sample_number, elapsed_microseconds
        ) VALUES (
            p_architecture_name,
            v_sample + 1,
            TIMESTAMPDIFF(MICROSECOND, v_started_at, NOW(6))
        );
        SET v_sample = v_sample + 1;
    END WHILE;
END$$
DELIMITER ;

CALL test_measure_architecture_latency('npc_teste_4_6_4', 20, 8);
CALL test_measure_architecture_latency('npc_exp_4_32_4', 20, 8);
CALL test_measure_architecture_latency('npc_exp_4_64_4', 20, 8);
CALL test_measure_architecture_latency('npc_exp_4_64_32_64_4', 20, 8);
CALL test_measure_architecture_latency('npc_exp_4_128_64_128_4', 20, 8);
CALL test_measure_architecture_latency('npc_exp_4_256_128_64_4', 20, 8);
CALL test_measure_architecture_latency('npc_exp_4_512_4', 20, 8);

WITH amostras_ordenadas AS (
    SELECT architecture_name, elapsed_microseconds,
        ROW_NUMBER() OVER (
            PARTITION BY architecture_name ORDER BY elapsed_microseconds
        ) AS amostra_ordenada,
        COUNT(*) OVER (PARTITION BY architecture_name) AS total_amostras
    FROM tmp_nn_architecture_latency
)
SELECT arquitetura.nome AS architecture_name,
       COUNT(*) AS samples,
       MAX(larguras.pesos) AS weights,
       MAX(larguras.biases) AS biases,
       ROUND(AVG(amostras_ordenadas.elapsed_microseconds), 1) AS avg_microseconds,
       MAX(CASE WHEN amostras_ordenadas.amostra_ordenada =
                         CEILING(amostras_ordenadas.total_amostras * 0.95)
                THEN amostras_ordenadas.elapsed_microseconds END) AS p95_microseconds,
       MAX(amostras_ordenadas.elapsed_microseconds) AS max_microseconds
FROM amostras_ordenadas
JOIN nn_architecture arquitetura ON arquitetura.nome = amostras_ordenadas.architecture_name
JOIN (
    SELECT l.architecture_id,
        (SELECT COUNT(*) FROM nn_synapse s
         JOIN nn_neuron origem ON origem.id = s.from_neuron_id
         JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
         JOIN nn_neuron destino ON destino.id = s.to_neuron_id
         JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
         WHERE camada_origem.architecture_id = l.architecture_id
           AND camada_destino.architecture_id = l.architecture_id) AS pesos,
        (SELECT COUNT(*) FROM nn_neuron n
         JOIN nn_layer camada ON camada.id = n.layer_id
         WHERE camada.architecture_id = l.architecture_id
           AND camada.tipo IN ('hidden','output')) AS biases
    FROM nn_layer l
    GROUP BY l.architecture_id
) larguras ON larguras.architecture_id = arquitetura.id
GROUP BY arquitetura.nome
ORDER BY SUM(larguras.pesos) + SUM(larguras.biases);

DROP PROCEDURE test_measure_architecture_latency;
DROP TEMPORARY TABLE tmp_nn_architecture_latency;
