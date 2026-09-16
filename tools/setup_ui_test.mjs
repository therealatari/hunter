// Optional developer browser test. Players need neither Node nor WebDriver.
// PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs BROWSER_PATH=/path/to/chromium node tools/setup_ui_test.mjs
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

const assets = new URL('../scripts/eohunter/setup/assets/', import.meta.url);
const requests = [];
const legacy = {schema_version: 1, settings: {fried: 95, hunting_commands: 'incant 719(x2), custom verb', unknown_extension: {keep: ['verbatim', false]}, hunting_right_hand: 'keep'}};
const fields = [
  {key: 'fried', label: 'Return when my mind is full', help: 'Mind threshold, at or above this percentage.', aliases: ['fried'], type: 'integer', default: 100, page: 'monitoring'},
  {key: 'hunting_right_hand', label: 'Right hand', help: 'Equipment hand intent.', type: 'string', default: 'keep', page: 'equipment'},
  {key: 'hunting_commands', label: 'Usual combat sequence', help: 'Original routine text.', type: 'string', default: '', page: 'combat'},
  {key: 'combat_buffs', label: 'Required combat buffs', help: 'Native missing buff policy.', type: 'structured', default: {}, page: 'buffs', editor: 'raw'},
  ...['hunting_room_id', 'hunting_boundaries', 'targets', 'invalid_targets', 'always_flee_from'].map((key) => ({key, label: key, type: 'string', default: '', page: 'area'}))
];
let stored, saveDelay = 0, areaDelay = 0;
const server = createServer(async (req, res) => {
  if (req.url === '/api') {
    assert.equal(req.headers['x-setup-token'], 'test-token');
    let body = ''; for await (const chunk of req) body += chunk;
    const request = JSON.parse(body); requests.push(request);
    let result;
    if (request.action === 'bootstrap') result = {context: {character: 'Test character', game: 'Test'}, fields, profiles: ['slow profile', 'fast profile'], legacy_profiles: ['legacy'], defaults: ['usual'], plans: ['usual combat'], capabilities: {}};
    else if (request.action === 'read') {
      if (request.name === 'slow profile') await new Promise((resolve) => setTimeout(resolve, 500));
      result = {data: request.kind === 'defaults' ? {schema_version: 1, settings: {hunting_right_hand: 'ready:weapon'}} : request.name.endsWith('profile') ? {schema_version: 1, settings: {fried: request.name === 'slow profile' ? 11 : 22}} : legacy, revision: 'old-revision'};
    }
    else if (request.action === 'validate') result = {errors: [], warnings: ['Hazards not checked for unknown equipment.'], missing: [{key: 'resting_room_id', message: 'Select a rest room.'}], effective: {...(request.data.defaults ? {hunting_right_hand: 'ready:weapon'} : {}), ...request.data.settings}, provenance: request.data.defaults ? {hunting_right_hand: 'usual character defaults'} : {}};
    else if (request.action === 'save') { stored = request; if (saveDelay) await new Promise((resolve) => setTimeout(resolve, saveDelay)); result = {revision: 'saved-revision'}; }
    else if (request.action === 'profile_map') result = {rooms: [], sheets: [], markers: {}, editable: true};
    else if (request.action === 'areas') result = [
      {name: 'Example habitat', maps: [{id: 'example.png', name: 'Example map'}], zones: [{id: 'core', label: 'Core area'}]},
      {name: 'Example alias', maps: [{id: 'example.png', name: 'Example map'}], zones: [{id: 'core', label: 'Core area'}]},
      {name: 'Disconnected habitat', maps: [{id: 'example.png', name: 'Example map'}]}
    ];
    else if (request.action === 'area') {
      if (areaDelay) await new Promise((resolve) => setTimeout(resolve, areaDelay));
      const roomIds = request.room_ids || [1, 2];
      result = {selected_creature_names: ['veteran reiver', 'burly reiver'], room_ids: roomIds, boundary_ids: [3],
        editable_room_ids: [1, 2, 3, 4], context_rooms: [1, 2, 3, 4].map((id) => ({id, title: `Fixture room ${id}`})),
        added_room_ids: request.added_room_ids || [], zone_metadata: {status: 'draft', notes: ['Special cave excluded; access needs review.'], excluded_uids: [104]},
        components: request.area.startsWith('Disconnected') ? [[1], [2]] : [roomIds], coverage: {complete: true}, creatures: [{name: 'veteran reiver', level: 25}, {name: 'burly reiver', level: 20}], verification: 'Data-derived; not field-checked', diagnostics: []};
    }
    else throw new Error(`Unexpected action: ${request.action}`);
    res.writeHead(200, {'Content-Type': 'application/json'}); res.end(JSON.stringify(result)); return;
  }
  const filename = req.url === '/' ? 'index.html' : req.url.slice(1);
  if (!['index.html', 'routine-editor.js', 'injury-editor.js', 'settings-editor.js', 'app.js', 'style.css'].includes(filename)) {res.writeHead(404); res.end(); return;}
  res.writeHead(200, {'Content-Type': filename.endsWith('.js') ? 'application/javascript' : filename.endsWith('.css') ? 'text/css' : 'text/html'});
  res.end(await readFile(new URL(filename, assets)));
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port;
let browser, page;
const browserErrors = [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(predicate, description) {
  for (let count = 0; count < 100; count++) { if (await predicate()) return; await sleep(100); }
  throw new Error(`Timed out: ${description}\n${page ? await page.locator('body').innerText() : ''}`);
}
const execute = (script, ...args) => page.evaluate(({script, args}) => new Function(script).apply(null, args), {script, args});
const click = (text) => execute("const b=Array.from(document.querySelectorAll('button')).find(b=>b.textContent.trim()===arguments[0]); if(!b)throw new Error('Missing button '+arguments[0]); if(b.disabled)throw new Error('Disabled button '+arguments[0]); b.click();", text);
const fill = (selector, value, event = 'change') => execute("const n=document.querySelector(arguments[0]); if(!n)throw new Error('Missing input '+arguments[0]); n.value=arguments[1]; n.dispatchEvent(new Event(arguments[2],{bubbles:true}));", selector, value, event);
const text = () => execute('return document.body.textContent');
try {
  const {chromium} = await import(process.env.PLAYWRIGHT_MODULE ? pathToFileURL(process.env.PLAYWRIGHT_MODULE).href : 'playwright');
  browser = await chromium.launch({headless: true, ...(process.env.BROWSER_PATH ? {executablePath: process.env.BROWSER_PATH} : {})});
  page = await browser.newPage();
  page.on('pageerror', (error) => browserErrors.push(error.message));
  await page.goto(`http://127.0.0.1:${port}/#token=test-token`);
  await waitFor(async () => (await text()).includes('Connected.'), 'bootstrap');
  assert.equal(await execute('return location.hash'), '');
  await click('Open as copy');
  await waitFor(async () => (await text()).includes('Opened a compatibility source.'), 'legacy import');
  await fill('#search', 'fried', 'input');
  await execute("document.querySelector('.search-result').click()");
  assert.equal(await execute('return document.activeElement.id'), 'field-fried');
  await fill('#field-fried', '87');
  await click('Review & save');
  await click('Check effective configuration');
  await waitFor(async () => (await text()).includes('Select a rest room.'), 'missing information shown');
  await fill('#save-name', 'native-copy', 'input');
  await click('Save to EOHunter');
  await waitFor(async () => Boolean(stored), 'save');
  assert.equal(stored.kind, 'profiles');
  assert.equal(stored.revision, null);
  assert.equal(stored.data.settings.fried, '87');
  assert.deepEqual(stored.data.settings.unknown_extension, legacy.settings.unknown_extension);
  assert.equal(stored.data.settings.hunting_commands, legacy.settings.hunting_commands);
  await waitFor(async () => (await text()).includes('Saved “native-copy”'), 'saved status');
  await click('Raw configuration');
  await fill('#raw-json', '{invalid', 'input');
  await click('Equipment');
  await click('Raw configuration');
  assert.equal(await execute("return document.querySelector('#raw-json').value"), '{invalid');
  await click('Review & save');
  const savesBeforeInvalid = requests.filter((r) => r.action === 'save').length;
  await click('Save to EOHunter');
  assert.equal(requests.filter((r) => r.action === 'save').length, savesBeforeInvalid);
  await click('Raw configuration');
  await fill('#raw-json', JSON.stringify(stored.data), 'input');
  await click('Guided setup');
  await click('Advanced editor');
  await click('Area & creatures');
  await click('Load / refresh areas');
  await waitFor(async () => (await text()).includes('3 habitats available'), 'area catalog');
  await fill('select[aria-label="Map or region"]', 'example.png');
  assert.equal(await execute('return document.querySelectorAll(\'select[aria-label="Hunting area"] option[data-zone="core"]\').length'), 1, 'Habitat aliases must not duplicate the same area');
  await fill('select[aria-label="Hunting area"]', 'Example habitat::core');
  await click('Preview selected area');
  await waitFor(async () => (await text()).includes('Known creatures'), 'area preview');
  assert((await text()).includes('Suggested area — editable, not field-tested'));
  assert((await text()).includes('Special cave excluded; access needs review.'));
  assert((await text()).includes('2 proposed hunting rooms'), 'Selecting an area populates geography before targets');
  await click('Raw configuration');
  assert.equal(JSON.parse(await execute("return document.querySelector('#raw-json').value")).area, undefined, 'Browsing does not apply the area');
  await click('Area & creatures');
  await fill('select[aria-label="Response to veteran reiver"]', 'hunt');
  await fill('select[aria-label="Response to burly reiver"]', 'ignore');
  assert((await text()).includes('2 proposed hunting rooms'), 'Ignoring a creature retains transit and geographic rooms');
  assert.equal(await execute('return document.querySelector(\'input[aria-label="Include room 4"]\').checked'), false, 'Excluded special rooms are not preselected');
  await execute('document.querySelector(\'input[aria-label="Include room 4"]\').click()');
  await click('Recalculate boundaries for selected rooms');
  await waitFor(async () => (await text()).includes('3 proposed hunting rooms'), 'explicit manual addition');
  assert.deepEqual(requests.at(-1).added_room_ids, [4]);
  await fill('select[aria-label="Response to veteran reiver"]', 'ignore');
  assert((await text()).includes('3 proposed hunting rooms'), 'Target changes preserve manually added rooms');
  await fill('select[aria-label="Response to veteran reiver"]', 'hunt');
  await click('Reset to suggested area rooms');
  await waitFor(async () => (await text()).includes('2 proposed hunting rooms'), 'footprint preview');
  await fill('select[aria-label="Choose a mapped starting room"]', '1');
  await click('Apply this hunting footprint');
  await click('Equipment');
  await fill('#field-hunting_right_hand', 'ready:weapon');
  await click('Area & creatures');
  await click('Raw configuration');
  let draft = JSON.parse(await execute("return document.querySelector('#raw-json').value"));
  assert.equal(draft.area, 'Example habitat');
  assert.equal(draft.settings.targets, 'veteran reiver(a)');
  assert.equal(draft.settings.hunting_boundaries, '3');
  assert.equal(draft.settings.hunting_right_hand, 'ready:weapon');
  assert.equal(draft.settings.hunting_room_id, '1', 'Use the explicitly selected entrance');
  assert.equal(draft.settings.resting_room_id, undefined, 'Never invent a safe rest room');
  await click('Area & creatures');
  await fill('select[aria-label="Hunting area"]', 'Disconnected habitat');
  await click('Preview selected area');
  await waitFor(async () => (await text()).includes('Known creatures'), 'second area preview');
  await click('Reset to suggested area rooms');
  await waitFor(async () => (await text()).includes('This footprint is disconnected'), 'disconnected preview');
  assert.equal(await execute("return Array.from(document.querySelectorAll('button')).find(b=>b.textContent==='Apply this hunting footprint').disabled"), true);
  areaDelay = 350;
  await click('Reset to suggested area rooms');
  await fill('select[aria-label="Map or region"]', '');
  await sleep(500);
  assert.equal(await execute("return document.querySelector('#footprint-editor')"), null, 'Late area requests cannot restore a map that was deselected');
  areaDelay = 0;
  await click('Buffs');
  await fill('#field-combat_buffs', '{bad');
  await click('Equipment'); await click('Buffs');
  assert.equal(await execute("return document.querySelector('#field-combat_buffs').value"), '{bad');
  await fill('#field-combat_buffs', '{}');
  // A linked value remains inherited after an unrelated field changes.
  await click('Raw configuration');
  draft = JSON.parse(await execute("return document.querySelector('#raw-json').value"));
  delete draft.settings.hunting_right_hand;
  draft.defaults = 'usual';
  await fill('#raw-json', JSON.stringify(draft), 'input');
  await click('Review & save'); await click('Check effective configuration');
  await waitFor(async () => (await text()).includes('Configuration check complete.'), 'inherited validation');
  await click('Monitoring & limits'); await fill('#field-fried', '76');
  await click('Equipment');
  assert.equal(await execute("return document.querySelector('#field-hunting_right_hand').value"), 'ready:weapon');
  assert((await text()).includes('usual character defaults'));
  // Switching documents during an in-flight save cannot adopt its revision.
  saveDelay = 500;
  await click('Review & save'); await click('Save to EOHunter');
  await waitFor(() => requests.filter((request) => request.action === 'save').length === 2, 'delayed save issued');
  await click('Manage profiles'); await execute("document.querySelector('details.card').open=true"); await click('New character setup');
  assert((await text()).includes('Wait for this save to finish'));
  assert.equal(await execute("return document.querySelector('#draft-name').textContent"), 'native-copy');
  await waitFor(async () => (await text()).includes('Saved “native-copy”'), 'delayed save complete');
  // Out-of-order load responses must not replace the most recently chosen document.
  await execute('window.confirm=()=>true');
  const openNamed = (name) => execute("const row=Array.from(document.querySelectorAll('.list-item')).find(r=>r.querySelector('strong')?.textContent===arguments[0]); row.querySelector('button').click();", name);
  await click('Manage profiles');
  await openNamed('slow profile'); await openNamed('fast profile');
  await waitFor(async () => (await text()).includes('Opened fast profile.'), 'newer fast load');
  await sleep(650);
  assert.equal(await execute("return document.querySelector('#draft-name').textContent"), 'fast profile');
  await click('Raw configuration');
  assert.equal(JSON.parse(await execute("return document.querySelector('#raw-json').value")).settings.fried, 22);
  assert(requests.every((request) => ['bootstrap', 'read', 'validate', 'save', 'areas', 'area', 'profile_map'].includes(request.action)));
  assert.deepEqual(browserErrors, []);
  console.log('PASS: browser preservation, search, missing-data review, invalid JSON retention, shared wizard draft, creature policy, geometry guard, inherited values, save/load races, and token transport.');
} finally {
  if (browser) await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
