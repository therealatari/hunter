# frozen_string_literal: true

require 'tmpdir'
require 'yaml'
require_relative 'engine_helper'

RSpec.describe 'native profile runtime reads' do
  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @store = EO::HunterSetup::Store.new(root: File.join(directory, 'eohunter'))
      example.run
    end
  end

  def save(kind, name, data)
    @store.save(kind, name, data, expected_revision: nil)
  end

  def load_profile(name)
    EO::Engine::Profile.load(File.join(@directory, 'eohunter', 'profiles', "#{name}.yaml"))
  end

  it 'resolves referenced defaults and plans once without changing the files' do
    save(:defaults, 'usual', { 'schema_version' => 1, 'settings' => { 'fried' => 80, 'pull' => true } })
    save(:plans, 'sword', { 'commands' => 'attack target' })
    save(:profiles, 'hunt', { 'schema_version' => 1, 'defaults' => 'usual', 'combat_plan' => 'sword', 'settings' => { 'pull' => false } })
    before = Dir.glob(File.join(@directory, '**', '*.yaml')).to_h { |path| [path, File.binread(path)] }
    profile = load_profile('hunt')
    expect(profile['fried']).to eq(80)
    expect(profile['pull']).to be(false)
    expect(profile['hunting_commands']).to eq(['attack target'])
    before.each { |path, content| expect(File.binread(path)).to eq(content) }
    defaults = @store.read(:defaults, 'usual')
    @store.save(:defaults, 'usual', { 'schema_version' => 1, 'settings' => { 'fried' => 90 } }, expected_revision: defaults[:revision])
    expect(profile['fried']).to eq(80)
    expect(load_profile('hunt')['fried']).to eq(90)
  end

  it 'rejects missing native references before constructing a hunt' do
    save(:profiles, 'hunt', { 'schema_version' => 1, 'defaults' => 'missing', 'settings' => {} })
    expect { load_profile('hunt') }.to raise_error(ArgumentError, /missing/)
  end

  it 'loads the shared injury rule into the existing evaluator input once per launch' do
    policy = { 'schema_version' => 1, 'settings' => { 'wounded_eval' => 'Char.percent_health <= 70' } }
    save(:injury_policies, 'normal', policy)
    @store.set_character_injury_policy('normal', expected_revision: nil)
    save(:profiles, 'hunt', { 'schema_version' => 1, 'settings' => { 'hunting_commands' => 'attack' } })
    running = load_profile('hunt')
    expect(running['wounded_eval']).to eq('Char.percent_health <= 70')
    saved = @store.read(:injury_policies, 'normal')
    @store.save(:injury_policies, 'normal', policy.merge('settings' => { 'wounded_eval' => 'Char.percent_health <= 50' }), expected_revision: saved[:revision])
    expect(running['wounded_eval']).to eq('Char.percent_health <= 70')
    expect(load_profile('hunt')['wounded_eval']).to eq('Char.percent_health <= 50')
  end

  it 'retains standalone legacy profile semantics' do
    path = File.join(@directory, 'legacy.yaml')
    File.write(path, YAML.dump({ 'fried' => '75', 'hunting_commands' => 'attack target', 'pull' => false }))
    profile = EO::Engine::Profile.load(path)
    expect(profile['fried']).to eq(75)
    expect(profile['pull']).to be(false)
    expect(profile['hunting_commands']).to eq(['attack target'])
  end

  it 'gives explicit recovery values precedence over compatibility settings, including false' do
    path = File.join(@directory, 'ecleanse.yaml')
    original = YAML.dump({ 'cleanse_poison' => true, 'recover_disarmed' => true, 'safe_room' => '42', 'troubadours_rally' => true })
    File.write(path, original)
    profile = EO::Engine::Profile.new({ 'recovery' => { 'cleanse_poison' => false, 'safe_room' => '' } })
    policy = profile.recovery_policy(path: path, char_settings: { 'cleanse_disease' => true })
    expect(policy.cleanse_poison).to be(false)
    expect(policy.recover_disarmed).to be(true)
    expect(policy.cleanse_disease).to be(true)
    expect(policy.safe_room).to eq('')
    expect(policy.troubadours_rally).to be(false)
    expect(File.read(path)).to eq(original)
  end

  it 'preserves the legacy profile rally toggle while accepting an explicit native override' do
    path = File.join(@directory, 'missing.yaml')
    legacy = EO::Engine::Profile.new({ 'troubadours_rally' => true })
    native = EO::Engine::Profile.new({ 'troubadours_rally' => true, 'recovery' => { 'troubadours_rally' => false } })
    expect(legacy.recovery_policy(path: path).troubadours_rally).to be(true)
    expect(native.recovery_policy(path: path).troubadours_rally).to be(false)
  end

  it 'rejects truthy strings in recovery toggles' do
    expect { EO::Engine::Profile.new({ 'recovery' => { 'cleanse_poison' => 'false' } }) }.to raise_error(ArgumentError, /cleanse_poison/)
  end
end
