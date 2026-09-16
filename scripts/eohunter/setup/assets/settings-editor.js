/* Lossless presentation helpers. No commands or policy execution. */
'use strict';
(() => {
  function lines(raw) {
    if (raw == null || raw === '') return [];
    if (Array.isArray(raw)) return raw.every((line) => typeof line === 'string') ? raw.slice() : null;
    return typeof raw === 'string' ? raw.split(/,\s*/).filter((line) => line.trim()) : null;
  }
  function replaceLines(original, values) {
    if (values.some((line) => !line.trim() || /[,\r\n]/.test(line))) throw new Error('Enter one non-empty entry per row, without commas or newlines.');
    return Array.isArray(original) ? values.slice() : values.join(', ');
  }
  function boonChoice(ignore, flee, key) {
    if (lines(flee)?.includes(key)) return 'flee';
    return lines(ignore)?.includes(key) ? 'ignore' : 'fight';
  }
  function setBoons(ignore, flee, keys, choice) {
    if (!['fight', 'ignore', 'flee'].includes(choice)) throw new Error('Choose Fight, Ignore or Flee.');
    const left = lines(ignore), right = lines(flee);
    if (!left || !right) throw new Error('Custom boon values need the raw editor; they have not been changed.');
    const selected = new Set(keys);
    return {
      boons_ignore: [...left.filter((key) => !selected.has(key)), ...(choice === 'ignore' ? keys : [])],
      boons_flee: [...right.filter((key) => !selected.has(key)), ...(choice === 'flee' ? keys : [])]
    };
  }
  const api = {lines, replaceLines, boonChoice, setBoons};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else globalThis.HunterSettingsEditor = api;
})();
