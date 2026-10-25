DELIMITER $$
DROP PROCEDURE IF EXISTS sp_nn_create_initial_population$$

CREATE PROCEDURE sp_nn_create_initial_population(
    IN p_architecture_name VARCHAR(50),
    IN p_population_size INT
)
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_input_count INT DEFAULT 0;
    DECLARE v_hidden_count INT DEFAULT 0;
    DECLARE v_output_count INT DEFAULT 0;
    DECLARE v_expected_inputs INT DEFAULT 0;
    DECLARE v_expected_outputs INT DEFAULT 0;
    DECLARE v_expected_synapses INT DEFAULT 0;
    DECLARE v_actual_synapses INT DEFAULT 0;
    DECLARE v_input_mappings INT DEFAULT 0;
    DECLARE v_output_mappings INT DEFAULT 0;
    DECLARE v_existing_genomes INT DEFAULT 0;
    DECLARE v_index INT DEFAULT 0;
    DECLARE v_genome_id INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_population_size < 2 OR p_population_size > 100 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A população inicial deve ter entre 2 e 100 genomas';
    END IF;

    SELECT id, n_entradas, n_saidas
    INTO v_architecture_id, v_expected_inputs, v_expected_outputs
    FROM nn_architecture
    WHERE nome = p_architecture_name;

    IF v_architecture_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Arquitetura não encontrada';
    END IF;

    SELECT COUNT(*) INTO v_input_count
    FROM nn_layer l
    JOIN nn_neuron n ON n.layer_id = l.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'input';

    SELECT COUNT(*) INTO v_hidden_count
    FROM nn_layer l
    JOIN nn_neuron n ON n.layer_id = l.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'hidden';

    SELECT COUNT(*) INTO v_output_count
    FROM nn_layer l
    JOIN nn_neuron n ON n.layer_id = l.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'output';

    SELECT COUNT(*) INTO v_input_mappings
    FROM nn_layer l
    JOIN nn_neuron n ON n.layer_id = l.id
    JOIN nn_neuron_io io ON io.neuron_id = n.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'input';

    SELECT COUNT(*) INTO v_output_mappings
    FROM nn_layer l
    JOIN nn_neuron n ON n.layer_id = l.id
    JOIN nn_neuron_io io ON io.neuron_id = n.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'output';

    SELECT COALESCE(SUM(origem.quantidade * destino.quantidade), 0)
    INTO v_expected_synapses
    FROM (
        SELECT l.ordem, COUNT(n.id) AS quantidade
        FROM nn_layer l
        JOIN nn_neuron n ON n.layer_id = l.id
        WHERE l.architecture_id = v_architecture_id
        GROUP BY l.id, l.ordem
    ) AS origem
    JOIN (
        SELECT l.ordem, COUNT(n.id) AS quantidade
        FROM nn_layer l
        JOIN nn_neuron n ON n.layer_id = l.id
        WHERE l.architecture_id = v_architecture_id
        GROUP BY l.id, l.ordem
    ) AS destino ON destino.ordem = origem.ordem + 1;

    SELECT COUNT(*) INTO v_actual_synapses
    FROM nn_synapse s
    JOIN nn_neuron origem ON origem.id = s.from_neuron_id
    JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
    JOIN nn_neuron destino ON destino.id = s.to_neuron_id
    JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
    WHERE camada_origem.architecture_id = v_architecture_id
      AND camada_destino.architecture_id = v_architecture_id;

    IF v_input_count <> v_expected_inputs
       OR v_hidden_count = 0
       OR v_output_count <> v_expected_outputs
       OR v_input_mappings <> v_expected_inputs
       OR v_output_mappings <> v_expected_outputs
       OR v_expected_synapses = 0
       OR v_actual_synapses <> v_expected_synapses THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Topologia, mapeamentos ou conexões da arquitetura são inválidos';
    END IF;

    SELECT COUNT(*) INTO v_existing_genomes
    FROM nn_genome
    WHERE architecture_id = v_architecture_id;

    IF v_existing_genomes > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Já existem genomas; a população inicial não foi alterada';
    END IF;

    START TRANSACTION;

    WHILE v_index < p_population_size DO
        INSERT INTO nn_genome (architecture_id, geracao, fitness, origem)
        VALUES (v_architecture_id, 0, 0, 'aleatorio');

        SET v_genome_id = LAST_INSERT_ID();

        INSERT INTO nn_genome_weight (genome_id, synapse_id, peso)
        SELECT v_genome_id, s.id, RAND() * 2.0 - 1.0
        FROM nn_synapse s
        JOIN nn_neuron origem ON origem.id = s.from_neuron_id
        JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
        JOIN nn_neuron destino ON destino.id = s.to_neuron_id
        JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
        WHERE camada_origem.architecture_id = v_architecture_id
          AND camada_destino.architecture_id = v_architecture_id;

        INSERT INTO nn_genome_bias (genome_id, neuron_id, bias)
        SELECT v_genome_id, n.id, RAND() * 2.0 - 1.0
        FROM nn_neuron n
        JOIN nn_layer l ON l.id = n.layer_id
        WHERE l.architecture_id = v_architecture_id
          AND l.tipo IN ('hidden', 'output');

        SET v_index = v_index + 1;
    END WHILE;

    COMMIT;

    SELECT id AS genome_id, geracao AS generation, origem AS origin, fitness
    FROM nn_genome
    WHERE architecture_id = v_architecture_id AND geracao = 0
    ORDER BY id;
END$$
DELIMITER ;
