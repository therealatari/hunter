# frozen_string_literal: true

require 'ostruct'
require 'tmpdir'
require_relative 'engine_helper'
require_relative 'support/fake_world'

# EOHunter.build and .build_follower are the wiring: a profile in, the
# behavior set the engine runs out. Nothing covered them, because loading
# eohunter.lic would launch a hunt - so a renamed constructor keyword
# passes every part spec and fails only in the game, as an ArgumentError
# on the first run. The module is sliced out and evaluated the way
# controller_snapshot_spec does.
RSpec.describe 'EOHunter wiring' do
  let(:source) { File.read(File.expand_path('../../scripts/eohunter.lic', __dir__)) }

  # Everything from `module EOHunter` to the matching end, minus the
  # controller entry points that need a live Script.
  let(:wiring) do
    body = source[/^module EOHunter\n.*?\nend\n/m]
    Module.new.tap { |mod| mod.module_eval(body) }::EOHunter
  end

  let(:world) { FakeWorld.new }
  let(:profile) { EO::Engine::Profile.new(raw) }
  let(:raw) do
    { 'hunting_room_id' => '1', 'hunting_boundaries' => '9', 'resting_room_id' => '2',
      'targets' => 'kobold:a', 'hunting_commands' => 'attack' }
  end

  before do
    stub_const('CharSettings', {})
    stub_const('DATA_DIR', Dir.tmpdir)
    stub_const('XMLData', OpenStruct.new(game: 'TEST'))
    stub_const('Char', OpenStruct.new(name: 'Testchar'))
  end

  # build wires the real behaviors, and Flee and Maintain register line
  # rules as they are constructed. Watch keeps those in module state, so
  # left behind they outlive the example and the next spec to assert on
  # the hook set sees rules it never made.
  after { EO::Engine::Watch.clear! }

  describe 'required preparation failures' do
    let(:rest) { EO::Engine::Behaviors::Rest.new(policy: profile.rest_policy) }
    let(:engine) { EO::Engine::Engine.new(world: world, behaviors: [], interval: 0) }

    before do
      EO::Engine::Events.reset!
      allow(wiring).to receive(:msg)
      wiring.wire(engine, rest: rest, rest_policy: profile.rest_policy)
    end

    after do
      EO::Engine::Events.reset!
      EO::Engine::Actions::Base.interrupt = nil
    end

    it 'requests the ordinary return without stopping in combat, then stops at refuge before preparations replay' do
      EO::Engine::Events.emit(:preparation_failed, name: 'crystal', status: :timeout, reason: :no_confirmation)
      expect(rest.phase).to eq(:leave)
      expect(rest.rest_site).to eq(:town)
      expect(engine).not_to be_stopping
      world.id = profile.rest_policy.resting_room
      engine.tick
      expect(engine.stop_reason).to eq(:preparation_failed)
    end

    it 'stops and reports a failed return when the existing travel lifecycle is stranded' do
      EO::Engine::Events.emit(:preparation_failed, name: 'crystal', status: :failed, reason: :denied)
      EO::Engine::Events.emit(:rest_stranded, room: 2, here: 1)
      expect(engine.stop_reason).to eq(:preparation_return_failed)
      expect(wiring).to have_received(:msg).with('error', /stranded/)
    end
  end

  # The priority order the engine arbitrates on. A behavior that moves
  # here changes which one wins a tick, so it is pinned by number.
  let(:priorities) do
    { survival: 0, cleanse: 5, flee: 10, rest: 20, loot: 30,
      maintain: 40, engage: 50, wander: 60 }
  end

  it 'builds every behavior the engine runs, at its documented priority' do
    behaviors = wiring.build(profile, world)

    priorities.each do |name, priority|
      expect(behaviors[name]).not_to be_nil, "build returned no :#{name}"
      expect(behaviors[name].priority).to eq(priority), "#{name} is priority #{behaviors[name].priority}, not #{priority}"
    end
    expect(behaviors[:area]).not_to be_nil
  end

  it 'builds a follower with Orders, Assist and Follow in place of Rest, Engage and Wander' do
    member = instance_double(EO::Engine::Group::Member, strict_movement?: false, native_reader: nil)
    behaviors = wiring.build_follower(profile, world, member)

    expect(behaviors[:rest]).to be_a(EO::Engine::Behaviors::Orders)
    expect(behaviors[:engage]).to be_a(EO::Engine::Behaviors::Assist)
    expect(behaviors[:wander]).to be_a(EO::Engine::Behaviors::Follow)
    # the follower's report reads these back out of the same hash
    expect(behaviors[:rest_policy]).not_to be_nil
    expect(behaviors[:counters]).not_to be_nil
  end

  it 'passes the same exact child adapter to follower travel and cleanup consumers' do
    member = instance_double(EO::Engine::Group::Member, strict_movement?: false, native_reader: nil)
    scripts = double('exact owned children')
    behaviors = wiring.build_follower(profile, world, member, scripts: scripts)

    expect(behaviors[:rest].instance_variable_get(:@scripts)).to equal(scripts)
    expect(behaviors[:loot].instance_variable_get(:@scripts)).to equal(scripts)
    travel = behaviors[:wander].instance_variable_get(:@travel)
    trip = travel.call(2)
    expect(trip).to be_a(EO::Engine::Travel::Trip)
    expect(trip.instance_variable_get(:@scripts)).to equal(scripts)
  end

  it 'adds the leader-only Muster when leading, and not when solo' do
    expect(wiring.build(profile, world)[:muster]).to be_nil

    leader = instance_double(EO::Engine::Group::Leader, strict_movement?: false)
    behaviors = wiring.build(profile, world, leader: leader)
    expect(behaviors[:muster]).not_to be_nil
    expect(behaviors[:muster].priority).to eq(15)
  end

  # The engine is constructed from exactly these keys; a rename that the
  # part specs cannot see would hand it a nil behavior.
  it 'names the behaviors the script hands to the engine' do
    solo = source[/behaviors\.values_at\(:survival.*?\)\.compact/]
    follower = source[/behaviors\.values_at\(:survival[^)]*\)(?!\.compact)/]
    built = wiring.build(profile, world).keys

    [solo, follower].compact.each do |call|
      call.scan(/:(\w+)/).flatten.map(&:to_sym).each do |key|
        next if key == :muster # leader-only, compacted out when solo

        expect(built).to include(key), "the engine is given :#{key}, which build does not return"
      end
    end
  end

  # The profile name is the first script argument, interpolated whole into
  # a path. `;eohunter ../../../../etc/passwd` read any YAML on disk.
  describe '.profile_path' do
    it 'keeps an ordinary name untouched' do
      expect(wiring.profile_path('ojandhaart')).to end_with('bigshot_profiles/ojandhaart.yaml')
      expect(wiring.profile_path('my profile')).to end_with('bigshot_profiles/my profile.yaml')
    end

    it 'cannot be walked out of the profile directory' do
      %w[../../../../etc/passwd a/b/c .hidden].each do |name|
        path = wiring.profile_path(name)
        expect(path).to include('bigshot_profiles/')
        expect(path).not_to include('..')
        expect(File.dirname(path)).to end_with('bigshot_profiles')
      end
    end

    it 'refuses a name with nothing left of it' do
      expect { wiring.profile_path('../') }.to raise_error(ArgumentError)
    end
  end
end
