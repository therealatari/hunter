#!/usr/bin/env node
// Offline acceptance only: owns a temporary-data Ruby fixture and browser.
// RUBY=/path/to/ruby PLAYWRIGHT_MODULE=/path/to/playwright BROWSER_PATH=/path/to/chrome node tools/setup_ui_acceptance.mjs
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';

const {chromium} = createRequire(import.meta.url)(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../', import.meta.url));
const fixture = spawn(process.env.RUBY || 'ruby', ['tools/setup_fixture.rb'], {
  cwd: root, stdio: ['ignore', 'pipe', 'pipe']
});
let fixtureErrors = '';
fixture.stderr.on('data', (chunk) => { fixtureErrors += chunk; });
const exited = new Promise((resolve) => fixture.once('exit', resolve));
let browser;
const results = [];

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return {promise, resolve};
}

async function within(promise, message) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), 10000);
    })]);
  } finally { clearTimeout(timer); }
}

async function fixtureUrl() {
  return new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error(`Fixture did not start: ${fixtureErrors}`)), 15000);
    fixture.once('error', (error) => { clearTimeout(timer); reject(error); });
    fixture.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`Fixture exited (${code}): ${fixtureErrors}`));
    });
    fixture.stdout.on('data', (chunk) => {
      output += chunk;
      const match = output.match(/http:\/\/127\.0\.0\.1:\d+\/#token=[a-f0-9]+/);
      if (match) { clearTimeout(timer); resolve(match[0]); }
    });
  });
}

async function nav(page, label) {
  if (await page.getByRole('button', {name: 'Advanced editor', exact: true}).isVisible()) await page.getByRole('button', {name: 'Advanced editor', exact: true}).click();
  await page.locator('#navigation').getByRole('button', {name: label, exact: true}).click();
  await page.locator('#main').getByRole('heading', {name: label, exact: true}).waitFor();
}

async function editNamed(page, name) {
  await nav(page, 'Manage profiles');
  await page.locator('.list-item').filter({has: page.getByText(name, {exact: true})})
    .getByRole('button', {name: 'Edit', exact: true}).click();
  await page.waitForFunction((name) => document.getElementById('status').textContent === `Opened ${name}.`, name);
}

async function valueIs(page, selector, value) {
  await page.waitForFunction(({selector, value}) => document.querySelector(selector)?.value === value, {selector, value});
}

async function rawDraft(page) {
  await nav(page, 'Raw configuration');
  return JSON.parse(await page.locator('#raw-json').inputValue());
}

async function roomAction(page, owner, id, label) {
  await page.locator(`${owner} [data-room-id="${id}"] .room-overlay`).click({button: 'right'});
  await page.getByRole('menu', {name: `Actions for room ${id}`, exact: true}).getByRole('menuitemcheckbox', {name: label, exact: true}).click();
}

async function saveDraft(page) {
  await nav(page, 'Review & save');
  const saved = page.waitForResponse((response) => response.url().endsWith('/api') &&
    response.request().postDataJSON()?.action === 'save');
  await page.getByRole('button', {name: 'Save to EOHunter', exact: true}).click();
  const response = await saved;
  assert.equal(response.status(), 200, await response.text());
  await page.waitForFunction(() => document.getElementById('status').textContent.startsWith('Saved'));
}

// Delay an actual backend response, not a fixed sleep or a replacement model.
async function delayResponse(page, matches) {
  const captured = deferred(), release = deferred();
  let held = false;
  await page.route('**/api', async (route) => {
    if (!held && matches(route.request().postDataJSON())) {
      held = true;
      const response = await route.fetch();
      captured.resolve();
      await release.promise;
      await route.fulfill({response});
    } else await route.continue();
  });
  return {captured: captured.promise, release: release.resolve};
}

