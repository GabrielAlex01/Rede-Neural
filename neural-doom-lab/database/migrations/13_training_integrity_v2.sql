-- Additive integrity layer for v2 training and end-of-session ACK receipt.
-- Run only in one isolated Neural Doom schema. No historical table is altered.
-- Existing evaluation rows are never rewritten or reclassified retroactively.

SELECT VERSION() AS mysql_version, DATABASE() AS selected_schema;

DROP PROCEDURE IF EXISTS sp_nn_assert_training_integrity_schema_v2;
DELIMITER $$
CREATE PROCEDURE sp_nn_assert_training_integrity_schema_v2()
BEGIN
    DECLARE v_required_tables INT DEFAULT 0;

    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Migration permitida somente nos dois schemas isolados Neural Doom';
    END IF;

    SELECT COUNT(*) INTO v_required_tables
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name IN (
          'nn_engine_session', 'nn_engine_session_provenance_v2',
          'nn_genome_evaluation_v2'
      );
    IF v_required_tables <> 3 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Instale primeiro o schema base e a migration de proveniência v2';
    END IF;
END$$
CALL sp_nn_assert_training_integrity_schema_v2()$$
DROP PROCEDURE sp_nn_assert_training_integrity_schema_v2$$
DELIMITER ;

-- Keep trusted training evaluations separate from the existing v2 reporting
-- table. This avoids ALTER permission requirements and preserves old rows.
CREATE TABLE IF NOT EXISTS nn_training_session_registration_v2 (
    session_id CHAR(36) PRIMARY KEY,
    fitness_version VARCHAR(40) NOT NULL,
    registered_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    FOREIGN KEY (session_id) REFERENCES nn_engine_session(session_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_genome_evaluation_training_v2 (
    session_id CHAR(36) NOT NULL,
    genome_id INT NOT NULL,
    attribution_version VARCHAR(40) NOT NULL,
    fitness_version VARCHAR(40) NOT NULL,
    damage_to_player BIGINT UNSIGNED NOT NULL,
    player_kills INT UNSIGNED NOT NULL,
    damage_received BIGINT UNSIGNED NOT NULL,
    npc_deaths INT UNSIGNED NOT NULL,
    survival_seconds BIGINT UNSIGNED NOT NULL,
    fitness DECIMAL(14,4) NOT NULL,
    copied_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (session_id, genome_id),
    KEY idx_nn_training_eval_genome_version_v2 (genome_id, fitness_version, fitness),
    CONSTRAINT fk_nn_training_eval_source_v2
        FOREIGN KEY (session_id, genome_id)
        REFERENCES nn_genome_evaluation_v2(session_id, genome_id),
    CONSTRAINT fk_nn_training_eval_registration_v2
        FOREIGN KEY (session_id)
        REFERENCES nn_training_session_registration_v2(session_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_training_session_completion_v2 (
    session_id CHAR(36) PRIMARY KEY,
    ack_token CHAR(36) NOT NULL,
    fitness_version VARCHAR(40) NOT NULL,
    evaluation_count INT UNSIGNED NOT NULL,
    completed_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    ack_confirmed_at TIMESTAMP(6) NULL,
    UNIQUE KEY uq_nn_training_ack_token_v2 (ack_token),
    FOREIGN KEY (session_id) REFERENCES nn_training_session_registration_v2(session_id)
) ENGINE=InnoDB;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_nn_register_training_session_v2$$
CREATE PROCEDURE sp_nn_register_training_session_v2(IN p_session_id CHAR(36))
BEGIN
    DECLARE v_session_count INT DEFAULT 0;
    DECLARE v_open_count INT DEFAULT 0;
    DECLARE v_npc_count INT DEFAULT 0;
    DECLARE v_registration_version VARCHAR(40) DEFAULT NULL;

    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Registro de treinamento permitido somente nos dois schemas isolados Neural Doom';
    END IF;
    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
    END IF;

    SELECT COUNT(*), SUM(encerrada_em IS NULL)
      INTO v_session_count, v_open_count
    FROM nn_engine_session WHERE session_id = p_session_id;
    IF v_session_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão não encontrada';
    END IF;
    IF COALESCE(v_open_count, 0) <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Sessão encerrada não pode ser registrada retroativamente para treinamento';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM nn_engine_session_provenance_v2
        WHERE session_id = p_session_id
          AND attribution_version = 'neural_attack_provenance_v2'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Sessão sem proveniência v2 não pode ser registrada para treinamento';
    END IF;
    SELECT COUNT(*) INTO v_npc_count
    FROM nn_session_npc WHERE session_id = p_session_id;
    IF v_npc_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão sem NPCs atribuídos a genomas';
    END IF;

    SELECT MAX(fitness_version) INTO v_registration_version
    FROM nn_training_session_registration_v2
    WHERE session_id = p_session_id;
    IF v_registration_version IS NULL THEN
        INSERT INTO nn_training_session_registration_v2 (session_id, fitness_version)
        VALUES (p_session_id, 'combat_outcome_v2_1');
    ELSEIF v_registration_version <> 'combat_outcome_v2_1' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Sessão já registrada em outra versão de fitness';
    END IF;
END$$

DROP PROCEDURE IF EXISTS sp_nn_finish_session_training_v2$$
CREATE PROCEDURE sp_nn_finish_session_training_v2(
    IN p_session_id CHAR(36),
    OUT p_ack_token CHAR(36)
)
BEGIN
    finish_training_session: BEGIN
        DECLARE v_session_count INT DEFAULT 0;
        DECLARE v_existing_ack CHAR(36) DEFAULT NULL;
        DECLARE v_registered_version VARCHAR(40) DEFAULT NULL;
        DECLARE v_invalid_evaluation_count INT DEFAULT 0;
        DECLARE v_evaluation_count INT DEFAULT 0;
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
                SET MESSAGE_TEXT = 'Encerramento permitido somente nos dois schemas isolados Neural Doom';
        END IF;
        IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
        END IF;

        SELECT MAX(ack_token) INTO v_existing_ack
        FROM nn_training_session_completion_v2
        WHERE session_id = p_session_id;
        IF v_existing_ack IS NOT NULL THEN
            SET p_ack_token = v_existing_ack;
            LEAVE finish_training_session;
        END IF;

        SELECT MAX(fitness_version) INTO v_registered_version
        FROM nn_training_session_registration_v2
        WHERE session_id = p_session_id;
        IF v_registered_version IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Sessão não foi registrada antes do encerramento; avaliação retroativa recusada';
        END IF;
        IF v_registered_version <> 'combat_outcome_v2_1' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Versão de fitness da sessão incompatível';
        END IF;

        SELECT COUNT(*) INTO v_session_count
        FROM nn_engine_session WHERE session_id = p_session_id;
        IF v_session_count = 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão não encontrada';
        END IF;

        -- The existing evaluator owns its own transaction. It is safe to call
        -- again after a partial retry because v2 evaluation is idempotent.
        CALL sp_nn_finish_session_v2(p_session_id);

        SELECT COUNT(*) INTO v_invalid_evaluation_count
        FROM nn_genome_evaluation_v2 e
        WHERE e.session_id = p_session_id
          AND (
              e.attribution_version <> 'neural_attack_provenance_v2'
              OR e.fitness <> CAST(
                  e.damage_to_player
                  + (e.player_kills * 100.0)
                  - (e.damage_received * 0.25)
                  - (e.npc_deaths * 50.0)
                  + (e.survival_seconds / 60.0)
                  AS DECIMAL(14,4)
              )
          );
        IF v_invalid_evaluation_count <> 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Fitness v2 diverge da fórmula de combate; ACK recusado';
        END IF;

        START TRANSACTION;
        INSERT INTO nn_genome_evaluation_training_v2 (
            session_id, genome_id, attribution_version, fitness_version,
            damage_to_player, player_kills, damage_received, npc_deaths,
            survival_seconds, fitness
        )
        SELECT e.session_id, e.genome_id, e.attribution_version,
            'combat_outcome_v2_1', e.damage_to_player, e.player_kills,
            e.damage_received, e.npc_deaths, e.survival_seconds, e.fitness
        FROM nn_genome_evaluation_v2 e
        WHERE e.session_id = p_session_id
          AND e.attribution_version = 'neural_attack_provenance_v2'
          AND e.fitness = CAST(
              e.damage_to_player
              + (e.player_kills * 100.0)
              - (e.damage_received * 0.25)
              - (e.npc_deaths * 50.0)
              + (e.survival_seconds / 60.0)
              AS DECIMAL(14,4)
          )
        ON DUPLICATE KEY UPDATE
            attribution_version = VALUES(attribution_version),
            fitness_version = VALUES(fitness_version),
            damage_to_player = VALUES(damage_to_player),
            player_kills = VALUES(player_kills),
            damage_received = VALUES(damage_received),
            npc_deaths = VALUES(npc_deaths),
            survival_seconds = VALUES(survival_seconds),
            fitness = VALUES(fitness),
            copied_at = CURRENT_TIMESTAMP(6);

        SELECT COUNT(*) INTO v_evaluation_count
        FROM nn_genome_evaluation_training_v2
        WHERE session_id = p_session_id
          AND fitness_version = 'combat_outcome_v2_1';
        IF v_evaluation_count = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Sessão não produziu avaliação de treinamento v2';
        END IF;

        SET p_ack_token = UUID();
        INSERT INTO nn_training_session_completion_v2 (
            session_id, ack_token, fitness_version, evaluation_count
        ) VALUES (
            p_session_id, p_ack_token, 'combat_outcome_v2_1', v_evaluation_count
        );
        COMMIT;
    END finish_training_session;
END$$

DROP PROCEDURE IF EXISTS sp_nn_confirm_training_ack_v2$$
CREATE PROCEDURE sp_nn_confirm_training_ack_v2(
    IN p_session_id CHAR(36),
    IN p_ack_token CHAR(36)
)
BEGIN
    DECLARE v_matches INT DEFAULT 0;

    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Confirmação de ACK permitida somente nos dois schemas isolados Neural Doom';
    END IF;
    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1
       OR p_ack_token IS NULL OR IS_UUID(p_ack_token) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão ou token de ACK inválido';
    END IF;

    UPDATE nn_training_session_completion_v2
    SET ack_confirmed_at = COALESCE(ack_confirmed_at, CURRENT_TIMESTAMP(6))
    WHERE session_id = p_session_id AND ack_token = p_ack_token;
    SET v_matches = ROW_COUNT();

    IF v_matches = 0 AND NOT EXISTS (
        SELECT 1 FROM nn_training_session_completion_v2
        WHERE session_id = p_session_id
          AND ack_token = p_ack_token
          AND ack_confirmed_at IS NOT NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Token de ACK não corresponde a uma sessão concluída';
    END IF;
END$$
DELIMITER ;

SELECT 'OK: avaliação de treinamento e ACK versionados sem alterar avaliações históricas.' AS resultado;
