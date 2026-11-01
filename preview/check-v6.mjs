// v6 preview render check — runs on a real GitHub Actions runner (macOS / Windows).
// Usage: node check-v6.mjs <page-url> <out-dir>
// Writes check-report.txt and shots/*.png into <out-dir>. Exits non-zero if any
// assertion fails. This checks the preview file only; it never downloads installer
// files (only button hrefs are asserted, plus production endpoint headers in a
// separate job).
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';

const [,, pageUrl, outDir] = process.argv;
if (!pageUrl || !outDir) {
  console.error('usage: node check-v6.mjs <page-url> <out-dir>');
  process.exit(2);
}

const shotsDir = path.join(outDir, 'shots');
fs.mkdirSync(shotsDir, { recursive: true });

const lines = [];
const failures = [];
const log = (s = '') => { lines.push(s); console.log(s); };
const check = (name, ok, detail = '') => {
  log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures.push(name);
};

const browser = await chromium.launch();
const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await context.newPage();

const consoleErrors = [];
const pageErrors = [];
page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
page.on('pageerror', (e) => { pageErrors.push(String(e)); });

const buttons = () => page.$$eval('#osDownloadActions a.download-cta', (as) =>
  as.map((a) => ({ label: (a.textContent || '').trim().replace(/\s+/g, ' '), href: a.getAttribute('href') })));
const selectedCard = () => page.$eval('#appSelector [aria-checked="true"]', (el) => el.getAttribute('data-app'));
const theme = () => page.evaluate(() => document.documentElement.getAttribute('data-theme'));
const overflow = () => page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: window.innerWidth }));

log(`platform: ${process.platform}`);
log(`page: ${pageUrl}`);
log(`userAgent: ${await page.evaluate(() => navigator.userAgent)}`);
log(`detected OS (page logic): ${await page.evaluate(() => { const ua = navigator.userAgent || ''; const plat = navigator.platform || ''; if (/Mac/.test(plat) || /Macintosh/.test(ua)) return 'macos'; if (/Win/.test(plat) || /Windows/.test(ua)) return 'windows'; return 'unknown'; })}`);
log('');

await page.goto(pageUrl, { waitUntil: 'load', timeout: 30000 });
await page.waitForSelector('#osDownloadActions a.download-cta', { timeout: 15000 });
await page.waitForTimeout(1200);

// --- initial state: desktop edition selected by default -------------------
const initialCard = await selectedCard();
check('default selected edition card is codex-desktop', initialCard === 'codex-desktop', `got ${initialCard}`);
check('emblem SVG present (emblemGrad)', await page.evaluate(() => !!document.getElementById('emblemGrad')));
const initialTheme = await theme();
check('initial theme is light', initialTheme === 'light', `got ${initialTheme}`);

const initialButtons = await buttons();
log(`initial buttons: ${JSON.stringify(initialButtons)}`);
const expectedOwnHref = process.platform === 'darwin'
  ? '/api/installer/download-chatgpt-mac'
  : process.platform === 'win32'
    ? '/api/installer/download-chatgpt-win'
    : null;
if (expectedOwnHref) {
  check(`own-OS desktop button present (${expectedOwnHref})`,
    initialButtons.some((b) => b.href === expectedOwnHref),
    `buttons found: ${initialButtons.map((b) => b.href).join(', ')}`);
} else {
  check('both desktop OS buttons present (unknown platform)',
    initialButtons.some((b) => b.href === '/api/installer/download-chatgpt-win') &&
    initialButtons.some((b) => b.href === '/api/installer/download-chatgpt-mac'),
    `buttons found: ${initialButtons.map((b) => b.href).join(', ')}`);
}
check('initial buttons all carry desktop-edition labels',
  initialButtons.length > 0 && initialButtons.every((b) => b.label.includes('桌面版')),
  initialButtons.map((b) => b.label).join(' | '));

const ov1 = await overflow();
log(`horizontal overflow check: scrollWidth=${ov1.sw} innerWidth=${ov1.iw} (info only)`);

// --- screenshots, light theme ---------------------------------------------
await page.screenshot({ path: path.join(shotsDir, 'light-viewport.png') });
const mob = await context.newPage();
await mob.setViewportSize({ width: 390, height: 844 });
await mob.goto(pageUrl, { waitUntil: 'load', timeout: 30000 });
await mob.waitForTimeout(1200);
await mob.screenshot({ path: path.join(shotsDir, 'light-mobile.png') });
await mob.close();

