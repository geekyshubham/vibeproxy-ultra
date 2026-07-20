/* ============================================================================
   run-ui-tests.mjs — real frontend UI tests for the VibeProxy management panel.

   Drives the ACTUAL served page in headless Chromium (Playwright):
     - loads http://127.0.0.1:<port>/management.html from an isolated backend
     - captures ALL console errors / page errors (catches crashes like o.filter)
     - logs in with the management key
     - clicks through every tab, asserts content renders + no crash
     - exercises interactive controls and asserts visible feedback (toasts)
     - screenshots each tab to uitest/shots/

   Usage: node run-ui-tests.mjs <port> <key>
   The caller is responsible for starting/stopping the isolated backend.
   ============================================================================ */
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const PORT = process.argv[2] || '8450';
const KEY = process.argv[3] || 'vibeproxy-admin';
const BASE = `http://127.0.0.1:${PORT}`;
const HERE = dirname(fileURLToPath(import.meta.url));
const SHOTS = join(HERE, 'shots');
mkdirSync(SHOTS, { recursive: true });

const results = [];
function record(name, ok, detail = '') {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`);
}

const consoleErrors = [];
const pageErrors = [];

async function main() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });

  page.on('console', (msg) => {
    if (msg.type() === 'error') consoleErrors.push(msg.text());
  });
  page.on('pageerror', (err) => pageErrors.push(String(err)));

  // Record every non-2xx response with its method+URL so we can tell an EXPECTED
  // 400 (e.g. GET /logs when file-logging is off) from a real contract bug.
  const httpFailures = [];
  page.on('response', (resp) => {
    const s = resp.status();
    if (s >= 400) httpFailures.push(`${resp.request().method()} ${new URL(resp.url()).pathname} → ${s}`);
  });

  // --- Load ---
  await page.goto(`${BASE}/management.html`, { waitUntil: 'networkidle', timeout: 15000 });
  record('page loads', true, await page.title());

  // --- Favicon present ---
  const favicon = await page.getAttribute('link[rel="icon"]', 'href').catch(() => null);
  record('favicon set (glyph)', !!favicon && favicon.startsWith('data:image/png'), favicon ? 'data URI' : 'missing');

  // --- Login gate ---
  await page.waitForSelector('.gate-card, .shell', { timeout: 8000 });
  const onGate = await page.$('.gate-card');
  if (onGate) {
    await page.fill('#mgmt-key', KEY);
    await page.click('button:has-text("Unlock console")');
    await page.waitForSelector('.shell', { timeout: 8000 });
    record('login with key', true, 'reached console');
  } else {
    record('login with key', true, 'already authenticated');
  }

  // --- Brand mark in topbar ---
  const brand = await page.$('.topbar .brand-mark img');
  record('topbar brand glyph', !!brand);

  // --- Tabs: click each, assert a view renders, screenshot ---
  const tabs = ['Overview', 'Accounts', 'Keys', 'Logs', 'Config'];
  for (const tab of tabs) {
    const before = consoleErrors.length + pageErrors.length;
    await page.click(`.tab:has-text("${tab}")`);
    await page.waitForTimeout(700);
    const view = await page.$('.view');
    const after = consoleErrors.length + pageErrors.length;
    const noCrash = after === before;
    record(`tab: ${tab} renders`, !!view && noCrash, noCrash ? '' : 'console/page error during render');
    await page.screenshot({ path: join(SHOTS, `tab-${tab.toLowerCase()}.png`) });
  }

  // --- Provider icons are real images (consistency with Swift app) ---
  await page.click('.tab:has-text("Config")');
  await page.waitForTimeout(600);
  const provImgs = await page.$$eval('.plogo img', (imgs) => imgs.length);
  record('provider icons render as images', provImgs > 0, `${provImgs} <img> logos`);

  // --- Interactive: toggle a Config switch, assert toast feedback ---
  const sw = await page.$('.cfg-row .sw');
  if (sw) {
    await sw.click();
    const toast = await page.waitForSelector('.toast', { timeout: 4000 }).catch(() => null);
    record('config toggle → toast feedback', !!toast, toast ? await toast.textContent() : 'no toast');
    // toggle back
    await page.waitForTimeout(500);
    await sw.click().catch(() => {});
    await page.waitForTimeout(500);
  } else {
    record('config toggle → toast feedback', false, 'no switch found');
  }

  // --- Interactive: Keys tab, add a proxy key, assert it appears + toast ---
  await page.click('.tab:has-text("Keys")');
  await page.waitForTimeout(600);
  const keyInput = await page.$('input[placeholder="New access key…"]');
  if (keyInput) {
    await keyInput.fill('ui-test-key');
    await page.click('button:has-text("Add")');
    const toast = await page.waitForSelector('.toast', { timeout: 4000 }).catch(() => null);
    await page.waitForTimeout(600);
    const rows = await page.$$eval('.lrow', (els) => els.length);
    record('keys: add key → toast + row', !!toast && rows > 0, `${rows} rows`);
    // clean up: delete it
    const del = await page.$('.lrow .btn-danger');
    if (del) {
      await del.click();
      await page.waitForTimeout(500);
    }
  } else {
    record('keys: add key → toast + row', false, 'no key input');
  }

  // --- Accounts tab refresh gives feedback ---
  await page.click('.tab:has-text("Accounts")');
  await page.waitForTimeout(500);
  const refreshBtn = await page.$('button:has-text("Refresh")');
  if (refreshBtn) {
    await refreshBtn.click();
    const toast = await page.waitForSelector('.toast', { timeout: 4000 }).catch(() => null);
    record('accounts: refresh → toast feedback', !!toast);
  } else {
    record('accounts: refresh → toast feedback', false, 'no refresh button');
  }

  // --- Logs tab: enable logging via the empty-state button, assert feedback ---
  await page.click('.tab:has-text("Logs")');
  await page.waitForTimeout(500);
  const enableBtn = await page.$('button:has-text("Enable logging")');
  if (enableBtn) {
    await enableBtn.click();
    const toast = await page.waitForSelector('.toast', { timeout: 4000 }).catch(() => null);
    record('logs: enable logging → toast', !!toast);
  } else {
    // logging may already be on; assert the log table or empty state shows without crash
    const shown = await page.$('.tbl, .empty');
    record('logs: renders (table/empty)', !!shown, 'logging already enabled');
  }

  // --- HTTP failures: distinguish EXPECTED from real ---
  // GET /logs legitimately returns 400 when file-logging is off — the UI renders
  // an empty state for it. Any OTHER >=400 is a real contract/UX bug.
  const unexpected = httpFailures.filter((f) => !/^GET \/v0\/management\/logs → 400$/.test(f));
  record(
    'no UNEXPECTED http failures',
    unexpected.length === 0,
    unexpected.length ? unexpected.slice(0, 5).join(' | ') : `clean (${httpFailures.length} expected)`,
  );

  // --- Crash gate: uncaught page errors are the real regression signal ---
  record(
    'no uncaught page errors (o.filter regression)',
    pageErrors.length === 0,
    pageErrors.slice(0, 3).join(' | ') || 'clean',
  );

  // Informational: console errors (browser logs generic text for handled 400s too).
  const realConsole = consoleErrors.filter((e) => !/Failed to load resource/.test(e));
  record(
    'no unhandled console errors',
    realConsole.length === 0,
    realConsole.slice(0, 3).join(' | ') || `clean (${consoleErrors.length} resource-load logs, all handled)`,
  );

  await browser.close();

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log('FAILURES:');
    failed.forEach((f) => console.log(`  - ${f.name}: ${f.detail}`));
    process.exit(1);
  }
  process.exit(0);
}

main().catch((err) => {
  console.error('UI test harness error:', err);
  process.exit(2);
});
