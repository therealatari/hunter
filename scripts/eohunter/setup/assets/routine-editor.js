/* Configuration codec only. The native Profile/Engage parser owns execution.
 * No eval, game commands, or alternate combat interpreter. */
'use strict';
(() => {
  const amounts = [
    ['m', 'Mana (points)', 'at least', 'below'], ['s', 'Stamina (points)', 'at least', 'below'],
    ['v', 'Spirit (points)', 'at least', 'below'], ['h', 'My health (%)', 'at least', 'below'],
    ['e', 'Encumbrance (%)', 'at least', 'below'], ['essence', 'Shadow essence', 'at least', 'below'],
    ['mob', 'Fightable creatures in room', 'at least', 'at most'], ['valid', 'Valid targets in room', 'at least', 'at most'],
    ['thp', 'Target health (%)', 'at most', 'above'], ['empowered', 'Empowered bonus', 'below', 'at least']
  ];
  // These labels describe the live predicates, not the sometimes inverted
  // names inherited from Bigshot. Special cases stay explicit.
  const flags = [
    ['!prone', 'Target is down'], ['!frozen', 'Target is immobilized'], ['!rooted', 'Target is rooted'],
    ...['calm', 'disoriented', 'hovering', 'immobilized', 'kneeling', 'sitting', 'sleeping', 'stunned', 'webbed', 'flying',
      'undead', 'noncorporeal', 'ascended', 'ascension_boss', 'challenging', 'disengaged', 'inferior', 'mini_boss', 'mount', 'rider', 'sympathetic']
      .map((word) => [word, `Target is ${word.replaceAll('_', ' ')}`]),
    ['ancient', 'Target is grizzled or ancient (not ancient ghoul master)'], ['wounded', 'Target health is at most 25%'],
    ['fatalcrit', 'Target has taken a fatal critical'], ['smote', 'Target has been smitten'],
    ['ucsdecent', 'Unarmed position is decent'], ['ucsgood', 'Unarmed position is good'], ['ucsexcellent', 'Unarmed position is excellent'],
    ['ucstierup', 'Unarmed tier-up follow-up is available'], ['k1', 'I am kneeling'],
    ['tier1', 'My unarmed tier is 1'], ['tier2', 'My unarmed tier is 2'], ['tier3', 'My unarmed tier is 3'],
    ['hidden', 'I am hidden'], ['disease', 'I am diseased'], ['poison', 'I am poisoned'],
    ['outside', 'Room is outdoors'], ['!splashy', 'Room is tagged splashy'], ['pcs', 'Players outside my group are here'],
    ['justice', 'Swift Justice is ready'], ['reflex', 'Arcane Reflex is ready']
  ];
  const effects = [['EB', 'Buff'], ['ES', 'Spell effect'], ['EC', 'Cooldown'], ['ED', 'Debuff']];
  function registerBuffConditions(words) {
    for (const word of words || []) if (/^[a-z0-9]+$/.test(word) && !flags.some(([key]) => key === word)) flags.push([word, `My ${word} buff is active`]);
  }
  const invert = (token) => token.startsWith('!') ? token.slice(1) : `!${token}`;

  function parse(raw) {
    if (raw == null || (Array.isArray(raw) && !raw.length)) return [];
    if (typeof raw !== 'string') return null;
    // Native split_xx also splits every comma, even inside quotes. Don't
    // imply that quoting protects a comma or silently repair imported text.
    return raw.split(/,\s*/).filter((part) => part.trim()).map(parseLine);
  }
  function parseLine(raw) {
    let body = raw.trim(), repeat = '1';
    const repetitions = body.match(/\(x(\d+|x)\)$/i);
    if (repetitions) { repeat = repetitions[1].toLowerCase(); body = body.slice(0, repetitions.index).trim(); }
    const match = body.match(/^([^()]+?)(?:\s*\(([^()]*)\))?$/);
    // Compound commands, regex parentheses, embedded (xx), unmatched quotes
    // and unfamiliar forms remain an opaque row, never destructively parsed.
    if (!match || /\sand\s/.test(body) || /[\r\n]/.test(body)) return {raw, editable: false};
    const mods = match[2] || '';
    if ((mods.match(/"/g) || []).length % 2) return {raw, editable: false};
    return {raw, editable: true, command: match[1].trim(), repeat, modifiers: mods.match(/(?:[^\s"]|"[^"]*")+/g) || []};
  }
  function serialize(line) {
    if (!line.editable) return line.raw;
    if (!line.command.trim() || /[,()\r\n]/.test(line.command) || /\sand\s/.test(line.command)) throw new Error('Use original routine text for compound commands or parentheses.');
    if (line.repeat !== 'x' && (!/^\d+$/.test(line.repeat) || +line.repeat < 1 || +line.repeat > 100)) throw new Error('Choose 1 to 100 repeats per pass.');
    if (line.modifiers.some((token) => /[,()\r\n]/.test(token))) throw new Error('Use original routine text for complex modifiers.');
    if ((line.modifiers.includes('once') || line.modifiers.includes('room')) && line.repeat !== '1') throw new Error('Once-per-target/room cannot be combined with multiple repeats: identical repeated lines share the native once flag.');
    if (line.modifiers.includes('untildead') && (line.repeat !== '1' || line.modifiers.some((m) => ['once', 'room'].includes(m)))) throw new Error('Repeat-on-target cannot be combined with once-per-target/room or a per-pass repeat count.');
    return line.command.trim() + (line.modifiers.length ? ` (${line.modifiers.join(' ')})` : '') + (line.repeat !== '1' ? `(x${line.repeat})` : '');
  }
  function describe(token) {
    for (const [key, label, positive, negative] of amounts) {
      const match = token.match(new RegExp(`^(!?)${key}(\\d+)$`, 'i'));
      if (match) return `${label}: ${match[1] ? negative : positive} ${match[2]}`;
    }
    if (/^repeatdelay\d+$/i.test(token)) return `Wait at least ${token.match(/\d+/)[0]} seconds between uses of this exact line in the room`;
    if (token === 'once') return 'Once per target (resets on room change)';
    if (token === 'room') return 'Once per room';
    if (token === 'untildead') return 'Repeat successful actions on this target; skips/failures advance, target change resets the sequence';
    for (const [key, label] of flags) {
      if (key.toLowerCase() === token.toLowerCase()) return label;
      // Exact-tier negation is not a clean boolean inverse in native code.
      if (!key.startsWith('tier') && invert(key).toLowerCase() === token.toLowerCase()) return `Not: ${label.toLowerCase()}`;
    }
    const effect = token.match(/^(!?)(E[BSCD])"(.+)"$/i);
    if (effect) return `${effects.find(([key]) => key === effect[2].toUpperCase())[1]} ${effect[1] ? 'absent' : 'present'} (name pattern): ${effect[3]}`;
    return `Advanced native modifier: ${token} — retained; check the routines guide`;
  }
  const stances = ['offensive', 'advance', 'forward', 'neutral', 'guarded', 'defensive'];
  const elements = ['', 'acid', 'air', 'cold', 'earth', 'fire', 'lightning', 'steam', 'water'];
  const actionTypes = [
    ['attack', 'Melee attack'], ['incant', 'Spell'], ['fire', 'Ranged fire'], ['hide', 'Hide'], ['ambush', 'Aimed attack / ambush'],
    ['jab', 'Jab'], ['punch', 'Punch'], ['kick', 'Kick'], ['grapple', 'Grapple'], ['unarmed', 'Automatic unarmed combat'],
    ['hurl', 'Hurl weapon'], ['dhurl', 'Aimed hurl'], ['maneuver', 'Maneuver / technique'],
    ['stance', 'Change stance'], ['wait', 'Wait for target swing'], ['sleep', 'Pause'],
    ['mstrike', 'MSTRIKE'], ['wand', 'Wave a wand'], ['wandolier', 'Use a wandolier'], ['jewel', 'Activate a gemstone ability'],
    ['curse', 'Curse (715)'], ['efury', 'Earthen Fury (917)'], ['tether', 'Tether (706)'], ['phase', 'Phase target (704)'],
    ['caststop', 'Cast then stop a spell'], ['unravel', 'Song of Unravelling (1013)'], ['depress', 'Song of Depression (1015)'],
    ['resonance', 'Resonance bolt rotation'], ['sacrifice', 'Sacrifice'], ['smite', 'Voln SMITE'], ['leech', 'Mana Leech'],
    ['berserk', 'Berserk'], ['store', 'Stow held equipment'], ['wield', 'Wield equipment'], ['script', 'Run a combat script'],
    ['force', 'Repeat until an endroll is reached'], ['eachtarget', 'Apply to each valid target'], ['prefix', 'Buff before an action'],
    ['custom', 'Other native command']
  ];
  const actionHelp = {
    attack: 'Hunter selects the creature and sets the configured hunting stance before attacking.',
    incant: 'Choose the native spell delivery. Incant uses the game target; other methods use Hunter’s selected target through Lich. Not every spell supports every method, element or open/closed variant. Lich’s spell handling may also change stance.',
    fire: 'Uses Hunter’s ranged action and the profile’s ranged aiming order. Configure your weapon/hand intent and ammunition container below; this does not invent a reload or ammo-generation sequence.',
    hide: 'Tries to hide up to this many times. A failure does not guarantee the next action is stopped: require “I am hidden” on an ambush if open attacks are unwanted.',
    ambush: 'Uses AMBUSH while hidden, otherwise ATTACK. A blank aim uses the profile’s ambush order (or native defaults). Require hiding with the “I am hidden” condition to skip open attacks.',
    unarmed: 'Uses Hunter’s existing unarmed tier logic; the requested move can change as the tier changes.',
    hurl: 'Uses the native throw/recovery path. Equipment recovery depends on the configured hunting loadout; special returning weapons still need verification.',
    dhurl: 'Aimed hurl uses the selected body part, or the profile ambush order when blank. Managed loadouts retain native throw/recovery ownership.',
    maneuver: 'Choices come from the installed Hunter maneuver table, not a new copy of Lich’s skill data. A listed technique is not proof this character has learned it. Native availability, cost and cooldown gates still apply.',
    stance: 'Changes stance at this step. Hunter may set hunting stance again before the next attack; Lich’s spell logic may also change it. This is not a permanent override of automatic stance policy.',
    wait: 'Uses wander stance while waiting for the selected target to swing, up to the time limit. This is the native wait action, not an unconditional delay.',
    sleep: 'Pauses for the time shown. Normally switches to wander stance; keep-current-stance uses the native nostance option. Stops early for native interruption/target-loss conditions.',
    mstrike: 'Uses the native MSTRIKE policy below. An optional unarmed move selects its UAC variant.',
    wand: 'Uses the configured fresh/depleted containers and wand types. Set these in Wands and spell fallback.',
    wandolier: 'Uses native wandolier handling and the fresh wand container. Reservation and stance options apply to this action only.',
    jewel: 'Enter the GEMSTONE ACTIVATE mnemonic for your ability. Native cooldown and availability checks still apply.',
    curse: 'Select the native Curse variant, not a separate incant line.',
    tether: 'Uses native tether wait and optional transfer/recast handling.',
    force: 'Native force retries the inner action until the requested endroll or a native failure/timeout. This is not an unlimited loop.',
    eachtarget: 'Runs the inner action against each currently valid target through Hunter’s existing routine handler.',
    prefix: 'The native prefix checks the selected buff before running the inner action.',
    script: 'Run a combat script by name. This is configuration only; setup does not execute it.',
    store: 'Uses the native stow action. Managed hunting loadouts may restore their configured equipment afterward.',
    wield: 'Uses the native noun-based wield action. Managed loadout rules still own the desired hunting equipment.',
    custom: 'Preserves a native routine command. Use original routine text for compound commands. This editor cannot guarantee the command exists or succeeds.'
  };
  function actionDefaults(kind) {
    return {kind, spell: '', delivery: 'incant', scope: '', element: '', attempts: '3', part: '', move: kind === 'mstrike' ? '' : 'punch',
      stance: 'defensive', seconds: '3', nostance: false, technique: '', all: false, command: '',
      variant: 'clumsy', hand: 'right', noun: '', mnemonic: '', spells: '', noreserve: false, recast: false,
      inner: 'attack', endroll: '101', prefix: 'haste', script: ''};
  }
  function encodeAction(value, maneuvers = []) {
    const integer = (text, label, limit) => {
      if (!/^[1-9]\d*$/.test(String(text)) || +text > limit) throw new Error(`${label} must be a whole number from 1 to ${limit}.`);
      return String(text);
    };
    const part = () => {
      if (!/^[a-z ]*$/i.test(value.part || '') || /\sand\s/i.test(value.part || '')) throw new Error('Enter one body part, without commas or routine syntax.');
      return value.part?.trim() ? ` ${value.part.trim()}` : '';
    };
    if (['attack', 'jab', 'punch', 'kick', 'grapple', 'hurl', 'fire', 'wand', 'phase', 'depress', 'sacrifice', 'smite', 'leech', 'berserk'].includes(value.kind)) return value.kind;
    const inner = () => {
      if (!value.inner?.trim() || /[,()\r\n]/.test(value.inner) || /\sand\s/.test(value.inner)) throw new Error('Choose one inner action; conditions belong on the outer step.');
      return value.inner.trim();
    };
    switch (value.kind) {
      case 'mstrike':
        if (!['', 'jab', 'punch', 'grapple', 'kick'].includes(value.move)) throw new Error('Choose a supported MSTRIKE variant.');
        return `mstrike${value.move ? ` ${value.move}` : ''}`;
      case 'wandolier':
        if (!stances.includes(value.stance)) throw new Error('Choose a wandolier stance.');
        return `wandolier ${value.stance}${value.noreserve ? ' noreserve' : ''}`;
      case 'jewel':
        if (!/^\w+$/.test(value.mnemonic)) throw new Error('Enter one gemstone mnemonic.');
        return `jewel ${value.mnemonic}`;
      case 'curse':
        if (!['clumsy', 'weakness', 'darkness', 'itch', 'hex', 'pox', 'nightmare', 'star'].includes(value.variant)) throw new Error('Choose a curse type.');
        return `curse ${value.variant}`;
      case 'efury':
        if (!['', 'fire', 'cold'].includes(value.element)) throw new Error('Choose fire, cold or default.');
        return `efury${value.element ? ` ${value.element}` : ''}`;
      case 'tether': return `tether${value.recast ? ' recast' : ''}`;
      case 'caststop': return `caststop ${integer(value.spell, 'Spell number', 99999)}`;
      case 'unravel': return `unravel${value.spell ? ` ${integer(value.spell, 'Spell number', 99999)}` : ''}`;
      case 'resonance':
        if (!/^[1-9]\d*(?: +[1-9]\d*)+$/.test(value.spells)) throw new Error('Enter at least two spell numbers separated by spaces.');
        return `resonance ${value.spells}`;
      case 'store':
        if (!['left', 'right', 'both'].includes(value.hand)) throw new Error('Choose which hands to stow.');
        return `store ${value.hand}`;
      case 'wield':
        if (!/^\w+$/.test(value.noun) || !['left', 'right'].includes(value.hand)) throw new Error('Native wield needs a single noun and a hand.');
        return `wield ${value.noun} ${value.hand}`;
      case 'script':
        if (!value.script?.trim() || /[,();\r\n]/.test(value.script) || /\sand\s/.test(value.script)) throw new Error('Enter a script name and arguments without a semicolon or routine separators.');
        return `script ${value.script.trim()}`;
      case 'force': return `force ${inner()} until ${integer(value.endroll, 'Endroll', 9999)}`;
      case 'eachtarget': return `eachtarget ${inner()}`;
      case 'prefix':
        if (!['haste', 'slayer', 'tonis'].includes(value.prefix)) throw new Error('Choose a native buff prefix.');
        return `${value.prefix} ${inner()}`;
      case 'incant': {
        const n = integer(value.spell, 'Spell number', 99999);
        if (!['incant', 'default', 'cast', 'channel', 'evoke'].includes(value.delivery) || !['', 'open', 'closed'].includes(value.scope) || !elements.includes(value.element)) throw new Error('Choose supported spell options.');
        if (['506', '240', '1035'].includes(n) && value.delivery === 'default' && !value.scope && value.element) throw new Error('Choose an explicit delivery method: this spell number is also a native action prefix.');
        return [value.delivery === 'incant' ? 'incant' : '', n, value.scope,
          ['default', 'incant'].includes(value.delivery) ? '' : value.delivery, value.element].filter(Boolean).join(' ');
      }
      case 'hide': return `hide ${integer(value.attempts, 'Hide attempts', 100)}`;
      case 'ambush': case 'dhurl': return value.kind + part();
      case 'unarmed':
        if (!['jab', 'punch', 'kick', 'grapple'].includes(value.move)) throw new Error('Choose an unarmed move.');
        // Native unarmed accepts a single-word aim, unlike ambush.
        if (value.part && !/^[a-z]+$/i.test(value.part)) throw new Error('Native unarmed aim takes one word; use a supported single-word body part.');
        return `unarmed ${value.move}${part()}`;
      case 'stance':
        if (!stances.includes(value.stance) && !/^(?:[0-9]0|100)$/.test(value.stance)) throw new Error('Choose a stance name or a native multiple of ten.');
        return `stance ${value.stance}`;
      case 'wait': case 'sleep': return `${value.kind} ${integer(value.seconds, 'Seconds', value.kind === 'sleep' ? 60 : 300)}${value.kind === 'sleep' && value.nostance ? ' nostance' : ''}`;
      case 'maneuver':
        if (!maneuvers.some((m) => m.word === value.technique)) throw new Error('Choose a technique from the installed Hunter table.');
        return value.technique + (value.all ? ' all' : '');
      case 'custom':
        if (!value.command.trim() || /[,()\r\n]/.test(value.command) || /\sand\s/.test(value.command)) throw new Error('Use original routine text for compound commands or parentheses.');
        return value.command.trim();
      default: throw new Error('Choose an action type.');
    }
  }
  function decodeAction(command, maneuvers = []) {
    const raw = command.trim(), text = raw.toLowerCase();
    const model = (kind, fields = {}) => ({...actionDefaults(kind), ...fields});
    if (['attack', 'jab', 'punch', 'kick', 'grapple', 'hurl', 'fire', 'wand', 'phase', 'depress', 'sacrifice', 'smite', 'leech', 'berserk'].includes(text)) return model(text);
    let special;
    if ((special = text.match(/^mstrike(?: (jab|punch|grapple|kick))?$/))) return model('mstrike', {move: special[1] || ''});
    if ((special = text.match(/^wandolier (offensive|advance|forward|neutral|guarded|defensive)( noreserve)?$/))) return model('wandolier', {stance: special[1], noreserve: Boolean(special[2])});
    if ((special = text.match(/^jewel (\w+)$/))) return model('jewel', {mnemonic: special[1]});
    if ((special = text.match(/^curse (clumsy|weakness|darkness|itch|hex|pox|nightmare|star)$/))) return model('curse', {variant: special[1]});
    if ((special = text.match(/^efury(?: (fire|cold))?$/))) return model('efury', {element: special[1] || ''});
    if ((special = text.match(/^tether( recast)?$/))) return model('tether', {recast: Boolean(special[1])});
    if ((special = text.match(/^(caststop|unravel)(?: ([1-9]\d*))?$/)) && (special[2] || special[1] === 'unravel')) return model(special[1], {spell: special[2] || ''});
    if ((special = text.match(/^resonance ([1-9]\d*(?: +[1-9]\d*)+)$/))) return model('resonance', {spells: special[1]});
    if ((special = text.match(/^store (left|right|both)$/))) return model('store', {hand: special[1]});
    if ((special = text.match(/^wield (\w+) (left|right)$/))) return model('wield', {noun: special[1], hand: special[2]});
    if ((special = raw.match(/^script (.+)$/))) return model('script', {script: special[1]});
    if ((special = raw.match(/^force (.+) until ([1-9]\d*)$/))) return model('force', {inner: special[1], endroll: special[2]});
    if ((special = raw.match(/^eachtarget (.+)$/))) return model('eachtarget', {inner: special[1]});
    if ((special = raw.match(/^(haste|slayer|tonis) (.+)$/))) return model('prefix', {prefix: special[1], inner: special[2]});
    let m = text.match(/^(incant )?(\d+)(?: (open|closed))?(?: (cast|channel|evoke))?(?: (acid|air|cold|earth|fire|lightning|steam|water))?$/);
    if (m && !(m[1] && m[4]) && !( !m[1] && ['506', '240', '1035'].includes(m[2]) && !m[3] && !m[4] && m[5])) return model('incant', {spell: m[2], delivery: m[1] ? 'incant' : m[4] || 'default', scope: m[3] || '', element: m[5] || ''});
    if ((m = text.match(/^hide(?: (\d+))?$/))) return model('hide', {attempts: m[1] || '3'});
    if ((m = text.match(/^(ambush|dhurl)(?: ([a-z ]+))?$/))) return model(m[1], {part: m[2] || ''});
    if ((m = text.match(/^unarmed (jab|punch|kick|grapple)(?: ([a-z]+))?$/))) return model('unarmed', {move: m[1], part: m[2] || ''});
    if ((m = text.match(/^stance (offensive|advance|forward|neutral|guarded|defensive|[0-9]0|100)$/))) return model('stance', {stance: m[1]});
    if ((m = text.match(/^(wait|sleep) (\d+)( nostance)?$/)) && !(m[1] === 'wait' && m[3])) return model(m[1], {seconds: m[2], nostance: Boolean(m[3])});
    const technique = maneuvers.find((item) => text === item.word || text === `${item.word} all`);
    if (technique) return model('maneuver', {technique: technique.word, all: text.endsWith(' all')});
    return model('custom', {command: raw});
  }
  const api = {parse, parseLine, serialize, describe, amounts, flags, effects, invert,
    actionTypes, actionHelp, actionDefaults, encodeAction, decodeAction, stances, elements, registerBuffConditions};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else globalThis.HunterRoutineEditor = api;
})();
