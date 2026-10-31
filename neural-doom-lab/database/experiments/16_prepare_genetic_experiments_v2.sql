-- Reproducible, additive setup for four isolated genetic-v2 architecture runs.
-- Execute with neural_doom_local_game_20261024 as the selected database.
-- The called procedure validates the schema, refuses conflicting names, and
-- treats an exact re-run as a no-op. No USE/CREATE DATABASE or legacy data edits.

SELECT VERSION() AS mysql_version, DATABASE() AS selected_schema;

SET @experiment_v2_ref46 = NULL;
CALL sp_nn_create_genetic_experiment_v2(
    'genetic_v2_20261031_ref46', 'genetic_v2_ref46_20261031',
    JSON_ARRAY(4, 6, 4), 'relu', 20261031, 8, 0.050000, 2, 2,
    'Freedoom2 E1M1 skill2, headless fixed controls 20s', @experiment_v2_ref46
);
SELECT @experiment_v2_ref46 AS experiment_id;

SET @experiment_v2_h32 = NULL;
CALL sp_nn_create_genetic_experiment_v2(
    'genetic_v2_20261031_h32', 'genetic_v2_h32_20261031',
    JSON_ARRAY(4, 32, 4), 'relu', 20261031, 8, 0.050000, 2, 2,
    'Freedoom2 E1M1 skill2, headless fixed controls 20s', @experiment_v2_h32
);
SELECT @experiment_v2_h32 AS experiment_id;

SET @experiment_v2_h64 = NULL;
CALL sp_nn_create_genetic_experiment_v2(
    'genetic_v2_20261031_h64', 'genetic_v2_h64_20261031',
    JSON_ARRAY(4, 64, 4), 'relu', 20261031, 8, 0.050000, 2, 2,
    'Freedoom2 E1M1 skill2, headless fixed controls 20s', @experiment_v2_h64
);
SELECT @experiment_v2_h64 AS experiment_id;

SET @experiment_v2_deep6464 = NULL;
CALL sp_nn_create_genetic_experiment_v2(
    'genetic_v2_20261031_deep6464', 'genetic_v2_deep6464_20261031',
    JSON_ARRAY(4, 64, 32, 64, 4), 'relu', 20261031, 8, 0.050000, 2, 2,
    'Freedoom2 E1M1 skill2, headless fixed controls 20s', @experiment_v2_deep6464
);
SELECT @experiment_v2_deep6464 AS experiment_id;

SELECT experiment.experiment_id, experiment.experiment_name,
       architecture.nome AS architecture_name,
       experiment.topology_json AS topology,
       experiment.trainable_parameters, experiment.population_size,
       experiment.seed, experiment.planned_generations,
       experiment.evaluations_per_genome, experiment.mutation_rate,
       experiment.condition_label
FROM nn_training_experiment_v2 experiment
JOIN nn_architecture architecture ON architecture.id = experiment.architecture_id
WHERE experiment_name IN (
    'genetic_v2_20261031_ref46', 'genetic_v2_20261031_h32',
    'genetic_v2_20261031_h64', 'genetic_v2_20261031_deep6464'
)
ORDER BY experiment.experiment_name;
