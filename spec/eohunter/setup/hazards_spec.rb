# frozen_string_literal: true

require_relative '../engine_helper'
require_relative '../../../scripts/eohunter/setup/hazards'

RSpec.describe EO::HunterSetup::Hazards do
  subject(:hazards) { described_class.new(profile_class: EO::Engine::Profile) }

  it 'warns for a hazardous action in both usual and creature-specific routines' do
    raw = { 'hunting_commands' => 'attack, incant 719', 'hunting_commands_b' => 'incant 713' }
    result = hazards.check(raw, area: 'The Bowels')
    expect(result['warnings']).to contain_exactly(
      hash_including('key' => 'hunting_commands', 'step' => 2, 'spell' => '719', 'kind' => 'possible_conflict'),
      hash_including('key' => 'hunting_commands_b', 'step' => 1, 'spell' => '713', 'kind' => 'possible_conflict')
    )
    expect(result['warnings'].map { |warning| warning['source'] }).to all(start_with('https://gswiki.play.net/'))
  end

  it 'keeps water warnings conditional on the selected Nelemar footprint' do
    raw = { 'hunting_commands' => '719' }
    expect(hazards.check(raw, area: 'Nelemar')['warnings'].first['kind']).to eq('possible_conflict')
    expect(hazards.check(raw, area: 'Nelemar', conditions: { 'wet' => true })['warnings'].first['kind']).to eq('known_conflict')
    expect(hazards.check(raw, area: 'Nelemar', conditions: { 'wet' => false })['warnings']).to be_empty
    expect(hazards.check(raw, area: 'Luinne Bheinn')['warnings']).to be_empty
  end

  it 'never reports opaque scripts or equipment as checked or safe' do
    raw = { 'hunting_commands' => 'script cast719, fire', 'hunting_right_hand' => 'dispel-flaring sword' }
    result = hazards.check(raw, area: 'Nelemar')
    expect(result['coverage']).to include('status' => 'partial', 'checked_steps' => 0)
    expect(result['coverage']['not_checked'].join).to include('equipment flares', 'scripts')
    expect(result['warnings']).to be_empty
  end

  it 'does not mark an invalid profile as covered' do
    result = hazards.check({ 'hunting_loadout_sets' => [] }, area: 'Bowels')
    expect(result['coverage']['status']).to eq('not_checked')
    expect(result['coverage']['not_checked'].join).to include('could not be loaded')
  end

  it 'recognizes the named spell and preserves raw text' do
    raw = { 'hunting_commands' => 'incant balefire(x2), incant darkcat' }
    before = raw.dup
    expect(hazards.check(raw, area: 'Bowels', conditions: { gas: true })['warnings'].map { |warning| warning['spell'] }).to eq(%w[713 713 719])
    expect(raw).to eq(before)
  end
end
