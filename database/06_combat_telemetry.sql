CREATE TABLE IF NOT EXISTS nn_combat_event (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    event_id CHAR(36) NOT NULL,
    session_id CHAR(36) NOT NULL,
    engine_npc_id VARCHAR(64) NOT NULL,
    event_type ENUM('PLAYER_DAMAGE','PLAYER_KILL','NPC_DAMAGE','NPC_DEATH') NOT NULL,
    valor INT UNSIGNED NOT NULL,
    criado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_nn_combat_event_id (event_id),
    FOREIGN KEY (session_id, engine_npc_id)
        REFERENCES nn_session_npc(session_id, engine_npc_id) ON DELETE CASCADE,
    INDEX idx_nn_combat_session_npc (session_id, engine_npc_id, event_type),
    INDEX idx_nn_combat_created (criado_em)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_genome_evaluation (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    session_id CHAR(36) NOT NULL,
    genome_id INT NOT NULL,
    damage_to_player BIGINT UNSIGNED NOT NULL DEFAULT 0,
    player_kills INT UNSIGNED NOT NULL DEFAULT 0,
    damage_received BIGINT UNSIGNED NOT NULL DEFAULT 0,
    npc_deaths INT UNSIGNED NOT NULL DEFAULT 0,
    survival_seconds BIGINT UNSIGNED NOT NULL DEFAULT 0,
    fitness DECIMAL(14,4) NOT NULL,
    avaliado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_nn_evaluation_session_genome (session_id, genome_id),
    FOREIGN KEY (session_id) REFERENCES nn_engine_session(session_id) ON DELETE CASCADE,
    FOREIGN KEY (genome_id) REFERENCES nn_genome(id),
    INDEX idx_nn_evaluation_genome (genome_id, fitness)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_generation_summary (
    architecture_id INT NOT NULL,
    geracao INT NOT NULL,
    tamanho_populacao INT UNSIGNED NOT NULL,
    individuos_avaliados INT UNSIGNED NOT NULL,
    fitness_medio DECIMAL(14,4) NULL,
    melhor_fitness DECIMAL(14,4) NULL,
    pior_fitness DECIMAL(14,4) NULL,
    completa TINYINT(1) NOT NULL DEFAULT 0,
    atualizado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (architecture_id, geracao),
    FOREIGN KEY (architecture_id) REFERENCES nn_architecture(id) ON DELETE CASCADE
) ENGINE=InnoDB;

DROP PROCEDURE IF EXISTS sp_nn_record_combat_event;
DROP PROCEDURE IF EXISTS sp_nn_close_session;
DROP PROCEDURE IF EXISTS sp_nn_evaluate_session;
DROP PROCEDURE IF EXISTS sp_nn_finish_session;
DELIMITER $$
CREATE PROCEDURE sp_nn_record_combat_event(
    IN p_event_id CHAR(36),
    IN p_session_id CHAR(36),
    IN p_engine_npc_id VARCHAR(64),
    IN p_event_type VARCHAR(20),
    IN p_value INT UNSIGNED
)
BEGIN
    DECLARE v_session_ended TIMESTAMP DEFAULT NULL;
    DECLARE v_npc_count INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_event_id IS NULL OR p_session_id IS NULL
       OR IS_UUID(p_event_id) <> 1 OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID do evento ou da sessão inválido';
    END IF;
    IF p_engine_npc_id IS NULL OR CHAR_LENGTH(TRIM(p_engine_npc_id)) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID do NPC do engine inválido';
    END IF;
    IF p_event_type IS NULL
       OR p_event_type NOT IN ('PLAYER_DAMAGE','PLAYER_KILL','NPC_DAMAGE','NPC_DEATH') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Tipo de evento de combate inválido';
    END IF;
    IF p_value IS NULL OR p_value = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'O valor do evento deve ser positivo';
    END IF;
    IF p_event_type IN ('PLAYER_KILL','NPC_DEATH') AND p_value <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Eventos de morte devem ter valor 1';
    END IF;

    SELECT COUNT(*) INTO v_npc_count
    FROM nn_session_npc
    WHERE session_id = p_session_id AND engine_npc_id = p_engine_npc_id;
    IF v_npc_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NPC não registrado nesta sessão';
    END IF;

    SELECT encerrada_em INTO v_session_ended
    FROM nn_engine_session
    WHERE session_id = p_session_id;
    IF v_session_ended IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A sessão já foi encerrada';
    END IF;

    INSERT IGNORE INTO nn_combat_event (
        event_id, session_id, engine_npc_id, event_type, valor
    ) VALUES (
        p_event_id, p_session_id, p_engine_npc_id, p_event_type, p_value
    );
END$$

CREATE PROCEDURE sp_nn_close_session(IN p_session_id CHAR(36))
BEGIN
    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
    END IF;

    UPDATE nn_engine_session
    SET encerrada_em = COALESCE(encerrada_em, CURRENT_TIMESTAMP)
    WHERE session_id = p_session_id;
END$$

CREATE PROCEDURE sp_nn_evaluate_session(IN p_session_id CHAR(36))
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_session_count INT DEFAULT 0;
    DECLARE v_npc_count INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
    END IF;

    SELECT COUNT(*), MAX(architecture_id) INTO v_session_count, v_architecture_id
    FROM nn_engine_session WHERE session_id = p_session_id;
    IF v_session_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão não encontrada';
    END IF;

    SELECT COUNT(*) INTO v_npc_count
    FROM nn_session_npc WHERE session_id = p_session_id;
    IF v_npc_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A sessão não possui NPCs avaliáveis';
    END IF;

    START TRANSACTION;
    UPDATE nn_engine_session
    SET encerrada_em = COALESCE(encerrada_em, CURRENT_TIMESTAMP)
    WHERE session_id = p_session_id;

    INSERT INTO nn_genome_evaluation (
        session_id, genome_id, damage_to_player, player_kills,
        damage_received, npc_deaths, survival_seconds, fitness
    )
    SELECT p_session_id,
        avaliacoes.genome_id,
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
                COALESCE(eventos.npc_died_at, sessao.encerrada_em)
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
        damage_to_player = VALUES(damage_to_player),
        player_kills = VALUES(player_kills),
        damage_received = VALUES(damage_received),
        npc_deaths = VALUES(npc_deaths),
        survival_seconds = VALUES(survival_seconds),
        fitness = VALUES(fitness),
        avaliado_em = CURRENT_TIMESTAMP;

    UPDATE nn_genome g
    SET g.fitness = (
        SELECT AVG(e.fitness)
        FROM nn_genome_evaluation e
        WHERE e.genome_id = g.id
    )
    WHERE g.architecture_id = v_architecture_id
      AND EXISTS (SELECT 1 FROM nn_genome_evaluation e WHERE e.genome_id = g.id);

    INSERT INTO nn_generation_summary (
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
        SELECT g.id, g.architecture_id, g.geracao, g.fitness,
            EXISTS (
                SELECT 1 FROM nn_genome_evaluation e
                WHERE e.genome_id = g.id
            ) AS avaliado
        FROM nn_genome g
        WHERE g.architecture_id = v_architecture_id
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

CREATE PROCEDURE sp_nn_finish_session(IN p_session_id CHAR(36))
BEGIN
    DECLARE v_session_count INT DEFAULT 0;
    DECLARE v_npc_count INT DEFAULT 0;

    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
    END IF;

    SELECT COUNT(*) INTO v_session_count
    FROM nn_engine_session WHERE session_id = p_session_id;

    IF v_session_count > 0 THEN
        SELECT COUNT(*) INTO v_npc_count
        FROM nn_session_npc WHERE session_id = p_session_id;

        IF v_npc_count > 0 THEN
            CALL sp_nn_evaluate_session(p_session_id);
        ELSE
            CALL sp_nn_close_session(p_session_id);
        END IF;
    END IF;
END$$
DELIMITER ;
