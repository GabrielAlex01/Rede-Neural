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
const matchSeconds = Number(process.env.DOOM_MATCH_SECONDS ?? 75);
const repetitionsPerGenome = 2;
const maxAttemptsPerGeneration = 4;
const p95LatencyBudgetMs = 800;
const resultDirectory = process.env.DOOM_RESULT_DIR
  ?? path.join(tmpdir(), 'neural-doom-automated-experiments');
const report = {
  run_started_at: new Date().toISOString(),
  environment: {
    game_schema: gameSchema,
    map: 'Freedoom 2 E1M1',
    skill: 2,
    duration_seconds: matchSeconds,
    browser: 'Microsoft Edge headless, isolated context',
    input_pattern: 'fixed arrows/Space/Ctrl/Shift sequence from automated-match.mjs',
    genome_repetitions: repetitionsPerGenome,
    engine_random_seed: 'not explicitly configurable by the current web build',
  },
  architectures: [],
};

const architectures = [
  { name: 'auto_20261025_ref46', experiment: 'auto_20261025_ref_4_6_4', topology: [4, 6, 4] },
  { name: 'auto_20261025_h32', experiment: 'auto_20261025_h32_4_32_4', topology: [4, 32, 4] },
  { name: 'auto_20261025_h64', experiment: 'auto_20261025_h64_4_64_4', topology: [4, 64, 4] },
  { name: 'auto_20261025_deep6464', experiment: 'auto_20261025_deep_4_64_32_64_4', topology: [4, 64, 32, 64, 4] },
  { name: 'auto_20261025_deep12864128', experiment: 'auto_20261025_128_64_128', topology: [4, 128, 64, 128, 4] },
  { name: 'auto_20261025_deep25612864', experiment: 'auto_20261025_256_128_64', topology: [4, 256, 128, 64, 4] },
  { name: 'auto_20261025_h512', experiment: 'auto_20261025_512_4_512_4', topology: [4, 512, 4] },
];

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function executeMysql(query, input = undefined) {
  const result = spawnSync(mysqlPath, [
    `--login-path=${loginPath}`,
    `--database=${gameSchema}`,
    '--batch',
    '--raw',
    '--skip-column-names',
    ...(query ? ['--execute', query] : []),
  ], {
    cwd: repositoryDirectory,
    encoding: 'utf8',
    input,
    windowsHide: true,
    timeout: 30000,
  });
  if (result.error) throw new Error(`Falha ao iniciar mysql.exe: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`MySQL recusou a etapa solicitada: ${result.stderr.trim() || `exit ${result.status}`}`);
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
      const response = await fetch(url, { signal: AbortSignal.timeout(2000) });
      if (response.ok) return;
    } catch {}
    await delay(500);
  }
  throw new Error(`${label} não ficou saudável em ${timeoutMilliseconds} ms.`);
}

async function runBrowserMatch(architecture, generation, attempt) {
  const matchEnvironment = {
    ...process.env,
    DOOM_FRONTEND_URL: frontendUrl,
    DOOM_MATCH_SECONDS: String(matchSeconds),
    DOOM_WS_URL: `ws://127.0.0.1:${backendPort}/ws/ai`,
    DOOM_RESULT_DIR: resultDirectory,
    NN_ARCHITECTURE_NAME: architecture.name,
  };
  const output = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path.join(scriptDirectory, 'automated-match.mjs')], {
      cwd: frontendDirectory,
      env: matchEnvironment,
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
    throw new Error(`Harness de jogo não produziu JSON válido (exit ${output.code}): ${output.stderr.slice(-1000)}`);
  }

  match.generation_under_test = generation;
  match.attempt = attempt;
  match.process_exit_code = output.code;
  match.mysql_persisted = match.session_id ? queryPersistedSession(match.session_id) : null;
  const actionMetrics = match.session_end_ack?.action_metrics;
  match.validation = {
    acknowledged: match.session_end_ack?.closed === true,
    persisted_closed: match.mysql_persisted?.closed === true,
    architecture_matches: match.mysql_persisted?.architecture === architecture.name,
    decision_counts_match: Number.isInteger(actionMetrics?.sql_decisions)
      && actionMetrics.sql_decisions === match.mysql_persisted?.sql_decisions,
    applied_actions: Number(actionMetrics?.applied ?? 0) > 0,
    combat_events: Number(match.mysql_persisted?.combat_event_rows ?? 0) > 0,
  };
  match.validation.complete = Object.values(match.validation).every((value) => value === true);
  return match;
}

