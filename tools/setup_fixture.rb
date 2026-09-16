# frozen_string_literal: true

# Browser acceptance fixture only. No Lich, credentials, profiles or game I/O.
require 'tmpdir'
require 'zlib'
load File.expand_path('../scripts/eohunter/engine.rb', __dir__)
%w[schema geography map_images hazards app server].each do |part|
  require File.expand_path("../scripts/eohunter/setup/#{part}", __dir__)
end

Room = Struct.new(:id, :uid, :wayto, :image, :image_coords, :title)
Template = Struct.new(:name, :level, :areas, :undead) do
  def found_at_uid?(uid) = areas.any? { |area| area[:uids].include?(uid) }
end

Dir.mktmpdir('eohunter-browser-fixture') do |directory|
  # A real decodable raster, generated only for offline overlay-coordinate tests.
  chunk = ->(kind, data) { [data.bytesize].pack('N') + kind + data + [Zlib.crc32(kind + data)].pack('N') }
  pixels = ("\x00".b + [240, 232, 208].pack('C*') * 400) * 200
  png = [137, 80, 78, 71, 13, 10, 26, 10].pack('C*') + chunk.call('IHDR', [400, 200, 8, 2, 0, 0, 0].pack('NNCCCCC')) + chunk.call('IDAT', Zlib.deflate(pixels)) + chunk.call('IEND', ''.b)
  %w[fixture-only.png fixture-rest.png].each { |name| File.binwrite(File.join(directory, name), png) }
  images = EO::HunterSetup::MapImages.new(root: directory, names: %w[fixture-only.png fixture-rest.png])
  store = EO::HunterSetup::Store.new(root: File.join(directory, 'native'), legacy_root: File.join(directory, 'legacy'))
  store.save('plans', 'Usual combat', { 'commands' => 'attack' }, expected_revision: nil)
  store.save('defaults', 'Usual setup', { 'schema_version' => 1, 'settings' => { 'fried' => 100, 'hunting_right_hand' => 'keep' }, 'combat_plan' => 'Usual combat' }, expected_revision: nil)
  store.save('profiles', 'Fixture hunt', { 'schema_version' => 1, 'settings' => { 'hunting_room_id' => 2, 'resting_room_id' => 1,
                                                                               'hunting_boundaries' => '1', 'targets' => 'fixture rat',
                                                                               'custom_extension' => { 'keep_me' => false } } }, expected_revision: nil)
  rooms = [Room.new(1, [101], { '2' => 'east' }), Room.new(2, [102], { '1' => 'west', '3' => 'east' }), Room.new(3, [103], { '2' => 'west' })]
  rooms.each do |room|
    room.image = 'fixture-only.png'
    room.image_coords = [room.id * 90, 50, room.id * 90 + 10, 60]
    room.title = ["Fixture room #{room.id}"]
  end
  rooms << Room.new(4, [104], {}, 'fixture-rest.png', [10, 10, 20, 20], ['Distant rest fixture'])
  rooms << Room.new(5, [4568001], { '6' => ';e do_not_execute' }, 'fixture-only.png', [40, 100, 50, 110], ['Plane 3 fixture'])
  rooms << Room.new(6, [4570001], { '5' => ';e do_not_execute' }, 'fixture-only.png', [200, 100, 210, 110], ['Plane 5 fixture'])
  templates = [Template.new('fixture rat', 1, [{ name: 'Fixture area (not game data)', uids: [102, 103] }], false)]
  templates << Template.new('shared plane creature', 90, [{ name: 'The Rift', uids: [4568001, 4570001] }], false)
  templates << Template.new('plane three creature', 90, [{ name: 'The Rift', uids: [4568001] }], false)
  templates << Template.new('plane five creature', 90, [{ name: 'The Rift', uids: [4570001] }], false)
  templates << Template.new('enormous rift crawler', 103, [{ name: 'The Rift', uids: [4569001] }], false)
  resolver = ->(uid) { rooms.select { |room| room.uid.include?(uid) }.map(&:id) }
  schema = EO::HunterSetup::Schema.new(profile_class: EO::Engine::Profile, cleanse_policy_class: EO::Engine::Cleanse::Policy)
  original_capabilities = schema.capabilities
  schema.define_singleton_method(:capabilities) { original_capabilities.merge('injury_checks' => %w[able_to_cast? able_to_use_ranged? able_to_sneak? get_injury_data].to_h { |name| [name, true] }) }
  draft_area = { id: 'draft-route', label: 'Draft route', parent_label: 'Draft fixture region',
                 native_habitat_names: ['Fixture area (not game data)'], map_sheets: ['fixture-only.png'],
                 uids: [101, 102, 103], excluded_uids: [4568001], status: 'draft',
                 notes: ['The scripted cave is excluded; access has not been checked.', 'Room 1 is a transit room without a creature record.'],
                 source: { kind: 'offline fixture' }, static_check: { result: 'partial' } }
  special_area = draft_area.merge(id: 'special-cave', label: 'Scripted cave', uids: [4568001], excluded_uids: [], status: 'special_candidate')
  catalog = EO::HunterSetup::AreaCatalog.new(records: [draft_area, special_area])
  geography = EO::HunterSetup::Geography.new(templates: templates, rooms: rooms, uid_resolver: resolver, catalog: catalog)
  app = EO::HunterSetup::App.new(store: store, schema: schema, geography: geography, map_images: images,
                                 society_abilities: { groups: [
                                   { name: 'Council of Light', available: true, member: true, abilities: [{ id: 9903, name: 'Sign of Warding', description: 'Fixture ward.', cost: { mana: 1 }, maintainable: true }] },
                                   { name: 'Order of Voln', available: true, member: true, abilities: [{ id: 9805, name: 'Symbol of Courage', description: 'Fixture courage.', cost: 42, maintainable: true }, { id: 9813, name: 'Symbol of Mana', maintainable: false, reason: 'Use mana recovery.' }] },
                                   { name: 'Guardians of Sunfist', available: true, member: true, abilities: [{ id: 9707, name: 'Sigil of Defense', description: 'Fixture defense.', cost: { mana: 5, stamina: 5 }, maintainable: true }] }
                                 ] },
                                 uid_ids: resolver, room_lookup: ->(id) { rooms.find { |room| room.id == id } },
                                 context: { character: 'Demo character (fixture)', game: 'OFFLINE' },
                                 hazards: EO::HunterSetup::Hazards.new(profile_class: EO::Engine::Profile))
  server = EO::HunterSetup::Server.new(app: app)
  %w[INT TERM].each { |signal| Signal.trap(signal) { Thread.new { server.shutdown } } }
  begin
    server.start
    puts server.url
    $stdout.flush
    server.join
  ensure
    server.shutdown
  end
end
