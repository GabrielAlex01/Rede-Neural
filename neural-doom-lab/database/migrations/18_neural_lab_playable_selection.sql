-- Refreshes the playable architecture catalog and adds exact-genome session
-- selection. It changes procedures only in the two isolated Neural Doom schemas.
-- No architectures, genomes, sessions, or evaluation rows are rewritten.

SELECT VERSION() AS mysql_version, DATABASE() AS selected_schema;

DROP PROCEDURE IF EXISTS sp_nn_lab_list_architectures;
DROP PROCEDURE IF EXISTS sp_nn_select_session_genome_v2;

DELIMITER $$

CREATE PROCEDURE sp_nn_lab_list_architectures()
BEGIN
    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Laboratório permitido somente nos schemas isolados Neural Doom';
    END IF;

    SELECT a.id AS architecture_id,
           a.nome AS architecture_name,
           a.n_entradas AS input_count,
           a.n_saidas AS output_count,
           COALESCE((
               SELECT GROUP_CONCAT(
                   (SELECT COUNT(*) FROM nn_neuron n WHERE n.layer_id = l.id)
                   ORDER BY l.ordem SEPARATOR ' -> '
               )
               FROM nn_layer l
               WHERE l.architecture_id = a.id
           ), '') AS topology,
           (SELECT COUNT(*) FROM nn_layer l WHERE l.architecture_id = a.id) AS layer_count,
           (SELECT COUNT(*) FROM nn_neuron n JOIN nn_layer l ON l.id = n.layer_id
            WHERE l.architecture_id = a.id) AS neuron_count,
           (SELECT COUNT(*) FROM nn_synapse s
            JOIN nn_neuron source_neuron ON source_neuron.id = s.from_neuron_id
            JOIN nn_layer source_layer ON source_layer.id = source_neuron.layer_id
            WHERE source_layer.architecture_id = a.id) AS weight_count,
           (SELECT COUNT(*) FROM nn_neuron n JOIN nn_layer l ON l.id = n.layer_id
            WHERE l.architecture_id = a.id AND l.tipo IN ('hidden', 'output')) AS bias_count,
           (SELECT COUNT(*) FROM nn_genome g WHERE g.architecture_id = a.id) AS genome_count,
           (SELECT COUNT(DISTINCT g.geracao) FROM nn_genome g WHERE g.architecture_id = a.id) AS generation_count,
           (SELECT MAX(g.geracao) FROM nn_genome g WHERE g.architecture_id = a.id) AS latest_generation,
           CASE WHEN training.experiment_count IS NOT NULL
                THEN training.active_generation
                ELSE (SELECT MAX(g.geracao) FROM nn_genome g WHERE g.architecture_id = a.id)
           END AS playable_generation,
           CASE
             WHEN a.n_entradas <> 4 OR a.n_saidas <> 4 THEN 0
             WHEN training.experiment_count IS NULL THEN EXISTS (
                 SELECT 1 FROM nn_genome g
                 WHERE g.architecture_id = a.id
                   AND g.geracao = (SELECT MAX(latest.geracao)
                                    FROM nn_genome latest
                                    WHERE latest.architecture_id = a.id)
             )
             WHEN training.experiment_count = 1
              AND training.evaluating_generation_count = 1
              AND EXISTS (
                  SELECT 1 FROM nn_training_experiment_genome_v2 member
                  WHERE member.experiment_id = training.experiment_id
                    AND member.generation = training.active_generation
              ) THEN 1
             ELSE 0
           END AS playable
    FROM nn_architecture a
    LEFT JOIN (
        SELECT experiment.architecture_id,
               COUNT(DISTINCT experiment.experiment_id) AS experiment_count,
               MAX(experiment.experiment_id) AS experiment_id,
               COUNT(generation.generation) AS evaluating_generation_count,
               MAX(generation.generation) AS active_generation
        FROM nn_training_experiment_v2 experiment
        LEFT JOIN nn_training_generation_v2 generation
          ON generation.experiment_id = experiment.experiment_id
         AND generation.status = 'EVALUATING'
        GROUP BY experiment.architecture_id
    ) training ON training.architecture_id = a.id
    ORDER BY a.nome;
END$$