// Scroll through the page so reveal-on-scroll sections become visible,
// then take the full-page shot.
await page.evaluate(async () => {
  await new Promise((resolve) => {
    let y = 0;
    const step = () => {
      y += 600;
      window.scrollTo(0, y);
      if (y < document.body.scrollHeight) setTimeout(step, 120);
      else resolve();
    };
    step();
  });
});
await page.waitForTimeout(600);
await page.evaluate(() => window.scrollTo(0, 0));
await page.waitForTimeout(300);
await page.screenshot({ path: path.join(shotsDir, 'light-full.png'), fullPage: true });

// --- dark theme ------------------------------------------------------------
await page.click('#themeToggle');
await page.waitForFunction(() => document.documentElement.getAttribute('data-theme') === 'dark', null, { timeout: 5000 });
check('theme toggle switches to dark', (await theme()) === 'dark');
await page.waitForTimeout(400);
await page.screenshot({ path: path.join(shotsDir, 'dark-viewport.png') });
await page.screenshot({ path: path.join(shotsDir, 'dark-full.png'), fullPage: true });

// --- switch to terminal edition, assert hrefs ------------------------------
await page.click('#themeToggle'); // back to light for the card checks
await page.waitForFunction(() => document.documentElement.getAttribute('data-theme') === 'light', null, { timeout: 5000 });

await page.click('#appSelector [data-app="codex"]');
await page.waitForFunction(() => {
  const hrefs = [...document.querySelectorAll('#osDownloadActions a.download-cta')].map((a) => a.getAttribute('href'));
  return hrefs.includes('/api/installer/download-win') && hrefs.includes('/api/installer/download-mac');
}, null, { timeout: 8000 }).catch(() => {});
const terminalButtons = await buttons();
log(`terminal buttons: ${JSON.stringify(terminalButtons)}`);
check('terminal card selected after click', (await selectedCard()) === 'codex');
check('terminal buttons use download-win / download-mac hrefs',
  terminalButtons.some((b) => b.href === '/api/installer/download-win') &&
  terminalButtons.some((b) => b.href === '/api/installer/download-mac'),
  terminalButtons.map((b) => b.href).join(', '));
check('terminal buttons carry terminal-edition labels',
  terminalButtons.length > 0 && terminalButtons.every((b) => b.label.includes('终端版')),
  terminalButtons.map((b) => b.label).join(' | '));

// --- switch back to desktop edition, assert hrefs --------------------------
await page.click('#appSelector [data-app="codex-desktop"]');
await page.waitForFunction(() => {
  const hrefs = [...document.querySelectorAll('#osDownloadActions a.download-cta')].map((a) => a.getAttribute('href'));
  return hrefs.includes('/api/installer/download-chatgpt-win') && hrefs.includes('/api/installer/download-chatgpt-mac');
}, null, { timeout: 8000 }).catch(() => {});
const desktopButtons = await buttons();
log(`desktop buttons after switching back: ${JSON.stringify(desktopButtons)}`);
check('desktop card selected after click back', (await selectedCard()) === 'codex-desktop');
check('desktop buttons use download-chatgpt-win / download-chatgpt-mac hrefs',
  desktopButtons.some((b) => b.href === '/api/installer/download-chatgpt-win') &&
  desktopButtons.some((b) => b.href === '/api/installer/download-chatgpt-mac'),
  desktopButtons.map((b) => b.href).join(', '));

// --- console / page errors (reported, page errors fail) --------------------
log('');
log(`console errors (${consoleErrors.length}):`);
consoleErrors.forEach((e) => log(`  [console] ${e}`));
log(`page errors (${pageErrors.length}):`);
pageErrors.forEach((e) => log(`  [pageerror] ${e}`));
check('no uncaught page errors', pageErrors.length === 0, `${pageErrors.length} pageerror(s)`);

await browser.close();

log('');
log(failures.length === 0 ? 'RESULT: PASS' : `RESULT: FAIL (${failures.length} failed: ${failures.join(', ')})`);
fs.writeFileSync(path.join(outDir, 'check-report.txt'), lines.join('\n') + '\n');
process.exit(failures.length === 0 ? 0 : 1);
