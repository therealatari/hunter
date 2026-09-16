# frozen_string_literal: true

require 'tmpdir'
require_relative '../../../scripts/eohunter/setup/composition'

RSpec.describe EO::HunterSetup::Composition do
  around do |example|
    Dir.mktmpdir('hunter-composition') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:store) { EO::HunterSetup::Store.new(root: @directory) }
  let(:composition) { described_class.new(store: store) }

  it 'reads a character-scoped active native profile without fallback to a legacy namesake' do
    path = File.join(@directory, 'GSIV', 'Example', 'eohunter')
    active_store = EO::HunterSetup::Store.new(root: path)
    args = { data_dir: @directory, game: 'GSIV', character: 'Example' }
    expect(described_class.active_profile_name(**args)).to be_nil
    active_store.save(:profiles, 'active', {}, expected_revision: nil)
    active_store.set_active_profile('active', expected_revision: nil)
    expect(described_class.active_profile_name(**args)).to eq('active')
    expect(described_class.active_profile_name(**args.merge(character: 'Other'))).to be_nil
    FileUtils.mkdir_p(File.join(@directory, 'GSIV', 'Example', 'bigshot_profiles'))
    File.write(File.join(@directory, 'GSIV', 'Example', 'bigshot_profiles', 'active.yaml'), 'hunting_commands: attack')
    File.unlink(File.join(path, 'profiles', 'active.yaml'))
    expect { described_class.active_profile_name(**args) }.to raise_error(EO::HunterSetup::Store::NotFound)
  end

  def document(settings = {}, **links)
    { 'schema_version' => 1, 'settings' => settings }.merge(links.transform_keys(&:to_s))
  end

  def save(kind, name, data)
    store.save(kind, name, data, expected_revision: nil)
  end

  def plan(name, commands)
    save(:plans, name, { 'commands' => commands })
  end

  describe 'shared injury policies' do
    before do
      save(:injury_policies, 'Usual', document({ 'wounded_eval' => 'Char.percent_health <= 70' }))
      save(:injury_policies, 'Parasite', document({ 'wounded_eval' => 'Char.percent_health <= 50' }))
      store.set_character_injury_policy('Usual', expected_revision: nil)
    end

    it 'inherits across hunts, captures provenance, and permits an explicit area override' do
      inherited = composition.resolve(document({ 'targets' => 'rat' }))
      expect(inherited.raw['wounded_eval']).to eq('Char.percent_health <= 70')
      expect(inherited.provenance['wounded_eval']).to eq('character injury policy/Usual')
      expect(inherited.revisions.keys).to contain_exactly('character/injury_policy', 'injury_policies/Usual')
      expect(composition.resolve(document({}, injury_policy: 'Parasite')).raw['wounded_eval']).to eq('Char.percent_health <= 50')
      expect(composition.resolve(document({}, injury_policy: 'Parasite')).provenance['wounded_eval']).to eq('injury_policies/Parasite')
      expect(store.character_preferences[:injury_policy]).to eq('Usual')
    end

    it 'preserves old local and inherited custom rules, including explicit empty values' do
      ['custom_rule?', '', nil].each do |rule|
        expect(composition.resolve(document({ 'wounded_eval' => rule })).raw['wounded_eval']).to eq(rule)
        expect(composition.resolve({ 'wounded_eval' => rule }).raw['wounded_eval']).to eq(rule)
      end
      save(:defaults, 'old', document({ 'wounded_eval' => 'old_defaults_rule?' }))
      expect(composition.resolve(document({}, defaults: 'old')).raw['wounded_eval']).to eq('old_defaults_rule?')
      opted_in = composition.resolve(document({ 'wounded_eval' => 'custom_rule?' }, defaults: 'old', injury_policy: nil))
      expect(opted_in.raw['wounded_eval']).to eq('Char.percent_health <= 70')
      expect(opted_in.warnings.join).to include('replaces')
    end

    it 'never injects the active policy into a reusable defaults document' do
      expect(composition.resolve(document({}), character_policy: false).raw).to eq({})
    end

    it 'holds a captured policy unchanged until the next resolution' do
      previous = composition.resolve(document({}))
      saved = store.read(:injury_policies, 'Usual')
      store.save(:injury_policies, 'Usual', document({ 'wounded_eval' => 'new_rule?' }), expected_revision: saved[:revision])
      expect(previous.raw['wounded_eval']).to eq('Char.percent_health <= 70')
      expect(composition.resolve(document({})).raw['wounded_eval']).to eq('new_rule?')
      store.set_character_injury_policy('Parasite', expected_revision: store.character_preferences[:revision])
      expect(composition.resolve(document({})).raw['wounded_eval']).to eq('Char.percent_health <= 50')
      expect(composition.resolve(document({}, injury_policy: 'Usual')).raw['wounded_eval']).to eq('new_rule?')
    end

    it 'rejects missing, malformed and non-name references instead of weakening a selected policy' do
      ['missing', '../Usual', false, {}].each do |name|
        expect(composition.resolve(document({}, injury_policy: name))).not_to be_valid
      end
      File.write(File.join(@directory, 'injury_policies', 'Usual.yaml'), "schema_version: 1\nsettings: {}\n")
      expect(composition.resolve(document({}))).not_to be_valid
      File.unlink(File.join(@directory, 'injury_policies', 'Usual.yaml'))
      expect(composition.resolve(document({}))).not_to be_valid
      expect(composition.resolve(document({}, injury_policy: 'Parasite'))).to be_valid
    end

    it 'warns when explicit character inheritance has no selected policy' do
      store.set_character_injury_policy(nil, expected_revision: store.character_preferences[:revision])
      result = composition.resolve(document({ 'wounded_eval' => 'old_rule?' }, injury_policy: nil))
      expect(result.raw).not_to have_key('wounded_eval')
      expect(result.warnings.join).to include('No character injury policy')
    end
  end

  it 'resolves native and legacy file launches against the owning character only, without writing legacy files' do
    root = File.join(@directory, 'GSIV', 'Example')
    scoped = EO::HunterSetup::Store.new(root: File.join(root, 'eohunter'))
    scoped.save(:injury_policies, 'Usual', document({ 'wounded_eval' => 'health_rule?' }), expected_revision: nil)
    scoped.set_character_injury_policy('Usual', expected_revision: nil)
    scoped.save(:profiles, 'native', document({}), expected_revision: nil)
    native = File.join(root, 'eohunter', 'profiles', 'native.yaml')
    expect(described_class.read_profile(native)['wounded_eval']).to eq('health_rule?')
    legacy = File.join(root, 'bigshot_profiles', 'old.yaml')
    FileUtils.mkdir_p(File.dirname(legacy))
    bytes = YAML.dump({ hunting_commands: 'attack', extension: { 101 => 'test' } })
    File.write(legacy, bytes)
    expect(described_class.read_profile(legacy)).to include('hunting_commands' => 'attack', 'wounded_eval' => 'health_rule?', 'extension' => { 101 => 'test' })
    expect(File.binread(legacy)).to eq(bytes)
    other = File.join(@directory, 'GSIV', 'Other', 'bigshot_profiles', 'old.yaml')
    FileUtils.mkdir_p(File.dirname(other))
    File.write(other, bytes)
    expect(described_class.read_profile(other)).not_to have_key('wounded_eval')
  end

  it 'leaves a standalone legacy raw profile and all custom routine slots intact' do
    raw = { 'targets' => 'orc(c)', 'hunting_commands' => 'attack', 'hunting_commands_c' => 'incant 901', 'future_extension' => false }
    result = composition.resolve(raw)
    expect(result).to be_valid
    expect(result.raw).to eq(raw)
    expect(result.provenance.values.uniq).to eq(['profile'])
    expect(result.revisions).to eq({})
  end

  it 'inherits only the documented settings, retaining local area and target choices' do
    saved = save(:defaults, 'Calvix', document({ 'hunting_right_hand' => 'sword', 'hunting_room_id' => 99, 'targets' => 'wrong', 'resting_room_id' => 88, 'future_extension' => true }))
    result = composition.resolve(document({ 'hunting_room_id' => 10, 'targets' => 'kobold', 'custom_extension' => 42 }, defaults: 'Calvix'))
    expect(result).to be_valid
    expect(result.raw).to eq('hunting_right_hand' => 'sword', 'hunting_room_id' => 10, 'targets' => 'kobold', 'custom_extension' => 42)
    expect(result.provenance['hunting_right_hand']).to eq('defaults/Calvix')
    expect(result.revisions).to eq('defaults/Calvix' => saved[:revision])
  end

  it 'preserves false and empty overrides and replaces structured values whole' do
    save(:defaults, 'Calvix', document({ 'pull' => true, 'signs' => '101, 103', 'combat_buffs' => { 'enabled' => true, 'spells' => ['101'] }, 'recovery' => { 'use_hide' => true, 'safe_room' => 100 } }))
    result = composition.resolve(document({ 'pull' => false, 'signs' => [], 'combat_buffs' => {}, 'recovery' => { 'use_hide' => false } }, defaults: 'Calvix'))
    expect(result.raw).to include('pull' => false, 'signs' => [], 'combat_buffs' => {}, 'recovery' => { 'use_hide' => false })
    expect(result.provenance.values.uniq).to eq(['profile'])
    result = composition.resolve(document({}, defaults: 'Calvix'))
    expect(result.raw['pull']).to be(true)
  end

  it 'selects the area plan before the character plan and permits explicitly clearing that link' do
    plan('usual', 'attack')
    plan('Bowels', 'incant 901')
    save(:defaults, 'Calvix', document({ 'hunting_commands' => 'punch' }, combat_plan: 'usual'))
    expect(composition.resolve(document({}, defaults: 'Calvix')).raw['hunting_commands']).to eq('attack')
    result = composition.resolve(document({}, defaults: 'Calvix', combat_plan: 'Bowels'))
    expect(result.raw['hunting_commands']).to eq('incant 901')
    expect(result.provenance['hunting_commands']).to eq('plans/Bowels')
    expect(result.revisions.keys).to contain_exactly('defaults/Calvix', 'plans/Bowels')
    expect(composition.resolve(document({}, defaults: 'Calvix', combat_plan: nil)).raw['hunting_commands']).to eq('punch')
  end

  it 'lets a local routine override the inherited named plan, including an intentional empty routine' do
    plan('usual', 'attack')
    save(:defaults, 'Calvix', document({}, combat_plan: 'usual'))
    ['punch', ''].each do |commands|
      result = composition.resolve(document({ 'hunting_commands' => commands }, defaults: 'Calvix'))
      expect(result).to be_valid
      expect(result.raw['hunting_commands']).to eq(commands)
      expect(result.provenance['hunting_commands']).to eq('profile')
      expect(result.revisions.keys).to eq(['defaults/Calvix'])
      expect(result.warnings).to eq([])
    end
  end

  it 'explains when an explicitly selected plan replaces a conflicting local raw routine' do
    plan('usual', 'attack')
    result = composition.resolve(document({ 'hunting_commands' => 'punch' }, combat_plan: 'usual'))
    expect(result).to be_valid
    expect(result.raw['hunting_commands']).to eq('attack')
    expect(result.provenance['hunting_commands']).to eq('plans/usual')
    expect(result.warnings.join).to include('replaces', 'hunting_commands')
  end

  it 'allocates deduplicated creature exceptions while preserving exclusions and existing slots' do
    plan('usual', 'attack')
    plan('disable', 'incant 912, attack')
    settings = { 'targets' => 'orc, burly orc, troll(c)', 'invalid_targets' => 'rat', 'always_flee_from' => 'dragon', 'hunting_commands_c' => 'punch', 'hunting_commands_b' => 'kick' }
    result = composition.resolve(document(settings, combat_plan: 'usual', creature_plans: { 'orc' => 'disable', 'burly orc' => 'disable' }))
    expect(result).to be_valid
    expect(result.raw).to include('targets' => 'orc(d), burly orc(d), troll(c)', 'invalid_targets' => 'rat', 'always_flee_from' => 'dragon', 'hunting_commands_b' => 'kick', 'hunting_commands_c' => 'punch', 'hunting_commands_d' => 'incant 912, attack')
    expect(result.provenance['targets/burly orc']).to eq('creature_plans/disable')
  end

  it 'reuses a matching routine, including the main plan, without consuming another slot' do
    plan('same', 'attack')
    result = composition.resolve(document({ 'targets' => 'orc', 'hunting_commands' => 'attack' }, creature_plans: { 'orc' => 'same' }))
    expect(result).to be_valid
    expect(result.raw['targets']).to eq('orc(a)')
    expect(result.raw).not_to have_key('hunting_commands_b')
  end

  it 'fails when no a-j slot remains and never overwrites a saved legacy routine' do
    plan('new', 'new sequence')
    settings = { 'targets' => 'orc' }.merge(('a'..'j').to_h { |slot| [slot == 'a' ? 'hunting_commands' : "hunting_commands_#{slot}", "existing #{slot}"] })
    result = composition.resolve(document(settings, creature_plans: { 'orc' => 'new' }))
    expect(result).not_to be_valid
    expect(result.errors.join).to include('a-j')
    expect(result.raw).to eq(settings)
  end

  it 'does not convert an unrestricted target list into a restricted one to add an exception' do
    plan('new', 'attack')
    result = composition.resolve(document({ 'targets' => '' }, creature_plans: { 'orc' => 'new' }))
    expect(result).not_to be_valid
    expect(result.raw['targets']).to eq('')
    expect(result.errors.join).to include('explicit text target list')
  end

  it 'rejects ineligible, explicitly excluded and shadowed creature exceptions' do
    plan('new', 'attack')
    [{ 'targets' => 'troll' }, { 'targets' => 'orc', 'invalid_targets' => 'orc' }, { 'targets' => '.*, orc' }].each do |settings|
      result = composition.resolve(document(settings, creature_plans: { 'orc' => 'new' }))
      expect(result).not_to be_valid
      expect(result.raw['targets']).to eq(settings['targets'])
    end
  end

  it 'reports missing and malformed references without guessing a runnable configuration' do
    [document({}, defaults: 'missing'), document({}, combat_plan: 'missing'), document({}, defaults: false), document({}, creature_plans: [])].each do |profile|
      result = composition.resolve(profile)
      expect(result).not_to be_valid
      expect(result.errors).not_to be_empty
    end
    save(:plans, 'wrong', { 'commands' => ['attack'] })
    expect(composition.resolve(document({}, combat_plan: 'wrong')).errors.join).to include('commands must be text')
    expect(composition.resolve({ 'schema_version' => 2, 'settings' => {} })).not_to be_valid
    expect(composition.resolve({ 'schema_version' => 1, 'settings' => [] })).not_to be_valid
  end

  it 'captures immutable copied values and revisions while leaving the input mutable' do
    defaults = save(:defaults, 'Calvix', document({ 'signs' => ['101'] }))
    input = document({ 'custom' => { 'sequence' => ['first'] } }, defaults: 'Calvix')
    captured = composition.resolve(input)
    input['settings']['custom']['sequence'] << 'second'
    expect(captured.raw['custom']['sequence']).to eq(['first'])
    expect { captured.raw['custom']['sequence'] << 'third' }.to raise_error(FrozenError)
    store.save(:defaults, 'Calvix', document({ 'signs' => ['103'] }), expected_revision: defaults[:revision])
    expect(captured.raw['signs']).to eq(['101'])
    expect(composition.resolve(input).raw['signs']).to eq(['103'])
  end

  describe '#assign_creature_sequence' do
    it 'uses native slots and preserves unrelated settings and shared plans without saving' do
      plan('usual', 'attack')
      plan('control', 'incant 711')
      input = document({ 'targets' => 'orc, troll', 'hunting_commands_c' => 'keep this', 'custom_extension' => false },
                       combat_plan: 'usual', creature_plans: { 'orc' => 'usual', 'troll' => 'control' })
      before = Marshal.load(Marshal.dump(input))
      draft = composition.assign_creature_sequence(input, creature: 'orc', commands: 'incant 703, incant 711')
      expect(input).to eq(before)
      expect(draft['settings']).to include('hunting_commands_c' => 'keep this', 'custom_extension' => false)
      expect(draft['creature_plans']).to eq('troll' => 'control')
      result = composition.resolve(draft)
      expect(result).to be_valid
      expect(result.raw['targets']).to eq('orc(d), troll(b)')
      expect(result.raw['hunting_commands_d']).to eq('incant 703, incant 711')
      expect(store.read(:plans, 'usual')[:data]).to eq('commands' => 'attack')
      expect(store.list(:profiles)).to be_empty
    end

    it 'edits a dedicated local slot in place but forks a slot shared by two targets' do
      input = document({ 'targets' => 'orc(b), troll', 'hunting_commands_b' => 'attack' })
      edited = composition.assign_creature_sequence(input, creature: 'orc', commands: 'kick')
      expect(edited['settings']).to include('targets' => 'orc(b), troll(a)', 'hunting_commands_b' => 'kick')
      input['settings']['targets'] = 'orc(b), troll(b)'
      forked = composition.assign_creature_sequence(input, creature: 'orc', commands: 'kick')
      expect(forked['settings']).to include('targets' => 'orc(c), troll(b)', 'hunting_commands_b' => 'attack', 'hunting_commands_c' => 'kick')
    end

    it 'does not change an inherited routine or a slot reused by another named plan' do
      plan('attack', 'attack')
      save(:defaults, 'usual', document({ 'hunting_commands_b' => 'attack' }))
      inherited = document({ 'targets' => 'orc(b), troll' }, defaults: 'usual')
      expect(composition.assign_creature_sequence(inherited, creature: 'orc', commands: 'kick')['settings'])
        .to include('targets' => 'orc(c), troll(a)', 'hunting_commands_c' => 'kick')
      linked = document({ 'targets' => 'orc(b), troll', 'hunting_commands_b' => 'attack' }, creature_plans: { 'troll' => 'attack' })
      edited = composition.assign_creature_sequence(linked, creature: 'orc', commands: 'kick')
      expect(composition.resolve(edited).raw).to include('targets' => 'orc(c), troll(b)', 'hunting_commands_b' => 'attack')
    end

    it 'refuses full slots, unknown, excluded, duplicate, or shadowed targets without editing input' do
      full = document({ 'targets' => 'orc' }.merge(('b'..'j').to_h { |slot| ["hunting_commands_#{slot}", 'keep'] }))
      expect { composition.assign_creature_sequence(full, creature: 'orc', commands: 'kick') }.to raise_error(ArgumentError, /No free/)
      [document({ 'targets' => '' }), document({ 'targets' => 'troll' }), document({ 'targets' => 'orc, ORC' }),
       document({ 'targets' => '.*, orc' }), document({ 'targets' => 'orc', 'invalid_targets' => 'orc' })].each do |input|
        before = Marshal.load(Marshal.dump(input))
        expect { composition.assign_creature_sequence(input, creature: 'orc', commands: 'kick') }.to raise_error(ArgumentError)
        expect(input).to eq(before)
      end
      expect { composition.assign_creature_sequence(document({ 'targets' => 'orc' }), creature: 'orc', commands: []) }.to raise_error(ArgumentError, /action text/)
    end
  end
end
