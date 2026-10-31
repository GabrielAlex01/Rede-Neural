import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const frontendDirectory = path.resolve(scriptDirectory, '..');
const projectDirectory = path.resolve(frontendDirectory, '..');
const repositoryDirectory = path.resolve(projectDirectory, '..');
const gameSchema = 'neural_doom_local_game_20261024';
const loginPath = process.env.MYSQL_LOGIN_PATH ?? 'neural-doom-installer-20261024';
const mysqlPath = process.env.MYSQL_EXE
  ?? 'C:\\Program Files\\MySQL\\MySQL Server 8.0\\bin\\mysql.exe';
const pythonPath = process.env.PYTHON_EXE
  ?? path.join(projectDirectory, '.venv', 'Scripts', 'python.exe');
const frontendUrl = process.env.DOOM_FRONTEND_URL ?? 'http://127.0.0.1:5173/';
const backendPort = Number(process.env.DOOM_EVAL_BACKEND_PORT ?? 8001);
const matchSeconds = Number(process.env.DOOM_MATCH_SECONDS ?? 20);
const populationSize = 8;
const evaluationsPerGenome = 2;
const plannedGenerations = 2;
const eliteCount = 2;
const maxAttemptsPerGeneration = 8;
const p95LatencyBudgetMs = 800;
const resultDirectory = process.env.DOOM_RESULT_DIR
  ?? path.join(tmpdir(), 'neural-doom-genetic-experiments-v2');
const architectures = [
  { alias: 'genetic_v2_ref46_20261031', experiment: 'genetic_v2_20261031_ref46', topology: [4, 6, 4] },
  { alias: 'genetic_v2_h32_20261031', experiment: 'genetic_v2_20261031_h32', topology: [4, 32, 4] },
  { alias: 'genetic_v2_h64_20261031', experiment: 'genetic_v2_20261031_h64', topology: [4, 64, 4] },
  { alias: 'genetic_v2_deep6464_20261031', experiment: 'genetic_v2_20261031_deep6464', topology: [4, 64, 32, 64, 4] },
];

