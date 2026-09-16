# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

EngageNpc = Struct.new(:id, :name, :noun, :status, :type, keyword_init: true) unless defined?(EngageNpc)

RSpec.describe EO::Engine::Engage::Routine do
  it 'splits the modifiers off the text and keeps the raw line' do
    lines = described_class.parse(['attack', '1030 (m20 once)', 'cman bullrush (!prone EB"Enh. Strength")'])
    expect(lines.map(&:text)).to eq(['attack', '1030', 'cman bullrush'])
    expect(lines[1].modifiers).to eq(['m20', 'once'])
    expect(lines[2].modifiers).to eq(['!prone', 'EB"Enh. Strength"'])
    expect(lines[1].raw).to eq('1030 (m20 once)')
  end
end

RSpec.describe EO::Engine::Engage::Conditions do
  let(:me) do
    OpenStruct.new(encumbrance_pct: 10, shadow_essence: 0, health_pct: 100, kneeling?: false, mana: 100, stamina: 100, spirit: 10,
                   hidden?: false, diseased?: false, poisoned?: false)
  end
  let(:room) { OpenStruct.new(targets: [], players: []) }
  let(:world) { OpenStruct.new(me: me, room: room, group_nouns: []) }
  let(:target) { EngageNpc.new(id: '1', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc') }
  let(:state) { EO::Engine::Engage::State.new }
  let(:tp) { EO::Engine::Targets::Policy.new }
  let(:buffs) { [] }

  before do
    active = buffs
    me.define_singleton_method(:effect_active?) { |n| active.any? { |b| n.is_a?(Regexp) ? b =~ n : b == n } }
    me.define_singleton_method(:buff_matching?) { |rx| active.any? { |b| b =~ rx } }
    me.define_singleton_method(:spell_active?) { |_n| false }
    me.define_singleton_method(:spell_effect_active?) { |_p| false }
    me.define_singleton_method(:cooldown_active?) { |_n| false }
    me.define_singleton_method(:debuff_active?) { |_n| false }
    me.define_singleton_method(:buff_time_left) { |_n| 0.0 }
  end

  def blocked(raw, **opts)
    line = EO::Engine::Engage::Routine.parse([raw]).first
    described_class.blocked_by(line, world, target, state, tp, **opts)
  end

  it 'passes a line with no modifiers' do
    expect(blocked('attack')).to be_nil
  end

  it 'reads the amount modifiers and their negations' do
    expect(blocked('1030 (m20)')).to be_nil
    me.mana = 19
    expect(blocked('1030 (m20)')).to eq('m20')
    expect(blocked('1030 (!m20)')).to be_nil
    me.mana = 20
    expect(blocked('1030 (!m20)')).to eq('!m20')
    room.targets = [target, EngageNpc.new(id: '2', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc')]
    expect(blocked('cman sweep (mob2)')).to be_nil
    expect(blocked('cman sweep (mob3)')).to eq('mob3')
  end

  it 'reads buff words, buff time, and the generic effects checks' do
    # bigshot check_state_condition 4367: the bare word skips while the
    # buff is DOWN, so the line that puts it up runs once and then stops.
    # `barrage (barrage)` is "barrage unless already barraging".
    expect(blocked('barrage (barrage)')).to eq('barrage')
    buffs << 'Enh. Dexterity (+10)'
    expect(blocked('barrage (barrage)')).to be_nil
    expect(blocked('barrage (!barrage)')).to eq('!barrage')
    expect(blocked('barrage (buff30)')).to eq('buff30')
    me.define_singleton_method(:buff_time_left) { |_n| 5.0 }
    expect(blocked('barrage (buff30)')).to be_nil
    expect(blocked('attack (EB"Enh. Dex")')).to be_nil
    expect(blocked('attack (!EB"Enh. Dex")')).to eq('!EB"Enh. Dex"')
  end

  it "reads creature facts from Lich's creature instance" do
    statuses = []
    creature = OpenStruct.new
    creature.define_singleton_method(:has_status?) { |s| statuses.include?(s.to_s) }
    world.define_singleton_method(:creature) { |_id| creature }
    expect(blocked('cman trip (prone)')).to be_nil
    statuses << 'prone'
    expect(blocked('cman trip (prone)')).to eq('prone')
    expect(blocked('cman trip (!prone)')).to be_nil
    target.type = 'aggressive npc,undead'
    expect(blocked('smite (undead)')).to be_nil
    expect(blocked('smite (!undead)')).to eq('!undead')
  end

  it 'reads once, room and repeatdelay from the registry' do
    now = Time.at(10_000)
    expect(blocked('1030 (once)')).to be_nil
    state.register('1', '1030 (once)', now)
    expect(blocked('1030 (once)')).to eq('once')
    state.register('9', '1712 (room)', now)
    expect(blocked('1712 (room)')).to eq('room')
    state.register('9', '917 (repeatdelay10)', now)
    expect(blocked('917 (repeatdelay10)', now: now + 5)).to eq('repeatdelay10')
    expect(blocked('917 (repeatdelay10)', now: now + 11)).to be_nil
  end
end

RSpec.describe EO::Engine::Behaviors::Engage do
  def npc(id, name = 'kobold', noun: name.split.last, status: '')
    EngageNpc.new(id: id.to_s, name: name, noun: noun, status: status, type: 'aggressive npc')
  end

  let(:me) do
    OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, current_target_id: nil, hidden?: false,
                   mana: 100, stamina: 100, max_stamina: 100, spirit: 10, health_pct: 100, encumbrance_pct: 0, kneeling?: false,
                   profession: 'Warrior', moc_ranks: 0, diseased?: false, poisoned?: false, shadow_essence: 0, name: 'Testchar')
  end
  let(:room) { OpenStruct.new(id: 1, targets: [npc(1), npc(2, 'orc')], players: [], title: '[Kobold Village]') }
  let(:spells) { {} }
  let(:world) { OpenStruct.new(me: me, room: room, spell: spells, claim_mine?: true, foreign_disks: [], group_nouns: []) }
  let(:policy) { EO::Engine::Engage::Policy.new(routines: { 'a' => ['attack', '1030 (once)'], 'b' => ['cman bullrush'] }) }
  let(:tp) { EO::Engine::Targets::Policy.new(wanted: { 'kobold' => 'a', 'orc' => 'b' }) }
  let(:stances) { [] }
  let(:engage) { described_class.new(policy: policy, targets_policy: tp, stance: ->(s) { stances << s; true }) }
  let(:calls) { [] }

  before do
    %i[spell_active? cooldown_active? debuff_active? spell_effect_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
    me.define_singleton_method(:effect_active?) { |_n| false }
    me.define_singleton_method(:buff_matching?) { |_n| false }
    me.define_singleton_method(:buff_time_left) { |_n| 0.0 }
    ok = EO::Engine::Actions::Result.new(status: :success)
    log = calls
    { EO::Engine::Actions::Target => :target, EO::Engine::Actions::Attack => :attack, EO::Engine::Actions::Cast => :cast,
      EO::Engine::Actions::Maneuver => :maneuver, EO::Engine::Actions::Command => :command }.each do |klass, tag|
      allow(klass).to receive(:new) do |_w, **kw|
        t = kw[:target]
        log << [tag, kw.reject { |k, _| k == :target }.merge(t ? { target: t.respond_to?(:id) ? t.id : t } : {})]
        instance_double(klass, call: ok)
      end
    end
  end

  after { EO::Engine::Events.reset! }

  it 'runs a named preparation without stance or target substitution, respecting once' do
    policy.preparations = EO::Engine::Preparations.new('target' => { 'perform' => 'feed my crystal', 'result' => 'user_feed_result' })
    policy.routines = { 'a' => ['prepare target(once)'] }
    result = EO::Engine::Actions::Result.new(status: :success, reason: :prepared)
    action = instance_double(EO::Engine::Actions::Prepare, call: result)
    expect(EO::Engine::Actions::Prepare).to receive(:new).with(world, name: 'target', preparations: policy.preparations).once.and_return(action)
    expect(engage).not_to receive(:soothe)
    expect(engage).not_to receive(:reaction)
    expect(engage.tick(world)).to be_success # TARGET owns this tick
    expect(engage.tick(world)).to equal(result)
    expect(engage.tick(world)).to have_attributes(status: :skipped, reason: :condition)
    expect(stances).to be_empty
  end

  it 'holds an unsent named preparation instead of registering once or advancing to attack' do
    policy.preparations = EO::Engine::Preparations.new('crystal' => { 'perform' => 'feed my crystal', 'result' => 'user_feed_result' })
    policy.routines = { 'a' => ['prepare crystal(once)', 'attack'] }
    skipped = EO::Engine::Actions::Result.new(status: :skipped, reason: :muckled)
    prepared = EO::Engine::Actions::Result.new(status: :success, reason: :prepared)
    action = instance_double(EO::Engine::Actions::Prepare)
    allow(action).to receive(:call).and_return(skipped, prepared)
    expect(EO::Engine::Actions::Prepare).to receive(:new).twice.and_return(action)
    expect(engage.tick(world)).to be_success # TARGET owns this tick
    expect(engage.tick(world)).to equal(skipped)
    expect(engage.tick(world)).to equal(prepared)
    expect(calls.map(&:first)).not_to include(:attack)
    engage.tick(world)
    expect(calls.map(&:first)).to include(:attack)
  end

  it 'sends only TARGET in the first tick and only the preparation in the next' do
    policy.preparations = EO::Engine::Preparations.new('crystal' => { 'perform' => 'feed my crystal', 'result' => 'user_feed_result' })
    policy.routines = { 'a' => ['prepare crystal'] }
    world.message_events = [:user_feed_result]
    allow(EO::Engine::Actions::Target).to receive(:new).and_call_original
    commands = []
    allow_any_instance_of(EO::Engine::Actions::Target).to receive(:game_send) do |_action, command|
      commands << command
      'You are now targeting a kobold.'
    end
    allow_any_instance_of(EO::Engine::Actions::Target).to receive(:next_line).and_return('You are now targeting a kobold.')
    allow_any_instance_of(EO::Engine::Actions::Prepare).to receive(:game_send) do |_action, command|
      commands << command
      EO::Engine::Events.emit(:user_feed_result)
      'fed'
    end

    expect(engage.tick(world)).to have_attributes(status: :success, acted: true)
    expect(commands).to eq(['target #1'])
    commands.clear
    expect(engage.tick(world)).to have_attributes(status: :success, reason: :prepared, acted: true)
    expect(commands).to eq(['feed my crystal'])
  end

  it 'retains the normal stance change for legacy spell preparation' do
    policy.routines = { 'a' => ['prepare spirit warding i'] }
    engage.tick(world)
    expect(stances).to eq(['defensive'])
    expect(calls).to include([:command, { command: 'prepare spirit warding i' }])
  end

  it 'does not defer a preparation when the game already has the selected target' do
    me.current_target_id = '1'
    policy.preparations = EO::Engine::Preparations.new('crystal' => { 'perform' => 'feed my crystal', 'result' => 'user_feed_result' })
    policy.routines = { 'a' => ['prepare crystal'] }
    result = EO::Engine::Actions::Result.new(status: :success, reason: :prepared)
    action = instance_double(EO::Engine::Actions::Prepare, call: result)
    expect(EO::Engine::Actions::Target).not_to receive(:new)
    expect(EO::Engine::Actions::Prepare).to receive(:new).and_return(action)
    expect(engage.tick(world)).to equal(result)
  end

  it 'passes by a creature met outside the hunting area' do
    area = instance_double(EO::Engine::Wander::Area, built?: true)
    allow(area).to receive(:include?) { |id| id.to_i == 1 }
    roamer = described_class.new(policy: policy, targets_policy: tp, area: area, stance: ->(_s) { true })
    expect(roamer.wants_control?(world)).to be true
    room.id = 50
    expect(roamer.wants_control?(world)).to be false
  end

  it 'finishes a fight already under way when the room is out of area' do
    area = instance_double(EO::Engine::Wander::Area, built?: true)
    allow(area).to receive(:include?) { |id| id.to_i == 1 }
    state = EO::Engine::Engage::State.new
    roamer = described_class.new(policy: policy, targets_policy: tp, area: area, state: state, stance: ->(_s) { true })
    room.id = 50
    state.fight_room = 50
    expect(roamer.wants_control?(world)).to be true
  end

  it 'wants control only in our room with a wanted creature' do
    expect(engage.wants_control?(world)).to be true
    world[:claim_mine?] = false
    expect(engage.wants_control?(world)).to be false
    world[:claim_mine?] = true
    room.targets = []
    expect(engage.wants_control?(world)).to be false
  end

  it 'owns the hands only while its current target is still live' do
    expect(engage.owns_hands?(world)).to be false
    engage.tick(world)
    expect(engage.owns_hands?(world)).to be true
    room.targets.first.status = 'dead'
    room.targets.shift
    expect(engage.owns_hands?(world)).to be false
  end

  it 'releases hands when priority selects another living target' do
    policy.priority = true
    orc = room.targets.last
    kobold = room.targets.first
    room.targets = [orc]
    engage.tick(world)
    expect(engage.owns_hands?(world)).to be true

    room.targets.unshift(kobold)
    expect(engage.loadout_target(world)).to eq(kobold)
    expect(engage.owns_hands?(world)).to be false
    expect(engage.target).to eq(orc)
  end

  it 'lets the equipment handoff consume the tick before targeting or attacking' do
    result = EO::Engine::Actions::Result.new(status: :success, reason: :established)
    handoff = double('equipment handoff')
    engage.prepare_loadout = handoff
    expect(handoff).to receive(:call).with(world, room.targets.first).and_return(result)

    expect(engage.tick(world)).to eq(result)
    expect(calls).to be_empty
    expect(engage.target).to be_nil
  end

  it 'preserves a routine weapon across wield, attack and store, then restores before the next target' do
    policy.routines['a'] = ['wield maul', 'attack', 'store both']
    baseline = OpenStruct.new(id: 'staff', noun: 'staff')
    world.hands = OpenStruct.new(right: baseline, left: nil)
    adapter = instance_double(EO::Engine::Loadout::Core, ready_item: baseline)
    allow(adapter).to receive(:reconcile) { |**| world.hands.right = baseline }
    loadout = EO::Engine::Behaviors::Loadout.new(
      policy: EO::Engine::Loadout::Policy.new(right: 'ready:weapon'), owner: engage, adapter: adapter
    )
    ok = EO::Engine::Actions::Result.new(status: :success)
    wield = instance_double(EO::Engine::Actions::Wield)
    allow(wield).to receive(:call) { world.hands.right = OpenStruct.new(id: 'maul', noun: 'maul'); ok }
    allow(EO::Engine::Actions::Wield).to receive(:new).and_return(wield)
    store = instance_double(EO::Engine::Actions::Store)
    allow(store).to receive(:call) { world.hands.right = nil; ok }
    allow(EO::Engine::Actions::Store).to receive(:new).and_return(store)
    engine = EO::Engine::Engine.new(world: world, behaviors: [loadout, engage], interval: 0)

    engine.tick
    expect(world.hands.right.id).to eq('maul')
    engine.tick
    expect(world.hands.right.id).to eq('maul')
    engine.tick
    expect(store).to have_received(:call).once
    expect(adapter).not_to have_received(:reconcile)
    room.targets.shift
    engine.tick
    expect(world.hands.right.id).to eq('staff')
    expect(adapter).to have_received(:reconcile).once
    expect(engage.target.name).to eq('kobold') # the next target has not been engaged yet
  end

  it 'keeps a fight it started when another player walks in, and asks the claim afresh in the next room' do
    policy.routines['a'] = ['attack']
    engage.tick(world)
    expect(engage.target).not_to be_nil
    world[:claim_mine?] = false
    expect(engage.wants_control?(world)).to be true
    EO::Engine::Events.emit(:entered_room, room: 2)
    room.id = 2
    expect(engage.wants_control?(world)).to be false
    world[:claim_mine?] = true
    expect(engage.wants_control?(world)).to be true
  end

  # Both sides went through .to_s, so an unmapped room (Map.current nil,
  # room.id nil) compared '' == '' and read as combat-blocked: Engage
  # never engaged and Wander never claimed. Nothing is blocked until
  # something blocks it.
  it 'engages in an unmapped room, where no room has been blocked' do
    room.id = nil
    expect(engage.state.combat_blocked_room).to be_nil
    expect(engage.wants_control?(world)).to be(true)
  end

  # bigshot resets every per-target latch whenever the game's target is not
  # the creature it is about to attack (attack 7774-7777). The engine had
  # the same reset but only called it on a new room or a bolt, so the
  # unarmed tier, the armed follow-up, the aim indices, the dislodge state
  # and a pending weapon reaction carried over from the creature that died.
  it 'resets the per-target routine state when the target changes' do
    engage.state.unarmed_tier = 3
    engage.state.unarmed_followup = true
    engage.state.unarmed_followup_attack = 'jab'
    engage.state.archery_aim = 2
    engage.state.uac_aim = 2
    engage.state.reaction = 'something'

    engage.tick(world) # targets kobold 1, which the game is not on

    expect(engage.state.unarmed_tier).to eq(1)
    expect(engage.state.unarmed_followup).to be false
    expect(engage.state.unarmed_followup_attack).to eq('')
    expect(engage.state.archery_aim).to eq(0)
    expect(engage.state.uac_aim).to eq(0)
    expect(engage.state.reaction).to be_nil
  end

  it 'leaves the state alone when the game is already on the target' do
    me.current_target_id = '1'
    engage.state.unarmed_tier = 3
    engage.tick(world)
    expect(engage.state.unarmed_tier).to eq(3)
  end

  # cmd 3995: a kick while held in place is a punch. kick_to_punch existed
  # with its citation and its YARD but had no call site, and the latch it
  # read was never declared.
  it 'sends a punch for a kick while rooted' do
    policy.routines['a'] = ['kick']
    engage.tick(world) # target
    engage.tick(world) # the kick line
    expect(calls.map { |c| c.last[:command] }.compact).to include('kick')

    calls.clear
    EO::Engine::Events.emit(:rooted)
    engage.state.new_room!(1) # back to the top of the routine
    me.current_target_id = nil
    EO::Engine::Events.emit(:rooted)
    engage.tick(world)
    engage.tick(world)
    expect(calls.map { |c| c.last[:command] }.compact).to include('punch')
  end

  it 'stops swapping the kick once the coils break' do
    engage # subscribe before emitting
    EO::Engine::Events.emit(:rooted)
    expect(engage.state.rooted).to be true
    EO::Engine::Events.emit(:unrooted)
    expect(engage.state.rooted).to be false
  end

  # bigshot sleeps in one-second slices and breaks on rest or a dead target
  # (cmd_sleep 6548-6552). A bare Kernel#sleep held the whole tick: a
  # routine 'sleep 20' kept the engine in one line while the creature died,
  # we were stunned, or a stop was requested. The breaks are asserted on
  # routine_sleep itself, since Engage retargets before dispatching again.
  describe 'a routine sleep' do
    let(:slept) { [] }

    before do
      engage.tick(world) # take a target
      allow(engage).to receive(:sleep) { |n| slept << n }
    end

    def sleep_for(seconds) = engage.send(:routine_sleep, world, seconds)

    it 'runs to the end when nothing interrupts' do
      clock = Time.now
      allow(engage).to receive(:sleep) { |n| slept << n; clock += n }
      allow(Time).to receive(:now) { clock }
      sleep_for(3)
      expect(slept.sum).to be_within(0.5).of(3)
    end

    it 'breaks when the target dies' do
      room.targets.first.status = 'dead'
      sleep_for(30)
      expect(slept.sum).to be < 1.0
    end

    it 'breaks when the target leaves the room' do
      room.targets = []
      sleep_for(30)
      expect(slept.sum).to be < 1.0
    end

    it 'breaks when we are muckled' do
      me[:muckled?] = true
      sleep_for(30)
      expect(slept.sum).to be < 1.0
    end

    it 'breaks when the engine is stopping' do
      allow(EO::Engine::Actions::Base).to receive(:respond_to?).with(:interrupt).and_return(true)
      allow(EO::Engine::Actions::Base).to receive(:interrupt).and_return(-> { true })
      sleep_for(30)
      expect(slept.sum).to be < 1.0
    end

    it 'caps a runaway N' do
      clock = Time.now
      allow(engage).to receive(:sleep) { |n| slept << n; clock += n }
      allow(Time).to receive(:now) { clock }
      sleep_for(9999)
      expect(slept.sum).to be <= EO::Engine::Behaviors::Engage::MAX_ROUTINE_SLEEP
    end

    # The dispatch seam itself: a `sleep N` line must go through
    # routine_sleep, not Kernel#sleep, or none of the breaks above apply.
    it 'is what the routine line dispatches to' do
      seen = nil
      allow(engage).to receive(:routine_sleep) { |_w, n| seen = n }
      line = EO::Engine::Engage::Routine.parse(['sleep 30']).first
      expect(engage.send(:dispatch, world, 'sleep 30', line).reason).to eq(:slept)
      expect(seen).to eq(30)
    end
  end

  it 'marks a room combat-blocked when the game reports sanctuary' do
    policy.routines['a'] = ['702']
    spells[702] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 2, name: 'Mana Disruption')
    blocked = EO::Engine::Actions::Result.new(status: :failed, reason: :blocked,
                                              line: 'Be at peace my child, there is no need for spells of war in here.')
    allow(EO::Engine::Actions::Cast).to receive(:new).and_return(instance_double(EO::Engine::Actions::Cast, call: blocked))

    expect(engage.tick(world).reason).to eq(:blocked)
    expect(engage.state.combat_blocked_room).to eq(1)
    expect(engage.wants_control?(world)).to be(false)

    room.id = 2
    EO::Engine::Events.emit(:entered_room, room: 2)
    expect(engage.state.combat_blocked_room).to be_nil
  end

  it 'targets the creature, then runs its routine one line per tick with the hunting stance' do
    engage.tick(world)
    expect(calls.map(&:first)).to eq([:target, :attack])
    expect(calls[0].last[:target]).to eq('1')
    expect(calls[1].last[:command]).to eq('attack')
    expect(stances).to eq(['defensive'])
    spells[1030] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 10, name: 'x')
    me.current_target_id = '1'
    engage.tick(world)
    expect(calls.last).to eq([:cast, { spell: 1030, extra: nil, incant: false, target: '1' }])
    # the once line is registered, so the third tick wraps to attack and the fourth skips it
    engage.tick(world)
    skipped = engage.tick(world)
    expect(skipped.reason).to eq(:condition)
    expect(skipped.status).to eq(:skipped)
    expect(skipped.failed?).to be(false)
  end

  it 'repeats untildead one action per tick and restarts the opener for a new target' do
    policy.routines['a'] = ['jab', 'attack (untildead)']
    4.times { engage.tick(world) }
    expect(calls.select { |tag, _| tag == :attack }.map { |_, args| args[:command] }).to eq(%w[jab attack attack attack])
    room.targets = [npc(3)]
    engage.tick(world)
    expect(calls.last).to eq([:attack, { command: 'jab', target: '3' }])
    room.targets = []
    count = calls.size
    expect(engage.tick(world).reason).to eq(:no_target)
    expect(calls.size).to eq(count)
  end

  it 'checks conditions on every untildead tick and advances on a failed condition' do
    policy.routines['a'] = ['attack (m40 untildead)', 'jab']
    engage.tick(world)
    me.mana = 39
    expect(engage.tick(world).reason).to eq(:condition)
    engage.tick(world)
    expect(calls.select { |tag, _| tag == :attack }.map { |_, args| args[:command] }).to eq(%w[attack jab])
  end

  it 'does not retain an untildead cursor after an action failure or interruption' do
    policy.routines['a'] = ['attack (untildead)', 'jab']
    refused = EO::Engine::Actions::Result.new(status: :failed, reason: :interrupted)
    allow(EO::Engine::Actions::Attack).to receive(:new).and_return(instance_double(EO::Engine::Actions::Attack, call: refused))
    expect(engage.tick(world)).to equal(refused)
    expect(EO::Engine::Actions::Attack).to receive(:new).with(world, target: room.targets.first, command: 'jab')
    engage.tick(world)
  end

  it 'lets priority targeting replace an untildead target' do
    policy.priority = true
    policy.routines = { 'a' => ['jab', 'attack (untildead)'] }
    room.targets = [npc(3, 'orc')]
    2.times { engage.tick(world) }
    room.targets.unshift(npc(4))
    engage.tick(world)
    expect(calls.last).to eq([:attack, { command: 'jab', target: '4' }])
  end

  it 'yields repeat-on-target to the engine arbiter, holds and stop requests' do
    policy.routines['a'] = ['attack (untildead)']
    urgent = EO::Engine::Behavior.new
    needed = false
    allow(urgent).to receive(:priority).and_return(0)
    allow(urgent).to receive(:wants_control?) { needed }
    allow(urgent).to receive(:tick).and_return(EO::Engine::Actions::Result.new(status: :success))
    engine = EO::Engine::Engine.new(world: world, behaviors: [urgent, engage], interval: 0)
    engine.tick
    expect(calls.count { |tag, _| tag == :attack }).to eq(1)
    needed = true
    engine.tick
    expect(urgent).to have_received(:tick).once
    expect(calls.count { |tag, _| tag == :attack }).to eq(1)
    needed = false
    engine.pause!
    engine.tick
    expect(calls.count { |tag, _| tag == :attack }).to eq(1)
    engine.resume!
    engine.tick
    expect(calls.count { |tag, _| tag == :attack }).to eq(2)
    engine.stop!(:manual_stop)
    engine.tick
    expect(calls.count { |tag, _| tag == :attack }).to eq(2)
    expect(engine.stop_reason).to eq(:manual_stop)
  end

  # bigshot spell_is_selfcast? 5785: only 506/902/411 were handled, so a
  # cleric's "303" went out as `cast #1` at the kobold - mana spent, the
  # creature buffed, our own ward never refreshed.
  it 'casts a self spell at our own name, and an attack spell at the creature' do
    policy.routines['a'] = ['303', '702']
    spells[303] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 5, name: 'Prayer of Protection')
    spells[702] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 2, name: 'Mana Disruption')

    engage.tick(world)
    expect(calls.last).to eq([:cast, { spell: 303, extra: nil, incant: false, target: 'Testchar' }])

    engage.tick(world)
    expect(calls.last).to eq([:cast, { spell: 702, extra: nil, incant: false, target: '1' }])
  end

  it 'casts a support spell on a named group member in the room' do
    policy.routines['a'] = ['allycast 117 Skooshii']
    spells[117] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 15, name: 'Spirit Strike')
    room.players = [OpenStruct.new(noun: 'Skooshii', name: 'Skooshii')]
    world.group_nouns = ['Skooshii']

    engage.tick(world)

    expect(calls.last).to eq([:cast, { spell: 117, target: 'Skooshii' }])
  end

  it 'rearms an afterattack ally cast only when that named ally attacks' do
    policy.routines['a'] = ['allycast 117 Skooshii (afterattack)']
    spells[117] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 15, name: 'Spirit Strike')
    room.players = [OpenStruct.new(noun: 'Skooshii', name: 'Skooshii')]
    world.group_nouns = ['Skooshii']
    me.current_target_id = '1'

    expect(engage.tick(world).status).to eq(:success)
    expect(engage.tick(world).reason).to eq(:awaiting_ally_attack)
    expect(calls.count { |tag, _| tag == :cast }).to eq(1)

    EO::Engine::Events.emit(:ally_attacked, name: 'SomeoneElse')
    expect(engage.tick(world).reason).to eq(:awaiting_ally_attack)

    EO::Engine::Events.emit(:ally_attacked, name: 'skooshii')
    expect(engage.tick(world).status).to eq(:success)
    expect(calls.count { |tag, _| tag == :cast }).to eq(2)
  end

  it 'skips an ally cast when that group member is not in the room' do
    policy.routines['a'] = ['allycast 117 Skooshii']
    spells[117] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 15, name: 'Spirit Strike')
    world.group_nouns = ['Skooshii']

    result = engage.tick(world)

    expect(result.status).to eq(:skipped)
    expect(result.reason).to eq(:ally_missing)
    expect(calls.none? { |tag, _| tag == :cast }).to be(true)
  end

  it 'casts kweed as an evoked 610 unless a weed is already down' do
    policy.routines['a'] = ['kweed(buff5)']
    spells[610] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 10, name: 'Tangleweed')
    engage.tick(world)
    expect(calls.last).to eq([:cast, { spell: 610, extra: 'evoke', target: '1' }])
    room.loot = [OpenStruct.new(name: 'a thorny vine', noun: 'vine')]
    me.current_target_id = '1'
    expect(engage.tick(world).reason).to eq(:weed_present)
  end

  it 'picks the routine letter by the targets list' do
    room.targets = [npc(2, 'orc')]
    engage.tick(world)
    expect(calls.last).to eq([:maneuver, { category: :cman, name: 'Bull Rush', skip_if_buff: false, target: '2' }])
  end

  # Ojandhaart, 2026-09-10: routine b cycled "stance offensive" (already
  # offensive) and "incant 608" (already hidden) around each FIRE, and
  # the fire budget counted every one of them. The stance no-op and the
  # gate refusal are the routine declining its own line; only the FIRE
  # went to the game, and only it carries the stamp the budget counts.
  it 'hands the engine only the sent command as acted, not the stance no-op or a spell gate refusal' do
    policy.routines['a'] = ['stance offensive', 'incant 608', 'fire']
    spells[608] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 8, name: 'Camouflage')
    me[:hidden?] = true
    me.current_target_id = '1'
    fired = EO::Engine::Actions::Result.new(status: :success, acted: true)
    allow(EO::Engine::Actions::Ranged).to receive(:new).and_return(instance_double(EO::Engine::Actions::Ranged, call: fired))

    stance = engage.tick(world)
    expect(stance.status).to eq(:success)
    expect(stance.acted?).to be(false)
    refused = engage.tick(world)
    expect(refused.reason).to eq(:hidden)
    expect(refused.acted?).to be(false)
    expect(engage.tick(world).acted?).to be(true)
    expect(calls).to eq([]) # neither the stance line nor the refused spell built an action
  end

  it 'preserves the configured spirit minimum when an attack spell needs mana' do
    configured = EO::Engine::Profile.new({ 'hunting_commands' => '702', 'use_wracking' => true, 'wracking_spirit' => 9 })
    hunter = described_class.new(policy: configured.engage_policy, targets_policy: tp, stance: ->(_s) { true })
    spells[702] = OpenStruct.new(known?: true, affordable?: false, active?: false, mana_cost: 2, name: 'Mana Disruption')
    expect(EO::Engine::Actions::Wrack).to receive(:new).with(world, policy: have_attributes(wracking_spirit: 9))
                                                       .and_return(instance_double(EO::Engine::Actions::Wrack, call: EO::Engine::Actions::Result.new(status: :failed, reason: :no_wrack)))
    expect(hunter.tick(world).reason).to eq(:out_of_mana)
  end

  it 'learns an untargetable name from the probe and moves on' do
    refused = EO::Engine::Actions::Result.new(status: :failed, reason: :untargetable)
    allow(EO::Engine::Actions::Target).to receive(:new).and_return(instance_double(EO::Engine::Actions::Target, call: refused))
    learned = []
    EO::Engine::Events.on(:untargetable_learned) { |e| learned << e.data[:name] }
    expect(engage.tick(world).reason).to eq(:untargetable)
    expect(learned).to eq(['kobold'])
    expect(tp.untargetable_set).to eq(['kobold'])
    expect(engage.wants_control?(world)).to be true
    expect(engage.send(:next_target, world).id).to eq('2')
  end

  it 'does not blacklist a species when an ally kills the target during the target probe' do
    refused = EO::Engine::Actions::Result.new(status: :failed, reason: :untargetable, line: "You can't target a kobold.")
    probe = instance_double(EO::Engine::Actions::Target)
    allow(EO::Engine::Actions::Target).to receive(:new).and_return(probe)
    allow(probe).to receive(:call) do
      room.targets.first.status = 'dead'
      refused
    end
    learned = []
    EO::Engine::Events.on(:untargetable_learned) { |e| learned << e.data[:name] }

    result = engage.tick(world)

    expect(result.status).to eq(:skipped)
    expect(result.reason).to eq(:target_gone)
    expect(learned).to be_empty
    expect(tp.untargetable_set).to be_empty
  end

  it 'switches to a better-ranked creature only with priority on' do
    room.targets = [npc(2, 'orc'), npc(1)]
    tp = EO::Engine::Targets::Policy.new(wanted: { 'kobold' => 'a', 'orc' => 'b' })
    plain = described_class.new(policy: policy, targets_policy: tp, stance: ->(_s) { true })
    plain.tick(world)
    expect(plain.target.id).to eq('1')
    room.targets.unshift(npc(3, 'kobold'))
    plain.tick(world)
    expect(plain.target.id).to eq('1')
    policy.priority = true
    room.targets = [npc(2, 'orc')]
    pri = described_class.new(policy: policy, targets_policy: tp, stance: ->(_s) { true })
    pri.tick(world)
    expect(pri.target.id).to eq('2')
    room.targets << npc(4, 'kobold')
    pri.tick(world)
    expect(pri.target.id).to eq('4')
  end

  it 'assesses a pending boon creature as the tick\'s action before fighting, then fights by what it learned' do
    boon = EngageNpc.new(id: '7', name: 'slimy kobold', noun: 'kobold', status: '', type: 'aggressive npc,boon')
    assessed = []
    cache = EO::Engine::Targets::BoonCache.new(nil, assess: ->(c) { assessed << c.id; EO::Engine::Actions::Result.new(status: :success, line: 'It appears to be slimy.') })
    tp.boons_ignore = ['regen']
    tp.boon_abilities = cache
    room.targets = [boon]
    expect(engage.wants_control?(world)).to be true # unknown is not excluded, and nothing was sent
    expect(assessed).to be_empty
    expect(engage.tick(world)).to be_success
    expect(assessed).to eq(['7'])
    expect(calls).to be_empty
    expect(engage.wants_control?(world)).to be false # a regen boon on the ignore list
  end

  it 'waves the wand in the spell\'s place when out of mana with wand_if_oom' do
    policy.routines['a'] = ['1030']
    policy.wand_if_oom = true
    spells[1030] = OpenStruct.new(known?: true, affordable?: false, active?: false, mana_cost: 10, name: 'x')
    waved = EO::Engine::Actions::Result.new(status: :success, reason: :waved)
    wand = instance_double(EO::Engine::Actions::Wand, call: waved)
    expect(EO::Engine::Actions::Wand).to receive(:new).with(world, target: room.targets.first, policy: policy, state: engage.state, stance: engage.stance).and_return(wand)
    expect(engage.tick(world)).to equal(waved)
    expect(calls.map(&:first)).not_to include(:cast)
  end

  it 'gates a spell the way cmd_spell does and reports out of mana' do
    policy.routines['a'] = ['1030']
    spells[1030] = OpenStruct.new(known?: true, affordable?: false, active?: false, mana_cost: 10, name: 'x')
    oom = []
    EO::Engine::Events.on(:out_of_mana) { |e| oom << e.data[:spell] }
    expect(engage.tick(world).reason).to eq(:out_of_mana)
    expect(oom).to eq([1030])
    policy.oom = -1
    engage.tick(world)
    expect(oom.size).to eq(1)
  end

  it 'routes a routines.rb word, a warcry ALL, and falls through to a bare command' do
    policy.routines['a'] = ['wield sword', 'growl all', 'search']
    world[:hands] = OpenStruct.new(right: OpenStruct.new(id: '1', noun: 'katana'), left: OpenStruct.new(id: nil, noun: ''))
    wielded = []
    allow_any_instance_of(EO::Engine::Actions::Wield).to receive(:wield) { |_a, noun, hand:| wielded << [noun, hand]; OpenStruct.new(name: 'a sword') }
    expect(engage.tick(world).reason).to eq(:wielded)
    expect(wielded).to eq([['sword', nil]])
    engage.tick(world)
    expect(calls.last).to eq([:maneuver, { category: :warcry, name: 'growl', skip_if_buff: false, target: 'all' }])
    engage.tick(world)
    expect(calls.last).to eq([:command, { command: 'search' }])
  end

  # "506 attack" also matches the SPELL regex, which reads the number and
  # drops everything after it: the buff went up, the attack never ran, and
  # every later pass failed the line with :active because 506 was now
  # active. bigshot cmd 3359-3387 casts the prefix and then runs the
  # command.
  it 'runs the command after a prefix spell, not the spell alone' do
    policy.routines['a'] = ['506 attack']
    spells[506] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 5, name: 'Celerity')
    engage.tick(world)
    expect(calls.map(&:first)).to include(:attack)
  end

  # ...but the numeric prefixes are spell numbers too, so "506 evoke" reads
  # both ways. The cast mode is what the writer meant: a prefix exists to
  # buff and then do something else, and a bare mode is not something else.
  # Reading it as a prefix cast 506 normally and then sent "evoke" as a
  # bare command, which is a different operation entirely.
  it 'leaves an explicit cast mode to the spell branch' do
    spells[506] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 5, name: 'Celerity')
    casts = []
    allow(engage).to receive(:spell) { |_w, _incant, num, extra| casts << [num, extra]; EO::Engine::Actions::Result.new(status: :success) }
    %w[evoke cast channel].each do |mode|
      casts.clear
      line = EO::Engine::Engage::Routine.parse(["506 #{mode}"]).first
      engage.send(:dispatch, world, line.text, line)
      expect(casts).to eq([[506, mode]]), "506 #{mode} did not reach the spell branch"
    end
  end

  it 'still treats a real command after the prefix as a prefix' do
    spells[506] = OpenStruct.new(known?: true, affordable?: true, active?: false, mana_cost: 5, name: 'Celerity')
    casts = []
    allow(engage).to receive(:spell) { |_w, _incant, num, extra| casts << [num, extra]; EO::Engine::Actions::Result.new(status: :success) }
    line = EO::Engine::Engage::Routine.parse(['506 attack']).first
    engage.send(:dispatch, world, line.text, line)
    expect(casts.first&.first).to eq(506)
    expect(calls.map(&:first)).to include(:attack)
  end

  it 'forgets the room registry and the target on a new room' do
    engage.tick(world)
    engage.state.register('1', 'x')
    EO::Engine::Events.emit(:entered_room, room: 2)
    expect(engage.state.registry).to be_empty
    expect(engage.target).to be_nil
  end
end
