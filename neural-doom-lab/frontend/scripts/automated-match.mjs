import { existsSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { chromium } from 'playwright-core';

const baseUrl = process.env.DOOM_FRONTEND_URL ?? 'http://127.0.0.1:5173/';
const durationSeconds = Number(process.env.DOOM_MATCH_SECONDS ?? 30);
const outputDirectory = process.env.DOOM_RESULT_DIR ?? path.join(tmpdir(), 'neural-doom-results');
const edgePath = process.env.DOOM_EDGE_PATH ?? [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
].find((candidate) => {
  return existsSync(candidate);
});

if (!Number.isInteger(durationSeconds) || durationSeconds < 5 || durationSeconds > 600) {
  throw new Error('DOOM_MATCH_SECONDS precisa estar entre 5 e 600.');
}
if (!edgePath) {
  throw new Error('Microsoft Edge não foi encontrado; configure DOOM_EDGE_PATH.');
}

const runId = new Date().toISOString().replaceAll(':', '-');
const frameTimes = new Map();
const actions = {};
const responseLatencies = [];
const telemetryTypes = {};
const pageErrors = [];
const httpErrors = [];
let npcStateRequests = 0;
let sessionId = null;
let sessionAck = null;
let sessionReceiptAck = null;
let engineName = null;
const selectedArchitectureName = process.env.DOOM_ARCHITECTURE_NAME ?? null;
const decisions = [];

function parseFrame(payload) {
  const text = typeof payload === 'string' ? payload : payload?.toString?.();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

const browser = await chromium.launch({
  executablePath: edgePath,
  headless: true,
  args: ['--disable-background-timer-throttling', '--disable-renderer-backgrounding'],
});

try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  page.setDefaultTimeout(15000);
  await page.addInitScript((backendWebSocketUrl) => {
    if (!backendWebSocketUrl) return;
    const NativeWebSocket = globalThis.WebSocket;
    globalThis.WebSocket = class RoutedWebSocket extends NativeWebSocket {
      constructor(url, protocols) {
        const isAiBridge = new URL(url, window.location.href).pathname === '/ws/ai';
        const routedUrl = isAiBridge ? backendWebSocketUrl : url;
        if (protocols === undefined) super(routedUrl);
        else super(routedUrl, protocols);
      }
    };
  }, process.env.DOOM_WS_URL ?? null);
  page.on('pageerror', (error) => pageErrors.push(String(error)));
  page.on('response', (response) => {
    if (response.status() >= 400) {
      httpErrors.push({ status: response.status(), url: response.url() });
    }
  });
  page.on('console', (message) => {
    if (message.type() === 'error') {
      pageErrors.push({ text: message.text(), location: message.location() });
    }
  });
  page.on('websocket', (socket) => {
    if (!socket.url().endsWith('/ws/ai')) return;
    socket.on('framesent', ({ payload }) => {
      const message = parseFrame(payload);
      if (!message) return;
      if (message.session_id) sessionId = message.session_id;
      if (message.type === 'npc_state') {
        npcStateRequests += 1;
        frameTimes.set(message.request_id, performance.now());
      }
      if (message.type === 'combat_event') {
        const eventType = message.event?.event_type ?? 'unknown';
        telemetryTypes[eventType] = (telemetryTypes[eventType] ?? 0) + 1;
      }
    });
    socket.on('framereceived', ({ payload }) => {
      const message = parseFrame(payload);
      if (!message) return;
      if (message.type === 'npc_action' && message.request_id) {
        const sentAt = frameTimes.get(message.request_id);
        if (sentAt !== undefined) responseLatencies.push(performance.now() - sentAt);
        if (message.action) actions[message.action] = (actions[message.action] ?? 0) + 1;
        decisions.push({
          action: message.action,
          architecture_name: message.architecture_name ?? null,
          run_id: message.run_id ?? null,
          mysql_inference_ms: message.mysql_inference_ms ?? null,
          database_round_trip_ms: message.database_round_trip_ms ?? null,
        });
      } else if (message.type === 'session_end_ack') {
        sessionAck = message;
      } else if (message.type === 'session_end_ack_receipt_ack') {
        sessionReceiptAck = message;
      }
    });
  });

  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await page.locator('#ai-mode').selectOption('external');
  await page.waitForFunction(
    () => document.querySelector('#ai-debug-backend')?.textContent.includes('Connected'),
  );
  if (selectedArchitectureName) {
    await page.locator('.neural-lab-summary').click();
    await page.waitForFunction(
      () => document.querySelector('#lab-status')?.textContent.includes('MySQL conectado'),
      null,
      { timeout: 10000 },
    );
    await page.locator('#lab-architecture-select').selectOption(selectedArchitectureName);
    await page.waitForFunction(
      (name) => document.querySelector('#lab-architecture-summary')?.textContent.includes(name),
      selectedArchitectureName,
    );
  }
  await page.locator('#play-button').click();
  await page.waitForFunction(
    () => document.querySelector('#session-engine-state')?.textContent === 'Engine online',
    null,
    { timeout: 30000 },
  );
  await page.locator('#doom-canvas').focus();

  // Start New Game on E1M1 and choose the lowest damage difficulty.
  await page.keyboard.press('Enter');
  await page.waitForTimeout(250);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(500);
  const closeDeadline = Date.now() + 7000;
  while (Date.now() < closeDeadline && !sessionAck) {
    await page.waitForTimeout(50);
  }
  while (
    Date.now() < closeDeadline
    && sessionAck?.ack_token
    && !sessionReceiptAck
  ) {
    await page.waitForTimeout(50);
  }
  await page.keyboard.press('ArrowUp');
  await page.waitForTimeout(300);
  await page.keyboard.press('ArrowUp');
  await page.waitForTimeout(300);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(1000);

  const gameLogStart = await page.locator('#log-output').innerText();
  const controlStartedAt = Date.now();
  const controlDeadline = Date.now() + durationSeconds * 1000;
  const pattern = [
    [['Shift', 'ArrowUp'], 3000],
    [['Space'], 250],
    [['Shift', 'ArrowUp'], 3000],
    [['Control'], 800],
    [['ArrowRight'], 850],
    [['Shift', 'ArrowUp'], 3000],
    [['Space'], 250],
    [['Shift', 'ArrowUp'], 3000],
    [['Control'], 800],
    [['ArrowLeft'], 1500],
    [['Shift', 'ArrowUp'], 3000],
  ];

  while (Date.now() < controlDeadline) {
    for (const [keys, duration] of pattern) {
      if (Date.now() >= controlDeadline) break;
      for (const key of keys) await page.keyboard.down(key);
      await page.waitForTimeout(duration);
      for (const key of [...keys].reverse()) await page.keyboard.up(key);
    }
  }

  const canvasPath = path.join(outputDirectory, `${runId}.png`);
  await mkdir(outputDirectory, { recursive: true });
  await page.locator('#doom-canvas').screenshot({ path: canvasPath });
  const labScreenshotPath = selectedArchitectureName
    ? path.join(outputDirectory, `${runId}-lab.png`)
    : null;
  if (labScreenshotPath) await page.screenshot({ path: labScreenshotPath, fullPage: true });
  const metricsBeforeClose = await page.locator('#ai-debug-metrics').innerText();
  const gameLogEnd = await page.locator('#log-output').innerText();
  const startSkill = gameLogEnd.match(/startskill\s+(\d+)/i)?.[1] ?? null;

  await page.locator('#ai-mode').selectOption('original');
  await page.waitForFunction(
    () => document.querySelector('#ai-debug-backend')?.textContent.includes('Inativo'),
    null,
    { timeout: 5000 },
  ).catch(() => {});
  await page.waitForTimeout(500);

  const record = {
    run_id: runId,
    frontend_url: baseUrl,
    websocket_url: process.env.DOOM_WS_URL ?? 'ws://127.0.0.1:8000/ws/ai',
    architecture_name: selectedArchitectureName ?? process.env.NN_ARCHITECTURE_NAME ?? 'npc_teste_4_6_4',
    requested_architecture_name: selectedArchitectureName,
    environment: 'Freedoom2 bundle, E1M1, browser Edge headless, EXTERNAL_AI, MySQL backend',
    skill: startSkill === null ? null : Number(startSkill),
    duration_seconds: durationSeconds,
    actual_control_seconds: Number(((Date.now() - controlStartedAt) / 1000).toFixed(2)),
    session_id: sessionId,
    npc_state_requests: npcStateRequests,
    decisions_received: Object.values(actions).reduce((sum, count) => sum + count, 0),
    actions_selected_by_sql: actions,
    decisions,
    ws_round_trip_ms: responseLatencies.length ? {
      count: responseLatencies.length,
      mean: responseLatencies.reduce((sum, value) => sum + value, 0) / responseLatencies.length,
      p95: [...responseLatencies].sort((a, b) => a - b)[Math.ceil(responseLatencies.length * 0.95) - 1],
      samples: responseLatencies.map((value) => Number(value.toFixed(3))),
    } : null,
    combat_events_sent: telemetryTypes,
    metrics_before_session_close: metricsBeforeClose,
    engine_log_tail: gameLogEnd.split(/\r?\n/).slice(-40),
    session_end_ack: sessionAck ? {
      closed: sessionAck.closed,
      session_id: sessionAck.session_id,
      training_evaluation_complete: sessionAck.training_evaluation_complete,
      action_metrics: sessionAck.action_metrics,
    } : null,
    session_end_ack_receipt: sessionReceiptAck ? {
      confirmed: sessionReceiptAck.confirmed,
      session_id: sessionReceiptAck.session_id,
    } : null,
    engine_start_log: gameLogStart.includes('Engine initialized successfully.'),
    screenshot: canvasPath,
    neural_laboratory: selectedArchitectureName ? {
      screenshot: labScreenshotPath,
      selected_architecture: selectedArchitectureName,
      live_action: await page.locator('#lab-live-action').innerText(),
      live_identity: await page.locator('#lab-live-identity').innerText(),
      engine_result: await page.locator('#lab-live-engine-result').innerText(),
      latency: await page.locator('#lab-live-latency').innerText(),
      visible_activation_count: await page.locator('#lab-activations .lab-neuron-row').count(),
      activation_rows: await page.locator('#lab-activations .lab-neuron-row').allInnerTexts(),
    } : null,
    browser_errors: pageErrors,
    http_errors: httpErrors,
  };
  const resultPath = path.join(outputDirectory, `${runId}.json`);
  await writeFile(resultPath, `${JSON.stringify(record, null, 2)}\n`, 'utf8');
  process.stdout.write(`${JSON.stringify({ result_path: resultPath, ...record }, null, 2)}\n`);

  if (!sessionAck?.closed) process.exitCode = 2;
  if (sessionAck?.training_evaluation_complete && !sessionReceiptAck?.confirmed) process.exitCode = 4;
  if (record.decisions_received === 0) process.exitCode = 3;
} finally {
  await browser.close();
}
