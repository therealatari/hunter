# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../eohunter/engine_helper'
require_relative '../../scripts/eohunter_group/runtime'

RSpec.describe 'MA startup with native setup profiles' do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @character_root = File.join(root, 'TEST', 'Leader')
      @store = EO::HunterSetup::Store.new(root: File.join(@character_root, 'eohunter'))
      example.run
    end
  end

  def legacy(settings)
    path = File.join(@character_root, 'bigshot_profiles', 'Trio.yaml')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, YAML.dump(settings))
    path
  end

  def config
    EO::HunterGroup.read_group_profile('Trio', data_dir: @root, game: 'TEST', character: 'Leader')
  end

  def save(kind, name, data)
    @store.save(kind, name, data, expected_revision: nil)
  end

  it 'preserves legacy startup without writing or migrating the profile' do
    path = legacy('group_members' => 'First, Second', 'resting_room_id' => 324)
    original = File.binread(path)
    expect(config).to eq(members: %w[First Second], refuge_room: 324)
    expect(File.binread(path)).to eq(original)
  end

  it 'uses the same native profile, defaults and plans as an ordinary hunt' do
    legacy('group_members' => ['Wrong'], 'resting_room_id' => 1)
    save(:defaults, 'usual', { 'schema_version' => 1, 'settings' => { 'fried' => 90 } })
    save(:plans, 'sword', { 'commands' => 'attack(untildead)' })
    save(:profiles, 'Trio', { 'schema_version' => 1, 'defaults' => 'usual', 'combat_plan' => 'sword',
                            'settings' => { 'group_members' => %w[First Second], 'resting_room_id' => 324 } })
    path = EO::HunterSetup::Composition.profile_path('Trio', data_dir: @root, game: 'TEST', character: 'Leader')
    profile = EO::Engine::Profile.load(path)
    expect(config).to eq(members: profile['group_members'], refuge_room: profile['resting_room_id'])
    expect(config).to eq(members: %w[First Second], refuge_room: 324)
    expect(profile['fried']).to eq(90)
    expect(profile['hunting_commands']).to eq(['attack(untildead)'])
    # Recovery pins resolved raw input, not an envelope or mutable plan reference.
    recovered = EO::Engine::Profile.new(profile.source)
    expect(recovered.settings).to eq(profile.settings)
    expect(profile.source).not_to have_key('combat_plan')
  end

  it 'refuses invalid native references instead of launching the legacy namesake' do
    legacy('group_members' => ['First'], 'resting_room_id' => 324)
    save(:profiles, 'Trio', { 'schema_version' => 1, 'defaults' => 'missing',
                            'settings' => { 'group_members' => ['First'], 'resting_room_id' => 324 } })
    expect { config }.to raise_error(ArgumentError, /missing/)
  end

  it 'does not let startup metadata come from character-wide defaults' do
    save(:defaults, 'usual', { 'schema_version' => 1, 'settings' => { 'group_members' => ['First'], 'resting_room_id' => 324 } })
    save(:profiles, 'Trio', { 'schema_version' => 1, 'defaults' => 'usual', 'settings' => {} })
    expect { config }.to raise_error(ArgumentError, /group_members/)
  end
end
