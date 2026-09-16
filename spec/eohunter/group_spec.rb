# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

module GroupSpecHelpers
  def player(noun, status: '') = OpenStruct.new(noun: noun, name: noun, status: status)

  def npc(id, name: 'kobold', status: '', type: 'aggressive npc') = OpenStruct.new(id: id.to_s, name: name, noun: name, status: status, type: type)

  def report(name, **fields)
    EO::Engine::Group::Report.new(**{ name: name, room: 1, rt: false, hidden: false, sneaky: false, looting: false, rest_prep_done: true,
                                      rest_reason: nil, not_hunting_reason: nil, encumbrance_left: 50, wounded: false, at: Time.now }.merge(fields))
  end

  # A leader with two registered, reporting followers.
  def hub_with(*names, clock: Time)
    hub = EO::Engine::Group::Hub.new(clock: clock)
    hub.open_hunt(leader: 'Lead', expected: names, rooms: { rally: [3], hunting: 200, waypoints: [1, 2], resting: 100 })
    names.each do |n|
      hub.register(n, hunt_id: hub.hunt_id)
      hub.report(n, report(n))
    end
    hub.activate!
    hub
  end
end

RSpec.describe EO::Engine::Group::Hub do
  include GroupSpecHelpers

  let(:clock) { OpenStruct.new(now: Time.at(1000)) }
  let(:hub) { described_class.new(clock: clock) }

  it 'opens a hunt with a fresh id and a roster, and is ready when everyone expected has registered' do
    id = hub.open_hunt(leader: 'Lead', expected: %w[Bob Ann])
    expect(hub.ready?).to be false
    expect(hub.missing).to eq(%w[Bob Ann])
    hub.register('Bob', hunt_id: id)
    expect(hub.missing).to eq(['Ann'])
    hub.register('Ann', hunt_id: id)
    expect(hub.ready?).to be true
    expect(hub.members).to eq(%w[Bob Ann])
  end

  it 'counts registrations when the roster is a number, and refuses the wrong hunt or an unexpected name' do
    id = hub.open_hunt(leader: 'Lead', expected: 1)
    expect { hub.register('Bob', hunt_id: 'nope') }.to raise_error(ArgumentError, /not open/)
    hub.register('Bob', hunt_id: id)
    expect(hub.ready?).to be true
    hub.open_hunt(leader: 'Lead', expected: ['Ann'])
    expect { hub.register('Bob', hunt_id: hub.hunt_id) }.to raise_error(ArgumentError, /not expected/)
  end

  it 'queues orders per follower and hands them over once' do
    id = hub.open_hunt(leader: 'Lead', expected: %w[Bob Ann])
    hub.register('Bob', hunt_id: id)
    hub.register('Ann', hunt_id: id)
    hub.broadcast(:attack, room: 7)
    hub.order('Ann', :loot, 'Ann', room: 7)
    expect(hub.pending?('Ann', :loot)).to be true
    bob = hub.take_orders('Bob')
    expect(bob.map(&:type)).to eq([:attack])
    expect(bob.first.hunt_id).to eq(id)
    expect(bob.first.room).to eq(7)
    expect(hub.take_orders('Bob')).to eq([])
    expect(hub.take_orders('Ann').map { |o| [o.type, o.payload] }).to eq([[:attack, nil], [:loot, 'Ann']])
    expect { hub.broadcast(:dance) }.to raise_error(ArgumentError)
  end

  it 'knows who is answering by the age of their report, and whether the leader is' do
    id = hub.open_hunt(leader: 'Lead', expected: %w[Bob Ann])
    hub.register('Bob', hunt_id: id)
    hub.register('Ann', hunt_id: id)
    hub.report('Bob', report('Bob', at: nil))
    expect(hub.liveness).to eq('Bob' => :online, 'Ann' => :online)
    expect(hub.leader_alive?).to be true
    clock.now = Time.at(1012)
    expect(hub.liveness).to eq('Bob' => :offline, 'Ann' => :offline)
    hub.heartbeat!(room: 5)
    expect(hub.leader_state).to eq(room: 5)
    clock.now = Time.at(1030)
    expect(hub.leader_alive?).to be false
    hub.heartbeat!
    expect(hub.leader_alive?).to be true
    hub.leader_finished!(:done)
    expect(hub.leader_alive?).to be false
    expect(hub.finished_reason).to eq(:done)
  end

  it 'treats a newly registered follower as online during its first-report grace period' do
    id = hub.open_hunt(leader: 'Lead', expected: ['Bob'])
    hub.register('Bob', hunt_id: id)
    hub.activate!
    expect(hub.liveness).to eq('Bob' => :online)

    clock.now = Time.at(1011)
    expect(hub.liveness).to eq('Bob' => :offline)
  end

  it 'records acks for the open hunt only' do
    id = hub.open_hunt(leader: 'Lead', expected: ['Bob'])
    hub.register('Bob', hunt_id: id)
    hub.ack(:hunt_over, 'Bob', hunt_id: id)
    expect(hub.acked(:hunt_over)).to eq(['Bob'])
    expect { hub.ack(:hunt_over, 'Bob', hunt_id: 'old') }.to raise_error(ArgumentError)
  end
end

RSpec.describe EO::Engine::Group::Order do
  it 'is stale from another room or after fifteen seconds' do
    order = described_class.new(type: :attack, hunt_id: 'x', room: 1, at: Time.at(1000))
    expect(order.stale?(1, Time.at(1010))).to be false
    expect(order.stale?(2, Time.at(1010))).to be true
    expect(order.stale?(1, Time.at(1016))).to be true
  end
end

