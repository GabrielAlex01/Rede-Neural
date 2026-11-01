-- Registro de parâmetros/ sementes e vínculo automático das sessões da partida.
CREATE TABLE IF NOT EXISTS nn_training_experiment (
    experiment_id CHAR(36) PRIMARY KEY,
    nome VARCHAR(80) NOT NULL,
    architecture_id INT NOT NULL,
    seed BIGINT UNSIGNED NOT NULL,
    population_size SMALLINT UNSIGNED NOT NULL,
    mutation_rate DECIMAL(7,6) NOT NULL,
    planned_generations SMALLINT UNSIGNED NOT NULL,
    evaluations_per_genome SMALLINT UNSIGNED NOT NULL,
    condition_label VARCHAR(120) NOT NULL,
    trainable_parameters INT UNSIGNED NOT NULL,
    criado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_nn_training_experiment_name (nome),
    UNIQUE KEY uq_nn_training_experiment_architecture (architecture_id),
    FOREIGN KEY (architecture_id) REFERENCES nn_architecture(id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_training_experiment_generation (
    experiment_id CHAR(36) NOT NULL,
    geracao INT UNSIGNED NOT NULL,
    seed BIGINT UNSIGNED NOT NULL,
    mutation_rate DECIMAL(7,6) NOT NULL,
    elite_count SMALLINT UNSIGNED NULL,
    criado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (experiment_id, geracao),
    FOREIGN KEY (experiment_id)
        REFERENCES nn_training_experiment(experiment_id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nn_training_experiment_session (
    experiment_id CHAR(36) NOT NULL,
    session_id CHAR(36) NOT NULL,
    associado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (experiment_id, session_id),
    UNIQUE KEY uq_nn_training_session (session_id),
    FOREIGN KEY (experiment_id)
        REFERENCES nn_training_experiment(experiment_id) ON DELETE CASCADE,
    FOREIGN KEY (session_id)
        REFERENCES nn_engine_session(session_id) ON DELETE CASCADE
) ENGINE=InnoDB;

DROP PROCEDURE IF EXISTS sp_nn_create_training_experiment;
DROP PROCEDURE IF EXISTS sp_nn_evolve_training_experiment;
DELIMITER $$
CREATE PROCEDURE sp_nn_create_training_experiment(
    IN p_experiment_name VARCHAR(80),
    IN p_architecture_name VARCHAR(50),
    IN p_seed BIGINT UNSIGNED,
    IN p_population_size INT,
    IN p_mutation_rate DOUBLE,
    IN p_planned_generations INT,
    IN p_evaluations_per_genome INT,
    IN p_condition_label VARCHAR(120)
)
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_experiment_id CHAR(36) DEFAULT NULL;
    DECLARE v_input_count INT DEFAULT 0;
    DECLARE v_output_count INT DEFAULT 0;
    DECLARE v_existing_genomes INT DEFAULT 0;
    DECLARE v_trainable_parameters INT DEFAULT 0;

    IF p_experiment_name IS NULL OR CHAR_LENGTH(TRIM(p_experiment_name)) = 0
       OR p_architecture_name IS NULL OR CHAR_LENGTH(TRIM(p_architecture_name)) = 0
       OR p_condition_label IS NULL OR CHAR_LENGTH(TRIM(p_condition_label)) = 0
       OR p_seed IS NULL OR p_seed > 4294967295
       OR p_population_size IS NULL OR p_population_size < 2 OR p_population_size > 100
       OR p_mutation_rate IS NULL OR p_mutation_rate < 0 OR p_mutation_rate > 1
       OR p_planned_generations IS NULL OR p_planned_generations < 1 OR p_planned_generations > 50
       OR p_evaluations_per_genome IS NULL
       OR p_evaluations_per_genome < 1 OR p_evaluations_per_genome > 100 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Parâmetros do experimento inválidos';
    END IF;

    SELECT id, n_entradas, n_saidas
    INTO v_architecture_id, v_input_count, v_output_count
    FROM nn_architecture WHERE nome = p_architecture_name;
    IF v_architecture_id IS NULL OR v_input_count <> 4 OR v_output_count <> 4 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Arquitetura inexistente ou incompatível com o engine';
    END IF;

    SELECT COUNT(*) INTO v_existing_genomes
    FROM nn_genome WHERE architecture_id = v_architecture_id;
    IF v_existing_genomes <> 0 OR EXISTS (
        SELECT 1 FROM nn_training_experiment
        WHERE nome = p_experiment_name OR architecture_id = v_architecture_id
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Experimento/arquitetura já utilizado; nada foi sobrescrito';
    END IF;

    SELECT
        (SELECT COUNT(*) FROM nn_synapse s
         JOIN nn_neuron origem ON origem.id = s.from_neuron_id
         JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
         JOIN nn_neuron destino ON destino.id = s.to_neuron_id
         JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
         WHERE camada_origem.architecture_id = v_architecture_id
           AND camada_destino.architecture_id = v_architecture_id)
        +
        (SELECT COUNT(*) FROM nn_neuron n
         JOIN nn_layer l ON l.id = n.layer_id
         WHERE l.architecture_id = v_architecture_id AND l.tipo IN ('hidden','output'))
    INTO v_trainable_parameters;

    SET v_experiment_id = UUID();
    CALL sp_nn_create_seeded_population(
        p_architecture_name, p_population_size, p_seed
    );

    INSERT INTO nn_training_experiment (
        experiment_id, nome, architecture_id, seed, population_size,
        mutation_rate, planned_generations, evaluations_per_genome,
        condition_label, trainable_parameters
    ) VALUES (
        v_experiment_id, p_experiment_name, v_architecture_id, p_seed,
        p_population_size, p_mutation_rate, p_planned_generations,
        p_evaluations_per_genome, p_condition_label, v_trainable_parameters
    );

    INSERT INTO nn_training_experiment_generation (
        experiment_id, geracao, seed, mutation_rate, elite_count
    ) VALUES (
        v_experiment_id, 0, p_seed, p_mutation_rate, NULL
    );

    SELECT v_experiment_id AS experiment_id,
           p_experiment_name AS experiment_name,
           p_architecture_name AS architecture_name,
           v_trainable_parameters AS trainable_parameters;
END$$

CREATE PROCEDURE sp_nn_evolve_training_experiment(
    IN p_experiment_id CHAR(36),
    IN p_source_generation INT,
    IN p_elite_count INT
)
BEGIN
    DECLARE v_experiment_name VARCHAR(80) DEFAULT NULL;
    DECLARE v_architecture_name VARCHAR(50) DEFAULT NULL;
    DECLARE v_seed BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_mutation_rate DECIMAL(7,6) DEFAULT NULL;
    DECLARE v_planned_generations INT DEFAULT NULL;
    DECLARE v_evaluations_per_genome INT DEFAULT NULL;
    DECLARE v_incomplete_genomes INT DEFAULT 0;
    DECLARE v_generation_seed BIGINT UNSIGNED DEFAULT NULL;

    IF p_experiment_id IS NULL OR IS_UUID(p_experiment_id) <> 1
       OR p_source_generation IS NULL OR p_source_generation < 0
       OR p_elite_count IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Parâmetros para evolução do experimento inválidos';
    END IF;

    SELECT experimento.nome, arquitetura.nome, experimento.seed,
           experimento.mutation_rate, experimento.planned_generations,
           experimento.evaluations_per_genome
    INTO v_experiment_name, v_architecture_name, v_seed, v_mutation_rate,
         v_planned_generations, v_evaluations_per_genome
    FROM nn_training_experiment experimento
    JOIN nn_architecture arquitetura ON arquitetura.id = experimento.architecture_id
    WHERE experimento.experiment_id = p_experiment_id;

    IF v_experiment_name IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Experimento não encontrado';
    END IF;
    IF p_source_generation >= v_planned_generations THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Limite de gerações planejadas atingido';
    END IF;

    SELECT COUNT(*) INTO v_incomplete_genomes
    FROM nn_genome genoma
    WHERE genoma.architecture_id = (
        SELECT architecture_id FROM nn_training_experiment
        WHERE experiment_id = p_experiment_id
    )
      AND genoma.geracao = p_source_generation
      AND (
          SELECT COUNT(*)
          FROM nn_genome_evaluation avaliacao
          JOIN nn_training_experiment_session sessao
            ON sessao.session_id = avaliacao.session_id
          WHERE sessao.experiment_id = p_experiment_id
            AND avaliacao.genome_id = genoma.id
      ) < v_evaluations_per_genome;

    IF v_incomplete_genomes > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cada genoma precisa das avaliações previstas em partidas do experimento';
    END IF;

    SET v_generation_seed = MOD(v_seed + p_source_generation + 1, 4294967296);
    CALL sp_nn_evolve_generation_seeded(
        v_architecture_name, p_source_generation, p_elite_count,
        v_mutation_rate, v_generation_seed
    );

    INSERT INTO nn_training_experiment_generation (
        experiment_id, geracao, seed, mutation_rate, elite_count
    ) VALUES (
        p_experiment_id, p_source_generation + 1,
        v_generation_seed, v_mutation_rate, p_elite_count
    );

    SELECT experimento.experiment_id, experimento.nome AS experiment_name,
           historico.geracao, historico.seed, historico.mutation_rate,
           historico.elite_count
    FROM nn_training_experiment_generation historico
    JOIN nn_training_experiment experimento
      ON experimento.experiment_id = historico.experiment_id
    WHERE historico.experiment_id = p_experiment_id
      AND historico.geracao = p_source_generation + 1;
END$$
DELIMITER ;
