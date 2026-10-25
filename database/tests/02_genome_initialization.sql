CALL sp_nn_create_initial_population('npc_teste_4_6_4', 4);

DROP PROCEDURE IF EXISTS test_assert_initial_population;

DELIMITER $$
CREATE PROCEDURE test_assert_initial_population()
BEGIN
    DECLARE v_architecture_id INT;
    DECLARE v_genomes INT DEFAULT 0;
    DECLARE v_bad_genomes INT DEFAULT 0;
    DECLARE v_bad_weights INT DEFAULT 0;
    DECLARE v_bad_biases INT DEFAULT 0;

    SELECT id INTO v_architecture_id
    FROM nn_architecture
    WHERE nome = 'npc_teste_4_6_4';

    SELECT COUNT(*) INTO v_genomes
    FROM nn_genome
    WHERE architecture_id = v_architecture_id AND geracao = 0;

    SELECT COUNT(*) INTO v_bad_genomes
    FROM nn_genome g
    WHERE g.architecture_id = v_architecture_id
      AND g.geracao = 0
      AND (
          (SELECT COUNT(*) FROM nn_genome_weight w WHERE w.genome_id = g.id) <> 48
          OR (SELECT COUNT(*) FROM nn_genome_bias b WHERE b.genome_id = g.id) <> 10
          OR g.origem <> 'aleatorio'
          OR g.fitness <> 0
      );

    SELECT COUNT(*) INTO v_bad_weights
    FROM nn_genome_weight w
    JOIN nn_genome g ON g.id = w.genome_id
    WHERE g.architecture_id = v_architecture_id
      AND g.geracao = 0
      AND (w.peso < -1 OR w.peso > 1 OR w.peso IS NULL);

    SELECT COUNT(*) INTO v_bad_biases
    FROM nn_genome_bias b
    JOIN nn_genome g ON g.id = b.genome_id
    WHERE g.architecture_id = v_architecture_id
      AND g.geracao = 0
      AND (b.bias < -1 OR b.bias > 1 OR b.bias IS NULL);

    IF v_genomes <> 4 OR v_bad_genomes <> 0
       OR v_bad_weights <> 0 OR v_bad_biases <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Genomas, pesos ou biases iniciais não conferem';
    END IF;
END$$
DELIMITER ;

CALL test_assert_initial_population();
DROP PROCEDURE test_assert_initial_population;

DROP PROCEDURE IF EXISTS test_reject_invalid_population_size;

DELIMITER $$
CREATE PROCEDURE test_reject_invalid_population_size()
BEGIN
    DECLARE v_rejected TINYINT DEFAULT 0;
    DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_rejected = 1;

    CALL sp_nn_create_initial_population('npc_teste_4_6_4', 1);

    IF v_rejected = 0 THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'A população menor que 2 deveria ser rejeitada';
    END IF;
END$$
DELIMITER ;

CALL test_reject_invalid_population_size();
DROP PROCEDURE test_reject_invalid_population_size;

DROP PROCEDURE IF EXISTS test_reject_duplicate_initial_population;

DELIMITER $$
CREATE PROCEDURE test_reject_duplicate_initial_population()
BEGIN
    DECLARE v_rejected TINYINT DEFAULT 0;
    DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_rejected = 1;

    CALL sp_nn_create_initial_population('npc_teste_4_6_4', 4);

    IF v_rejected = 0 THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'A segunda população inicial deveria ser rejeitada';
    END IF;
END$$
DELIMITER ;

CALL test_reject_duplicate_initial_population();
DROP PROCEDURE test_reject_duplicate_initial_population;

SELECT 'OK: 4 genomas aleatórios, 48 pesos e 10 biases por genoma; entradas inválidas e duplicação rejeitadas.' AS resultado;