RSpec.describe EO::Engine::Group::Leader do
  include GroupSpecHelpers

  let(:hub) { hub_with('Bob', 'Ann') }
  let(:policy) { EO::Engine::Group::Policy.new }
  let(:leader) { described_class.new(hub, name: 'Lead', policy: policy) }
  let(:world) { OpenStruct.new(room: OpenStruct.new(id: 1, players: [player('Bob'), player('Ann')]), group_nouns: %w[Bob Ann]) }

  it 'is solo with nobody registered' do
    empty = EO::Engine::Group::Hub.new
    empty.open_hunt(leader: 'Lead', expected: 2)
    expect(described_class.new(empty, name: 'Lead').solo?).to be true
    expect(leader.solo?).to be false
    expect(leader.size).to eq(3)
  end

  it 'has everyone present only when each follower is here and in the game group' do
    expect(leader.all_present?(world)).to be true
    world.room.players = [player('Bob')]
    expect(leader.all_present?(world)).to be false
    world.room.players = [player('Bob'), player('Ann')]
    world[:group_nouns] = ['Bob']
    expect(leader.all_present?(world)).to be false
  end

  it 'answers the group questions from the reports' do
    expect(leader.looting_done?).to be true
    expect(leader.roundtime?).to be false
    expect(leader.rest_prep_complete?).to be true
    expect(leader.need_sneaky?).to be false
    hub.report('Bob', report('Bob', looting: true, rt: true, rest_prep_done: false, sneaky: true, rest_reason: 'fried.', not_hunting_reason: 'mind still above threshold.', wounded: true))
    expect(leader.looting_done?).to be false
    expect(leader.roundtime?).to be true
    expect(leader.rest_prep_complete?).to be false
    expect(leader.need_sneaky?).to be true
    expect(leader.any_wounded?).to be true
    expect(leader.rest_reasons).to eq('Bob' => 'fried.')
    expect(leader.not_hunting_reasons).to eq('Bob' => 'mind still above threshold.')
  end

  it 'stops waiting on a follower that has gone quiet, and reports it once' do
    clock = OpenStruct.new(now: Time.now)
    quiet_hub = hub_with('Bob', 'Ann', clock: clock)
    lead = described_class.new(quiet_hub, name: 'Lead', policy: policy, clock: clock)
    quiet_hub.report('Bob', report('Bob', looting: true, rest_reason: 'fried.', at: clock.now))
    expect(lead.looting_done?).to be false
    clock.now += 20
    quiet_hub.report('Ann', report('Ann', at: clock.now))
    expect(lead.online).to eq(['Ann'])
    expect(lead.active_names).to eq(%w[Ann Lead])
    expect(lead.looting_done?).to be true
    expect(lead.rest_reasons).to be_empty
    expect(lead.newly_lost).to eq(['Bob'])
    expect(lead.newly_lost).to eq([])
    world.room.players = [player('Ann')]
    world[:group_nouns] = ['Ann']
    expect(lead.all_present?(world)).to be true
  end

  # The follower clears its own rest_prep_done only when it processes the
  # :resting_prep order, which is at least a tick away. The leader queues
  # that order and tests rest_prep_complete? in the same call, so on every
  # rest after the first it read last cycle's true and walked through a
  # barrier that had never been satisfied.
  it 'does not accept last cycle\'s rest prep for this one' do
    %w[Bob Ann].each { |n| hub.report(n, report(n, rest_prep_done: true)) }
    expect(leader.rest_prep_complete?).to be true # prepped, last rest

    hub.broadcast(:resting_prep, room: 1)
    expect(leader.rest_prep_complete?).to be false # ordered again, not yet done

    %w[Bob Ann].each { |n| hub.report(n, report(n, rest_prep_done: true)) }
    expect(leader.rest_prep_complete?).to be true # reported back
  end

  it 'leaves the flag alone for every other order' do
    %w[Bob Ann].each { |n| hub.report(n, report(n, rest_prep_done: true)) }
    hub.broadcast(:prep_rest, room: 1)
    hub.broadcast(:go2_waypoints, room: 1)
    expect(leader.rest_prep_complete?).to be true
  end

  describe 'the looter (ma_looter 7119)' do
    it 'is the leader unless never_loot says so, then a follower' do
      expect(leader.looter).to eq('Lead')
      policy.never_loot = ['Lead']
      expect(%w[Bob Ann]).to include(leader.looter)
    end

    it 'is the named looter when in the group' do
      policy.looter = 'ann'
      expect(leader.looter).to eq('Ann')
      policy.looter = 'Zed'
      expect(leader.looter).to eq('Lead')
    end
    # The match used to be an unanchored regex, so a configured looter of
    # "Bo" claimed every corpse from a member named "Bobby".
    it 'is not a member whose name merely contains the configured one' do
      policy.looter = 'Bo'
      expect(leader.looter).to eq('Lead')
      policy.looter = 'nn'
      expect(leader.looter).to eq('Lead')
    end

    it 'is the least encumbered with random_loot, the named one on a tie' do
      policy.random_loot = true
      hub.report('Bob', report('Bob', encumbrance_left: 80))
      expect(leader.looter(me_left: 10)).to eq('Bob')
      hub.report('Ann', report('Ann', encumbrance_left: 80))
      policy.looter = 'Ann'
      expect(leader.looter(me_left: 10)).to eq('Ann')
      policy.looter = nil
      policy.never_loot = %w[Bob Ann]
      expect(leader.looter(me_left: 10)).to eq('Lead')
    end
  end

  it 'publishes the leader state and orders every follower' do
    leader.publish(world, phase: :hunting, target: npc(9))
    expect(hub.leader_state[:room]).to eq(1)
    expect(hub.leader_state[:target]).to eq(id: '9', name: 'kobold', noun: 'kobold')
    leader.order(:attack, room: 1)
    expect(hub.take_orders('Bob').map(&:type)).to eq([:attack])
    expect(hub.take_orders('Ann').map(&:type)).to eq([:attack])
  end

  it 'repeats the last heartbeat between ticks, so a blocking action never reads as a dead leader' do
    live = EO::Engine::Group::Hub.new
    live.open_hunt(leader: 'Lead', expected: ['Bob'])
    lead = described_class.new(live, name: 'Lead')
    live.instance_variable_set(:@heartbeat, Time.now - 60)
    lead.keep_alive!(interval: 0.02)
    sleep 0.06
    expect(live.leader_alive?).to be false # nothing published yet, nothing to repeat
    lead.publish(world, phase: :hunting)
    live.instance_variable_set(:@heartbeat, Time.now - 60)
    sleep 0.06
    lead.stop_pulse!
    expect(live.leader_alive?).to be true
    expect(live.leader_state[:phase]).to eq(:hunting)
  end

  it 'ends the hunt with a hunt_over to everyone and a finished leader' do
    leader.finish!(:script_killed)
    expect(hub.take_orders('Bob').map { |o| [o.type, o.payload] }).to eq([[:hunt_over, :script_killed]])
    expect(hub.leader_alive?).to be false
    expect(hub.last_exit[:reason]).to eq(:script_killed)
  end

  describe 'the bounty verdict (the split plan 3.2)' do
    it 'is hunting until every member is complete, failed or off the bounty, and terminal states stick' do
      hub.report('Bob', report('Bob', bounty: :hunting))
      hub.report('Ann', report('Ann', bounty: :none))
      expect(leader.verdict(:complete)).to eq(:hunting)
      hub.report('Bob', report('Bob', bounty: :complete))
      expect(leader.verdict(:hunting)).to eq(:hunting) # the leader's own count
      expect(leader.verdict(:complete)).to eq(:bounty_complete)
      hub.report('Bob', report('Bob', bounty: :hunting)) # a stale line after completion
      expect(leader.verdict(:complete)).to eq(:bounty_complete)
      hub.report('Ann', report('Ann', bounty: :failed))
      expect(leader.verdict(:complete)).to eq(:bounty_complete)
    end

    it 'puts a lost member before everything' do
      clock = OpenStruct.new(now: Time.now)
      quiet_hub = hub_with('Bob', clock: clock)
      lead = described_class.new(quiet_hub, name: 'Lead', clock: clock)
      quiet_hub.report('Bob', report('Bob', bounty: :complete, at: clock.now))
      expect(lead.verdict(:complete)).to eq(:bounty_complete)
      clock.now += 20
      expect(lead.verdict(:complete)).to eq(:member_lost)
    end

    it 'decides the child\'s rest from the verdict alone: the leader done with a follower unfinished keeps hunting' do
      hub.report('Bob', report('Bob', bounty: :hunting))
      hub.report('Ann', report('Ann', bounty: :none))
      expect(leader.bounty_decision(true)).to eq(:hunt)
      expect(leader.bounty_decision(false)).to eq(:hunt)
      hub.report('Bob', report('Bob', bounty: :complete))
      expect(leader.bounty_decision(false)).to eq(:hunt)
      expect(leader.bounty_decision(true)).to eq(:rest)
      clock = OpenStruct.new(now: Time.now)
      quiet_hub = hub_with('Bob', clock: clock)
      lead = described_class.new(quiet_hub, name: 'Lead', clock: clock)
      clock.now += 20
      expect(lead.bounty_decision(false)).to eq(:member_lost)
    end
  end

  describe 'the acknowledged shutdown (the split plan 3.3)' do
    it 'waits for every ack, then records a clean exit' do
      clock = OpenStruct.new(now: Time.at(1000))
      h = hub_with('Bob', clock: clock)
      lead = described_class.new(h, name: 'Lead', clock: clock)
      allow(lead).to receive(:sleep) { h.ack(:hunt_over, 'Bob', hunt_id: h.hunt_id) }
      record = lead.end_hunt(:bounty_complete)
      expect(record[:clean]).to be true
      expect(record[:unacked]).to eq([])
      expect(h.take_orders('Bob').map(&:type)).to eq([:hunt_over])
      expect(h.leader_alive?).to be false
    end

    # The script's before_dying calls finish! on every exit, including a
    # normal one where end_hunt already ran. finish! used to broadcast a
    # second hunt_over and replace last_exit with a smaller record, losing
    # the unacked list the report exists for.
    it 'keeps end_hunt\'s report when the teardown hook finishes too' do
      clock = OpenStruct.new(now: Time.at(1000))
      h = hub_with('Bob', clock: clock)
      lead = described_class.new(h, name: 'Lead', clock: clock)
      allow(lead).to receive(:sleep) { clock.now += 5 }
      lead.end_hunt(:bounty_complete, deadline: 0)
      expect(h.last_exit[:unacked]).to eq(['Bob'])

      lead.finish!(:bounty_complete)
      expect(h.last_exit[:unacked]).to eq(['Bob'])
      expect(h.last_exit[:clean]).to be false
      # and no second hunt_over on the wire
      expect(h.take_orders('Bob').map(&:type)).to eq([:hunt_over])
    end

    it 'still finishes a hunt end_hunt never closed' do
      clock = OpenStruct.new(now: Time.at(1000))
      h = hub_with('Bob', clock: clock)
      lead = described_class.new(h, name: 'Lead', clock: clock)
      lead.finish!(:script_killed)
      expect(h.last_exit[:reason]).to eq(:script_killed)
      expect(h.leader_alive?).to be false
    end

    it 'gives up at the deadline and names who never answered' do
      clock = OpenStruct.new(now: Time.at(1000))
      h = hub_with('Bob', 'Ann', clock: clock)
      lead = described_class.new(h, name: 'Lead', clock: clock)
      h.ack(:hunt_over, 'Ann', hunt_id: h.hunt_id)
      allow(lead).to receive(:sleep) { clock.now += 5 }
      record = lead.end_hunt(:member_lost, deadline: 15)
      expect(record[:clean]).to be false
      expect(record[:unacked]).to eq(['Bob'])
      expect(h.last_exit[:reason]).to eq(:member_lost)
    end
  end
end

