# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::ManagedGroup do
  it 'refreshes the native roster at safe startup instead of trusting join-only cached nouns' do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    entry = Module.new.tap { |mod| mod.module_eval(source[/^module EOHunter\n.*?\nend\n/m]) }::EOHunter
    native_group = double('native Group', check: nil, checked?: true)
    stub_const('Lich::Gemstone::Group', native_group)
    stub_const('Script', double('Script', current: Object.new))
    allow(entry).to receive(:before_dying)
    allow(entry).to receive(:group_identity_reader).and_return(-> { true })
    allow(entry).to receive(:group_native_reader).and_return(nil)
    local = EO::Engine::World.new
    allow(local).to receive(:room).and_return(OpenStruct.new(id: 324))
    run = double('context', recovery?: false, refuge_room: 324, role: :head, members: ['Follower'], report_unresolved: nil)
    expect(native_group).to receive(:check).ordered
    expect(entry).to receive(:lead).ordered.and_raise('stop after membership refresh')
    expect { entry.run_managed(nil, local, run) }.to raise_error('stop after membership refresh')
  end

  let(:policy) { EO::Engine::Rest::Policy.new(resting_room: 324, rest_till_exp: 100) }
  let(:me) do
    OpenStruct.new(dead?: false, standing?: true, muckled?: false, in_rt?: false, in_cast_rt?: false,
                   encumbrance_pct: 0, fxp_pct: 0, mana_pct: 100, spirit: 10, stamina_pct: 100)
  end
  let(:world) do
    OpenStruct.new(me: me, room: OpenStruct.new(id: 324, count: 2, targets: [], players: [OpenStruct.new(noun: 'Follower')]),
                   hands: OpenStruct.new(right: OpenStruct.new(id: '11'), left: OpenStruct.new(id: nil)),
                   group_nouns: ['Follower'], group_leader_noun: nil, hiders?: false)
  end
  let(:context) do
    double('exact context', recovery?: false, command: :prepare, cancelled?: false, refuge_room: 324,
      members: ['Follower'], leader: 'Leader', join_at_rally: true,
      report_ready: true, report_committed: true, report_state: true, report_safe: true, report_unresolved: true)
  end
  let(:children) { double('owned children', idle?: true, idle_except?: true, stop_all: nil) }
  let(:rest) { double('shared Rest', { prepare_managed!: nil, 'prepare_hands=' => nil, managed_prepared?: true, phase: :managed_ready, cancel!: nil }) }
  let(:loadout) { double('native Loadout', satisfied?: true, prepare: nil, stuck?: false) }
  let(:loot) { double('native Loot', looting?: false, preserve_next_preemption!: true) }
  let(:normal_rest) { double('normal group Rest', resting?: false, depart_managed!: true) }
  let(:behaviors) do
    { rest_policy: policy, rest: normal_rest, loot: loot, loadout: loadout,
      loadout_policy: EO::Engine::Loadout::Policy.new,
      engage: double('native combat', owns_hands?: false), survival: double('native survival') }
  end
  let(:leader) { double('native leader', hub: double('native hub', ready?: true, activate!: true), online: ['Follower']) }
  let(:sample) do
    { source: { connection_id: 'connection', sequence: 1, received_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      fields: { room: { value: { epoch: 2 } } } }.freeze
  end
  let(:adapter) do
    described_class::Adapter.new(context: context, behaviors: behaviors, world: world, children: children,
                                 native_reader: -> { sample }, identity_reader: -> { true }, leader: leader)
  end
  let(:engine) { double('owned engine', on_tick: true, on_tick_completed: true, stop!: true, paused?: false, stopping?: false, status: { behavior: 'managed group' }) }

  before do
    allow(EO::Engine::Behaviors::Rest).to receive(:new).and_return(rest)
    EO::Engine::Travel.reset!
    EO::Engine::Events.reset!
  end

  it 'does not report registration or a current snapshot as completed preparation' do
    expect(context).not_to receive(:report_ready)
    adapter.observe(world)
  end

  it 'holds all departure until preparation and roster commit then reuses ordinary Rest' do
    adapter.completed(world, 1, state: :running)
    expect(context).to receive(:report_ready).with(hash_including(owner_tick: 1, room: 324))
    adapter.observe(world)
    allow(context).to receive(:command).and_return(:commit)
    expect(context).to receive(:report_committed).with(hash_including(owner_tick: 1))
    adapter.observe(world)
    expect(adapter.phase).to eq(:committed)
    allow(context).to receive(:command).and_return(:hunt)
    expect(leader.hub).to receive(:activate!).once
    expect(normal_rest).to receive(:depart_managed!).once
    adapter.observe(world)
    expect(adapter.wants_control?(world)).to be false
  end

  it 'refuses a hunt command without commitment' do
    adapter.completed(world, 1, state: :running)
    allow(context).to receive(:command).and_return(:hunt)
    expect(leader.hub).not_to receive(:activate!)
    adapter.observe(world)
    expect(adapter.phase).to eq(:returning)
  end

  def activate_managed_hunt
    adapter.completed(world, 1, state: :running)
    allow(context).to receive(:command).and_return(:commit)
    adapter.observe(world)
    allow(context).to receive(:command).and_return(:hunt)
    adapter.observe(world)
    expect(adapter.phase).to eq(:hunting)
  end

  it 'leaves hunting room-presence changes to native muster/follow instead of aborting an intact party' do
    activate_managed_hunt
    # The movement transcript still names the intact party; room PCs are
    # temporarily empty while Lich replaces the room description.
    world.room.players = []
    adapter.observe(world)
    expect(adapter.phase).to eq(:hunting)
  end

  it 'still returns when the native party roster changes during hunting' do
    activate_managed_hunt
    world.group_nouns = ['Unexpected']
    adapter.observe(world)
    expect(adapter.phase).to eq(:returning)
    expect(context).to have_received(:report_state).with(hash_including(reason: 'physical party changed'))
  end

  it 'requires actual co-location for startup even with the expected roster' do
    world.room.players = []
    adapter.completed(world, 1, state: :running)
    expect(context).not_to receive(:report_ready)
    adapter.observe(world)
    expect(adapter.phase).to eq(:preparing)
  end

  it 'revokes readiness on cast roundtime after a completed turn' do
    adapter.completed(world, 1, state: :running)
    me[:in_cast_rt?] = true
    expect(context).not_to receive(:report_ready)
    expect(context).to receive(:report_state).with(hash_including(ready: false))
    adapter.observe(world)
  end

  it 'does not accept a different native room epoch' do
    world.room.count = 3
    adapter.completed(world, 1, state: :running)
    expect(context).not_to receive(:report_ready)
    adapter.observe(world)
  end

  it 'does not commit an owner paused after its last completed preparation turn' do
    adapter.attach(engine)
    adapter.completed(world, 1, state: :running)
    allow(engine).to receive(:paused?).and_return(true)
    allow(context).to receive(:command).and_return(:commit)
    expect(context).not_to receive(:report_committed)
    adapter.observe(world)
  end

  it 'requires completed child cleanup and the existing rest resource policy' do
    allow(children).to receive(:idle?).and_return(false)
    adapter.completed(world, 1, state: :running)
    expect(context).not_to receive(:report_ready)
    adapter.observe(world)
    allow(children).to receive(:idle?).and_return(true)
    policy.rest_till_mana = 90
    me.mana_pct = 5
    adapter.completed(world, 2, state: :running)
    adapter.observe(world)
  end

  it 'cancels activation if native readiness disappears after commitment' do
    adapter.completed(world, 1, state: :running)
    allow(context).to receive(:command).and_return(:commit)
    adapter.observe(world)
    me[:in_rt?] = true
    allow(context).to receive(:command).and_return(:hunt)
    expect(leader.hub).not_to receive(:activate!)
    adapter.observe(world)
    expect(adapter.phase).to eq(:returning)
  end

  it 'does not prepare or hunt in a recovery-only invocation' do
    allow(context).to receive_messages(recovery?: true, command: :hunt)
    expect(rest).not_to receive(:prepare_managed!)
    expect(normal_rest).not_to receive(:depart_managed!)
    adapter.observe(world)
    expect(adapter.phase).to eq(:returning)
  end

  it 'does not report safe before native teardown or with unconfirmed original hands' do
    allow(context).to receive_messages(recovery?: true, command: :return)
    allow(rest).to receive(:phase).and_return(:resting)
    adapter.attach(engine)
    expect(context).not_to receive(:report_safe)
    adapter.completed(world, 1, state: :running)
  end

  it 'propagates an engine failure instead of a successful managed exit' do
    adapter.attach(engine)
    allow(engine).to receive(:stop_reason).and_return(:engine_error)
    expect(context).to receive(:report_unresolved).with('engine_error')
    expect { adapter.finish! }.to raise_error(described_class::Failed, 'engine_error')
  end

  it 'forwards a later emergency preemption after the managed adapter owns the loot drain' do
    native_loot = EO::Engine::Behaviors::Loot.allocate
    allow(native_loot).to receive_messages(looting?: true, tick: nil)
    behaviors[:loot] = native_loot
    emergency = double('urgent survival', priority: 0, name: 'survival', runs_muckled?: true,
      wants_control?: false, tick: nil, fire_budget: nil)
    runner = EO::Engine::Engine.new(world: world, behaviors: [emergency, adapter], interval: 0)
    adapter.attach(runner)
    adapter.request_return('operator stop')
    runner.tick
    expect(runner.status[:behavior]).to eq('managed group')
    expect(native_loot).to have_received(:tick).with(world).once

    # The second turn preempts Adapter, not Loot. Its delegation must invoke
    # the existing asynchronous loot teardown and suspend its local trip.
    allow(emergency).to receive(:wants_control?).and_return(true)
    expect(native_loot).to receive(:stop_script!).once
    expect(rest).to receive(:preempted!).with(world).once
    runner.tick
    expect(runner.status[:behavior]).to eq('survival')
    expect(runner.stopping?).to be false
  end

  it 'returns through local Rest and verifies final hands without a living hub' do
    world.group_nouns = []
    adapter.attach(engine)
    adapter.request_return('hub lost')
    expect(rest).to receive(:request_return!).with('hub lost')
    expect(rest).to receive(:tick).with(world)
    adapter.tick(world)
    allow(rest).to receive(:phase).and_return(:resting)
    allow(children).to receive(:idle?).and_return(false)
    expect(context).not_to receive(:report_safe)
    adapter.completed(world, 1, state: :running)
    allow(children).to receive(:idle?).and_return(true)
    # An altered keep-hand is not an appropriate equipment handoff.
    world.hands.right.id = '99'
    adapter.completed(world, 2, state: :running)
  end

  it 'reports safe only after return, completed tick and restored equipment' do
    world.group_nouns = []
    adapter.attach(engine)
    adapter.request_return('operator stop')
    allow(rest).to receive_messages(request_return!: true, tick: nil)
    adapter.tick(world)
    allow(rest).to receive(:phase).and_return(:resting)
    expect(context).to receive(:report_safe).with(hash_including(safe: true, owner_tick: 3, hands: ['11', nil]))
    expect(engine).to receive(:stop!).with(:managed_safe)
    adapter.completed(world, 3, state: :running)
    expect(adapter.finish!).to be true
  end

  describe 'exact child cleanup' do
    it 'keeps a stopping child busy until its native join completes' do
      owner = Object.new
      child = double('go2', join: false, stopping?: true)
      scripts = double('Script', current: owner, start_child: child)
      owned = described_class::Children.new(owner: owner, scripts: scripts)
      owned.start('go2', '324')
      expect(owned.running?('go2')).to be true
      expect(owned.idle?).to be false
      allow(child).to receive_messages(join: true, exit_error: nil)
      expect(owned.idle?).to be true
    end

    it 'exposes native child errors after teardown' do
      owner = Object.new
      child = double('prep', join: true, exit_error: RuntimeError.new('prep failed'))
      owned = described_class::Children.new(owner: owner, scripts: double(current: owner, start_child: child))
      owned.start('prep')
      expect { owned.idle? }.to raise_error(described_class::Failed, /prep failed/)
    end
  end
end

RSpec.describe 'managed preparation shares existing Rest actions' do
  it 'finishes an owned preparation script without crossing into rally travel' do
    policy = EO::Engine::Rest::Policy.new(hunting_prep_commands: ['script spellup'])
    scripts = double('owned scripts', running?: false, start: true)
    rest = EO::Engine::Behaviors::Rest.new(policy: policy, scripts: scripts)
    rest.prepare_managed!
    expect(scripts).to receive(:start).with('spellup', nil).once
    rest.tick(double('world'))
    allow(scripts).to receive(:running?).with('spellup').and_return(true)
    rest.tick(double('world'))
    expect(rest.managed_prepared?).to be false
    allow(scripts).to receive(:running?).with('spellup').and_return(false)
    rest.tick(double('world'))
    expect(rest.managed_prepared?).to be true
    3.times { rest.tick(double('world')) }
    expect(rest.phase).to eq(:managed_ready)
    rest.depart_managed!
    expect(rest.phase).to eq(:rally_out)
  end

  it 'preserves only the cooperative loot handoff, keeping later emergency cancellation' do
    loot = EO::Engine::Behaviors::Loot.allocate
    allow(loot).to receive(:stop_script!)
    loot.preserve_next_preemption!
    loot.preempted!(nil)
    expect(loot).not_to have_received(:stop_script!)
    loot.preempted!(nil)
    expect(loot).to have_received(:stop_script!).once
  end

  it 'keeps normal loot preemption unchanged' do
    loot = EO::Engine::Behaviors::Loot.allocate
    expect(loot).to receive(:stop_script!).once
    loot.preempted!(nil)
  end

  it 'allows survival to interrupt even the pending cooperative handoff' do
    loot = EO::Engine::Behaviors::Loot.allocate
    expect(loot).to receive(:stop_script!).once
    loot.preserve_next_preemption! { false }
    loot.preempted!(nil)
  end

  it 'pins raw profile configuration without reinterpreting cleaned command lists' do
    raw = { 'group_members' => ['Testfollower', 'Testsecond'], 'hunting_prep_commands' => 'stance defensive,script spellup',
            'hunting_commands' => 'attack', 'resting_room_id' => 324 }
    profile = EO::Engine::Profile.new(raw)
    expect(profile['group_members']).to eq(%w[Testfollower Testsecond])
    raw['hunting_commands'] = 'kick'
    recovery = EO::Engine::Profile.new(profile.source)
    expect(recovery.settings).to eq(profile.settings)
  end
end
