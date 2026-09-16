# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../scripts/eocoordination/protocol'
require_relative '../../scripts/eohunter_group/supervisor'

RSpec.describe EO::HunterGroup::Supervisor do
  let(:now) { [10.0] }
  let(:owner) { Object.new }
  let(:children) { [] }
  let(:scripts) do
    double('native scripts', current: owner).tap do |native|
      allow(native).to receive(:start_child) do
        double('exact native child', join: nil, completed_successfully?: false).tap { |child| children << child }
      end
    end
  end
  let(:journal) { double('journal', pending: nil, record: true, clear: true) }
  let(:busy) { [false] }
  let(:supervisor) { described_class.new(scripts: scripts, journal: journal, busy: -> { busy.first }, clock: -> { now.first }) }
  let(:identity) { { game: 'GS3', character: 'Leader', incarnation: 'abc', connection_generation: 0, run_id: 'run-one' } }
  let(:configuration) do
    { run_id: 'run-one', role: :head, profile: 'Trio', leader_identity: identity,
      members: ['Follower'], refuge_room: 324 }
  end

  after { children.each { |child| EO::HunterGroup.unbind(child) } }

  def ready
    supervisor.context.report_state(ready: true, hands: %w[sword shield])
    supervisor.context.report_ready(ready: true, hands: %w[sword shield])
    supervisor.tick
  end

  it 'launches once, binds only the exact returned child and refuses changed retry data' do
    supervisor.prepare(**configuration)
    expect(EO::HunterGroup.await_context(children.first, timeout: 0)).to equal(supervisor.context)
    expect { EO::HunterGroup.await_context(Object.new, timeout: 0) }.to raise_error(/no exact supervisor/)
    supervisor.prepare(**configuration)
    expect(children.size).to eq(1)
    expect { supervisor.prepare(**configuration.merge(profile: 'other')) }.to raise_error(/configuration changed/)
  end

  it 'refuses launches outside the exact native owner thread' do
    supervisor
    result = Thread.new do
      begin
        supervisor.prepare(**configuration)
      rescue ThreadError => error
        error
      end
    end.value
    expect(result).to be_a(ThreadError)
    expect(children).to be_empty
  end

  it 'passes profile names with spaces through native Array arguments unchanged' do
    supervisor.prepare(**configuration.merge(profile: 'Leveling Trio'))
    expect(scripts).to have_received(:start_child).with('eohunter', args: ['Leveling Trio', 'head', 'managed'])
  end

  it 'refuses unrelated local activity and unresolved previous runs' do
    busy[0] = true
    expect { supervisor.prepare(**configuration) }.to raise_error(/unrelated local activity/)
    busy[0] = false
    allow(journal).to receive(:pending).and_return({ 'run_id' => 'old' })
    restarted = described_class.new(scripts: scripts, journal: journal, busy: -> { false })
    expect { restarted.prepare(**configuration) }.to raise_error(/unresolved/)
    expect(children).to be_empty
  end

  it 'requires preparation and a separate fresh commitment acknowledgment' do
    supervisor.prepare(**configuration)
    expect { supervisor.commit(run_id: 'run-one') }.to raise_error(/not ready/)
    ready
    supervisor.commit(run_id: 'run-one')
    expect(supervisor.context.command).to eq(:commit)
    expect { supervisor.hunt(run_id: 'run-one') }.to raise_error(/not acknowledged/)
    supervisor.context.report_committed(ready: true)
    supervisor.tick
    supervisor.hunt(run_id: 'run-one')
    expect(supervisor.context.command).to eq(:hunt)
  end

  it 'invalidates ready and committed evidence after native state changes or stalls' do
    supervisor.prepare(**configuration)
    ready
    supervisor.context.report_state(ready: false)
    expect { supervisor.commit(run_id: 'run-one') }.to raise_error(/not ready/)
    ready
    supervisor.commit(run_id: 'run-one')
    supervisor.context.report_committed(ready: true)
    supervisor.tick
    now[0] += 3
    expect { supervisor.hunt(run_id: 'run-one') }.to raise_error(/not acknowledged/)
  end

  it 'cancels preparation on expiry and remains responsive during unbounded native teardown' do
    supervisor.prepare(**configuration)
    now[0] += 91
    supervisor.tick
    expect(supervisor.context.command).to eq(:return)
    now[0] += 181
    3.times { supervisor.tick }
    expect(supervisor.status).to include(phase: :unresolved, child_pending: true)
    expect(children.size).to eq(1)
    expect(journal).not_to have_received(:clear)
  end

  it 'waits for exact native teardown before starting one recovery-only child' do
    supervisor.prepare(**configuration)
    supervisor.context.pin_profile({ 'weapon' => 'sword' }, 'digest')
    supervisor.context.report_state(ready: false, hands: %w[sword shield])
    supervisor.context.report_unresolved('crashed')
    2.times { supervisor.tick }
    expect(children.size).to eq(1)
    allow(children.first).to receive(:join).with(0).and_return(children.first)
    supervisor.tick
    expect(children.size).to eq(2)
    expect(supervisor.context).to be_recovery
    expect(supervisor.context.command).to eq(:return)
    expect(supervisor.context.prepared_hands).to eq(%w[sword shield])
    allow(children.last).to receive(:join).with(0).and_return(children.last)
    supervisor.tick
    expect(supervisor.status[:phase]).to eq(:unresolved)
    expect(children.size).to eq(2)
  end

  it 'records safety only after explicit safe evidence and successful native completion' do
    supervisor.prepare(**configuration)
    supervisor.context.report_safe(safe: true)
    supervisor.tick
    expect(journal).not_to have_received(:clear)
    allow(children.first).to receive(:join).with(0).and_return(children.first)
    allow(children.first).to receive(:completed_successfully?).and_return(true)
    supervisor.tick
    expect(journal).to have_received(:clear).with(run_id: 'run-one', safe: true)
    expect(supervisor.status[:phase]).to eq(:safe)
  end

  it 'retains unresolved status if the verified safety journal cannot be removed' do
    supervisor.prepare(**configuration)
    supervisor.context.report_safe(safe: true)
    allow(children.first).to receive(:join).with(0).and_return(children.first)
    allow(children.first).to receive(:completed_successfully?).and_return(true)
    allow(journal).to receive(:clear).and_return(false)
    supervisor.tick
    expect(supervisor.status[:phase]).to eq(:unresolved)
  end

  it 'persists original policy and hands before releasing preparation' do
    allow(journal).to receive(:record_evidence).and_return(true)
    supervisor.prepare(**configuration)
    supervisor.context.pin_profile({ 'weapon' => 'keep' }, 'digest')
    ready
    supervisor.tick
    expect(journal).to have_received(:record_evidence).once.with(run_id: 'run-one', profile: 'Trio',
                                                                 settings: { 'weapon' => 'keep' }, hands: %w[sword shield])
  end

  it 'requests return when completed engine turns stall despite repeated observations' do
    supervisor.prepare(**configuration)
    ready
    supervisor.commit(run_id: 'run-one')
    supervisor.context.report_committed(ready: true)
    supervisor.context.report_state(ready: true, owner_tick: 1)
    supervisor.tick
    supervisor.hunt(run_id: 'run-one')
    now[0] += 121
    supervisor.context.report_state(phase: :hunting, ready: false, owner_tick: 1, native_children_pending: true)
    supervisor.tick
    expect(supervisor.context.command).to eq(:return)
    expect(supervisor.status[:reason]).to include('stopped completing turns')
    expect(children.size).to eq(1)
  end

  it 'recovers a restart only from the exact persisted source and original hands' do
    pending = { 'run_id' => 'run-one', 'profile' => 'Trio', 'settings' => { 'weapon' => 'keep' },
                'hands' => %w[sword shield] }
    allow(journal).to receive(:pending).and_return(pending)
    supervisor.recover(run_id: 'run-one', profile: 'Trio', leader_identity: identity, refuge_room: 324,
                       profile_settings: pending['settings'], prepared_hands: pending['hands'])
    expect(supervisor.context).to be_recovery
    expect(supervisor.context.prepared_hands).to eq(%w[sword shield])
    expect(supervisor.context.profile_settings).to eq('weapon' => 'keep')
  end

  it 'refuses restart recovery without original evidence' do
    allow(journal).to receive(:pending).and_return({ 'run_id' => 'run-one' })
    expect do
      supervisor.recover(run_id: 'run-one', profile: 'Trio', leader_identity: identity, refuge_room: 324,
                         profile_settings: nil, prepared_hands: nil)
    end.to raise_error(/original profile or hand evidence unavailable/)
    expect(children).to be_empty
  end
end