RSpec.describe EO::Engine::Group, '.bounty_state' do
  def world_with(type)
    task = OpenStruct.new(type: type, none?: type == :none, done?: %i[taskmaster guard failed heirloom_found].include?(type))
    OpenStruct.new(bounty_task: task)
  end

  it 'reads the member state off the Lich task' do
    expect(described_class.bounty_state(OpenStruct.new(bounty_task: nil))).to eq(:none)
    expect(described_class.bounty_state(world_with(:none))).to eq(:none)
    expect(described_class.bounty_state(world_with(:cull))).to eq(:hunting)
    expect(described_class.bounty_state(world_with(:taskmaster))).to eq(:complete)
    expect(described_class.bounty_state(world_with(:guard))).to eq(:complete)
    expect(described_class.bounty_state(world_with(:failed))).to eq(:failed)
  end
end

RSpec.describe EO::Engine::Group::Member do
  include GroupSpecHelpers

  let(:hub) do
    h = EO::Engine::Group::Hub.new
    h.open_hunt(leader: 'Lead', expected: ['Bob'], rooms: { hunting: 200 })
    h
  end
  let(:member) { described_class.new(hub, name: 'Bob', deadline: 0.2) }

  it 'registers for the open hunt and reports, and reads the leader' do
    expect(member.register).to be true
    expect(member.hunt_id).to eq(hub.hunt_id)
    expect(member.report(report('Bob'))).to be true
    expect(hub.reports.keys).to eq(['Bob'])
    hub.heartbeat!(name: 'Lead', room: 5, phase: :hunting, target: { id: '9' })
    expect(member.leader_state[:room]).to eq(5)
    expect(member.leader_room).to eq(5)
    expect(member.leader_name).to eq('Lead')
    expect(member.leader_target).to eq(id: '9')
    expect(member.rooms).to eq(hunting: 200)
    expect(member.leader_alive?).to be true
  end

  it 'refreshes the cached leader snapshot while reporting' do
    member.register
    hub.heartbeat!(name: 'Lead', room: 9, phase: :hunting, target: { id: '7' })

    expect(member.report(report('Bob'))).to be true
    expect(member.leader_room).to eq(9)
    expect(member.leader_target).to eq(id: '7')
  end

  it 'keeps the last report fresh between ticks, so a blocking action never reads as lost' do
    member.register
    member.report(report('Bob', at: Time.now - 30))
    expect(hub.liveness).to eq('Bob' => :offline)
    hub.heartbeat!(name: 'Lead', room: 4, phase: :resting)
    member.keep_alive!(interval: 0.02)
    sleep 0.1
    member.stop_pulse!
    expect(hub.liveness).to eq('Bob' => :online)
    expect(hub.reports['Bob'].room).to eq(1)
    expect(member.leader_phase).to eq(:resting)
  end

  it 'reads the leader signs flag, held for the refuge and both walks' do
    member.register
    hub.heartbeat!(name: 'Lead', room: 4, phase: :resting, signs: false)
    member.leader_state
    expect(member.leader_signs_wanted?).to be false

    # the walk back out is still :resting, and signs stay held
    hub.heartbeat!(name: 'Lead', room: 6, phase: :resting, signs: false)
    member.leader_state
    expect(member.leader_phase).to eq(:resting)
    expect(member.leader_signs_wanted?).to be false

    hub.heartbeat!(name: 'Lead', room: 200, phase: :hunting, signs: true)
    member.leader_state
    expect(member.leader_signs_wanted?).to be true
  end

  it 'treats a leader that publishes no signs flag as wanting signs' do
    member.register
    hub.heartbeat!(name: 'Lead', room: 4, phase: :hunting)
    member.leader_state
    expect(member.leader_signs_wanted?).to be true
  end

  it 'cannot register before a hunt is open' do
    closed = described_class.new(EO::Engine::Group::Hub.new, name: 'Bob', deadline: 0.2)
    expect(closed.register).to be false
    expect(closed.lost?).to be false
  end

  it 'takes only this hunt\'s orders and drops a stale attack' do
    member.register
    hub.broadcast(:attack, room: 1)
    hub.broadcast(:follow_now, room: 1)
    stale = EO::Engine::Group::Order.new(type: :attack, hunt_id: 'old', room: 1, at: Time.now)
    hub.instance_variable_get(:@queues)['Bob'] << stale
    expect(member.orders(room: 2).map(&:type)).to eq([:follow_now])
  end

  it 'acks with the hunt id' do
    member.register
    member.ack(:hunt_over)
    expect(hub.acked(:hunt_over)).to eq(['Bob'])
  end

  it 'marks the leader lost when the hub raises or does not answer in time' do
    broken = Object.new
    def broken.hunt_id = raise('gone')
    lost = described_class.new(broken, name: 'Bob', deadline: 0.2)
    expect(lost.register).to be false
    expect(lost.lost?).to be true
    expect(lost.leader_alive?).to be false
    slow = Object.new
    def slow.hunt_id = sleep(2)
    stuck = described_class.new(slow, name: 'Bob', deadline: 0.05)
    expect(stuck.register).to be false
    expect(stuck.lost?).to be true
  end
end

