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
let npcStateRequests = 0;
let sessionId = null;
let sessionAck = null;
let engineName = null;

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
  page.on('console', (message) => {
    if (message.type() === 'error') pageErrors.push(message.text());
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
      } else if (message.type === 'session_end_ack') {
        sessionAck = message;
      }
    });
  });

  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await page.locator('#ai-mode').selectOption('external');
  await page.waitForFunction(
    () => document.querySelector('#ai-debug-backend')?.textContent.includes('Connected'),
  );
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
    architecture_name: process.env.NN_ARCHITECTURE_NAME ?? 'npc_teste_4_6_4',
    environment: 'Freedoom2 bundle, E1M1, browser Edge headless, EXTERNAL_AI, MySQL backend',
    skill: startSkill === null ? null : Number(startSkill),
    duration_seconds: durationSeconds,
    actual_control_seconds: Number(((Date.now() - controlStartedAt) / 1000).toFixed(2)),
    session_id: sessionId,
    npc_state_requests: npcStateRequests,
    decisions_received: Object.values(actions).reduce((sum, count) => sum + count, 0),
    actions_selected_by_sql: actions,
    ws_round_trip_ms: responseLatencies.length ? {
      count: responseLatencies.length,
      mean: responseLatencies.reduce((sum, value) => sum + value, 0) / responseLatencies.length,
      p95: [...responseLatencies].sort((a, b) => a - b)[Math.ceil(responseLatencies.length * 0.95) - 1],
    } : null,
    combat_events_sent: telemetryTypes,
    metrics_before_session_close: metricsBeforeClose,
    engine_log_tail: gameLogEnd.split(/\r?\n/).slice(-40),
    session_end_ack: sessionAck ? {
      closed: sessionAck.closed,
      session_id: sessionAck.session_id,
      action_metrics: sessionAck.action_metrics,
    } : null,
    engine_start_log: gameLogStart.includes('Engine initialized successfully.'),
    screenshot: canvasPath,
    browser_errors: pageErrors,
  };
  const resultPath = path.join(outputDirectory, `${runId}.json`);
  await writeFile(resultPath, `${JSON.stringify(record, null, 2)}\n`, 'utf8');
  process.stdout.write(`${JSON.stringify({ result_path: resultPath, ...record }, null, 2)}\n`);

  if (!sessionAck?.closed) process.exitCode = 2;
  if (record.decisions_received === 0) process.exitCode = 3;
} finally {
  await browser.close();
}
