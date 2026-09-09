
-- PROJETO: Rede Neural em Tabelas MySQL para IA de NPCs (estilo Doom)
-- Modelagem do banco de dados

-- Este schema é dividido em 4 blocos:
--   1. Estrutura da rede neural (topologia/arquitetura)
--   2. Genoma (pesos individuais por NPC + evolução)
--   3. Entidades do jogo (mapa, NPCs, jogador)
--   4. Execução (forward pass / runs de decisão)

 
CREATE DATABASE IF NOT EXISTS npc_neural_game
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
 
USE npc_neural_game;
 
-- BLOCO 1: ESTRUTURA DA REDE NEURAL (topologia)
-- Define o "formato" do cérebro, sem valores ainda.

 
CREATE TABLE nn_architecture (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(50) NOT NULL,          -- ex: 'grunt', 'imp', 'cacodemon'
    n_entradas INT NOT NULL,
    n_saidas INT NOT NULL,
    criado_em TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
 
CREATE TABLE nn_layer (
    id INT AUTO_INCREMENT PRIMARY KEY,
    architecture_id INT NOT NULL,
    ordem INT NOT NULL,                 -- 0 = entrada, N = saída
    tipo ENUM('input','hidden','output') NOT NULL,
    FOREIGN KEY (architecture_id) REFERENCES nn_architecture(id) ON DELETE CASCADE,
    UNIQUE KEY uq_arch_ordem (architecture_id, ordem)
) ENGINE=InnoDB;
 
CREATE TABLE nn_neuron (
    id INT AUTO_INCREMENT PRIMARY KEY,
    layer_id INT NOT NULL,
    posicao INT NOT NULL,               -- índice do neurônio dentro da camada
    funcao_ativacao ENUM('sigmoid','relu','tanh') NOT NULL DEFAULT 'sigmoid',
    FOREIGN KEY (layer_id) REFERENCES nn_layer(id) ON DELETE CASCADE,
    UNIQUE KEY uq_layer_posicao (layer_id, posicao)
) ENGINE=InnoDB;
 
CREATE TABLE nn_synapse (
    id INT AUTO_INCREMENT PRIMARY KEY,
    from_neuron_id INT NOT NULL,
    to_neuron_id INT NOT NULL,
    FOREIGN KEY (from_neuron_id) REFERENCES nn_neuron(id) ON DELETE CASCADE,
    FOREIGN KEY (to_neuron_id) REFERENCES nn_neuron(id) ON DELETE CASCADE,
    UNIQUE KEY uq_synapse (from_neuron_id, to_neuron_id),
    INDEX idx_to_neuron (to_neuron_id)
) ENGINE=InnoDB;
 

-- BLOCO 2: GENOMA (pesos individuais + evolução)
-- Cada NPC tem seu próprio conjunto de pesos sobre a mesma topologia.

CREATE TABLE nn_genome (
    id INT AUTO_INCREMENT PRIMARY KEY,
    architecture_id INT NOT NULL,
    geracao INT NOT NULL DEFAULT 0,
    fitness DECIMAL(10,4) NOT NULL DEFAULT 0,
    origem ENUM('aleatorio','mutacao','crossover') NOT NULL DEFAULT 'aleatorio',
    pai1_id INT NULL,
    pai2_id INT NULL,
    criado_em TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (architecture_id) REFERENCES nn_architecture(id) ON DELETE CASCADE,
    FOREIGN KEY (pai1_id) REFERENCES nn_genome(id) ON DELETE SET NULL,
    FOREIGN KEY (pai2_id) REFERENCES nn_genome(id) ON DELETE SET NULL,
    INDEX idx_fitness (architecture_id, fitness)
) ENGINE=InnoDB;
 
CREATE TABLE nn_genome_weight (
    genome_id INT NOT NULL,
    synapse_id INT NOT NULL,
    peso FLOAT NOT NULL,
    PRIMARY KEY (genome_id, synapse_id),
    FOREIGN KEY (genome_id) REFERENCES nn_genome(id) ON DELETE CASCADE,
    FOREIGN KEY (synapse_id) REFERENCES nn_synapse(id) ON DELETE CASCADE
) ENGINE=InnoDB;
 
CREATE TABLE nn_genome_bias (
    genome_id INT NOT NULL,
    neuron_id INT NOT NULL,
    bias FLOAT NOT NULL,
    PRIMARY KEY (genome_id, neuron_id),
    FOREIGN KEY (genome_id) REFERENCES nn_genome(id) ON DELETE CASCADE,
    FOREIGN KEY (neuron_id) REFERENCES nn_neuron(id) ON DELETE CASCADE
) ENGINE=InnoDB;
 
-- BLOCO 3: ENTIDADES DO JOGO (mapa, NPCs, jogador)
 
CREATE TABLE game_level (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(50) NOT NULL
) ENGINE=InnoDB;
 
CREATE TABLE level_wall (
    id INT AUTO_INCREMENT PRIMARY KEY,
    level_id INT NOT NULL,
    x1 FLOAT NOT NULL,
    y1 FLOAT NOT NULL,
    x2 FLOAT NOT NULL,
    y2 FLOAT NOT NULL,
    FOREIGN KEY (level_id) REFERENCES game_level(id) ON DELETE CASCADE,
    INDEX idx_level (level_id)
) ENGINE=InnoDB;
 
CREATE TABLE npc_type (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(50) NOT NULL,
    architecture_id INT NOT NULL,
    hp_max INT NOT NULL,
    velocidade FLOAT NOT NULL,
    dano_ataque INT NOT NULL,
    alcance_ataque FLOAT NOT NULL DEFAULT 1.0,
    FOREIGN KEY (architecture_id) REFERENCES nn_architecture(id)
) ENGINE=InnoDB;
 
CREATE TABLE npc_instance (
    id INT AUTO_INCREMENT PRIMARY KEY,
    level_id INT NOT NULL,
    npc_type_id INT NOT NULL,
    genome_id INT NOT NULL,
    x FLOAT NOT NULL,
    y FLOAT NOT NULL,
    angulo FLOAT NOT NULL DEFAULT 0,
    hp INT NOT NULL,
    estado ENUM('patrulha','perseguindo','atacando','fugindo','morto') NOT NULL DEFAULT 'patrulha',
    ultimo_tick_decisao INT NOT NULL DEFAULT 0,
    criado_em TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (level_id) REFERENCES game_level(id) ON DELETE CASCADE,
    FOREIGN KEY (npc_type_id) REFERENCES npc_type(id),
    FOREIGN KEY (genome_id) REFERENCES nn_genome(id),
    INDEX idx_level_estado (level_id, estado)
) ENGINE=InnoDB;
 
CREATE TABLE player_state (
    id INT AUTO_INCREMENT PRIMARY KEY,
    level_id INT NOT NULL,
    x FLOAT NOT NULL,
    y FLOAT NOT NULL,
    angulo FLOAT NOT NULL DEFAULT 0,
    hp INT NOT NULL DEFAULT 100,
    municao INT NOT NULL DEFAULT 50,
    atualizado_em TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (level_id) REFERENCES game_level(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- BLOCO 4: EXECUÇÃO (forward pass / decisões dos NPCs)
 
CREATE TABLE nn_run (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    npc_instance_id INT NOT NULL,
    tick INT NOT NULL,
    criado_em TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (npc_instance_id) REFERENCES npc_instance(id) ON DELETE CASCADE,
    INDEX idx_npc_tick (npc_instance_id, tick)
) ENGINE=InnoDB;
 
CREATE TABLE nn_run_activation (
    run_id BIGINT NOT NULL,
    neuron_id INT NOT NULL,
    valor FLOAT NOT NULL,
    PRIMARY KEY (run_id, neuron_id),
    FOREIGN KEY (run_id) REFERENCES nn_run(id) ON DELETE CASCADE,
    FOREIGN KEY (neuron_id) REFERENCES nn_neuron(id) ON DELETE CASCADE
) ENGINE=InnoDB;
 

-- FIM DO SCHEMA
-- Próximos passos (não incluídos aqui, ficam para a outra metade do projeto):
--   - Stored procedures: forward_pass(), criar_genoma_aleatorio(),
--     avaliar_fitness(), crossover(), mutar()
--   - Seed data: uma arquitetura de teste (ex: 4 entradas -> 4 ocultos -> 3 saídas)
--     e um nível simples com paredes
