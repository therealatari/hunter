# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

# Watch is the engine's subscription to Lich's parser seam: each fact
# arrives on the bus under the name the behaviors listen for, completed
# with what the moment knows.
RSpec.describe EO::Engine::Watch do
  let(:tracker) { Lich::Gemstone::Combat::Tracker }
  let(:seen) { [] }

  before do
    tracker.reset!
    # Other behavior specs build profile rules before this group's first
    # example. This fixture starts with no profile, independent of seed order.
    described_class.clear!
    EO::Engine::Events.on { |e| seen << [e.type, e.data] }
    stub_const('DownstreamHook', Class.new { def self.add(*); end; def self.remove(*); end })
    described_class.install!
  end

  after do
    described_class.uninstall!
    described_class.clear!
    EO::Engine::Events.reset!
  end

  it 'enables the tracker with attack events and subscribes to messages, reloads, :ucs and :attack' do
    expect(tracker.enabled?).to be true
    expect(tracker.settings[:emit_attacks]).to be true
    expect(tracker.handlers.keys).to include(:disarm_seen, :bolted, :ucs, :attack)
    expect(tracker.names.keys).to contain_exactly('eohunter:messages', 'eohunter:definitions_reloaded', 'eohunter:ucs', 'eohunter:attack')
    expect(described_class).to be_installed
  end

  it 'passes a message event through under its name with the line' do
    tracker.emit(:bolted, raw: 'You bolt!')
    expect(seen).to eq([[:bolted, { raw: 'You bolt!' }]])
  end

  it 're-enumerates message names on every reload without using its payload' do
    allow(Lich::Gemstone::Combat::Messages).to receive(:events).and_return(%i[bolted user_feed_result])
    tracker.emit(:definitions_reloaded, events: [:wrong_name])
    tracker.emit(:bolted, raw: 'bolt')
    tracker.emit(:user_feed_result, item: 'crystal', ok: true)
    tracker.emit(:disarm_seen, raw: 'removed')
    tracker.emit(:wrong_name, raw: 'not a definition')
    expect(seen).to eq([[:bolted, { raw: 'bolt' }], [:user_feed_result, { item: 'crystal', ok: true }]])

    allow(Lich::Gemstone::Combat::Messages).to receive(:events).and_return([:user_other_result])
    tracker.emit(:definitions_reloaded, nil)
    tracker.emit(:user_feed_result, ok: false)
    tracker.emit(:bolted, raw: 'removed too')
    tracker.emit(:user_other_result, ok: true)
    expect(seen.last).to eq([:user_other_result, { ok: true }])
    expect(seen.size).to eq(3)
  end

  it 'delivers each fact once after repeated reloads and installations' do
    3.times do
      tracker.emit(:definitions_reloaded, {})
      described_class.install!
    end
    tracker.emit(:bolted, raw: 'one')
    tracker.emit(:ucs, kind: :position, tier: 2, id: 1)
    tracker.emit(:attack, inbound: true, attacker: { id: 77 })
    expect(seen.map(&:first)).to eq(%i[bolted unarmed_tier incoming_swing])
    expect(tracker.handlers[:definitions_reloaded].size).to eq(1)
  end

  it 'removes the current message and reload handlers after several reloads' do
    3.times { tracker.emit(:definitions_reloaded, {}) }
    described_class.uninstall!
    tracker.emit(:definitions_reloaded, {})
    tracker.emit(:bolted, raw: 'gone')
    expect(seen).to be_empty
    expect(tracker.handlers.values.flatten).to be_empty
    expect(tracker.names).to be_empty
    expect(described_class).not_to be_installed
  end

  it 'ignores a reload callback captured before uninstall, including after reinstall' do
    old_reload = tracker.names.fetch('eohunter:definitions_reloaded')
    described_class.uninstall!
    old_reload.call(:definitions_reloaded, {})
    expect(tracker.names).to be_empty
    expect(described_class).not_to be_installed

    described_class.install!
    current_message = tracker.names.fetch('eohunter:messages')
    old_reload.call(:definitions_reloaded, {})
    expect(tracker.names.fetch('eohunter:messages')).to equal(current_message)
    tracker.emit(:bolted, raw: 'one')
    expect(seen).to eq([[:bolted, { raw: 'one' }]])
  end

  it 'removes the message subscription when no events remain and can add it again' do
    allow(Lich::Gemstone::Combat::Messages).to receive(:events).and_return([])
    tracker.emit(:definitions_reloaded, {})
    tracker.emit(:bolted, raw: 'gone')
    tracker.emit(:unrelated_event, {})
    expect(seen).to be_empty
    expect(tracker.names).not_to have_key('eohunter:messages')

    allow(Lich::Gemstone::Combat::Messages).to receive(:events).and_return([:user_feed_result])
    tracker.emit(:definitions_reloaded, {})
    tracker.emit(:user_feed_result, ok: true)
    expect(seen).to eq([[:user_feed_result, { ok: true }]])
  end

  it 'renames the item limit and the hive trap kinds, adding the room' do
    allow(EO::Engine::World).to receive(:new).and_return(OpenStruct.new(room: OpenStruct.new(id: 42)))
    tracker.emit(:item_limit, raw: 'x')
    tracker.emit(:hive_trap, kind: :ground, raw: 'y')
    expect(seen.map(&:first)).to eq(%i[too_many_items hive_trap])
    expect(seen.last.last).to include(kind: :hive_traps_ground, room_id: 42)
  end

  it 'adds the hands and the room to a disarm' do
    hands = OpenStruct.new(right: 'r', left: 'l')
    allow(EO::Engine::World).to receive(:new).and_return(OpenStruct.new(room: OpenStruct.new(id: 7, title: 'Kobold Village'), hands: hands))
    tracker.emit(:disarm_seen, kind: :recover, noun: 'katana', raw: 'z')
    expect(seen.first.last).to include(kind: :recover, noun: 'katana', hands: hands, room_id: 7, title: 'Kobold Village')
  end

  it 'says whether a shrugged bless was ours' do
    me = OpenStruct.new(inventory_ids: ['5'])
    hands = OpenStruct.new(right: OpenStruct.new(noun: 'bow'), left: OpenStruct.new(noun: ''))
    allow(EO::Engine::World).to receive(:new).and_return(OpenStruct.new(me: me, hands: hands))
    tracker.emit(:bless_shrugged, id: '5', noun: 'arrow', raw: 'a')
    tracker.emit(:bless_shrugged, id: '9', noun: 'bow', raw: 'b')
    tracker.emit(:bless_shrugged, id: '9', noun: 'sword', raw: 'c')
    expect(seen.map { |_, d| d[:mine] }).to eq([true, true, false])
  end

  it 'turns the UCS facts into the unarmed tier and followup' do
    tracker.emit(:ucs, id: 1, name: 'kobold', kind: :position, value: 'good', tier: 2)
    tracker.emit(:ucs, id: 1, name: 'kobold', kind: :tierup, value: 'jab', tier: nil)
    tracker.emit(:ucs, id: 1, name: 'kobold', kind: :smite_on, value: nil, tier: nil)
    expect(seen).to eq([[:unarmed_tier, { tier: 2, id: 1 }], [:unarmed_followup, { attack: 'jab', id: 1 }]])
  end

  it 'turns an inbound attack into the incoming swing and our own rolls into force rolls' do
    tracker.emit(:attack, inbound: true, attacker: { id: 77, name: 'a kobold' }, resolutions: [{ result: 150 }])
    tracker.emit(:attack, inbound: false, resolutions: [{ result: 120 }, { result: 98 }])
    tracker.emit(:attack, inbound: false, foreign_caster: true, resolutions: [{ result: 200 }])
    expect(seen).to eq([[:incoming_swing, { target_id: '77' }], [:force_roll, { roll: 120 }], [:force_roll, { roll: 98 }]])
  end

  it 'turns another player\'s attack into an ally attack by name, and nothing when unnamed' do
    tracker.emit(:attack, foreign_caster: true, attacker: { name: 'Testfollower' }, resolutions: [{ result: 200 }])
    tracker.emit(:attack, foreign_caster: true, attacker: nil)
    tracker.emit(:attack, foreign_caster: true, attacker: { id: -5 })
    expect(seen).to eq([[:ally_attacked, { name: 'Testfollower' }]])
  end

  it 'keeps a hook only for rules of its own, such as the profile flee text' do
    hooks = []
    stub_const('DownstreamHook', Class.new do
      define_singleton_method(:add) { |name, *| hooks << name }
      define_singleton_method(:remove) { |name| hooks.delete(name) }
    end)
    described_class.uninstall!
    described_class.install!
    expect(hooks).to be_empty
    described_class.on(/run away/, :flee_message)
    described_class.install!
    expect(hooks).to eq([EO::Engine::HOOK_NAME])
    described_class.process('You had better run away now.')
    expect(seen.last).to eq([:flee_message, { raw: 'You had better run away now.' }])
  end
