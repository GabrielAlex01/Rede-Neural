-- A evolução usa apenas a avaliação de fixture sintético do teste 04.
CALL sp_nn_evolve_generation('npc_teste_4_6_4', 0, 2, 1.0);

DROP PROCEDURE IF EXISTS test_assert_genetic_evolution;
DELIMITER $$
CREATE PROCEDURE test_assert_genetic_evolution()
BEGIN
    DECLARE v_children INT DEFAULT 0;
    DECLARE v_bad_children INT DEFAULT 0;
    DECLARE v_bad_weights INT DEFAULT 0;
    DECLARE v_bad_biases INT DEFAULT 0;
    DECLARE v_mutated_children INT DEFAULT 0;
    DECLARE v_generation_complete TINYINT DEFAULT 1;
    DECLARE v_evaluated_count INT DEFAULT -1;
    DECLARE v_rejected_unrated TINYINT DEFAULT 0;
    DECLARE v_rejected_rate TINYINT DEFAULT 0;

    SELECT COUNT(*) INTO v_children
    FROM nn_genome
    WHERE architecture_id = (SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4')
      AND geracao = 1;

    SELECT COUNT(*) INTO v_bad_children
    FROM nn_genome filho
    WHERE filho.geracao = 1
      AND filho.architecture_id = (SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4')
      AND (
          filho.origem NOT IN ('mutacao','crossover')
          OR filho.pai1_id IS NULL OR filho.pai2_id IS NULL OR filho.pai1_id = filho.pai2_id
          OR (SELECT COUNT(*) FROM nn_genome pai WHERE pai.id = filho.pai1_id AND pai.geracao = 0) <> 1
          OR (SELECT COUNT(*) FROM nn_genome pai WHERE pai.id = filho.pai2_id AND pai.geracao = 0) <> 1
          OR (SELECT COUNT(*) FROM nn_genome_weight peso WHERE peso.genome_id = filho.id) <> 48
          OR (SELECT COUNT(*) FROM nn_genome_bias bias WHERE bias.genome_id = filho.id) <> 10
          OR filho.fitness <> 0
      );

    SELECT COUNT(*) INTO v_mutated_children
    FROM nn_genome
    WHERE architecture_id = (SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4')
      AND geracao = 1 AND origem = 'mutacao';

    SELECT COUNT(*) INTO v_bad_weights
    FROM nn_genome_weight peso
    JOIN nn_genome filho ON filho.id = peso.genome_id
    WHERE filho.geracao = 1
      AND filho.architecture_id = (SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4')
      AND (peso.peso < -1 OR peso.peso > 1 OR peso.peso IS NULL);

    SELECT COUNT(*) INTO v_bad_biases
    FROM nn_genome_bias bias
    JOIN nn_genome filho ON filho.id = bias.genome_id
    WHERE filho.geracao = 1
      AND filho.architecture_id = (SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4')
      AND (bias.bias < -1 OR bias.bias > 1 OR bias.bias IS NULL);

    SELECT completa, individuos_avaliados INTO v_generation_complete, v_evaluated_count
    FROM nn_generation_summary
    WHERE architecture_id = (SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4')
      AND geracao = 1;

    IF v_children <> 4 OR v_bad_children <> 0 OR v_bad_weights <> 0 OR v_bad_biases <> 0
       OR v_mutated_children = 0 OR v_generation_complete <> 0 OR v_evaluated_count <> 0 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Crossover, mutação ou criação da geração inválidos';
    END IF;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_rejected_unrated = 1;
        CALL sp_nn_evolve_generation('npc_teste_4_6_4', 1, 2, 0.1);
    END;
    IF v_rejected_unrated = 0 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Geração sem avaliações deveria ser rejeitada';
    END IF;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_rejected_rate = 1;
        CALL sp_nn_evolve_generation('npc_teste_4_6_4', 0, 2, 1.1);
    END;
    IF v_rejected_rate = 0 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Taxa de mutação acima de 1 deveria ser rejeitada';
    END IF;
END$$
DELIMITER ;

CALL test_assert_genetic_evolution();
DROP PROCEDURE test_assert_genetic_evolution;

-- Uma segunda sessão de fixture valida apenas que as gerações ficam comparáveis.
SET @next_generation_session = '66666666-6666-4666-8666-666666666666';
CALL sp_nn_decide(@next_generation_session, 'g1-npc-1', 1, 100, 100, 400, 1, 10, @run, @action, @confidence);
CALL sp_nn_decide(@next_generation_session, 'g1-npc-2', 2, 100, 100, 800, 1, 20, @run, @action, @confidence);
CALL sp_nn_decide(@next_generation_session, 'g1-npc-3', 3, 100, 100, 1200, 0, 30, @run, @action, @confidence);
CALL sp_nn_decide(@next_generation_session, 'g1-npc-4', 4, 100, 100, 1600, 0, 40, @run, @action, @confidence);
CALL sp_nn_record_combat_event(
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1',
    @next_generation_session, 'g1-npc-1', 'PLAYER_DAMAGE', 15
);
CALL sp_nn_close_session(@next_generation_session);
CALL sp_nn_evaluate_session(@next_generation_session);

DROP PROCEDURE IF EXISTS test_assert_generation_comparison;
DELIMITER $$
CREATE PROCEDURE test_assert_generation_comparison()
BEGIN
    DECLARE v_generations INT DEFAULT 0;
    DECLARE v_complete_generations INT DEFAULT 0;
    DECLARE v_with_fitness INT DEFAULT 0;

    SELECT COUNT(*), SUM(completa), SUM(fitness_medio IS NOT NULL)
    INTO v_generations, v_complete_generations, v_with_fitness
    FROM nn_generation_summary
    WHERE architecture_id = (SELECT id FROM nn_architecture WHERE nome = 'npc_teste_4_6_4')
      AND geracao IN (0, 1);

    IF v_generations <> 2 OR v_complete_generations <> 2 OR v_with_fitness <> 2 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Resumo de desempenho das duas gerações incompleto';
    END IF;
END$$
DELIMITER ;

CALL test_assert_generation_comparison();
DROP PROCEDURE test_assert_generation_comparison;

SELECT 'OK: elite por fitness, crossover, mutação limitada e evolução bloqueada sem avaliação.' AS resultado;
