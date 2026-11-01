-- Isolated, MySQL-only experiment catalog for trusted-fitness genetics v2.
-- Run only in the two isolated Neural Doom schemas. No legacy table is altered.
SELECT VERSION() AS mysql_version, DATABASE() AS selected_schema;

DROP PROCEDURE IF EXISTS sp_nn_assert_genetic_experiments_schema_v2;
DELIMITER $$
CREATE PROCEDURE sp_nn_assert_genetic_experiments_schema_v2()
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
          'nn_engine_session', 'nn_genome', 'nn_genome_evaluation_training_v2',
          'nn_training_session_registration_v2', 'nn_training_session_completion_v2'
      );
    IF v_required_tables <> 5 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Instale as migrations base, proveniência e integridade de treinamento v2 primeiro';
    END IF;
END$$
CALL sp_nn_assert_genetic_experiments_schema_v2()$$
DROP PROCEDURE sp_nn_assert_genetic_experiments_schema_v2$$
DELIMITER ;

CREATE TABLE IF NOT EXISTS nn_training_experiment_v2 (
    experiment_id CHAR(36) PRIMARY KEY,
    experiment_name VARCHAR(80) NOT NULL,
    architecture_id INT NOT NULL,
    topology_json JSON NOT NULL,
    hidden_activation VARCHAR(10) NOT NULL,
    seed BIGINT UNSIGNED NOT NULL,
    population_size SMALLINT UNSIGNED NOT NULL,
    mutation_rate DECIMAL(7,6) NOT NULL,
    planned_generations SMALLINT UNSIGNED NOT NULL,
    evaluations_per_genome SMALLINT UNSIGNED NOT NULL,
    condition_label VARCHAR(120) NOT NULL,
    trainable_parameters INT UNSIGNED NOT NULL,
    created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    UNIQUE KEY uq_nn_training_exp_v2_name (experiment_name),
    UNIQUE KEY uq_nn_training_exp_v2_architecture (architecture_id),
    CONSTRAINT fk_nn_training_exp_v2_architecture
        FOREIGN KEY (architecture_id) REFERENCES nn_architecture(id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_training_generation_v2 (
    experiment_id CHAR(36) NOT NULL,
    generation INT UNSIGNED NOT NULL,
    seed BIGINT UNSIGNED NOT NULL,
    mutation_rate DECIMAL(7,6) NOT NULL,
    elite_count SMALLINT UNSIGNED NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'EVALUATING',
    population_size SMALLINT UNSIGNED NOT NULL,
    evaluations_per_genome SMALLINT UNSIGNED NOT NULL,
    evaluated_genomes SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    evaluation_count INT UNSIGNED NOT NULL DEFAULT 0,
    fitness_mean DECIMAL(14,4) NULL,
    best_fitness DECIMAL(14,4) NULL,
    worst_fitness DECIMAL(14,4) NULL,
    created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    completed_at TIMESTAMP(6) NULL,
    PRIMARY KEY (experiment_id, generation),
    CONSTRAINT chk_nn_training_generation_v2_status
        CHECK (status IN ('EVALUATING', 'EVOLVED', 'COMPLETE')),
    CONSTRAINT fk_nn_training_generation_v2_experiment
        FOREIGN KEY (experiment_id) REFERENCES nn_training_experiment_v2(experiment_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_training_experiment_genome_v2 (
    experiment_id CHAR(36) NOT NULL,
    generation INT UNSIGNED NOT NULL,
    genome_id INT NOT NULL,
    parent1_genome_id INT NULL,
    parent2_genome_id INT NULL,
    created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (experiment_id, generation, genome_id),
    UNIQUE KEY uq_nn_training_v2_genome (genome_id),
    KEY idx_nn_training_v2_member_generation (experiment_id, generation),
    CONSTRAINT fk_nn_training_v2_member_generation
        FOREIGN KEY (experiment_id, generation)
        REFERENCES nn_training_generation_v2(experiment_id, generation),
    CONSTRAINT fk_nn_training_v2_member_genome
        FOREIGN KEY (genome_id) REFERENCES nn_genome(id),
    CONSTRAINT fk_nn_training_v2_parent1
        FOREIGN KEY (parent1_genome_id) REFERENCES nn_genome(id),
    CONSTRAINT fk_nn_training_v2_parent2
        FOREIGN KEY (parent2_genome_id) REFERENCES nn_genome(id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_training_experiment_session_v2 (
    session_id CHAR(36) PRIMARY KEY,
    experiment_id CHAR(36) NOT NULL,
    generation INT UNSIGNED NOT NULL,
    condition_label VARCHAR(120) NOT NULL,
    registered_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    KEY idx_nn_training_v2_session_generation (experiment_id, generation, registered_at),
    CONSTRAINT fk_nn_training_v2_session_generation
        FOREIGN KEY (experiment_id, generation)
        REFERENCES nn_training_generation_v2(experiment_id, generation),
    CONSTRAINT fk_nn_training_v2_session_engine
        FOREIGN KEY (session_id) REFERENCES nn_engine_session(session_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_training_genome_score_v2 (
    experiment_id CHAR(36) NOT NULL,
    generation INT UNSIGNED NOT NULL,
    genome_id INT NOT NULL,
    evaluations_used SMALLINT UNSIGNED NOT NULL,
    fitness_mean DECIMAL(14,4) NOT NULL,
    fitness_best DECIMAL(14,4) NOT NULL,
    fitness_worst DECIMAL(14,4) NOT NULL,
    damage_to_player BIGINT UNSIGNED NOT NULL,
    player_kills INT UNSIGNED NOT NULL,
    damage_received BIGINT UNSIGNED NOT NULL,
    npc_deaths INT UNSIGNED NOT NULL,
    survival_seconds BIGINT UNSIGNED NOT NULL,
    recorded_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (experiment_id, generation, genome_id),
    CONSTRAINT fk_nn_training_v2_score_member
        FOREIGN KEY (experiment_id, generation, genome_id)
        REFERENCES nn_training_experiment_genome_v2(experiment_id, generation, genome_id)
) ENGINE=InnoDB;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_nn_create_genetic_experiment_v2$$
CREATE PROCEDURE sp_nn_create_genetic_experiment_v2(
    IN p_experiment_name VARCHAR(80),
    IN p_architecture_name VARCHAR(50),
    IN p_topology JSON,
    IN p_hidden_activation VARCHAR(10),
    IN p_seed BIGINT UNSIGNED,
    IN p_population_size INT,
    IN p_mutation_rate DECIMAL(7,6),
    IN p_planned_generations INT,
    IN p_evaluations_per_genome INT,
    IN p_condition_label VARCHAR(120),
    OUT p_experiment_id CHAR(36)
)
experiment_create: BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_existing_count INT DEFAULT 0;
    DECLARE v_exact_existing_count INT DEFAULT 0;
    DECLARE v_existing_experiment_id CHAR(36) DEFAULT NULL;
    DECLARE v_trainable_parameters INT DEFAULT 0;
    DECLARE v_created_genomes INT DEFAULT 0;
    DECLARE v_created_members INT DEFAULT 0;
    DECLARE v_topology_text LONGTEXT DEFAULT NULL;

    IF DATABASE() NOT IN (
        'neural_doom_local_game_20261024',
        'neural_doom_local_sql_test_20261024'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Criação de experimento permitida somente nos dois schemas isolados Neural Doom';
    END IF;
    IF p_experiment_name IS NULL OR CHAR_LENGTH(TRIM(p_experiment_name)) = 0
       OR p_architecture_name IS NULL OR CHAR_LENGTH(TRIM(p_architecture_name)) = 0
       OR p_topology IS NULL OR JSON_TYPE(p_topology) <> 'ARRAY'
       OR p_hidden_activation IS NULL OR p_hidden_activation NOT IN ('sigmoid', 'relu', 'tanh')
       OR p_seed IS NULL OR p_seed > 4294967295
       OR p_population_size IS NULL OR p_population_size < 4 OR p_population_size > 100
       OR p_mutation_rate IS NULL OR p_mutation_rate < 0 OR p_mutation_rate > 0.5
       OR p_planned_generations IS NULL OR p_planned_generations < 2 OR p_planned_generations > 50
       OR p_evaluations_per_genome IS NULL OR p_evaluations_per_genome < 1 OR p_evaluations_per_genome > 100
       OR p_condition_label IS NULL OR CHAR_LENGTH(TRIM(p_condition_label)) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Parâmetros do experimento genético v2 inválidos';
    END IF;

    SELECT COUNT(*) INTO v_exact_existing_count
    FROM nn_training_experiment_v2 experiment
    JOIN nn_architecture architecture ON architecture.id = experiment.architecture_id
    WHERE experiment.experiment_name = p_experiment_name
      AND architecture.nome = p_architecture_name
      AND CAST(experiment.topology_json AS CHAR) = CAST(p_topology AS CHAR)
      AND experiment.hidden_activation = p_hidden_activation
      AND experiment.seed = p_seed
      AND experiment.population_size = p_population_size
      AND experiment.mutation_rate = p_mutation_rate
      AND experiment.planned_generations = p_planned_generations
      AND experiment.evaluations_per_genome = p_evaluations_per_genome
      AND experiment.condition_label = p_condition_label;
    IF v_exact_existing_count = 1 THEN
        SELECT experiment_id INTO p_experiment_id
        FROM nn_training_experiment_v2
        WHERE experiment_name = p_experiment_name;
        SELECT p_experiment_id AS experiment_id,
               p_experiment_name AS experiment_name,
               p_architecture_name AS architecture_name,
               'EXPERIMENTO EXISTENTE, CONFIGURAÇÃO CONFERIDA' AS result;
        LEAVE experiment_create;
    END IF;

    SELECT COUNT(*) INTO v_existing_count
    FROM nn_training_experiment_v2 experiment
    JOIN nn_architecture architecture ON architecture.id = experiment.architecture_id
    WHERE experiment.experiment_name = p_experiment_name
       OR architecture.nome = p_architecture_name;
    SELECT v_existing_count + COUNT(*) INTO v_existing_count
    FROM nn_architecture
    WHERE nome = p_architecture_name
      AND id NOT IN (
          SELECT architecture_id FROM nn_training_experiment_v2
      );
    IF v_existing_count <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Nome/arquitetura já existe com outra configuração; nada foi sobrescrito';
    END IF;

    CALL sp_nn_create_configurable_architecture(
        p_architecture_name, p_topology, p_hidden_activation
    );
    SELECT id INTO v_architecture_id
    FROM nn_architecture WHERE nome = p_architecture_name;
    CALL sp_nn_create_seeded_population(
        p_architecture_name, p_population_size, p_seed
    );

    SELECT
        (SELECT COUNT(*) FROM nn_synapse synapse
         JOIN nn_neuron source_neuron ON source_neuron.id = synapse.from_neuron_id
         JOIN nn_layer source_layer ON source_layer.id = source_neuron.layer_id
         JOIN nn_neuron target_neuron ON target_neuron.id = synapse.to_neuron_id
         JOIN nn_layer target_layer ON target_layer.id = target_neuron.layer_id
         WHERE source_layer.architecture_id = v_architecture_id
           AND target_layer.architecture_id = v_architecture_id)
        +
        (SELECT COUNT(*) FROM nn_neuron neuron
         JOIN nn_layer layer ON layer.id = neuron.layer_id
         WHERE layer.architecture_id = v_architecture_id AND layer.tipo IN ('hidden','output'))
    INTO v_trainable_parameters;
    SELECT COUNT(*) INTO v_created_genomes
    FROM nn_genome
    WHERE architecture_id = v_architecture_id AND geracao = 0;
    IF v_created_genomes <> p_population_size THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'População inicial incompleta; experimento v2 não foi cadastrado';
    END IF;

    SET p_experiment_id = UUID();
    START TRANSACTION;
    INSERT INTO nn_training_experiment_v2 (
        experiment_id, experiment_name, architecture_id, topology_json,
        hidden_activation, seed, population_size, mutation_rate,
        planned_generations, evaluations_per_genome, condition_label,
        trainable_parameters
    ) VALUES (
        p_experiment_id, p_experiment_name, v_architecture_id, p_topology,
        p_hidden_activation, p_seed, p_population_size, p_mutation_rate,
        p_planned_generations, p_evaluations_per_genome, p_condition_label,
        v_trainable_parameters
    );
    INSERT INTO nn_training_generation_v2 (
        experiment_id, generation, seed, mutation_rate, status,
        population_size, evaluations_per_genome
    ) VALUES (
        p_experiment_id, 0, p_seed, p_mutation_rate, 'EVALUATING',
        p_population_size, p_evaluations_per_genome
    );
    INSERT INTO nn_training_experiment_genome_v2 (
        experiment_id, generation, genome_id
    )
    SELECT p_experiment_id, 0, id
    FROM nn_genome
    WHERE architecture_id = v_architecture_id AND geracao = 0
    ORDER BY id;
    SET v_created_members = ROW_COUNT();
    IF v_created_members <> p_population_size THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Membros da população v2 não correspondem ao tamanho configurado';
    END IF;
    COMMIT;

    SELECT p_experiment_id AS experiment_id,
           p_experiment_name AS experiment_name,
           p_architecture_name AS architecture_name,
           p_topology AS topology,
           v_trainable_parameters AS trainable_parameters,
           p_population_size AS population_size,
           p_seed AS seed;
END$$

DROP PROCEDURE IF EXISTS sp_nn_register_training_session_v2$$
CREATE PROCEDURE sp_nn_register_training_session_v2(IN p_session_id CHAR(36))
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_session_count INT DEFAULT 0;
    DECLARE v_session_ended TIMESTAMP DEFAULT NULL;
    DECLARE v_npc_count INT DEFAULT 0;
    DECLARE v_registration_version VARCHAR(40) DEFAULT NULL;
    DECLARE v_experiment_count INT DEFAULT 0;
    DECLARE v_experiment_id CHAR(36) DEFAULT NULL;
    DECLARE v_generation_count INT DEFAULT 0;
    DECLARE v_generation INT DEFAULT NULL;
    DECLARE v_generation_status VARCHAR(16) DEFAULT NULL;
    DECLARE v_existing_experiment_id CHAR(36) DEFAULT NULL;
    DECLARE v_existing_generation INT DEFAULT NULL;
    DECLARE v_condition_label VARCHAR(120) DEFAULT NULL;
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
            SET MESSAGE_TEXT = 'Registro permitido somente nos dois schemas isolados Neural Doom';
    END IF;
    IF p_session_id IS NULL OR IS_UUID(p_session_id) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ID da sessão inválido';
    END IF;

    START TRANSACTION;
    SELECT COUNT(*), MAX(architecture_id), MAX(encerrada_em)
      INTO v_session_count, v_architecture_id, v_session_ended
    FROM nn_engine_session WHERE session_id = p_session_id;
    IF v_session_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sessão não encontrada';
    END IF;
    IF v_session_ended IS NOT NULL THEN
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

    INSERT IGNORE INTO nn_training_session_registration_v2 (session_id, fitness_version)
    VALUES (p_session_id, 'combat_outcome_v2_1');
    SELECT fitness_version INTO v_registration_version
    FROM nn_training_session_registration_v2 WHERE session_id = p_session_id;
    IF v_registration_version <> 'combat_outcome_v2_1' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Versão de fitness da sessão incompatível';
    END IF;

    SELECT COUNT(*), MAX(experiment_id)
      INTO v_experiment_count, v_experiment_id
    FROM nn_training_experiment_v2
    WHERE architecture_id = v_architecture_id;
    IF v_experiment_count > 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Arquitetura associada a mais de um experimento v2';
    END IF;
    IF v_experiment_count = 1 THEN
        SELECT COUNT(*), MAX(generation)
          INTO v_generation_count, v_generation
        FROM nn_training_generation_v2
        WHERE experiment_id = v_experiment_id AND status = 'EVALUATING';
        IF v_generation_count <> 1 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Experimento v2 não possui exatamente uma geração aberta para avaliações';
        END IF;
        SELECT status INTO v_generation_status
        FROM nn_training_generation_v2
        WHERE experiment_id = v_experiment_id AND generation = v_generation
        FOR UPDATE;
        IF v_generation_status <> 'EVALUATING' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Geração v2 não está aceitando sessões';
        END IF;
        SELECT condition_label INTO v_condition_label
        FROM nn_training_experiment_v2 WHERE experiment_id = v_experiment_id;

        INSERT IGNORE INTO nn_training_experiment_session_v2 (
            session_id, experiment_id, generation, condition_label
        ) VALUES (
            p_session_id, v_experiment_id, v_generation, v_condition_label
        );
        SELECT experiment_id, generation
          INTO v_existing_experiment_id, v_existing_generation
        FROM nn_training_experiment_session_v2
        WHERE session_id = p_session_id;
        IF v_existing_experiment_id <> v_experiment_id
           OR v_existing_generation <> v_generation THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Sessão já associada a outro experimento/geração v2';
        END IF;
    END IF;
    COMMIT;
END$$
DELIMITER ;

SELECT 'OK: tabelas de experimentos v2 criadas; gerações e avaliações antigas permanecem isoladas.' AS result;