end

RSpec.describe 'Combat::Tracker stand-in' do
  let(:tracker) { Lich::Gemstone::Combat::Tracker }

  before { tracker.reset! }
  after { tracker.reset! }

  it 'replaces named registrations across all old event lists' do
    seen = []
    tracker.on(:old, :retained, name: 'named') { |type, _| seen << [:old, type] }
    replacement = tracker.on(:retained, :added, name: 'named') { |type, _| seen << [:new, type] }
    %i[old retained added].each { |type| tracker.emit(type, {}) }
    expect(seen).to eq([[:new, :retained], [:new, :added]])
    expect(tracker.names).to eq('named' => replacement)
  end

  it 'removes names when unregistering a handler or name, and clears them on reset' do
    handler = tracker.on(:fact, name: 'by_handler') { |*| }
    tracker.off(handler)
    expect(tracker.names).to be_empty
    tracker.on(:fact, name: 'by_name') { |*| }
    tracker.off('by_name')
    expect(tracker.names).to be_empty
    expect(tracker.handlers.values.flatten).to be_empty
    tracker.on(:fact, name: 'reset') { |*| }
    tracker.reset!
    expect(tracker.names).to be_empty
    expect(tracker.handlers).to be_empty
  end

  it 'takes a snapshot so subscription changes do not skip or add callbacks during delivery' do
    seen = []
    tracker.on(:fact) do |*|
      seen << :first
      tracker.off('second')
      tracker.on(:fact, name: 'third') { |*| seen << :third }
    end
    tracker.on(:fact, name: 'second') { |*| seen << :second }
    tracker.emit(:fact, {})
    expect(seen).to eq(%i[first second])
    tracker.emit(:fact, {})
    expect(seen).to eq(%i[first second first third])
  end
end
