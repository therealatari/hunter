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

  def document(settings = {}, **links)
    { 'schema_version' => 1, 'settings' => settings }.merge(links.transform_keys(&:to_s))
  end

  def save(kind, name, data)
    store.save(kind, name, data, expected_revision: nil)
  end

  def plan(name, commands)
    save(:plans, name, { 'commands' => commands })
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
