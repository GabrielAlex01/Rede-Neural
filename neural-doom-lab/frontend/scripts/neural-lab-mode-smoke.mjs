import { existsSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { chromium } from 'playwright-core';

const baseUrl = process.env.DOOM_FRONTEND_URL ?? 'http://127.0.0.1:5173/';
const outputDirectory = process.env.DOOM_MODE_RESULT_DIR
  ?? path.join(tmpdir(), 'neural-doom-mode-check');
const edgePath = process.env.DOOM_EDGE_PATH ?? [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
].find((candidate) => existsSync(candidate));

if (!edgePath) throw new Error('Microsoft Edge não foi encontrado; configure DOOM_EDGE_PATH.');
await mkdir(outputDirectory, { recursive: true });

const errors = [];
const neuralSockets = [];
let neuralDecisionRequests = 0;
const labRequests = [];
const browser = await chromium.launch({
  executablePath: edgePath,
  headless: true,
  args: ['--disable-background-timer-throttling', '--disable-renderer-backgrounding'],
});

try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  page.on('pageerror', (error) => errors.push(String(error)));
  page.on('console', (message) => {
    const location = message.location();
    if (message.type() === 'error' && !location.url.endsWith('/favicon.ico')) {
      errors.push({ text: message.text(), location });
    }
  });
  page.on('request', (request) => {
    if (request.url().includes('/api/lab')) labRequests.push(request.url());
  });
  page.on('websocket', (socket) => {
    if (new URL(socket.url()).pathname !== '/ws/ai') return;
    neuralSockets.push(socket.url());
    socket.on('framesent', ({ payload }) => {
      try {
        if (JSON.parse(String(payload)).type === 'npc_state') neuralDecisionRequests += 1;
      } catch {
        // Binary/keepalive frames do not represent a neural decision.
      }
    });
  });

  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await page.locator('#ai-provider').selectOption('local');
  await page.locator('#ai-mode').selectOption('external');
  await page.waitForFunction(
    () => document.querySelector('#ai-debug-backend')?.textContent.includes('Local mock selected'),
  );
  await page.locator('#play-button').click();
  await page.waitForFunction(
    () => document.querySelector('#session-engine-state')?.textContent === 'Engine online',
    null,
    { timeout: 30000 },
  );
  await page.locator('#doom-canvas').focus();
  await page.keyboard.press('Enter');
  await page.waitForTimeout(250);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(500);
  await page.keyboard.press('ArrowUp');
  await page.waitForTimeout(150);
  await page.keyboard.press('ArrowUp');
  await page.waitForTimeout(150);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(1000);

  const deadline = Date.now() + 15000;
  const pattern = [
    [['Shift', 'ArrowUp'], 1800],
    [['Control'], 600],
    [['ArrowRight'], 700],
  ];
  while (Date.now() < deadline) {
    for (const [keys, duration] of pattern) {
      if (Date.now() >= deadline) break;
      for (const key of keys) await page.keyboard.down(key);
      await page.waitForTimeout(duration);
      for (const key of [...keys].reverse()) await page.keyboard.up(key);
    }
  }

  const gameLog = await page.locator('#log-output').innerText();
  const localDecisionObserved = /state received → local mock/i.test(gameLog);
  const screenshot = path.join(outputDirectory, 'freedoom-local-mock.png');
  await page.locator('#doom-canvas').screenshot({ path: screenshot });
  if (neuralDecisionRequests) throw new Error(`Local mock enviou ${neuralDecisionRequests} decisões ao backend neural.`);
  if (labRequests.length) throw new Error('Local mock gerou consulta ao laboratório/MySQL.');
  if (!localDecisionObserved) throw new Error('Nenhuma ação local mock foi observada no log do jogo.');
  if (errors.length) throw new Error(`Erros do browser: ${JSON.stringify(errors)}`);

  const report = {
    result: 'PASS',
    mode: 'EXTERNAL_AI',
    provider: 'Local mock (JavaScript de demonstração; sem inferência SQL)',
    local_decision_observed: localDecisionObserved,
    neural_websocket_connections: neuralSockets.length,
    neural_decision_requests: neuralDecisionRequests,
    lab_or_mysql_requests: labRequests.length,
    screenshot,
    browser_errors: errors,
  };
  await writeFile(path.join(outputDirectory, 'report.json'), `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
} finally {
  await browser.close();
}