RSpec.describe EO::Engine::Behaviors::Orders do
  include GroupSpecHelpers

  let(:hub) { hub_with('Bob') }
  let(:member) { EO::Engine::Group::Member.new(hub, name: 'Bob', deadline: 0.5) }
  let(:me) { OpenStruct.new(fxp_pct: 50, mana_pct: 80, spirit: 10, stamina_pct: 90, encumbrance_pct: 10, dead?: false, in_rt?: false, in_cast_rt?: false, hidden?: false) }
  let(:room) { OpenStruct.new(id: 1, uid: 11, players: [player('Lead')], targets: [], creatures: []) }
  let(:world) { OpenStruct.new(me: me, room: room, group_nouns: ['Lead'], group_leader_noun: 'Lead') }
  let(:policy) do
    EO::Engine::Rest::Policy.new(resting_room: 5, return_waypoints: [], hunting_room: 6, rally_rooms: [], fog_return: 1,
                                 resting_commands: ['sit'], resting_scripts: ['eherbs'], hunting_prep_commands: ['stand'], hunting_scripts: ['eloot'],
                                 wander_stance: 'defensive', rest_interval: 0)
  end
  let(:trips) { [] }
  let(:fogged) { [] }
  let(:stances) { [] }
  let(:scripts) do
    Class.new do
      attr_reader :started, :killed

      def initialize = (@started = []; @killed = []; @running = [])
      def start(name, args) = @started << [name, args]
      def running?(name) = @running.include?(name)
      def kill(name) = @killed << name
      def run!(name) = @running << name
      def stop!(name) = @running.delete(name)
    end.new
  end
  let(:assist) { instance_double(EO::Engine::Behaviors::Assist, attack!: nil, stand_down!: nil) }
  let(:follow) { instance_double(EO::Engine::Behaviors::Follow, rejoin!: nil, independent!: nil) }
  let(:loot) { instance_double(EO::Engine::Behaviors::Loot, assign!: nil) }
  let(:orders) do
    described_class.new(member: member, policy: policy, assist: assist, follow: follow, loot: loot,
                        travel: ->(r) { trips << r; true }, fog: ->(_p, _r) { fogged << true; true },
                        scripts: scripts, stance: ->(s) { stances << s; true })
  end

  before do
    member.register
    me.define_singleton_method(:debuff_level) { |_n| nil }
    me.define_singleton_method(:debuff_active?) { |_n| false }
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:send_through_ladder).and_return('ok')
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:sleep)
    allow_any_instance_of(EO::Engine::Actions::LeaveGroup).to receive(:send_and_match).and_return(EO::Engine::Actions::Result.new(status: :success))
  end

  def run(limit = 20)
    limit.times do
      break unless orders.wants_control?(world)

      orders.tick(world)
    end
  end

  it 'wants control only with an order pending or a step in progress' do
    expect(orders.wants_control?(world)).to be false
    hub.broadcast(:hunting_prep, room: 1)
    expect(orders.wants_control?(world)).to be true
  end

  it 'tells Assist to attack and to stand down, and Follow to rejoin' do
    hub.broadcast(:attack, room: 1)
    hub.broadcast(:follow_now, room: 1)
    hub.broadcast(:prep_rest, room: 1)
    expect(assist).to receive(:attack!).ordered
    expect(assist).to receive(:stand_down!).twice.ordered
    expect(follow).to receive(:rejoin!)
    run
    expect(stances).to eq(['defensive'])
  end

  it 'acknowledges movement preparation only after standing down and leaving roundtime' do
    hub.broadcast(:prepare_move, room: 1)
    me[:in_rt?] = true
    expect(assist).to receive(:stand_down!)
    expect(follow).to receive(:rejoin!)

    expect(orders.wants_control?(world)).to be true
    expect(orders.tick(world)).to be_nil
    expect(hub.acked(:prepare_move)).to be_empty
    expect(orders.wants_control?(world)).to be true
    expect(orders.tick(world)).to be_nil

    me[:in_rt?] = false
    expect(orders.tick(world).reason).to eq(:movement_ready)
    expect(hub.acked(:prepare_move)).to eq(['Bob'])
  end

  it 'runs its own prep lists and scripts, one line per tick, and marks the rest prep done after the scripts' do
    hub.broadcast(:hunting_prep, room: 1)
    hub.broadcast(:hunting_scripts_start, room: 1)
    hub.broadcast(:resting_prep, room: 1)
    hub.broadcast(:resting_scripts_start, room: 1)
    expect(orders.rest_prep_done).to be false
    run
    expect(scripts.started).to eq([['eloot', nil], ['eherbs', nil]])
    expect(orders.rest_prep_done).to be true
    scripts.run!('eloot')
    hub.broadcast(:hunting_scripts_stop, room: 1)
    run
    expect(scripts.killed).to eq(['eloot'])
    expect(stances).to eq(['defensive'])
    # the stop is not a rest: no fog of its own, the next order says where to go
    expect(orders.phase).to eq(:idle)
    expect(fogged).to be_empty
  end

  it 'runs follower resting scripts sequentially' do
    policy.resting_scripts = ['eherbs', 'eloot sell']
    hub.broadcast(:resting_scripts_start, room: 1)

    expect(orders.wants_control?(world)).to be true
    orders.tick(world) # accept the order
    orders.tick(world) # start eherbs
    scripts.run!('eherbs')
    orders.tick(world)
    expect(scripts.started).to eq([['eherbs', nil]])

    scripts.stop!('eherbs')
    orders.tick(world)
    expect(scripts.started).to eq([['eherbs', nil], ['eloot', 'sell']])
  end

  it 'walks the leader\'s rooms, not its own' do
    hub.broadcast(:go2_rally, room: 1)
    hub.broadcast(:go2_hunting_room, room: 1)
    hub.broadcast(:go2_waypoints, room: 1)
    hub.broadcast(:go2_resting_room, room: 1)
    run(40)
    expect(trips).to eq([3, 200, 1, 2, 100])
  end

  it 'fogs home on order and leaves the group for an independent return' do
    hub.broadcast(:leave_group, room: 1)
    hub.broadcast(:fog_return, room: 1)
    expect(follow).to receive(:independent!)
    run
    expect(fogged.size).to eq(1)
    expect(orders.phase).to eq(:idle)
  end

  it 'ignores a loot order naming someone else' do
    hub.broadcast(:loot, 'Ann', room: 1)
    expect(loot).not_to receive(:assign!)
    run
  end

  it 'assigns the loot when named' do
    hub.broadcast(:loot, 'Bob', room: 1)
    expect(loot).to receive(:assign!)
    run
  end

  it 'acks a hunt_over and reports it' do
    seen = []
    EO::Engine::Events.on(:hunt_over) { |e| seen << e.data[:reason] }
    hub.broadcast(:hunt_over, :bounty_complete, room: 1)
    run
    expect(seen).to eq([:bounty_complete])
    expect(hub.acked(:hunt_over)).to eq(['Bob'])
    EO::Engine::Events.reset!
  end

  it 'is resting when the leader says so' do
    expect(orders.resting?).to be false
    hub.heartbeat!(phase: :resting)
    member.leader_state
    expect(orders.resting?).to be true
  end

  it 'reports a forced rest to the leader with the real rest predicates, and clears it when the return cycle begins' do
    orders.rest!('No fresh wands!')
    expect(orders.forced_reason).to eq('No fresh wands!')
    report = EO::Engine::Group.report(world, name: 'Bob', rest_policy: policy, counters: EO::Engine::Rest::Counters.new,
                                                 forced: orders.forced_reason)
    expect(report.rest_reason).to eq('No fresh wands!')
    hub.report('Bob', report)
    expect(hub.reports['Bob'].rest_reason).to eq('No fresh wands!')

    hub.broadcast(:prep_rest, room: 1)
    run
    expect(orders.forced_reason).to be_nil
    expect(EO::Engine::Group.report(world, name: 'Bob', rest_policy: policy, counters: EO::Engine::Rest::Counters.new,
                                    forced: orders.forced_reason).rest_reason).to be_nil
  end
end

RSpec.describe EO::Engine::Behaviors::Assist do
  include GroupSpecHelpers

  let(:hub) { hub_with('Bob') }
  let(:member) { EO::Engine::Group::Member.new(hub, name: 'Bob', deadline: 0.5) }
  let(:room) { OpenStruct.new(id: 1, players: [player('Lead')], targets: [npc(1, name: 'kobold'), npc(2, name: 'orc')]) }
  let(:world) { OpenStruct.new(me: OpenStruct.new(current_target_id: nil), room: room) }
  let(:tp) { EO::Engine::Targets::Policy.new(wanted: { 'orc' => 'a', 'kobold' => 'b' }) }
  let(:assist) { described_class.new(member: member, policy: EO::Engine::Engage::Policy.new(routines: { 'a' => ['attack'] }), targets_policy: tp) }

  before do
    member.register
    hub.heartbeat!(name: 'Lead', room: 1, phase: :hunting, target: { id: '1' })
    member.leader_state
  end

  it 'fights only after an attack order, only with the leader here' do
    expect(assist.wants_control?(world)).to be false
    assist.attack!
    expect(assist.wants_control?(world)).to be true
    room.players = []
    expect(assist.wants_control?(world)).to be false
    room.players = [player('Lead')]
    assist.stand_down!
    expect(assist.wants_control?(world)).to be false
  end

  it 'takes the leader\'s live target and never starts an independent fight' do
    assist.attack!
    expect(assist.send(:next_target, world).id).to eq('1')
    room.targets[0].status = 'dead'
    expect(assist.send(:next_target, world)).to be_nil
    hub.heartbeat!(name: 'Lead', room: 1, phase: :hunting, target: nil)
    member.leader_state
    expect(assist.send(:next_target, world)).to be_nil
  end
end

