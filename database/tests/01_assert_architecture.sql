DROP PROCEDURE IF EXISTS test_assert_seeded_architecture;

DELIMITER $$
CREATE PROCEDURE test_assert_seeded_architecture()
BEGIN
    DECLARE v_architecture_id INT DEFAULT NULL;
    DECLARE v_layers INT DEFAULT 0;
    DECLARE v_inputs INT DEFAULT 0;
    DECLARE v_hidden INT DEFAULT 0;
    DECLARE v_outputs INT DEFAULT 0;
    DECLARE v_synapses INT DEFAULT 0;
    DECLARE v_mappings INT DEFAULT 0;
    DECLARE v_invalid_state_inputs INT DEFAULT 0;

    SELECT id INTO v_architecture_id
    FROM nn_architecture
    WHERE nome = 'npc_teste_4_6_4';

    IF v_architecture_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Arquitetura npc_teste_4_6_4 ausente';
    END IF;

    SELECT COUNT(*) INTO v_layers
    FROM nn_layer
    WHERE architecture_id = v_architecture_id;

    SELECT COUNT(*) INTO v_inputs
    FROM nn_layer l JOIN nn_neuron n ON n.layer_id = l.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'input';

    SELECT COUNT(*) INTO v_hidden
    FROM nn_layer l JOIN nn_neuron n ON n.layer_id = l.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'hidden';

    SELECT COUNT(*) INTO v_outputs
    FROM nn_layer l JOIN nn_neuron n ON n.layer_id = l.id
    WHERE l.architecture_id = v_architecture_id AND l.tipo = 'output';

    SELECT COUNT(*) INTO v_synapses
    FROM nn_synapse s
    JOIN nn_neuron origem ON origem.id = s.from_neuron_id
    JOIN nn_layer camada_origem ON camada_origem.id = origem.layer_id
    JOIN nn_neuron destino ON destino.id = s.to_neuron_id
    JOIN nn_layer camada_destino ON camada_destino.id = destino.layer_id
    WHERE camada_origem.architecture_id = v_architecture_id
      AND camada_destino.architecture_id = v_architecture_id;

    SELECT COUNT(*) INTO v_mappings
    FROM nn_neuron_io io
    JOIN nn_neuron n ON n.id = io.neuron_id
    JOIN nn_layer l ON l.id = n.layer_id
    WHERE l.architecture_id = v_architecture_id;

    SELECT COUNT(*) INTO v_invalid_state_inputs
    FROM nn_neuron_io io
    JOIN nn_neuron n ON n.id = io.neuron_id
    JOIN nn_layer l ON l.id = n.layer_id
    WHERE l.architecture_id = v_architecture_id
      AND l.tipo = 'input'
      AND io.nome = 'CURRENT_STATE';

    IF v_layers <> 3 OR v_inputs <> 4 OR v_hidden <> 6 OR v_outputs <> 4
       OR v_synapses <> 48 OR v_mappings <> 8 OR v_invalid_state_inputs <> 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Contagens ou mapeamentos da arquitetura não conferem';
    END IF;
END$$
DELIMITER ;

CALL test_assert_seeded_architecture();
DROP PROCEDURE test_assert_seeded_architecture;

SELECT 'OK: 4 -> 6 -> 4, 48 sinapses, 8 mapeamentos; CURRENT_STATE não é entrada.' AS resultado;
