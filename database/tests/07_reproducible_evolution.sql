-- Teste exclusivamente matemático/SQL; eventos fixture não são evidência de aprendizado.
-- Requer os scripts 01–09 instalados em um schema isolado de testes.
DROP PROCEDURE IF EXISTS test_ensure_seeded_architecture;
DELIMITER $$
CREATE PROCEDURE test_ensure_seeded_architecture(IN p_name VARCHAR(50))
BEGIN
    IF NOT EXISTS (SELECT 1 FROM nn_architecture WHERE nome = p_name) THEN
        CALL sp_nn_create_configurable_architecture(
            p_name, JSON_ARRAY(4, 2, 4), 'relu'
        );
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM nn_genome g JOIN nn_architecture a ON a.id = g.architecture_id
        WHERE a.nome = p_name
    ) THEN
        CALL sp_nn_create_seeded_population(p_name, 2, 8675309);
    END IF;
END$$
DELIMITER ;

CALL test_ensure_seeded_architecture('npc_repro_a');
CALL test_ensure_seeded_architecture('npc_repro_b');
DROP PROCEDURE test_ensure_seeded_architecture;

DROP PROCEDURE IF EXISTS test_ensure_unseeded_architecture;
DELIMITER $$
CREATE PROCEDURE test_ensure_unseeded_architecture()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM nn_architecture WHERE nome = 'npc_unseeded_smoke'
    ) THEN
        CALL sp_nn_create_configurable_architecture(
            'npc_unseeded_smoke', JSON_ARRAY(4, 2, 4), 'relu'
        );
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM nn_genome g JOIN nn_architecture a ON a.id = g.architecture_id
        WHERE a.nome = 'npc_unseeded_smoke'
    ) THEN
        CALL sp_nn_create_initial_population('npc_unseeded_smoke', 2);
    END IF;
END$$
DELIMITER ;

CALL test_ensure_unseeded_architecture();
DROP PROCEDURE test_ensure_unseeded_architecture;