try {
  const url = await fixtureUrl();
  const endpoint = new URL(url);
  const token = new URLSearchParams(endpoint.hash.slice(1)).get('token');
  browser = await chromium.launch({headless: true, ...(process.env.BROWSER_PATH ? {executablePath: process.env.BROWSER_PATH} : {})});
  const context = await browser.newContext({viewport: {width: 1400, height: 1000}});
  context.setDefaultTimeout(10000);
  const api = async (action, args = {}) => {
    const response = await context.request.post(`${endpoint.origin}/api`, {
      headers: {Origin: endpoint.origin, 'X-Setup-Token': token}, data: {action, ...args}
    });
    assert.equal(response.status(), 200, await response.text());
    return response.json();
  };
  // Distinguish inherited values from engine defaults; all writes stay in the fixture.
  const defaults = await api('read', {kind: 'defaults', name: 'Usual setup'});
  defaults.data.settings.fried = 87;
  await api('save', {kind: 'defaults', name: 'Usual setup', data: defaults.data, revision: defaults.revision});
  const original = await api('read', {kind: 'profiles', name: 'Fixture hunt'});
  await api('save', {kind: 'profiles', name: 'Other hunt', data: original.data, revision: null});
  await api('save', {kind: 'profiles', name: 'Role toggle fixture', revision: null, data: {
    schema_version: 1, settings: {...original.data.settings, field_rest_room_id: 'u102', resting_room_id: 'u102'}
  }});
  await api('save', {kind: 'plans', name: 'No fire', revision: null, data: {commands: 'incant 711'}});
  await api('save', {kind: 'profiles', name: 'Sequence choices', revision: null, data: {
    schema_version: 1, settings: {...original.data.settings, targets: 'fixture rat, fixture troll', hunting_commands: 'attack', hunting_commands_c: 'keep untouched'}
  }});

  async function check(name, run) {
    if (process.env.SETUP_TEST_FILTER && !name.includes(process.env.SETUP_TEST_FILTER)) return;
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('dialog', (dialog) => dialog.accept());
    try {
      await page.goto(url);
      await page.waitForFunction(() => document.getElementById('status').textContent.startsWith('Connected.'));
      await run(page);
      assert.deepEqual(errors, [], 'Unexpected browser exceptions');
      results.push({name, passed: true});
      console.log(`PASS ${name}`);
    } catch (error) {
      results.push({name, passed: false});
      console.error(`FAIL ${name}: ${error.message}\nEditor status: ${await page.locator('#status').textContent().catch(() => '(unavailable)')}`);
    } finally { await page.close({runBeforeUnload: false}); }
  }

  await check('edit, save and reopen preserve unknown false values; fried search works', async (page) => {
    await editNamed(page, 'Fixture hunt');
    await page.locator('#search').fill('fried');
    await page.locator('#search-results').getByRole('button').filter({hasText: 'Return when my mind is full'}).click();
    await page.locator('#field-fried').fill('91');
    await page.locator('#field-fried').press('Tab');
    await saveDraft(page);
    await editNamed(page, 'Fixture hunt');
    const draft = await rawDraft(page);
    assert.equal(String(draft.settings.fried), '91');
    assert.deepEqual(draft.settings.custom_extension, {keep_me: false});
  });

  await check('hunting settings show everyday controls and hide technical compatibility controls', async (page) => {
    await editNamed(page, 'Fixture hunt');
    await page.locator('#navigation').getByRole('button', {name: 'Hunting behavior', exact: true}).click();
    for (const key of ['loot_script', 'priority', 'delay_loot', 'loot_stance', 'final_loot', 'flee_clouds', 'flee_vines', 'flee_webs', 'flee_voids', 'ignore_disks']) {
      assert.equal(await page.locator(`#field-${key}`).isVisible(), true, `${key} should not require Advanced settings`);
    }
    for (const key of ['flee_message', 'box_in_hand']) assert.equal(await page.locator(`#field-${key}`).isVisible(), false);
    await page.getByText('Advanced settings (2)', {exact: true}).click();
    for (const key of ['flee_message', 'box_in_hand']) assert.equal(await page.locator(`#field-${key}`).isVisible(), true);
    const draft = await rawDraft(page);
    assert.equal(Object.hasOwn(draft.settings, 'box_in_hand'), false, 'Viewing categories must not change settings');
  });

  await check('hunting behavior groups related controls without duplicates or hidden normal settings', async (page) => {
    await editNamed(page, 'Fixture hunt');
    const before = await rawDraft(page);
    await page.locator('#navigation').getByRole('button', {name: 'Hunting behavior', exact: true}).click();
    const groups = {
      'Movement and stance': ['hunting_stance', 'wander_stance', 'sneaky_sneaky', 'wander_wait'],
      'Choosing fights': ['priority', 'lone_targets_only', 'ignore_disks'],
      'Looting': ['loot_script', 'delay_loot', 'loot_stance', 'final_loot'],
      'When to leave a room': ['flee_count', 'flee_clouds', 'flee_vines', 'flee_webs', 'flee_voids']
    };
    for (const [name, keys] of Object.entries(groups)) {
      const section = page.getByRole('region', {name, exact: true});
      await section.getByRole('heading', {name, exact: true}).waitFor();
      for (const key of keys) {
        assert.equal(await section.locator(`#field-${key}`).isVisible(), true);
        assert.equal(await page.locator(`#field-${key}`).count(), 1);
      }
    }
    if (process.env.SETUP_SCREENSHOTS) await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/hunting-groups.png`});
    await page.setViewportSize({width: 390, height: 844});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
    assert.equal(await page.locator('#field-flee_count').isVisible(), true);
    await page.setViewportSize({width: 1400, height: 1000});
    await page.locator('#search').fill('flee_message');
    await page.locator('#search-results').getByRole('button').click();
    assert.equal(await page.locator('#field-flee_message').isVisible(), true, 'Search still reveals advanced fields');
    assert.deepEqual(await rawDraft(page), before, 'Grouping and browsing must not change the draft');
  });

  await check('profile management hides, restores and confirms recoverable deletion', async (page) => {
    await api('save', {kind: 'profiles', name: 'Disposable hunt', revision: null, data: original.data});
    await page.getByRole('button', {name: 'Refresh profile list', exact: true}).click();
    const row = () => page.locator('.list-item').filter({has: page.getByText('Disposable hunt', {exact: true})});
    await row().getByRole('button', {name: 'Hide', exact: true}).click();
    await row().waitFor({state: 'detached'});
    await page.goto('about:blank');
    await page.goto(url); // New document: the editor deliberately removes its token from the address bar.
    await page.getByLabel('Show hidden profiles', {exact: true}).check();
    await row().getByRole('button', {name: 'Show', exact: true}).click();
    await row().getByRole('button', {name: 'Hide', exact: true}).waitFor();
    page.removeAllListeners('dialog');
    const cancelled = new Promise((resolve) => page.once('dialog', async (dialog) => { await dialog.dismiss(); resolve(); }));
    await row().getByRole('button', {name: 'Delete…', exact: true}).click();
    await within(cancelled, 'Delete confirmation was not displayed');
    assert.deepEqual((await api('read', {kind: 'profiles', name: 'Disposable hunt'})).data, original.data);
    page.once('dialog', (dialog) => dialog.accept());
    await row().getByRole('button', {name: 'Delete…', exact: true}).click();
    await row().waitFor({state: 'detached'});
    assert.match(await page.locator('#status').textContent(), /Recovery copy/);
    assert.equal((await api('bootstrap')).profiles.includes('Disposable hunt'), false);
  });

  await check('active profile is explicit, highlighted, protected and reopened on setup startup', async (page) => {
    const row = () => page.locator('.list-item').filter({has: page.getByText('Fixture hunt', {exact: true})});
    try {
      await row().getByRole('button', {name: 'Set active', exact: true}).click();
      await page.waitForFunction(() => document.getElementById('status').textContent.includes('is now the active default'));
      await page.goto('about:blank');
      await page.goto(url); // Reopen the full authenticated launch URL in a fresh document.
      await page.waitForFunction(() => document.getElementById('status').textContent === 'Opened Fixture hunt.');
      assert.match(await page.locator('#dirty').textContent(), /Active profile/);
      assert.equal(await page.locator('#draft-name').textContent(), 'Fixture hunt');
      assert.equal(await page.locator('#main > h1').textContent(), 'Manage profiles', 'Setup lands on profile management even with an active hunt');
      await nav(page, 'Monitoring & limits');
      const selected = await api('read', {kind: 'profiles', name: 'Fixture hunt'});
      const checked = await api('validate', {data: selected.data});
      const expectedFried = checked.effective.fried ?? (await api('bootstrap')).fields.find((field) => field.key === 'fried').default;
      assert.equal(await page.locator('#field-fried').inputValue(), String(expectedFried));
      await page.locator('#navigation').getByRole('button', {name: 'Manage profiles', exact: true}).click();
      assert.match(await row().getAttribute('class'), /active-profile/);
      assert.equal(await row().getByRole('button', {name: 'Delete…', exact: true}).isDisabled(), true);
      assert.equal(await row().getByRole('button', {name: 'Hide', exact: true}).count(), 0);
      await page.getByRole('button', {name: 'Clear active profile', exact: true}).click();
      await page.getByText('No default hunt selected.', {exact: true}).waitFor();
    } finally {
      const preferences = (await api('bootstrap')).profile_visibility;
      if (preferences.active_profile) await api('set_active_profile', {name: null, revision: preferences.revision});
    }
  });

  await check('manage profiles uses a compact responsive dashboard as its landing page', async (page) => {
    assert.equal(await page.locator('#main > h1').textContent(), 'Manage profiles');
    await page.setViewportSize({width: 1600, height: 1000});
    const active = page.getByRole('region', {name: 'Active profile', exact: true});
    const injury = page.getByRole('region', {name: 'Character injury default', exact: true});
    const first = await active.boundingBox(), second = await injury.boundingBox();
    assert.equal(Math.round(first.y), Math.round(second.y), 'Default summaries should share a desktop row');
    assert.ok(second.x > first.x + first.width, 'Default summaries must not overlap');
    assert.ok(first.height < 230 && second.height < 230, 'Empty summaries should not become full-page cards');
    const catalog = await page.locator('.management-catalog').boundingBox();
    assert.ok(catalog.width > 1100, 'Dashboard should use available desktop width');
    if (process.env.SETUP_SCREENSHOTS) await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/manage-dashboard-desktop.png`});
    await page.setViewportSize({width: 390, height: 844});
    const narrowFirst = await active.boundingBox(), narrowSecond = await injury.boundingBox();
    assert.ok(narrowSecond.y >= narrowFirst.y + narrowFirst.height, 'Summaries should stack on mobile');
    assert.equal(await page.evaluate(() => document.querySelector('#content-pane').scrollWidth <= document.querySelector('#content-pane').clientWidth + 1), true, 'Dashboard should not scroll sideways');
    if (process.env.SETUP_SCREENSHOTS) await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/manage-dashboard-mobile.png`});
  });

  await check('shared sections have create links and refuse deletion of referenced plans', async (page) => {
    const section = (title) => page.locator('section.card').filter({has: page.getByRole('heading', {name: title, exact: true})});
    await section('Character defaults').getByRole('button', {name: 'Add character defaults', exact: true}).click();
    assert.match(await page.locator('#draft-name').textContent(), /Untitled|New|Unnamed/i);
    await page.locator('#navigation').getByRole('button', {name: 'Manage profiles', exact: true}).click();
    await section('Combat Plans').getByRole('button', {name: 'Add combat plan', exact: true}).click();
    await page.getByRole('heading', {name: 'Combat sequence', exact: true}).waitFor();
    await page.locator('#navigation').getByRole('button', {name: 'Manage profiles', exact: true}).click();
    const row = page.locator('.list-item').filter({has: page.getByText('No fire', {exact: true})});
    await api('save', {kind: 'profiles', name: 'Plan dependent', revision: null, data: {schema_version: 1, settings: {}, combat_plan: 'No fire'}});
    await row.getByRole('button', {name: 'Delete…', exact: true}).click();
    await page.waitForFunction(() => document.getElementById('status').textContent.includes('still used by profiles/Plan dependent'));
    assert.equal((await api('bootstrap')).plans.includes('No fire'), true);
  });

  await check('shared editor navigation never labels a combat sequence as monitoring', async (page) => {
    await page.getByRole('button', {name: 'Add combat plan', exact: true}).click();
    await page.getByRole('heading', {name: 'Combat sequence', exact: true}).waitFor();
    const monitoring = page.locator('#navigation').getByRole('button', {name: 'Monitoring & limits', exact: true});
    if (await monitoring.count()) {
      await monitoring.click();
      assert.equal(await page.getByRole('heading', {name: 'Combat sequence', exact: true}).count(), 0,
        'Monitoring & limits incorrectly renders the shared Combat Plan editor');
    }
    assert.equal(await monitoring.count(), 0, 'Hunt-only navigation should not be offered while editing a standalone Combat Plan');
    await page.getByLabel('Combat Plan name', {exact: true}).fill('Navigation plan');
    await page.getByText('Original routine text (advanced)', {exact: true}).click();
    await page.getByLabel('Original combat routine', {exact: true}).fill('incant 703, incant 719, incant 711, incant 705(x3)');
    await page.getByLabel('Original combat routine', {exact: true}).press('Tab');
    await page.locator('#search').fill('fried');
    assert.equal(await page.locator('#search-results button').count(), 0);
    assert.match(await page.locator('#search-results').textContent(), /limited to this shared configuration/);
    await page.getByRole('button', {name: 'Choose a hunt profile', exact: true}).click();
    const draft = await rawDraft(page);
    assert.equal(draft.commands, 'incant 703, incant 719, incant 711, incant 705(x3)');
    await saveDraft(page);
    await editNamed(page, 'Fixture hunt');
    await nav(page, 'Monitoring & limits');
    assert.equal(await page.locator('#field-fried').count(), 1);
    assert.equal(await page.getByRole('heading', {name: 'Combat sequence', exact: true}).count(), 0);
    await nav(page, 'Buffs');
    assert.equal(await page.getByRole('heading', {name: 'Combat sequence', exact: true}).count(), 0);
    assert.match(await page.locator('#search-results').textContent(), /Return when my mind is full/);
    assert.equal((await api('read', {kind: 'plans', name: 'Navigation plan'})).data.commands, draft.commands);
  });

  await check('shared injury navigation exposes only policy settings and preserves the draft', async (page) => {
    await page.getByRole('button', {name: 'Add injury policy', exact: true}).click();
    assert.equal(await page.locator('#navigation').getByRole('button', {name: 'Combat Plans', exact: true}).count(), 0);
    assert.equal(await page.locator('#navigation').getByRole('button', {name: 'Rest & services', exact: true}).count(), 0);
    await page.getByLabel('Injury return preset', {exact: true}).selectOption('caster');
    await page.getByRole('button', {name: 'Apply injury return rule', exact: true}).click();
    await page.locator('#search').fill('wounded_eval');
    assert.equal(await page.locator('#search-results button').count(), 1);
    await page.getByRole('button', {name: 'Choose a hunt profile', exact: true}).click();
    const draft = await rawDraft(page);
    assert.match(draft.settings.wounded_eval, /able_to_cast/);
    await nav(page, 'Monitoring & limits');
    assert.equal(await page.getByLabel('Return at or below health percent', {exact: true}).inputValue(), '70');
  });

  await check('rest settings are grouped by location, readiness, services and preparation', async (page) => {
    await editNamed(page, 'Fixture hunt');
    await page.locator('#navigation').getByRole('button', {name: 'Rest & services', exact: true}).click();
    const groups = {
      'Rest locations': ['resting_room_id', 'field_rest_room_id'],
      'Ready to hunt again': ['rest_till_exp', 'rest_till_mana', 'rest_till_spirit', 'rest_till_percentstamina'],
      'Town rest services': ['resting_commands', 'resting_scripts', 'after_town_rest'],
      'Before leaving for a hunt': ['hunting_prep_commands', 'hunting_scripts'],
      'Field rest services': ['field_rest_for', 'field_rest_commands', 'field_rest_scripts', 'field_hunting_prep_commands', 'field_rest_timeout_seconds']
    };
    for (const [name, keys] of Object.entries(groups)) {
      const section = page.getByRole('region', {name, exact: true});
      await section.getByRole('heading', {name, exact: true}).waitFor();
      for (const key of keys) {
        assert.equal(await section.locator(`#field-${key}`).count(), 1);
        assert.equal(await page.locator(`#field-${key}`).count(), 1);
      }
    }
    if (process.env.SETUP_SCREENSHOTS) await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/rest-groups.png`});
  });

  await check('guided gaps: boon choices preserve extensions and round-trip through save', async (page) => {
    await api('save', {kind: 'profiles', name: 'Boon panel test', revision: null, data: {
      schema_version: 1, settings: {...original.data.settings, boons_ignore: ['future_boon', 'dispelling'], boons_flee: ['another_extension']}
    }});
    await page.goto('about:blank');
    await page.goto(url);
    await page.waitForFunction(() => document.getElementById('status').textContent.startsWith('Connected.'));
    await editNamed(page, 'Boon panel test');
    await page.locator('#boon-editor > summary').click();
    const choice = page.getByLabel('Response to Dispelling', {exact: true});
    assert.equal(await choice.inputValue(), 'ignore');
    await choice.selectOption('flee');
    if (process.env.SETUP_SCREENSHOTS) await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/boon-panel.png`});
    await page.getByRole('button', {name: 'Fight all listed boons', exact: true}).click();
    await choice.selectOption('flee');
    const draft = await rawDraft(page);
    assert.deepEqual(draft.settings.boons_ignore, ['future_boon']);
    assert.deepEqual(draft.settings.boons_flee, ['another_extension', 'dispelling']);
    await saveDraft(page);
    await editNamed(page, 'Boon panel test');
    await page.locator('#boon-editor > summary').click();
    assert.equal(await choice.inputValue(), 'flee');
  });

  await check('guided gaps: named fog options and ordered services save native values', async (page) => {
    await editNamed(page, 'Other hunt');
    await nav(page, 'Rest & services');
    await page.getByLabel('Return method', {exact: true}).selectOption({label: 'Sigil of Escape'});
    const services = page.getByLabel('Services at rest sequence', {exact: true});
    await services.getByLabel('New Services at rest entry', {exact: true}).fill('eloot sell');
    await services.getByRole('button', {name: 'Add entry', exact: true}).click();
    await services.getByLabel('New Services at rest entry', {exact: true}).fill('eherbs');
    await services.getByRole('button', {name: 'Add entry', exact: true}).click();
    await services.locator('.list-item').last().getByRole('button', {name: 'Move up', exact: true}).click();
    const draft = await rawDraft(page);
    assert.equal(draft.settings.fog_return, '4');
    assert.deepEqual(draft.settings.resting_scripts, ['eherbs', 'eloot sell']);
    await saveDraft(page);
    await editNamed(page, 'Other hunt');
    assert.deepEqual((await rawDraft(page)).settings.resting_scripts, ['eherbs', 'eloot sell']);
  });

  await check('guided gaps: combat specialty options and boolean action choices remain exact', async (page) => {
    await api('save', {kind: 'profiles', name: 'Special actions test', revision: null, data: {schema_version: 1, settings: {...original.data.settings, hunting_commands: ''}}});
    await page.goto('about:blank');
    await page.goto(url);
    await page.waitForFunction(() => document.getElementById('status').textContent.startsWith('Connected.'));
    await editNamed(page, 'Special actions test');
    await nav(page, 'Combat Plans');
    const editor = page.locator('section.card').filter({has: page.getByRole('heading', {name: 'Usual combat sequence', exact: true})});
    const add = editor.locator(':scope > .action-builder');
    await add.getByLabel('Action to add', {exact: true}).selectOption('tether');
    await add.getByLabel('Recast when tether transfers').selectOption('true');
    await add.getByLabel('Recast when tether transfers').selectOption('false');
    await add.getByRole('button', {name: 'Add action', exact: true}).click();
    await add.getByLabel('Action to add', {exact: true}).selectOption('curse');
    await add.getByLabel('Curse type').selectOption('nightmare');
    await add.getByRole('button', {name: 'Add action', exact: true}).click();
    await add.getByLabel('Action to add', {exact: true}).selectOption('force');
    await add.getByLabel('Required endroll').fill('120');
    await add.getByText('Choose the inner action', {exact: true}).click();
    const inner = add.locator('details > .action-builder');
    await inner.getByLabel('Action type', {exact: true}).selectOption('incant');
    await inner.getByLabel('Step spell number', {exact: true}).fill('1002');
    await inner.getByRole('button', {name: 'Update action', exact: true}).click();
    await add.getByRole('button', {name: 'Add action', exact: true}).click();
    await page.getByText('Unarmed combat and MSTRIKE', {exact: true}).click();
    await page.getByLabel('Attack at excellent UAC positioning', {exact: true}).selectOption('kick');
    await page.getByLabel('Disable automatic unarmed MSTRIKE', {exact: true}).selectOption('true');
    if (process.env.SETUP_SCREENSHOTS) await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/combat-specialties.png`});
    const draft = await rawDraft(page);
    assert.equal(draft.settings.hunting_commands, 'tether, curse nightmare, force incant 1002 until 120');
    assert.equal(draft.settings.tier3, 'kick');
    assert.equal(draft.settings.uac_mstrike, true);
    await saveDraft(page);
  });

  await check('guided gaps: alternative sequence stays open after editing without changing the usual sequence', async (page) => {
    await editNamed(page, 'Sequence choices');
    await nav(page, 'Combat Plans');
    await page.getByText('Alternative combat sequences', {exact: true}).click();
    const alternative = page.locator('section.card').filter({has: page.getByRole('heading', {name: 'When my mind is full (coordinated groups)', exact: true})});
    await alternative.getByRole('button', {name: 'Add action', exact: true}).click();
    await alternative.getByRole('button', {name: 'Add action', exact: true}).click();
    assert.equal(await alternative.getByLabel('Original combat routine').inputValue(), 'attack, attack');
    const draft = await rawDraft(page);
    assert.equal(draft.settings.disable_commands, 'attack, attack');
    assert.equal(draft.settings.hunting_commands, 'attack');
  });

  await check('guided gaps: notes are editor metadata and team settings do not enroll anyone', async (page) => {
    await editNamed(page, 'Other hunt');
    await page.getByRole('button', {name: 'Guided setup', exact: true}).click();
    await page.locator('#navigation').getByRole('button').filter({hasText: 'Your character'}).click();
    await page.getByLabel('Profile notes', {exact: true}).fill('Use cold spells here.');
    await page.getByLabel('Profile notes', {exact: true}).press('Tab');
    await nav(page, 'Multi-Account Team');
    await page.getByLabel('Required multi-account followers', {exact: true}).fill('TestFollower');
    await page.getByLabel('Required multi-account followers', {exact: true}).press('Tab');
    const draft = await rawDraft(page);
    assert.equal(draft.notes, 'Use cold spells here.');
    assert.equal(draft.settings.group_members, 'TestFollower');
    assert.equal(draft.settings.notes, undefined);
    await saveDraft(page);
    assert.equal((await api('read', {kind: 'profiles', name: 'Other hunt'})).data.notes, 'Use cold spells here.');
  });

  await check('inherited values survive an unrelated edit', async (page) => {
    await editNamed(page, 'Other hunt');
    await nav(page, 'Combat Plans');
    await page.getByLabel(/^Character defaults/).selectOption('Usual setup');
    await nav(page, 'Review & save');
    await page.getByRole('button', {name: 'Check effective configuration', exact: true}).click();
    await page.waitForFunction(() => document.getElementById('status').textContent === 'Configuration check complete.');
    await nav(page, 'Monitoring & limits');
    await valueIs(page, '#field-fried', '87');
    await page.locator('#field-oom').fill('15');
    await page.locator('#field-oom').press('Tab');
    await nav(page, 'Equipment');
    await nav(page, 'Monitoring & limits');
    await valueIs(page, '#field-fried', '87');
    assert.equal((await rawDraft(page)).settings.fried, undefined, 'Reading an inherited field must not create an override');
  });

  await check('room selection toggles visibly by default and offers distinct start and rest tools', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await nav(page, 'Area & creatures');
    await page.getByRole('button', {name: 'Load / refresh areas', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('Fixture area (not game data)');
    await page.getByRole('button', {name: 'Preview selected area', exact: true}).click();
    const map = page.locator('#footprint-map-picker');
    const room = map.locator('[data-room-id="3"]');
    await room.locator('.room-overlay').click();
    assert.equal(await room.evaluate((node) => node.classList.contains('selected-room')), false, 'Default room click must visibly remove it from the selected hunting area, not silently select a start');
    await room.focus(); await page.keyboard.press('Enter');
    await map.locator('[data-room-id="3"].selected-room').waitFor();
    await roomAction(page, '#footprint-map-picker', 3, 'Starting room');
    await roomAction(page, '#footprint-map-picker', 2, 'Starting room');
    assert.equal(await map.locator('[data-room-id].starting-room').count(), 1, 'A new start replaces the previous marker');
    await map.locator('[data-room-id="2"].starting-room').waitFor();
    await roomAction(page, '#footprint-map-picker', 1, 'Field rest');
    await map.locator('[data-room-id="1"].field-rest-room').waitFor();
    assert.equal(await map.locator('[data-room-id="1"].selected-room').count(), 0, 'Choosing a rest room outside the hunt must not add it to hunting rooms');
    const colors = await map.evaluate((node) => ['.starting-room', '.field-rest-room'].map((css) => getComputedStyle(node.querySelector(`${css} .room-overlay`)).fill));
    assert.notEqual(colors[0], colors[1]);
    assert.match(await map.locator('.map-feedback').innerText(), /Field rest.*#1/);
    const before = await rawDraft(page);
    assert.equal(before.settings.field_rest_room_id, undefined, 'Map preview must not apply or save rest edits before Apply');
    await nav(page, 'Area & creatures');
    await page.getByRole('button', {name: 'Recalculate boundaries for selected rooms', exact: true}).click();
    await page.locator('#footprint-count').waitFor();
    await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).click();
    const after = await rawDraft(page);
    assert.equal(after.settings.field_rest_room_id, '1');
    assert.equal(after.settings.hunting_room_id, '2');
    assert.deepEqual(after.area_provenance.room_ids, [2, 3]);
  });

  await check('right-click roles, keyboard menu and near-box clicks share the same room edits', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('Fixture area (not game data)');
    const map = page.locator('#footprint-map-picker');
    const room = map.locator('[data-room-id="3"]');
    await room.focus(); await page.keyboard.press('Shift+F10');
    await page.getByRole('menu', {name: 'Actions for room 3', exact: true}).waitFor();
    await page.keyboard.press('Escape');
    assert.equal(await page.getByRole('menu').count(), 0);
    assert.equal(await room.evaluate((node) => node.classList.contains('selected-room')), true, 'Opening/dismissing a menu does not toggle membership');
    const box = await room.locator('.room-overlay').boundingBox();
    await page.mouse.click(box.x + box.width + 4, box.y + box.height / 2);
    await map.locator('[data-room-id="3"].excluded-room').waitFor();
    await roomAction(page, '#footprint-map-picker', 3, 'Hunting room');
    await map.locator('[data-room-id="3"].selected-room').waitFor();
    await roomAction(page, '#footprint-map-picker', 3, 'Boundary room');
    await map.locator('[data-room-id="3"].boundary-room.excluded-room').waitFor();
    await room.focus(); await page.keyboard.press('Shift+F10');
    await page.keyboard.press('Home'); await page.keyboard.press('ArrowDown'); await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter');
    await map.locator('[data-room-id="3"].starting-room.selected-room').waitFor();
    assert.equal(await map.locator('[data-room-id="3"].boundary-room').count(), 0, 'Start overrides a conflicting boundary');
    await roomAction(page, '#footprint-map-picker', 1, 'Field rest');
    await roomAction(page, '#footprint-map-picker', 1, 'Town rest');
    const badges = map.locator('[data-room-id="1"] .room-badge');
    assert.equal(await badges.count(), 2, 'Co-located rest roles remain individually identifiable');
    const colors = await badges.locator('circle').evaluateAll((nodes) => nodes.map((node) => getComputedStyle(node).fill));
    assert.notEqual(colors[0], colors[1]);
    await map.locator('[data-room-id="2"] .room-overlay').click();
    await map.locator('[data-room-id="2"].excluded-room').waitFor();
    assert.equal(await map.locator('[data-room-id="2"].town-rest-room').count(), 0, 'Left-click always toggles, regardless of the previous menu action');
    await map.getByRole('button', {name: 'Undo room selection', exact: true}).click();
    await map.locator('[data-room-id="2"].selected-room').waitFor();
    if (process.env.SETUP_SCREENSHOTS) await map.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/room-controls.png`});
    assert.equal((await rawDraft(page)).settings.hunting_room_id, undefined, 'All preview changes remain unapplied');
  });

  await check('room role menu shows simultaneous roles and toggles only the selected role off', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('Fixture area (not game data)');
    const map = page.locator('#footprint-map-picker');
    await roomAction(page, '#footprint-map-picker', 3, 'Starting room');
    await roomAction(page, '#footprint-map-picker', 3, 'Field rest');
    await map.locator('[data-room-id="3"].selected-room.starting-room.field-rest-room').waitFor();
    await map.locator('[data-room-id="3"] .room-overlay').click({button: 'right'});
    for (const name of ['Hunting room', 'Starting room', 'Field rest']) {
      assert.equal(await page.getByRole('menuitemcheckbox', {name, exact: true}).getAttribute('aria-checked'), 'true');
    }
    if (process.env.SETUP_SCREENSHOTS) await page.getByRole('menu').screenshot({path: `${process.env.SETUP_SCREENSHOTS}/room-role-menu.png`});
    await page.keyboard.press('Escape');
    await roomAction(page, '#footprint-map-picker', 3, 'Field rest');
    assert.equal(await map.locator('[data-room-id="3"].field-rest-room').count(), 0, 'Selecting the active Field rest role again must remove it');
    await map.locator('[data-room-id="3"].selected-room.starting-room').waitFor();
    await map.locator('[data-room-id="3"] .room-overlay').click({button: 'right'});
    const menu = page.getByRole('menu', {name: 'Actions for room 3', exact: true});
    for (const [name, checked] of [['Hunting room', true], ['Starting room', true], ['Field rest', false], ['Town rest', false], ['Boundary room', false]]) {
      assert.equal(await menu.getByRole('menuitemcheckbox', {name, exact: true}).getAttribute('aria-checked'), String(checked));
    }
    await page.keyboard.press('Escape');
    await map.getByRole('button', {name: 'Undo room selection', exact: true}).click();
    await map.locator('[data-room-id="3"].selected-room.starting-room.field-rest-room').waitFor();
    await roomAction(page, '#footprint-map-picker', 3, 'Field rest');
    await roomAction(page, '#footprint-map-picker', 3, 'Starting room');
    assert.equal(await map.locator('[data-room-id="3"].starting-room').count(), 0);
    await map.locator('[data-room-id="3"].selected-room').waitFor();
    await roomAction(page, '#footprint-map-picker', 3, 'Starting room');
    await roomAction(page, '#footprint-map-picker', 2, 'Hunting room');
    await map.locator('[data-room-id="2"].excluded-room').waitFor();
    await roomAction(page, '#footprint-map-picker', 2, 'Hunting room');
    await map.locator('[data-room-id="2"].selected-room').waitFor();
    await roomAction(page, '#footprint-map-picker', 2, 'Boundary room');
    await map.locator('[data-room-id="2"].boundary-room').waitFor();
    await roomAction(page, '#footprint-map-picker', 2, 'Boundary room');
    await map.locator('[data-room-id="2"].selected-room').waitFor();
    assert.equal(await map.locator('[data-room-id="2"].boundary-room').count(), 0);
    await page.getByRole('button', {name: 'Recalculate boundaries for selected rooms', exact: true}).click();
    await page.locator('#footprint-count').waitFor();
    await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).click();
    const draft = await rawDraft(page);
    assert.equal(draft.settings.field_rest_room_id, '', 'An applied removal must stay explicit, not restore inherited settings');
    assert.equal(draft.settings.hunting_room_id, '3');
    assert.deepEqual(draft.area_provenance.room_ids, [2, 3]);
  });

  await check('saved profile rest roles toggle independently and remain cleared after save and reopen', async (page) => {
    await editNamed(page, 'Role toggle fixture');
    await nav(page, 'Area & creatures');
    const map = page.locator('#profile-map');
    await map.locator('[data-room-id="2"].selected-room.starting-room.field-rest-room.town-rest-room').waitFor();
    await map.locator('[data-room-id="2"] .room-overlay').click({button: 'right'});
    for (const name of ['Hunting room', 'Starting room', 'Field rest', 'Town rest']) {
      assert.equal(await page.getByRole('menuitemcheckbox', {name, exact: true}).getAttribute('aria-checked'), 'true');
    }
    await page.getByRole('menuitemcheckbox', {name: 'Field rest', exact: true}).click();
    await map.locator('[data-room-id="2"].selected-room.starting-room.town-rest-room').waitFor();
    assert.equal(await map.locator('[data-room-id="2"].field-rest-room').count(), 0);
    await page.getByRole('button', {name: 'Undo map edit', exact: true}).click();
    await map.locator('[data-room-id="2"].field-rest-room').waitFor();
    await roomAction(page, '#profile-map', 2, 'Field rest');
    await map.locator('[data-room-id="2"].selected-room.starting-room.town-rest-room').waitFor();
    await roomAction(page, '#profile-map', 2, 'Town rest');
    await map.locator('[data-room-id="2"].selected-room.starting-room').waitFor();
    assert.equal(await map.locator('[data-room-id="2"].town-rest-room').count(), 0);
    let draft = await rawDraft(page);
    assert.equal(draft.settings.field_rest_room_id, '');
    assert.equal(draft.settings.resting_room_id, '');
    assert.equal(draft.settings.hunting_room_id, 2);
    assert.equal(draft.settings.hunting_boundaries, '1');
    await nav(page, 'Area & creatures');
    await roomAction(page, '#profile-map', 1, 'Town rest');
    await map.locator('[data-room-id="1"].town-rest-room').waitFor();
    await saveDraft(page);
    await editNamed(page, 'Role toggle fixture');
    draft = await rawDraft(page);
    assert.equal(draft.settings.field_rest_room_id, '');
    assert.equal(draft.settings.resting_room_id, '1');
    await nav(page, 'Area & creatures');
    await map.locator('[data-room-id="2"].selected-room.starting-room').waitFor();
    assert.equal(await map.locator('.field-rest-room[data-room-id]').count(), 0);
    await roomAction(page, '#profile-map', 2, 'Starting room');
    await map.locator('[data-room-id="2"]:not(.starting-room)').waitFor();
    assert.equal((await rawDraft(page)).settings.hunting_room_id, '');
  });

  await check('map clicks choose a footprint without changing the draft until Apply', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await nav(page, 'Area & creatures');
    await page.getByRole('button', {name: 'Load / refresh areas', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('Fixture area (not game data)');
    await page.getByRole('button', {name: 'Preview selected area', exact: true}).click();
    await page.getByLabel('Response to fixture rat', {exact: true}).selectOption('hunt');
    await page.getByRole('button', {name: 'Reset to suggested area rooms', exact: true}).click();
    await page.locator('#footprint-count').waitFor();
    assert.equal(await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).isEnabled(), false);
    await roomAction(page, '#footprint-map-picker', 2, 'Starting room');
    await page.locator('#footprint-map-picker [data-room-id="3"][role="button"]').focus();
    await page.keyboard.press('Enter');
    assert.equal(await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).count(), 0);
    assert.equal((await rawDraft(page)).settings.hunting_room_id, undefined);
    await nav(page, 'Area & creatures');
    await page.getByRole('button', {name: 'Recalculate boundaries for selected rooms', exact: true}).click();
    await page.locator('#footprint-count').waitFor();
    assert.match(await page.locator('#footprint-count').innerText(), /1 proposed hunting rooms · 2 boundary rooms/);
    assert.equal(await page.locator('#footprint-map-picker [data-room-id="3"].boundary-room').count(), 1);
    await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).click();
    const draft = await rawDraft(page);
    assert.equal(draft.settings.hunting_boundaries, '1, 3');
    assert.equal(draft.settings.resting_room_id, undefined);
    assert.equal(draft.settings.hunting_room_id, '2');
    assert.equal(draft.settings.targets, 'fixture rat(a)');
    assert.deepEqual(draft.area_provenance.room_ids, [2]);
    assert.equal(draft.area, 'Fixture area (not game data)');
    await nav(page, 'Area & creatures');
    await page.getByLabel('Response to fixture rat', {exact: true}).selectOption('ignore');
    assert.match(await page.locator('#footprint-count').innerText(), /1 proposed hunting rooms/);
    assert.equal((await rawDraft(page)).settings.hunting_boundaries, '1, 3', 'Changing target policy cannot silently change an approved route');
  });

  await check('draft catalog preserves transit rooms, reports limitations and excludes special candidates', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    const choices = await page.getByLabel('Hunting area', {exact: true}).locator('option').allTextContents();
    assert.equal(choices.filter((name) => name.includes('Draft route')).length, 1);
    assert.equal(choices.some((name) => name.includes('Scripted cave')), false);
    await page.getByLabel('Hunting area', {exact: true}).selectOption('Draft fixture region::draft-route');
    await page.getByRole('heading', {name: 'Suggested area — editable, not field-tested', exact: true}).waitFor();
    await page.getByText('Area notes & limitations', {exact: true}).click();
    await page.getByText('The scripted cave is excluded; access has not been checked.', {exact: true}).waitFor();
    await page.getByText(/catalog static check is partial/).first().waitFor();
    assert.match(await page.locator('#footprint-count').innerText(), /3 proposed hunting rooms/);
    await page.getByLabel('Response to fixture rat', {exact: true}).selectOption('hunt');
    await page.getByLabel('Response to fixture rat', {exact: true}).selectOption('ignore');
    assert.match(await page.locator('#footprint-count').innerText(), /3 proposed hunting rooms/);
    await page.locator('#footprint-map-picker [data-room-id="1"].selected-room').waitFor();
    assert.equal(await page.getByLabel('Include room 5', {exact: true}).isChecked(), false);
    const draft = await rawDraft(page);
    assert.equal(draft.area, undefined, 'Area and target browsing must not apply geographic settings');
    assert.equal(draft.settings.hunting_room_id, undefined);
  });

  await check('manual map additions require explicit room choice and stay local until Apply', async (page) => {
    const mutations = [];
    page.on('request', (request) => {
      if (request.url().endsWith('/api') && request.postDataJSON()?.action === 'save') mutations.push(request.postDataJSON());
    });
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('Fixture area (not game data)');
    await page.locator('#footprint-count').waitFor();
    const outside = page.locator('#footprint-map-picker [data-room-id="1"][role="button"]');
    assert.equal(await outside.getAttribute('class'), 'excluded-room boundary-room');
    await outside.click();
    await page.getByRole('button', {name: 'Recalculate boundaries for selected rooms', exact: true}).click();
    await page.locator('#footprint-count').waitFor();
    assert.match(await page.locator('#footprint-count').innerText(), /3 proposed hunting rooms · 0 boundary rooms/);
    await page.getByLabel('Response to fixture rat', {exact: true}).selectOption('hunt');
    assert.match(await page.locator('#footprint-count').innerText(), /3 proposed hunting rooms/);
    const browsing = await rawDraft(page);
    assert.equal(browsing.area_provenance, undefined);
    assert.equal(browsing.settings.hunting_room_id, undefined);
    await nav(page, 'Area & creatures');
    await page.getByLabel('Choose a mapped starting room', {exact: true}).selectOption('2');
    await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).click();
    const applied = await rawDraft(page);
    assert.deepEqual(applied.area_provenance.room_ids, [1, 2, 3]);
    assert.deepEqual(applied.area_provenance.added_room_ids, [1]);
    assert.equal(applied.settings.resting_room_id, undefined);
    assert.deepEqual(mutations, [], 'Browsing, manual selection and Apply never persist a profile');
  });

  await check('rest map picker browses independent maps, cancels safely and changes only the chosen role', async (page) => {
    await editNamed(page, 'Other hunt');
    const before = await rawDraft(page);
    await nav(page, 'Area & creatures');
    const map = page.locator('#profile-map');
    await map.getByRole('button', {name: 'Choose field rest on another map', exact: true}).click();
    let pane = page.getByRole('dialog', {name: 'Choose field rest room', exact: true});
    await pane.getByLabel('Rest room map', {exact: true}).selectOption('fixture-rest.png');
    await pane.locator('[data-room-id="4"] .room-overlay').click();
    if (process.env.SETUP_SCREENSHOTS) await pane.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/rest-map-picker.png`});
    await pane.getByRole('button', {name: 'Cancel', exact: true}).click();
    assert.deepEqual(await rawDraft(page), before, 'Browsing and cancelling must not mutate the draft');
    await nav(page, 'Area & creatures');
    for (const [role, key] of [['field rest', 'field_rest_room_id'], ['town rest', 'resting_room_id']]) {
      await map.getByRole('button', {name: `Choose ${role} on another map`, exact: true}).click();
      pane = page.getByRole('dialog', {name: `Choose ${role} room`, exact: true});
      await pane.getByLabel('Rest room map', {exact: true}).selectOption('fixture-rest.png');
      await pane.locator('[data-room-id="4"]').focus();
      await page.keyboard.press('Enter');
      await pane.getByRole('button', {name: `Use this room for ${role}`, exact: true}).click();
      const after = await rawDraft(page);
      before.settings[key] = '4';
      assert.deepEqual(after, before, 'Rest picking must preserve every unrelated profile field');
      await nav(page, 'Area & creatures');
    }
    const persisted = await api('read', {kind: 'profiles', name: 'Other hunt'});
    assert.notEqual(persisted.data.settings.resting_room_id, '4', 'Confirming is draft-only, not a save');
  });

  await check('an area proposal can choose off-map rest without changing its hunting membership', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await nav(page, 'Area & creatures');
    await page.getByRole('button', {name: 'Load / refresh areas', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('Fixture area (not game data)');
    await page.getByRole('button', {name: 'Preview selected area', exact: true}).click();
    await page.getByRole('button', {name: 'Reset to suggested area rooms', exact: true}).click();
    await page.locator('#footprint-count').waitFor();
    const before = await page.locator('#footprint-count').innerText();
    const picker = page.locator('#footprint-map-picker');
    await picker.getByRole('button', {name: 'Choose field rest on another map', exact: true}).click();
    const pane = page.getByRole('dialog', {name: 'Choose field rest room', exact: true});
    await pane.getByLabel('Rest room map', {exact: true}).selectOption('fixture-rest.png');
    await pane.locator('[data-room-id="4"] .room-overlay').click();
    await pane.getByRole('button', {name: 'Use this room for field rest', exact: true}).click();
    assert.equal(await page.locator('#footprint-count').innerText(), before);
    await page.getByLabel('Choose a mapped starting room', {exact: true}).selectOption('2');
    await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).click();
    const draft = await rawDraft(page);
    assert.equal(draft.settings.field_rest_room_id, '4');
    assert.deepEqual(draft.area_provenance.room_ids, [2, 3]);
    assert.equal(draft.settings.hunting_boundaries, '1');
  });

  await check('closing a loading rest map ignores its late response', async (page) => {
    await editNamed(page, 'Other hunt');
    const before = await rawDraft(page);
    await nav(page, 'Area & creatures');
    await page.locator('#profile-map').getByRole('button', {name: 'Choose town rest on another map', exact: true}).waitFor();
    const delay = await delayResponse(page, (body) => body.action === 'profile_map' && body.sheet === 'fixture-rest.png');
    try {
      await page.locator('#profile-map').getByRole('button', {name: 'Choose town rest on another map', exact: true}).click();
      const pane = page.getByRole('dialog', {name: 'Choose town rest room', exact: true});
      await pane.getByLabel('Rest room map', {exact: true}).selectOption('fixture-rest.png');
      await delay.captured;
      await page.keyboard.press('Escape');
      delay.release();
      assert.deepEqual(await rawDraft(page), before);
      assert.equal(await page.getByRole('dialog').count(), 0);
    } finally { delay.release(); }
  });

  await check('guided injury presets preserve custom Ruby until Apply and survive saving', async (page) => {
    const legacyRule = await api('read', {kind: 'profiles', name: 'Other hunt'});
    legacyRule.data.settings.wounded_eval = 'custom_injury_rule?';
    await api('save', {kind: 'profiles', name: 'Other hunt', data: legacyRule.data, revision: legacyRule.revision});
    await editNamed(page, 'Other hunt');
    await nav(page, 'Monitoring & limits');
    const card = page.locator('#injury-rule');
    await card.getByText('Original Ruby injury rule (advanced)', {exact: true}).click();
    await page.locator('#field-wounded_eval').fill('custom_injury_rule?');
    await page.locator('#field-wounded_eval').press('Tab');
    await nav(page, 'Area & creatures'); await nav(page, 'Monitoring & limits');
    assert.match(await card.innerText(), /existing custom injury rule is being kept/);
    await card.getByLabel('Injury return preset', {exact: true}).selectOption('caster');
    assert.equal(await page.locator('#field-wounded_eval').inputValue(), 'custom_injury_rule?', 'Choosing a preset must not silently replace custom Ruby');
    await card.getByLabel('Return at or below health percent', {exact: true}).fill('50');
    await card.getByLabel('Return with popped muscles (Overexerted)', {exact: true}).check();
    await card.getByRole('button', {name: 'Apply injury return rule', exact: true}).click();
    let draft = await rawDraft(page);
    assert.equal(draft.settings.wounded_eval, 'Char.percent_health <= 50 || bleeding? || !Lich::Gemstone::Injured.able_to_cast? || Lich::Gemstone::Effects::Debuffs.active?("Overexerted")');
    await saveDraft(page); await editNamed(page, 'Other hunt'); await nav(page, 'Monitoring & limits');
    assert.equal(await card.getByLabel('Return at or below health percent', {exact: true}).inputValue(), '50');
    assert.equal(await card.getByLabel('Return if injuries prevent casting', {exact: true}).isChecked(), true);
    if (process.env.SETUP_SCREENSHOTS) await card.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/injury-rule.png`});
    await card.getByLabel('Return at or below health percent', {exact: true}).fill('101');
    assert.equal(await card.getByRole('button', {name: 'Apply injury return rule', exact: true}).isDisabled(), true);
    const restored = await api('read', {kind: 'profiles', name: 'Other hunt'});
    delete restored.data.settings.wounded_eval;
    await api('save', {kind: 'profiles', name: 'Other hunt', data: restored.data, revision: restored.revision});
  });

  await check('injury policies share a character default, support hunt overrides and preserve custom rules', async (page) => {
    try {
      await nav(page, 'Manage profiles');
      await page.getByRole('button', {name: 'Add injury policy', exact: true}).click();
      assert.equal(await page.locator('#scope').textContent(), 'SHARED INJURY POLICY');
      await page.getByLabel('Injury policy name', {exact: true}).fill('Normal injuries');
      await page.getByLabel('Injury return preset', {exact: true}).selectOption('caster');
      await page.getByLabel('Return at or below health percent', {exact: true}).fill('70');
      await page.getByRole('button', {name: 'Apply injury return rule', exact: true}).click();
      await saveDraft(page);
      const normal = await api('read', {kind: 'injury_policies', name: 'Normal injuries'});
      assert.match(normal.data.settings.wounded_eval, /health <= 70/);
      await nav(page, 'Manage profiles');
      const row = () => page.locator('.list-item').filter({has: page.getByText('Normal injuries', {exact: true})});
      await row().getByRole('button', {name: 'Use as character default', exact: true}).click();
      await page.waitForFunction(() => document.getElementById('status').textContent.includes('is the character injury default'));
      assert.match(await row().innerText(), /CHARACTER DEFAULT/);
      assert.equal(await row().getByRole('button', {name: 'Delete…', exact: true}).isDisabled(), true);
      await api('save', {kind: 'injury_policies', name: 'Parasite injuries', revision: null,
        data: {schema_version: 1, settings: {wounded_eval: 'Char.percent_health <= 50'}}});
      await api('save', {kind: 'profiles', name: 'Policy hunt', revision: null, data: {schema_version: 1, settings: {targets: 'rat', hunting_commands: 'attack'}}});
      await page.getByRole('button', {name: 'Refresh profile list', exact: true}).click();
      await editNamed(page, 'Policy hunt');
      await nav(page, 'Monitoring & limits');
      const selector = page.getByLabel('Injury policy for this hunt', {exact: true});
      assert.equal(await selector.inputValue(), 'character');
      assert.match(await page.locator('#injury-policy-selection').innerText(), /Normal injuries \(character default\)/);
      assert.equal(await page.locator('#injury-rule').count(), 0, 'Shared rules are not silently copied into an inline override');
      await selector.selectOption('policy:Parasite injuries');
      await page.waitForFunction(() => !document.querySelector('[aria-label="Injury policy for this hunt"]').disabled);
      assert.match(await page.locator('#injury-policy-selection').innerText(), /Parasite injuries \(this hunt only\)/);
      await saveDraft(page);
      const overridden = await api('read', {kind: 'profiles', name: 'Policy hunt'});
      assert.equal(overridden.data.injury_policy, 'Parasite injuries');
      assert.equal(Object.hasOwn(overridden.data.settings, 'wounded_eval'), false);
      assert.equal((await api('validate', {data: overridden.data})).effective.wounded_eval, 'Char.percent_health <= 50');
      assert.equal((await api('validate', {data: {schema_version: 1, settings: {}}})).effective.wounded_eval, normal.data.settings.wounded_eval);
      assert.deepEqual((await api('delete_preview', {kind: 'injury_policies', name: 'Parasite injuries'})).dependents, ['profiles/Policy hunt']);
      await editNamed(page, 'Policy hunt'); await nav(page, 'Monitoring & limits');
      await selector.selectOption('character');
      await page.waitForFunction(() => !document.querySelector('[aria-label="Injury policy for this hunt"]').disabled);
      await saveDraft(page);
      assert.equal((await api('read', {kind: 'profiles', name: 'Policy hunt'})).data.injury_policy, null);
      await editNamed(page, 'Normal injuries');
      await page.getByLabel('Return at or below health percent', {exact: true}).fill('65');
      await page.getByRole('button', {name: 'Apply injury return rule', exact: true}).click();
      await saveDraft(page);
      assert.match((await api('validate', {data: (await api('read', {kind: 'profiles', name: 'Policy hunt'})).data})).effective.wounded_eval, /health <= 65/);
      await api('save', {kind: 'profiles', name: 'Old injury hunt', revision: null,
        data: {schema_version: 1, settings: {wounded_eval: 'old_rule?'}}});
      await nav(page, 'Manage profiles');
      await page.getByRole('button', {name: 'Refresh profile list', exact: true}).click();
      await editNamed(page, 'Old injury hunt'); await nav(page, 'Monitoring & limits');
      assert.equal(await selector.inputValue(), 'custom');
      assert.equal((await api('validate', {data: {wounded_eval: 'old_rule?'}})).effective.wounded_eval, 'old_rule?');
      await selector.selectOption('character');
      await page.waitForFunction(() => !document.querySelector('[aria-label="Injury policy for this hunt"]').disabled);
      assert.equal(await page.locator('#injury-rule').count(), 0);
      const optedIn = await rawDraft(page);
      assert.equal(Object.hasOwn(optedIn.settings, 'wounded_eval'), false);
      assert.equal(optedIn.injury_policy, null);
    } finally {
      const boot = await api('bootstrap');
      if (boot.character_preferences.injury_policy) await api('set_character_injury_policy', {name: null, revision: boot.character_preferences.revision});
    }
  });

  await check('society upkeep offers learned signs symbols and sigils without losing advanced entries', async (page) => {
    await editNamed(page, 'Other hunt');
    await nav(page, 'Buffs');
    const raw = page.locator('#field-signs');
    await page.getByText('Original upkeep entries and other abilities (advanced)', {exact: true}).click();
    await raw.fill('515 rapid, 9903, custom-extension'); await raw.press('Tab');
    await page.getByLabel('Keep Symbol of Courage active', {exact: true}).check();
    await page.getByLabel('Keep Sigil of Defense active', {exact: true}).check();
    await page.getByLabel('Keep Sign of Warding active', {exact: true}).uncheck();
    assert.equal(await page.getByLabel('Keep Symbol of Mana active', {exact: true}).isDisabled(), true);
    if (process.env.SETUP_SCREENSHOTS) await page.locator('#society-upkeep').screenshot({path: `${process.env.SETUP_SCREENSHOTS}/society-upkeep.png`});
    let draft = await rawDraft(page);
    assert.equal(draft.settings.signs, '515 rapid, custom-extension, 9805, 9707');
    assert.equal(draft.settings.use_wracking, undefined, 'Picking upkeep must not enable mana recovery');
    await saveDraft(page);
    await editNamed(page, 'Other hunt'); await nav(page, 'Buffs');
    assert.equal(await page.getByLabel('Keep Symbol of Courage active', {exact: true}).isChecked(), true);
    assert.equal(await page.getByLabel('Keep Sigil of Defense active', {exact: true}).isChecked(), true);
    assert.equal(await page.getByLabel('Keep Sign of Warding active', {exact: true}).isChecked(), false);
    // Restore this shared fixture so unrelated map/routine checks retain their baseline.
    const restored = await api('read', {kind: 'profiles', name: 'Other hunt'});
    delete restored.data.settings.signs;
    await api('save', {kind: 'profiles', name: 'Other hunt', data: restored.data, revision: restored.revision});
  });

  await check('saved profile map keeps custom geometry and edits start, boundary and both rest sites', async (page) => {
    await editNamed(page, 'Other hunt');
    const map = page.locator('#profile-map');
    await map.locator('[data-room-id="2"].starting-room').waitFor();
    const image = map.locator('svg image').first();
    assert.equal(await image.getAttribute('width'), '400');
    assert.equal(await image.getAttribute('height'), '200');
    assert.match(await image.getAttribute('href'), /^data:image\/png;base64,/);
    assert.equal(await map.locator('svg line').count(), 0, 'Classic artwork supplies paths, never generated connections');
    const overlay = map.locator('[data-room-id="2"] rect');
    assert.equal(await overlay.getAttribute('x'), '180');
    assert.equal(await overlay.getAttribute('y'), '50');
    assert.equal(await overlay.getAttribute('width'), '10');
    const beforeZoom = await overlay.evaluate((node) => node.getScreenCTM().a);
    await map.getByLabel('Map zoom: fixture-only.png', {exact: true}).selectOption('2');
    const afterZoom = await overlay.evaluate((node) => node.getScreenCTM().a);
    assert(Math.abs(afterZoom - beforeZoom * 2) < 0.01, 'Overlay coordinates scale with the image; focus outlines deliberately stay constant-width');
    await map.getByLabel('Map zoom: fixture-only.png', {exact: true}).selectOption('1');
    assert.equal(await map.locator('[data-room-id="1"].boundary-room.town-rest-room').count(), 1);
    assert.equal(await page.locator('#footprint-editor').count(), 0, 'No creature proposal is required');
    await roomAction(page, '#profile-map', 3, 'Boundary room');
    await map.locator('[data-room-id="3"].boundary-room').waitFor();
    assert.equal((await rawDraft(page)).settings.hunting_boundaries, '1, 3');
    await nav(page, 'Area & creatures');
    await map.locator('[data-room-id="3"][role="button"]').focus();
    await page.keyboard.press('Space');
    await page.waitForFunction(() => document.querySelector('#profile-map [data-room-id="3"]')?.classList.contains('boundary-room') === false);
    await roomAction(page, '#profile-map', 3, 'Starting room');
    await map.locator('[data-room-id="3"].starting-room').waitFor();
    await page.getByLabel('Additional map sheet', {exact: true}).selectOption('fixture-rest.png');
    await map.locator('[data-room-id="4"][role="button"]').waitFor();
    await roomAction(page, '#profile-map', 4, 'Town rest');
    await map.locator('[data-room-id="4"].town-rest-room').waitFor();
    await roomAction(page, '#profile-map', 1, 'Field rest');
    await map.locator('[data-room-id="1"].field-rest-room').waitFor();
    if (process.env.SETUP_SCREENSHOTS) await map.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/profile-map.png`});
    const draft = await rawDraft(page);
    assert.equal(draft.settings.hunting_room_id, '3');
    assert.equal(draft.settings.hunting_boundaries, '1');
    assert.equal(draft.settings.resting_room_id, '4');
    assert.equal(draft.settings.field_rest_room_id, '1');
    assert.equal(draft.settings.targets, 'fixture rat');
    assert.deepEqual(draft.settings.custom_extension, {keep_me: false});
    await nav(page, 'Area & creatures');
    await page.getByRole('button', {name: 'Undo map edit', exact: true}).click();
    assert.equal((await rawDraft(page)).settings.field_rest_room_id, undefined);
    const saved = await api('read', {kind: 'profiles', name: 'Other hunt'});
    assert.equal(saved.data.settings.hunting_room_id, 2, 'Map clicks do not save or execute');
  });

  await check('a late profile read cannot replace the last requested profile', async (page) => {
    const gate = await delayResponse(page, (request) => request.action === 'read' && request.name === 'Fixture hunt');
    try {
      await page.locator('.list-item').filter({has: page.getByText('Fixture hunt', {exact: true})}).getByRole('button', {name: 'Edit', exact: true}).click();
      await within(gate.captured, 'The profile read was not intercepted');
      await editNamed(page, 'Other hunt');
      const completed = page.waitForResponse((response) => response.request().postDataJSON()?.action === 'read' && response.request().postDataJSON()?.name === 'Fixture hunt');
      gate.release();
      await completed;
      // Subsequent UI work also lets the old read's continuation run.
      await rawDraft(page);
      assert.equal(await page.locator('#draft-name').textContent(), 'Other hunt');
    } finally { gate.release(); }
  });

  await check('a late save cannot change a replacement draft identity or data', async (page) => {
    await editNamed(page, 'Fixture hunt');
    const gate = await delayResponse(page, (request) => request.action === 'save');
    try {
      await nav(page, 'Review & save');
      await page.getByRole('button', {name: 'Save to EOHunter', exact: true}).click();
      await within(gate.captured, 'The profile save was not intercepted');
      await nav(page, 'Manage profiles');
      await page.getByText('Reusable settings & current draft', {exact: true}).click();
      const create = page.getByRole('button', {name: 'New Combat Plan', exact: true});
      if (await create.isEnabled()) await create.click();
      const beforeName = await page.locator('#draft-name').textContent();
      const beforeScope = await page.locator('#scope').textContent();
      const before = await rawDraft(page);
      const completed = page.waitForResponse((response) => response.request().postDataJSON()?.action === 'save');
      gate.release();
      await completed;
      await page.waitForFunction(() => document.getElementById('status').textContent.includes('Saved'));
      assert.equal(await page.locator('#draft-name').textContent(), beforeName);
      assert.equal(await page.locator('#scope').textContent(), beforeScope);
      assert.deepEqual(await rawDraft(page), before);
    } finally { gate.release(); }
  });
  await check('Field Journal creates a hunt through five guided chapters without raw JSON', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    assert.equal(await page.locator('#navigation .guide-step').count(), 5);
    assert.equal(await page.locator('#wizard').isVisible(), false, 'No duplicate step tabs');
    await page.getByRole('heading', {name: 'Your character', exact: true}).waitFor();
    await page.getByLabel('Hunt name', {exact: true}).fill('Guided fixture');
    await page.getByLabel('How will you hunt?', {exact: true}).selectOption('group');
    assert.match(await page.locator('#main').innerText(), /Other people control their own characters/);
    await page.getByLabel('How will you hunt?', {exact: true}).selectOption('team');
    assert.match(await page.locator('#main').innerText(), /explicit local participation/);
    await page.getByLabel('How will you hunt?', {exact: true}).selectOption('solo');
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('Fixture area (not game data)');
    await page.getByLabel('Response to fixture rat', {exact: true}).selectOption('hunt');
    await page.getByRole('button', {name: 'Reset to suggested area rooms', exact: true}).click();
    await page.getByLabel('Choose a mapped starting room', {exact: true}).selectOption('2');
    await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).click();
    assert.match(await page.locator('#target-policy-summary').innerText(), /Hunt only: fixture rat/);
    if (process.env.SETUP_SCREENSHOTS) {
      await page.locator('#profile-map [data-room-id="2"].starting-room').waitFor();
      await page.locator('#content-pane').evaluate((element) => { element.scrollTop = 0; });
      await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/journal-area.png`});
    }
    await page.getByRole('button', {name: 'Continue: Combat approach →', exact: true}).click();
    await page.getByLabel('Action to add', {exact: true}).selectOption('incant');
    await page.getByLabel('Spell number', {exact: true}).fill('711');
    await page.getByRole('button', {name: 'Add action', exact: true}).click();
    await page.getByRole('button', {name: 'Add action', exact: true}).click();
    assert.equal((await page.locator('.topbar').boundingBox()).y, 0, 'Editing a low-down combat control must not scroll the entire shell');
    assert.equal(await page.locator('.sequence-list code').allTextContents().then((rows) => rows.join(', ')), 'incant 711, attack');
    await page.locator('.sequence-list .list-item').nth(1).getByRole('button', {name: 'Move up', exact: true}).click();
    assert.equal(await page.getByLabel('Original combat routine').inputValue(), 'attack, incant 711');
    await page.locator('.sequence-list .list-item').nth(0).getByRole('button', {name: 'Remove', exact: true}).click();
    assert.equal((await page.locator('.topbar').boundingBox()).y, 0, 'Reordering/removing an action must not scroll the entire shell');
    if (process.env.SETUP_SCREENSHOTS) {
      await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/journal-combat.png`});
      assert.equal((await page.locator('.topbar').boundingBox()).y, 0, 'Capturing the editor must not scroll its shell');
    }
    await page.getByRole('button', {name: 'Continue: Rest & recovery →', exact: true}).click();
    await page.getByLabel('Town or main rest room', {exact: true}).fill('1');
    await page.getByLabel('Town or main rest room', {exact: true}).press('Tab');
    await page.getByRole('button', {name: 'Continue: Review & save →', exact: true}).click();
    await page.getByRole('button', {name: 'Check effective configuration', exact: true}).click();
    await page.getByText('Configuration checks passed.', {exact: false}).waitFor();
    await page.getByRole('button', {name: 'Save to EOHunter', exact: true}).click();
    await page.waitForFunction(() => document.querySelector('#status').textContent.startsWith('Saved “Guided fixture”'));
    const saved = await api('read', {kind: 'profiles', name: 'Guided fixture'});
    assert.equal(saved.data.settings.targets, 'fixture rat(a)');
    assert.equal(saved.data.settings.hunting_commands, 'incant 711');
    assert.equal(saved.data.settings.resting_room_id, '1');
    assert.equal(saved.data.settings.hunting_room_id, '2');
    assert.equal(await page.locator('#raw-json').count(), 0);
    await page.setViewportSize({width: 390, height: 800});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    if (process.env.SETUP_SCREENSHOTS) await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/journal-mobile.png`});
  });
  await check('empty targeting is never presented as ready, and shared plans open a command editor', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.locator('#review-button').click();
    await page.getByRole('button', {name: 'Check effective configuration', exact: true}).click();
    await page.getByText('Not ready to hunt.', {exact: false}).waitFor();
    assert.match(await page.locator('#validation-results').innerText(), /Choose creatures to hunt/);
    assert.equal(await page.getByText('No configuration errors reported for this mode.', {exact: true}).count(), 0);
    await nav(page, 'Manage profiles');
    await page.getByText('Reusable settings & current draft', {exact: true}).click();
    await page.getByRole('button', {name: 'New Combat Plan', exact: true}).click();
    await page.getByRole('heading', {name: 'Combat sequence', exact: true}).waitFor();
    assert.equal(await page.locator('#raw-json').count(), 0);
    await page.getByRole('button', {name: 'Add action', exact: true}).click();
    assert.equal(await page.getByLabel('Original combat routine').inputValue(), 'attack');
  });
  await check('guided editing overrides an inherited sequence only after an explicit action', async (page) => {
    await editNamed(page, 'Other hunt');
    await nav(page, 'Combat Plans');
    await page.getByLabel(/^Character defaults/).selectOption('Usual setup');
    await page.waitForFunction(() => !document.querySelector('#main').textContent.includes('Resolving inherited'));
    await nav(page, 'Review & save');
    await page.getByRole('button', {name: 'Check effective configuration', exact: true}).click();
    await page.waitForFunction(() => document.querySelector('#status').textContent === 'Configuration check complete.');
    await nav(page, 'Combat Plans');
    await page.getByRole('button', {name: 'Guided setup', exact: true}).click();
    assert.equal(await page.getByLabel('Original combat routine').inputValue(), 'attack');
    await page.getByLabel('Action to add', {exact: true}).selectOption('incant');
    await page.getByLabel('Spell number', {exact: true}).fill('711');
    await page.getByRole('button', {name: 'Add action', exact: true}).click();
    const draft = await rawDraft(page);
    assert.equal(draft.settings.hunting_commands, 'attack, incant 711');
    assert.equal(draft.defaults, 'Usual setup');
    assert.equal((await api('read', {kind: 'plans', name: 'Usual combat'})).data.commands, 'attack');
  });
  await check('reusable combat sequences can be added and switched without replacing the hunt draft', async (page) => {
    await editNamed(page, 'Other hunt');
    await nav(page, 'Combat Plans');
    await page.getByRole('button', {name: 'Guided setup', exact: true}).click();
    const library = page.locator('#combat-sequences');
    await library.getByRole('button', {name: 'Add sequence', exact: true}).click();
    let composer = page.locator('#new-combat-sequence');
    await composer.getByLabel('Sequence name', {exact: true}).fill('Everyday melee');
    await composer.getByRole('button', {name: 'Add action', exact: true}).click();
    await composer.getByRole('button', {name: 'Save & use as hunt default', exact: true}).click();
    await valueIs(page, '#combat-sequences select', 'Everyday melee');
    await library.getByRole('button', {name: 'Add sequence', exact: true}).click();
    composer = page.locator('#new-combat-sequence');
    await composer.getByLabel('Sequence name', {exact: true}).fill('Control and pain');
    await composer.getByLabel('Action to add', {exact: true}).selectOption('incant');
    await composer.getByLabel('Spell number', {exact: true}).fill('711');
    await composer.getByRole('button', {name: 'Add action', exact: true}).click();
    await composer.getByRole('button', {name: 'Save & use as hunt default', exact: true}).click();
    await valueIs(page, '#combat-sequences select', 'Control and pain');
    await page.locator('#selected-combat-sequence').getByText('incant 711', {exact: true}).waitFor();
    await library.getByLabel('Sequence for this hunt', {exact: true}).selectOption('Everyday melee');
    await page.locator('#selected-combat-sequence').getByText('attack', {exact: true}).waitFor();
    let draft = await rawDraft(page);
    assert.equal(draft.combat_plan, 'Everyday melee');
    assert.equal(draft.settings.hunting_room_id, original.data.settings.hunting_room_id);
    assert.equal(draft.settings.targets, original.data.settings.targets);
    assert.deepEqual(draft.settings.custom_extension, {keep_me: false});
    assert.equal((await api('read', {kind: 'plans', name: 'Control and pain'})).data.commands, 'incant 711');
    assert.equal((await api('read', {kind: 'plans', name: 'Everyday melee'})).data.commands, 'attack');
    assert.equal((await api('read', {kind: 'profiles', name: 'Other hunt'})).data.combat_plan, undefined, 'Creating a sequence does not save the hunt');
    await saveDraft(page);
    await editNamed(page, 'Other hunt');
    draft = await rawDraft(page);
    assert.equal(draft.combat_plan, 'Everyday melee');
    const beforeCopy = draft;
    await nav(page, 'Combat Plans');
    await library.getByRole('button', {name: 'Save a copy as another sequence', exact: true}).click();
    composer = page.locator('#new-combat-sequence');
    assert.equal(await composer.getByLabel('Original combat routine').inputValue(), 'attack');
    await composer.getByLabel('Sequence name', {exact: true}).fill('Another everyday sequence');
    await composer.getByRole('button', {name: 'Save universal sequence', exact: true}).click();
    await page.waitForFunction(() => document.querySelector('#status').textContent.includes('Saved universal sequence'));
    assert.deepEqual(await rawDraft(page), beforeCopy, 'Adding to the library does not change the default or creature assignments');
    assert.equal((await api('read', {kind: 'plans', name: 'Another everyday sequence'})).data.commands, 'attack');
  });
  await check('each creature selects any universal sequence or a private custom sequence', async (page) => {
    await editNamed(page, 'Sequence choices');
    await nav(page, 'Combat Plans');
    await page.getByRole('button', {name: 'Guided setup', exact: true}).click();
    const creatures = page.locator('#creature-sequences');
    await creatures.getByLabel('Sequence for fixture rat', {exact: true}).selectOption('plan:Usual combat');
    await creatures.getByLabel('Sequence for fixture troll', {exact: true}).selectOption('plan:No fire');
    await creatures.locator('.creature-sequence').filter({has: page.getByRole('heading', {name: 'fixture troll', exact: true})}).getByText('incant 711', {exact: true}).waitFor();
    await creatures.getByLabel('Sequence for fixture rat', {exact: true}).selectOption('custom');
    let composer = page.locator('#new-combat-sequence');
    await composer.getByRole('button', {name: 'Cancel new sequence', exact: true}).click();
    assert.equal(await creatures.getByLabel('Sequence for fixture rat', {exact: true}).inputValue(), 'plan:Usual combat');
    await creatures.getByLabel('Sequence for fixture rat', {exact: true}).selectOption('custom');
    composer = page.locator('#new-combat-sequence');
    assert.equal(await composer.getByLabel('Original combat routine').inputValue(), 'attack');
    await composer.getByText('Original routine text (advanced)', {exact: true}).click();
    await composer.getByLabel('Original combat routine').fill('incant 703 (once), incant 711');
    await composer.getByLabel('Original combat routine').press('Tab');
    await composer.getByRole('button', {name: 'Apply custom sequence to draft', exact: true}).click();
    await page.waitForFunction(() => document.querySelector('#status').textContent.includes('Custom sequence for fixture rat applied'));
    assert.equal(await creatures.getByLabel('Sequence for fixture rat', {exact: true}).inputValue(), 'custom');
    assert.equal(await creatures.getByLabel('Sequence for fixture troll', {exact: true}).inputValue(), 'plan:No fire');
    const rat = creatures.locator('.creature-sequence').filter({has: page.getByRole('heading', {name: 'fixture rat', exact: true})});
    await rat.getByText('incant 703 (once), incant 711', {exact: true}).waitFor();
    if (process.env.SETUP_SCREENSHOTS) await creatures.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/creature-sequences.png`});
    let draft = await rawDraft(page);
    assert.deepEqual(draft.creature_plans, {'fixture troll': 'No fire'});
    assert.equal(draft.settings.hunting_commands_c, 'keep untouched');
    assert.equal((await api('read', {kind: 'plans', name: 'Usual combat'})).data.commands, 'attack');
    assert.equal((await api('read', {kind: 'plans', name: 'No fire'})).data.commands, 'incant 711');
    const composed = await api('validate', {kind: 'profiles', data: draft});
    const ratSlot = composed.effective.targets.match(/fixture rat\(([a-j])\)/)[1];
    const trollSlot = composed.effective.targets.match(/fixture troll\(([a-j])\)/)[1];
    assert.notEqual(ratSlot, trollSlot);
    assert.equal(composed.effective[`hunting_commands_${ratSlot}`], 'incant 703 (once), incant 711');
    assert.equal(composed.effective[`hunting_commands_${trollSlot}`], 'incant 711');
    await saveDraft(page);
    await editNamed(page, 'Sequence choices');
    await nav(page, 'Combat Plans');
    await creatures.getByLabel('Sequence for fixture rat', {exact: true}).selectOption('plan:No fire');
    await page.waitForFunction(() => document.querySelector('#creature-sequences select')?.disabled === false);
    draft = await rawDraft(page);
    assert.deepEqual(draft.creature_plans, {'fixture troll': 'No fire', 'fixture rat': 'No fire'});
    assert.equal(draft.settings[`hunting_commands_${ratSlot}`], 'incant 703 (once), incant 711', 'Switching to a universal sequence preserves the old native routine');
  });
  await check('combat styles expose spell delivery, ranged, hiding, ambush and stance without changing unrelated settings', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.locator('#navigation').getByRole('button').filter({hasText: 'Combat approach'}).click();
    const editor = page.locator('section.card').filter({has: page.getByRole('heading', {name: 'Usual combat sequence', exact: true})});
    const add = editor.locator(':scope > .action-builder');
    await add.getByLabel('Action to add', {exact: true}).selectOption('incant');
    await add.getByLabel('Spell number', {exact: true}).fill('903');
    await add.getByLabel('Spell delivery', {exact: true}).selectOption('evoke');
    await add.getByLabel('Spell element', {exact: true}).selectOption('fire');
    await add.getByRole('button', {name: 'Add action', exact: true}).click();
    await add.getByLabel('Action to add', {exact: true}).selectOption('fire');
    assert.equal(await add.getByLabel('Aim body part', {exact: true}).count(), 0, 'Fire must not offer unsupported per-line aiming');
    await add.getByRole('button', {name: 'Add action', exact: true}).click();
    await add.getByLabel('Action to add', {exact: true}).selectOption('hide');
    await add.getByLabel('Maximum hide attempts').fill('4');
    await add.getByRole('button', {name: 'Add action', exact: true}).click();
    await add.getByLabel('Action to add', {exact: true}).selectOption('ambush');
    await add.getByLabel('Aim body part', {exact: true}).fill('right eye');
    await add.getByRole('button', {name: 'Add action', exact: true}).click();
    let row = editor.getByLabel('Action 4', {exact: true});
    await row.locator('summary').click();
    await row.getByLabel('Condition to add').selectOption('flag:hidden');
    await row.getByRole('button', {name: 'Add condition', exact: true}).click();
    await add.getByLabel('Action to add', {exact: true}).selectOption('stance');
    await add.getByLabel('Stance for this step').selectOption('defensive');
    await add.getByRole('button', {name: 'Add action', exact: true}).click();
    await add.getByLabel('Action to add', {exact: true}).selectOption('maneuver');
    await add.getByLabel('Technique', {exact: true}).selectOption('bullrush');
    await add.getByRole('button', {name: 'Add action', exact: true}).click();
    assert.equal(await editor.getByLabel('Original combat routine').inputValue(), '903 evoke fire, fire, hide 4, ambush right eye (hidden), stance defensive, bullrush');
    row = editor.getByLabel('Action 1', {exact: true});
    await row.locator('summary').click();
    await row.getByLabel('Step spell delivery', {exact: true}).selectOption('channel');
    await row.getByRole('button', {name: 'Update action', exact: true}).click();
    assert.match(await editor.getByLabel('Original combat routine').inputValue(), /^903 channel fire,/);
    const settings = page.locator('#combat-style-settings');
    await settings.locator(':scope > summary').click();
    await settings.getByLabel('Ranged aiming order', {exact: true}).fill('right eye, head');
    await settings.getByLabel('Ranged aiming order', {exact: true}).press('Tab');
    await settings.getByLabel('Stance before attacking', {exact: true}).selectOption('offensive');
    await settings.getByLabel('Hide before moving through hunting rooms', {exact: true}).selectOption('true');
    const draft = await rawDraft(page);
    assert.equal(draft.settings.archery_aim, 'right eye, head');
    assert.equal(draft.settings.hunting_stance, 'offensive');
    assert.equal(draft.settings.sneaky_sneaky, true);
    assert.equal(draft.settings.hunting_right_hand, undefined, 'Choosing an action must not change the weapon loadout');
  });
  await check('repeat on target is a capability gated explicit choice and persists through composition', async (page) => {
    await editNamed(page, 'Sequence choices');
    await nav(page, 'Combat Plans');
    await page.getByRole('button', {name: 'Guided setup', exact: true}).click();
    const editor = page.locator('section.card').filter({has: page.getByRole('heading', {name: 'Usual combat sequence', exact: true})});
    const row = editor.getByLabel('Action 1', {exact: true});
    await row.locator('summary').click();
    await row.getByLabel('Repetition rule').selectOption('untildead');
    assert.equal(await row.getByLabel('Times per pass').isDisabled(), true);
    assert.equal(await editor.getByLabel('Original combat routine').inputValue(), 'attack (untildead)');
    await row.getByLabel('Repetition rule').selectOption('once');
    assert.equal(await editor.getByLabel('Original combat routine').inputValue(), 'attack (once)');
    await row.getByLabel('Repetition rule').selectOption('cycle');
    assert.equal(await editor.getByLabel('Original combat routine').inputValue(), 'attack');
    await row.getByLabel('Repetition rule').selectOption('untildead');
    await page.getByRole('button', {name: 'Review & save', exact: true}).first().click();
    await page.getByRole('button', {name: 'Save to EOHunter', exact: true}).click();
    await page.waitForFunction(() => document.querySelector('#status').textContent.startsWith('Saved “'));
    assert.equal((await api('read', {kind: 'profiles', name: 'Sequence choices'})).data.settings.hunting_commands, 'attack (untildead)');
  });
  await check('older engines do not offer new repeat-on-target choices', async (page) => {
    await page.route('**/api', async (route) => {
      if (route.request().postDataJSON()?.action !== 'bootstrap') return route.continue();
      const response = await route.fetch();
      const data = await response.json();
      data.capabilities.repeat_until_target_gone = false;
      await route.fulfill({response, json: data});
    });
    await page.goto('about:blank');
    await page.goto(url);
    await page.waitForFunction(() => document.querySelector('#status').textContent.startsWith('Connected.'));
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.locator('#navigation').getByRole('button').filter({hasText: 'Combat approach'}).click();
    await page.getByRole('button', {name: 'Add action', exact: true}).click();
    const row = page.getByLabel('Action 1', {exact: true});
    await row.locator('summary').click();
    assert.equal(await row.locator('select[aria-label="Repetition rule"] option[value="untildead"]').count(), 0);
    assert.match(await row.innerText(), /does not advertise repeat-until-target-gone support/);
  });
  await check('guided action modifiers compile repeats and conditions and survive save and reopen', async (page) => {
    await editNamed(page, 'Sequence choices');
    await nav(page, 'Combat Plans');
    await page.getByRole('button', {name: 'Guided setup', exact: true}).click();
    const editor = page.locator('section.card').filter({has: page.getByRole('heading', {name: 'Usual combat sequence', exact: true})});
    const originalText = editor.getByLabel('Original combat routine');
    await editor.getByText('Original routine text (advanced)', {exact: true}).click();
    await originalText.fill('incant 719, incant 711, incant 705');
    await originalText.press('Tab');
    let row = editor.getByLabel('Action 1', {exact: true});
    await row.locator('summary').click();
    await row.getByLabel('Repetition rule').selectOption('once');
    row = editor.getByLabel('Action 2', {exact: true});
    await row.locator('summary').click();
    await row.getByLabel('Times per pass').fill('2');
    await row.getByLabel('Times per pass').press('Tab');
    await row.getByLabel('Condition value').fill('40');
    await row.getByRole('button', {name: 'Add condition', exact: true}).click();
    await row.getByLabel('Condition to add').selectOption('flag:stunned');
    await row.getByLabel('Condition comparison').selectOption('!');
    await row.getByRole('button', {name: 'Add condition', exact: true}).click();
    assert.equal(await originalText.inputValue(), 'incant 719 (once), incant 711 (m40 !stunned)(x2), incant 705');
    assert.match(await row.innerText(), /Mana \(points\): at least 40/);
    await row.getByLabel('Condition to add').selectOption('effect:EB');
    await row.getByLabel('Effect name').fill('Elemental Defense I');
    await row.getByRole('button', {name: 'Add condition', exact: true}).click();
    assert.match(await originalText.inputValue(), /EB"Elemental Defense I"/);
    await row.getByLabel('Condition to add').selectOption('delay');
    await row.getByLabel('Condition value').fill('12');
    await row.getByRole('button', {name: 'Add condition', exact: true}).click();
    const expected = await originalText.inputValue();
    if (process.env.SETUP_SCREENSHOTS) await editor.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/routine-modifiers.png`});
    await page.setViewportSize({width: 390, height: 800});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    await page.setViewportSize({width: 1400, height: 1000});
    await nav(page, 'Review & save');
    await page.getByRole('button', {name: 'Save to EOHunter', exact: true}).click();
    await page.waitForFunction(() => document.querySelector('#status').textContent.startsWith('Saved “'));
    assert.equal((await api('read', {kind: 'profiles', name: 'Sequence choices'})).data.settings.hunting_commands, expected);
    await editNamed(page, 'Sequence choices');
    await nav(page, 'Combat Plans');
    await page.getByRole('button', {name: 'Guided setup', exact: true}).click();
    assert.equal(await page.getByLabel('Original combat routine').inputValue(), expected);
    assert.match(await page.getByLabel('Action 2', {exact: true}).innerText(), /repeatdelay12/);
  });
  await check('imported opaque modifiers stay intact and editing another row never normalizes them', async (page) => {
    await editNamed(page, 'Role toggle fixture');
    await nav(page, 'Combat Plans');
    await page.getByRole('button', {name: 'Guided setup', exact: true}).click();
    await page.getByText('Original routine text (advanced)', {exact: true}).click();
    const text = page.getByLabel('Original combat routine');
    await text.fill('stance offensive and attack, attack (extensionXYZ), incant 711 (m40)(x2)');
    await text.press('Tab');
    assert.equal(await page.getByLabel('Action 1', {exact: true}).locator('.routine-controls').count(), 0);
    const row = page.getByLabel('Action 2', {exact: true});
    await row.locator('summary').click();
    assert.match(await row.innerText(), /Advanced native modifier: extensionXYZ/);
    await row.getByLabel('Condition value').fill('30');
    await row.getByRole('button', {name: 'Add condition', exact: true}).click();
    assert.equal(await text.inputValue(), 'stance offensive and attack, attack (extensionXYZ m30), incant 711 (m40)(x2)');
    await row.getByLabel('Times per pass').fill('0');
    await row.getByLabel('Times per pass').press('Tab');
    assert.match(await row.locator('.routine-controls > .error-text').innerText(), /1 to 100/);
    assert.equal(await text.inputValue(), 'stance offensive and attack, attack (extensionXYZ m30), incant 711 (m40)(x2)');
  });
  await check('possible visitors support target and sequence choices without changing the selected plane', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('The Rift::plane-5');
    const visitors = page.locator('section.card').filter({has: page.getByRole('heading', {name: 'Can also appear here', exact: true})});
    await visitors.getByText('enormous rift crawler', {exact: true}).waitFor();
    assert.match(await visitors.innerText(), /Can burrow from Plane 4/);
    assert.equal(await visitors.getByRole('link', {name: 'Encounter source', exact: true}).getAttribute('href'), 'https://gswiki.play.net/The_Rift/saved_posts#Preview');
    const map = page.locator('#footprint-map-picker');
    await map.locator('[data-room-id="6"].selected-room').waitFor();
    const selected = () => map.locator('[data-room-id].selected-room').evaluateAll((rooms) => rooms.map((room) => room.dataset.roomId));
    const before = await selected();
    assert.deepEqual(before, ['6']);
    await page.getByLabel('Response to plane five creature', {exact: true}).selectOption('hunt');
    const response = page.getByLabel('Response to enormous rift crawler', {exact: true});
    for (const policy of ['hunt', 'ignore', 'flee', 'hunt']) {
      await response.selectOption(policy);
      assert.deepEqual(await selected(), before);
    }
    await roomAction(page, '#footprint-map-picker', 6, 'Starting room');
    await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Combat approach →', exact: true}).click();
    await page.getByLabel('Sequence for enormous rift crawler', {exact: true}).selectOption('plan:No fire');
    await page.waitForFunction(() => document.querySelector('#creature-sequences select')?.disabled === false);
    const draft = await rawDraft(page);
    assert.equal(draft.creature_plans['enormous rift crawler'], 'No fire');
    assert.deepEqual(draft.area_provenance.room_ids, [6]);
    assert.equal(draft.settings.hunting_boundaries, '5');
    assert.equal(draft.settings.hunting_room_id, '6');
    assert.match(draft.settings.targets, /enormous rift crawler/);
  });
  await check('new universal sequences reject overwrite and preserve a cancelled hunt draft', async (page) => {
    await editNamed(page, 'Other hunt');
    const before = await rawDraft(page);
    await nav(page, 'Combat Plans');
    await page.locator('#combat-sequences').getByRole('button', {name: 'Add sequence', exact: true}).click();
    const composer = page.locator('#new-combat-sequence');
    await composer.getByLabel('Sequence name', {exact: true}).fill('Usual combat');
    await composer.getByRole('button', {name: 'Add action', exact: true}).click();
    await composer.getByRole('button', {name: 'Save universal sequence', exact: true}).click();
    await composer.getByText(/Save conflict:/).waitFor();
    assert.equal(await composer.getByLabel('Sequence name', {exact: true}).inputValue(), 'Usual combat');
    await composer.getByRole('button', {name: 'Cancel new sequence', exact: true}).click();
    assert.deepEqual(await rawDraft(page), before);
    assert.equal((await api('read', {kind: 'plans', name: 'Usual combat'})).data.commands, 'attack');
  });
  await check('late custom creature composition cannot overwrite a newer draft edit', async (page) => {
    await editNamed(page, 'Sequence choices');
    await nav(page, 'Combat Plans');
    await page.getByLabel('Sequence for fixture rat', {exact: true}).selectOption('custom');
    const gate = await delayResponse(page, (request) => request.action === 'creature_sequence');
    try {
      await page.getByRole('button', {name: 'Apply custom sequence to draft', exact: true}).click();
      await within(gate.captured, 'The custom-sequence response was not intercepted');
      const newer = await rawDraft(page);
      newer.settings.fried = 93;
      await page.locator('#raw-json').fill(JSON.stringify(newer));
      const completed = page.waitForResponse((response) => response.request().postDataJSON()?.action === 'creature_sequence');
      gate.release(); await completed;
      await page.waitForFunction(() => document.querySelector('#status').textContent.includes('hunt draft changed'));
      assert.deepEqual(await rawDraft(page), newer);
      await nav(page, 'Combat Plans');
      await page.locator('#new-combat-sequence').getByText('The hunt draft changed. Review it and apply this custom sequence again.', {exact: true}).waitFor();
    } finally { gate.release(); }
  });
  await check('late area previews cannot overwrite a different draft', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    const gate = await delayResponse(page, (request) => request.action === 'area');
    try {
      await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
      await page.getByLabel('Hunting area', {exact: true}).selectOption('Fixture area (not game data)');
      await within(gate.captured, 'Area response was not intercepted');
      await editNamed(page, 'Other hunt');
      const completed = page.waitForResponse((response) => response.request().postDataJSON()?.action === 'area');
      gate.release();
      await completed;
      await nav(page, 'Area & creatures');
      assert.equal(await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).count(), 0);
      assert.equal(await page.locator('#draft-name').textContent(), 'Other hunt');
    } finally { gate.release(); }
  });
  await check('a late profile map cannot overwrite geometry edited while it was loading', async (page) => {
    const gate = await delayResponse(page, (request) => request.action === 'profile_map');
    try {
      await editNamed(page, 'Other hunt');
      await within(gate.captured, 'Profile map was not intercepted');
      await page.locator('#field-hunting_room_id').fill('3');
      await page.locator('#field-hunting_room_id').press('Tab');
      await page.locator('#profile-map [data-room-id="3"].starting-room').waitFor();
      const completed = page.waitForResponse((response) => response.request().postDataJSON()?.action === 'profile_map' && response.request().postDataJSON()?.settings?.hunting_room_id === 2);
      gate.release(); await completed;
      await nav(page, 'Area & creatures');
      assert.equal(await page.locator('#profile-map [data-room-id="3"].starting-room').count(), 1);
      assert.equal((await rawDraft(page)).settings.hunting_room_id, '3');
    } finally { gate.release(); }
  });
  await check('target changes preserve area geometry during an in-flight recalculation', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('Fixture area (not game data)');
    await page.getByLabel('Response to fixture rat', {exact: true}).selectOption('hunt');
    const gate = await delayResponse(page, (request) => request.action === 'area' && !!request.room_ids);
    try {
      await page.getByRole('button', {name: 'Recalculate boundaries for selected rooms', exact: true}).click();
      await within(gate.captured, 'Footprint suggestion was not intercepted');
      await page.getByLabel('Response to fixture rat', {exact: true}).selectOption('ignore');
      const completed = page.waitForResponse((response) => response.request().postDataJSON()?.action === 'area' && !!response.request().postDataJSON()?.room_ids);
      gate.release(); await completed;
      await nav(page, 'Area & creatures');
      await page.locator('#footprint-count').waitFor();
      assert.match(await page.locator('#footprint-count').innerText(), /2 proposed hunting rooms/);
      assert.equal((await rawDraft(page)).settings.hunting_boundaries, undefined);
    } finally { gate.release(); }
  });
  await check('missing classic artwork reports an error without inventing a diagram', async (page) => {
    await page.route('**/api', async (route) => {
      if (route.request().postDataJSON()?.action === 'map_image') await route.fulfill({status: 422, contentType: 'application/json', body: JSON.stringify({error: 'Classic map is not installed.'})});
      else await route.continue();
    });
    await editNamed(page, 'Other hunt');
    await page.getByText(/Classic map unavailable:/).waitFor();
    assert.equal(await page.locator('#profile-map svg').count(), 0);
    await page.getByText('Find a room by name or number', {exact: true}).click();
    await page.getByLabel('Find profile map room', {exact: true}).fill('3');
    await page.getByRole('button', {name: '#3 · Fixture room 3', exact: true}).click();
    await page.getByRole('menuitemcheckbox', {name: 'Starting room', exact: true}).click();
    assert.equal((await rawDraft(page)).settings.hunting_room_id, '3', 'Room-list fallback stays usable');
  });
  await check('guided region preview appears on the right before area selection and highlights only the selected zone', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    const preview = page.locator('#region-map-preview');
    await preview.locator('svg').waitFor();
    assert.equal(await preview.locator('.selected-room').count(), 0);
    const controlsBox = await page.locator('.area-controls').boundingBox(), mapBox = await preview.boundingBox();
    assert.ok(mapBox.x >= controlsBox.x + controlsBox.width, 'Desktop map must be to the right of area controls');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('The Rift::plane-5');
    await preview.locator('[data-room-id="6"].selected-room').waitFor();
    assert.equal(await preview.locator('[data-room-id="5"].selected-room').count(), 0);
    await page.getByLabel('Hunting area', {exact: true}).selectOption('The Rift::plane-3');
    await preview.locator('[data-room-id="5"].selected-room').waitFor();
    assert.equal(await preview.locator('[data-room-id="6"].selected-room').count(), 0);
    if (process.env.SETUP_SCREENSHOTS) await page.screenshot({path: `${process.env.SETUP_SCREENSHOTS}/region-preview.png`});
    await page.getByLabel('Hunting area', {exact: true}).selectOption('');
    await preview.locator('svg').waitFor();
    assert.equal(await preview.locator('.selected-room').count(), 0);
    await page.setViewportSize({width: 800, height: 900});
    const mobileControls = await page.locator('.area-controls').boundingBox(), mobileMap = await preview.boundingBox();
    assert.ok(mobileMap.y + mobileMap.height <= mobileControls.y + 1, 'Narrow screens stack the preview above controls');
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    const draft = await rawDraft(page);
    assert.equal(draft.settings.hunting_room_id, undefined, 'Browsing regions and zones must not apply geometry');
  });

  await check('leaving a region ignores a delayed map preview response', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    const gate = await delayResponse(page, (request) => request.action === 'profile_map' && request.sheet === 'fixture-only.png');
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await within(gate.captured, 'Region map request did not reach the backend');
    await page.getByLabel('Map or region', {exact: true}).selectOption('');
    const completed = page.waitForResponse((response) => response.request().postDataJSON()?.action === 'profile_map' && response.request().postDataJSON()?.sheet === 'fixture-only.png');
    gate.release();
    await completed;
    await page.locator('#region-map-preview').getByText(/Choose a map \/ region/).waitFor();
    assert.equal(await page.locator('#region-map-preview svg').count(), 0);
  });

  await check('map, named hunting area, then creatures keeps a shared monster inside one plane', async (page) => {
    await page.getByRole('button', {name: 'Create with guidance', exact: true}).click();
    await page.getByRole('button', {name: 'Continue: Area & creatures →', exact: true}).click();
    assert.equal(await page.getByLabel('Hunting area', {exact: true}).isDisabled(), true);
    await page.getByLabel('Map or region', {exact: true}).selectOption('fixture-only.png');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('The Rift::plane-5');
    await page.getByLabel('Response to shared plane creature', {exact: true}).waitFor();
    assert.equal(await page.getByLabel('Response to plane three creature', {exact: true}).count(), 0);
    await page.getByLabel('Response to shared plane creature', {exact: true}).selectOption('hunt');
    await page.getByRole('button', {name: 'Reset to suggested area rooms', exact: true}).click();
    await page.getByLabel('Choose a mapped starting room', {exact: true}).selectOption('6');
    await page.getByRole('button', {name: 'Show full classic map', exact: true}).waitFor();
    assert.ok(await page.locator('#footprint-map-picker svg').first().evaluate((node) => node.getBoundingClientRect().height <= 581), 'Focused area should fit the map viewport without vertical scrolling');
    await page.getByRole('button', {name: 'Show full classic map', exact: true}).click();
    await page.getByRole('button', {name: 'Focus selected hunting area', exact: true}).click();
    await page.getByRole('button', {name: 'Apply this hunting footprint', exact: true}).click();
    const applied = await rawDraft(page);
    assert.equal(applied.area_zone, 'plane-5');
    assert.deepEqual(applied.area_provenance.room_ids, [6]);
    assert.equal(applied.settings.hunting_boundaries, '5');
    assert.equal(applied.settings.targets, 'shared plane creature(a)');
    await nav(page, 'Area & creatures');
    await page.getByLabel('Hunting area', {exact: true}).selectOption('The Rift::plane-3');
    await page.getByRole('button', {name: 'Preview selected area', exact: true}).click();
    await page.getByLabel('Response to plane three creature', {exact: true}).waitFor();
    await page.getByRole('button', {name: 'Reset to suggested area rooms', exact: true}).click();
    await page.getByLabel('Choose a mapped starting room', {exact: true}).selectOption('5');
    const notApplied = await rawDraft(page);
    assert.equal(notApplied.settings.hunting_room_id, '6', 'Changing subarea only previews; it cannot overwrite approved geometry');
    assert.equal(notApplied.area_zone, 'plane-5');
  });
  console.log(`${results.filter((result) => result.passed).length}/${results.length} setup browser checks passed.`);
  if (results.some((result) => !result.passed)) process.exitCode = 1;
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  if (fixture.exitCode === null) {
    fixture.kill('SIGTERM');
    const force = setTimeout(() => fixture.kill('SIGKILL'), 3000);
    await exited;
    clearTimeout(force);
  }
}