const report = {
  started_at: new Date().toISOString(),
  environment: {
    schema: gameSchema,
    map: 'Freedoom 2 E1M1',
    skill: 2,
    match_seconds: matchSeconds,
    browser: 'Microsoft Edge headless, isolated Playwright context',
    control: 'fixed arrows/Space/Ctrl/Shift pattern from automated-match.mjs',
    population_size: populationSize,
    evaluations_per_genome: evaluationsPerGenome,
    planned_generations: plannedGenerations,
    seed: 20261031,
    mutation_rate: 0.05,
    elite_count: eliteCount,
    engine_random_seed: 'not configurable by the current browser build',
  },
  architectures: [],
};

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function executeMysql(query, input = undefined) {
  const args = [
    `--login-path=${loginPath}`,
    '--protocol=TCP', '--host=127.0.0.1', '--port=3306',
    `--database=${gameSchema}`,
    '--batch', '--raw', '--skip-column-names',
    ...(query ? ['--execute', query] : []),
  ];
  const result = spawnSync(mysqlPath, args, {
    cwd: repositoryDirectory,
    encoding: 'utf8',
    input,
    windowsHide: true,
    timeout: 120000,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error) throw new Error(`Falha ao iniciar mysql.exe: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`MySQL recusou a etapa; exit ${result.status}: ${result.stderr.trim()}`);
  }
  return result.stdout.trim();
}

async function waitForHttp(url, child, label, timeoutMilliseconds = 30000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (child?.exitCode !== null && child?.exitCode !== undefined) {
      throw new Error(`${label} encerrou durante a inicialização (exit ${child.exitCode}).`);
    }
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(1500) });
      if (response.ok) return;
    } catch {}
    await delay(350);
  }
  throw new Error(`${label} não ficou saudável em ${timeoutMilliseconds} ms.`);
}

async function ensureFrontend() {
  let response;
  try {
    response = await fetch(frontendUrl, { signal: AbortSignal.timeout(1000) });
  } catch {}

  if (response) {
    const html = response.ok ? await response.text() : '';
    if (response.ok && html.includes('<title>Neural Doom Lab</title>')) return null;
    throw new Error(`A URL ${frontendUrl} não aponta para o frontend esperado; não será substituída.`);
  }

  const address = new URL(frontendUrl);
  if (address.protocol !== 'http:' || !['127.0.0.1', 'localhost', '::1'].includes(address.hostname)) {
    throw new Error('O runner só inicia o frontend em URL HTTP local.');
  }
  const viteEntry = path.join(frontendDirectory, 'node_modules', 'vite', 'bin', 'vite.js');
  if (!existsSync(viteEntry)) throw new Error('Vite não está instalado em frontend/node_modules.');
  const child = spawn(process.execPath, [
    viteEntry, '--host', address.hostname, '--port', String(Number(address.port || 80)), '--strictPort',
  ], { cwd: frontendDirectory, windowsHide: true, stdio: 'ignore' });
  try {
    await waitForHttp(frontendUrl, child, 'Vite');
    const health = await fetch(frontendUrl, { signal: AbortSignal.timeout(1500) });
    if (!health.ok || !(await health.text()).includes('<title>Neural Doom Lab</title>')) {
      throw new Error('Vite iniciou, mas não serve o Neural Doom Lab esperado.');
    }
    return child;
  } catch (error) {
    child.kill();
    throw error;
  }
}

async function startBackend(architectureName) {
  try {
    const existing = await fetch(`http://127.0.0.1:${backendPort}/health`, { signal: AbortSignal.timeout(700) });
    if (existing.ok) throw new Error(`Porta ${backendPort} já pertence a outro backend; não será reutilizada.`);
  } catch (error) {
    if (String(error.message).includes('já pertence')) throw error;
  }
  const child = spawn(pythonPath, [
    '-m', 'uvicorn', 'backend.main:app', '--host', '127.0.0.1',
    '--port', String(backendPort), '--log-level', 'warning',
  ], {
    cwd: projectDirectory,
    env: { ...process.env, NN_ARCHITECTURE_NAME: architectureName },
    windowsHide: true,
    stdio: 'ignore',
  });
  try {
    await waitForHttp(`http://127.0.0.1:${backendPort}/health`, child, `FastAPI ${architectureName}`);
    return child;
  } catch (error) {
    child.kill();
    throw error;
  }
}

async function stopProcess(child) {
  if (!child || child.exitCode !== null) return;
  child.kill();
  await Promise.race([
    new Promise((resolve) => child.once('close', resolve)),
    delay(5000),
  ]);
}

async function runBrowserMatch(architecture, experimentId, generation, attempt) {
  const environment = {
    ...process.env,
    DOOM_FRONTEND_URL: frontendUrl,
    DOOM_MATCH_SECONDS: String(matchSeconds),
    DOOM_WS_URL: `ws://127.0.0.1:${backendPort}/ws/ai`,
    DOOM_RESULT_DIR: resultDirectory,
    NN_ARCHITECTURE_NAME: architecture.alias,
  };
  const output = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path.join(scriptDirectory, 'automated-match.mjs')], {
      cwd: frontendDirectory,
      env: environment,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', (chunk) => { stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject);
    child.once('close', (code) => resolve({ code, stdout, stderr }));
  });

  let match;
  try {
    match = JSON.parse(output.stdout);
  } catch {
    throw new Error(`O navegador não produziu JSON válido (exit ${output.code}): ${output.stderr.slice(-1200)}`);
  }
  match.experiment_id = experimentId;
  match.generation_under_test = generation;
  match.attempt = attempt;
  match.process_exit_code = output.code;
  match.mysql_persisted = match.session_id ? queryPersistedSession(match.session_id) : null;
  const metrics = match.session_end_ack?.action_metrics;
  const persisted = match.mysql_persisted;
  match.validation = {
    engine_started: match.engine_start_log === true,
    skill_two: match.skill === 2,
    session_ack: match.session_end_ack?.closed === true,
    ack_matches_browser_session: match.session_end_ack?.session_id === match.session_id,
    frontend_ack_receipt: match.session_end_ack_receipt?.confirmed === true,
    receipt_matches_browser_session: match.session_end_ack_receipt?.session_id === match.session_id,
    mysql_closed: persisted?.closed === true,
    architecture_matches: persisted?.architecture_name === architecture.alias,
    experiment_matches: persisted?.experiment_id === experimentId,
    generation_matches: Number(persisted?.generation) === generation,
    all_population_genomes_assigned: Number(persisted?.distinct_assigned_genomes) === populationSize,
    all_population_genomes_evaluated: Number(persisted?.distinct_evaluated_genomes) === populationSize,
    session_genome_evaluations_match_assignments:
      Number(persisted?.distinct_assigned_genomes) === Number(persisted?.distinct_evaluated_genomes),
    ack_evaluation_count_matches:
      Number(persisted?.ack_evaluation_count) === Number(persisted?.training_evaluations),
    db_ack_confirmed: persisted?.ack_confirmed === true,
    db_decisions_match_frontend: Number(persisted?.sql_decisions) === Number(metrics?.sql_decisions),
    no_invalid_sql_response: Number(metrics?.invalid_sql_responses ?? -1) === 0,
    applied_engine_action: Number(metrics?.applied ?? 0) > 0,
    real_combat_event: Number(persisted?.combat_event_rows ?? 0) > 0,
    no_http_errors: (match.http_errors ?? []).length === 0,
    no_websocket_errors: !(match.browser_errors ?? []).some((error) =>
      /websocket connection.*failed|ERR_NO_BUFFER_SPACE/i.test(error.text ?? '')),
  };
  // A valid ACK may cover only NPCs actually spawned in that match. Coverage
  // of the full population is accumulated across repeat sessions below.
  const nonBlockingObservations = new Set([
    'all_population_genomes_assigned',
    'all_population_genomes_evaluated',
    // Survival-only sessions are real outcomes, although they do not prove
    // that the roster engaged in combat. Keep that distinction in the report.
    'real_combat_event',
  ]);
  match.validation.complete = Object.entries(match.validation)
    .filter(([key]) => !nonBlockingObservations.has(key))
    .every(([, value]) => value === true);
  return match;
}

