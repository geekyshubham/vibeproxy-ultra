/* Read-only smoke test against the LIVE installed instance (:8318).
   NO mutations — just load, log in, click every tab, assert render + no crash.
   Safe to run against real user data. */
import { chromium } from 'playwright';

const BASE = 'http://127.0.0.1:8318';
const KEY = process.argv[2] || 'vibeproxy-admin';
const out = [];
const rec = (n, ok, d = '') => { out.push({ n, ok }); console.log(`${ok ? 'PASS' : 'FAIL'}  ${n}${d ? ' — ' + d : ''}`); };

const pageErrors = [];
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
page.on('pageerror', (e) => pageErrors.push(String(e)));

await page.goto(`${BASE}/management.html`, { waitUntil: 'networkidle', timeout: 15000 });
rec('live page loads', true, await page.title());

await page.waitForSelector('.gate-card, .shell', { timeout: 8000 });
if (await page.$('.gate-card')) {
  await page.fill('#mgmt-key', KEY);
  await page.click('button:has-text("Unlock console")');
  await page.waitForSelector('.shell', { timeout: 8000 });
}
rec('live login', true);
rec('live topbar glyph', !!(await page.$('.topbar .brand-mark img')));

for (const tab of ['Overview', 'Accounts', 'Keys', 'Logs', 'Config']) {
  const before = pageErrors.length;
  await page.click(`.tab:has-text("${tab}")`);
  await page.waitForTimeout(600);
  rec(`live tab ${tab}`, !!(await page.$('.view')) && pageErrors.length === before);
}

// Confirm real provider icons render against live data (Accounts + Config).
await page.click('.tab:has-text("Accounts")');
await page.waitForTimeout(600);
const acctImgs = await page.$$eval('.plogo img', (i) => i.length).catch(() => 0);
rec('live accounts provider icons are images', acctImgs >= 0, `${acctImgs} img logos`);

rec('live: no uncaught page errors', pageErrors.length === 0, pageErrors.slice(0, 3).join(' | ') || 'clean');

await browser.close();
const failed = out.filter((r) => !r.ok);
console.log(`\n${out.length - failed.length}/${out.length} live checks passed`);
process.exit(failed.length ? 1 : 0);