function queryPersistedSession(sessionId) {
  if (!/^[0-9a-f-]{36}$/i.test(sessionId)) throw new Error('session_id inválido no relatório do navegador.');
  const sid = sessionId.toLowerCase();
  const query = `SELECT JSON_OBJECT(
    'session_id', s.session_id,
    'closed', s.encerrada_em IS NOT NULL,
    'architecture', a.nome,
    'npcs', (SELECT COUNT(*) FROM nn_session_npc n WHERE n.session_id=s.session_id),
    'sql_decisions', (SELECT COUNT(*) FROM nn_decision_run d WHERE d.session_id=s.session_id),
    'decisions_by_action', (SELECT JSON_OBJECTAGG(action, action_count) FROM (SELECT action, COUNT(*) AS action_count FROM nn_decision_run WHERE session_id=s.session_id GROUP BY action) actions),
    'combat_event_rows', (SELECT COUNT(*) FROM nn_combat_event e WHERE e.session_id=s.session_id),
    'damage_to_player', (SELECT COALESCE(SUM(valor),0) FROM nn_combat_event e WHERE e.session_id=s.session_id AND e.event_type='PLAYER_DAMAGE'),
    'player_kills', (SELECT COALESCE(SUM(valor),0) FROM nn_combat_event e WHERE e.session_id=s.session_id AND e.event_type='PLAYER_KILL'),
    'damage_received', (SELECT COALESCE(SUM(valor),0) FROM nn_combat_event e WHERE e.session_id=s.session_id AND e.event_type='NPC_DAMAGE'),
    'npc_deaths', (SELECT COALESCE(SUM(valor),0) FROM nn_combat_event e WHERE e.session_id=s.session_id AND e.event_type='NPC_DEATH'),
    'evaluated_genomes', (SELECT COUNT(*) FROM nn_genome_evaluation e WHERE e.session_id=s.session_id),
    'mean_fitness', (SELECT ROUND(AVG(fitness),4) FROM nn_genome_evaluation e WHERE e.session_id=s.session_id),
    'best_fitness', (SELECT ROUND(MAX(fitness),4) FROM nn_genome_evaluation e WHERE e.session_id=s.session_id),
    'experiment_id', (SELECT experiment_id FROM nn_training_experiment_session x WHERE x.session_id=s.session_id LIMIT 1)
  ) FROM nn_engine_session s JOIN nn_architecture a ON a.id=s.architecture_id
  WHERE s.session_id='${sid}'`;
  const encoded = executeMysql(query);
  return encoded ? JSON.parse(encoded) : { session_id: sid, persisted: false };
}

function missingGenomeEvaluations(experimentId, generation) {
  const query = `SELECT COUNT(*) FROM nn_genome genome
    WHERE genome.architecture_id=(SELECT architecture_id FROM nn_training_experiment WHERE experiment_id='${experimentId}')
      AND genome.geracao=${generation}
      AND (SELECT COUNT(*) FROM nn_genome_evaluation evaluation
        JOIN nn_training_experiment_session linked ON linked.session_id=evaluation.session_id
        WHERE linked.experiment_id='${experimentId}' AND evaluation.genome_id=genome.id)<${repetitionsPerGenome}`;
  return Number(executeMysql(query));
}

function experimentGenerationSummary(experimentId) {
  const query = `SELECT JSON_ARRAYAGG(JSON_OBJECT(
      'generation', results.geracao,
      'evaluation_rows', results.evaluation_rows,
      'genomes_evaluated', results.genomes_evaluated,
      'mean_fitness', results.mean_fitness,
      'best_fitness', results.best_fitness,
      'damage_to_player', results.damage_to_player,
      'player_kills', results.player_kills,
      'damage_received', results.damage_received,
      'npc_deaths', results.npc_deaths,
      'survival_seconds', results.survival_seconds
    )) FROM (
      SELECT genome.geracao, COUNT(*) AS evaluation_rows,
        COUNT(DISTINCT evaluation.genome_id) AS genomes_evaluated,
        ROUND(AVG(evaluation.fitness),4) AS mean_fitness,
        ROUND(MAX(evaluation.fitness),4) AS best_fitness,
        SUM(evaluation.damage_to_player) AS damage_to_player,
        SUM(evaluation.player_kills) AS player_kills,
        SUM(evaluation.damage_received) AS damage_received,
        SUM(evaluation.npc_deaths) AS npc_deaths,
        SUM(evaluation.survival_seconds) AS survival_seconds
      FROM nn_genome_evaluation evaluation
      JOIN nn_genome genome ON genome.id=evaluation.genome_id
      JOIN nn_training_experiment_session linked ON linked.session_id=evaluation.session_id
      WHERE linked.experiment_id='${experimentId}'
      GROUP BY genome.geracao
    ) results`;
  const encoded = executeMysql(query);
  return encoded ? JSON.parse(encoded) : [];
}