RSpec.describe EO::Engine::Behaviors::Follow do
  include GroupSpecHelpers

  let(:hub) { hub_with('Bob') }
  let(:member) { EO::Engine::Group::Member.new(hub, name: 'Bob', deadline: 0.5) }
  let(:room) { OpenStruct.new(id: 1, players: [player('Lead')]) }
  let(:world) { OpenStruct.new(me: OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false), room: room, group_nouns: [], group_leader_noun: 'Lead') }
  let(:trips) { [] }
  let(:follow) { described_class.new(member: member, travel: ->(r) { trips << r; true }) }

  before do
    member.register
    hub.heartbeat!(name: 'Lead', room: 9, phase: :hunting)
    member.leader_state
  end

  it 'has nothing to do with the leader here and the group joined' do
    expect(follow.wants_control?(world)).to be false
  end

  it 'goes to the leader\'s room when the leader is elsewhere' do
    room.players = []
    expect(follow.wants_control?(world)).to be true
    expect(follow.tick(world).reason).to eq(:arrived)
    expect(trips).to eq([9])
  end

  it 'does not backtrack to a stale leader room when group movement completes during its room read' do
    hub.heartbeat!(name: 'Lead', room: 32763, phase: :hunting)
    member.leader_state
    game_objects = OpenStruct.new(pcs: [])
    current_room = OpenStruct.new(id: 32764)
    map = double('native Map')
    # The PC list and mapped room are live readers. The next room read
    # completes the group arrival after Follow first saw no leader.
    allow(map).to receive(:current) do
      game_objects.pcs = [player('Lead')]
      current_room
    end
    native_world = EO::Engine::World.new
    allow(native_world).to receive_messages(gameobj: game_objects, map: map,
                                            me: world.me, group_leader_noun: 'Lead', group_nouns: ['Lead'])
    scripts = double('owned travel scripts', running?: false)
    allow(scripts).to receive(:start)
    native_follow = described_class.new(member: member,
                                        travel: ->(destination) { EO::Engine::Travel::Trip.new(destination, scripts: scripts, unhide: false) })

    native_follow.tick(native_world)

    expect(native_world.room.players.map(&:noun)).to eq(['Lead'])
    expect(scripts).not_to have_received(:start)
  ensure
    native_follow&.cancel!
  end

  it 'cancels its owned catch-up trip before rejoining a leader who has arrived' do
    scripts = double('owned travel scripts', running?: true, start: nil, kill: nil)
    native_follow = described_class.new(member: member,
                                        travel: ->(destination) { EO::Engine::Travel::Trip.new(destination, scripts: scripts, unhide: false) })
    room.players = []
    world[:group_leader_noun] = nil
    native_follow.tick(world)
    expect(EO::Engine::Travel.underway?).to be true

    room.players = [player('Lead')]
    expect(EO::Engine::Actions::Join).to receive(:new).with(world, leader: 'Lead') do
      expect(scripts).to have_received(:kill).with('go2').once
      expect(EO::Engine::Travel.active).to be_nil
      double(call: EO::Engine::Actions::Result.new(status: :success))
    end
    native_follow.tick(world)
    world[:group_leader_noun] = 'Lead'
    expect(native_follow.wants_control?(world)).to be false
    expect(scripts).to have_received(:start).once
  ensure
    native_follow&.cancel!
  end

  it 'does not start catch-up when group arrival completes in the travel arrival check' do
    room.players = []
    reads = 0
    allow(room).to receive(:id) do
      reads += 1
      room.players = [player('Lead')] if reads >= 2
      1
    end
    scripts = double('owned scripts', running?: false, start: nil)
    native_follow = described_class.new(member: member,
                                        travel: ->(destination) { EO::Engine::Travel::Trip.new(destination, scripts: scripts, unhide: false) })

    native_follow.tick(world)

    expect(room.players.map(&:noun)).to eq(['Lead'])
    expect(scripts).not_to have_received(:start)
  ensure
    native_follow&.cancel!
  end

  it 'waits for a native parser cut instead of backtracking during an incomplete room update' do
    room.players = []
    room.id = 3944
    room.count = 2
    publication = nil # Socket ingress has withdrawn the preceding room cut.
    allow(member).to receive(:native_reader).and_return(-> { publication })
    scripts = double('owned scripts', running?: false, start: nil)
    native_follow = described_class.new(member: member,
                                        travel: ->(destination) { EO::Engine::Travel::Trip.new(destination, scripts: scripts, unhide: false) })

    result = native_follow.tick(world)
    expect(scripts).not_to have_received(:start)
    expect(result.reason).to eq(:state_unconfirmed)

    # The same group arrives; only now is the room's player list complete.
    room.players = [player('Lead')]
    publication = { source: { connection_id: 'connection', sequence: 2,
                              received_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                    fields: { room: { value: { epoch: 2 } } } }.freeze
    expect(native_follow.tick(world)).to be_nil
    expect(scripts).not_to have_received(:start)
  ensure
    native_follow&.cancel!
  end

  it 'revalidates the native cut after travel resolves its destination' do
    room.players = []
    room.count = 2
    publication = { source: { connection_id: 'connection', sequence: 2,
                              received_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                    fields: { room: { value: { epoch: 2 } } } }.freeze
    allow(member).to receive(:native_reader).and_return(-> { publication })
    scripts = double('owned scripts', running?: false, start: nil)
    trip = nil
    invalidated = false
    native_follow = described_class.new(member: member, travel: lambda { |destination|
      trip = EO::Engine::Travel::Trip.new(destination, scripts: scripts, unhide: false,
        at: lambda { |*|
          publication = nil unless invalidated
          invalidated = true
          false
        })
    })

    native_follow.tick(world)

    expect(scripts).not_to have_received(:start)
    expect(trip.attempts).to eq(0)
    expect(EO::Engine::Travel.underway?).to be false

    # A completed local frame still shows a real separation. Catch-up must
    # resume without a timer or sacrificing one of go2's attempts.
    publication = { source: { connection_id: 'connection', sequence: 3,
                              received_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                    fields: { room: { value: { epoch: 2 } } } }.freeze
    native_follow.tick(world)
    expect(scripts).to have_received(:start).with('go2', '9 --disable-confirm').once
  ensure
    native_follow&.cancel!
  end

  it 'waits for native trip arrival cleanup before joining the leader at its destination' do
    scripts = double('owned travel scripts', running?: true, start: nil, kill: nil)
    native_follow = described_class.new(member: member,
                                        travel: ->(destination) { EO::Engine::Travel::Trip.new(destination, scripts: scripts, unhide: false) })
    room.players = []
    world[:group_leader_noun] = nil
    native_follow.tick(world)
    room.id = 9
    room.players = [player('Lead')]
    allow(EO::Engine::Actions::Join).to receive(:new).and_return(
      double(call: EO::Engine::Actions::Result.new(status: :success))
    )

    expect(native_follow.tick(world)).to be_nil
    expect(EO::Engine::Travel.underway?).to be true
    expect(scripts).not_to have_received(:kill)
    expect(EO::Engine::Actions::Join).not_to have_received(:new)

    allow(scripts).to receive(:running?).and_return(false)
    expect(native_follow.tick(world).success?).to be true
    expect(EO::Engine::Travel.active).to be_nil
    expect(EO::Engine::Actions::Join).to have_received(:new).once
    expect(scripts).to have_received(:start).once
  ensure
    native_follow&.cancel!
  end

  it 'waits out its own roundtime before trying to catch the leader' do
    room.players = []
    world.me[:in_rt?] = true

    result = follow.tick(world)

    expect(result.status).to eq(:skipped)
    expect(result.reason).to eq(:roundtime)
    expect(trips).to be_empty

    world.me[:in_rt?] = false
    expect(follow.tick(world).reason).to eq(:arrived)
    expect(trips).to eq([9])
  end

  it 'joins the leader when here but not in the group' do
    world[:group_leader_noun] = nil
    expect(follow.wants_control?(world)).to be true
    join = instance_double(EO::Engine::Actions::Join, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Join).to receive(:new).with(world, leader: 'Lead').and_return(join)
    follow.tick(world)
  end

  it 'catches a split leader and rejoins the game group' do
    room.players = []
    world[:group_leader_noun] = nil

    expect(follow.tick(world).reason).to eq(:arrived)
    expect(trips).to eq([9])

    room.id = 9
    room.players = [player('Lead')]
    join = instance_double(EO::Engine::Actions::Join, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Join).to receive(:new).with(world, leader: 'Lead').and_return(join)
    expect(follow.tick(world).status).to eq(:success)
  end

  it 'travels alone after leave_group until the next follow_now' do
    room.players = []
    follow.independent!
    expect(follow.wants_control?(world)).to be false
    follow.rejoin!
    expect(follow.wants_control?(world)).to be true
  end
end

RSpec.describe EO::Engine::Behaviors::Muster do
  include GroupSpecHelpers

  let(:hub) { hub_with('Bob') }
  let(:leader) { EO::Engine::Group::Leader.new(hub, name: 'Lead') }
  let(:me) { OpenStruct.new(webbed?: false, sleeping?: false, stunned?: false, hidden?: false, dead?: false, in_rt?: false, in_cast_rt?: false) }
  let(:room) { OpenStruct.new(id: 1, players: [player('Bob')]) }
  let(:world) { OpenStruct.new(me: me, room: room, group_nouns: ['Bob']) }
  let(:clock) { OpenStruct.new(now: Time.at(1000)) }
  let(:fight) { [false] }
  let(:muster) { described_class.new(leader: leader, resting: -> { false }, fight: ->(_w) { fight.first }, clock: clock) }

  before { allow_any_instance_of(EO::Engine::Actions::GroupOpen).to receive(:send_and_match).and_return(EO::Engine::Actions::Result.new(status: :success)) }

  def acknowledge_movement
    hub.ack(:prepare_move, 'Bob', hunt_id: hub.hunt_id)
  end

  it 'holds with nothing to fight while a member is stunned' do
    room.players = [player('Bob', status: 'stunned')]
    expect(muster.wants_control?(world)).to be true
    expect(muster.tick(world)).to be_nil
    fight[0] = true
    expect(muster.wants_control?(world)).to be false
  end

  it 'holds between fights until every follower is out of roundtime' do
    hub.report('Bob', report('Bob', rt: true))

    expect(muster.wants_control?(world)).to be true
    expect(muster.tick(world)).to be_nil

    hub.report('Bob', report('Bob', rt: false))
    expect(muster.wants_control?(world)).to be true
  end

  it 'requires every follower to acknowledge standing down before movement' do
    expect(muster.wants_control?(world)).to be true
    expect(muster.tick(world).reason).to eq(:prepare_movement)
    expect(hub.take_orders('Bob').map(&:type)).to eq([:prepare_move])

    expect(muster.wants_control?(world)).to be true
    expect(muster.tick(world)).to be_nil

    acknowledge_movement
    expect(muster.wants_control?(world)).to be true
    expect(muster.tick(world).reason).to eq(:movement_ready)
    expect(muster.wants_control?(world)).to be false
  end

  it 'calls a missing follower back, once every ten seconds' do
    room.players = []
    expect(muster.wants_control?(world)).to be true
    expect(muster.tick(world).reason).to eq(:called_back)
    expect(hub.take_orders('Bob').map(&:type)).to eq([:follow_now])
    expect(muster.tick(world)).to be_nil
    clock.now += 11
    expect(muster.tick(world).reason).to eq(:called_back)
  end

  it 'never wants control solo' do
    solo = EO::Engine::Group::Hub.new
    solo.open_hunt(leader: 'Lead', expected: 1)
    alone = described_class.new(leader: EO::Engine::Group::Leader.new(solo, name: 'Lead'), resting: -> { false }, fight: ->(_w) { false })
    room.players = []
    expect(alone.wants_control?(world)).to be false
  end
end

RSpec.describe EO::Engine::Behaviors::Rest, 'with a group' do
  include GroupSpecHelpers

  let(:hub) { hub_with('Bob') }
  let(:group_policy) { EO::Engine::Group::Policy.new }
  let(:leader) { EO::Engine::Group::Leader.new(hub, name: 'Lead', policy: group_policy) }
  let(:me) { OpenStruct.new(fxp_pct: 50, mana_pct: 80, spirit: 10, stamina_pct: 90, encumbrance_pct: 10, dead?: false, in_rt?: false, in_cast_rt?: false, hidden?: false, webbed?: false, sleeping?: false, stunned?: false) }
  let(:room) { OpenStruct.new(id: 1, uid: 11, players: [player('Bob')]) }
  let(:world) { OpenStruct.new(me: me, room: room, group_nouns: ['Bob']) }
  let(:policy) do
    EO::Engine::Rest::Policy.new(oom: 20, rest_till_mana: 90, rest_till_exp: 100, resting_room: 100, return_waypoints: [1],
                                 hunting_room: 200, rally_rooms: [3], fog_return: 1,
                                 resting_commands: ['sit'], resting_scripts: [], hunting_prep_commands: ['stand'], hunting_scripts: [],
                                 wander_stance: 'defensive', rest_interval: 0)
  end
  let(:scripts) { OpenStruct.new(started: []).tap { |s| s.define_singleton_method(:running?) { |_n| false }; s.define_singleton_method(:start) { |n, a| started << [n, a] }; s.define_singleton_method(:kill) { |_n| nil } } }
  let(:clock) { OpenStruct.new(now: Time.at(1000)) }
  let(:rest) do
    described_class.new(policy: policy, travel: ->(_r) { true }, fog: ->(_p, _r) { true }, scripts: scripts,
                        stance: ->(_s) { true }, group: leader, clock: clock)
  end

  before do
    me.define_singleton_method(:debuff_level) { |_n| nil }
    me.define_singleton_method(:debuff_active?) { |_n| false }
    allow(rest).to receive(:sleep)
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:send_through_ladder).and_return('ok')
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:sleep)
    allow_any_instance_of(EO::Engine::Actions::GroupOpen).to receive(:send_and_match).and_return(EO::Engine::Actions::Result.new(status: :success))
    allow_any_instance_of(EO::Engine::Actions::Disband).to receive(:send_and_match).and_return(EO::Engine::Actions::Result.new(status: :success))
  end

  def orders_sent = hub.take_orders('Bob').map(&:type)

  # The optional block runs before each tick: a stand-in for the followers
  # doing their own work between the leader's ticks.
  def run_until(phase, limit: 60)
    limit.times do
      yield if block_given?
      rest.tick(world)
      return if rest.phase == phase
    end
    raise "never reached #{phase}, at #{rest.phase}"
  end

  describe 'should_rest? with the followers (9016)' do
    it 'rests on a follower\'s reason, naming them' do
      expect(rest.wants_control?(world)).to be false
      hub.report('Bob', report('Bob', rest_reason: 'encumbered.'))
      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('Bob: encumbered.')
    end

    it 'rests when any live member reaches their own fried threshold by default' do
      hub.report('Bob', report('Bob', rest_reason: 'fried.'))
      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('Bob: fried.')
    end

    it 'can retain the all-members-fried behavior' do
      group_policy.fried_trigger = ['all']
      hub.report('Bob', report('Bob', rest_reason: 'fried.'))
      expect(rest.wants_control?(world)).to be false
      me.mana_pct = 10
      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('out of mana.')
    end

    it 'rests in all mode once every live member is fried' do
      group_policy.fried_trigger = ['all']
      policy.fried = 95
      me.fxp_pct = 100
      hub.report('Bob', report('Bob', rest_reason: 'fried.'))

      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('fried.')
    end

    it 'names the follower injury that overrides an otherwise unsatisfied all-fried barrier' do
      group_policy.fried_trigger = ['all']
      policy.fried = 0
      hub.report('Bob', report('Bob', rest_reason: 'wounded.'))
      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('Bob: wounded.')
    end

    it 'rests only for designated fried members when names are configured' do
      group_policy.fried_trigger = ['Ann', 'Skooshii']
      hub.report('Bob', report('Bob', rest_reason: 'fried.'))
      expect(rest.wants_control?(world)).to be false

      group_policy.fried_trigger << 'bOb'
      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('Bob: fried.')
    end

    it 'matches a designated leader without case sensitivity' do
      group_policy.fried_trigger = ['lead']
      policy.fried = 95
      me.fxp_pct = 100

      expect(rest.wants_control?(world)).to be true
      expect(rest.reason).to eq('fried.')
    end

    it 'waits on a wounded rest while a member is stunned' do
      hub.report('Bob', report('Bob', rest_reason: 'wounded.'))
      room.players = [player('Bob', status: 'stunned')]
      expect(rest.wants_control?(world)).to be false
      room.players = [player('Bob')]
      expect(rest.wants_control?(world)).to be true
    end
  end

  it 'waits for the followers to finish looting before leaving, then orders them home with us' do
    me.mana_pct = 10
    hub.report('Bob', report('Bob', looting: true))
    rest.wants_control?(world)
    rest.tick(world)
    expect(rest.phase).to eq(:wait_followers)
    rest.tick(world)
    expect(rest.phase).to eq(:hold)
    rest.tick(world)
    expect(rest.phase).to eq(:hold)
    hub.report('Bob', report('Bob'))
    rest.tick(world)
    expect(rest.phase).to eq(:leave)
    rest.tick(world)
    expect(orders_sent).to eq(%i[hunting_scripts_stop prep_rest unhide follow_now])
    expect(rest.phase).to eq(:fog)
  end

  it 'gathers after each waypoint and at the resting room, preps quietly first, then waits for everyone rested' do
    me.mana_pct = 10
    rest.wants_control?(world)
    run_until(:resting_prep)
    hub.take_orders('Bob')
    room.players = []
    rest.tick(world) # at the resting room: the quiet gather
    expect(rest.phase).to eq(:hold)
    expect(orders_sent).to eq([:follow_now])
    room.players = [player('Bob')]
    rest.tick(world)
    expect(rest.phase).to eq(:resting_prep_own)
    run_until(:rested)
    hub.report('Bob', report('Bob', rest_prep_done: false))
    rest.tick(world)
    expect(orders_sent).to eq(%i[resting_prep resting_scripts_start follow_now])
    expect(rest.phase).to eq(:hold)
    hub.report('Bob', report('Bob', rest_prep_done: true))
    rest.tick(world)
    expect(rest.phase).to eq(:resting)
  end

  it 'tells the followers first when they need not be quiet' do
    group_policy.quiet_followers = false
    me.mana_pct = 10
    rest.wants_control?(world)
    run_until(:resting_prep)
    hub.take_orders('Bob')
    rest.tick(world)
    expect(orders_sent).to eq(%i[resting_prep resting_scripts_start])
    expect(rest.phase).to eq(:resting_prep_own)
  end

  it 'holds the rest until every follower is ready too' do
    me.mana_pct = 10
    rest.wants_control?(world)
    # The :resting_prep order clears the follower's rest_prep_done, so the
    # barrier only opens once Bob reports back having actually prepped.
    run_until(:resting) { hub.report('Bob', report('Bob')) }
    me.mana_pct = 95
    hub.report('Bob', report('Bob', not_hunting_reason: 'mana still below threshold.'))
    rest.tick(world)
    expect(rest.phase).to eq(:resting)
    hub.report('Bob', report('Bob'))
    rest.tick(world)
    expect(rest.phase).to eq(:hunting_prep)
  end

  it 'preps the followers first, gathers before the rally, starts scripts together, and holds at the hunting room for signs and sneaks' do
    rest.start!
    rest.tick(world)
    expect(orders_sent).to eq([:hunting_prep])
    run_until(:rally_out)
    rest.tick(world)
    expect(rest.phase).to eq(:rally) # everyone present already
    run_until(:hunting_scripts)
    hub.take_orders('Bob') # the gathers' follow_nows
    rest.tick(world)
    expect(orders_sent).to eq(%i[follow_now hunting_scripts_start])
    expect(rest.phase).to eq(:hunting_scripts_own)
    run_until(:arrived)
    hub.report('Bob', report('Bob', sneaky: true, hidden: false))
    rest.tick(world)
    expect(orders_sent).to eq(%i[cast_signs check_sneaky follow_now])
    expect(rest.phase).to eq(:hold)
    hub.report('Bob', report('Bob', sneaky: true, hidden: true))
    rest.tick(world)
    expect(rest.phase).to eq(:done)
  end

  it 'disbands and sends the followers on their own for an independent return, and waits for nobody' do
    group_policy.independent_return = true
    me.mana_pct = 10
    rest.wants_control?(world)
    rest.tick(world)
    hub.report('Bob', report('Bob'))
    run_until(:leave)
    rest.tick(world)
    expect(orders_sent).to eq(%i[hunting_scripts_stop prep_rest leave_group fog_return go2_waypoints go2_resting_room])
    expect(rest.phase).to eq(:disband)
    world[:group_nouns] = []
    rest.tick(world)
    expect(rest.phase).to eq(:fog)
    run_until(:resting_prep)
    expect(rest.phase).to eq(:resting_prep) # no gather at the waypoint
  end

  it 'disbands and orders the rally trip for independent travel' do
    group_policy.independent_travel = true
    rest.start!
    run_until(:rally_out)
    hub.take_orders('Bob')
    world[:group_nouns] = []
    rest.tick(world)
    expect(orders_sent).to eq([:go2_rally])
    expect(rest.phase).to eq(:rally)
    run_until(:hunting_scripts)
    rest.tick(world)
    expect(orders_sent).to eq([:follow_now]) # 7281: the followers rejoin at the rally room
    expect(rest.phase).to eq(:hold)
    world[:group_nouns] = ['Bob']
    rest.tick(world)
    expect(orders_sent).to eq(%i[hunting_scripts_start go2_hunting_room])
    expect(rest.phase).to eq(:hunting_scripts_own)
  end

  it 're-orders follow_now every ten seconds while holding, unhiding first' do
    me.mana_pct = 10
    rest.wants_control?(world)
    run_until(:leave)
    rest.tick(world)
    room.players = []
    hub.take_orders('Bob')
    run_until(:hold) # after the waypoint
    expect(orders_sent).to eq([:follow_now])
    rest.tick(world)
    expect(orders_sent).to eq([])
    clock.now += 11
    me[:hidden?] = true
    sent = []
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:send_through_ladder) { |_a, cmd| sent << cmd; 'ok' }
    rest.tick(world)
    expect(sent).to eq(['unhide'])
    expect(orders_sent).to eq([:follow_now])
  end
