-- Additive migration for the corrected engine event attribution.
-- Select exactly one isolated target schema before running this file:
--   neural_doom_local_game_20261024 OR neural_doom_local_sql_test_20261024
-- This file never creates, drops, or selects a database. Existing sessions and
-- evaluations stay legacy; the app account only needs EXECUTE on new routines.

SELECT VERSION() AS mysql_version, DATABASE() AS selected_schema;

DROP PROCEDURE IF EXISTS sp_nn_install_attack_provenance_v2;
DELIMITER $$
CREATE PROCEDURE sp_nn_install_attack_provenance_v2()
BEGIN
    DECLARE v_tables INT DEFAULT 0;

    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Migration permitida somente nos dois schemas isolados Neural Doom';
    END IF;

    SELECT COUNT(*) INTO v_tables
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name = 'nn_engine_session';
    IF v_tables = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Instale primeiro o schema base de sessões';
    END IF;

    -- Version membership is additive and separate: existing session rows and
    -- the legacy evaluation/fitness tables are never rewritten.
    CREATE TABLE IF NOT EXISTS nn_engine_session_provenance_v2 (
        session_id CHAR(36) PRIMARY KEY,
        attribution_version VARCHAR(40) NOT NULL,
        registrado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (session_id) REFERENCES nn_engine_session(session_id)
    ) ENGINE=InnoDB;

    CREATE TABLE IF NOT EXISTS nn_genome_evaluation_v2 (
        id BIGINT AUTO_INCREMENT PRIMARY KEY,
        session_id CHAR(36) NOT NULL,
        genome_id INT NOT NULL,
        attribution_version VARCHAR(40) NOT NULL,
        damage_to_player BIGINT UNSIGNED NOT NULL DEFAULT 0,
        player_kills INT UNSIGNED NOT NULL DEFAULT 0,
        damage_received BIGINT UNSIGNED NOT NULL DEFAULT 0,
        npc_deaths INT UNSIGNED NOT NULL DEFAULT 0,
        survival_seconds BIGINT UNSIGNED NOT NULL DEFAULT 0,
        fitness DECIMAL(14,4) NOT NULL,
        avaliado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE KEY uq_nn_evaluation_v2_session_genome (session_id, genome_id),
        FOREIGN KEY (session_id) REFERENCES nn_engine_session(session_id),
        FOREIGN KEY (genome_id) REFERENCES nn_genome(id),
        INDEX idx_nn_evaluation_v2_genome (genome_id, fitness)
    ) ENGINE=InnoDB;

    CREATE TABLE IF NOT EXISTS nn_generation_summary_v2 (
        architecture_id INT NOT NULL,
        geracao INT NOT NULL,
        tamanho_populacao INT UNSIGNED NOT NULL,
        individuos_avaliados INT UNSIGNED NOT NULL,
        fitness_medio DECIMAL(14,4) NULL,
        melhor_fitness DECIMAL(14,4) NULL,
        pior_fitness DECIMAL(14,4) NULL,
        completa TINYINT(1) NOT NULL DEFAULT 0,
        atualizado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (architecture_id, geracao),
        FOREIGN KEY (architecture_id) REFERENCES nn_architecture(id)
    ) ENGINE=InnoDB;
END$$
CALL sp_nn_install_attack_provenance_v2()$$
DROP PROCEDURE sp_nn_install_attack_provenance_v2$$

DROP PROCEDURE IF EXISTS sp_nn_mark_session_v2$$
CREATE PROCEDURE sp_nn_mark_session_v2(IN p_session_id CHAR(36))
BEGIN
    DECLARE v_session_count INT DEFAULT 0;
    DECLARE v_session_ended TIMESTAMP DEFAULT NULL;
    DECLARE v_attribution_version VARCHAR(40) DEFAULT NULL;

    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Marcação v2 permitida somente nos dois schemas isolados Neural Doom';
    END IF;
    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
    END IF;

    SELECT COUNT(*) INTO v_session_count
    FROM nn_engine_session WHERE session_id = p_session_id;
    IF v_session_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão não encontrada para marcação v2';
    END IF;
    SELECT encerrada_em INTO v_session_ended
    FROM nn_engine_session WHERE session_id = p_session_id;
    IF v_session_ended IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão encerrada não pode ser marcada v2';
    END IF;

    INSERT IGNORE INTO nn_engine_session_provenance_v2 (
        session_id, attribution_version
    ) VALUES (p_session_id, 'neural_attack_provenance_v2');

    SELECT attribution_version INTO v_attribution_version
    FROM nn_engine_session_provenance_v2 WHERE session_id = p_session_id;
    IF v_attribution_version <> 'neural_attack_provenance_v2' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Versão de proveniência da sessão incompatível';
    END IF;