function queryPersistedSession(sessionId) {
  if (!/^[0-9a-f-]{36}$/i.test(sessionId)) throw new Error('session_id inválido no resultado headless.');
  const sid = sessionId.toLowerCase();
  const query = `SELECT JSON_OBJECT(
    'closed', s.encerrada_em IS NOT NULL,
    'architecture_name', architecture.nome,
    'experiment_id', linked.experiment_id,
    'generation', linked.generation,
    'population_size', experiment.population_size,
    'npcs', (SELECT COUNT(*) FROM nn_session_npc npc WHERE npc.session_id=s.session_id),
    'distinct_assigned_genomes', (SELECT COUNT(DISTINCT npc.genome_id)
      FROM nn_session_npc npc
      JOIN nn_training_experiment_genome_v2 member
        ON member.experiment_id=linked.experiment_id
       AND member.generation=linked.generation AND member.genome_id=npc.genome_id
      WHERE npc.session_id=s.session_id),
    'sql_decisions', (SELECT COUNT(*) FROM nn_decision_run decision WHERE decision.session_id=s.session_id),
    'training_evaluations', (SELECT COUNT(*) FROM nn_genome_evaluation_training_v2 evaluation
      WHERE evaluation.session_id=s.session_id),
    'distinct_evaluated_genomes', (SELECT COUNT(DISTINCT evaluation.genome_id)
      FROM nn_genome_evaluation_training_v2 evaluation
      JOIN nn_training_experiment_genome_v2 member
        ON member.experiment_id=linked.experiment_id
       AND member.generation=linked.generation AND member.genome_id=evaluation.genome_id
      WHERE evaluation.session_id=s.session_id),
    'ack_confirmed', completion.ack_confirmed_at IS NOT NULL,
    'ack_evaluation_count', completion.evaluation_count,
    'combat_event_rows', (SELECT COUNT(*) FROM nn_combat_event event WHERE event.session_id=s.session_id),
    'player_damage', (SELECT COALESCE(SUM(event.valor),0) FROM nn_combat_event event WHERE event.session_id=s.session_id AND event.event_type='PLAYER_DAMAGE'),
    'npc_damage', (SELECT COALESCE(SUM(event.valor),0) FROM nn_combat_event event WHERE event.session_id=s.session_id AND event.event_type='NPC_DAMAGE'),
    'npc_deaths', (SELECT COALESCE(SUM(event.valor),0) FROM nn_combat_event event WHERE event.session_id=s.session_id AND event.event_type='NPC_DEATH'),
    'player_kills', (SELECT COALESCE(SUM(event.valor),0) FROM nn_combat_event event WHERE event.session_id=s.session_id AND event.event_type='PLAYER_KILL')
  )
  FROM nn_engine_session s
  JOIN nn_architecture architecture ON architecture.id=s.architecture_id
  LEFT JOIN nn_training_experiment_session_v2 linked ON linked.session_id=s.session_id
  LEFT JOIN nn_training_experiment_v2 experiment ON experiment.experiment_id=linked.experiment_id
  LEFT JOIN nn_training_session_completion_v2 completion ON completion.session_id=s.session_id
  WHERE s.session_id='${sid}'`;
  const encoded = executeMysql(query);
  return encoded ? JSON.parse(encoded) : null;
}