async function startBackend(architectureName) {
  try {
    const existing = await fetch(`http://127.0.0.1:${backendPort}/health`, { signal: AbortSignal.timeout(1000) });
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

async function ensureFrontend() {
  let response;
  try {
    response = await fetch(frontendUrl, { signal: AbortSignal.timeout(1000) });
  } catch {}

  if (response) {
    const html = response.ok ? await response.text() : '';
    if (response.ok && html.includes('<title>Neural Doom Lab</title>')) return null;
    throw new Error(`A URL ${frontendUrl} não aponta para o frontend Neural Doom Lab; não será substituída.`);
  }

  const frontendAddress = new URL(frontendUrl);
  if (frontendAddress.protocol !== 'http:'
      || !['127.0.0.1', 'localhost', '::1'].includes(frontendAddress.hostname)) {
    throw new Error('O runner só pode iniciar o frontend em uma URL HTTP local.');
  }
  const frontendPort = Number(frontendAddress.port || 80);
  const viteEntry = path.join(frontendDirectory, 'node_modules', 'vite', 'bin', 'vite.js');
  if (!existsSync(viteEntry)) throw new Error('Vite não está instalado em frontend/node_modules.');
  const child = spawn(process.execPath, [
    viteEntry, '--host', frontendAddress.hostname, '--port', String(frontendPort), '--strictPort',
  ], {
    cwd: frontendDirectory,
    windowsHide: true,
    stdio: 'ignore',
  });
  try {
    await waitForHttp(frontendUrl, child, 'Frontend Vite');
    const health = await fetch(frontendUrl, { signal: AbortSignal.timeout(2000) });
    if (!health.ok || !(await health.text()).includes('<title>Neural Doom Lab</title>')) {
      throw new Error('Vite iniciou, mas não está servindo o Neural Doom Lab esperado.');
    }
    return child;
  } catch (error) {
    child.kill();
    throw error;
  }
}

async function stopBackend(child) {
  if (!child || child.exitCode !== null) return;
  child.kill();
  await Promise.race([
    new Promise((resolve) => child.once('close', resolve)),
    delay(5000),
  ]);
}

async function evaluateGeneration(architecture, experimentId, generation) {
  const generationRuns = [];
  let missing = missingGenomeEvaluations(experimentId, generation);
  let latencyBudgetExceeded = false;
  for (let attempt = 1; missing > 0 && attempt <= maxAttemptsPerGeneration; attempt += 1) {
    const result = await runBrowserMatch(architecture, generation, attempt);
    generationRuns.push(result);
    const actionMetrics = result.session_end_ack?.action_metrics;
    const persisted = result.mysql_persisted;
    process.stdout.write(`${architecture.name} gen${generation} partida ${attempt}: SQL=${persisted?.sql_decisions ?? 0}, `
      + `NPC=${persisted?.npcs ?? 0}, mortes=${persisted?.npc_deaths ?? 0}, `
      + `ATTACK aplicado=${actionMetrics?.actions?.ATTACK?.applied ?? 0}, `
      + `fallback=${actionMetrics?.fallback ?? 0}, P95=${result.ws_round_trip_ms?.p95?.toFixed(1) ?? 'n/a'}ms, `
      + `ACK=${result.session_end_ack?.closed === true}\n`);
    missing = missingGenomeEvaluations(experimentId, generation);
    if (result.ws_round_trip_ms?.p95 >= p95LatencyBudgetMs) {
      latencyBudgetExceeded = true;
      break;
    }
    if (result.validation?.complete !== true) break;
  }
  return {
    runs: generationRuns,
    missing_genomes: missing,
    latency_budget_exceeded: latencyBudgetExceeded,
    integrity_failed: generationRuns.some((result) => result.validation?.complete !== true),
  };
}

if (gameSchema !== 'neural_doom_local_game_20261024') {
  throw new Error('Este script está deliberadamente restrito ao schema local isolado configurado.');
}
if (!existsSync(mysqlPath) || !existsSync(pythonPath)) {
  throw new Error('mysql.exe ou Python do ambiente virtual não foi encontrado; defina MYSQL_EXE/PYTHON_EXE.');
}
if (!Number.isInteger(matchSeconds) || matchSeconds < 5 || matchSeconds > 600) {
  throw new Error('DOOM_MATCH_SECONDS precisa estar entre 5 e 600.');
}
if (!Number.isInteger(backendPort) || backendPort < 1024 || backendPort > 65535) {
  throw new Error('DOOM_EVAL_BACKEND_PORT inválida.');
}

if (matchSeconds !== 75) {
  throw new Error('A comparação entre arquiteturas está calibrada para partidas de 75 segundos.');
}

await mkdir(resultDirectory, { recursive: true });
executeMysql('', await readFile(
  path.join(repositoryDirectory, 'database', '11_prepare_autonomous_architecture_experiments.sql'), 'utf8',
));
const ownedFrontend = await ensureFrontend();

if (process.argv.includes('--prepare-only')) {
  await stopBackend(ownedFrontend);
  process.stdout.write(`Preparação validada para ${gameSchema}; nenhum experimento ou partida foi iniciado.\n`);
} else {
for (const architecture of architectures) {
  const experimentId = executeMysql(
    `SELECT experiment_id FROM nn_training_experiment WHERE nome='${architecture.experiment}'`,
  );
  if (!/^[0-9a-f-]{36}$/i.test(experimentId)) {
    report.architectures.push({ ...architecture, error: 'Experimento não encontrado no schema isolado.' });
    continue;
  }

  const architectureReport = {
    ...architecture,
    experiment_id: experimentId,
    generations: [],
  };
  report.architectures.push(architectureReport);
  let backend;
  try {
    backend = await startBackend(architecture.name);
    const generationZero = await evaluateGeneration(architecture, experimentId, 0);
    architectureReport.generations.push({ generation: 0, ...generationZero });
    if (generationZero.integrity_failed || generationZero.latency_budget_exceeded || generationZero.missing_genomes !== 0) {
      architectureReport.evolution = generationZero.latency_budget_exceeded
        ? `não executada: P95 ultrapassou ${p95LatencyBudgetMs} ms`
        : generationZero.integrity_failed
          ? 'não executada: partida sem ACK, persistência, ação aplicada ou telemetria íntegros'
          : 'não executada: faltam avaliações reais por genoma na geração 0';
      continue;
    }

    const generationOneExists = Number(executeMysql(
      `SELECT COUNT(*) FROM nn_training_experiment_generation WHERE experiment_id='${experimentId}' AND geracao=1`,
    )) > 0;
    if (generationOneExists) {
      architectureReport.evolution = 'geração 1 já existia; configuração mantida';
    } else {
      executeMysql(`CALL sp_nn_evolve_training_experiment('${experimentId}', 0, 2)`);
      architectureReport.evolution = 'geração 1 criada após avaliações reais suficientes';
    }
    const generationOne = await evaluateGeneration(architecture, experimentId, 1);
    architectureReport.generations.push({ generation: 1, ...generationOne });
    if (generationOne.integrity_failed) {
      architectureReport.evolution += '; avaliação interrompida por integridade incompleta';
    }
    architectureReport.sql_generation_summary = experimentGenerationSummary(experimentId);
  } catch (error) {
    architectureReport.error = error.message;
  } finally {
    await stopBackend(backend);
  }
}

await stopBackend(ownedFrontend);

report.run_finished_at = new Date().toISOString();
report.result_directory = resultDirectory;
const reportPath = path.join(resultDirectory, `architecture-experiments-${new Date().toISOString().replaceAll(':', '-')}.json`);
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
const summary = report.architectures.map((architecture) => ({
  name: architecture.name,
  topology: architecture.topology,
  evolution: architecture.evolution,
  error: architecture.error,
  generations: architecture.generations?.map((generation) => ({
    generation: generation.generation,
    missing_genomes: generation.missing_genomes,
    sessions: generation.runs.map((run) => ({
      session_id: run.session_id,
      mysql: run.mysql_persisted,
      action_metrics: run.session_end_ack?.action_metrics,
      ws_round_trip_ms: run.ws_round_trip_ms,
      ack_closed: run.session_end_ack?.closed === true,
    })),
  })),
  sql_generation_summary: architecture.sql_generation_summary,
}));
process.stdout.write(`${JSON.stringify({ report_path: reportPath, run_started_at: report.run_started_at, run_finished_at: report.run_finished_at, architectures: summary }, null, 2)}\n`);

if (report.architectures.every((architecture) => architecture.error || architecture.generations?.length === 0)) {
  process.exitCode = 1;
}
}
