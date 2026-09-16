/* Fixed configuration templates, never a Ruby evaluator. */
'use strict';
(() => {
  const predicates = {
    bleeding: 'bleeding?',
    casting: '!Lich::Gemstone::Injured.able_to_cast?',
    ranged: '!Lich::Gemstone::Injured.able_to_use_ranged?',
    hiding: '!Lich::Gemstone::Injured.able_to_sneak?',
    overexerted: 'Lich::Gemstone::Effects::Debuffs.active?("Overexerted")'
  };
  const defaults = () => ({health: '70', wound: '2', scar: '', bleeding: false, casting: false, ranged: false, hiding: false, overexerted: false});
  const presets = {
    general: {label: 'General hunting', help: 'Return at 70% health or a rank 2+ wound.', values: defaults()},
    cautious: {label: 'Cautious', help: 'Return at 85% health, any wound or bleeding.', values: {...defaults(), health: '85', wound: '1', bleeding: true}},
    caster: {label: 'Spellcaster', help: 'Return at 70% health, bleeding, or injuries that Lich says prevent casting.', values: {...defaults(), wound: '', bleeding: true, casting: true}},
    ranged: {label: 'Ranged hunter', help: 'Return at 70% health, bleeding, or injuries that prevent ranged attacks.', values: {...defaults(), wound: '', bleeding: true, ranged: true}}
  };
  function encode(model) {
    const parts = [];
    const number = (value, max, label) => {
      if (value === '' || value == null) return null;
      if (!/^\d+$/.test(String(value)) || Number(value) < 1 || Number(value) > max) throw new Error(`${label} must be from 1 to ${max}, or blank to disable.`);
      return Number(value);
    };
    const health = number(model.health, 100, 'Health percentage');
    if (health != null) parts.push(`Char.percent_health <= ${health}`);
    for (const kind of ['wound', 'scar']) {
      const rank = number(model[kind], 3, `${kind} rank`);
      if (rank != null) parts.push(kind === 'scar' ? `Lich::Gemstone::Injured.get_injury_data[1].values.any? { |rank| rank.to_i >= ${rank} }` : `XMLData.injuries.any? { |_part, injury| injury["wound"].to_i >= ${rank} }`);
    }
    for (const [key, expression] of Object.entries(predicates)) if (model[key] === true) parts.push(expression);
    if (!parts.length) throw new Error('Choose at least one injury return condition. Existing rules have not changed.');
    return parts.join(' || ');
  }
  // Recognize only our canonical grammar; imported Ruby is never guessed at.
  function decode(raw) {
    if (typeof raw !== 'string' || !raw.trim()) return null;
    const model = {...defaults(), health: '', wound: ''};
    for (const part of raw.split(' || ')) {
      let match;
      if ((match = part.match(/^Char\.percent_health <= (\d+)$/))) model.health = match[1];
      else if ((match = part.match(/^XMLData\.injuries\.any\? \{ \|_part, injury\| injury\["wound"\]\.to_i >= ([1-3]) \}$/))) model.wound = match[1];
      else if ((match = part.match(/^Lich::Gemstone::Injured\.get_injury_data\[1\]\.values\.any\? \{ \|rank\| rank\.to_i >= ([1-3]) \}$/))) model.scar = match[1];
      else {
        const key = Object.keys(predicates).find((key) => predicates[key] === part);
        if (!key) return null;
        model[key] = true;
      }
    }
    try { return encode(model) === raw ? model : null; } catch (_) { return null; }
  }
  const api = {presets, defaults, predicates, encode, decode};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof window !== 'undefined') window.HunterInjuryEditor = api;
})();
