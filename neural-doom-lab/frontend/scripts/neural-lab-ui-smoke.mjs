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
  const catalogPayload = await page.evaluate(async () => {
    const apiBase = `${window.location.protocol}//${window.location.hostname}:8000`;
    const response = await fetch(`${apiBase}/api/lab/architectures`);
    if (!response.ok) throw new Error(`Catálogo SQL HTTP ${response.status}`);
    return await response.json();
  });
  const catalog = catalogPayload.architectures ?? [];
  const playableInCatalogOrder = catalog.filter((item) => Number(item.playable) === 1);
  const catalogPlayableNames = playableInCatalogOrder.map((item) => item.architecture_name).sort();
  const selectorNames = await page.locator('#lab-architecture-select option').evaluateAll(
    (options) => options.map((option) => option.value).sort(),
  );
  if (JSON.stringify(selectorNames) !== JSON.stringify(catalogPlayableNames)) {
    throw new Error('O seletor de partida diverge das arquiteturas que o SQL considera utilizáveis.');
  }
  const requestedDefault = catalog.find((item) => item.architecture_name === catalogPayload.configured_default
    && Number(item.playable) === 1);
  const expectedInitialArchitecture = requestedDefault?.architecture_name ?? playableInCatalogOrder[0]?.architecture_name;
  if (await page.locator('#lab-architecture-select').inputValue() !== expectedInitialArchitecture) {
    throw new Error('A seleção inicial não respeita preferência salva/padrão configurado/ordem do catálogo.');
  }
  const expectedCandidate = catalog.find((item) => item.topology === '4 -> 32 -> 4' && Number(item.playable) === 1);
  const expectedAlternative = catalog.find((item) => item.topology === '4 -> 6 -> 4' && Number(item.playable) === 1);
  const candidateText = await page.locator('#lab-recommended-candidate').innerText();
  const alternativeText = await page.locator('#lab-recommended-alternative').innerText();
  const evidenceText = await page.locator('#lab-recommendation').innerText();
  if (expectedCandidate ? !candidateText.includes(expectedCandidate.architecture_name) : !candidateText.includes('não disponível')) {
    throw new Error('A opção jogável 4→32→4 não corresponde ao catálogo SQL.');
  }
  if (expectedAlternative ? !alternativeText.includes(expectedAlternative.architecture_name) : !alternativeText.includes('não disponível')) {
    throw new Error('A referência leve 4→6→4 não corresponde ao catálogo SQL.');
  }
  if (!evidenceText.includes('não classifica fitness')
      || !evidenceText.includes('Maior fitness individual v2 observado')
      || !evidenceText.includes('Genoma com combate demonstrado')) {
    throw new Error('O painel não separa o filtro de jogo das evidências de fitness e combate.');
  }
  await page.waitForFunction(() => document.querySelector('#lab-layer-list')?.textContent.includes('INPUT'));
  await page.waitForFunction(() => document.querySelector('#lab-weights .lab-weight-row'));
  await page.waitForFunction(() => {
    const value = document.querySelector('#lab-weight-bias')?.textContent ?? '';
    return /Bias do neurônio \d+: -?\d/.test(value);
  });
  const selectedGenomeWeights = await page.locator('#lab-weights .lab-weight-row').count();
  const selectedGenomeBias = await page.locator('#lab-weight-bias').innerText();
  const controlsText = await page.locator('#utilities .controls').innerText();
  if (controlsText.includes('WASD') || !controlsText.includes('↑ / ↓') || !controlsText.includes('Ctrl')
      || !controlsText.includes('Espaço') || !controlsText.includes('Shift')) {
    throw new Error(`O painel de controles não reflete o mapeamento validado do engine: ${controlsText}`);
  }

  const pinButton = page.locator('#lab-pin-genome');
  if (await pinButton.isEnabled()) {
    const gameGenomeId = await page.locator('#lab-genome-select').inputValue();
    await pinButton.click();
    const storedPin = await page.evaluate(() => JSON.parse(localStorage.getItem('neural-doom-lab.game-genome') || 'null'));
    if (String(storedPin?.genomeId) !== String(gameGenomeId)) {
      throw new Error('A seleção de genoma não foi persistida para a próxima sessão.');
    }
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.locator('.neural-lab-summary').click();
    await page.waitForFunction(() => document.querySelector('#lab-status')?.textContent.includes('MySQL conectado'), null, { timeout: 10000 });
    if (String(await page.locator('#lab-genome-select').inputValue()) !== String(gameGenomeId)) {
      throw new Error('O genoma fixado não foi restaurado após recarregar a interface.');
    }
  }

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
    playableArchitectures: selectorNames,
    h32PlayableOption: expectedCandidate?.architecture_name ?? null,
    lightReference: expectedAlternative?.architecture_name ?? null,
    evidenceText,
    controlsText,
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
