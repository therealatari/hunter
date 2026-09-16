/* EOHunter setup. Local assets, a single draft, and no game-action transport. */
'use strict';
(() => {
  const $ = (id) => document.getElementById(id);
  const clone = (value) => JSON.parse(JSON.stringify(value));
  const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  const pretty = (value) => JSON.stringify(value, null, 2);
  const token = new URLSearchParams(location.hash.slice(1)).get('token') || '';
  history.replaceState(null, '', location.pathname + location.search);
  const pages = [
    ['Guided setup', 'character', 'Character & equipment'],
    ['Profiles', 'manage', 'Manage profiles'], ['Profiles', 'compare', 'Compare'],
    ['Hunting & recovery', 'area', 'Area & creatures'], ['Hunting & recovery', 'behavior', 'Hunting behavior'],
    ['Hunting & recovery', 'rest', 'Rest & services'], ['Hunting & recovery', 'recovery', 'Recovery & emergencies'],
    ['Hunting & recovery', 'monitoring', 'Monitoring & limits'], ['Combat & equipment', 'combat', 'Combat Plans'],
    ['Combat & equipment', 'equipment', 'Equipment'], ['Combat & equipment', 'buffs', 'Buffs'],
    ['Combat & equipment', 'items', 'Item preparations'], ['Hunting with others', 'group', 'Group Hunt'],
    ['Hunting with others', 'team', 'Multi-Account Team'], ['Expert tools', 'raw', 'Raw configuration'],
    ['Expert tools', 'review', 'Review & save']
  ];
  const descriptions = {
    character: 'Start with your character’s usual equipment. You can reuse it in other hunts later.',
    area: 'Choose the overall map, then a hunting area within it, then the creatures you want to hunt.',
    behavior: 'Set how this character moves, chooses targets, and handles the hunting room.',
    rest: 'Choose return and rest destinations, and the commands and services used there.',
    recovery: 'Configure this character’s recovery responses. Explicit Hunter settings override compatibility inputs.',
    monitoring: 'Decide when to return and when to leave rest. Check the units beside each setting.',
    combat: 'Choose a reusable or custom sequence for each creature, with a hunt default for anything without its own choice.',
    equipment: 'Choose the hands, loadouts, and equipment rules used by this character.',
    buffs: 'Configure the installed combat-buff policy. New dispel-specific recovery options require engine support.',
    items: 'Configure supported named preparations. Keep custom actions and confirmations intact.',
    group: 'Configure this character’s behavior alongside other players. These settings cannot start their scripts.',
    team: 'Configure local hunting behavior for a coordinated team. Participation must be enabled separately on each member.'
  };
  const state = {boot: null, draft: {schema_version: 1, settings: {}}, baseline: {schema_version: 1, settings: {}},
    kind: 'profile', name: '', loadedName: '', revision: null, source: 'native', page: 'manage', guided: false,
    mode: 'solo', validation: null, generation: 0, invalid: new Map(), area: null, areaName: '', mapName: '', zoneId: '', areas: null,
    disconnected: false, saving: false, documentId: 0, readRequest: 0, resolveRequest: 0, validationGeneration: -1, resolving: false,
    areaRequest: 0, loadingAreas: false, playContext: 'solo', anyTargets: false,
    footprintRequest: 0, footprint: null, footprintBase: null, footprintNames: [], footprintRooms: [], footprintStart: '', footprintBusy: false,
    mapOpen: true, footprintRest: {}, footprintBoundaries: [], mapMessage: '', footprintUndo: [],
    profileMap: null, profileMapKey: '', profileMapRequest: 0, profileMapBusy: false, profileMapSheet: '', profileMapMessage: '',
    profileRoomRequest: 0, profileRoomBusy: null, mapUndo: [], sequenceDraft: null};
  const guide = [
    ['character', 'Your character', 'Equipment & usual settings'], ['area', 'Area & creatures', 'Where and what to hunt'],
    ['combat', 'Combat approach', 'Usual sequence & exceptions'], ['rest', 'Rest & recovery', 'When to return and recover'],
    ['review', 'Review & save', 'Check the whole plan']
  ];
  const combatOptions = ['tier3', 'aim', 'uac_smite', 'uac_mstrike', 'mstrike_mob', 'mstrike_cooldown', 'mstrike_quickstrike', 'mstrike_stamina_cooldown', 'mstrike_stamina_quickstrike'];
  const wandOptions = ['wand', 'fresh_wand_container', 'dead_wand_container', 'wand_if_oom'];
  const orderedFields = new Set(['resting_commands', 'resting_scripts', 'hunting_prep_commands', 'hunting_scripts',
    'field_rest_commands', 'field_rest_scripts', 'field_hunting_prep_commands', 'custom_fog']);
  function el(tag, attributes = {}, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attributes)) {
      if (key === 'class') node.className = value;
      else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
      else if (key === 'text') node.textContent = value;
      else if (key === 'checked' || key === 'disabled' || key === 'hidden') node[key] = value;
      else node.setAttribute(key, value);
    }
    for (const child of children.flat()) if (child !== null && child !== undefined) node.append(child.nodeType ? child : document.createTextNode(String(child)));
    return node;
  }
  function button(label, click, css = '') { return el('button', {type: 'button', class: css, onclick: click}, label); }
  function detailsPanel(key, title, ...children) {
    state.panels ||= {};
    const panel = el('details', {class: 'card', ...(state.panels[key] ? {open: ''} : {})}, el('summary', {}, title), ...children);
    panel.addEventListener('toggle', () => { if (panel.isConnected) state.panels[key] = panel.open; });
    return panel;
  }
  function note(message, style = '') { return el('div', {class: `notice ${style}`}, message); }
  function status(message, error = false) { $('status').textContent = message; $('status').className = error ? 'error' : ''; }
  function fail(error) { status(error.message || String(error), true); }
  async function api(action, args = {}) {
    if (state.disconnected) throw new Error('This setup session has disconnected. Open setup again in Lich; your draft is still visible here.');
    if (args.kind) args = {...args, kind: {profile: 'profiles', plan: 'plans'}[args.kind] || args.kind};
    let response;
    try { response = await fetch('/api', {method: 'POST', credentials: 'same-origin', headers: {'Content-Type': 'application/json', 'X-Setup-Token': token}, body: JSON.stringify({action, ...args})}); }
    catch (_) { state.disconnected = true; throw new Error('Connection lost. Keep this window to copy your draft, and reopen setup from the same character.'); }
    const result = await response.json();
    if (!response.ok || result.error) {
      if (response.status === 401 || response.status === 403) state.disconnected = true;
      throw new Error(result.kind === 'Conflict' ? `Save conflict: ${result.error}. Your draft is preserved. Compare it with the current saved version or save under a new name.` : result.error || `Request failed (${response.status}).`);
    }
    return result;
  }
  function normalizedPage(value) {
    const aliases = {hunting: 'behavior', preparations: 'items', profiles: 'manage', plans: 'combat', 'combat_plans': 'combat', 'area_creatures': 'area', 'multi_account': 'team'};
    const key = String(value || 'raw').toLowerCase().replace(/[^a-z0-9]+/g, '_');
    return aliases[key] || (pages.find((p) => p[1] === key || p[2].toLowerCase().replace(/[^a-z0-9]+/g, '_') === key) || [null, 'raw'])[1];
  }
  function names(values) { return (values || []).map((x) => typeof x === 'string' ? x : x.name); }
  function dirty() { return Boolean(state.sequenceDraft) || pretty(state.draft) !== pretty(state.baseline) || state.name !== state.loadedName || state.invalid.size > 0; }
  function changed() {
    state.generation += 1; state.validationGeneration = -1; updateHeader();
    queueMicrotask(() => {
      if ($('profile-map') && state.profileMapKey !== profileMapKey()) {
        const replacement = document.createElement('div'); renderProfileMap(replacement); $('profile-map').replaceWith(...replacement.childNodes);
      }
    });
  }
  function updateHeader() {
    $('draft-name').textContent = state.name || `Untitled ${state.kind === 'defaults' ? 'character setup' : state.kind === 'plan' ? 'Combat Plan' : 'hunt'}`;
    $('scope').textContent = state.kind === 'defaults' ? 'SHARED CHARACTER DEFAULTS' : state.kind === 'plan' ? 'SHARED COMBAT PLAN' : 'HUNT PROFILE';
    $('dirty').textContent = state.source === 'legacy' ? 'Legacy copy · not saved to Hunter' : dirty() ? 'Unsaved changes' : state.revision ? 'Saved revision' : 'New draft';
    $('guided-toggle').textContent = state.guided ? 'Advanced editor' : 'Guided setup';
    $('guided-toggle').disabled = state.kind !== 'profile';
    document.body.classList.toggle('guided', state.guided);
  }
  function set(key, value) { state.draft.settings[key] = value; changed(); }
  function effective(key) { return own(state.draft.settings || {}, key) ? state.draft.settings[key] : state.validation?.effective?.[key] ?? state.boot.fields.find((f) => f.key === key)?.default; }
  async function validate() {
    if (state.invalid.size) throw new Error('Correct the invalid JSON fields before checking or saving this draft.');
    if (state.kind === 'plan') return {errors: [], warnings: ['Combat Plans are validated in the context of a hunt.'], effective: {}, provenance: {}};
    const generation = state.generation;
    const result = await api('validate', {data: state.draft, kind: state.kind, mode: state.mode, area: state.draft.area});
    if (generation !== state.generation) throw new Error('The draft changed during validation. Check it again.');
    state.validation = result; state.validationGeneration = generation;
    return result;
  }
  async function resolveInheritance() {
    const documentId = state.documentId, request = ++state.resolveRequest;
    state.resolving = true; state.validation = null; render();
    try { await validate(); }
    catch (error) { fail(error); }
    finally { if (documentId === state.documentId && request === state.resolveRequest) { state.resolving = false; render(); } }
  }
  function steps() { return guide.map(([id]) => id); }
  function renderNav() {
    const nav = $('navigation'); nav.replaceChildren(); let section;
    if (state.guided) {
      nav.append(el('h2', {}, 'YOUR HUNT JOURNAL'));
      guide.forEach(([id, label, hint], index) => {
        const item = button('', () => navigate(id), 'guide-step');
        item.append(el('span', {class: 'step-number', 'aria-hidden': 'true'}, index + 1), el('span', {}, el('strong', {}, label), el('small', {}, hint)));
        if (id === state.page) item.setAttribute('aria-current', 'page');
        nav.append(item);
      });
      nav.append(button('Back to saved hunts', () => { state.guided = false; navigate('manage'); }, 'back-to-profiles'));
    } else for (const [group, id, label] of pages.filter(([group]) => group !== 'Guided setup')) {
      if (section !== group) { nav.append(el('h2', {}, group)); section = group; }
      const item = button(label, () => navigate(id));
      if (id === state.page) item.setAttribute('aria-current', 'page');
      nav.append(item);
    }
    // One progress navigation, not a second row of competing tabs.
    $('wizard').hidden = true;
    $('wizard').replaceChildren();
  }
  function navigate(page, focusKey) {
    if (focusKey || (state.guided && !steps().includes(page))) state.guided = false;
    state.page = page; render();
    $('sidebar').classList.remove('open'); $('nav-toggle').setAttribute('aria-expanded', 'false');
    $('content-pane').scrollTop = 0;
    const control = focusKey && $(`field-${focusKey}`);
    if (control) { let parent = control.parentElement; while (parent) { if (parent.tagName === 'DETAILS') parent.open = true; parent = parent.parentElement; } control.focus({preventScroll: true}); control.scrollIntoView({block: 'center'}); }
    else $('main').focus({preventScroll: true});
  }
  function render() {
    dismissRoomActions?.();
    if (!state.boot) return;
    updateHeader(); renderNav();
    const main = $('main'); main.replaceChildren();
    main.classList.toggle('area-workspace', state.guided && state.page === 'area');
    const step = guide.find(([id]) => id === state.page);
    main.append(el('span', {class: 'eyebrow'}, state.guided ? `CHAPTER ${steps().indexOf(state.page) + 1} OF 5 · YOUR NEXT HUNT` : 'YOUR NEXT HUNT'), el('h1', {}, state.guided ? step[1] : pages.find((p) => p[1] === state.page)[2]));
    if (descriptions[state.page]) main.append(el('p', {class: 'intro'}, descriptions[state.page]));
    if (state.kind !== 'profile' && !['manage', 'raw', 'review', 'compare'].includes(state.page)) main.append(note(`You are editing a shared ${state.kind === 'plan' ? 'Combat Plan' : 'character setup'}. Saved changes apply to linked hunts on their next launch.`));
    if (state.page === 'manage') renderManage(main);
    else if (state.page === 'raw') renderRaw(main);
    else if (state.page === 'review') renderReview(main);
    else if (state.page === 'compare') renderCompare(main);
    else if (state.kind === 'plan') renderPlanCommands(main);
    else if (state.guided && state.page === 'character') renderCharacter(main);
    else {
      if (state.page === 'area') { renderArea(main); renderBoons(main); }
      if (state.page === 'combat') renderCombat(main);
      if (state.page === 'equipment') main.append(fieldSection('Wands and spell fallback', wandOptions));
      if (state.page === 'rest') renderReturnOptions(main);
      if (state.page === 'buffs') renderBuffs(main);
      if (state.page === 'monitoring') renderInjuryRule(main);
      if (state.page === 'team') renderTeam(main);
      if (['group', 'team'].includes(state.page)) main.append(modeControl());
      if (state.guided) renderGuidedFields(main, state.page);
      else renderFields(main, state.page);
    }
    if (state.guided) {
      const sequence = steps(), index = sequence.indexOf(state.page);
      const bar = el('div', {class: 'wizard-bottom'});
      if (index > 0) bar.append(button('← Previous', () => navigate(sequence[index - 1])));
      if (index < sequence.length - 1) bar.append(button(`Continue: ${guide[index + 1][1]} →`, () => navigate(sequence[index + 1]), 'primary'));
      if (bar.children.length) main.append(bar);
    }
  }
  function modeControl() {
    const select = el('select', {'aria-label': 'Participation validation mode'});
    [['solo', 'My character only (solo engine mode)'], ['head', 'Coordinated leader (head mode)'], ['tail', 'Coordinated follower (tail mode)']].forEach(([value, label]) => select.append(el('option', {value}, label)));
    select.value = state.mode;
    select.addEventListener('change', () => { state.mode = select.value; changed(); renderNav(); });
    return el('div', {class: 'field'}, el('label', {}, 'Check compatibility for this engine role', select), el('p', {class: 'help'}, 'Validation only: this is not saved as a launch role. Joining someone’s party does not mean they participate in coordinated automation.'));
  }
  function discardOkay() {
    if (state.saving) { status('Wait for this save to finish before switching configurations.', true); return false; }
    return !dirty() || window.confirm('Replace the current unsaved draft? Copy it from Raw configuration first if you want to keep it.');
  }
  function fresh(kind = 'profile', guided = false) {
    if (!discardOkay()) return;
    state.documentId += 1; state.readRequest += 1; state.validation = null;
    Object.assign(state, {kind, name: '', loadedName: '', revision: null, source: 'native', draft: kind === 'plan' ? {commands: ''} : {schema_version: 1, settings: {}}, area: null, areaName: '', mapName: '', zoneId: '', guided, anyTargets: false, playContext: 'solo', mode: 'solo', sequenceDraft: null});
    invalidateFootprint();
    resetProfileMap();
    state.areaRequest += 1;
    state.baseline = clone(state.draft); state.invalid.clear(); changed(); navigate(guided ? 'character' : kind === 'plan' ? 'combat' : 'equipment');
  }
  async function open(kind, name, source = 'native') {
    if (!discardOkay()) return;
    const readRequest = ++state.readRequest;
    try {
      const result = await api('read', {kind, name, source});
      if (readRequest !== state.readRequest || state.saving) return;
      state.documentId += 1; state.validation = null;
      let data = clone(result.data);
      if (kind !== 'plan' && !own(data, 'settings')) data = {schema_version: 1, settings: data};
      Object.assign(state, {kind, draft: data, baseline: clone(data), name, loadedName: name, revision: source === 'legacy' ? null : result.revision, source, area: null, areaName: data.area || '', mapName: data.area_map || '', zoneId: data.area_zone || '', guided: false, anyTargets: false, sequenceDraft: null});
      state.areaRequest += 1;
      invalidateFootprint();
      resetProfileMap();
      state.invalid.clear(); changed();
      if (kind !== 'plan') { try { await validate(); } catch (error) { fail(error); } }
      if (readRequest !== state.readRequest) return;
      navigate(kind === 'plan' ? 'combat' : kind === 'defaults' ? 'equipment' : 'area');
      status(source === 'legacy' ? 'Opened a compatibility source. Saving creates an EOHunter-owned copy; the source stays untouched.' : `Opened ${name}.`);
    } catch (error) { fail(error); }
  }
  function renderManage(main) {
    main.append(el('p', {class: 'intro'}, 'Build a new hunt step by step, or pick a saved hunt below to adjust it. Nothing runs while you are setting up.'));
    main.append(el('section', {class: 'card welcome'}, el('span', {class: 'eyebrow'}, 'START HERE'), el('h2', {}, 'Where will you hunt next?'), el('p', {}, 'Five short steps: your character, your hunting area, combat, recovery, and a final check.'), button('Create with guidance', () => fresh('profile', true), 'primary')));
    main.append(el('details', {class: 'card'}, el('summary', {}, 'Reusable settings & current draft'), el('p', {class: 'help'}, 'Optional: share your usual equipment and combat approach across several hunts.'), el('div', {class: 'actions'}, button('New character setup', () => fresh('defaults')), button('New Combat Plan', () => fresh('plan'))), nameControl(), modeControl(), button('Edit this hunt’s settings', () => navigate('area')), button('Save as another profile (keeps links)', () => { if (state.saving) return status('Wait for the save to finish before copying.', true); state.documentId += 1; state.readRequest += 1; state.revision = null; state.loadedName = ''; state.name = state.name ? `${state.name}-copy` : ''; state.source = 'native'; changed(); render(); })));
    for (const [title, kind, list, source] of [['Saved hunts', 'profile', state.boot.profiles, 'native'], ['Character defaults', 'defaults', state.boot.defaults, 'native'], ['Combat Plans', 'plan', state.boot.plans, 'native'], ['Copy a legacy profile', 'profile', state.boot.legacy_profiles, 'legacy']]) {
      const section = el('section', {class: 'card'}, el('h2', {}, title));
      if (!names(list).length) section.append(el('p', {class: 'empty'}, 'None found for this character.'));
      else section.append(el('div', {class: 'list'}, names(list).map((name) => el('div', {class: 'list-item'}, el('div', {class: 'grow'}, el('strong', {}, name), el('span', {class: 'small muted'}, source === 'legacy' ? 'Read-only compatibility source' : 'EOHunter-owned')), button(source === 'legacy' ? 'Open as copy' : 'Edit', () => open(kind, name, source))))));
      main.append(section);
    }
  }
  function nameControl() {
    const input = el('input', {id: 'save-name', type: 'text', value: state.name, placeholder: 'e.g. Rift evening hunt', autocomplete: 'off'});
    input.addEventListener('input', () => { state.name = input.value; changed(); });
    return el('div', {class: 'field'}, el('label', {for: 'save-name'}, state.kind === 'profile' ? 'Hunt name' : state.kind === 'defaults' ? 'Character setup name' : 'Combat Plan name'), input, el('p', {class: 'help'}, 'A new name creates a separate EOHunter file. Existing names require their current saved revision.'));
  }
  function fieldSection(title, keys) {
    const fields = keys.map((key) => state.boot.fields.find((field) => field.key === key)).filter(Boolean);
    return el('section', {class: 'card'}, el('h2', {}, title), el('div', {class: 'field-grid'}, fields.map(fieldControl)));
  }
  function renderCharacter(main) {
    main.append(el('section', {class: 'card'}, el('h2', {}, `A hunt for ${state.boot.context?.character || 'this character'}`), nameControl(), referenceSelect('defaults', 'Start from my saved character defaults', state.boot.defaults)));
    renderNotes(main);
    const context = el('select', {'aria-label': 'How will you hunt?'}, [['solo', 'Solo Hunt'], ['group', 'Group Hunt'], ['team', 'Multi-Account Team']].map(([value, label]) => el('option', {value}, label)));
    context.value = state.playContext;
    context.addEventListener('change', () => { state.playContext = context.value; if (context.value === 'solo') state.mode = 'solo'; changed(); render(); });
    const card = el('section', {class: 'card'}, el('h2', {}, 'Who is coming?'), el('label', {class: 'control-label'}, 'How will you hunt?', context));
    card.append(el('p', {class: 'help'}, state.playContext === 'group' ? 'Other people control their own characters. This editor only changes your character’s profile; it does not enroll or control your friends.' : state.playContext === 'team' ? 'You control multiple accounts. Each character still needs its own profile and explicit local participation setup. This selection does not start or configure the other members.' : 'Configure this character to hunt independently.'));
    if (state.playContext !== 'solo') card.append(modeControl(), button('Open advanced group settings', () => navigate(state.playContext === 'team' ? 'team' : 'group')));
    main.append(card, fieldSection('What should be in your hands?', ['hunting_right_hand', 'hunting_left_hand']),
      el('section', {class: 'card'}, el('h2', {}, 'Buffs for this character'), el('p', {class: 'help'}, 'Choose learned society abilities to keep active, configure mana recovery, or review missing-buff policies.'), button('Choose buffs and society abilities', () => navigate('buffs'))));
  }
  function renderGuidedFields(main, page) {
    if (page === 'area') {
      main.append(el('details', {class: 'card'}, el('summary', {}, 'Manual route overrides'), fieldSection('Use room numbers from your map', ['hunting_room_id', 'hunting_boundaries'])));
    } else if (page === 'combat') {
      main.append(fieldSection('How many creatures can you handle?', ['flee_count']));
    } else if (page === 'rest') {
      renderInjuryRule(main);
      main.append(fieldSection('Where will you recover?', ['resting_room_id', 'field_rest_room_id']),
        fieldSection('When should you return?', ['fried', 'oom', 'encumbered']),
        fieldSection('What happens at rest?', ['resting_scripts', 'resting_commands']),
        fieldSection('When should hunting resume?', ['rest_till_exp', 'rest_till_mana']));
      const details = detailsPanel('more-recovery', 'More recovery options');
      details.append(fieldSection('Preparation before departure', ['hunting_prep_commands', 'hunting_scripts']),
        fieldSection('Nearby field-rest services (solo only)', ['field_rest_for', 'field_rest_commands', 'field_rest_scripts', 'field_hunting_prep_commands', 'field_rest_timeout_seconds', 'after_town_rest']),
        fieldSection('Additional departure requirements', ['rest_till_spirit', 'rest_till_percentstamina']),
        el('p', {class: 'help'}, 'Emergency responses and missing-buff policies remain in their own settings pages.'), button('Recovery & emergencies', () => navigate('recovery')), button('Buffs', () => navigate('buffs')));
      main.append(details);
    }
  }
  function fieldControl(field) {
    const key = field.key, local = own(state.draft.settings, key), value = effective(key), type = field.type || field.cleaner;
    const card = el('div', {class: `field ${['structured', 'json', 'object', 'array'].includes(type) ? 'wide' : ''}`});
    const label = el('label', {for: `field-${key}`, title: field.help || ''}, field.label || key); card.append(label);
    let input;
    if (['bool', 'boolean'].includes(type)) {
      input = el('select', {id: `field-${key}`}, el('option', {value: 'true'}, 'Enabled'), el('option', {value: 'false'}, 'Disabled'));
      input.value = String(value === true || value === 'true');
    } else if (field.options?.length) {
      input = el('select', {id: `field-${key}`}, field.options.map((option) => el('option', {value: typeof option === 'object' ? option.value : option}, typeof option === 'object' ? option.label : option)));
      if (value != null && !Array.from(input.options).some((option) => option.value === String(value))) input.append(el('option', {value: String(value)}, String(value)));
      input.value = value == null ? '' : String(value);
    } else if (['structured', 'json', 'object', 'array'].includes(type)) {
      input = el('textarea', {id: `field-${key}`, class: 'mono', spellcheck: 'false'}, state.invalid.get(key)?.text ?? pretty(value ?? (type === 'array' ? [] : {})));
    } else {
      input = el('input', {id: `field-${key}`, type: 'text', value: Array.isArray(value) ? value.join(', ') : value == null ? '' : typeof value === 'object' ? pretty(value) : String(value)});
      if (['number', 'integer', 'float', 'to_i', 'to_f', 'seconds'].includes(type)) input.setAttribute('inputmode', 'decimal');
    }
    input.setAttribute('aria-describedby', `help-${key}`);
    input.setAttribute('title', field.help || '');
    if (field.available === false || field.editable === false) input.disabled = true;
    if (!local && state.resolving) { input.disabled = true; if (input.tagName !== 'SELECT') input.value = ''; }
    const error = el('span', {class: 'error-text', role: 'status'}, state.invalid.get(key)?.error || '');
    input.addEventListener('change', () => {
      let next = input.value;
      try {
        if (['bool', 'boolean'].includes(type)) next = next === 'true';
        else if (['structured', 'json', 'object', 'array'].includes(type)) next = JSON.parse(next);
        state.invalid.delete(key); input.removeAttribute('aria-invalid'); error.textContent = ''; set(key, next);
        source.textContent = 'Explicit setting in this draft';
        if (['signs', 'wounded_eval'].includes(key)) render();
      } catch (exception) { state.invalid.set(key, {text: input.value, error: `Invalid JSON: ${exception.message}`}); input.setAttribute('aria-invalid', 'true'); error.textContent = state.invalid.get(key).error; changed(); }
    });
    const provenance = state.validation?.provenance?.[key];
    const source = el('span', {class: 'source'}, local ? 'Explicit setting in this draft' : state.resolving ? 'Resolving inherited value…' : provenance ? `From ${typeof provenance === 'string' ? provenance : pretty(provenance)}` : state.draft.defaults ? 'Inherited; use Review to resolve the selected character defaults' : 'Engine / compatibility default');
    card.append(input, error, el('p', {id: `help-${key}`, class: 'help'}, field.help || 'Stored using the existing Hunter setting semantics.', field.units ? ` Units: ${field.units}.` : ''), source);
    if (orderedFields.has(key)) {
      const raw = el('details', {}, el('summary', {}, 'Original list (advanced)'), input);
      card.prepend(orderedList(field, value, input.disabled));
      card.append(raw);
    }
    if (['resting_room_id', 'field_rest_room_id'].includes(key) && !input.disabled) card.append(restMapButton(key));
    card.append(el('details', {}, el('summary', {}, 'Setting details'), el('p', {}, el('code', {}, key)), el('p', {}, `Default: ${pretty(field.default) ?? 'not set'}. Scope: ${field.scope || 'this saved configuration'}.`), field.requires ? el('p', {}, `Requires: ${String(field.requires)}`) : null, field.available === false ? el('p', {}, field.unavailable_reason || 'Unavailable in the installed engine.') : null));
    if (local) card.append(button('Use default again', () => { delete state.draft.settings[key]; state.invalid.delete(key); changed(); resolveInheritance(); }, 'reset'));
    return card;
  }
  function renderFields(main, page) {
    const handled = {area: ['boons_ignore', 'boons_flee'], rest: ['fog_return', 'fog_optional', 'fog_rift', 'custom_fog', 'return_waypoint_ids', 'rallypoint_room_ids'],
      combat: [...combatOptions, 'hunting_commands', 'quick_commands', 'disable_commands'], equipment: wandOptions,
      team: ['group_members', 'group_fried_trigger', 'group_strict_movement', 'independent_travel', 'independent_return', 'group_deader', 'ma_looter', 'never_loot', 'random_loot', 'quiet_followers']};
    const fields = state.boot.fields.filter((f) => normalizedPage(f.page) === page && !handled[page]?.includes(f.key) && !(page === 'buffs' && f.key === 'signs') && !(page === 'monitoring' && f.key === 'wounded_eval'));
    if (!fields.length) { main.append(note('No additional settings are described for this page by the installed engine. Unknown extension keys remain available in Raw configuration.')); return; }
    const isAdvanced = (field) => field.advanced ?? (field.editor === 'raw');
    const standard = fields.filter((f) => !isAdvanced(f)), advanced = fields.filter(isAdvanced);
    if (standard.length) main.append(el('section', {class: 'card'}, el('div', {class: 'field-grid'}, standard.map(fieldControl))));
    if (advanced.length) main.append(el('details', {class: 'card'}, el('summary', {}, `Advanced settings (${advanced.length})`), el('div', {class: 'field-grid'}, advanced.map(fieldControl))));
  }
  function orderedList(field, raw, disabled) {
    const codec = globalThis.HunterSettingsEditor, values = codec.lines(raw);
    const box = el('div', {class: 'ordered-settings', 'aria-label': `${field.label} sequence`});
    box.append(el('p', {class: 'help'}, field.key.endsWith('_scripts') ? 'Add script names with arguments, without a leading semicolon or “script”. Resting services are ordered; active hunting scripts run during the hunting phase.' : 'One preparation command per row. To call a script from a command list, use “script name”. These lists do not use combat conditions.'));
    if (!values) { box.append(note('Structured imported entries are preserved. Use Raw configuration to edit them.')); return box; }
    const error = el('p', {class: 'error-text', role: 'status'});
    const commit = (next) => {
      try { set(field.key, codec.replaceLines(raw, next)); render(); }
      catch (failure) { error.textContent = failure.message; }
    };
    values.forEach((value, index) => {
      const edit = el('input', {value, 'aria-label': `${field.label} step ${index + 1}`, disabled, title: field.help});
      const update = button('Update', () => commit(values.map((entry, i) => i === index ? edit.value : entry)));
      const up = button('Move up', () => { const next = values.slice(); [next[index - 1], next[index]] = [next[index], next[index - 1]]; commit(next); });
      const down = button('Move down', () => { const next = values.slice(); [next[index + 1], next[index]] = [next[index], next[index + 1]]; commit(next); });
      const remove = button('Remove', () => commit(values.filter((_, i) => i !== index)));
      update.disabled = remove.disabled = disabled; up.disabled = disabled || index === 0; down.disabled = disabled || index === values.length - 1;
      box.append(el('div', {class: 'list-item'}, edit, update, up, down, remove));
    });
    const next = el('input', {'aria-label': `New ${field.label} entry`, placeholder: field.key.endsWith('_scripts') ? 'e.g. eherbs' : 'e.g. stance defensive', disabled});
    const add = button('Add entry', () => commit([...values, next.value])); add.disabled = disabled;
    box.append(el('div', {class: 'row'}, next, add), error);
    return box;
  }
  function renderNotes(main) {
    const value = state.draft.notes ?? state.draft.settings?.notes ?? '';
    if (typeof value !== 'string') { main.append(note('Imported structured notes are preserved in Raw configuration.')); return; }
    const input = el('textarea', {'aria-label': 'Profile notes', title: 'Personal setup notes. These do not change hunting behavior.'}, value);
    input.addEventListener('change', () => { state.draft.notes = input.value; changed(); });
    main.append(el('section', {class: 'card'}, el('h2', {}, 'Profile notes'), input, el('p', {class: 'help'}, 'Reminders about this setup. Saved as editor metadata, not hunting instructions.')));
  }
  function renderReturnOptions(main) {
    main.append(fieldSection('How to return to rest', ['fog_return', 'fog_optional', 'fog_rift', 'return_waypoint_ids', 'rallypoint_room_ids']));
    main.append(el('details', {class: 'card', ...(String(effective('fog_return')) === '6' ? {open: ''} : {})}, el('summary', {}, 'Custom return sequence (used only with Custom return commands)'),
      fieldSection('Custom return commands', ['custom_fog'])));
  }
  function renderTeam(main) {
    main.append(note('This configures one character. Every follower still needs a local profile and explicit receiver approval. Saving does not enroll anyone or start the group.'),
      fieldSection('Members and readiness', ['group_members', 'group_strict_movement', 'group_deader']),
      fieldSection('Travel together or independently', ['independent_travel', 'independent_return']),
      fieldSection('When the team rests', ['group_fried_trigger', 'quiet_followers']),
      fieldSection('Who handles loot?', ['ma_looter', 'random_loot', 'never_loot']));
  }
  function renderBoons(main) {
    const codec = globalThis.HunterSettingsEditor, abilities = state.boot.boon_abilities || [];
    const panel = el('details', {class: 'card', id: 'boon-editor'}, el('summary', {}, 'Boon creatures: fight, ignore or flee'));
    panel.append(el('p', {class: 'help'}, 'Only boons recognized by the installed engine are listed. Fight follows your normal target rules; Ignore does not stop incoming attacks. Flee takes precedence when a creature has multiple boons.'));
    const error = el('p', {class: 'error-text', role: 'status'});
    const apply = (keys, choice) => {
      try { const next = codec.setBoons(effective('boons_ignore'), effective('boons_flee'), keys, choice); Object.assign(state.draft.settings, next); changed(); render(); $('boon-editor').open = true; }
      catch (failure) { error.textContent = failure.message; }
    };
    if (!abilities.length) panel.append(note('The installed boon table is unavailable. Existing values remain editable below.'));
    else {
      const bulk = el('div', {class: 'actions'});
      for (const [value, label] of [['fight', 'Fight'], ['ignore', 'Ignore'], ['flee', 'Flee']]) {
        const control = button(`${label} all listed boons`, () => apply(abilities.map((entry) => entry.key), value)); control.disabled = state.resolving; bulk.append(control);
      }
      panel.append(bulk);
      for (const ability of abilities) {
        const select = el('select', {'aria-label': `Response to ${ability.label}`, disabled: state.resolving, title: `Recognized adjectives: ${ability.adjectives.join(', ')}`},
          [['fight', 'Fight using normal target rules'], ['ignore', 'Do not target'], ['flee', 'Leave the room']].map(([value, label]) => el('option', {value}, label)));
        select.value = codec.boonChoice(effective('boons_ignore'), effective('boons_flee'), ability.key);
        select.addEventListener('change', () => apply([ability.key], select.value));
        panel.append(el('div', {class: 'field'}, el('label', {}, el('span', {class: 'control-label'}, ability.label), select), el('p', {class: 'help'}, `Recognized adjectives: ${ability.adjectives.join(', ')}`)));
      }
    }
    panel.append(error, el('details', {}, el('summary', {}, 'Original boon lists and extension names'), fieldSection('Native boon lists', ['boons_ignore', 'boons_flee'])));
    main.append(panel);
  }
  function renderInjuryRule(main) {
    const codec = window.HunterInjuryEditor, field = state.boot.fields.find((field) => field.key === 'wounded_eval');
    if (!codec || !field) return;
    const raw = effective('wounded_eval'), decoded = codec.decode(raw);
    let model = decoded || codec.defaults();
    const supported = state.boot.capabilities?.injury_checks || {};
    const native = {casting: 'able_to_cast?', ranged: 'able_to_use_ranged?', hiding: 'able_to_sneak?'};
    const unavailable = () => Boolean(model.scar && !supported.get_injury_data) || Object.entries(native).some(([flag, method]) => model[flag] && !supported[method]);
    const card = el('section', {class: 'card', id: 'injury-rule'}, el('h2', {}, 'When am I too injured to continue?'),
      el('p', {class: 'help'}, 'Choose a starting preset, adjust it, then Apply. Return when ANY selected condition is true. This uses the existing injury-return policy and your configured rest destinations; it does not heal you or teleport out of danger.'));
    if (!decoded && raw) card.append(note('Your existing custom injury rule is being kept unchanged. Applying these controls will replace that rule, not add to it.', 'warning'));
    else if (!raw) card.append(note('No injury rule is configured here yet. The suggested controls below do nothing until you apply them.'));
    else card.append(note('The controls show your saved or inherited injury rule. Changes below require Apply.'));
    const preset = el('select', {'aria-label': 'Injury return preset'}, el('option', {value: ''}, 'Choose a preset, or adjust the controls'));
    for (const [key, item] of Object.entries(codec.presets)) {
      const option = el('option', {value: key}, item.label);
      option.disabled = Object.entries(native).some(([flag, method]) => item.values[flag] && !supported[method]);
      preset.append(option);
    }
    const fields = el('div', {class: 'field-grid'}), preview = el('p', {class: 'help', role: 'status'}), explanation = el('p', {class: 'help'});
    const apply = button('Apply injury return rule', () => {
      try { if (unavailable()) throw new Error('A selected native injury reader is unavailable in this Lich build. Your existing rule has not changed.');
        set('wounded_eval', codec.encode(model)); render(); status('Injury return rule applied to this draft. Save is still required.');
      } catch (error) { preview.textContent = error.message; }
    }, 'primary');
    const refresh = () => {
      try {
        codec.encode(model);
        const parts = [];
        if (model.health) parts.push(`health is ${Number(model.health)}% or lower`);
        if (model.wound) parts.push(`any wound is rank ${model.wound} or higher`);
        if (model.scar) parts.push(`any scar is rank ${model.scar} or higher`);
        for (const [key, label] of [['bleeding', 'you are bleeding'], ['casting', 'injuries prevent casting'], ['ranged', 'injuries prevent ranged attacks'], ['hiding', 'injuries prevent hiding'], ['overexerted', 'you have popped muscles (Overexerted)']]) if (model[key]) parts.push(label);
        preview.textContent = `Return when ${parts.join(' OR ')}.`;
        apply.disabled = state.resolving || unavailable();
      } catch (error) { preview.textContent = error.message; apply.disabled = true; }
    };
    const controls = () => {
      fields.replaceChildren();
      const health = el('input', {type: 'number', min: 1, max: 100, step: 1, value: model.health, 'aria-label': 'Return at or below health percent', title: 'Health percentage, not hit points. Leave blank to disable this condition.'});
      health.addEventListener('input', () => { model.health = health.value; refresh(); });
      fields.append(el('label', {}, 'Health at or below (%)', health, el('span', {class: 'help'}, 'Blank disables this condition.')));
      for (const [key, label] of [['wound', 'Any wound rank'], ['scar', 'Any scar rank']]) {
        const select = el('select', {'aria-label': label, title: 'Return at this severity or higher, anywhere on your body.'}, [['', 'Do not check'], ['1', 'Rank 1 or higher'], ['2', 'Rank 2 or higher'], ['3', 'Rank 3']].map(([value, name]) => el('option', {value}, name)));
        select.value = model[key]; select.disabled = key === 'scar' && !supported.get_injury_data;
        select.addEventListener('change', () => { model[key] = select.value; refresh(); }); fields.append(el('label', {}, label, select, select.disabled ? el('span', {class: 'help'}, 'Native cached scar reader unavailable.') : null));
      }
      for (const [key, label] of [['bleeding', 'Return if bleeding'], ['casting', 'Return if injuries prevent casting'], ['ranged', 'Return if injuries prevent ranged attacks'], ['hiding', 'Return if injuries prevent hiding'], ['overexerted', 'Return with popped muscles (Overexerted)']]) {
        const input = el('input', {type: 'checkbox', 'aria-label': label}); input.checked = model[key]; input.disabled = Boolean(native[key] && !supported[native[key]]);
        input.title = native[key] ? 'Uses Lich’s existing injury/scar check, including supported bypass effects. Not a mana, roundtime or spell-knowledge check.' : label;
        input.addEventListener('change', () => { model[key] = input.checked; refresh(); });
        fields.append(el('label', {}, input, ` ${label}`, input.disabled ? el('span', {class: 'help'}, 'Native injury reader unavailable.') : null));
      }
      refresh();
    };
    preset.addEventListener('change', () => { if (!preset.value) return; model = {...codec.presets[preset.value].values}; explanation.textContent = codec.presets[preset.value].help; controls(); });
    controls();
    card.append(el('label', {}, 'Start from a common setup', preset), explanation, fields, preview, apply,
      el('p', {class: 'help'}, 'Caster and ranged checks reuse native Lich injury rules, including scars and supported Sigil of Determination effects. They may refresh injury data during a hunt. Setup never runs them. Presets are starting points, not a guarantee of safety.'),
      el('details', {}, el('summary', {}, 'Original Ruby injury rule (advanced)'), fieldControl(field)));
    main.append(card);
  }
  function renderBuffs(main) {
    const catalog = state.boot.society_abilities || {};
    const raw = effective('signs');
    const valid = raw == null || typeof raw === 'string' || (Array.isArray(raw) && raw.every((entry) => typeof entry === 'string'));
    const entries = valid ? (Array.isArray(raw) ? [...raw] : String(raw || '').split(',').map((entry) => entry.trim()).filter(Boolean)) : [];
    const card = el('section', {class: 'card', id: 'society-upkeep'}, el('h2', {}, 'Society abilities to keep active'),
      el('p', {class: 'help'}, 'Choose the Signs, Symbols or Sigils Hunter should renew when missing and affordable. These use Hunter’s existing upkeep policy, not a new buff script. No abilities are enabled by default; selecting one may spend mana, stamina, spirit or favor during the hunt.'),
      el('p', {class: 'help'}, catalog.notice || (catalog.groups?.length ? 'Ability information was supplied by the session’s native readers. Reopen setup after learning new abilities.' : 'Native ability information is unavailable in this setup session. Your existing entries remain editable below.')));
    if (!valid) card.append(note('The imported upkeep list has an unsupported shape. Edit its original value below; no entries have been discarded.', 'warning'));
    for (const group of catalog.groups || []) {
      const section = el('section', {class: 'society-group'}, el('h3', {}, group.name));
      if (!group.available) section.append(note(group.error || 'Native reader unavailable.', 'warning'));
      else if (!group.member) section.append(el('p', {class: 'help'}, 'Not a member according to the current Lich reader.'));
      else {
        const other = el('details', {}, el('summary', {}, 'Other learned abilities — not automatic upkeep'));
        let others = 0;
        for (const ability of group.abilities || []) {
          const selected = entries.some((entry) => entry.trim() === String(ability.id));
          const check = el('input', {type: 'checkbox', 'aria-label': `Keep ${ability.name} active`}); check.checked = selected;
          check.disabled = !valid || state.resolving || (!ability.maintainable && !selected);
          const costs = ability.cost && typeof ability.cost === 'object' ? Object.entries(ability.cost).map(([resource, value]) => `${value} ${resource}`).join(', ') : ability.cost != null ? `${ability.cost} favor` : 'not reported';
          const timing = ability.cost_type === 'dissipates' ? ' Charged when the effect wears off.' : '';
          const help = `${ability.description || 'Description unavailable.'} Cost: ${costs}.${timing}`;
          check.title = help;
          check.addEventListener('change', () => {
            const next = entries.filter((entry) => entry.trim() !== String(ability.id));
            if (check.checked) next.push(String(ability.id));
            // Keep custom expressions and other societies exactly as imported.
            set('signs', Array.isArray(raw) ? next : next.join(', ')); render();
          });
          const row = el('div', {class: 'society-ability'}, el('label', {title: help}, check, ` ${ability.name}`), el('p', {class: 'help'}, help));
          if (!ability.maintainable) row.append(el('p', {class: 'help'}, ability.reason || 'Not available for automatic upkeep.', selected ? ' Already configured; uncheck to remove it, or review the original entry below.' : ''));
          if (ability.maintainable || selected) section.append(row); else { other.append(row); others++; }
        }
        if (others) section.append(other);
        if (!group.abilities?.length) section.append(note('No learned abilities were reported. Reopen setup after the game updates your society rank.'));
      }
      card.append(section);
    }
    const rawField = state.boot.fields.find((field) => field.key === 'signs');
    if (rawField) card.append(el('details', {}, el('summary', {}, 'Original upkeep entries and other abilities (advanced)'), fieldControl(rawField)));
    main.append(card, el('section', {class: 'card'}, el('h2', {}, 'Missing buffs, mana recovery and blessings'),
      el('p', {class: 'help'}, 'Upkeep choices renew the selected abilities. Combat-buff monitoring below is a separate policy for missing required spells. Mana recovery and weapon blessing also have their own switches; none is enabled by choosing a society ability.'),
      note('Dispel-cause detection, bulk MANA SPELLUP scheduling and per-spell recovery timing require native engine support. This page does not invent those policies.')));
  }
  function referenceSelect(key, label, collection) {
    const select = el('select', {'aria-label': label}, el('option', {value: ''}, key === 'defaults' ? 'Independent profile · no linked defaults' : 'Use inherited / existing command sequence'), names(collection).map((name) => el('option', {value: name}, name)));
    if (state.draft[key] && !names(collection).includes(state.draft[key])) select.append(el('option', {value: state.draft[key]}, `${state.draft[key]} (missing)`));
    select.value = state.draft[key] || '';
    select.addEventListener('change', () => { if (select.value) state.draft[key] = select.value; else delete state.draft[key]; changed(); resolveInheritance(); });
    return el('div', {class: 'field'}, el('label', {}, label, select), el('p', {class: 'help'}, 'Links are resolved on the next launch. Local overrides stay intact.'));
  }
  function renderCombat(main) {
    if (state.kind === 'profile' && !state.guided) main.append(el('section', {class: 'card'}, referenceSelect('defaults', 'Character defaults', state.boot.defaults)));
    const library = el('section', {class: 'card', id: 'combat-sequences'}, el('h2', {}, 'Your combat sequences'),
      el('p', {class: 'help'}, 'Keep several universal sequences, such as Everyday, No fire, or Tough enemies. Each creature below can use any of them or its own custom sequence. The hunt default is only the fallback; Hunter does not run the whole collection.'),
      referenceSelect('combat_plan', state.kind === 'defaults' ? 'Sequence for these character defaults' : 'Sequence for this hunt', state.boot.plans));
    const begin = (commands) => {
      if (state.sequenceDraft || state.saving) return;
      state.sequenceDraft = {name: '', commands, error: ''}; updateHeader(); render();
      $('sequence-name')?.focus({preventScroll: true});
    };
    const add = button('Add sequence', () => begin(''));
    const current = state.draft.combat_plan ? state.validation?.effective?.hunting_commands : effective('hunting_commands');
    const copy = button('Save a copy as another sequence', () => begin(current));
    add.disabled = Boolean(state.sequenceDraft) || state.saving;
    copy.disabled = add.disabled || state.resolving || typeof current !== 'string' || !current.trim();
    library.append(el('div', {class: 'actions spaced'}, add, copy, button('Manage saved sequences', () => navigate('manage'))),
      el('p', {class: 'help'}, 'Saved sequences are reusable Combat Plans. Selecting one changes only this draft until you save the hunt. Editing a shared plan affects linked hunts on their next launch.'));
    main.append(library);
    if (state.sequenceDraft) renderSequenceDraft(main);
    else {
      if (state.resolving) main.append(note('Resolving your saved combat settings…'));
      else if (state.draft.combat_plan) main.append(el('section', {class: 'card', id: 'selected-combat-sequence'},
        el('h2', {}, `Selected sequence: ${state.draft.combat_plan}`),
        typeof current === 'string' ? el('pre', {}, current || '(empty sequence)') : note('This sequence could not be resolved. Check its saved Combat Plan in Review & save.', 'warning'),
        el('p', {class: 'help'}, 'Use “Save a copy as another sequence” to make a variation without changing the original. Choose “Use inherited / existing command sequence” above to return to this hunt’s own routine.')));
      else {
        if (state.draft.defaults && !own(state.draft.settings, 'hunting_commands')) main.append(note('The sequence below comes from your character defaults. Editing it creates an override for this hunt; the shared defaults stay unchanged.'));
        main.append(sequenceEditor('Usual combat sequence', effective('hunting_commands'), (value) => set('hunting_commands', value)));
      }
    }
    renderCreatureSequences(main);
    const styles = detailsPanel('combat-specialties', 'Unarmed combat and MSTRIKE');
    styles.append(fieldSection('Automatic unarmed attacks', ['tier3', 'aim', 'uac_smite', 'uac_mstrike']),
      fieldSection('MSTRIKE resources and targets', combatOptions.filter((key) => key.startsWith('mstrike_'))));
    const alternatives = detailsPanel('alternative-sequences', 'Alternative combat sequences');
    alternatives.addEventListener('toggle', () => {
      if (!alternatives.open || alternatives.dataset.loaded) return;
      alternatives.dataset.loaded = 'true';
      alternatives.append(sequenceEditor('When my mind is full (coordinated groups)', effective('disable_commands'), (value) => set('disable_commands', value)),
        sequenceEditor('Quick-target combat sequence', effective('quick_commands'), (value) => set('quick_commands', value)));
    });
    main.append(styles, alternatives);
    if (state.guided) main.append(el('details', {class: 'card'}, el('summary', {}, 'Wands and spell fallback'), fieldSection('Wand settings', wandOptions)));
    if (state.guided) {
      const settings = el('details', {class: 'card', id: 'combat-style-settings'}, el('summary', {}, 'Weapons, aiming, stealth & automatic stances'));
      settings.append(el('p', {class: 'help'}, 'These settings belong to this hunt, not to an individual shared sequence. They configure Hunter’s existing behaviour; changing a sequence does not silently change equipment or movement.'),
        fieldSection('Automatic stance policy', ['hunting_stance', 'wander_stance', 'stand_stance']),
        fieldSection('Ranged and aimed attacks', ['archery_aim', 'ambush', 'ammo_container']),
        fieldSection('Equipment and hidden movement', ['hunting_right_hand', 'hunting_left_hand', 'sneaky_sneaky']),
        el('p', {class: 'help'}, 'Hidden movement is not stalking a moving target. Hunter has no guided stalking policy here. Use existing group/follow settings for player groups; custom stalking routines remain advanced.'));
      main.append(settings);
    }
  }
  function renderCreatureSequences(main) {
    const section = el('section', {class: 'card', id: 'creature-sequences'}, el('h2', {}, 'Combat sequence for each creature'),
      el('p', {class: 'help'}, 'For each target, choose any saved universal sequence, write a custom sequence just for that creature, or use the hunt default. This never adds hunt targets or changes flee rules.'));
    main.append(section);
    const entries = targetEntries(), exceptions = state.draft.creature_plans || {};
    if (!entries?.length) { section.append(note('Choose creatures in Area & creatures to assign their sequences. Unrestricted hunting keeps the hunt default; no target list is invented.')); return; }
    if (typeof exceptions !== 'object' || Array.isArray(exceptions)) { section.append(note('The creature plan mapping needs correction in Raw configuration.', 'warning')); return; }
    for (const entry of entries) {
      const link = Object.keys(exceptions).find((name) => name.toLowerCase().trim() === entry.name.toLowerCase());
      const selected = link ? `plan:${exceptions[link]}` : entry.slot !== 'a' ? 'custom' : 'default';
      const choices = el('select', {'aria-label': `Sequence for ${entry.name}`}, el('option', {value: 'default'}, 'Use hunt default'),
        el('optgroup', {label: 'Universal sequences'}, names(state.boot.plans).map((name) => el('option', {value: `plan:${name}`}, name))),
        el('option', {value: 'custom'}, 'Custom for this creature'));
      if (![...choices.options].some((option) => option.value === selected)) choices.append(el('option', {value: selected}, `${exceptions[link]} (missing)`));
      choices.value = selected; choices.disabled = state.resolving || state.saving || Boolean(state.sequenceDraft);
      const resolvedEntry = targetEntries(state.validation?.effective?.targets)?.find((target) => target.name.toLowerCase() === entry.name.toLowerCase());
      const slot = resolvedEntry?.slot || entry.slot;
      const commands = state.validation?.effective?.[slot === 'a' ? 'hunting_commands' : `hunting_commands_${slot}`] ?? effective(slot === 'a' ? 'hunting_commands' : `hunting_commands_${slot}`);
      const customize = () => {
        if (state.sequenceDraft || state.saving || state.resolving) return;
        state.sequenceDraft = {creature: entry.name, commands: typeof commands === 'string' ? commands : '', error: ''}; render();
        $('new-combat-sequence')?.scrollIntoView({block: 'nearest'});
      };
      choices.addEventListener('change', () => {
        if (choices.value === 'custom') { customize(); return; }
        if (link) delete state.draft.creature_plans[link];
        if (choices.value.startsWith('plan:')) {
          state.draft.creature_plans ||= {}; state.draft.creature_plans[entry.name] = choices.value.slice(5);
        } else state.draft.settings.targets = entries.map((target) => `${target.name}(${target.name === entry.name ? 'a' : target.slot})`).join(', ');
        changed(); resolveInheritance();
      });
      const row = el('div', {class: 'creature-sequence spaced'}, el('h3', {}, entry.name), choices);
      if (selected === 'custom') {
        const edit = button('Edit custom sequence', customize); edit.disabled = choices.disabled; row.append(edit);
        row.append(el('p', {class: 'help'}, 'Custom for this creature in this hunt. Editing keeps other creatures’ sequences unchanged.'));
      }
      if (!state.resolving && typeof commands === 'string') row.append(el('pre', {}, commands || '(empty sequence)'));
      section.append(row);
    }
    for (const [name, plan] of Object.entries(exceptions)) {
      if (entries.some((entry) => entry.name.toLowerCase() === name.toLowerCase().trim())) continue;
      section.append(note(`Saved exception for unlisted target ${name}: ${plan}. Review this reference; it has not been discarded.`, 'warning'),
        button(`Remove exception for ${name}`, () => { delete state.draft.creature_plans[name]; changed(); resolveInheritance(); }));
    }
  }
  function renderSequenceDraft(main) {
    const draft = state.sequenceDraft;
    const card = el('section', {class: 'card', id: 'new-combat-sequence'}, el('h2', {}, draft.creature ? `Custom sequence: ${draft.creature}` : 'Add a reusable sequence'),
      el('p', {class: 'help'}, draft.creature ? 'Applies only to this creature in this hunt. Saved universal sequences and other creatures stay unchanged.' : 'Save a new named sequence without leaving or saving your hunt. Existing names are never overwritten here.'));
    if (!draft.creature) {
      const name = el('input', {id: 'sequence-name', value: draft.name, placeholder: 'e.g. Everyday, No fire, Tough enemies', autocomplete: 'off'});
      name.addEventListener('input', () => { draft.name = name.value; updateHeader(); });
      card.append(el('label', {class: 'control-label', for: 'sequence-name'}, 'Sequence name'), name);
    }
    card.append(sequenceEditor('Actions in this sequence', draft.commands, (value) => { draft.commands = value; updateHeader(); }));
    if (draft.error) card.append(note(draft.error, 'error'));
    const actions = el('div', {class: 'actions spaced'},
      button(draft.creature ? 'Apply custom sequence to draft' : 'Save universal sequence', () => saveSequenceDraft(false), 'primary'));
    if (!draft.creature) actions.append(button('Save & use as hunt default', () => saveSequenceDraft(true)));
    actions.append(button('Cancel new sequence', () => { if (!state.saving) { state.sequenceDraft = null; render(); } }));
    card.append(actions);
    if (state.saving) card.querySelectorAll('input, textarea, select, button').forEach((control) => { control.disabled = true; });
    main.append(card);
  }
  async function saveSequenceDraft(selectAsDefault = false) {
    const draft = state.sequenceDraft;
    if (!draft || state.saving) return;
    if ((!draft.creature && !draft.name.trim()) || typeof draft.commands !== 'string' || !draft.commands.trim()) {
      draft.error = draft.creature ? 'Add at least one action.' : 'Give the sequence a name and add at least one action.'; render(); return;
    }
    const documentId = state.documentId, generation = state.generation, name = draft.name?.trim();
    state.saving = true; state.readRequest += 1; draft.error = ''; render();
    try {
      if (draft.creature) {
        const updated = await api('creature_sequence', {data: clone(state.draft), creature: draft.creature, commands: draft.commands});
        if (documentId !== state.documentId || generation !== state.generation || state.sequenceDraft !== draft) throw new Error('The hunt draft changed. Review it and apply this custom sequence again.');
        state.draft = updated; state.sequenceDraft = null; changed(); await resolveInheritance();
        status(`Custom sequence for ${draft.creature} applied to this draft. Save the hunt when ready.`); return;
      }
      await api('save', {kind: 'plan', name, data: {commands: draft.commands}, revision: null});
      if (!names(state.boot.plans).includes(name)) state.boot.plans.push(name);
      if (documentId !== state.documentId || state.sequenceDraft !== draft) return;
      state.sequenceDraft = null;
      if (!selectAsDefault) status(`Saved universal sequence “${name}”. It is now available for every creature. Your hunt selections were not changed.`);
      else if (generation === state.generation) {
        state.draft.combat_plan = name; changed(); await resolveInheritance();
        status(`Saved sequence “${name}” and selected it for this draft. Save the hunt separately; no hunt was started.`);
      } else status(`Saved sequence “${name}”. Your draft changed while saving, so its selected sequence was left untouched. Choose the new sequence when ready.`);
    } catch (error) {
      if (state.sequenceDraft === draft) draft.error = error.message;
      fail(error);
    } finally { state.saving = false; render(); }
  }
  function renderPlanCommands(main) {
    main.append(nameControl(), sequenceEditor('Combat sequence', state.draft.commands, (value) => { state.draft.commands = value; changed(); }));
  }
  function sequenceEditor(title, raw, write) {
    const codec = globalThis.HunterRoutineEditor;
    const card = el('section', {class: 'card'}, el('h2', {}, title), el('p', {class: 'help'}, 'Actions run in order, then the sequence starts again while combat continues. Conditions are checked before each action: if any fails, skip that action and move on; do not wait.'));
    const empty = raw == null || (Array.isArray(raw) && raw.length === 0);
    const text = typeof raw === 'string' ? raw : empty ? '' : pretty(raw);
    const parsed = codec.parse(raw), parts = parsed?.map((line) => line.raw);
    const original = el('textarea', {'aria-label': 'Original combat routine', class: 'mono', spellcheck: 'false'}, text);
    if (parsed) {
      const update = () => { write(parts.join(', ')); render(); };
      const list = el('div', {class: 'sequence-list'});
      list.replaceChildren(...parsed.map((line, index) => {
        const up = button('Move up', () => { [parts[index - 1], parts[index]] = [parts[index], parts[index - 1]]; update(); }); up.disabled = index === 0;
        const down = button('Move down', () => { [parts[index + 1], parts[index]] = [parts[index], parts[index + 1]]; update(); }); down.disabled = index === parts.length - 1;
        const command = el('code', {class: 'grow'}, line.raw);
        const row = el('div', {class: 'sequence-step', 'aria-label': `Action ${index + 1}`},
          el('div', {class: 'list-item'}, el('span', {class: 'step-number', 'aria-hidden': 'true'}, index + 1), command, up, down,
            button('Remove', () => { parts.splice(index, 1); update(); })));
        if (line.editable) {
          row.append(routineControls(line, (next) => {
            const value = codec.serialize(next);
            parts[index] = value; write(parts.join(', ')); original.value = parts.join(', '); command.textContent = value;
          }));
        } else row.append(note('Compound or custom syntax is preserved. Edit this line in Original routine text below.'));
        return row;
      }));
      if (!parts.length) list.append(el('p', {class: 'empty'}, 'No combat actions yet. Add an attack or a spell.'));
      card.append(list, actionBuilder('attack', (command) => { parts.push(command); update(); }, true));
    } else card.append(note('This sequence uses a structured value. It is preserved exactly; use Raw configuration to edit its structure.'));
    original.readOnly = parsed === null;
    original.addEventListener('change', () => { write(original.value); render(); });
    const details = el('details', {}, el('summary', {}, 'Original routine text (advanced)'), original);
    details.open = parsed === null || parsed.some((line) => !line.editable);
    card.append(details);
    return card;
  }
  function actionBuilder(command, save, adding = false) {
    const codec = globalThis.HunterRoutineEditor, maneuvers = state.boot.routine_maneuvers || [];
    let model = codec.decodeAction(command, maneuvers);
    const box = el('div', {class: 'action-builder'});
    const label = adding ? 'Action to add' : 'Action type';
    const type = el('select', {'aria-label': label}, codec.actionTypes.map(([value, text]) => el('option', {value}, text)));
    type.value = model.kind;
    const fields = el('div', {class: 'action-options'}), help = el('p', {class: 'help'}), error = el('p', {class: 'error-text', role: 'status'});
    const options = (key, label, choices) => {
      // Keep an imported numeric stance visible without rewriting it.
      if (model[key] && !choices.some(([value]) => value === model[key])) choices = [...choices, [model[key], `Existing: ${model[key]}`]];
      const select = el('select', {'aria-label': adding ? label : `Step ${label.toLowerCase()}`}, choices.map(([value, text]) => el('option', {value}, text)));
      select.value = String(model[key]); select.addEventListener('change', () => { model[key] = choices.find(([value]) => String(value) === select.value)?.[0] ?? select.value; });
      fields.append(el('label', {class: 'field'}, label, select));
    };
    const input = (key, label, placeholder = '', numeric = false) => {
      const control = el('input', {'aria-label': adding ? label : `Step ${label.toLowerCase()}`, value: model[key], placeholder, ...(numeric ? {inputmode: 'numeric'} : {})});
      control.addEventListener('input', () => { model[key] = control.value; });
      fields.append(el('label', {class: 'field'}, label, control));
    };
    function draw() {
      fields.replaceChildren(); error.textContent = '';
      help.textContent = codec.actionHelp[model.kind] || 'Uses the native targeted combat action. Hunting stance and native safety gates still apply.';
      switch (model.kind) {
        case 'mstrike': options('move', 'MSTRIKE variant', [['', 'Weapon attack'], ...['jab', 'punch', 'kick', 'grapple'].map((value) => [value, value])]); break;
        case 'wandolier':
          options('stance', 'Wand stance', codec.stances.map((value) => [value, value]));
          options('noreserve', 'Reserve the retrieved wand', [[false, 'Use native reservation'], [true, 'Do not reserve']]); break;
        case 'jewel': input('mnemonic', 'Gemstone ability mnemonic', 'e.g. arcaneintensity'); break;
        case 'curse': options('variant', 'Curse type', ['clumsy', 'weakness', 'darkness', 'itch', 'hex', 'pox', 'nightmare', 'star'].map((value) => [value, value])); break;
        case 'efury': options('element', 'Earthen Fury element', [['', 'Default'], ['fire', 'Fire'], ['cold', 'Cold']]); break;
        case 'tether': options('recast', 'Recast when tether transfers', [[false, 'No'], [true, 'Use native recast handling']]); break;
        case 'caststop': case 'unravel': input('spell', 'Spell number', model.kind === 'unravel' ? 'Optional spell to unravel' : 'Required', true); break;
        case 'resonance': input('spells', 'Rotation spell numbers', '511 512 513'); break;
        case 'store': options('hand', 'Hands to stow', [['left', 'Left'], ['right', 'Right'], ['both', 'Both']]); break;
        case 'wield': input('noun', 'Item noun', 'staff'); options('hand', 'Destination hand', [['left', 'Left'], ['right', 'Right']]); break;
        case 'script': input('script', 'Script name and arguments', 'my-combat-script'); break;
        case 'force': case 'eachtarget': case 'prefix': {
          if (model.kind === 'force') input('endroll', 'Required endroll', '101', true);
          if (model.kind === 'prefix') options('prefix', 'Buff before action', [['haste', 'Haste (506)'], ['slayer', 'Spirit Slayer (240)'], ['tonis', 'Song of Tonis (1035)']]);
          const current = el('code', {}, model.inner);
          const chooser = el('details', {}, el('summary', {}, 'Choose the inner action'), current);
          chooser.addEventListener('toggle', () => {
            if (!chooser.open || chooser.dataset.loaded) return;
            chooser.dataset.loaded = 'true';
            chooser.append(actionBuilder(model.inner, (command) => { model.inner = command; current.textContent = command; chooser.open = false; }, false));
          });
          fields.append(chooser, el('p', {class: 'help'}, 'Choose and update the inner action, then add/update this outer step. Conditions apply to the outer step.'));
          break;
        }
        case 'incant':
          input('spell', 'Spell number', 'e.g. 711', true);
          options('delivery', 'Spell delivery', [['incant', 'Incant'], ['default', 'Lich spell default'], ['cast', 'Cast'], ['channel', 'Channel'], ['evoke', 'Evoke']]);
          options('scope', 'Spell targeting variant', [['', 'Spell default'], ['open', 'Open (spell-dependent; may affect others)'], ['closed', 'Closed (spell-dependent)']]);
          options('element', 'Spell element', codec.elements.map((value) => [value, value || 'Spell default']));
          break;
        case 'ambush': case 'dhurl': input('part', 'Aim body part', 'Blank: use profile aiming order'); break;
        case 'hide': input('attempts', 'Maximum hide attempts', '3', true); break;
        case 'unarmed':
          options('move', 'Unarmed move', ['jab', 'punch', 'kick', 'grapple'].map((value) => [value, value]));
          input('part', 'Aim body part', 'Optional single-word body part'); break;
        case 'stance': options('stance', 'Stance for this step', codec.stances.map((value) => [value, value])); break;
        case 'wait': case 'sleep':
          input('seconds', model.kind === 'wait' ? 'Maximum wait seconds' : 'Pause seconds', '3', true);
          if (model.kind === 'sleep') {
            const keep = el('input', {type: 'checkbox', checked: model.nostance, 'aria-label': 'Keep current stance during pause'});
            keep.addEventListener('change', () => { model.nostance = keep.checked; });
            fields.append(el('label', {class: 'row'}, keep, 'Keep current stance during pause'));
          }
          break;
        case 'maneuver':
          options('technique', 'Technique', [['', 'Choose a native technique'], ...maneuvers.map((item) => [item.word, `${item.name} (${item.category})`])]);
          const all = el('input', {type: 'checkbox', checked: model.all, 'aria-label': 'Use all-target variant'});
          all.addEventListener('change', () => { model.all = all.checked; });
          fields.append(el('label', {class: 'row'}, all, 'Use all-target variant (only where the technique supports it)'));
          if (!maneuvers.length) fields.append(note('The installed technique table is unavailable. Existing native command text is preserved.'));
          break;
        case 'custom': input('command', 'Action command', 'Existing native routine command'); break;
      }
      for (const control of fields.querySelectorAll('input, select')) control.title = `${control.getAttribute('aria-label')}. ${help.textContent}`;
    }
    type.addEventListener('change', () => { model = codec.actionDefaults(type.value); draw(); });
    draw();
    box.append(el('label', {class: 'field'}, label, type), fields, help, error,
      button(adding ? 'Add action' : 'Update action', () => {
        try { save(codec.encodeAction(model, maneuvers)); error.textContent = ''; }
        catch (failure) { error.textContent = failure.message; }
      }), el('p', {class: 'help'}, adding ? 'Only Add action inserts this step into the draft.' : 'Update action changes this step and keeps its conditions/repetition. Until then these options are only a preview.'));
    return box;
  }
  function routineControls(initial, write) {
    const codec = globalThis.HunterRoutineEditor;
    let line = clone(initial);
    const box = el('details', {class: 'routine-controls'});
    const summary = el('summary');
    const body = el('div', {class: 'routine-fields'});
    const error = el('p', {class: 'error-text', role: 'status'});
    const field = (label, input, help) => el('label', {class: 'field'}, el('span', {}, label), input, help ? el('small', {class: 'help'}, help) : null);
    const commit = (next) => {
      try { write(next); line = next; error.textContent = ''; draw(); }
      catch (failure) { draw(); error.textContent = `${failure.message} Draft unchanged; the previous value is shown.`; }
    };
    function draw() {
      summary.textContent = `Action options, conditions & repetition — ${line.modifiers.includes('untildead') ? 'repeat on this target' : `${line.repeat === 'x' ? '5 (legacy xx)' : line.repeat} per pass`}${line.modifiers.length ? `; ${line.modifiers.map(codec.describe).join('; ')}` : '; no conditions'}`;
      body.replaceChildren();
      const repeatOptions = [['cycle', 'Every sequence pass'], ['once', 'Once per target'], ['room', 'Once per room']];
      if (state.boot.capabilities?.repeat_until_target_gone || line.modifiers.includes('untildead')) repeatOptions.push(['untildead', 'Repeat until target dies / leaves (safety checks still apply)']);
      const scope = el('select', {'aria-label': 'Repetition rule'}, repeatOptions.map(([value, label]) => el('option', {value}, label)));
      scope.value = ['once', 'room', 'untildead'].find((value) => line.modifiers.includes(value)) || 'cycle';
      scope.addEventListener('change', () => commit({...line, repeat: scope.value === 'cycle' ? line.repeat : '1', modifiers: [...line.modifiers.filter((token) => !['once', 'room', 'untildead'].includes(token)), ...(scope.value === 'cycle' ? [] : [scope.value])]}));
      const count = el('input', {type: 'number', min: '1', max: '100', step: '1', value: line.repeat === 'x' ? '5' : line.repeat, 'aria-label': 'Times per pass', disabled: scope.value !== 'cycle'});
      count.addEventListener('change', () => commit({...line, repeat: count.value}));
      body.append(actionBuilder(line.command, (command) => commit({...line, command})), el('div', {class: 'row'}, field('When to repeat', scope, 'Once flags track identical lines; per-target flags reset when the room changes.'), field('Times per pass', count, 'Conditions are checked before each repeat. This is not a total cast limit for the entire fight.')));
      const conditions = el('div', {class: 'routine-condition-list', 'aria-label': 'Current conditions'});
      line.modifiers.forEach((token, index) => conditions.append(el('div', {class: 'row'}, el('span', {class: 'grow'}, codec.describe(token)),
        el('code', {}, token), button('Remove condition', () => commit({...line, modifiers: line.modifiers.filter((_, i) => i !== index)})))));
      body.append(conditions);
      const kind = el('select', {'aria-label': 'Condition to add'});
      kind.append(el('optgroup', {label: 'Resource and target thresholds'}, codec.amounts.map(([key, label]) => el('option', {value: `amount:${key}`}, label))),
        el('option', {value: 'delay'}, 'Minimum time between uses'),
        el('optgroup', {label: 'Player, target and room state'}, codec.flags.map(([key, label]) => el('option', {value: `flag:${key}`}, label))),
        el('optgroup', {label: 'Named effects on me'}, codec.effects.map(([key, label]) => el('option', {value: `effect:${key}`}, label))));
      const parameters = el('div', {class: 'row'});
      let makeToken;
      const parametersForKind = () => {
        parameters.replaceChildren();
        const [type, key] = kind.value.split(':');
        const comparison = el('select', {'aria-label': 'Condition comparison'});
        const value = el('input', {type: 'number', min: '0', step: '1', value: '40', 'aria-label': 'Condition value'});
        if (['h', 'e', 'thp'].includes(key)) value.max = '100';
        if (type === 'amount') {
          const info = codec.amounts.find(([name]) => name === key);
          comparison.append(el('option', {value: ''}, info[2]), el('option', {value: '!'}, info[3]));
          parameters.append(comparison, value);
          makeToken = () => { if (!/^\d+$/.test(value.value) || !value.checkValidity()) throw new Error('Enter a whole number in the allowed range.'); return `${comparison.value}${key}${value.value}`; };
        } else if (type === 'delay') {
          value.value = '30'; parameters.append(field('Seconds between uses', value));
          makeToken = () => { if (!/^\d+$/.test(value.value)) throw new Error('Enter whole seconds, zero or more.'); return `repeatdelay${value.value}`; };
        } else if (type === 'flag') {
          comparison.append(el('option', {value: ''}, 'Is true'));
          if (!key.startsWith('tier')) comparison.append(el('option', {value: '!'}, 'Is false'));
          parameters.append(comparison);
          makeToken = () => comparison.value ? codec.invert(key) : key;
        } else {
          comparison.append(el('option', {value: ''}, 'Is present'), el('option', {value: '!'}, 'Is absent'));
          const name = el('input', {'aria-label': 'Effect name', placeholder: 'e.g. Elemental Defense I'});
          parameters.append(comparison, name);
          makeToken = () => {
            if (!name.value.trim() || /[",()\r\n]/.test(name.value)) throw new Error('Enter an effect name without quotes, commas or parentheses; use original text for complex patterns.');
            return `${comparison.value}${key}"${name.value.trim().replace(/[.*+?^${}|[\]\\]/g, '\\$&')}"`;
          };
        }
      };
      kind.addEventListener('change', parametersForKind); parametersForKind();
      body.append(field('Add a condition (all must pass)', kind), parameters, button('Add condition', () => {
        try { const token = makeToken(); commit({...line, modifiers: [...line.modifiers, token]}); }
        catch (failure) { error.textContent = failure.message; }
      }), el('p', {class: 'help'}, 'Mana and stamina use points, not percentages. Times per pass is not N total casts per target. The whole sequence normally loops; (xx) means five repeats. Repeat-on-target retains this step after success, one action per engine tick; a failed condition or action advances normally. Target switches restart the sequence. Unknown imported modifiers are retained, not certified as supported.'));
      if (!state.boot.capabilities?.repeat_until_target_gone) body.append(note('This engine does not advertise repeat-until-target-gone support. Upgrade Hunter and setup together before using untildead.', 'warning'));
    }
    draw(); box.append(summary, body, error); return box;
  }
  function renderRaw(main) {
    main.append(el('p', {class: 'intro'}, 'Expert editing of the same draft. Unrecognized settings are retained; their behavior is not claimed by this editor. JSON formatting does not retain legacy YAML comments.'));
    const input = el('textarea', {class: 'raw-editor', id: 'raw-json', spellcheck: 'false', 'aria-label': 'Raw configuration JSON'}, state.invalid.get('__raw')?.text ?? pretty(state.draft));
    const error = el('p', {class: 'error-text', role: 'status'}, state.invalid.get('__raw')?.error || '');
    input.addEventListener('input', () => {
      try {
        const data = JSON.parse(input.value);
        if (!data || Array.isArray(data) || typeof data !== 'object') throw new Error('The document must be a JSON object.');
        if (state.kind !== 'plan' && (!data.settings || Array.isArray(data.settings) || typeof data.settings !== 'object')) throw new Error('Keep the settings object inside the native envelope.');
        state.draft = data; state.invalid.clear(); error.textContent = ''; input.removeAttribute('aria-invalid'); changed();
      } catch (exception) { state.invalid.set('__raw', {text: input.value, error: exception.message}); error.textContent = exception.message; input.setAttribute('aria-invalid', 'true'); changed(); }
    });
    main.append(el('section', {class: 'card'}, input, error));
    const unknown = Object.keys(state.draft.settings || {}).filter((key) => !state.boot.fields.some((f) => f.key === key));
    if (unknown.length) main.append(note(`Preserved keys without described controls: ${unknown.join(', ')}. They may be inactive or extension-specific.`, 'warning'));
  }
  function rowsForDiff(before, after, prefix = '') {
    const result = [];
    for (const key of new Set([...Object.keys(before || {}), ...Object.keys(after || {})])) {
      const left = before?.[key], right = after?.[key];
      if (pretty(left) === pretty(right)) continue;
      if (key === 'settings' && left && right) result.push(...rowsForDiff(left, right, 'settings.'));
      else result.push([prefix + key, left, right]);
    }
    return result;
  }
  function diffTable(before, after) {
    const changes = rowsForDiff(before, after);
    if (!changes.length) return el('p', {class: 'empty'}, 'No configuration changes.');
    return el('div', {class: 'table-scroll'}, el('table', {}, el('thead', {}, el('tr', {}, ['Setting', 'Saved / previous', 'Current draft'].map((x) => el('th', {}, x)))), el('tbody', {}, changes.map(([key, left, right]) => el('tr', {}, el('td', {}, el('code', {}, key)), el('td', {}, el('code', {}, pretty(left) ?? '(not set)')), el('td', {class: 'changed'}, el('code', {}, pretty(right) ?? '(removed; use fallback)')))))));
  }
  function renderCompare(main) {
    main.append(el('p', {class: 'intro'}, 'Compare the current draft with the revision you opened, or read the latest saved version without replacing your draft.'), el('section', {class: 'card'}, el('h2', {}, 'Changes since opening'), diffTable(state.baseline, state.draft)));
    if (state.loadedName) main.append(button('Compare against latest saved version', async () => {
      try { const current = await api('read', {kind: state.kind, name: state.loadedName, source: state.source}); main.append(el('section', {class: 'card spaced'}, el('h2', {}, 'Latest saved version → current draft'), diffTable(current.data, state.draft))); }
      catch (error) { fail(error); }
    }));
  }
  function issues(title, values, style) {
    if (!values?.length) return null;
    return el('section', {class: `notice ${style}`}, el('h3', {}, title), el('ul', {}, values.map((item) => el('li', {}, typeof item === 'string' ? item : item.message || pretty(item)))));
  }
  function missingFor(checked) {
    const missing = [...(checked.missing || [])];
    if (state.kind === 'profile' && !String(state.draft.settings?.targets || '').trim() && !state.anyTargets) missing.push({key: 'targets', message: 'Choose creatures to hunt, or explicitly confirm that any eligible creature is intended.'});
    if (state.kind === 'profile' && !String(checked.effective?.hunting_commands || state.draft.settings?.hunting_commands || '').trim()) missing.push({key: 'hunting_commands', message: 'Add a usual combat sequence or link a saved Combat Plan.'});
    return missing;
  }
  function fixIssues(title, values, style) {
    if (!values.length) return null;
    return el('section', {class: `notice ${style}`}, el('h3', {}, title), el('ul', {}, values.map((item) => {
      const field = state.boot.fields.find((field) => field.key === item.key);
      return el('li', {}, typeof item === 'string' ? item : item.message || pretty(item), field ? button(`Edit ${field.label}`, () => navigate(normalizedPage(field.page), field.key), 'issue-link') : null);
    })));
  }
  function renderReview(main) {
    main.append(el('p', {class: 'intro'}, 'Review the effective configuration and changes before saving. A saved revision is used by a subsequent launch; any running hunt keeps its existing configuration.'), nameControl());
    const summary = el('dl', {class: 'review-summary'});
    [['Character', `${state.boot.context?.character || 'Unknown'} · ${state.boot.context?.game || 'Unknown game'}`], ['Scope', state.kind], ['Source', state.source === 'legacy' ? 'Legacy source → new EOHunter copy' : 'EOHunter-owned'], ['Defaults', state.draft.defaults || 'Independent profile'], ['Combat Plan', state.draft.combat_plan || 'Inherited / existing routines'], ['Targets', state.draft.settings?.targets || 'Empty target list: all otherwise eligible creatures'], ['Validation mode', state.mode], ['Hunt start', 'No hunt is started by saving']].forEach(([label, value]) => summary.append(el('dt', {}, label), el('dd', {}, String(value))));
    main.append(el('section', {class: 'card'}, el('h2', {}, 'At a glance'), summary));
    const results = el('div', {id: 'validation-results'});
    const show = (validation) => {
      results.replaceChildren();
      const missing = missingFor(validation), errors = validation.errors || [];
      results.append(note(errors.length ? 'Fix the configuration errors before saving.' : missing.length ? 'Not ready to hunt. You may save an unfinished draft, but complete the items below before using it.' : 'Configuration checks passed. This is not a live safety check or permission to start a hunt.', errors.length ? 'error' : missing.length ? 'warning' : ''),
        fixIssues('Fix before saving', errors, 'error') || '', fixIssues('Still needed before hunting', missing, 'warning') || '',
        issues('Warnings to review', validation.warnings, 'warning') || note('Hazard coverage is limited. Unrecognized scripts, commands and equipment effects are not certified safe.', 'warning'));
      if (validation.hazard_coverage) results.append(el('details', {class: 'card'}, el('summary', {}, 'What the hazard check covers'), el('pre', {}, typeof validation.hazard_coverage === 'string' ? validation.hazard_coverage : pretty(validation.hazard_coverage))));
      if (validation.effective_recovery || validation.recovery_fallback) results.append(el('details', {class: 'card'}, el('summary', {}, 'Integrated recovery and compatibility fallback'), el('pre', {}, pretty({effective_recovery: validation.effective_recovery, read_only_fallback: validation.recovery_fallback}))));
      if (validation.effective) results.append(el('details', {class: 'card'}, el('summary', {}, 'Effective settings & sources'), el('pre', {}, pretty({settings: validation.effective, provenance: validation.provenance}))));
    };
    main.append(button('Check effective configuration', async () => { try { status('Checking this draft…'); show(await validate()); status('Configuration check complete.'); } catch (error) { fail(error); } }), results);
    if (state.validation && state.validationGeneration === state.generation) show(state.validation);
    main.append(el('section', {class: 'card spaced'}, el('h2', {}, 'Change preview'), diffTable(state.baseline, state.draft)));
    if (state.kind !== 'profile') {
      const impact = el('div');
      main.append(el('section', {class: 'card'}, el('h2', {}, 'Shared configuration impact'), el('p', {}, 'Linked hunts use this saved change on their next launch. Review the affected hunts before saving.'), button('Preview linked hunts', async () => {
        try {
          const linked = [];
          for (const name of names(state.boot.profiles)) {
            const profile = (await api('read', {kind: 'profile', name})).data;
            if (state.kind === 'defaults' ? profile.defaults === state.loadedName : profile.combat_plan === state.loadedName || Object.values(profile.creature_plans || {}).includes(state.loadedName)) linked.push(name);
          }
          impact.replaceChildren(note(linked.length ? `Directly linked hunts: ${linked.join(', ')}. Plans may also be inherited through character defaults.` : 'No directly linked hunts found. A plan may also be inherited through character defaults.'));
        } catch (error) { fail(error); }
      }), impact));
    }
    const saveButton = button('Save to EOHunter', save, 'primary'); saveButton.disabled = state.saving;
    main.append(note('Only EOHunter-owned files are written. Legacy Bigshot profiles and standalone ecleanse settings remain untouched.'), saveButton);
  }
  async function save() {
    if (state.saving) return;
    if (state.sequenceDraft) return status('Save or cancel the new combat sequence first. Your hunt draft is still intact.', true);
    if (!state.name.trim()) return status('Give this configuration a name before saving.', true);
    if (state.invalid.size) return status('Correct invalid JSON fields before saving. Your draft is preserved.', true);
    state.saving = true;
    state.readRequest += 1;
    const documentId = state.documentId, kind = state.kind;
    try {
      const validation = await validate();
      if (validation.errors?.length) { state.validation = validation; render(); throw new Error('Resolve the reported configuration errors before saving.'); }
      const data = clone(state.draft), name = state.name.trim(), generation = state.generation;
      const result = await api('save', {kind, name, data, revision: state.source === 'native' && name === state.loadedName ? state.revision : null});
      if (documentId !== state.documentId) return;
      state.revision = result.revision; state.loadedName = name; state.source = 'native'; state.baseline = data;
      if (generation === state.generation) state.name = name;
      const listKey = kind === 'profile' ? 'profiles' : kind === 'plan' ? 'plans' : 'defaults';
      if (!names(state.boot[listKey]).includes(name)) state.boot[listKey].push(name);
      status(`Saved “${name}” to EOHunter. ${missingFor(validation).length ? 'Saved as an unfinished draft; complete the review items before hunting. ' : ''}No hunt was started.${generation !== state.generation ? ' Newer draft changes remain unsaved.' : ''}`); render();
    } catch (error) { fail(error); }
    finally { state.saving = false; if (state.page === 'review') render(); else updateHeader(); }
  }
  function targetEntries(raw = state.draft.settings.targets) {
    if (raw != null && typeof raw !== 'string') return null;
    return String(raw || '').split(',').map((entry) => entry.trim()).filter(Boolean).map((entry) => { const match = entry.match(/^(.*?)\(([a-j])\)$/i); return {name: (match ? match[1] : entry).trim(), slot: match ? match[2] : 'a'}; });
  }
  function listEntries(key) { const raw = state.draft.settings[key]; return Array.isArray(raw) ? raw.map(String) : String(raw || '').split(',').map((entry) => entry.trim()).filter(Boolean); }
  const mapKeys = ['hunting_room_id', 'hunting_boundaries', 'resting_room_id', 'field_rest_room_id'];
  const mapMarks = [
    ['selected-room', '+', 'Hunting rooms'], ['excluded-room', '−', 'Outside hunt'],
    ['boundary-room', 'B', 'Boundary'], ['starting-room', 'S', 'Starting room'],
    ['field-rest-room', 'F', 'Field rest'], ['town-rest-room', 'T', 'Town rest']
  ];
  function mapLegend() {
    return el('div', {class: 'map-legend', 'aria-label': 'Map color legend'}, mapMarks.map(([css, symbol, label]) =>
      el('span', {class: 'map-legend-item'}, el('span', {class: `map-swatch ${css}`, 'aria-hidden': 'true'}, symbol), label)));
  }
  function mapTools(label, choices, change) {
    const tools = el('div', {class: 'map-tools', role: 'group', 'aria-label': label});
    for (const [value, name, help] of choices) {
      const pick = button(name, () => {
        change(value);
      });
      pick.title = help;
      tools.append(pick);
    }
    return tools;
  }
  function mapFeedback(message) { return el('p', {class: 'map-feedback', role: 'status', 'aria-live': 'polite'}, message); }
  const mapPickedRooms = new Map();
  function applyPickedRoom(owner, action, choose) {
    const room = mapPickedRooms.get(`${state.documentId}:${owner}`);
    if (room) choose(room, action);
    else status('Right-click a room for actions, or focus a room first and then choose a tool.', true);
  }
  function mapSettings() { return Object.fromEntries(mapKeys.filter((key) => own(state.draft.settings || {}, key)).map((key) => [key, state.draft.settings[key]])); }
  function restMapButton(key, proposal = false) {
    const label = key === 'field_rest_room_id' ? 'field rest' : 'town rest';
    return button(`Choose ${label} on another map`, () => openRestMap(key, proposal));
  }
  // An isolated, tentative selection. Browsing never replaces the hunt footprint.
  function openRestMap(key, proposal) {
    const label = key === 'field_rest_room_id' ? 'field rest' : 'town rest';
    const documentId = state.documentId, opener = document.activeElement;
    const initial = proposal && own(state.footprintRest, key) ? state.footprintRest[key] : effective(key);
    const dialog = el('dialog', {class: 'rest-map-dialog', 'aria-label': `Choose ${label} room`});
    const sheet = el('select', {'aria-label': 'Rest room map', disabled: true});
    const search = el('input', {type: 'search', 'aria-label': 'Search rest maps', placeholder: 'Search map names'});
    const content = el('div', {class: 'rest-map-content'}), feedback = mapFeedback('Loading available maps…');
    let request = 0, closed = false, maps = [], labels = {}, selected = null, current = null;
    const close = () => { if (!closed) { closed = true; request++; dismissRoomActions?.(); dialog.close(); dialog.remove(); if (opener?.isConnected) opener.focus({preventScroll: true}); } };
    const confirm = button(`Use this room for ${label}`, () => {
      if (!selected || closed || documentId !== state.documentId) return;
      const room = selected;
      if (proposal) {
        rememberFootprint(); state.footprintRest[key] = String(room.id);
        state.mapMessage = `${label === 'field rest' ? 'Field rest' : 'Town rest'}: #${room.id} · ${room.title}. Apply the hunting footprint to keep this choice.`;
      } else {
        state.mapUndo.push({settings: clone(mapSettings()), provenance: state.draft.area_provenance ? clone(state.draft.area_provenance) : null});
        state.draft.settings[key] = String(room.id); state.invalid.delete(key);
        // A pending area proposal must not later restore an older rest choice.
        if (own(state.footprintRest, key)) delete state.footprintRest[key];
        changed();
      }
      close(); render(); status(`${label === 'field rest' ? 'Field rest' : 'Town rest'} set to #${room.id}. Hunting rooms, starting room, targets and boundaries unchanged. ${proposal ? 'Apply the footprint, then save.' : 'Save is still required.'}`);
    }, 'primary');
    confirm.disabled = true;
    const populate = () => {
      const previous = sheet.value;
      const filtered = maps.filter((name) => `${labels[name] || ''} ${name}`.toLowerCase().includes(search.value.toLowerCase()));
      sheet.replaceChildren(el('option', {value: ''}, 'Choose a map'), ...filtered.map((name) => el('option', {value: name}, labels[name] ? `${labels[name]} — ${name}` : name)));
      sheet.value = filtered.includes(previous) ? previous : '';
      sheet.disabled = !maps.length;
    };
    const display = (data, name) => {
      const rooms = data.rooms.filter((room) => room.image === name);
      const choose = (room) => { selected = room; confirm.disabled = false; feedback.textContent = `Selected #${room.id} · ${room.title}. Confirm below to use it for ${label}.`; display(data, name); };
      const describe = (room) => {
        const chosen = room.id === (selected?.id ?? current), css = key === 'field_rest_room_id' ? 'field-rest-room' : 'town-rest-room';
        return {editable: true, css: chosen ? css : 'excluded-room', markers: chosen ? [[css, key === 'field_rest_room_id' ? 'F' : 'T']] : [],
          roles: {[key]: chosen}, label: `Room ${room.id}: ${room.title}${chosen ? `; ${label}` : ''}`};
      };
      content.replaceChildren(roomMaps(rooms, [], describe, choose, 'rest-map-picker', [], [[key, label]]));
      const list = el('details', {}, el('summary', {}, 'Find a rest room by name or number'));
      const filter = el('input', {type: 'search', 'aria-label': 'Find rest room', placeholder: 'Name or room number'}), options = el('div', {class: 'room-choices'});
      const fill = () => { const found = rooms.filter((room) => `${room.id} ${room.title}`.toLowerCase().includes(filter.value.toLowerCase())); options.replaceChildren(el('p', {}, `${found.length} matches; showing up to 100.`), ...found.slice(0, 100).map((room) => button(`#${room.id} · ${room.title}`, () => choose(room)))); };
      filter.addEventListener('input', fill); fill(); list.append(filter, options); content.append(list);
      if (!rooms.length) content.prepend(note('No rooms are mapped on this sheet.', 'warning'));
    };
    const load = async (name) => {
      const token = ++request; selected = null; confirm.disabled = true; content.replaceChildren(note('Loading map…'));
      feedback.textContent = 'Loading map…';
      try {
        const data = await api('profile_map', {settings: initial ? {[key]: initial} : {}, sheet: name || null});
        if (closed || token !== request || documentId !== state.documentId) return;
        maps = data.sheets || []; labels = data.sheet_labels || {}; current = data.markers?.[key]; populate();
        const shown = name || data.rooms.find((room) => room.id === current)?.image;
        if (shown) { sheet.value = shown; display(data, shown); }
        else content.replaceChildren(note('Select any installed map above. It does not need to contain your hunting area.'));
        feedback.textContent = (data.diagnostics || []).join(' ') || 'Click a room to select it, then confirm. No game commands are sent.';
      } catch (error) {
        if (!closed && token === request) { feedback.textContent = error.message; content.replaceChildren(button('Retry rest map', () => load(name))); }
      }
    };
    sheet.addEventListener('change', () => load(sheet.value));
    search.addEventListener('input', populate);
    dialog.addEventListener('cancel', (event) => { event.preventDefault(); close(); });
    dialog.append(el('h2', {}, `Choose ${label} room`), el('p', {class: 'help'}, 'Browse any classic map. Rest rooms may be outside the hunting area. Choosing a room does not verify that it is safe.'),
      search, sheet, feedback, content, el('div', {class: 'rest-map-footer'}, button('Cancel', close), confirm));
    document.body.append(dialog); dialog.showModal(); load(null);
  }
  function profileMapKey() { return pretty([state.documentId, mapSettings(), state.profileMapSheet]); }
  function resetProfileMap() {
    state.profileMapRequest += 1;
    state.profileRoomRequest += 1;
    Object.assign(state, {profileMap: null, profileMapKey: '', profileMapBusy: false, profileMapSheet: '', mapUndo: [], profileMapMessage: '', profileRoomBusy: null});
  }
  async function loadProfileMap() {
    const key = profileMapKey(), request = ++state.profileMapRequest;
    state.profileMapKey = key; state.profileMapBusy = true; state.profileMap = null;
    try {
      const result = await api('profile_map', {settings: mapSettings(), sheet: state.profileMapSheet || null});
      if (request !== state.profileMapRequest || key !== profileMapKey()) return;
      state.profileMap = result;
    } catch (error) {
      if (request === state.profileMapRequest && key === profileMapKey()) state.profileMap = {error: error.message};
    } finally {
      if (request === state.profileMapRequest) {
        state.profileMapBusy = false;
        // Refresh only this panel: do not discard focus/input in other fields.
        if ($('profile-map')) { const replacement = document.createElement('div'); renderProfileMap(replacement); $('profile-map').replaceWith(...replacement.childNodes); }
      }
    }
  }
  function renderProfileMap(main) {
    const optional = !mapKeys.some((key) => String(state.draft.settings?.[key] || '').trim());
    const card = el(optional ? 'details' : 'section', {class: 'card', id: 'profile-map'}, el(optional ? 'summary' : 'h2', {}, optional ? 'Choose rooms manually on a map (optional)' : 'Your profile on the map'),
      el('p', {class: 'help'}, 'These markers come from this profile—not a suggested creature habitat. Click to edit the draft; Save is still required. Existing custom boundaries are kept until you change them.'));
    main.append(card);
    if (state.profileMapKey !== profileMapKey()) {
      card.append(note('Loading the current profile’s mapped rooms…'));
      queueMicrotask(() => { if (state.profileMapKey !== profileMapKey()) loadProfileMap(); });
      return;
    }
    if (state.profileMapBusy || !state.profileMap) { card.append(note('Reading map data…')); return; }
    const data = state.profileMap;
    if (data.error) { card.append(note(data.error, 'warning'), button('Retry map', () => { state.profileMapKey = ''; render(); })); return; }
    const sheet = el('select', {'aria-label': 'Additional map sheet'}, el('option', {value: ''}, 'Show sheets containing this profile’s rooms'), (data.sheets || []).map((name) => el('option', {value: name}, name)));
    sheet.value = state.profileMapSheet;
    sheet.addEventListener('change', () => { state.profileMapSheet = sheet.value; render(); });
    card.append(el('label', {class: 'control-label'}, 'Show another map sheet (for a different start or rest room)', sheet), restMapButton('field_rest_room_id'), restMapButton('resting_room_id'));
    const tools = mapTools('Profile map click action', [
      ['hunting_boundaries', 'Boundary on/off', 'Click a room to add or remove a hunting boundary. The green preview is recalculated.'],
      ['hunting_room_id', 'Starting room', 'Click an interior room to set the hunting start.'],
      ['field_rest_room_id', 'Field rest', 'Click your nearby resting room. This does not certify that it is safe.'],
      ['resting_room_id', 'Town rest', 'Click your main rest and services destination.']
    ], (mode) => applyPickedRoom('profile-map', mode, choose));
    const undo = button('Undo map edit', () => {
      const previous = state.mapUndo.pop(); if (!previous) return;
      for (const key of mapKeys) { if (own(previous.settings, key)) state.draft.settings[key] = previous.settings[key]; else delete state.draft.settings[key]; }
      if (previous.provenance) state.draft.area_provenance = previous.provenance; else delete state.draft.area_provenance;
      invalidateFootprint(); changed(); render();
    });
    undo.disabled = !state.mapUndo.length;
    card.append(el('p', {class: 'control-label spaced'}, 'Left-click: room on/off. Right-click: room actions. Tools below act on the last clicked or focused room.'), tools, undo, mapLegend(),
      mapFeedback(state.profileMapMessage || 'Left-click changes hunting rooms; right-click chooses the start, boundary or rest spot. Save is still required.'),
      note('Classic maps with your profile’s room markers. The green hunting preview uses recorded exits, not live movement or access checks. Rest markers are your choices, not certified safe rooms.', 'warning'));
    if (data.truncated) card.append(note('The area preview reached Hunter’s room limit. It is incomplete; check the start and boundaries before hunting.', 'warning'));
    if (data.diagnostics?.length) card.append(issues('Map settings need attention', data.diagnostics, 'warning'));
    const markers = data.markers || {}, boundaryIds = new Set(markers.hunting_boundaries || []), hunting = new Set(data.hunting_room_ids || []);
    card.append(el('p', {}, `Start: ${markers.hunting_room_id || 'not set'} · Town rest: ${markers.resting_room_id || 'not set'} · Field rest: ${markers.field_rest_room_id || 'not set'} · Boundaries: ${[...boundaryIds].join(', ') || 'none'}`));
    const choose = async (room, action = 'toggle') => {
      if (data !== state.profileMap || state.profileMapKey !== profileMapKey() || !data.editable) return;
      if (state.profileRoomBusy) return status('Finishing the previous room edit. Please wait for the updated map.', true);
      if (!data.rooms.some((entry) => entry.id === room.id)) return;
      const key = action === 'start' ? 'hunting_room_id' : action === 'boundary' ? 'hunting_boundaries' : action;
      if (['toggle', 'include', 'exclude'].includes(key)) {
        if (data.truncated) return status('The current route is incomplete. Narrow its boundaries before editing individual rooms.', true);
        const include = key === 'include' || (key === 'toggle' && !hunting.has(room.id));
        const ids = include ? [...new Set([...hunting, room.id])] : [...hunting].filter((id) => id !== room.id);
        const beforeKey = profileMapKey(), generation = state.generation, request = ++state.profileRoomRequest;
        state.profileRoomBusy = request;
        $('profile-map')?.setAttribute('aria-busy', 'true');
        const feedback = $('profile-map')?.querySelector('.map-feedback'); if (feedback) feedback.textContent = 'Recalculating the edited room selection…';
        try {
          const result = await api('room_geometry', {room_ids: ids, start_room_id: markers.hunting_room_id});
          if (beforeKey !== profileMapKey() || generation !== state.generation || data !== state.profileMap) return;
          state.mapUndo.push({settings: clone(mapSettings()), provenance: state.draft.area_provenance ? clone(state.draft.area_provenance) : null});
          state.draft.settings.hunting_boundaries = result.boundary_ids.join(', ');
          delete state.draft.area_provenance;
          state.profileMapMessage = `${include ? 'Included' : 'Excluded'} #${room.id} · ${room.title}. Boundaries recalculated; Save is still required.`;
          invalidateFootprint(); changed(); render(); status(state.profileMapMessage);
        } catch (error) {
          if (beforeKey !== profileMapKey() || generation !== state.generation) return;
          state.profileMapMessage = error.message; render(); fail(error);
        } finally {
          if (state.profileRoomBusy === request) { state.profileRoomBusy = null; $('profile-map')?.removeAttribute('aria-busy'); }
        }
        return;
      }
      if (key === 'hunting_boundaries' && room.id === markers.hunting_room_id && !boundaryIds.has(room.id)) return status('Move the hunting start before making that room a boundary.', true);
      state.mapUndo.push({settings: clone(mapSettings()), provenance: state.draft.area_provenance ? clone(state.draft.area_provenance) : null});
      const removing = key === 'hunting_boundaries' ? boundaryIds.has(room.id) : markers[key] === room.id;
      if (key === 'hunting_boundaries') {
        const refs = data.boundary_refs || [];
        state.draft.settings[key] = (boundaryIds.has(room.id) ? refs.filter((entry) => entry.id !== room.id).map((entry) => entry.ref) : [...refs.map((entry) => entry.ref), String(room.id)]).join(', ');
      } else {
        // An explicit empty value clears the role without restoring an inherited default.
        state.draft.settings[key] = removing ? '' : String(room.id);
        if (!removing && key === 'hunting_room_id' && boundaryIds.has(room.id)) state.draft.settings.hunting_boundaries = (data.boundary_refs || []).filter((entry) => entry.id !== room.id).map((entry) => entry.ref).join(', ');
      }
      delete state.draft.area_provenance; // A manual route is no longer the approved habitat proposal.
      state.profileMapMessage = `${{hunting_room_id: 'Starting room', hunting_boundaries: 'Boundary', resting_room_id: 'Town rest', field_rest_room_id: 'Field rest'}[key]} ${removing ? 'removed from' : 'set to'} #${room.id} · ${room.title}. Draft changed; Save is still required.`;
      invalidateFootprint(); changed(); render(); status(state.profileMapMessage);
    };
    const describe = (room) => {
      const start = room.id === markers.hunting_room_id, town = room.id === markers.resting_room_id, field = room.id === markers.field_rest_room_id, boundary = boundaryIds.has(room.id);
      const labels = [start && 'starting room', boundary && 'boundary', town && 'town rest', field && 'field rest'].filter(Boolean);
      return {editable: data.editable, boundary, css: `${hunting.has(room.id) ? 'selected-room' : 'excluded-room'}${boundary ? ' boundary-room' : ''}${start ? ' starting-room' : ''}${town ? ' town-rest-room' : ''}${field ? ' field-rest-room' : ''}`,
        roles: {toggle: hunting.has(room.id), boundary, start, resting_room_id: town, field_rest_room_id: field},
        markers: [start && ['starting-room', 'S'], town && ['town-rest-room', 'T'], field && ['field-rest-room', 'F']].filter(Boolean),
        label: `Room ${room.id}: ${room.title}; ${labels.join(', ') || 'mapped room'}`};
    };
    if (!data.rooms?.length) { card.append(note('Choose a map sheet above, or enter a starting room below to display its map.')); return; }
    card.append(roomMaps(data.rooms, data.room_edges || [], describe, choose, 'profile-map'));
    const roomList = el('details', {}, el('summary', {}, 'Find a room by name or number'));
    const filter = el('input', {type: 'search', 'aria-label': 'Find profile map room', placeholder: 'Name or room number'}), options = el('div', {class: 'room-choices'});
    const populate = () => {
      const matching = data.rooms.filter((room) => `${room.id} ${room.title}`.toLowerCase().includes(filter.value.toLowerCase()));
      options.replaceChildren(el('p', {class: 'help'}, `${matching.length} matches; showing up to 100.`), ...matching.slice(0, 100).map((room) => {
        const pick = button(`#${room.id} · ${room.title}`, () => { mapPickedRooms.set(`${state.documentId}:profile-map`, room); showRoomActions(pick, room, choose, describe(room).roles); }); pick.disabled = !data.editable; return pick;
      }));
    };
    filter.addEventListener('input', populate); populate(); roomList.append(filter, options); card.append(roomList);
  }
  // Static sheet context is shared across rerenders; selection is always taken
  // from the current draft preview, never cached with the room coordinates.
  const regionMaps = new Map();
  function renderRegionMap(container) {
    const sheet = state.mapName;
    const label = [...(state.areas || [])].flatMap((area) => area.maps || []).find((map) => map.id === sheet)?.name || sheet;
    const selected = new Set(state.footprintRooms || []);
    const title = state.area?.zone_label || state.areaName;
    const card = el('section', {class: 'card region-map-preview', id: 'region-map-preview', 'aria-label': 'Selected region map'},
      el('h2', {}, sheet && sheet !== '@unmapped' ? label : 'Your hunting map'));
    container.append(card);
    if (!sheet || sheet === '@unmapped') {
      card.append(note(sheet ? 'No classic map is recorded for this region. Use the room list to review the area.' : 'Choose a map / region to see it here. Then choose a hunting area to highlight its rooms.'));
      return;
    }
    card.append(el('p', {class: 'help', role: 'status'}, selected.size ? `${title}: ${selected.size} proposed ${selected.size === 1 ? 'room' : 'rooms'} highlighted in green. This preview does not change your saved hunt.` : 'Choose a hunting area to highlight its rooms. Browsing does not change your saved hunt.'));
    const content = el('div', {}, note('Loading region map…'));
    card.append(content);
    const load = async () => {
      try {
        if (!regionMaps.has(sheet)) {
          const request = api('profile_map', {settings: {}, sheet});
          regionMaps.set(sheet, request);
          request.catch(() => { if (regionMaps.get(sheet) === request) regionMaps.delete(sheet); });
        }
        const data = await regionMaps.get(sheet);
        if (!card.isConnected) return;
        const rooms = (data.rooms || []).filter((room) => room.image === sheet);
        if (!rooms.length) { content.replaceChildren(note('This sheet has no positioned room data to preview.', 'warning')); return; }
        content.replaceChildren(roomMaps(rooms, [], (room) => ({editable: false,
          css: selected.has(room.id) ? 'selected-room' : 'excluded-room',
          label: `Room ${room.id}: ${selected.has(room.id) ? 'selected hunting area' : 'outside selected area'}`
        }), () => {}, 'region-overview'));
      } catch (error) {
        if (card.isConnected) content.replaceChildren(note(`Region preview unavailable: ${error.message}`, 'warning'), button('Retry region preview', load));
      }
    };
    queueMicrotask(load);
  }

  function renderArea(main) {
    if (state.guided) {
      const controls = el('div', {class: 'area-controls'}), preview = el('div', {class: 'area-preview-column'});
      main.append(el('div', {class: 'area-browser-layout'}, controls, preview));
      renderRegionMap(preview);
      main = controls;
    }
    if (state.kind === 'profile') renderProfileMap(main);
    const card = el('section', {class: 'card'}, el('h2', {}, 'Map → hunting area → creatures'), el('p', {class: 'help'}, 'Choose the overall map first, then the particular place you want to hunt. Creature choices appear only for that hunting area. Browsing does not replace your current route.'));
    const search = el('input', {type: 'search', placeholder: 'Search area names', 'aria-label': 'Search hunting areas'});
    const mapSelect = el('select', {'aria-label': 'Map or region'}, el('option', {value: ''}, 'Load maps to choose a region'));
    const select = el('select', {'aria-label': 'Hunting area', disabled: !state.mapName}, el('option', {value: ''}, 'Choose a map first'));
    function populate() {
      const maps = new Map(), options = [], seenZones = new Set();
      for (const area of state.areas || []) {
        const areaMaps = area.maps?.length ? area.maps : [{id: '@unmapped', name: 'Unmapped habitats (manual review)'}];
        areaMaps.forEach((map) => maps.set(map.id, map.name));
        const entries = area.zones?.length ? area.zones : [{id: '', label: area.name, maps: areaMaps}];
        for (const zone of entries) {
          const membership = zone.maps || areaMaps;
          if (!membership.some((map) => map.id === state.mapName)) continue;
          const zoneKey = `${zone.parent_label || ''}::${zone.id}`;
          if (zone.id && seenZones.has(zoneKey)) continue;
          const label = zone.id ? `${area.name} — ${zone.label}` : area.name;
          if (!label.toLowerCase().includes(search.value.toLowerCase())) continue;
          if (zone.id) seenZones.add(zoneKey);
          options.push(el('option', {value: zone.id ? `${area.name}::${zone.id}` : area.name, 'data-area': area.name, 'data-zone': zone.id}, label));
        }
      }
      mapSelect.replaceChildren(el('option', {value: ''}, 'Choose a map / region'), ...[...maps].sort((a, b) => a[1].localeCompare(b[1])).map(([id, name]) => el('option', {value: id}, name)));
      mapSelect.value = state.mapName;
      select.replaceChildren(el('option', {value: ''}, state.mapName ? 'Choose a hunting area' : 'Choose a map first'), ...options);
      select.disabled = !state.mapName;
      select.value = state.zoneId ? `${state.areaName}::${state.zoneId}` : state.areaName;
    }
    mapSelect.addEventListener('change', () => {
      state.mapName = mapSelect.value; state.areaName = ''; state.zoneId = ''; state.area = null;
      state.areaRequest += 1; invalidateFootprint(); render();
    });
    search.addEventListener('input', populate);
    if (state.areas) populate();
    async function loadAreas() {
      if (state.loadingAreas) return;
      state.loadingAreas = true;
      try { const result = await api('areas'); state.areas = Array.isArray(result) ? result : result.areas || []; populate(); if (card.isConnected) status(`${state.areas.length} habitats available from installed creature data.`); }
      catch (error) { if (card.isConnected) fail(error); }
      finally { state.loadingAreas = false; if (state.page === 'area' && !card.isConnected) render(); }
    }
    async function previewArea() {
      if (!select.value) {
        state.areaName = ''; state.zoneId = ''; state.area = null; state.areaRequest += 1;
        invalidateFootprint(); render(); return;
      }
      const selected = select.selectedOptions[0], name = selected.dataset.area, zone = selected.dataset.zone || '';
      const documentId = state.documentId, request = ++state.areaRequest;
      state.areaName = name; state.zoneId = zone; state.area = null;
      invalidateFootprint();
      // Remove the old preview immediately so its Apply button cannot assign
      // old boundaries to a newly selected area while a request is in flight.
      render();
      try {
        const area = await api('area', {area: name, zone: zone || null, map_image: state.mapName === '@unmapped' ? null : state.mapName});
        if (documentId !== state.documentId || request !== state.areaRequest) return;
        state.area = area;
        if (!area.zone_selection_required) adoptFootprint(area);
        render();
      } catch (error) { if (documentId === state.documentId && request === state.areaRequest) fail(error); }
    }
    card.append(button('Load / refresh areas', loadAreas), el('label', {class: 'control-label spaced'}, '1. Map / region', mapSelect),
      el('div', {class: 'spaced'}, search), el('label', {class: 'control-label spaced'}, '2. Hunting area', select));
    select.addEventListener('change', () => {
      if (state.guided) return previewArea();
      const selected = select.selectedOptions[0];
      state.areaName = selected?.dataset.area || ''; state.zoneId = selected?.dataset.zone || ''; state.area = null;
      state.areaRequest += 1; invalidateFootprint(); render();
    });
    if (state.guided) {
      if (!state.areas && !state.loadingAreas) queueMicrotask(loadAreas);
    } else card.append(button('Preview selected area', previewArea));
    main.append(card);
    if (!state.area) { main.append(note('Area suggestions come from installed creature and map data. Load and preview one, or use the existing area fields below. Safe entrance and rest choices need your review.', 'warning')); return; }
    const area = state.area;
    if (area.zone_selection_required) { main.append(note('Choose a named hunting area before selecting creatures.', 'warning')); return; }
    main.append(note(`3. Choose creatures in ${area.zone_label ? `${state.areaName} — ${area.zone_label}` : state.areaName}. Creature choices change targets only; transit rooms and your edited area remain selected.`));
    const any = el('input', {type: 'checkbox', checked: state.anyTargets});
    any.addEventListener('change', () => { state.anyTargets = any.checked; if (any.checked) set('targets', ''); else changed(); render(); });
    main.append(el('section', {class: 'card'}, el('h2', {}, 'Targeting rule'), el('p', {id: 'target-policy-summary'}, targetSummary()), el('label', {class: 'row'}, any, 'I intend to hunt any eligible creature (clears the selected list)'), el('p', {class: 'help'}, 'An empty target list in Hunter means all eligible creatures, not none. Exclusions and flee rules still apply.')));
    for (const [heading, creatures, help] of [
      ['Known creatures', area.creatures || [], 'Creatures recorded in the selected rooms.'],
      ['Can also appear here', area.visitors || [], 'Possible visitors, not regular residents. Choose how to respond if one appears. Choosing a visitor never adds its home area to your hunting rooms.']
    ]) {
      if (!creatures.length) continue;
      const entries = targetEntries();
      if (entries === null) { main.append(note('This profile uses a non-text target value. Keep it intact in Raw configuration or explicitly convert it to Hunter’s name(a), name(b) format before using creature controls.', 'warning')); return; }
      const body = el('tbody');
      for (const item of creatures) {
        const name = typeof item === 'string' ? item : item.name;
        if (!name) continue;
        const select = el('select', {'aria-label': `Response to ${name}`}, [['hunt', 'Hunt'], ['ignore', 'Do not target'], ['flee', 'Leave the room'], ['unchanged', 'Use current target rules']].map(([value, label]) => el('option', {value}, label)));
        select.value = listEntries('always_flee_from').includes(name) ? 'flee' : listEntries('invalid_targets').includes(name) ? 'ignore' : entries.some((entry) => entry.name === name) ? 'hunt' : 'unchanged';
        select.addEventListener('change', () => {
          if (select.value === 'unchanged') return;
          const current = targetEntries(), wanted = current.filter((entry) => entry.name !== name), ignored = listEntries('invalid_targets').filter((entry) => entry !== name), flee = listEntries('always_flee_from').filter((entry) => entry !== name);
          if (select.value === 'hunt') wanted.push(current.find((entry) => entry.name === name) || {name, slot: 'a'});
          if (select.value === 'ignore') ignored.push(name);
          if (select.value === 'flee') flee.push(name);
          state.draft.settings.targets = wanted.map((entry) => `${entry.name}(${entry.slot})`).join(', ');
          state.draft.settings.invalid_targets = ignored.join(', '); state.draft.settings.always_flee_from = flee.join(', '); changed();
          if (wanted.length) state.anyTargets = false;
          render();
          status(!wanted.length ? 'Target list is empty: all otherwise eligible creatures remain targetable. “Do not target” and flee rules still apply.' : 'Creature policy updated. Unlisted creatures are outside the explicit target list.');
        });
        const identity = el('td', {}, el('span', {}, name));
        if (item.reason) identity.append(el('p', {class: 'help'}, item.reason), el('p', {class: 'help'}, item.verification || ''));
        if (typeof item.source_url === 'string' && item.source_url.startsWith('https://gswiki.play.net/')) identity.append(el('a', {href: item.source_url, target: '_blank', rel: 'noopener noreferrer'}, 'Encounter source'));
        body.append(el('tr', {}, identity, el('td', {}, typeof item === 'object' ? item.level ?? 'Unknown' : 'Unknown'), el('td', {}, select)));
      }
      main.append(el('section', {class: 'card'}, el('h2', {}, heading), el('p', {class: 'help'}, help), el('p', {class: 'help'}, 'Do not target does not prevent incoming attacks or area effects. Leave the room uses Hunter’s flee policy. An empty target list means all otherwise eligible creatures; a populated list limits targeting to listed names. Priority and routine slots remain in the original target fields below.'), el('div', {class: 'table-scroll'}, el('table', {}, el('thead', {}, el('tr', {}, ['Creature', 'Level', 'Response'].map((label) => el('th', {}, label)))), body))));
    }
    renderFootprint(main);
  }
  function invalidateFootprint() {
    state.footprintRequest += 1;
    Object.assign(state, {footprint: null, footprintBase: null, footprintNames: [], footprintRooms: [], footprintStart: '', footprintBusy: false,
      footprintRest: {}, footprintBoundaries: [], footprintUndo: [], mapMessage: ''});
  }
  function adoptFootprint(result) {
    state.footprint = result; state.footprintBase = result;
    state.footprintNames = [...(result.selected_creature_names || [])];
    state.footprintRooms = [...(result.room_ids || [])];
    state.footprintRest = {}; state.footprintBoundaries = []; state.footprintUndo = []; state.mapMessage = '';
    const previousStart = Number(state.draft.settings.hunting_room_id);
    state.footprintStart = state.footprintRooms.includes(previousStart) ? String(previousStart) : '';
  }
  async function proposeFootprint(narrow = false) {
    const args = {area: state.areaName, zone: state.zoneId || null, map_image: state.mapName === '@unmapped' ? null : state.mapName || null};
    if (narrow) {
      args.room_ids = [...state.footprintRooms];
      args.added_room_ids = state.footprintRooms.filter((id) => !state.footprintBase.room_ids.includes(id));
    }
    const request = ++state.footprintRequest, documentId = state.documentId;
    state.footprintBusy = true; state.footprint = null;
    if (!narrow) state.footprintBase = null;
    render();
    try {
      const result = await api('area', args);
      if (request !== state.footprintRequest || documentId !== state.documentId) return;
      state.footprint = result;
      if (!narrow) adoptFootprint(result);
    } catch (error) { if (request === state.footprintRequest && documentId === state.documentId) fail(error); }
    finally { if (request === state.footprintRequest && documentId === state.documentId) { state.footprintBusy = false; render(); } }
  }
  function rememberFootprint() {
    state.footprintUndo.push({rooms: [...state.footprintRooms], start: state.footprintStart, rest: {...state.footprintRest}, boundaries: [...state.footprintBoundaries]});
    if (state.footprintUndo.length > 50) state.footprintUndo.shift();
  }
  function chooseFootprintRooms(ids) {
    rememberFootprint();
    state.footprintRequest += 1; state.footprintBusy = false; state.footprint = null;
    state.footprintRooms = [...new Set(ids)].sort((a, b) => a - b);
    if (!state.footprintRooms.includes(Number(state.footprintStart))) state.footprintStart = '';
    render();
  }
  function renderFootprint(main) {
    const applied = state.draft.area_provenance;
    const card = el('section', {class: 'card', id: 'footprint-editor'}, el('h2', {}, 'Suggested area — editable, not field-tested'),
      el('p', {class: 'help'}, 'Click green rooms to turn them off, or other mapped rooms to include them. Choose separate tools for your start and rest spots. Recalculate, then Apply to update the draft. Nothing is saved or executed by clicking the map.'));
    const suggest = button('Reset to suggested area rooms', () => proposeFootprint());
    suggest.disabled = state.footprintBusy;
    card.append(suggest);
    if (state.draft.settings.hunting_boundaries != null || applied) card.append(note(`Current draft route: ${state.draft.area || 'manual area'}, start ${state.draft.settings.hunting_room_id || 'not set'}, boundaries ${state.draft.settings.hunting_boundaries || '(none)'}. It is unchanged until you apply a proposal.`));
    if (state.footprintBusy) card.append(note('Calculating rooms and their perimeter…'));
    main.append(card);
    const base = state.footprintBase, proposal = state.footprint;
    if (!base) return;
    card.append(el('p', {class: 'help spaced'}, 'Static map data cannot verify current access, scripted travel, hazards or safe rest rooms. Review the area before applying it.'));
    const metadata = base.zone_metadata;
    if (metadata) {
      const limitations = el('details', {class: 'spaced'}, el('summary', {}, 'Area notes & limitations'));
      for (const message of metadata.notes || []) limitations.append(el('p', {class: 'help'}, message));
      for (const issue of base.diagnostics || []) if (['catalog_draft', 'catalog_static_check'].includes(issue.code)) limitations.append(el('p', {class: 'help'}, issue.message));
      if (metadata.excluded_uids?.length) limitations.append(el('p', {class: 'help'}, 'Special sections excluded from the suggestion remain unselected. Add rooms only after reviewing their access and hazards.'));
      card.append(limitations);
    }
    if (base.components.length > 1) {
      card.append(el('h3', {}, 'Choose a separate section'), el('p', {class: 'help'}, 'These mapped room sets are disconnected. Select one or narrow the room list; this does not invent plane or zone names.'));
      base.components.forEach((ids, index) => card.append(button(`Use section ${index + 1} (${ids.length} rooms; starts at #${ids[0]})`, () => { chooseFootprintRooms(ids); proposeFootprint(true); })));
    }
    const rooms = [...new Map([...(base.context_rooms || []), ...(base.boundary_rooms || []), ...(base.rooms || base.room_ids.map((id) => ({id, title: `Room ${id}`})))].map((room) => [room.id, room])).values()];
    card.append(footprintMap(rooms, base.context_edges || base.room_edges || []));
    const roomList = el('details', {class: 'card spaced'}, el('summary', {}, `Adjust rooms (${state.footprintRooms.length} selected; ${rooms.length} available)`));
    const filter = el('input', {type: 'search', placeholder: 'Room name or number', 'aria-label': 'Filter footprint rooms'});
    const rows = el('div', {class: 'room-choices'});
    const editableIds = new Set([...base.room_ids, ...(base.context_rooms || []).map((room) => room.id)]);
    rooms.forEach((room) => {
      const check = el('input', {type: 'checkbox', checked: state.footprintRooms.includes(room.id), disabled: !editableIds.has(room.id), 'aria-label': `Include room ${room.id}`});
      check.addEventListener('change', () => {
        const scroll = $('content-pane').scrollTop;
        chooseFootprintRooms(check.checked ? [...state.footprintRooms, room.id] : state.footprintRooms.filter((id) => id !== room.id));
        const next = $('footprint-room-list'); if (next) next.open = true;
        $('content-pane').scrollTop = scroll;
      });
      rows.append(el('label', {class: 'room-choice'}, check, `#${room.id} · ${room.title}`));
    });
    filter.addEventListener('input', () => { for (const row of rows.children) row.hidden = !row.textContent.toLowerCase().includes(filter.value.toLowerCase()); });
    roomList.id = 'footprint-room-list';
    roomList.append(filter, el('div', {class: 'actions spaced'}, button('Select all proposed rooms', () => chooseFootprintRooms(base.room_ids)), button('Clear room selection', () => chooseFootprintRooms([]))), rows);
    card.append(roomList);
    const recalculate = button('Recalculate boundaries for selected rooms', () => proposeFootprint(true));
    recalculate.disabled = state.footprintBusy || !state.footprintRooms.length;
    card.append(recalculate);
    if (!proposal) { card.append(note('Recalculate the edited selection before applying it. Your draft route has not changed.', 'warning')); return; }
    const ids = proposal.room_ids, boundaries = [...new Set([...proposal.boundary_ids, ...state.footprintBoundaries])].filter((id) => !ids.includes(id)).sort((a, b) => a - b);
    card.append(el('p', {class: 'spaced', id: 'footprint-count'}, `${ids.length} proposed hunting rooms · ${boundaries.length} boundary rooms · ${proposal.components.length} connected portions`));
    if (proposal.components.length > 1) card.append(note('This footprint is disconnected. Choose one section or adjust the rooms; it cannot be applied as one hunt.', 'warning'));
    if (proposal.coverage?.complete !== true) card.append(note('Map coverage is incomplete. This proposal cannot be applied automatically.', 'warning'));
    for (const issue of proposal.diagnostics || []) if (issue.code === 'no_mapped_entry') card.append(note(issue.message, 'warning'));
    const starting = el('select', {'aria-label': 'Choose a mapped starting room'}, el('option', {value: ''}, 'Choose a starting room you have checked'), ids.map((id) => el('option', {value: id}, `#${id} · ${rooms.find((room) => room.id === id)?.title || 'Room'}`)));
    starting.value = state.footprintStart;
    starting.addEventListener('change', () => { state.footprintStart = starting.value; render(); });
    card.append(el('label', {class: 'control-label spaced'}, 'Start inside these hunting rooms', starting));
    card.append(el('details', {class: 'spaced'}, el('summary', {}, 'Boundary changes, co-spawns & coverage'), el('p', {}, `Current boundaries: ${state.draft.settings.hunting_boundaries || '(not set)'}`), el('p', {}, `Proposed boundaries: ${boundaries.join(', ') || '(none)'}`),
      el('p', {}, `Also recorded in these rooms: ${(proposal.creatures || []).map((creature) => creature.name).join(', ') || 'none recorded'}. These are observations, not extra hunt targets.`),
      issues('Coverage diagnostics', proposal.diagnostics || [], 'warning') || '', el('pre', {}, pretty({rooms: ids, boundaries, opaque_edges: proposal.opaque_edges}))));
    const apply = button('Apply this hunting footprint', () => {
      const start = Number(state.footprintStart);
      if (state.footprint !== proposal || state.footprintBusy || proposal.components.length !== 1 || proposal.coverage?.complete !== true || !ids.includes(start)) return;
      state.draft.settings.hunting_boundaries = boundaries.join(', ');
      state.draft.settings.hunting_room_id = String(start);
      Object.assign(state.draft.settings, state.footprintRest);
      state.draft.area = state.areaName;
      state.draft.area_map = state.mapName;
      if (state.zoneId) state.draft.area_zone = state.zoneId; else delete state.draft.area_zone;
      state.draft.area_provenance = {area: state.areaName, map_image: proposal.map_image, zone_id: proposal.zone_id, zone_label: proposal.zone_label, creature_names: [...state.footprintNames], room_ids: [...ids], boundary_ids: [...boundaries], starting_room_id: start,
        added_room_ids: [...(proposal.added_room_ids || [])], zone_metadata: proposal.zone_metadata,
        verification: proposal.verification, data_revision: proposal.data_revision, map_revision: proposal.map_revision};
      changed(); render(); status('Hunting footprint and any explicitly chosen rest spots applied to the draft. Targets and combat routines were not changed. Save after reviewing.');
    }, 'primary');
    apply.disabled = state.footprintBusy || !ids.length || proposal.components.length !== 1 || proposal.coverage?.complete !== true || !ids.includes(Number(state.footprintStart));
    card.append(el('div', {class: 'spaced'}, apply));
  }
  function footprintMap(rooms, edges) {
    const details = el('details', {class: 'card spaced', id: 'footprint-map-picker'}, el('summary', {}, 'Choose rooms on the map'));
    details.open = state.mapOpen;
    details.addEventListener('toggle', () => { if (details.isConnected) state.mapOpen = details.open; });
    const tools = mapTools('Map click action', [
      ['toggle', 'Rooms on/off', 'Toggle the last clicked or focused room. Left-click a room for the same action.'],
      ['start', 'Starting room', 'Click an included room to mark where hunting starts.'],
      ['field_rest_room_id', 'Field rest', 'Click a nearby rest room, including one outside the hunting area.'],
      ['resting_room_id', 'Town rest', 'Click your main rest and services destination.'],
      ['include', 'Include rooms', 'Click rooms to include them without accidentally turning another one off.'],
      ['exclude', 'Exclude rooms', 'Click rooms to keep them outside the hunt.']
    ], (mode) => applyPickedRoom('footprint-map-picker', mode, choose));
    const undo = button('Undo room selection', () => {
      const previous = state.footprintUndo.pop(); if (!previous) return;
      state.footprintRequest += 1; state.footprintBusy = false; state.footprint = null;
      state.footprintRooms = previous.rooms; state.footprintStart = previous.start; state.footprintRest = previous.rest; state.footprintBoundaries = previous.boundaries;
      state.mapMessage = 'Undid the last room edit. Recalculate before applying.'; render();
    });
    undo.disabled = !state.footprintUndo.length;
    details.append(el('p', {class: 'control-label'}, 'Left-click: room on/off. Right-click: room actions. Tools below act on the last clicked or focused room.'), tools, undo, mapLegend(),
      mapFeedback(state.mapMessage || `${state.footprintRooms.length} hunting rooms selected. Click a room to turn it on or off.`),
      el('p', {class: 'help'}, 'Start = gold S. Field rest = purple F. Town rest = blue T. Boundary = red. Rest spots can be outside the hunt; choosing one does not add it to hunting rooms. Recalculate after changing rooms, then Apply. Rest spots are your choices, not a safety guarantee.'),
      el('p', {class: 'help'}, 'The familiar classic maps show your room selection. Missing images or coordinates are reported without inventing a replacement map. The searchable room list remains available.'));
    details.append(restMapButton('field_rest_room_id', true), restMapButton('resting_room_id', true));
    const candidateIds = new Set([...state.footprintBase.room_ids, ...(state.footprintBase.context_rooms || []).map((room) => room.id)]);
    const shownIds = new Set(rooms.map((room) => room.id));
    const context = (state.footprintBase.boundary_rooms || []).filter((room) => !shownIds.has(room.id));
    const boundaryIds = new Set([...(state.footprint?.boundary_ids || []), ...state.footprintBoundaries]);
    const restId = (key) => own(state.footprintRest, key) ? Number(state.footprintRest[key]) : Number(state.profileMap?.markers?.[key] ?? state.draft.settings[key]);
    const describe = (room) => {
      const selected = state.footprintRooms.includes(room.id), editable = candidateIds.has(room.id), start = String(room.id) === state.footprintStart, boundary = boundaryIds.has(room.id);
      const town = room.id === restId('resting_room_id'), field = room.id === restId('field_rest_room_id');
      return {editable, css: `${selected ? 'selected-room' : 'excluded-room'}${boundary ? ' boundary-room' : ''}${start ? ' starting-room' : ''}${town ? ' town-rest-room' : ''}${field ? ' field-rest-room' : ''}`, boundary,
        roles: {toggle: selected, boundary, start, resting_room_id: town, field_rest_room_id: field},
        markers: [start && ['starting-room', 'S'], town && ['town-rest-room', 'T'], field && ['field-rest-room', 'F']].filter(Boolean),
        label: `Room ${room.id}: ${room.title}; ${selected ? 'included' : 'excluded'}${start ? '; starting room' : ''}${boundary ? '; boundary' : ''}${town ? '; town rest' : ''}${field ? '; field rest' : ''}${editable ? '' : '; outside selected map'}`};
    };
    const choose = (room, action = 'toggle') => {
      if (!candidateIds.has(room.id)) return status('Choose a room on this map.', true);
      if (state.footprintBusy) return status('Wait for the room calculation to finish, then click again.', true);
      if (action === 'start') {
        const removing = state.footprintStart === String(room.id);
        if (!state.footprintRooms.includes(room.id)) chooseFootprintRooms([...state.footprintRooms, room.id]); else rememberFootprint();
        state.footprintBoundaries = state.footprintBoundaries.filter((id) => id !== room.id);
        state.footprintStart = removing ? '' : String(room.id);
        state.mapMessage = removing ? `Starting room removed from #${room.id}. Choose a start before applying; hunting rooms unchanged.` : `Starting room: #${room.id} · ${room.title}. Replaces the previous start.`; render();
      } else if (['field_rest_room_id', 'resting_room_id'].includes(action)) {
        const removing = restId(action) === room.id;
        rememberFootprint(); state.footprintRest[action] = removing ? '' : String(room.id);
        state.mapMessage = `${action === 'field_rest_room_id' ? 'Field rest' : 'Town rest'} ${removing ? 'removed from' : 'set to'} #${room.id} · ${room.title}. Hunting rooms unchanged.`; render();
      } else if (action === 'boundary') {
        const removing = boundaryIds.has(room.id);
        // Calculated boundaries are the perimeter of selected rooms. Include the
        // room when removing its boundary so recalculation cannot silently restore it.
        chooseFootprintRooms(removing ? [...state.footprintRooms, room.id] : state.footprintRooms.filter((id) => id !== room.id));
        state.footprintBoundaries = removing ? state.footprintBoundaries.filter((id) => id !== room.id) : [...new Set([...state.footprintBoundaries, room.id])];
        state.mapMessage = `Boundary ${removing ? 'removed; hunting now includes' : 'set; hunting excludes'} #${room.id} · ${room.title}. Recalculate before applying.`; render();
      } else {
        const include = action === 'include' || (action === 'toggle' && !state.footprintRooms.includes(room.id));
        state.mapMessage = `${include ? 'Included' : 'Excluded'} #${room.id} · ${room.title}. Recalculate to update boundaries.`;
        chooseFootprintRooms(include ? [...state.footprintRooms, room.id] : state.footprintRooms.filter((id) => id !== room.id));
        if (include) { state.footprintBoundaries = state.footprintBoundaries.filter((id) => id !== room.id); render(); }
      }
      status(state.mapMessage);
    };
    details.append(roomMaps([...rooms, ...context], edges, describe, choose, 'footprint-map-picker', state.zoneId ? state.footprintBase.room_ids : []));
    return details;
  }
  let dismissRoomActions;
  function showRoomActions(anchor, room, choose, roles, point, allowedChoices) {
    dismissRoomActions?.();
    const menu = el('div', {class: 'room-actions-menu', role: 'menu', 'aria-label': `Actions for room ${room.id}`},
      el('div', {class: 'room-actions-title'}, `#${room.id} · ${room.title}`));
    const choices = allowedChoices || [['toggle', 'Hunting room'], ['boundary', 'Boundary room'], ['start', 'Starting room'],
      ['field_rest_room_id', 'Field rest'], ['resting_room_id', 'Town rest']];
    const events = new AbortController();
    const close = (restore = false) => {
      events.abort(); menu.remove(); dismissRoomActions = null;
      if (restore && anchor.isConnected) anchor.focus({preventScroll: true});
    };
    dismissRoomActions = close;
    for (const [action, label] of choices) {
      const pick = button(label, () => { close(); choose(room, action); });
      pick.setAttribute('role', 'menuitemcheckbox');
      pick.setAttribute('aria-checked', String(Boolean(roles[action])));
      pick.prepend(el('span', {class: 'room-role-check', 'aria-hidden': 'true'}, roles[action] ? '✓' : ''));
      menu.append(pick);
    }
    (anchor.closest('dialog') || document.body).append(menu);
    const box = anchor.getBoundingClientRect();
    menu.style.left = `${Math.max(8, Math.min(point?.x ?? box.left, innerWidth - menu.offsetWidth - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(point?.y ?? box.bottom, innerHeight - menu.offsetHeight - 8))}px`;
    const items = [...menu.querySelectorAll('[role="menuitemcheckbox"]')];
    items[0].focus({preventScroll: true});
    menu.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' || event.key === 'Tab') { close(event.key === 'Escape'); return; }
      if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const current = items.indexOf(document.activeElement);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (current + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      items[next].focus();
    });
    document.addEventListener('pointerdown', (event) => { if (!menu.contains(event.target)) close(); }, {signal: events.signal});
  }
  // Both the guided footprint and persistent profile view use this renderer.
  // Callers own selection semantics; this function never changes settings.
  const mapImageCache = new Map(), mapViews = new Map();
  async function classicMapImage(name) {
    if (mapImageCache.has(name)) return mapImageCache.get(name);
    const loading = (async () => {
      const result = await api('map_image', {name});
      if (!/^data:image\/(png|jpeg|gif|webp);base64,/.test(result.data_url || '')) throw new Error('The map response was not a supported image.');
      const picture = new Image();
      picture.src = result.data_url;
      await picture.decode();
      if (!picture.naturalWidth || !picture.naturalHeight || picture.naturalWidth * picture.naturalHeight > 64000000) throw new Error('The map image dimensions are invalid or too large.');
      return {url: result.data_url, width: picture.naturalWidth, height: picture.naturalHeight};
    })();
    mapImageCache.set(name, loading);
    if (mapImageCache.size > 8) mapImageCache.delete(mapImageCache.keys().next().value);
    try { return await loading; }
    catch (error) { if (mapImageCache.get(name) === loading) mapImageCache.delete(name); throw error; }
  }
  function roomMaps(rooms, edges, describe, choose, ownerId, focusRoomIds = [], allowedChoices) {
    const result = document.createDocumentFragment(), sheets = new Map();
    rooms.forEach((room) => { const key = room.image || 'Unpositioned rooms'; if (!sheets.has(key)) sheets.set(key, []); sheets.get(key).push(room); });
    function svgNode(tag, attrs = {}, text) {
      const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
      Object.entries(attrs).forEach(([name, value]) => node.setAttribute(name, value));
      if (text != null) node.textContent = text;
      return node;
    }
    for (const [sheet, items] of sheets) {
      if (!items[0].image) {
        result.append(note(`${items.length} rooms have no classic map sheet. Use the room list to edit them; no diagram has been substituted.`, 'warning'));
        continue;
      }
      const viewKey = `${state.documentId}:${ownerId}:${sheet}:${ownerId === 'footprint-map-picker' ? state.zoneId : ''}`;
      if (!mapViews.has(viewKey)) mapViews.set(viewKey, {zoom: '1', left: 0, top: 0, cropped: focusRoomIds.length > 0});
      const view = mapViews.get(viewKey);
      const viewport = el('div', {class: `map-viewport zoom-${view.zoom}`, tabindex: 0, 'aria-label': `Scrollable map: ${sheet}`}, note('Loading classic map…'));
      const zoom = el('select', {'aria-label': `Map zoom: ${sheet}`}, [['1', 'Fit to width'], ['2', '2×'], ['3', '3×'], ['4', '4×']].map(([value, label]) => el('option', {value}, label)));
      zoom.value = view.zoom;
      zoom.addEventListener('change', () => { view.zoom = zoom.value; viewport.className = `map-viewport zoom-${view.zoom}`; });
      viewport.addEventListener('scroll', () => { if (viewport.querySelector('svg')) { view.left = viewport.scrollLeft; view.top = viewport.scrollTop; } });
      const warnings = el('div');
      const load = async () => {
        try {
          const picture = await classicMapImage(sheet);
          if (!viewport.isConnected) return;
          const svg = svgNode('svg', {viewBox: `0 0 ${picture.width} ${picture.height}`, class: 'footprint-map classic-map', role: 'group', 'aria-label': `Classic map: ${sheet}`});
          svg.append(svgNode('image', {href: picture.url, x: 0, y: 0, width: picture.width, height: picture.height, 'aria-hidden': 'true', class: 'classic-map-art'}));
          const missing = [], hitRooms = [];
          for (const room of items) {
            const box = room.image_coords;
            if (!Array.isArray(box) || box.length !== 4 || !box.every(Number.isFinite) || box[0] < 0 || box[1] < 0 || box[2] <= box[0] || box[3] <= box[1] || box[2] > picture.width || box[3] > picture.height) { missing.push(room.id); continue; }
            const {editable, css, label, markers = []} = describe(room), [x, y, right, bottom] = box;
            const group = svgNode('g', {class: css, 'data-room-id': room.id, role: editable ? 'button' : 'img', tabindex: editable ? 0 : -1, 'aria-label': label});
            group.append(svgNode('title', {}, label), svgNode('rect', {x, y, width: right - x, height: bottom - y, class: 'room-overlay', 'vector-effect': 'non-scaling-stroke'}));
            markers.forEach(([mark, letter], index) => {
              const badge = svgNode('g', {class: `room-badge ${mark}`, 'aria-hidden': 'true'});
              const cx = right + 5 + index * 13, cy = y - 4;
              badge.append(svgNode('circle', {cx, cy, r: 6, 'vector-effect': 'non-scaling-stroke'}),
                svgNode('text', {x: cx, y: cy, 'text-anchor': 'middle', 'dominant-baseline': 'central'}, letter));
              group.append(badge);
            });
            const activate = () => {
              if (!editable) return;
              const scroll = $('content-pane').scrollTop;
              view.focus = room.id;
              mapPickedRooms.set(`${state.documentId}:${ownerId}`, room);
              choose(room, 'toggle');
              $('content-pane').scrollTop = scroll;
            };
            group.addEventListener('focus', () => { mapPickedRooms.set(`${state.documentId}:${ownerId}`, room); });
            group.addEventListener('click', activate);
            group.addEventListener('contextmenu', (event) => {
              if (!editable) return;
              event.preventDefault(); event.stopPropagation();
              mapPickedRooms.set(`${state.documentId}:${ownerId}`, room);
              showRoomActions(group, room, choose, describe(room).roles, {x: event.clientX, y: event.clientY}, allowedChoices);
            });
            group.addEventListener('keydown', (event) => {
              if ((event.shiftKey && event.key === 'F10') || event.key === 'ContextMenu') { event.preventDefault(); showRoomActions(group, room, choose, describe(room).roles, undefined, allowedChoices); }
              else if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); activate(); }
            });
            if (editable) hitRooms.push({overlay: group.querySelector('.room-overlay'), activate});
            svg.append(group);
          }
          // Tiny map boxes remain usable when fit to width. Only a bounded
          // near miss selects the closest editable room; blank map space never
          // guesses a distant room. Coordinates are CSS pixels, including zoom.
          svg.addEventListener('click', (event) => {
            if (event.target.closest('[data-room-id]')) return;
            let nearest, distance = 8;
            for (const hit of hitRooms) {
              const box = hit.overlay.getBoundingClientRect();
              const dx = Math.max(box.left - event.clientX, 0, event.clientX - box.right);
              const dy = Math.max(box.top - event.clientY, 0, event.clientY - box.bottom);
              const gap = Math.hypot(dx, dy);
              if (gap < distance) { nearest = hit; distance = gap; }
            }
            if (nearest) nearest.activate();
            else status('Click a mapped room box, or zoom in to choose it. Blank map space is not a room.');
          });
          warnings.replaceChildren();
          const focusBoxes = items.filter((room) => focusRoomIds.includes(room.id) && !missing.includes(room.id)).map((room) => room.image_coords);
          if (focusBoxes.length) {
            const left = Math.max(0, Math.min(...focusBoxes.map((box) => box[0])) - 45), top = Math.max(0, Math.min(...focusBoxes.map((box) => box[1])) - 45);
            const right = Math.min(picture.width, Math.max(...focusBoxes.map((box) => box[2])) + 45), bottom = Math.min(picture.height, Math.max(...focusBoxes.map((box) => box[3])) + 45);
            const focus = button('', () => { view.cropped = !view.cropped; updateFocus(); });
            const updateFocus = () => {
              svg.setAttribute('viewBox', view.cropped ? `${left} ${top} ${right - left} ${bottom - top}` : `0 0 ${picture.width} ${picture.height}`);
              svg.classList.toggle('focused-area', view.cropped);
              svg.style.setProperty('--focus-width', `${580 * (right - left) / (bottom - top)}px`);
              zoom.options[0].textContent = view.cropped ? 'Fit selected area' : 'Fit to width';
              focus.textContent = view.cropped ? 'Show full classic map' : 'Focus selected hunting area';
            };
            updateFocus(); warnings.append(focus);
          }
          if (missing.length) warnings.append(note(`${missing.length} rooms lack valid positions on this image (${missing.slice(0, 12).join(', ')}${missing.length > 12 ? ', …' : ''}). They remain in the room list; their positions were not guessed.`, 'warning'));
          viewport.replaceChildren(svg);
          viewport.scrollLeft = view.left; viewport.scrollTop = view.top;
          if (view.focus) { viewport.querySelector(`[data-room-id="${view.focus}"]`)?.focus({preventScroll: true}); delete view.focus; }
        } catch (error) {
          if (!viewport.isConnected) return;
          viewport.replaceChildren(note(`Classic map unavailable: ${error.message} Use the room list for now.`, 'warning'), button('Retry classic map', load));
        }
      };
      result.append(el('h3', {}, sheet), zoom, viewport, warnings);
      queueMicrotask(load);
    }
    return result;
  }
  function targetSummary() {
    const names = targetEntries();
    return names?.length ? `Hunt only: ${names.map((entry) => entry.name).join(', ')}. Other creatures are not deliberately targeted.` : state.anyTargets ? 'You chose any eligible creature. Known creature rows below still allow exclusions and flee rules.' : 'No explicit hunt list. Hunter would target any eligible creature; choose creatures below or confirm that this is intended.';
  }
  function search() {
    const query = $('search').value.trim().toLowerCase(), results = $('search-results'); results.replaceChildren();
    if (!query || !state.boot) return;
    const matches = state.boot.fields.filter((field) => [field.key, field.label, field.help, ...(field.aliases || [])].join(' ').toLowerCase().includes(query));
    results.append(el('p', {class: 'small muted'}, `${matches.length} matching settings`));
    for (const field of matches.slice(0, 30)) {
      const page = normalizedPage(field.page);
      results.append(button('', () => navigate(page, field.key), 'search-result'));
      results.lastChild.append(el('strong', {}, field.label || field.key), el('span', {}, `${pages.find((p) => p[1] === page)[2]} · ${field.scope || 'current configuration'}`), el('span', {}, field.help || field.key));
    }
    if (matches.length > 30) results.append(el('p', {class: 'small muted'}, 'Refine the search to see the remaining matches.'));
  }
  $('search').addEventListener('input', search);
  $('nav-toggle').addEventListener('click', () => { const expanded = $('sidebar').classList.toggle('open'); $('nav-toggle').setAttribute('aria-expanded', String(expanded)); });
  $('guided-toggle').addEventListener('click', () => {
    state.guided = !state.guided;
    navigate(state.guided && !steps().includes(state.page) ? 'character' : !state.guided && state.page === 'character' ? 'equipment' : state.page);
  });
  $('review-button').addEventListener('click', () => navigate('review'));
  window.addEventListener('beforeunload', (event) => { if (dirty()) { event.preventDefault(); event.returnValue = ''; } });
  (async () => {
    try {
      if (!token) throw new Error('The setup session token is missing. Open the complete setup URL printed by ;eohunter-setup.');
      state.boot = await api('bootstrap');
      globalThis.HunterRoutineEditor.registerBuffConditions(state.boot.routine_buff_conditions);
      for (const key of ['fields', 'profiles', 'legacy_profiles', 'defaults', 'plans']) state.boot[key] ||= [];
      $('context').textContent = `${state.boot.context?.character || 'Character'} / ${state.boot.context?.game || 'Game'}`;
      render(); status('Connected. Changes stay in this draft until you save.');
    } catch (error) { fail(error); $('main').replaceChildren(el('h1', {}, 'Setup could not connect'), note(error.message, 'error')); }
  })();
})();