CREATE PROCEDURE sp_nn_select_session_genome_v2(
    IN p_architecture_name VARCHAR(50),
    IN p_session_id CHAR(36),
    IN p_engine_npc_id VARCHAR(64),
    IN p_npc_type SMALLINT UNSIGNED,
    IN p_health INT,
    IN p_max_health INT,
    IN p_genome_id INT
)
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_genome_architecture_id INT DEFAULT NULL;
    DECLARE v_genome_generation INT DEFAULT NULL;
    DECLARE v_latest_generation INT DEFAULT NULL;
    DECLARE v_experiment_count INT DEFAULT 0;
    DECLARE v_experiment_id CHAR(36) DEFAULT NULL;
    DECLARE v_evaluating_count INT DEFAULT 0;
    DECLARE v_evaluating_generation INT DEFAULT NULL;
    DECLARE v_member_count INT DEFAULT 0;
    DECLARE v_session_count INT DEFAULT 0;
    DECLARE v_session_architecture_id INT DEFAULT NULL;
    DECLARE v_session_ended TIMESTAMP DEFAULT NULL;
    DECLARE v_npc_count INT DEFAULT 0;
    DECLARE v_existing_genome_id INT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Seleção de genoma permitida somente nos schemas isolados Neural Doom';
    END IF;
    IF p_architecture_name IS NULL OR CHAR_LENGTH(TRIM(p_architecture_name)) = 0
       OR p_session_id IS NULL OR IS_UUID(p_session_id) <> 1
       OR p_engine_npc_id IS NULL OR CHAR_LENGTH(TRIM(p_engine_npc_id)) = 0
       OR p_health IS NULL OR p_max_health IS NULL OR p_max_health <= 0
       OR p_health < 0 OR p_health > p_max_health
       OR p_genome_id IS NULL OR p_genome_id < 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Seleção de genoma inválida';
    END IF;

    SELECT id INTO v_architecture_id
    FROM nn_architecture
    WHERE nome = p_architecture_name AND n_entradas = 4 AND n_saidas = 4;
    IF v_architecture_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Arquitetura ausente ou incompatível';
    END IF;

    SELECT architecture_id, geracao
      INTO v_genome_architecture_id, v_genome_generation
    FROM nn_genome
    WHERE id = p_genome_id;
    IF v_genome_architecture_id IS NULL OR v_genome_architecture_id <> v_architecture_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Genoma não pertence à arquitetura selecionada';
    END IF;

    SELECT COUNT(*), MAX(experiment_id)
      INTO v_experiment_count, v_experiment_id
    FROM nn_training_experiment_v2
    WHERE architecture_id = v_architecture_id;
    IF v_experiment_count > 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Arquitetura associada a múltiplos experimentos v2';
    ELSEIF v_experiment_count = 1 THEN
        SELECT COUNT(*), MAX(generation)
          INTO v_evaluating_count, v_evaluating_generation
        FROM nn_training_generation_v2
        WHERE experiment_id = v_experiment_id AND status = 'EVALUATING';
        IF v_evaluating_count <> 1 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Experimento v2 sem uma geração utilizável';
        END IF;
        SELECT COUNT(*) INTO v_member_count
        FROM nn_training_experiment_genome_v2
        WHERE experiment_id = v_experiment_id
          AND generation = v_evaluating_generation
          AND genome_id = p_genome_id;
        IF v_member_count <> 1 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Genoma não pertence à geração v2 aberta';
        END IF;
    ELSE
        SELECT MAX(geracao) INTO v_latest_generation
        FROM nn_genome
        WHERE architecture_id = v_architecture_id;
        IF v_genome_generation <> v_latest_generation THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Somente a geração mais recente pode iniciar partidas';
        END IF;
    END IF;

    START TRANSACTION;
    INSERT IGNORE INTO nn_engine_session (session_id, architecture_id)
    VALUES (p_session_id, v_architecture_id);

    SELECT COUNT(*) INTO v_session_count
    FROM nn_engine_session
    WHERE session_id = p_session_id;
    IF v_session_count <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Não foi possível abrir a sessão neural';
    END IF;
    SELECT architecture_id, encerrada_em
      INTO v_session_architecture_id, v_session_ended
    FROM nn_engine_session
    WHERE session_id = p_session_id
    FOR UPDATE;
    IF v_session_architecture_id <> v_architecture_id OR v_session_ended IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão encerrada ou associada a outra arquitetura';
    END IF;

    SELECT COUNT(*) INTO v_npc_count
    FROM nn_session_npc
    WHERE session_id = p_session_id AND engine_npc_id = p_engine_npc_id;
    IF v_npc_count = 0 THEN
        INSERT INTO nn_session_npc (
            session_id, engine_npc_id, npc_type, genome_id, max_health, last_health
        ) VALUES (
            p_session_id, p_engine_npc_id, p_npc_type, p_genome_id, p_max_health, p_health
        );
    ELSE
        SELECT genome_id INTO v_existing_genome_id
        FROM nn_session_npc
        WHERE session_id = p_session_id AND engine_npc_id = p_engine_npc_id
        FOR UPDATE;
        IF v_existing_genome_id <> p_genome_id THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NPC já está associado a outro genoma';
        END IF;
    END IF;
    COMMIT;
END$$

DELIMITER ;