end

RSpec.describe EO::Engine::Behaviors::Loot, 'with a group' do
  include GroupSpecHelpers

  let(:hub) { hub_with('Bob') }
  let(:group_policy) { EO::Engine::Group::Policy.new(looter: 'Bob') }
  let(:leader) { EO::Engine::Group::Leader.new(hub, name: 'Lead', policy: group_policy) }
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, fxp_pct: 50, encumbrance_pct: 10) }
  let(:room) { OpenStruct.new(id: 1, title: '[Kobold Village]', creatures: [npc(1, status: 'dead')], targets: [], loot: []) }
  let(:world) { OpenStruct.new(me: me, room: room, claim_mine?: true) }
  let(:policy) { EO::Engine::Loot::Policy.new }
  let(:tp) { EO::Engine::Targets::Policy.new }

  it 'hands the room to the named looter and waits until they are done' do
    loot = described_class.new(policy: policy, targets_policy: tp, group: leader)
    expect(loot.wants_control?(world)).to be true
    expect(loot.tick(world).reason).to eq(:loot_assigned)
    # the handoff, then the kill counted for the followers (it used to go uncounted)
    expect(hub.take_orders('Bob').map { |o| [o.type, o.payload] }).to eq([[:prep_rest, nil], [:loot, 'Bob'], [:follower_overkill, nil]])
    hub.report('Bob', report('Bob', looting: true))
    expect(loot.wants_control?(world)).to be false
    hub.report('Bob', report('Bob'))
    expect(loot.wants_control?(world)).to be false # that corpse is theirs
  end

  it 'loots itself when it is the looter, telling the followers to count the kill' do
    group_policy.looter = nil
    loot = described_class.new(policy: policy, targets_policy: tp, group: leader)
    allow_any_instance_of(EO::Engine::Actions::LteBoost).to receive(:call).and_return(EO::Engine::Actions::Result.new(status: :failed, reason: :not_fried))
    allow_any_instance_of(EO::Engine::Actions::Loot).to receive(:call).and_return(EO::Engine::Actions::Result.new(status: :success))
    expect(loot.wants_control?(world)).to be true
    expect(loot.tick(world).success?).to be true
    expect(hub.take_orders('Bob').map(&:type)).to eq([:follower_overkill])
  end

  it 'as a follower loots only when assigned, and is looting until the room is clear' do
    loot = described_class.new(policy: policy, targets_policy: tp, follower: true)
    expect(loot.wants_control?(world)).to be false
    expect(loot.looting?).to be false
    loot.assign!
    expect(loot.looting?).to be true
    expect(loot.wants_control?(world)).to be true
    allow_any_instance_of(EO::Engine::Actions::LteBoost).to receive(:call).and_return(EO::Engine::Actions::Result.new(status: :failed, reason: :not_fried))
    allow_any_instance_of(EO::Engine::Actions::Loot).to receive(:call).and_return(EO::Engine::Actions::Result.new(status: :success))
    loot.tick(world)
    expect(loot.wants_control?(world)).to be false
    expect(loot.looting?).to be false
  end
