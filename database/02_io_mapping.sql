USE npc_neural_game;

-- O tipo do neurônio continua sendo definido pela camada; aqui fica apenas o significado dele.
CREATE TABLE nn_neuron_io (
    neuron_id INT PRIMARY KEY,
    nome VARCHAR(50) NOT NULL,
    descricao VARCHAR(120) NOT NULL,
    FOREIGN KEY (neuron_id) REFERENCES nn_neuron(id) ON DELETE CASCADE,
    INDEX idx_io_nome (nome)
) ENGINE=InnoDB;
