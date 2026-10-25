DROP PROCEDURE IF EXISTS sp_nn_evolve_generation;
DELIMITER $$
CREATE PROCEDURE sp_nn_evolve_generation(
    IN p_architecture_name VARCHAR(50),
    IN p_source_generation INT,
    IN p_elite_count INT,
    IN p_mutation_rate DOUBLE
)
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_population_count INT DEFAULT 0;
    DECLARE v_evaluated_count INT DEFAULT 0;
    DECLARE v_next_generation_count INT DEFAULT 0;
    DECLARE v_child_index INT DEFAULT 0;
    DECLARE v_parent1_id INT DEFAULT NULL;
    DECLARE v_parent2_id INT DEFAULT NULL;
    DECLARE v_child_id INT DEFAULT NULL;
    DECLARE v_mutated_genes INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        DROP TEMPORARY TABLE IF EXISTS tmp_nn_elite;
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_architecture_name IS NULL OR p_source_generation IS NULL OR p_source_generation < 0
       OR p_elite_count IS NULL OR p_mutation_rate IS NULL
       OR p_mutation_rate < 0 OR p_mutation_rate > 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Parâmetros de evolução inválidos';
    END IF;

    SELECT id INTO v_architecture_id
    FROM nn_architecture
    WHERE nome = p_architecture_name;
    IF v_architecture_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Arquitetura não encontrada';
    END IF;

    SELECT COUNT(*), SUM(individuo_avaliado)
    INTO v_population_count, v_evaluated_count
    FROM (
        SELECT g.id,
            EXISTS (
                SELECT 1 FROM nn_genome_evaluation e WHERE e.genome_id = g.id
            ) AS individuo_avaliado
        FROM nn_genome g
        WHERE g.architecture_id = v_architecture_id
          AND g.geracao = p_source_generation
    ) populacao;

    IF v_population_count < 2 OR p_elite_count < 2 OR p_elite_count > v_population_count THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A população e a elite precisam ter ao menos dois genomas';
    END IF;
    IF v_evaluated_count <> v_population_count THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Todos os genomas da geração precisam de avaliação real antes da evolução';
    END IF;

    SELECT COUNT(*) INTO v_next_generation_count
    FROM nn_genome
    WHERE architecture_id = v_architecture_id AND geracao = p_source_generation + 1;
    IF v_next_generation_count > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A geração seguinte já existe e não será sobrescrita';
    END IF;

    START TRANSACTION;
    UPDATE nn_genome g
    SET g.fitness = (
        SELECT AVG(e.fitness)
        FROM nn_genome_evaluation e
        WHERE e.genome_id = g.id
    )
    WHERE g.architecture_id = v_architecture_id
      AND g.geracao = p_source_generation;

    DROP TEMPORARY TABLE IF EXISTS tmp_nn_elite;
    CREATE TEMPORARY TABLE tmp_nn_elite (
        genome_id INT PRIMARY KEY,
        fitness DECIMAL(14,4) NOT NULL
    ) ENGINE=MEMORY;

    INSERT INTO tmp_nn_elite (genome_id, fitness)
    SELECT id, fitness
    FROM nn_genome
    WHERE architecture_id = v_architecture_id AND geracao = p_source_generation
    ORDER BY fitness DESC, id ASC
    LIMIT p_elite_count;

    WHILE v_child_index < v_population_count DO
        SELECT genome_id INTO v_parent1_id
        FROM tmp_nn_elite
        ORDER BY RAND()
        LIMIT 1;

        SELECT genome_id INTO v_parent2_id
        FROM tmp_nn_elite
        WHERE genome_id <> v_parent1_id
        ORDER BY RAND()
        LIMIT 1;

        INSERT INTO nn_genome (
            architecture_id, geracao, fitness, origem, pai1_id, pai2_id
        ) VALUES (
            v_architecture_id, p_source_generation + 1, 0, 'crossover', v_parent1_id, v_parent2_id
        );
        SET v_child_id = LAST_INSERT_ID();

        INSERT INTO nn_genome_weight (genome_id, synapse_id, peso)
        SELECT v_child_id, peso1.synapse_id,
            CASE WHEN RAND() < p_mutation_rate THEN
                LEAST(1, GREATEST(-1,
                    (CASE WHEN RAND() < 0.5 THEN peso1.peso ELSE peso2.peso END)
                    + (RAND() * 2 - 1) * 0.25
                ))
            ELSE CASE WHEN RAND() < 0.5 THEN peso1.peso ELSE peso2.peso END
            END
        FROM nn_genome_weight peso1
        JOIN nn_genome_weight peso2 ON peso2.synapse_id = peso1.synapse_id
        WHERE peso1.genome_id = v_parent1_id AND peso2.genome_id = v_parent2_id;

        INSERT INTO nn_genome_bias (genome_id, neuron_id, bias)
        SELECT v_child_id, bias1.neuron_id,
            CASE WHEN RAND() < p_mutation_rate THEN
                LEAST(1, GREATEST(-1,
                    (CASE WHEN RAND() < 0.5 THEN bias1.bias ELSE bias2.bias END)
                    + (RAND() * 2 - 1) * 0.25
                ))
            ELSE CASE WHEN RAND() < 0.5 THEN bias1.bias ELSE bias2.bias END
            END
        FROM nn_genome_bias bias1
        JOIN nn_genome_bias bias2 ON bias2.neuron_id = bias1.neuron_id
        WHERE bias1.genome_id = v_parent1_id AND bias2.genome_id = v_parent2_id;

        SELECT (
            SELECT COUNT(*)
            FROM nn_genome_weight filho
            JOIN nn_genome_weight pai1
              ON pai1.genome_id = v_parent1_id AND pai1.synapse_id = filho.synapse_id
            JOIN nn_genome_weight pai2
              ON pai2.genome_id = v_parent2_id AND pai2.synapse_id = filho.synapse_id
            WHERE filho.genome_id = v_child_id
              AND NOT (filho.peso <=> pai1.peso)
              AND NOT (filho.peso <=> pai2.peso)
        ) + (
            SELECT COUNT(*)
            FROM nn_genome_bias filho
            JOIN nn_genome_bias pai1
              ON pai1.genome_id = v_parent1_id AND pai1.neuron_id = filho.neuron_id
            JOIN nn_genome_bias pai2
              ON pai2.genome_id = v_parent2_id AND pai2.neuron_id = filho.neuron_id
            WHERE filho.genome_id = v_child_id
              AND NOT (filho.bias <=> pai1.bias)
              AND NOT (filho.bias <=> pai2.bias)
        ) INTO v_mutated_genes;

        IF v_mutated_genes > 0 THEN
            UPDATE nn_genome SET origem = 'mutacao' WHERE id = v_child_id;
        END IF;

        SET v_child_index = v_child_index + 1;
    END WHILE;

    INSERT INTO nn_generation_summary (
        architecture_id, geracao, tamanho_populacao, individuos_avaliados,
        fitness_medio, melhor_fitness, pior_fitness, completa
    ) VALUES (
        v_architecture_id, p_source_generation + 1, v_population_count, 0,
        NULL, NULL, NULL, 0
    );

    DROP TEMPORARY TABLE IF EXISTS tmp_nn_elite;
    COMMIT;

    SELECT id AS genome_id, geracao AS generation, origem AS origin,
           pai1_id AS parent_1_id, pai2_id AS parent_2_id, fitness
    FROM nn_genome
    WHERE architecture_id = v_architecture_id AND geracao = p_source_generation + 1
    ORDER BY id;
END$$
DELIMITER ;