function experimentIdFor(name) {
  const literal = name.replaceAll("'", "''");
  const result = executeMysql(
    `SELECT experiment_id FROM nn_training_experiment_v2 WHERE experiment_name='${literal}'`,
  );
  if (!/^[0-9a-f-]{36}$/i.test(result)) throw new Error(`Experimento ausente ou ambíguo: ${name}`);
  return result.toLowerCase();
}

function missingGenomeEvaluations(experimentId, generation) {
  const result = executeMysql(`
    SELECT COUNT(*)
    FROM nn_training_experiment_genome_v2 member
    WHERE member.experiment_id='${experimentId}' AND member.generation=${generation}
      AND (
        SELECT COUNT(*)
        FROM nn_training_experiment_session_v2 session_v2
        JOIN nn_training_session_completion_v2 completion
          ON completion.session_id=session_v2.session_id
         AND completion.fitness_version='combat_outcome_v2_1'
         AND completion.ack_confirmed_at IS NOT NULL
        JOIN nn_genome_evaluation_training_v2 evaluation
          ON evaluation.session_id=session_v2.session_id
         AND evaluation.genome_id=member.genome_id
         AND evaluation.attribution_version='neural_attack_provenance_v2'
         AND evaluation.fitness_version='combat_outcome_v2_1'
        WHERE session_v2.experiment_id=member.experiment_id
          AND session_v2.generation=member.generation
      ) < ${evaluationsPerGenome}
  `);
  return Number(result);
}

function generationScores(experimentId, generation) {
  const encoded = executeMysql(`SELECT JSON_OBJECT(
    'generation_status', generation_row.status,
    'evaluation_count', generation_row.evaluation_count,
    'evaluated_genomes', generation_row.evaluated_genomes,
    'fitness_mean', generation_row.fitness_mean,
    'best_fitness', generation_row.best_fitness,
    'worst_fitness', generation_row.worst_fitness,
    'genome_scores', (SELECT JSON_ARRAYAGG(JSON_OBJECT(
      'genome_id', score.genome_id,
      'evaluations', score.evaluations_used,
      'fitness_mean', score.fitness_mean,
      'fitness_best', score.fitness_best,
      'fitness_worst', score.fitness_worst,
      'damage_to_player', score.damage_to_player,
      'player_kills', score.player_kills,
      'damage_received', score.damage_received,
      'npc_deaths', score.npc_deaths,
      'survival_seconds', score.survival_seconds
    )) FROM nn_training_genome_score_v2 score
      WHERE score.experiment_id=generation_row.experiment_id
        AND score.generation=generation_row.generation)
  ) FROM nn_training_generation_v2 generation_row
  WHERE generation_row.experiment_id='${experimentId}' AND generation_row.generation=${generation}`);
  return encoded ? JSON.parse(encoded) : null;
}