end

RSpec.describe EO::Engine::Behaviors::Engage, 'with a group' do
  include GroupSpecHelpers

  let(:hub) { hub_with('Bob') }
  let(:leader) { EO::Engine::Group::Leader.new(hub, name: 'Lead') }
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, hidden?: false, current_target_id: '1', standing?: true) }
  let(:room) { OpenStruct.new(id: 1, players: [player('Bob')], targets: [npc(1)], creatures: [npc(1)]) }
  let(:world) { OpenStruct.new(me: me, room: room, claim_mine?: true, foreign_disks: [], group_nouns: ['Bob']) }
  let(:clock) { OpenStruct.new(now: Time.at(1000)) }
  let(:fried) { [false] }
  let(:policy) { EO::Engine::Engage::Policy.new(routines: { 'a' => ['attack'] }, disable_commands: ['stance defensive'], hunting_stance: nil) }
  let(:engage) { described_class.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, group: leader, fried: -> { fried.first }, clock: clock) }

  before do
    allow_any_instance_of(EO::Engine::Actions::Attack).to receive(:call).and_return(EO::Engine::Actions::Result.new(status: :success))
    allow_any_instance_of(EO::Engine::Actions::GroupOpen).to receive(:send_and_match).and_return(EO::Engine::Actions::Result.new(status: :success))
    allow(engage).to receive(:soothe)
    allow(engage).to receive(:reaction)
  end

  it 'orders an attack on a new target and again every ten seconds' do
    engage.tick(world)
    expect(hub.take_orders('Bob').map(&:type)).to eq([:attack])
    engage.tick(world)
    expect(hub.take_orders('Bob')).to eq([])
    clock.now += 11
    engage.tick(world)
    expect(hub.take_orders('Bob').map(&:type)).to eq([:attack])
  end

  it 'calls a missing follower back without stopping the fight' do
    room.players = []
    expect(engage.tick(world).reason).to eq(:called_back)
    expect(hub.take_orders('Bob').map(&:type)).to eq(%i[attack follow_now])
    expect(engage.tick(world).success?).to be true # the routine line
  end

  it 'runs disable_commands for a fried member of a group' do
    fried[0] = true
    seen = []
    EO::Engine::Events.on(:engaged) { |e| seen << e.data[:routine] }
    allow(engage).to receive(:dispatch).and_return(EO::Engine::Actions::Result.new(status: :success))
    engage.tick(world)
    expect(seen).to eq(['disabled'])
    expect(engage).to have_received(:dispatch).with(world, 'stance defensive', anything)
    EO::Engine::Events.reset!
  end
end

RSpec.describe EO::Engine::Survival::Predicates, 'group deader' do
  include GroupSpecHelpers

  let(:room) { OpenStruct.new(title: 'x', players: [player('Bob', status: 'dead')], targets: []) }
  let(:world) { OpenStruct.new(room: room, group_nouns: ['Bob']) }

  it 'stops for a dead group member with group_deader, never as a follower' do
    policy = EO::Engine::Survival::Policy.new
    expect(described_class.deader?(world, policy)).to be false
    policy.group_deader = true
    expect(described_class.deader?(world, policy)).to be true
    expect(described_class.deader?(world, policy, follower: true)).to be false
    world[:group_nouns] = []
    expect(described_class.deader?(world, policy)).to be false
  end
