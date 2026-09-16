# frozen_string_literal: true

require 'ostruct'
require 'json'
require_relative '../../../scripts/eohunter/setup/geography'
require_relative '../engine_helper'

RSpec.describe EO::HunterSetup::Geography do
  def template(name, level, habitats)
    record = OpenStruct.new(name: name, level: level, undead: nil, areas: habitats)
    record.define_singleton_method(:found_at_uid?) do |uid|
      areas.any? { |area| area[:uids].any? { |entry| entry.is_a?(Range) ? entry.cover?(uid) : entry == uid } }
    end
    record
  end

  let(:templates) do
    [template('forest troll', 12, [{ name: 'Forest', uids: [101..102] }, { name: 'Island', uids: [201] }]),
     template('hill troll', 20, [{ name: 'Forest', uids: [102..103] }]),
     template('wolf', 8, [{ name: 'Meadow', uids: [103..104] }]),
     template('unknown beast', nil, [{ name: 'Unmapped', uids: [900] }])]
  end
  let(:rooms) do
    [OpenStruct.new(id: 1, uid: [101], wayto: { '2' => 'north' }),
     OpenStruct.new(id: 2, uid: [102], wayto: { '1' => 'south', '3' => 'east' }),
     OpenStruct.new(id: 3, uid: [103], wayto: { '2' => 'west', '4' => 'east' }),
     OpenStruct.new(id: 4, uid: [104], wayto: {}),
     OpenStruct.new(id: 8, uid: [108], wayto: { '1' => 'enter' }),
     OpenStruct.new(id: 20, uid: [201], wayto: {})]
  end
  let(:uid_rooms) { { 101 => [1], 102 => [2], 103 => [3], 104 => [4], 201 => [20] } }
  let(:resolver) { ->(uid) { uid_rooms.fetch(uid, []) } }
  subject(:geography) do
    described_class.new(templates: templates, rooms: rooms, uid_resolver: resolver,
                        data_revision: 'creatures-a', map_revision: 'map-a')
  end

  it 'lists named habitats with exact creature names and known-level/search filters' do
    expect(geography.areas.map { |a| a[:name] }).to eq(%w[Forest Island Meadow Unmapped])
    expect(geography.areas(query: 'TROLL', min_level: 15).map { |a| a[:name] }).to eq(['Forest'])
    expect(geography.areas(min_level: 1, max_level: 10).map { |a| a[:name] }).to eq(['Meadow'])
    expect(geography.areas(query: 'Forest').first[:creatures].map { |t| t[:name] }).to eq(['forest troll', 'hill troll'])
  end

  it 'warns about one-way entry rooms rather than treating weak connectivity as reachability' do
    rooms.find { |room| room.id == 1 }.wayto = {}
    result = geography.resolve(area: 'Forest', creature_names: ['forest troll'])
    expect(result[:components]).to eq([[1, 2]])
    expect(result[:diagnostics].find { |entry| entry[:code] == 'no_mapped_entry' }[:message]).to include('Rooms 2 have no mapped entrance')
    expect(geography.resolve(area: 'Forest', room_ids: [1])[:diagnostics].map { |entry| entry[:code] }).not_to include('no_mapped_entry')
  end

  describe 'persistent profile maps' do
    it 'recalculates exact manual room membership without losing incoming boundaries or running movement' do
      rooms[0].wayto['2'] = -> { raise 'never execute map movement' }
      result = geography.room_geometry(room_ids: [1, 2], start_room_id: 1)
      expect(result[:room_ids]).to eq([1, 2])
      expect(result[:boundary_ids]).to eq([3, 8])
      expanded = geography.room_geometry(room_ids: [1, 2, 3], start_room_id: 1)
      expect(expanded[:boundary_ids]).to eq([4, 8])
    end

    it 'refuses manual selections that remove the start, contain unknown rooms, or cannot be represented as one hunt' do
      expect { geography.room_geometry(room_ids: [2], start_room_id: 1) }.to raise_error(ArgumentError, /starting room/)
      expect { geography.room_geometry(room_ids: [1, 999], start_room_id: 1) }.to raise_error(ArgumentError, /mapped/)
      expect { geography.room_geometry(room_ids: [1, 3], start_room_id: 1) }.to raise_error(ArgumentError, /reachable/)
      expect { geography.room_geometry(room_ids: [], start_room_id: 1) }.to raise_error(ArgumentError, /mapped/)
      expect { geography.room_geometry(room_ids: ['1'], start_room_id: 1) }.to raise_error(ArgumentError, /mapped/)
      stub_const('EO::Engine::Wander::Area::CAP', 1)
      expect { geography.room_geometry(room_ids: [1, 2], start_room_id: 1) }.to raise_error(ArgumentError, /reachable/)
    end

    it 'reads custom geometry without a creature selection and preserves UID boundary references' do
      result = geography.profile_map(settings: { 'hunting_room_id' => 'u101', 'hunting_boundaries' => 'u103, 8', 'resting_room_id' => 20, 'field_rest_room_id' => 4 })
      expect(result[:markers]).to eq('hunting_room_id' => 1, 'hunting_boundaries' => [3, 8], 'resting_room_id' => 20, 'field_rest_room_id' => 4)
      expect(result[:hunting_room_ids]).to eq([1, 2])
      expect(result[:boundary_refs]).to eq([{ ref: 'u103', id: 3 }, { ref: '8', id: 8 }])
      expect(result[:rooms].map { |room| room[:id] }).to eq([1, 2, 3, 4, 8, 20])
      expect(result[:editable]).to be true
    end

    it 'uses native map sheets to show editable context and a separate rest destination' do
      rooms.each { |room| room.image = room.id == 20 ? 'island.png' : 'forest.png' }
      result = geography.profile_map(settings: { 'hunting_room_id' => 1, 'hunting_boundaries' => '2, 8' })
      expect(result[:rooms].map { |room| room[:id] }).to include(3, 4)
      expect(result[:rooms].map { |room| room[:id] }).not_to include(20)
      extra = geography.profile_map(settings: {}, sheet: 'island.png')
      expect(extra[:rooms].map { |room| room[:id] }).to eq([20])
      expect(extra[:sheets]).to eq(%w[forest.png island.png])
      expect { geography.profile_map(settings: {}, sheet: '../secret') }.to raise_error(ArgumentError, /unknown map/)
    end

    it 'does not guess ambiguous or broken references or change the original settings' do
      uid_rooms[101] = [1, 2]
      raw = { 'hunting_room_id' => 'u101', 'hunting_boundaries' => 'garbage, 999', 'resting_room_id' => 20 }
      before = Marshal.load(Marshal.dump(raw))
      result = geography.profile_map(settings: raw)
      expect(result[:editable]).to be false
      expect(result[:diagnostics].length).to eq(3)
      expect(result[:hunting_room_ids]).to eq([])
      expect(raw).to eq(before)
    end

    it 'never evaluates movement or timing code and follows directed exits using the native walker' do
      rooms[0].wayto = { '2' => -> { raise 'do not move' } }
      rooms[0].timeto = { '2' => -> { raise 'do not evaluate' } }
      rooms[1].wayto = {}
      result = geography.profile_map(settings: { 'hunting_room_id' => 1 })
      expect(result[:hunting_room_ids]).to eq([1, 2])
      expect(result[:verification]).to eq(described_class::VERIFICATION)
    end

    it 'flags a start inside a boundary and capped previews without certifying a complete area' do
      invalid = geography.profile_map(settings: { 'hunting_room_id' => 1, 'hunting_boundaries' => '1' })
      expect(invalid[:editable]).to be true # Allow removing the conflicting boundary on the map.
      expect(invalid[:diagnostics].join).to include('also a boundary')
      stub_const('EO::Engine::Wander::Area::CAP', 2)
      capped = geography.profile_map(settings: { 'hunting_room_id' => 1 })
      expect(capped[:truncated]).to be true
    end
  end

  describe 'map and named hunting-area selection' do
    let(:templates) do
      [template('shared creature', 90, [{ name: 'The Rift', uids: [4568001, 4570001, 4570014] }]),
       template('third plane creature', 86, [{ name: 'The Rift', uids: [4568001] }]),
       template('fifth plane creature', 93, [{ name: 'The Rift', uids: [4570001, 4570014] }])]
    end
    let(:rooms) do
      [OpenStruct.new(id: 1, uid: [4568001], wayto: { '2' => ';e do_not_execute' }, image: 'rift.png', tags: ['meta:mapname:Icemule - The Rift']),
       OpenStruct.new(id: 2, uid: [4570001], wayto: { '1' => ';e do_not_execute', '3' => 'east' }, image: 'rift.png'),
       OpenStruct.new(id: 3, uid: [4570014], wayto: { '2' => 'west' })]
    end
    let(:uid_rooms) { { 4568001 => [1], 4570001 => [2], 4570014 => [3] } }

    it 'exposes maps first and named hunting subdivisions from explicit UID data' do
      catalog = geography.areas.first
      expect(catalog[:maps]).to eq([{ id: 'rift.png', name: 'Icemule - The Rift' }])
      expect(catalog[:zones].map { |zone| zone[:label] }).to eq(['Plane 1', 'Plane 2', 'Plane 3', 'Plane 4', 'Plane 5', 'The Scatter'])
      expect(catalog[:zones].find { |zone| zone[:id] == 'plane-5' }[:maps]).to eq(catalog[:maps])
    end

    it 'requires a named zone before suggesting a subdivided region' do
      expect(geography.resolve(area: 'The Rift')[:zone_selection_required]).to be true
      expect { geography.resolve(area: 'The Rift', creature_names: ['shared creature']) }.to raise_error(ArgumentError, /Choose a named/)
      expect { geography.resolve(area: 'The Rift', zone: 'plane-9') }.to raise_error(ArgumentError, /Unknown subarea/)
    end

    it 'does not union other planes for a shared monster or through scripted connections' do
      result = geography.resolve(area: 'The Rift', zone: 'plane-5', map_image: 'rift.png', creature_names: ['shared creature'])
      expect(result[:room_ids]).to eq([2, 3])
      expect(result[:boundary_ids]).to eq([1])
      expect(result[:creatures].map { |creature| creature[:name] }).to eq(['fifth plane creature', 'shared creature'])
      expect(result).to include(zone_id: 'plane-5', zone_label: 'Plane 5', zone_selection_required: false)
      expect(result[:rooms].find { |room| room[:id] == 3 }[:image]).to be_nil
      expect(result[:coverage][:complete]).to be true
    end

    it 'rejects out-of-plane creatures and hand-selected rooms without broadening' do
      expect { geography.resolve(area: 'The Rift', zone: 'plane-5', creature_names: ['third plane creature']) }.to raise_error(ArgumentError, /Creatures not in habitat/)
      expect { geography.resolve(area: 'The Rift', zone: 'plane-5', room_ids: [1]) }.to raise_error(ArgumentError, /Rooms not in resolved/)
      expect(geography.resolve(area: 'The Rift', zone: 'plane-5', room_ids: [])[:room_ids]).to eq([])
    end

    it 'resolves missing UID diagnostics within the chosen zone rather than another plane' do
      uid_rooms.delete(4568001)
      expect(geography.resolve(area: 'The Rift', zone: 'plane-5')[:coverage][:complete]).to be true
      uid_rooms.delete(4570014)
      result = geography.resolve(area: 'The Rift', zone: 'plane-5')
      expect(result[:coverage][:complete]).to be false
      expect(result[:coverage][:unresolved_uids]).to eq([4570014])
    end

    it 'retains native transit UIDs in legacy Rift ranges independently of creature targets' do
      rooms << OpenStruct.new(id: 4, uid: [4570009], wayto: { '2' => 'west' })
      uid_rooms[4570009] = [4]
      result = geography.resolve(area: 'The Rift', zone: 'plane-5', creature_names: ['fifth plane creature'])
      expect(result[:room_ids]).to eq([2, 3, 4])
      expect(result[:selected_creature_names]).to eq(['fifth plane creature'])
    end

    it 'offers documented visitors without importing their home-plane rooms' do
      templates << template('enormous rift crawler', 103, [{ name: 'The Rift', uids: [4569001] }])
      rooms << OpenStruct.new(id: 4, uid: [4569001], wayto: {}, image: 'rift.png')
      uid_rooms[4569001] = [4]
      normal = geography.resolve(area: 'The Rift', zone: 'plane-5')
      expect(normal.fetch(:visitors).map { |visitor| visitor[:name] }).to eq(['enormous rift crawler'])
      expect(normal[:visitors].first).to include(level: 103, source_url: 'https://gswiki.play.net/The_Rift/saved_posts#Preview')
      expect(normal[:creatures].map { |creature| creature[:name] }).not_to include('enormous rift crawler')
      selected = geography.resolve(area: 'The Rift', zone: 'plane-5', creature_names: ['enormous rift crawler'])
      expect(selected[:selected_creature_names]).to eq(['enormous rift crawler'])
      expect(selected[:room_ids]).to eq(normal[:room_ids])
      expect(selected[:boundary_ids]).to eq(normal[:boundary_ids])
      expect(selected[:room_ids]).not_to include(4)
      expect(geography.resolve(area: 'The Rift', zone: 'plane-4')[:visitors]).to be_empty
      expect(geography.resolve(area: 'The Rift', zone: 'plane-3')[:visitors].map { |visitor| visitor[:name] }).to eq(['enormous rift crawler'])
      expect { geography.resolve(area: 'The Rift', zone: 'plane-2', creature_names: ['enormous rift crawler']) }.to raise_error(ArgumentError, /not in habitat/)
    end

    it 'keeps missing visitor attributes unknown and never duplicates a native resident' do
      absent = geography.resolve(area: 'The Rift', zone: 'plane-5')
      expect(absent[:visitors].first).to include(name: 'enormous rift crawler', level: nil, undead: nil)
      templates << template('enormous rift crawler', 103, [{ name: 'The Rift', uids: [4570001] }])
      present = geography.resolve(area: 'The Rift', zone: 'plane-5')
      expect(present[:creatures].count { |entry| entry[:name] == 'enormous rift crawler' }).to eq(1)
      expect(present[:visitors]).to be_empty
    end
  end

  describe 'research-backed geographical areas' do
    let(:record) do
      { id: 'woodland-path', label: 'Woodland path', parent_label: 'Woodland',
        native_habitat_names: %w[Forest Meadow], map_sheets: %w[west.png east.png],
        uids: [101, 102, 103, 104, 108], status: 'draft', notes: ['Review transit and the eastern exit.'],
        source: { map_sha256: 'map-a' }, static_check: { result: 'partial' } }
    end
    let(:catalog) { EO::HunterSetup::AreaCatalog.new(records: [record]) }
    subject(:geography) do
      described_class.new(templates: templates, rooms: rooms, uid_resolver: resolver, catalog: catalog,
                          data_revision: 'creatures-a', map_revision: 'map-a')
    end

    before do
      uid_rooms[108] = [8]
      rooms.each { |room| room.image = room.id < 3 ? 'west.png' : 'east.png' }
      rooms.find { |room| room.id == 8 }.image = nil
      rooms.find { |room| room.id == 20 }.image = 'island.png'
    end

    it 'lists multi-habitat aliases under a researched parent with evidence and maps' do
      parent = geography.areas.find { |entry| entry[:name] == 'Woodland' }
      expect(parent[:creatures].map { |entry| entry[:name] }).to eq(['forest troll', 'hill troll', 'wolf'])
      expect(parent[:zones].first).to include(record.reject { |key, _| key == :uids })
      expect(parent[:maps].map { |map| map[:id] }).to eq(%w[east.png west.png])
      expect(geography.areas(query: 'Woodland path').map { |entry| entry[:name] }).to eq(['Woodland'])
    end

    it 'retains all geographical members including transit and other map sheets for any target choice' do
      full = geography.resolve(area: 'Woodland', zone: 'woodland-path', map_image: 'west.png')
      only_wolf = geography.resolve(area: 'Woodland', zone: 'woodland-path', map_image: 'west.png', creature_names: ['wolf'])
      no_targets = geography.resolve(area: 'Woodland', zone: 'woodland-path', creature_names: [])
      [full, only_wolf, no_targets].each do |result|
        expect(result[:room_ids]).to eq([1, 2, 3, 4, 8])
        expect(result[:coverage][:uid_count]).to eq(5)
        expect(result[:diagnostics].map { |item| item[:code] }).to include('catalog_draft', 'catalog_static_check')
      end
      expect(only_wolf[:selected_creature_names]).to eq(['wolf'])
      expect(no_targets[:selected_creature_names]).to eq([])
      expect(full[:rooms].find { |room| room[:id] == 8 }[:image]).to be_nil
      expect(full[:zone_metadata][:notes]).to eq(record[:notes])
    end

    it 'retains unresolved geographic UID diagnostics even if no selected creature uses it' do
      uid_rooms.delete(108)
      result = geography.resolve(area: 'Woodland', zone: 'woodland-path', creature_names: ['wolf'])
      expect(result[:coverage]).to include(complete: false, unresolved_uids: [108])
    end

    it 'does not merge overlapping researched areas or creatures from another habitat with the same name' do
      other = record.merge(id: 'meadow', label: 'Meadow portion', uids: [103, 104])
      separate = described_class.new(templates: templates, rooms: rooms, uid_resolver: resolver,
                                     catalog: EO::HunterSetup::AreaCatalog.new(records: [record, other]))
      expect(separate.resolve(area: 'Woodland', zone: 'meadow')[:room_ids]).to eq([3, 4])
      expect { separate.resolve(area: 'Woodland', zone: 'meadow', creature_names: ['forest troll']) }.to raise_error(ArgumentError, /not in habitat/)
      expect(separate.resolve(area: 'Woodland', zone: 'woodland-path')[:room_ids]).not_to include(20)
    end

    it 'allows explicit additions from selected-sheet context and restricts ordinary subsets' do
      rooms << OpenStruct.new(id: 9, uid: [109], wayto: {}, image: 'west.png')
      base = geography.resolve(area: 'Woodland', zone: 'woodland-path', map_image: 'west.png')
      expect(base[:context_rooms].map { |room| room[:id] }).to eq([1, 2, 9])
      expect { geography.resolve(area: 'Woodland', zone: 'woodland-path', room_ids: [9]) }.to raise_error(ArgumentError, /not in resolved habitat/)
      edited = geography.resolve(area: 'Woodland', zone: 'woodland-path', map_image: 'west.png', added_room_ids: [9], room_ids: [1, 2, 9])
      expect(edited[:room_ids]).to eq([1, 2, 9])
      expect(edited[:added_room_ids]).to eq([9])
      expect(edited[:diagnostics].map { |item| item[:code] }).to include('manual_area_edit')
      expect { geography.resolve(area: 'Woodland', zone: 'woodland-path', map_image: 'west.png', added_room_ids: [20]) }.to raise_error(ArgumentError, /selected hunting map/)
      expect { geography.resolve(area: 'Woodland', zone: 'woodland-path', added_room_ids: [9]) }.to raise_error(ArgumentError, /selected hunting map/)
    end

    it 'withholds special candidates from ordinary area lookup' do
      record[:status] = 'special_candidate'
      expect(geography.areas.map { |entry| entry[:name] }).not_to include('Woodland')
      expect { geography.resolve(area: 'Woodland', zone: 'woodland-path') }.to raise_error(ArgumentError, /Unknown habitat/)
    end
  end

  it 'constrains an ordinary habitat to the selected map and keeps other map rooms out' do
    rooms[0].image = 'west.png'
    rooms[1].image = 'east.png'
    rooms[2].image = 'east.png'
    result = geography.resolve(area: 'Forest', map_image: 'east.png')
    expect(result[:room_ids]).to eq([2, 3])
    expect(result[:boundary_ids]).to eq([1, 4])
    expect { geography.resolve(area: 'Forest', map_image: 'unknown.png') }.to raise_error(ArgumentError, /Unknown hunting map/)
  end

  it 'allows an explicit manual extension of a legacy habitat only onto its chosen map' do
    rooms.each { |room| room.image = room.id == 20 ? 'island.png' : 'forest.png' }
    result = geography.resolve(area: 'Forest', map_image: 'forest.png', added_room_ids: [8], room_ids: [1, 2, 3, 8])
    expect(result[:room_ids]).to eq([1, 2, 3, 8])
    expect(result[:coverage][:complete]).to be true
    expect { geography.resolve(area: 'Forest', map_image: 'forest.png', added_room_ids: [20]) }.to raise_error(ArgumentError, /selected hunting map/)
  end

  it 'unions overlapping habitats but never pulls in another region of the same creature' do
    result = geography.resolve(area: 'Forest')
    expect(result[:room_ids]).to eq([1, 2, 3])
    expect(result[:boundary_ids]).to eq([4, 8])
    expect(result[:outgoing_boundary_ids]).to eq([4])
    expect(result[:incoming_boundary_ids]).to eq([8])
    expect(result[:components]).to eq([[1, 2, 3]])
    expect(result[:coverage]).to include(complete: true, uid_count: 3, room_count: 3)
  end

  it 'derives a creature subset within its selected habitat without collapsing shared nouns' do
    result = geography.resolve(area: 'Forest', creature_names: ['forest troll'])
    expect(result[:room_ids]).to eq([1, 2])
    expect(result[:boundary_ids]).to eq([3, 8])
    expect(result[:creatures].map { |t| t[:name] }).to eq(['forest troll', 'hill troll'])
    expect(result[:selected_creature_names]).to eq(['forest troll'])
  end

  it 'reports known co-spawns from overlapping other habitats, preserving unknown attributes' do
    result = geography.resolve(area: 'Forest')
    expect(result[:creatures]).to include(name: 'wolf', level: 8, undead: nil)
    expect(result[:verification]).to eq('Data-derived; not field-checked')
    expect(result).to include(data_revision: 'creatures-a', map_revision: 'map-a')
    expect(JSON.parse(JSON.generate(result))['room_ids']).to eq([1, 2, 3])
  end

  it 'restricts explicit room subsets and keeps explicit empty selections empty' do
    expect(geography.resolve(area: 'Forest', room_ids: [2])[:boundary_ids]).to eq([1, 3])
    [geography.resolve(area: 'Forest', room_ids: []), geography.resolve(area: 'Forest', creature_names: [])].each do |result|
      expect(result[:room_ids]).to be_empty
      expect(result[:coverage][:complete]).to be false
      expect(result[:diagnostics].map { |d| d[:code] }).to include('empty_footprint')
    end
  end

  it 'rejects unknown or out-of-habitat selections rather than broadening them' do
    expect { geography.resolve(area: 'Unknown') }.to raise_error(ArgumentError, /Unknown habitat/)
    expect { geography.resolve(area: 'Forest', creature_names: ['troll']) }.to raise_error(ArgumentError, /not in habitat/)
    expect { geography.resolve(area: 'Forest', room_ids: [20]) }.to raise_error(ArgumentError, /not in resolved habitat/)
  end

  it 'retains unmapped UID diagnostics even when some rooms resolve' do
    uid_rooms.delete(102)
    result = geography.resolve(area: 'Forest')
    expect(result[:room_ids]).to eq([1, 3])
    expect(result[:coverage]).to include(complete: false, unresolved_uids: [102])
    expect(result[:components]).to eq([[1], [3]])
    expect(result[:diagnostics].map { |d| d[:code] }).to include('disconnected', 'unresolved_uids')
  end

  it 'distinguishes wholly missing mappings, stale mapped IDs and ambiguous UID candidates' do
    uid_rooms[102] = [2, 20]
    uid_rooms[103] = [300]
    result = geography.resolve(area: 'Forest')
    expect(result[:coverage]).to include(complete: false, unresolved_uids: [103], missing_room_ids: [300], ambiguous_uids: { 102 => [2, 20] })
    expect(geography.resolve(area: 'Unmapped')[:coverage]).to include(complete: false, unresolved_uids: [900])
  end

  it 'reports separate portions even when every habitat UID has exactly one mapped room' do
    rooms[1].wayto.delete('3')
    rooms[2].wayto.delete('2')
    result = geography.resolve(area: 'Forest')
    expect(result[:room_ids]).to eq([1, 2, 3])
    expect(result[:components]).to eq([[1, 2], [3]])
    expect(result[:coverage][:complete]).to be true
    expect(result[:diagnostics].map { |d| d[:code] }).to include('disconnected')
  end

  it 'returns missing exterior destination IDs as boundaries and diagnostics' do
    rooms[2].wayto['999'] = 'enter door'
    result = geography.resolve(area: 'Forest')
    expect(result[:boundary_ids]).to eq([4, 8, 999])
    expect(result[:coverage][:complete]).to be false
    expect(result[:coverage][:missing_edge_room_ids]).to eq([999])
    expect(result[:diagnostics].map { |d| d[:code] }).to include('missing_rooms')
  end

  it 'labels missing revisions rather than manufacturing evidence' do
    result = described_class.new(templates: templates, rooms: rooms, uid_resolver: resolver).resolve(area: 'Forest')
    expect(result).to include(data_revision: nil, map_revision: nil)
    expect(result[:diagnostics].map { |d| d[:code] }).to include('revision_unknown', 'unverified')
  end

  it 'never evaluates executable movement or timing entries while computing the perimeter' do
    movement = -> { raise 'must never move' }
    timing = -> { raise 'must never evaluate access conditions' }
    rooms[1].wayto['3'] = movement
    rooms[2].timeto = { '4' => timing }
    result = geography.resolve(area: 'Forest')
    expect(result[:room_ids]).to eq([1, 2, 3])
    expect(result[:opaque_edges]).to contain_exactly({ from: 2, to: 3 }, { from: 3, to: 4 })
    expect(result[:diagnostics].map { |d| d[:code] }).to include('opaque_exits')
  end

  it 're-resolves UID changes without using cached native rooms_by_area results' do
    templates.each { |t| t.define_singleton_method(:rooms_by_area) { raise 'stale cached native view' } }
    first = geography.resolve(area: 'Forest')
    uid_rooms[101] = [20]
    successor = described_class.new(templates: templates, rooms: rooms, uid_resolver: resolver,
                                    data_revision: 'creatures-b', map_revision: 'map-b').resolve(area: 'Forest')
    expect(first[:room_ids]).to eq([1, 2, 3])
    expect(successor[:room_ids]).to eq([2, 3, 20])
    expect(successor).to include(map_revision: 'map-b', data_revision: 'creatures-b', verification: 'Data-derived; not field-checked')
  end

  it 'produces boundaries that reproduce the intended connected footprint in the actual Hunter area builder' do
    result = geography.resolve(area: 'Forest')
    map = rooms.to_h { |room| [room.id, room] }
    world = Object.new
    world.define_singleton_method(:exits_from) { |id| map.fetch(id).wayto.transform_keys(&:to_i) }
    world.define_singleton_method(:room_location) { |_id| nil }
    built = EO::Engine::Wander::Area.new(start: 1, boundaries: result[:boundary_ids]).build(world)
    expect(built.rooms.sort).to eq(result[:room_ids])
    expect(built.too_big?).to be false
  end

  it 'does not confuse weak connectivity with reachability against directed Hunter area building' do
    rooms[1].wayto.delete('1')
    result = geography.resolve(area: 'Forest')
    map = rooms.to_h { |room| [room.id, room] }
    world = Object.new
    world.define_singleton_method(:exits_from) { |id| map.fetch(id).wayto.transform_keys(&:to_i) }
    world.define_singleton_method(:room_location) { |_id| nil }
    built = EO::Engine::Wander::Area.new(start: 3, boundaries: result[:boundary_ids]).build(world)
    expect(result[:components]).to eq([[1, 2, 3]])
    expect(built.rooms.sort).to eq([2, 3])
  end

  it 'computes the perimeter after union, not the union of individual creature boundaries' do
    first = geography.resolve(area: 'Forest', creature_names: ['forest troll'])
    second = geography.resolve(area: 'Forest', creature_names: ['hill troll'])
    merged = geography.resolve(area: 'Forest', creature_names: ['forest troll', 'hill troll'])
    expect(first[:boundary_ids] + second[:boundary_ids]).to include(1, 3)
    expect(merged[:room_ids]).to eq([1, 2, 3])
    expect(merged[:boundary_ids] & merged[:room_ids]).to be_empty
    expect(merged[:boundary_ids]).to eq([4, 8])
  end

  it 'recomputes the perimeter when a user chooses just one of several sections' do
    rooms[1].wayto.delete('3')
    rooms[2].wayto.delete('2')
    whole = geography.resolve(area: 'Forest')
    selected = geography.resolve(area: 'Forest', creature_names: ['forest troll', 'hill troll'], room_ids: whole[:components].last)
    expect(selected[:room_ids]).to eq([3])
    expect(selected[:boundary_ids]).to eq([4])
    expect(selected[:components]).to eq([[3]])
    expect(selected[:coverage][:complete]).to be true
  end

  it 'exposes read-only room labels and graph edges for reviewing the footprint without running map commands' do
    rooms.first.title = ['[Forest, Clearing]']
    rooms.first.location = 'Forest'
    rooms.first.image = 'forest.png'
    rooms.first.image_coords = [10, 20, 18, 28]
    result = geography.resolve(area: 'Forest', creature_names: ['forest troll'])
    expect(result[:rooms].first).to include(id: 1, title: '[Forest, Clearing]', location: 'Forest', image: 'forest.png', coords: [14.0, 24.0])
    expect(result[:room_edges]).to contain_exactly([1, 2], [2, 1])
  end

  it 'rejects malformed subset shapes rather than silently coercing them' do
    expect { geography.resolve(area: 'Forest', creature_names: 'forest troll') }.to raise_error(ArgumentError, /array/)
    expect { geography.resolve(area: 'Forest', room_ids: 1) }.to raise_error(ArgumentError, /array/)
  end
end
