import { existsSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { chromium } from 'playwright-core';

const baseUrl = process.env.DOOM_FRONTEND_URL ?? 'http://127.0.0.1:5173/';
const outputDirectory = process.env.DOOM_LAB_UI_RESULT_DIR
  ?? path.join(os.tmpdir(), 'neural-doom-lab-ui-check');
const edgePath = process.env.DOOM_EDGE_PATH ?? [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
].find((candidate) => existsSync(candidate));

if (!edgePath) throw new Error('Microsoft Edge não foi encontrado; configure DOOM_EDGE_PATH.');
await mkdir(outputDirectory, { recursive: true });

const errors = [];
const labRequests = [];
const httpErrors = [];
const failedRequests = [];
const browser = await chromium.launch({
  executablePath: edgePath,
  headless: true,
  args: ['--disable-background-timer-throttling', '--disable-renderer-backgrounding'],
});

try {
  const context = await browser.newContext({ viewport: { width: 1365, height: 1000 } });
  const page = await context.newPage();
  page.on('pageerror', (error) => errors.push(String(error)));
  page.on('console', (message) => {
    if (message.type() === 'error') {
      const location = message.location();
      if (!location.url.endsWith('/favicon.ico')) errors.push({ text: message.text(), location });
    }
  });
  page.on('response', (response) => {
    if (response.status() >= 400) httpErrors.push({ status: response.status(), url: response.url() });
  });
  page.on('request', (request) => {
    if (request.url().includes('/api/lab')) labRequests.push(request.url());
  });
  page.on('requestfailed', (request) => {
    failedRequests.push({ url: request.url(), error: request.failure()?.errorText });
  });

  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await page.locator('#neural-lab').waitFor();
  if (await page.locator('#neural-lab').evaluate((node) => node.open)) {
    throw new Error('O painel do laboratório deveria iniciar recolhido.');
  }
  if (labRequests.length !== 0) throw new Error('O painel recolhido gerou consultas ao MySQL.');

  await page.locator('.neural-lab-summary').click();
  await page.waitForFunction(() => document.querySelector('#lab-status')?.textContent.includes('MySQL conectado'), null, { timeout: 10000 });
  const architectureCount = await page.locator('#lab-architecture-select option').count();
  if (architectureCount < 1) throw new Error('Nenhuma arquitetura foi carregada pelo endpoint SQL.');
  await page.waitForFunction(() => document.querySelector('#lab-layer-list')?.textContent.includes('INPUT'));
  await page.waitForFunction(() => document.querySelector('#lab-weights .lab-weight-row'));
  await page.waitForFunction(() => {
    const value = document.querySelector('#lab-weight-bias')?.textContent ?? '';
    return /Bias do neurônio \d+: -?\d/.test(value);
  });
  const selectedGenomeWeights = await page.locator('#lab-weights .lab-weight-row').count();
  const selectedGenomeBias = await page.locator('#lab-weight-bias').innerText();

  await page.locator('#lab-new-topology').fill('4,64,4');
  await page.waitForFunction(() => document.querySelector('#lab-parameter-count')?.textContent.includes('580 parâmetros treináveis'));
  await page.screenshot({ path: path.join(outputDirectory, 'neural-lab-panel.png'), fullPage: true });

  await page.setViewportSize({ width: 390, height: 844 });
  const mobileLayout = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
  }));
  if (mobileLayout.document > mobileLayout.viewport) {
    throw new Error(`O laboratório causou overflow horizontal em mobile: ${JSON.stringify(mobileLayout)}`);
  }
  if (errors.length) throw new Error(`Erros do navegador: ${JSON.stringify(errors)}; HTTP=${JSON.stringify(httpErrors)}; failed=${JSON.stringify(failedRequests)}`);

  const report = {
    result: 'PASS',
    architectureCount,
    selectedArchitecture: await page.locator('#lab-architecture-select').inputValue(),
    selectedGenomeWeights,
    selectedGenomeBias,
    sqlReadRequests: labRequests.length,
    collapsedPanelDidNotPoll: true,
    topologyEstimate: '4 -> 64 -> 4 = 580 parâmetros treináveis',
    mobileLayout,
    screenshot: path.join(outputDirectory, 'neural-lab-panel.png'),
    pageErrors: errors,
    httpErrors,
    failedRequests,
  };
  await writeFile(path.join(outputDirectory, 'report.json'), JSON.stringify(report, null, 2));
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
} finally {
  await browser.close();
}