async function evaluateGeneration(architecture, experimentId, generation) {
  const runs = [];
  let missing = missingGenomeEvaluations(experimentId, generation);
  let latencyBudgetExceeded = false;
  for (let attempt = 1; missing > 0 && attempt <= maxAttemptsPerGeneration; attempt += 1) {
    const match = await runBrowserMatch(architecture, experimentId, generation, attempt);
    runs.push(match);
    const metrics = match.session_end_ack?.action_metrics;
    const db = match.mysql_persisted;
    process.stdout.write(`${architecture.alias} gen${generation} match${attempt}: `
      + `eval=${db?.distinct_evaluated_genomes ?? 0}/${populationSize}, `
      + `SQL=${db?.sql_decisions ?? 0}, `
      + `ATTACK aplicado=${metrics?.actions?.ATTACK?.applied ?? 0}, `
      + `fallback=${metrics?.fallback ?? 0}, P95=${match.ws_round_trip_ms?.p95?.toFixed(1) ?? 'n/a'}ms, `
      + `eventos_combate=${Object.values(match.combat_events_sent ?? {}).reduce((sum, value) => sum + value, 0)}, `
      + `integridade=${match.validation.complete}\n`);
    missing = missingGenomeEvaluations(experimentId, generation);
    if (match.ws_round_trip_ms?.p95 >= p95LatencyBudgetMs) {
      latencyBudgetExceeded = true;
      break;
    }
    if (!match.validation.complete) break;
    if (missing > 0) await delay(2500);
  }
  return {
    runs,
    missing_genome_evaluations: missing,
    latency_budget_exceeded: latencyBudgetExceeded,
    integrity_failed: runs.some((match) => !match.validation.complete),
    persisted_scores: generationScores(experimentId, generation),
  };
}

if (gameSchema !== 'neural_doom_local_game_20261024') {
  throw new Error('Runner restrito ao schema local isolado neural_doom_local_game_20261024.');
}
if (!existsSync(mysqlPath) || !existsSync(pythonPath)) {
  throw new Error('mysql.exe ou Python do .venv não encontrado; use MYSQL_EXE/PYTHON_EXE.');
}
if (!Number.isInteger(matchSeconds) || matchSeconds !== 20) {
  throw new Error('Esta comparação reproduzível exige DOOM_MATCH_SECONDS=20.');
}
if (!Number.isInteger(backendPort) || backendPort < 1024 || backendPort > 65535) {
  throw new Error('DOOM_EVAL_BACKEND_PORT inválida.');
}

await mkdir(resultDirectory, { recursive: true });
const balancedAssignmentInstalled = executeMysql(`
  SELECT COUNT(*)
  FROM information_schema.ROUTINES
  WHERE ROUTINE_SCHEMA=DATABASE()
    AND ROUTINE_NAME='sp_nn_decide_for_architecture'
    AND ROUTINE_DEFINITION LIKE '%trusted_count%'
`);
if (balancedAssignmentInstalled !== '1') {
  executeMysql('', await readFile(
    path.join(repositoryDirectory, 'neural-doom-lab', 'database', 'migrations', '16_balanced_genome_assignment_v2.sql'),
    'utf8',
  ));
}
executeMysql('', await readFile(
  path.join(repositoryDirectory, 'neural-doom-lab', 'database', 'experiments', '16_prepare_genetic_experiments_v2.sql'),
  'utf8',
));

