import { chromium } from 'playwright-core';
import path from 'node:path';
import fs from 'node:fs';

const HOME = process.env.HOME;
const EXE = path.join(HOME, 'Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell');
const root = path.dirname(new URL(import.meta.url).pathname);
const outDir = path.join(root, 'stills');
fs.mkdirSync(outDir, { recursive: true });

const times = (process.argv[2] || '2,9,15,20,25,31,38,46,49').split(',').map(Number);
const scale = Number(process.argv[3] || 1);

const browser = await chromium.launch({ executablePath: EXE, args: ['--force-color-profile=srgb', '--font-render-hinting=none'] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: scale });
const t0 = Date.now();
for (const t of times) {
  await page.goto('file://' + path.join(root, 'film.html') + '?t=' + t);
  await page.waitForTimeout(250);
  await page.screenshot({ path: path.join(outDir, `t${t}.png`) });
  console.log('frame', t, Date.now() - t0, 'ms');
}
await browser.close();
