# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../../../scripts/eohunter/setup/store'
require_relative '../../../scripts/eohunter/setup/composition'
require_relative '../../../scripts/eohunter/setup/app'

RSpec.describe EO::HunterSetup::App do
  around { |example| Dir.mktmpdir('hunter-setup-app') { |dir| @dir = dir; example.run } }
  let(:store) { EO::HunterSetup::Store.new(root: File.join(@dir, 'eohunter'), legacy_root: File.join(@dir, 'legacy')) }
  let(:schema) do
    double(fields: [{ 'key' => 'fried', 'label' => 'Mind threshold' }], capabilities: {}, routine_maneuvers: [],
           validate: { 'errors' => [], 'missing' => [], 'warnings' => [], 'ready' => true, 'valid' => true })
  end
  let(:app) { described_class.new(store: store, schema: schema, context: { character: 'Fixture', game: 'TEST' }) }

  it 'bootstraps a new character without legacy data or creating directories' do
    reply = app.call('action' => 'bootstrap')
    expect(reply[:context][:character]).to eq('Fixture')
    expect(reply[:legacy_profiles]).to eq([])
    expect(Dir.children(@dir)).to eq([])
  end

  it 'saves and reloads complete native drafts, retaining unknown data' do
    raw = { 'fried' => 90, 'custom_extension' => { 'flag' => false } }
    saved = app.call('action' => 'save', 'kind' => 'profiles', 'name' => 'New hunt', 'data' => raw, 'revision' => nil)
    loaded = app.call('action' => 'read', 'kind' => 'profiles', 'name' => 'New hunt')
    expect(loaded[:data]).to eq(raw)
    expect(loaded[:revision]).to eq(saved[:revision])
    expect { app.call('action' => 'save', 'kind' => 'profiles', 'name' => 'New hunt', 'data' => {}, 'revision' => nil) }
      .to raise_error(EO::HunterSetup::Store::Conflict)
  end

  it 'validates composition with the native schema but never evaluates expressions' do
    raw = { 'wounded_eval' => 'raise "must not execute"' }
    expect(schema).to receive(:validate).with(raw, uid_ids: nil, mode: nil).and_return('errors' => [], 'missing' => ['rest'], 'warnings' => [], 'ready' => false)
    result = app.call('action' => 'validate', 'data' => raw)
    expect(result[:effective]).to eq(raw)
    expect(result[:missing]).to eq(['rest'])
  end

  it 'rejects method forwarding and reports unavailable maps' do
    expect { app.call('action' => 'instance_eval', 'data' => 'exit') }.to raise_error(ArgumentError, /unknown/)
    expect { app.call('action' => 'area', 'area' => 'Unknown') }.to raise_error(ArgumentError, /unavailable/)
    expect { app.call('action' => 'validate', 'data' => {}, 'mode' => 'execute') }.to raise_error(ArgumentError, /mode/)
  end

  it 'passes an explicit creature and room selection without broadening empty selections' do
    geography = double('geography')
    selected = described_class.new(store: store, schema: schema, geography: geography)
    expect(geography).to receive(:resolve).with(area: 'Castle', creature_names: ['guard'], room_ids: [12, 13], zone: nil, map_image: nil, added_room_ids: nil).and_return(room_ids: [12, 13])
    expect(selected.call('action' => 'area', 'area' => 'Castle', 'creature_names' => ['guard'], 'room_ids' => [12, 13])[:room_ids]).to eq([12, 13])
    expect(geography).to receive(:resolve).with(area: 'Castle', creature_names: [], room_ids: [], zone: nil, map_image: nil, added_room_ids: nil).and_return(room_ids: [])
    expect(selected.call('action' => 'area', 'area' => 'Castle', 'creature_names' => [], 'room_ids' => [])[:room_ids]).to eq([])
  end

  it 'forwards explicit manual additions with their selected map and area for validation' do
    geography = double('geography')
    selected = described_class.new(store: store, schema: schema, geography: geography)
    expect(geography).to receive(:resolve).with(area: 'Castle', creature_names: nil, room_ids: [12, 13, 14],
                                                zone: 'courtyard', map_image: 'castle.png', added_room_ids: [14])
                                          .and_return(room_ids: [12, 13, 14], added_room_ids: [14])
    result = selected.call('action' => 'area', 'area' => 'Castle', 'zone' => 'courtyard', 'map_image' => 'castle.png',
                           'room_ids' => [12, 13, 14], 'added_room_ids' => [14])
    expect(result).to eq(room_ids: [12, 13, 14], added_room_ids: [14])
    expect(Dir.children(@dir)).to eq([])
  end

  it 'renders existing profile geometry without invoking the creature suggestion path' do
    geography = double('geography')
    selected = described_class.new(store: store, schema: schema, geography: geography)
    settings = { 'hunting_room_id' => 12, 'hunting_boundaries' => '13' }
    expect(geography).to receive(:profile_map).with(settings: settings, sheet: 'forest.png').and_return(rooms: [])
    expect(selected.call('action' => 'profile_map', 'settings' => settings, 'sheet' => 'forest.png')).to eq(rooms: [])
    expect { app.call('action' => 'profile_map', 'settings' => settings) }.to raise_error(ArgumentError, /unavailable/)
  end

  it 'calculates manual room geometry as a read-only operation' do
    geography = double('geography')
    selected = described_class.new(store: store, schema: schema, geography: geography)
    expect(geography).to receive(:room_geometry).with(room_ids: [12, 13], start_room_id: 12).and_return(boundary_ids: [14])
    expect(selected.call('action' => 'room_geometry', 'room_ids' => [12, 13], 'start_room_id' => 12)).to eq(boundary_ids: [14])
    expect(Dir.children(@dir)).to eq([])
  end

  it 'assigns a custom creature sequence to a draft without saving or executing it' do
    input = { 'schema_version' => 1, 'settings' => { 'targets' => 'orc, troll', 'custom' => false } }
    draft = app.call('action' => 'creature_sequence', 'data' => input, 'creature' => 'orc', 'commands' => 'incant 711')
    expect(draft['settings']).to include('targets' => 'orc(b), troll(a)', 'hunting_commands_b' => 'incant 711', 'custom' => false)
    expect(input['settings']['targets']).to eq('orc, troll')
    expect(Dir.children(@dir)).to eq([])
  end

  it 'reads classic artwork only through the injected map image allowlist' do
    images = double('map images')
    expect(images).to receive(:read).with('classic.png').and_return(name: 'classic.png', data_url: 'fixture')
    selected = described_class.new(store: store, schema: schema, map_images: images)
    expect(selected.call('action' => 'map_image', 'name' => 'classic.png')[:name]).to eq('classic.png')
    expect { app.call('action' => 'map_image', 'name' => 'classic.png') }.to raise_error(ArgumentError, /unavailable/)
  end
end
