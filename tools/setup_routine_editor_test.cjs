// Pure codec checks; no browser, account, or game connection.
const assert = require('node:assert/strict');
const codec = require('../scripts/eohunter/setup/assets/routine-editor.js');
for (const text of ['incant 711 (m40 !stunned)(x2)', '719 (once)', 'attack (EB"Enh. Strength" repeatdelay30)', '705(xx)', 'cman bullrush (!prone)']) {
  const line = codec.parse(text)[0];
  assert.equal(line.editable, true, text);
  const again = codec.parse(codec.serialize(line))[0];
  assert.equal(again.command, line.command);
  assert.equal(again.repeat, line.repeat);
  assert.deepEqual(again.modifiers, line.modifiers);
}
for (const raw of ['stance offensive and attack', 'attack (ES"Foo (bar)")', 'attack (EB"unterminated)', 'attack(xx) trailing']) {
  const line = codec.parse(raw)[0];
  assert.equal(line.editable, false, raw);
  assert.equal(codec.serialize(line), raw);
}
assert.equal(codec.parse(['attack']), null);
assert.deepEqual(codec.parse([]), []);
assert.match(codec.describe('m40'), /points.*at least 40/);
assert.match(codec.describe('!mob3'), /at most 3/);
assert.match(codec.describe('thp50'), /at most 50/);
assert.equal(codec.describe('!prone'), 'Target is down');
assert.match(codec.describe('prone'), /Not: target is down/);
assert.match(codec.describe('mystery'), /Advanced native modifier/);
assert.equal(codec.parse('711(m40)(x2)')[0].repeat, '2');
assert.throws(() => codec.serialize({...codec.parse('711(once)')[0], repeat: '2'}), /share the native once flag/);
assert.throws(() => codec.serialize({...codec.parse('711')[0], repeat: '0'}), /1 to 100/);
assert.throws(() => codec.serialize({...codec.parse('711')[0], command: '711, quit'}), /original routine text/);
console.log('Routine editor codec checks passed.');

const maneuvers = [{word: 'bullrush', category: 'cman', name: 'Bull Rush'}, {word: 'shield bash', category: 'shield', name: 'Shield Bash'}];
for (const command of ['incant 711', '711', '711 channel', '903 open evoke fire', '903 closed cast cold',
  'fire', 'hide 5', 'ambush right eye', 'dhurl head', 'unarmed punch head', 'stance offensive', 'stance 50', 'wait 5',
  'sleep 3 nostance', 'bullrush', 'shield bash all']) {
  const model = codec.decodeAction(command, maneuvers);
  assert.notEqual(model.kind, 'custom', command);
  assert.equal(codec.encodeAction(model, maneuvers), command);
}
for (const command of ['fire head', 'incant 903 evoke fire', '903 unknownsuffix', 'stalk target', 'ambush left arm extra']) {
  const model = codec.decodeAction(command, maneuvers);
  assert.equal(codec.encodeAction(model, maneuvers), command, 'Imported text must not lose unrecognized arguments');
}
assert.throws(() => codec.encodeAction({...codec.actionDefaults('incant'), spell: '0'}), /Spell number/);
assert.throws(() => codec.encodeAction({...codec.actionDefaults('incant'), spell: '711', element: 'anything'}), /supported spell/);
assert.throws(() => codec.encodeAction({...codec.actionDefaults('hide'), attempts: '0'}), /Hide attempts/);
assert.throws(() => codec.encodeAction({...codec.actionDefaults('maneuver'), technique: 'invented'}, maneuvers), /installed Hunter table/);
assert.throws(() => codec.serialize({...codec.parse('attack (untildead)')[0], repeat: '2'}), /Repeat-on-target/);
assert.equal(codec.serialize(codec.parse('705 (untildead)')[0]), '705 (untildead)');
console.log('Action delivery and repetition codec checks passed.');
const injury = require('../scripts/eohunter/setup/assets/injury-editor.js');
for (const preset of Object.values(injury.presets)) assert.deepEqual(injury.decode(injury.encode(preset.values)), preset.values);
assert.equal(injury.decode('custom_wounded? || Char.percent_health <= 70'), null);
assert.throws(() => injury.encode({...injury.defaults(), health: '70; send_command'}), /Health percentage/);
assert.throws(() => injury.encode({...injury.defaults(), health: '101'}), /Health percentage/);
assert.throws(() => injury.encode({...injury.defaults(), health: '', wound: ''}), /at least one/);
assert.match(injury.encode({...injury.presets.caster.values, overexerted: true}), /!Lich::Gemstone::Injured.able_to_cast\?/);
assert.match(injury.encode({...injury.defaults(), scar: '2'}), /Injured.get_injury_data\[1\]/);
assert.deepEqual(injury.decode(injury.encode({...injury.defaults(), scar: '2'})), {...injury.defaults(), scar: '2'});
console.log('Injury preset codec checks passed.');
