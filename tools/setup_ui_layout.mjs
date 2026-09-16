// Offline browser layout regression. Uses local assets and no character data.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';

const {chromium} = createRequire(import.meta.url)(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assets = new URL('../scripts/eohunter/setup/assets/', import.meta.url);
const server = createServer(async (req, res) => {
  if (req.url === '/api') {
    for await (const _chunk of req) { /* Consume fixture request. */ }
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({context: {character: 'Layout fixture', game: 'OFFLINE'}, fields: [
      {key: 'fried', label: 'Return when my mind is full', help: 'Mind threshold.', aliases: ['fried'], type: 'integer', default: 100, page: 'monitoring'}],
      profiles: [], legacy_profiles: [], defaults: [], plans: [], capabilities: {}}));
    return;
  }
  const filename = req.url === '/' ? 'index.html' : req.url.slice(1);
  if (!['index.html', 'routine-editor.js', 'injury-editor.js', 'app.js', 'style.css'].includes(filename)) {res.writeHead(404); res.end(); return;}
  res.writeHead(200, {'Content-Type': filename.endsWith('.js') ? 'application/javascript' : filename.endsWith('.css') ? 'text/css' : 'text/html'});
  res.end(await readFile(new URL(filename, assets)));
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
let browser;
try {
  browser = await chromium.launch({headless: true, ...(process.env.BROWSER_PATH ? {executablePath: process.env.BROWSER_PATH} : {})});
  const page = await browser.newPage({viewport: {width: 1280, height: 800}});
  await page.goto(`http://127.0.0.1:${server.address().port}/#token=fixture`);
  await page.waitForFunction(() => document.querySelector('#status').textContent.startsWith('Connected.'));
  const rects = () => page.evaluate(() => Object.fromEntries(['.topbar', '.draftbar', '#sidebar'].map((selector) => {
    const rect = document.querySelector(selector).getBoundingClientRect();
    return [selector, {x: rect.x, y: rect.y, width: rect.width}];
  })));
  const before = await rects();
  for (const label of ['Equipment', 'Raw configuration', 'Manage profiles', 'Review & save']) {
    await page.locator('#navigation').getByRole('button', {name: label, exact: true}).click();
    assert.deepEqual(await rects(), before, `Navigation moved the shell after selecting ${label}`);
  }
  console.log('PASS fixed header/sidebar positions across navigation');

  await page.locator('#sidebar').evaluate((node) => { node.scrollTop = node.scrollHeight; });
  const menuScroll = await page.locator('#sidebar').evaluate((node) => node.scrollTop);
  await page.locator('#navigation').getByRole('button', {name: 'Raw configuration', exact: true}).click();
  assert.equal(await page.locator('#sidebar').evaluate((node) => node.scrollTop), menuScroll, 'Navigation reset its own scroll position');
  await page.locator('#content-pane').evaluate((node) => { node.scrollTop = node.scrollHeight; });
  assert.deepEqual(await rects(), before, 'Scrolling the form moved the shell');
  await page.locator('#navigation').getByRole('button', {name: 'Manage profiles', exact: true}).click();
  assert.equal(await page.locator('#content-pane').evaluate((node) => node.scrollTop), 0, 'A new page should start at its top');
  console.log('PASS independent menu/form scrolling');

  await page.locator('#search').fill('fried');
  await page.locator('#search-results').getByRole('button').click();
  assert.equal(await page.evaluate(() => document.activeElement.id), 'field-fried');
  assert.deepEqual(await rects(), before, 'Search focus moved the shell');
  await page.locator('#search').fill('');
  console.log('PASS search focus without moving the shell');

  await page.setViewportSize({width: 390, height: 700});
  const mobileBefore = await rects();
  for (const label of ['Raw configuration', 'Manage profiles', 'Equipment']) {
    await page.getByRole('button', {name: 'Toggle navigation'}).click();
    await page.locator('#navigation').getByRole('button', {name: label, exact: true}).click();
    const mobileAfter = await rects();
    assert.deepEqual(mobileAfter['.topbar'], mobileBefore['.topbar']);
    assert.deepEqual(mobileAfter['.draftbar'], mobileBefore['.draftbar']);
    assert.equal(await page.getByRole('button', {name: 'Toggle navigation'}).getAttribute('aria-expanded'), 'false');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  }
  console.log('PASS mobile overlay navigation without shifting the form');
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
}