END$$

DROP PROCEDURE IF EXISTS sp_nn_evaluate_session_v2$$
CREATE PROCEDURE sp_nn_evaluate_session_v2(IN p_session_id CHAR(36))
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_session_count INT DEFAULT 0;
    DECLARE v_npc_count INT DEFAULT 0;
    DECLARE v_evaluated_count INT DEFAULT 0;

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
            SET MESSAGE_TEXT = 'Avaliação v2 permitida somente nos dois schemas isolados Neural Doom';
    END IF;
    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
    END IF;

    START TRANSACTION;
    SELECT COUNT(*) INTO v_session_count
    FROM nn_engine_session WHERE session_id = p_session_id;
    IF v_session_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão não encontrada';
    END IF;

    SELECT architecture_id INTO v_architecture_id
    FROM nn_engine_session
    WHERE session_id = p_session_id
    FOR UPDATE;

    IF NOT EXISTS (
        SELECT 1 FROM nn_engine_session_provenance_v2
        WHERE session_id = p_session_id
          AND attribution_version = 'neural_attack_provenance_v2'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Sessão legada não pode ser avaliada pelo pipeline v2';
    END IF;

    SELECT COUNT(*) INTO v_npc_count
    FROM nn_session_npc WHERE session_id = p_session_id;
    IF v_npc_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A sessão não possui NPCs avaliáveis';
    END IF;

    UPDATE nn_engine_session
    SET encerrada_em = COALESCE(encerrada_em, CURRENT_TIMESTAMP)
    WHERE session_id = p_session_id;

    INSERT INTO nn_genome_evaluation_v2 (
        session_id, genome_id, attribution_version, damage_to_player,
        player_kills, damage_received, npc_deaths, survival_seconds, fitness
    )
    SELECT p_session_id,
        avaliacoes.genome_id,
        'neural_attack_provenance_v2',
        SUM(avaliacoes.damage_to_player),
        SUM(avaliacoes.player_kills),
        SUM(avaliacoes.damage_received),
        SUM(avaliacoes.npc_deaths),
        SUM(avaliacoes.survival_seconds),
        SUM(avaliacoes.damage_to_player)
            + SUM(avaliacoes.player_kills) * 100
            - SUM(avaliacoes.damage_received) * 0.25
            - SUM(avaliacoes.npc_deaths) * 50
            + SUM(avaliacoes.survival_seconds) / 60.0
    FROM (
        SELECT npc.genome_id,
            COALESCE(eventos.damage_to_player, 0) AS damage_to_player,
            COALESCE(eventos.player_kills, 0) AS player_kills,
            COALESCE(eventos.damage_received, 0) AS damage_received,
            COALESCE(eventos.npc_deaths, 0) AS npc_deaths,
            GREATEST(TIMESTAMPDIFF(
                SECOND,
                npc.criado_em,
                COALESCE(eventos.npc_died_at, sessao.encerrada_em,
                         CURRENT_TIMESTAMP)
            ), 0) AS survival_seconds
        FROM nn_session_npc npc
        JOIN nn_engine_session sessao ON sessao.session_id = npc.session_id
        LEFT JOIN (
            SELECT session_id, engine_npc_id,
                SUM(CASE WHEN event_type = 'PLAYER_DAMAGE' THEN valor ELSE 0 END) AS damage_to_player,
                SUM(CASE WHEN event_type = 'PLAYER_KILL' THEN valor ELSE 0 END) AS player_kills,
                SUM(CASE WHEN event_type = 'NPC_DAMAGE' THEN valor ELSE 0 END) AS damage_received,
                SUM(CASE WHEN event_type = 'NPC_DEATH' THEN valor ELSE 0 END) AS npc_deaths,
                MIN(CASE WHEN event_type = 'NPC_DEATH' THEN criado_em END) AS npc_died_at
            FROM nn_combat_event
            WHERE session_id = p_session_id
            GROUP BY session_id, engine_npc_id
        ) eventos ON eventos.session_id = npc.session_id
                 AND eventos.engine_npc_id = npc.engine_npc_id
        WHERE npc.session_id = p_session_id
    ) avaliacoes
    GROUP BY avaliacoes.genome_id
    ON DUPLICATE KEY UPDATE
        attribution_version = VALUES(attribution_version),
        damage_to_player = VALUES(damage_to_player),
        player_kills = VALUES(player_kills),
        damage_received = VALUES(damage_received),
        npc_deaths = VALUES(npc_deaths),
        survival_seconds = VALUES(survival_seconds),
        fitness = VALUES(fitness),
        avaliado_em = CURRENT_TIMESTAMP;

    SELECT COUNT(*) INTO v_evaluated_count
    FROM nn_genome_evaluation_v2
    WHERE session_id = p_session_id;
    IF v_evaluated_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Nenhuma avaliação v2 foi persistida';
    END IF;

    INSERT INTO nn_generation_summary_v2 (
        architecture_id, geracao, tamanho_populacao, individuos_avaliados,
        fitness_medio, melhor_fitness, pior_fitness, completa
    )
    SELECT avaliados.architecture_id, avaliados.geracao,
        COUNT(*) AS tamanho_populacao,
        SUM(avaliados.avaliado) AS individuos_avaliados,
        AVG(CASE WHEN avaliados.avaliado = 1 THEN avaliados.fitness END) AS fitness_medio,
        MAX(CASE WHEN avaliados.avaliado = 1 THEN avaliados.fitness END) AS melhor_fitness,
        MIN(CASE WHEN avaliados.avaliado = 1 THEN avaliados.fitness END) AS pior_fitness,
        SUM(avaliados.avaliado) = COUNT(*) AS completa
    FROM (
        SELECT g.id, g.architecture_id, g.geracao, AVG(e.fitness) AS fitness,
            EXISTS (
                SELECT 1 FROM nn_genome_evaluation_v2 e2
                WHERE e2.genome_id = g.id
            ) AS avaliado
        FROM nn_genome g
        LEFT JOIN nn_genome_evaluation_v2 e
          ON e.genome_id = g.id
         AND e.attribution_version = 'neural_attack_provenance_v2'
        WHERE g.architecture_id = v_architecture_id
        GROUP BY g.id, g.architecture_id, g.geracao
    ) avaliados
    GROUP BY avaliados.architecture_id, avaliados.geracao
    ON DUPLICATE KEY UPDATE
        tamanho_populacao = VALUES(tamanho_populacao),
        individuos_avaliados = VALUES(individuos_avaliados),
        fitness_medio = VALUES(fitness_medio),
        melhor_fitness = VALUES(melhor_fitness),
        pior_fitness = VALUES(pior_fitness),
        completa = VALUES(completa),
        atualizado_em = CURRENT_TIMESTAMP;

    COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_nn_finish_session_v2$$
CREATE PROCEDURE sp_nn_finish_session_v2(IN p_session_id CHAR(36))
BEGIN
    DECLARE v_session_count INT DEFAULT 0;
    DECLARE v_evaluated_count INT DEFAULT 0;

    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Encerramento v2 permitido somente nos dois schemas isolados Neural Doom';
    END IF;
    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
    END IF;

    SELECT COUNT(*)
    INTO v_session_count
    FROM nn_engine_session WHERE session_id = p_session_id;
    IF v_session_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão não encontrada';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM nn_engine_session_provenance_v2
        WHERE session_id = p_session_id
          AND attribution_version = 'neural_attack_provenance_v2'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Sessão legada não pode receber ACK de avaliação v2';
    END IF;

    CALL sp_nn_evaluate_session_v2(p_session_id);

    SELECT COUNT(*) INTO v_evaluated_count
    FROM nn_genome_evaluation_v2 WHERE session_id = p_session_id;
    IF v_evaluated_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Encerramento recusado: avaliação v2 não foi persistida';
    END IF;
END$$
DELIMITER ;

SELECT 'OK: atribuição v2 instalada sem alterar avaliações ou fitness legados.' AS resultado;