end

RSpec.describe EO::Engine::Profile, 'group policy' do
  it 'reads the MA Grouping keys' do
    profile = described_class.new({ 'independent_return' => true, 'ma_looter' => 'Bob', 'never_loot' => 'Ann, Zed', 'quiet_followers' => false,
                                    'group_deader' => true, 'troubadours_rally' => true })
    gp = profile.group_policy
    expect(gp.independent_return).to be true
    expect(gp.independent_travel).to be false
    expect(gp.looter).to eq('Bob')
    expect(gp.never_loot_list).to eq(%w[Ann Zed])
    expect(gp.quiet_followers).to be false
    expect(gp.fried_trigger).to eq(['any'])
    expect(profile.survival_policy.group_deader).to be true
    expect(profile['troubadours_rally']).to be true
    expect(described_class.new({}).group_policy.quiet_followers).to be true
    expect(described_class.new({ 'group_fried_trigger' => 'Testfollower, Testleader' }).group_policy.fried_trigger).to eq(%w[Testfollower Testleader])
  end
end

RSpec.describe EO::Engine::Engine, 'on_tick' do
  it 'runs the tick hooks every tick, paused or not' do
    ticks = []
    engine = described_class.new(world: OpenStruct.new, behaviors: [], interval: 0)
    engine.on_tick { |_w| ticks << :t }
    engine.tick
    engine.pause!
    engine.tick
    expect(ticks.size).to eq(2)
  end
end

RSpec.describe EO::Engine::Actions::GroupOpen do
  it "sends GROUP OPEN only when Lich's Group says the group is not open" do
    world = OpenStruct.new(me: OpenStruct.new(dead?: false), group_open?: true)
    action = described_class.new(world)
    expect(action.call.reason).to eq(:already_open)

    world[:group_open?] = false
    sent = []
    allow(action).to receive(:send_and_match) { |cmd, _rx, **| sent << cmd; EO::Engine::Actions::Result.new(status: :success, line: 'Your group status is now open.') }
    expect(action.call).to be_success
    expect(sent).to eq(['group open'])
  end
end

RSpec.describe EO::Engine::Actions::Join do
  let(:me) { OpenStruct.new(dead?: false) }
  let(:room) { OpenStruct.new(players: [OpenStruct.new(noun: 'Lead')]) }
  let(:world) { OpenStruct.new(me: me, room: room) }
  let(:native_group) { double('native Group', check: nil, checked?: true) }

  before { stub_const('Lich::Gemstone::Group', native_group) }

  it 'refreshes the complete native roster after a join before reporting success' do
    roster = ['Lead'] # The real "You join Lead" line does not name the other follower.
    allow(native_group).to receive(:nouns) { roster }
    allow(native_group).to receive(:check) { roster = ['Lead', 'Other'] }
    action = join(ok: OpenStruct.new(noun: 'Lead'))

    expect(action.call).to be_success
    expect(EO::Engine::World.new.group_nouns.sort).to eq(%w[Lead Other])
  end

  it 'refreshes an already-member reply too, but never a refused join' do
    expect(native_group).to receive(:check).once
    expect(join(noop: true).call).to be_success
    expect(join(err: true).call).not_to be_success
  end

  it 'does not report join success when the roster refresh is unanswered' do
    allow(native_group).to receive(:checked?).and_return(false)
    result = join(ok: true).call
    expect(result.status).to eq(:timeout)
    expect(result.reason).to eq(:group_unconfirmed)
  end

  def join(answer)
    action = described_class.new(world, leader: 'Lead')
    allow(action).to receive(:group_join).with('Lead').and_return(answer)
    action
  end

  it "reads Lich's Group.join answers" do
    lead = OpenStruct.new(id: '-1', noun: 'Lead')
    expect(join({ ok: lead }).call.reason).to eq(:joined)
    expect(join({ noop: lead }).call.reason).to eq(:already_member)
    expect(join({ err: lead }).call.reason).to eq(:closed)
    expect(join({ err: nil }).call.reason).to eq(:not_here)
  end

  it 'does not send when the leader is not in the room' do
    room.players = []
    expect(join({ ok: nil }).call.reason).to eq(:no_leader)
  end
end

# Lich kills the script's worker threads - the DRb server among them -
# before it runs at_exit procs (script.rb 2173, then 2191). So a bounded
# wait for follower acks inside before_dying can never collect one: it
# spent the full 15 s deadline and reported every follower unacked, on a
# plain ;kill as much as on a real stop. The acknowledged shutdown has to
# run while the threads are alive; the teardown hook keeps only the
# non-blocking finish!. The script's top-level flow has no behavioral
# spec, so this pins the arrangement in the source until one exists.
RSpec.describe 'the group shutdown in eohunter.lic' do
  let(:source) { File.read(File.expand_path('../../scripts/eohunter.lic', __dir__)) }
  let(:teardown) { source[/^unless dry\n  before_dying do\n.*?\n^end\n/m] }
  let(:run_path) { source[/^else\n  # bigshot pre_hunt.*?\n^end\n/m] }

  it 'acknowledges the shutdown from the run path, where the DRb thread is alive' do
    expect(run_path).to include('end_hunt')
  end

  it 'leaves only the non-blocking finish! in the teardown hook' do
    expect(teardown).not_to include('end_hunt')
    expect(teardown).to include('finish!')
  end

  it 'tears the watch down even when a fallible step raises' do
    expect(teardown).to match(/ensure\b.*Watch\.uninstall!/m)
  end
end

# The follower's link to the leader. Both of these used to degrade
# silently and permanently: one bad answer, and the follower spent the
# rest of the hunt acting on nothing.
RSpec.describe EO::Engine::Group::Member do
  include GroupSpecHelpers

  let(:hub) { hub_with('Bob') }
  let(:member) { described_class.new(hub, name: 'Bob', deadline: 0.5) }

  describe '#rooms' do
    it 'retries after a failed fetch instead of caching the empty answer' do
      hub.open_hunt(leader: 'Lead', expected: ['Bob'], rooms: { hunting: 7, resting: 5 })
      calls = 0
      allow(hub).to receive(:rooms) do
        calls += 1
        raise DRb::DRbConnError, 'leader stalled' if calls == 1

        { hunting: 7, resting: 5 }
      end

      expect(member.rooms).to eq({}) # the failure is not kept
      expect(member.rooms).to eq(hunting: 7, resting: 5)
      expect(calls).to eq(2)
    end

    it 'fetches once after a real answer arrives' do
      hub.open_hunt(leader: 'Lead', expected: ['Bob'], rooms: { hunting: 7 })
      allow(hub).to receive(:rooms).and_call_original
      3.times { member.rooms }
      expect(hub).to have_received(:rooms).once
    end
  end

  describe '#keep_alive!' do
    it 'keeps pulsing after a raise, rather than ending liveness silently' do
      hub.open_hunt(leader: 'Lead', expected: ['Bob'], rooms: {})
      member.register
      member.report(report('Bob'))
      # remote() catches a raise from the hub call itself; what used to
      # kill the pulse for good is a raise from the lines around it, where
      # the last report is duped and re-stamped before being sent.
      calls = 0
      hostile = member.instance_variable_get(:@last_report).dup
      hostile.define_singleton_method(:dup) do
        calls += 1
        raise 'cannot dup this report'
      end
      member.instance_variable_set(:@last_report, hostile)

      member.keep_alive!(interval: 0.02)
      # poll rather than sleep a fixed span: under a loaded machine a
      # fixed wait is a flaky test, and what matters is that beats keep
      # coming, not how fast
      deadline = Time.now + 5
      sleep 0.02 while calls < 2 && Time.now < deadline
      pulse = member.instance_variable_get(:@pulse)
      alive = pulse.alive?
      member.stop_pulse!

      expect(alive).to be true
      expect(calls).to be > 1
    end
  end
end

RSpec.describe EO::Engine::Group::Leader do
  include GroupSpecHelpers

  it 'keeps pulsing after a heartbeat raises' do
    hub = hub_with('Bob')
    policy = EO::Engine::Group::Policy.new
    leader = described_class.new(hub, name: 'Lead', policy: policy)
    leader.publish(OpenStruct.new(room: OpenStruct.new(id: 1)), phase: :hunting)
    calls = 0
    allow(hub).to receive(:heartbeat!) do
      calls += 1
      raise DRb::DRbConnError, 'one bad beat'
    end

    leader.keep_alive!(interval: 0.02)
    deadline = Time.now + 5
    sleep 0.02 while calls < 2 && Time.now < deadline
    pulse = leader.instance_variable_get(:@pulse)
    alive = pulse.alive?
    leader.stop_pulse!

    expect(alive).to be true
    expect(calls).to be > 1
  end
end
