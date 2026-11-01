import { existsSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { chromium } from 'playwright-core';

const baseUrl = process.env.DOOM_FRONTEND_URL ?? 'http://127.0.0.1:5173/';
const outputDirectory = process.env.DOOM_LAB_FPS_RESULT_DIR
  ?? path.join(os.tmpdir(), 'neural-doom-lab-fps-check');
const edgePath = process.env.DOOM_EDGE_PATH ?? [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
].find((candidate) => existsSync(candidate));

if (!edgePath) throw new Error('Microsoft Edge não foi encontrado; configure DOOM_EDGE_PATH.');
await mkdir(outputDirectory, { recursive: true });

const browser = await chromium.launch({
  executablePath: edgePath,
  headless: true,
  args: ['--disable-background-timer-throttling', '--disable-renderer-backgrounding'],
});

try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (error) => errors.push(String(error)));

  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await page.locator('#ai-mode').selectOption('original');
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
  await page.waitForTimeout(300);
  await page.keyboard.press('ArrowUp');
  await page.waitForTimeout(150);
  await page.keyboard.press('ArrowUp');
  await page.waitForTimeout(150);
  await page.keyboard.press('Enter');
  await page.waitForTimeout(1000);

  async function sampleFrames() {
    return page.evaluate(() => new Promise((resolve) => {
      let frames = 0;
      let startedAt = null;
      const sample = (timestamp) => {
        startedAt ??= timestamp;
        frames += 1;
        if (timestamp - startedAt >= 4000) {
          const duration = timestamp - startedAt;
          resolve({
            duration_ms: Number(duration.toFixed(1)),
            frames,
            browser_raf_fps: Number((frames * 1000 / duration).toFixed(2)),
          });
        } else {
          requestAnimationFrame(sample);
        }
      };
      requestAnimationFrame(sample);
    }));
  }

  await page.keyboard.down('Shift');
  await page.keyboard.down('ArrowRight');
  const panelClosed = await sampleFrames();
  await page.keyboard.up('ArrowRight');
  await page.keyboard.up('Shift');

  await page.locator('.neural-lab-summary').click();
  await page.waitForFunction(
    () => document.querySelector('#lab-status')?.textContent.includes('MySQL conectado'),
    null,
    { timeout: 10000 },
  );
  await page.locator('#doom-canvas').focus();
  await page.keyboard.down('Shift');
  await page.keyboard.down('ArrowRight');
  const panelOpen = await sampleFrames();
  await page.keyboard.up('ArrowRight');
  await page.keyboard.up('Shift');

  const canvasScreenshot = path.join(outputDirectory, 'freedoom-canvas.png');
  const labScreenshot = path.join(outputDirectory, 'freedoom-lab-open.png');
  await page.locator('#doom-canvas').screenshot({ path: canvasScreenshot });
  await page.screenshot({ path: labScreenshot, fullPage: true });
  if (errors.length) throw new Error(`Erros do browser: ${errors.join(' | ')}`);

  const report = {
    result: 'PASS',
    environment: 'Freedoom 2 E1M1, Edge headless, ORIGINAL_AI; browser requestAnimationFrame cadence is a rendering proxy, not an engine-specific FPS counter; no MySQL session or fitness evaluation was created',
    panel_closed: panelClosed,
    panel_open: panelOpen,
    percentage_change: panelClosed.browser_raf_fps > 0
      ? Number(((panelOpen.browser_raf_fps - panelClosed.browser_raf_fps) / panelClosed.browser_raf_fps * 100).toFixed(2))
      : null,
    backend_status_when_open: await page.locator('#lab-status').innerText(),
    canvas_screenshot: canvasScreenshot,
    lab_screenshot: labScreenshot,
    browser_errors: errors,
  };
  if (panelClosed.frames === 0 || panelOpen.frames === 0) {
    throw new Error('Nenhum callback RAF foi observado; a comparação de cadência não é válida.');
  }
  await writeFile(path.join(outputDirectory, 'report.json'), `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
} finally {
  await browser.close();
}
