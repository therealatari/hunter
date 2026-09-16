# frozen_string_literal: true

require_relative '../engine_helper'
require_relative '../../../scripts/eohunter/setup/schema'

RSpec.describe EO::HunterSetup::Schema do
  subject(:schema) { described_class.new(profile_class: EO::Engine::Profile, cleanse_policy_class: EO::Engine::Cleanse::Policy) }
  let(:raw) { { 'hunting_room_id' => '42', 'resting_room_id' => '100', 'targets' => 'kobold', 'hunting_commands' => 'attack' } }

  it 'presents native boon and buff vocabularies rather than a second execution table' do
    expect(schema.boon_abilities.map { |entry| entry[:key] }).to match_array(EO::Engine::Targets::BOON_ADJECTIVES.keys)
    expect(schema.boon_abilities).to include(hash_including(key: 'dispelling', adjectives: %w[dazzling flashy]))
    expect(schema.routine_buff_conditions).to match_array(EO::Engine::Engage::Conditions::BUFF_WORDS.keys)
  end

  it 'names fog values in native order and does not mislabel inverted UAC or death flags' do
    fields = schema.fields.to_h { |field| [field['key'], field] }
    options = fields['fog_return']['options'].to_h { |option| [option['value'], option['label']] }
    expect(options).to include('4' => 'Sigil of Escape', '5' => 'Familiar Gate (930)', '6' => 'Custom return commands')
    expect(fields['uac_mstrike']['label']).to start_with('Disable')
    expect(fields['dead_man_switch']['help']).to include('not a low-health logout trigger')
    expect(fields['tier3']['options'].map { |option| option['value'] }).to eq(%w[jab punch grapple kick])
  end

  it 'reuses the installed maneuver words without asserting they are learned' do
    expect(schema.routine_maneuvers).to include(word: 'bullrush', category: 'cman', name: 'Bull Rush')
    expect(schema.routine_maneuvers.map { |entry| entry[:word] }).to match_array(EO::Engine::Actions::Maneuver::WORDS.keys)
    expect(schema.capabilities['repeat_until_target_gone']).to be(true)
    expect(schema.fields.find { |field| field['key'] == 'hunting_stance' }['options']).to include('offensive', 'defensive', '50')
  end

  it 'keeps everyday hunting choices normal and technical controls advanced independently of help copy' do
    fields = schema.fields.to_h { |field| [field['key'], field] }
    %w[loot_script priority delay_loot loot_stance final_loot flee_clouds flee_vines flee_webs flee_voids ignore_disks].each do |key|
      expect(fields.fetch(key)).to include('advanced' => false, 'editor' => 'guided')
    end
    %w[flee_message box_in_hand].each do |key|
      expect(fields.fetch(key)).to include('advanced' => true)
    end
    profile_class = Class.new(EO::Engine::Profile)
    profile_class.const_set(:RULES, EO::Engine::Profile::RULES.merge('future_setting' => [:bool, false]))
    extension = described_class.new(profile_class: profile_class).fields.find { |field| field['key'] == 'future_setting' }
    expect(extension).to include('advanced' => true, 'editor' => 'raw')
  end

  it 'rejects repeat-on-target when the loaded engine does not advertise it' do
    hide_const('EO::Engine::Engage::Routine::REPEAT_UNTIL_TARGET_GONE')
    expect(schema.capabilities['repeat_until_target_gone']).to be(false)
    checked = schema.validate(raw.merge('hunting_commands' => 'attack (untildead)'))
    expect(checked['valid']).to be(false)
    expect(checked['errors'].map { |issue| issue['message'] }.join).to include('does not support untildead')
  end

  it 'accounts for every installed profile field once with an explicit editing path' do
    fields = schema.fields
    expect(fields.map { |field| field['key'] }).to match_array((EO::Engine::Profile::RULES.keys + ['recovery']).uniq)
    expect(fields.map { |field| field['key'] }.uniq.size).to eq(fields.size)
    fields.each do |field|
      expect(field.values_at('label', 'help', 'page', 'type')).to all(be_a(String))
      expect(%w[guided raw]).to include(field['editor'])
      expect(field['aliases']).to include(field['key'])
    end
  end

  it 'uses one canonical recovery control even when the native rules declare it' do
    profile_class = Class.new(EO::Engine::Profile)
    profile_class.const_set(:RULES, EO::Engine::Profile::RULES.merge('recovery' => [:structured, {}]))
    extended = described_class.new(profile_class: profile_class, cleanse_policy_class: EO::Engine::Cleanse::Policy)
    recovery_fields = extended.fields.select { |field| field['key'] == 'recovery' }
    expect(recovery_fields.size).to eq(1)
    expect(recovery_fields.first).to include('page' => 'recovery', 'label' => 'Integrated recovery preferences')
  end

  it 'finds canonical controls through legacy and everyday terms' do
    expect(schema.search('fried').map { |field| field['key'] }).to include('fried', 'disable_commands')
    expect(schema.search('oom').map { |field| field['key'] }).to include('oom')
    expect(schema.search('tail').map { |field| field['key'] }).to include('group_fried_trigger')
    expect(schema.search('ecleanse').map { |field| field['key'] }).to include('recovery')
    expect(schema.search('spirit points').map { |field| field['key'] }).to include('rest_till_spirit')
  end

  it 'uses native defaults without sharing mutable defaults with callers' do
    schema.fields.find { |field| field['key'] == 'group_fried_trigger' }['default'] << 'someone'
    expect(EO::Engine::Profile::RULES['group_fried_trigger'].last).to eq(['any'])
    expect(schema.fields.find { |field| field['key'] == 'fried' }['default']).to eq(100)
  end

  it 'validates native policies with exact normalized legacy semantics' do
    raw.merge!('fried' => '101', 'rest_till_spirit' => '7', 'hunting_commands' => 'attack(x2), stance offensive and attack')
    result = schema.validate(raw)
    expect(result).to include('valid' => true, 'ready' => true, 'errors' => [], 'missing' => [])
    expect(result['normalized']).to include('fried' => 101, 'rest_till_spirit' => 7,
                                            'hunting_commands' => ['attack', 'attack', ['stance offensive', 'attack']])
  end

  it 'allows incomplete drafts while naming missing required geometry' do
    result = schema.validate({})
    expect(result).to include('valid' => true, 'ready' => false)
    expect(result['missing'].map { |issue| issue['key'] }).to contain_exactly('hunting_room_id', 'resting_room_id')
  end

  it 'does not silently lose unresolved boundary UIDs dropped by the native cleaner' do
    raw['hunting_boundaries'] = 'u900, 99'
    result = schema.validate(raw, uid_ids: ->(_uid) { [] })
    expect(result).to include('valid' => true, 'ready' => false)
    expect(result['missing']).to include(hash_including('key' => 'hunting_boundaries', 'message' => /u900/))
  end

  it 'resolves mapped UIDs through the supplied read-only map helper' do
    raw.merge!('hunting_room_id' => 'u42', 'hunting_boundaries' => 'u99')
    result = schema.validate(raw, uid_ids: ->(uid) { [uid + 1000] })
    expect(result['ready']).to be true
    expect(result['normalized']).to include('hunting_room_id' => 1042, 'hunting_boundaries' => [1099])
  end

  it 'rejects malformed native structured settings rather than normalizing them away' do
    result = schema.validate(raw.merge('hunting_loadout_sets' => []))
    expect(result['valid']).to be false
    expect(result['errors'].first['message']).to include('hunting_loadout_sets')
  end

  it 'forces native lazy target regex validation without selecting a game target' do
    result = schema.validate(raw.merge('targets' => '[broken'))
    expect(result['valid']).to be false
    expect(result['errors']).not_to be_empty
  end

  it 'reports native unsupported group combinations before launch' do
    result = schema.validate(raw.merge('field_rest_room_id' => '101'), mode: 'tail')
    expect(result['ready']).to be false
    expect(result['errors'].first['message']).to include('ordinary solo hunts only')
    expect(schema.capabilities['configurable_dispel_recovery']).to be false
  end

  it 'shows native fallback behavior without inventing a stricter validator' do
    result = schema.validate(raw.merge('hunting_stance' => 'invalid', 'flee_message' => '[broken'))
    expect(result['valid']).to be true
    expect(result['normalized']).to include('hunting_stance' => 'defensive', 'flee_message' => nil)
    expect(result['warnings'].map { |issue| issue['key'] }).to include('hunting_stance', 'flee_message')
  end

  it 'never evaluates embedded Ruby or executes arbitrary commands' do
    expression = "raise 'setup must never execute this'"
    raw.merge!('wounded_eval' => expression, 'town_rest_required_eval' => expression,
               'hunting_commands' => "script never_run, #{expression}", 'extension_value' => { 'nested' => ['preserve'] })
    before = Marshal.dump(raw)
    result = schema.validate(raw)
    expect(result['valid']).to be true
    expect(result['warnings'].map { |issue| issue['key'] }).to include('wounded_eval', 'town_rest_required_eval', 'extension_value')
    expect(Marshal.dump(raw)).to eq(before)
  end

  it 'constructs native recovery preferences while preserving explicit false' do
    raw['recovery'] = { 'cleanse_poison' => false }
    result = schema.validate(raw)
    expect(result['valid']).to be true
    expect(raw['recovery']['cleanse_poison']).to be false
  end

  it 'preserves unsupported recovery preferences and reports that they are ignored' do
    result = schema.validate(raw.merge('recovery' => { 'future_recovery' => true }))
    expect(result['valid']).to be true
    expect(result['warnings']).to include(hash_including('key' => 'recovery.future_recovery', 'kind' => 'not_checked'))
  end

  it 'rejects a nonmapping recovery override and nonmapping profiles' do
    expect(schema.validate(raw.merge('recovery' => nil))['errors']).to include(hash_including('key' => 'recovery'))
    expect(schema.validate([])['valid']).to be false
  end

  describe '#validate_defaults' do
    let(:defaults) do
      {
        'combat_buffs'     => { 'enabled' => true, 'spells' => { '101' => 'recast' } },
        'preparations'     => { 'bread' => { 'perform' => 'eat bread', 'result' => 'bread_eaten' } },
        'hunting_commands' => 'prepare bread, attack'
      }
    end

    it 'accepts structurally valid buffs and preparations without hunt-specific rooms' do
      before = Marshal.dump(defaults)
      result = schema.validate_defaults(defaults)
      expect(result).to include('valid' => true, 'ready' => false, 'errors' => [], 'missing' => [])
      expect(result['warnings']).to include(hash_including('kind' => 'context_required'))
      expect(result['normalized'].keys).to match_array(defaults.keys)
      expect(result['normalized']).not_to have_key('resting_room_id')
      expect(Marshal.dump(defaults)).to eq(before)
    end

    it 'does not return the temporary destination even for an explicitly blank field' do
      result = schema.validate_defaults(defaults.merge('resting_room_id' => ''))
      expect(result['valid']).to be true
      expect(result['normalized']).not_to have_key('resting_room_id')
    end

    it 'still rejects malformed buff and preparation structures using native validation' do
      expect(schema.validate_defaults(defaults.merge('combat_buffs' => []))['valid']).to be false
      expect(schema.validate_defaults(defaults.merge('preparations' => []))['valid']).to be false
      expect(schema.validate_defaults(defaults.merge('preparations' => { 'bread' => { 'perform' => 'eat bread' } }))['valid']).to be false
    end

    it 'does not relax the actual composed hunt requirements' do
      expect(schema.validate(defaults.merge('hunting_room_id' => '42'))['valid']).to be false
      expect(schema.validate(defaults.merge('hunting_room_id' => '42', 'resting_room_id' => '100'))).to include('valid' => true, 'ready' => true)
    end

    it 'never evaluates expressions while checking defaults' do
      result = schema.validate_defaults(defaults.merge('wounded_eval' => "raise 'must not execute'"))
      expect(result['valid']).to be true
      expect(result['warnings']).to include(hash_including('key' => 'wounded_eval', 'kind' => 'not_checked'))
    end
  end
end