DROP PROCEDURE IF EXISTS test_reproducible_population_and_evolution;
DELIMITER $$
CREATE PROCEDURE test_reproducible_population_and_evolution()
BEGIN
    DECLARE v_genome_weight_differences BIGINT DEFAULT 0;
    DECLARE v_genome_bias_differences BIGINT DEFAULT 0;
    DECLARE v_child_weight_differences BIGINT DEFAULT 0;
    DECLARE v_child_bias_differences BIGINT DEFAULT 0;
    DECLARE v_invalid_child_count INT DEFAULT 0;
    DECLARE v_population_a INT DEFAULT 0;
    DECLARE v_population_b INT DEFAULT 0;
    DECLARE v_session_a CHAR(36) DEFAULT NULL;
    DECLARE v_session_b CHAR(36) DEFAULT NULL;
    DECLARE v_unseeded_session CHAR(36) DEFAULT NULL;
    DECLARE v_unseeded_children INT DEFAULT 0;
    DECLARE v_run_id BIGINT DEFAULT 0;
    DECLARE v_action VARCHAR(16) DEFAULT NULL;
    DECLARE v_confidence DOUBLE DEFAULT 0;

    DROP TEMPORARY TABLE IF EXISTS tmp_nn_repro_genomes_a;
    DROP TEMPORARY TABLE IF EXISTS tmp_nn_repro_genomes_b;
    CREATE TEMPORARY TABLE tmp_nn_repro_genomes_a (
        genome_order INT NOT NULL,
        genome_id INT NOT NULL,
        PRIMARY KEY (genome_order)
    ) ENGINE=MEMORY;
    CREATE TEMPORARY TABLE tmp_nn_repro_genomes_b (
        genome_order INT NOT NULL,
        genome_id INT NOT NULL,
        PRIMARY KEY (genome_order)
    ) ENGINE=MEMORY;

    INSERT INTO tmp_nn_repro_genomes_a (genome_order, genome_id)
    SELECT genome_order, genome_id
    FROM (
        SELECT arquitetura.nome AS architecture_name, genoma.id AS genome_id,
            ROW_NUMBER() OVER (PARTITION BY arquitetura.id ORDER BY genoma.id) AS genome_order
        FROM nn_genome genoma
        JOIN nn_architecture arquitetura ON arquitetura.id = genoma.architecture_id
        WHERE arquitetura.nome = 'npc_repro_a'
          AND genoma.geracao = 0
    ) populacao;
    INSERT INTO tmp_nn_repro_genomes_b (genome_order, genome_id)
    SELECT genome_order, genome_id
    FROM (
        SELECT arquitetura.nome AS architecture_name, genoma.id AS genome_id,
            ROW_NUMBER() OVER (PARTITION BY arquitetura.id ORDER BY genoma.id) AS genome_order
        FROM nn_genome genoma
        JOIN nn_architecture arquitetura ON arquitetura.id = genoma.architecture_id
        WHERE arquitetura.nome = 'npc_repro_b'
          AND genoma.geracao = 0
    ) populacao;

    SELECT COUNT(*) INTO v_population_a FROM tmp_nn_repro_genomes_a;
    SELECT COUNT(*) INTO v_population_b FROM tmp_nn_repro_genomes_b;
    IF v_population_a <> 2 OR v_population_b <> 2 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'População com semente incorreta';
    END IF;

    SELECT COUNT(*) INTO v_genome_weight_differences
    FROM tmp_nn_repro_genomes_a ga
    JOIN tmp_nn_repro_genomes_b gb ON gb.genome_order = ga.genome_order
    JOIN nn_genome_weight wa ON wa.genome_id = ga.genome_id
    JOIN nn_synapse sa ON sa.id = wa.synapse_id
    JOIN nn_neuron soa ON soa.id = sa.from_neuron_id
    JOIN nn_layer sla ON sla.id = soa.layer_id
    JOIN nn_neuron sda ON sda.id = sa.to_neuron_id
    JOIN nn_layer dla ON dla.id = sda.layer_id
    JOIN nn_genome_weight wb ON wb.genome_id = gb.genome_id
    JOIN nn_synapse sb ON sb.id = wb.synapse_id
    JOIN nn_neuron sob ON sob.id = sb.from_neuron_id
    JOIN nn_layer slb ON slb.id = sob.layer_id
    JOIN nn_neuron sdb ON sdb.id = sb.to_neuron_id
    JOIN nn_layer dlb ON dlb.id = sdb.layer_id
    WHERE sla.ordem = slb.ordem AND soa.posicao = sob.posicao
      AND dla.ordem = dlb.ordem AND sda.posicao = sdb.posicao
      AND NOT (wa.peso <=> wb.peso);

    SELECT COUNT(*) INTO v_genome_bias_differences
    FROM tmp_nn_repro_genomes_a ga
    JOIN tmp_nn_repro_genomes_b gb ON gb.genome_order = ga.genome_order
    JOIN nn_genome_bias ba ON ba.genome_id = ga.genome_id
    JOIN nn_neuron na ON na.id = ba.neuron_id
    JOIN nn_layer la ON la.id = na.layer_id
    JOIN nn_genome_bias bb ON bb.genome_id = gb.genome_id
    JOIN nn_neuron nb ON nb.id = bb.neuron_id
    JOIN nn_layer lb ON lb.id = nb.layer_id
    WHERE la.ordem = lb.ordem AND na.posicao = nb.posicao
      AND NOT (ba.bias <=> bb.bias);

    IF v_genome_weight_differences <> 0 OR v_genome_bias_differences <> 0 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'A mesma semente gerou populações diferentes';
    END IF;

    SET v_session_a = UUID();
    CALL sp_nn_decide_for_architecture(
        'npc_repro_a', v_session_a, 'repro-a-1', 1, 100, 100, 512, 1, 0,
        v_run_id, v_action, v_confidence
    );
    CALL sp_nn_decide_for_architecture(
        'npc_repro_a', v_session_a, 'repro-a-2', 1, 100, 100, 512, 1, 0,
        v_run_id, v_action, v_confidence
    );
    CALL sp_nn_record_combat_event(UUID(), v_session_a, 'repro-a-1', 'PLAYER_DAMAGE', 10);
    CALL sp_nn_record_combat_event(UUID(), v_session_a, 'repro-a-2', 'PLAYER_DAMAGE', 20);
    CALL sp_nn_finish_session(v_session_a);

    SET v_session_b = UUID();
    CALL sp_nn_decide_for_architecture(
        'npc_repro_b', v_session_b, 'repro-b-1', 1, 100, 100, 512, 1, 0,
        v_run_id, v_action, v_confidence
    );
    CALL sp_nn_decide_for_architecture(
        'npc_repro_b', v_session_b, 'repro-b-2', 1, 100, 100, 512, 1, 0,
        v_run_id, v_action, v_confidence
    );
    CALL sp_nn_record_combat_event(UUID(), v_session_b, 'repro-b-1', 'PLAYER_DAMAGE', 10);
    CALL sp_nn_record_combat_event(UUID(), v_session_b, 'repro-b-2', 'PLAYER_DAMAGE', 20);
    CALL sp_nn_finish_session(v_session_b);

    IF NOT EXISTS (
        SELECT 1 FROM nn_genome g JOIN nn_architecture a ON a.id = g.architecture_id
        WHERE a.nome = 'npc_repro_a' AND g.geracao = 1
    ) THEN
        CALL sp_nn_evolve_generation_seeded('npc_repro_a', 0, 2, 0.25, 20261025);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM nn_genome g JOIN nn_architecture a ON a.id = g.architecture_id
        WHERE a.nome = 'npc_repro_b' AND g.geracao = 1
    ) THEN
        CALL sp_nn_evolve_generation_seeded('npc_repro_b', 0, 2, 0.25, 20261025);
    END IF;

    DELETE FROM tmp_nn_repro_genomes_a;
    DELETE FROM tmp_nn_repro_genomes_b;
    INSERT INTO tmp_nn_repro_genomes_a (genome_order, genome_id)
    SELECT genome_order, genome_id
    FROM (
        SELECT arquitetura.nome AS architecture_name, genoma.id AS genome_id,
            ROW_NUMBER() OVER (PARTITION BY arquitetura.id ORDER BY genoma.id) AS genome_order
        FROM nn_genome genoma
        JOIN nn_architecture arquitetura ON arquitetura.id = genoma.architecture_id
        WHERE arquitetura.nome = 'npc_repro_a'
          AND genoma.geracao = 1
    ) filhos;
    INSERT INTO tmp_nn_repro_genomes_b (genome_order, genome_id)
    SELECT genome_order, genome_id
    FROM (
        SELECT arquitetura.nome AS architecture_name, genoma.id AS genome_id,
            ROW_NUMBER() OVER (PARTITION BY arquitetura.id ORDER BY genoma.id) AS genome_order
        FROM nn_genome genoma
        JOIN nn_architecture arquitetura ON arquitetura.id = genoma.architecture_id
        WHERE arquitetura.nome = 'npc_repro_b'
          AND genoma.geracao = 1
    ) filhos;

    SELECT COUNT(*) INTO v_child_weight_differences
    FROM tmp_nn_repro_genomes_a ga
    JOIN tmp_nn_repro_genomes_b gb ON gb.genome_order = ga.genome_order
    JOIN nn_genome_weight wa ON wa.genome_id = ga.genome_id
    JOIN nn_synapse sa ON sa.id = wa.synapse_id
    JOIN nn_neuron soa ON soa.id = sa.from_neuron_id
    JOIN nn_layer sla ON sla.id = soa.layer_id
    JOIN nn_neuron sda ON sda.id = sa.to_neuron_id
    JOIN nn_layer dla ON dla.id = sda.layer_id
    JOIN nn_genome_weight wb ON wb.genome_id = gb.genome_id
    JOIN nn_synapse sb ON sb.id = wb.synapse_id
    JOIN nn_neuron sob ON sob.id = sb.from_neuron_id
    JOIN nn_layer slb ON slb.id = sob.layer_id
    JOIN nn_neuron sdb ON sdb.id = sb.to_neuron_id
    JOIN nn_layer dlb ON dlb.id = sdb.layer_id
    WHERE sla.ordem = slb.ordem AND soa.posicao = sob.posicao
      AND dla.ordem = dlb.ordem AND sda.posicao = sdb.posicao
      AND NOT (wa.peso <=> wb.peso);

    SELECT COUNT(*) INTO v_child_bias_differences
    FROM tmp_nn_repro_genomes_a ga
    JOIN tmp_nn_repro_genomes_b gb ON gb.genome_order = ga.genome_order
    JOIN nn_genome_bias ba ON ba.genome_id = ga.genome_id
    JOIN nn_neuron na ON na.id = ba.neuron_id
    JOIN nn_layer la ON la.id = na.layer_id
    JOIN nn_genome_bias bb ON bb.genome_id = gb.genome_id
    JOIN nn_neuron nb ON nb.id = bb.neuron_id
    JOIN nn_layer lb ON lb.id = nb.layer_id
    WHERE la.ordem = lb.ordem AND na.posicao = nb.posicao
      AND NOT (ba.bias <=> bb.bias);

    SELECT COUNT(*) INTO v_invalid_child_count
    FROM nn_genome filho
    JOIN nn_architecture arquitetura ON arquitetura.id = filho.architecture_id
    WHERE arquitetura.nome IN ('npc_repro_a', 'npc_repro_b')
      AND filho.geracao = 1
      AND ((SELECT COUNT(*) FROM nn_genome_weight peso WHERE peso.genome_id = filho.id) <> 16
           OR (SELECT COUNT(*) FROM nn_genome_bias bias WHERE bias.genome_id = filho.id) <> 6
           OR filho.pai1_id IS NULL OR filho.pai2_id IS NULL);

    IF v_child_weight_differences <> 0 OR v_child_bias_differences <> 0
       OR v_invalid_child_count <> 0 OR @nn_population_seed IS NOT NULL
       OR @nn_evolution_seed IS NOT NULL THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Crossover/mutação semeados não foram reproduzíveis ou íntegros';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM nn_genome genoma
        JOIN nn_architecture arquitetura ON arquitetura.id = genoma.architecture_id
        WHERE arquitetura.nome = 'npc_unseeded_smoke' AND genoma.geracao = 1
    ) THEN
        SET v_unseeded_session = UUID();
        CALL sp_nn_decide_for_architecture(
            'npc_unseeded_smoke', v_unseeded_session, 'unseeded-1',
            1, 100, 100, 512, 1, 0, v_run_id, v_action, v_confidence
        );
        CALL sp_nn_decide_for_architecture(
            'npc_unseeded_smoke', v_unseeded_session, 'unseeded-2',
            1, 100, 100, 512, 1, 0, v_run_id, v_action, v_confidence
        );
        CALL sp_nn_record_combat_event(
            UUID(), v_unseeded_session, 'unseeded-1', 'PLAYER_DAMAGE', 10
        );
        CALL sp_nn_record_combat_event(
            UUID(), v_unseeded_session, 'unseeded-2', 'PLAYER_DAMAGE', 20
        );
        CALL sp_nn_finish_session(v_unseeded_session);
        CALL sp_nn_evolve_generation('npc_unseeded_smoke', 0, 2, 0.25);
    END IF;

    SELECT COUNT(*) INTO v_unseeded_children
    FROM nn_genome genoma
    JOIN nn_architecture arquitetura ON arquitetura.id = genoma.architecture_id
    WHERE arquitetura.nome = 'npc_unseeded_smoke' AND genoma.geracao = 1
      AND (SELECT COUNT(*) FROM nn_genome_weight peso
           WHERE peso.genome_id = genoma.id) = 16
      AND (SELECT COUNT(*) FROM nn_genome_bias bias
           WHERE bias.genome_id = genoma.id) = 6;
    IF v_unseeded_children <> 2 THEN
        SIGNAL SQLSTATE '45001' SET MESSAGE_TEXT = 'Evolução aleatória compatível não manteve a topologia';
    END IF;

    DROP TEMPORARY TABLE tmp_nn_repro_genomes_a;
    DROP TEMPORARY TABLE tmp_nn_repro_genomes_b;
END$$
DELIMITER ;

CALL test_reproducible_population_and_evolution();
DROP PROCEDURE test_reproducible_population_and_evolution;

SELECT 'OK: populações/filhos semeados reproduzíveis, evolução aleatória compatível e topologia íntegra. Eventos fixture não comprovam aprendizado.' AS resultado;