const experimentIds = new Map(architectures.map((architecture) => [
  architecture.alias,
  experimentIdFor(architecture.experiment),
]));
if (process.argv.includes('--prepare-only')) {
  report.finished_at = new Date().toISOString();
  report.prepared_experiments = architectures.map((architecture) => ({
    ...architecture,
    experiment_id: experimentIds.get(architecture.alias),
  }));
  const reportPath = path.join(resultDirectory, `genetics-v2-prepare-${Date.now()}.json`);
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  process.stdout.write(`Experimentos conferidos sem iniciar partidas. Relatório: ${reportPath}\n`);
} else {
  const ownedFrontend = await ensureFrontend();
  try {
    for (const architecture of architectures) {
      const experimentId = experimentIds.get(architecture.alias);
      const architectureReport = {
        ...architecture,
        experiment_id: experimentId,
        generations: [],
      };
      report.architectures.push(architectureReport);
      let backend;
      try {
        backend = await startBackend(architecture.alias);
        const generationZero = await evaluateGeneration(architecture, experimentId, 0);
        architectureReport.generations.push({ generation: 0, ...generationZero });
        if (generationZero.integrity_failed
            || generationZero.latency_budget_exceeded
            || generationZero.missing_genome_evaluations !== 0) {
          architectureReport.evolution = 'não executada: geração 0 sem cobertura/ACK/latência íntegra';
          continue;
        }

        executeMysql(`CALL sp_nn_evolve_training_experiment_v2('${experimentId}', 0, ${eliteCount})`);
        architectureReport.evolution = executeMysql(`
          SELECT status FROM nn_training_generation_v2
          WHERE experiment_id='${experimentId}' AND generation=0
        `);
        architectureReport.generations[0].persisted_scores = generationScores(experimentId, 0);
        const generationOne = await evaluateGeneration(architecture, experimentId, 1);
        architectureReport.generations.push({ generation: 1, ...generationOne });
        if (generationOne.integrity_failed
            || generationOne.latency_budget_exceeded
            || generationOne.missing_genome_evaluations !== 0) {
          architectureReport.finalization = 'pendente: geração 1 sem cobertura/ACK/latência íntegra';
          continue;
        }
        executeMysql(`CALL sp_nn_evolve_training_experiment_v2('${experimentId}', 1, ${eliteCount})`);
        architectureReport.finalization = executeMysql(`
          SELECT status FROM nn_training_generation_v2
          WHERE experiment_id='${experimentId}' AND generation=1
        `);
        architectureReport.generations[1].persisted_scores = generationScores(experimentId, 1);
      } catch (error) {
        architectureReport.error = error.message;
      } finally {
        await stopProcess(backend);
      }
    }
  } finally {
    await stopProcess(ownedFrontend);
  }

  report.finished_at = new Date().toISOString();
  report.result_directory = resultDirectory;
  const reportPath = path.join(resultDirectory, `genetics-v2-${new Date().toISOString().replaceAll(':', '-')}.json`);
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  process.stdout.write(`${JSON.stringify({ report_path: reportPath, architectures: report.architectures.map((architecture) => ({
    alias: architecture.alias,
    topology: architecture.topology,
    evolution: architecture.evolution,
    finalization: architecture.finalization,
    error: architecture.error,
    generations: architecture.generations.map((generation) => ({
      generation: generation.generation,
      missing_genome_evaluations: generation.missing_genome_evaluations,
      integrity_failed: generation.integrity_failed,
      latency_budget_exceeded: generation.latency_budget_exceeded,
      session_ids: generation.runs.map((run) => run.session_id),
      mean_ws_round_trip_ms: generation.runs.map((run) => run.ws_round_trip_ms?.mean ?? null),
      p95_ws_round_trip_ms: generation.runs.map((run) => run.ws_round_trip_ms?.p95 ?? null),
      score: generation.persisted_scores,
    })),
  })) }, null, 2)}\n`);

  if (report.architectures.some((architecture) => architecture.error
      || architecture.finalization !== 'COMPLETE'
      || architecture.generations.some((generation) => generation.integrity_failed
        || generation.latency_budget_exceeded
        || generation.missing_genome_evaluations !== 0))) {
    process.exitCode = 1;
  }
}
