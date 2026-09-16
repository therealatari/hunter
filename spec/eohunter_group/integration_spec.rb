# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../support/hunter_group_peer'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'managed hunter process contracts' do
  around do |example|
    Dir.mktmpdir('hunter-process-contract-') do |root|
      @root = root
      @processes = []
      @states = {}
      @publications = {}
      begin
        example.run
      ensure
        @processes.reverse_each(&:close)
      end
    end
  end

  def peer(character, runtime: true)
    policy = { enabled: true, leaders: { 'Testleader' => { game: 'GS3', groups: {
      'Trio' => { profile: 'LocalHunt', refuge_room: 324, join_at_rally: true }
    } } } }
    process = HunterGroupProcessSupport::PeerProcess.new(root: @root, character: character,
                                                         runtime: runtime, policy: policy)
    @processes << process
    @states[process] = process.initial
    process
  end

  def cycle(peers, elapsed: 0.6)
    peers.each do |process|
      result = process.call('tick', elapsed: elapsed, records: @publications.values)
      @states[process] = result
      @publications[process] = result[:publication] if result[:publication]
    end
  end

  def until_phase(peers, leader, phase, limit: 40)
    limit.times do
      cycle(peers)
      return if @states.fetch(leader).dig(:runtime, :group, :phase) == phase.to_s
    end
    raise "did not reach #{phase}: #{@states.transform_values { |state| state.slice(:runtime, :logs) }}"
  end

  def start_trio
    directory = File.join(@root, 'profiles', 'GS3', 'Testleader', 'bigshot_profiles')
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'Trio.yaml'), YAML.dump('group_members' => %w[Testfollower Testsecond], 'resting_room_id' => 324))
    leader, first, second = %w[Testleader Testfollower Testsecond].map { |name| peer(name) }
    peers = [leader, first, second]
    cycle(peers)
    leader.call('enqueue', action: 'start', arguments: ['Trio'])
    [leader, first, second]
  end

  def client_for(leader, follower)
    leader_identity = @publications.fetch(leader).dig(:eohunter_group_start, :identity)
    receiver_identity = @publications.fetch(follower).dig(:eohunter_group_start, :identity)
    rendezvous = EO::HunterGroup::Rendezvous.new(root: @root, windows: false)
    grant = rendezvous.read(id: rendezvous.id(receiver: receiver_identity, leader: leader_identity),
                            receiver: receiver_identity, leader: leader_identity)
    grant = JSON.parse(JSON.generate(grant), symbolize_names: true)
    EO::Coordination::Operations::Client.new(descriptor: grant.fetch(:descriptor),
                                             control_token: grant.fetch(:control_token), local_identity: leader_identity)
  end

  it 'runs authentic prepare/commit/hunt grants across three processes and retains replay receipts' do
    leader, first, second = start_trio
    peers = [leader, first, second]
    expect(peers.map { |process| process.initial[:pid] }.uniq.size).to eq(3)
    expect(peers.map { |process| process.initial[:pid] }).not_to include(Process.pid)

    until_phase(peers, leader, :hunting)
    peers.each do |process|
      expect(@states.fetch(process)[:launches]).to eq(1)
      expect(@states.fetch(process)[:commands].first).to start_with('prepare', 'commit')
      expect(@states.fetch(process)[:journal]).not_to be_nil
    end

    client = client_for(leader, first)
    run_id = @states.fetch(leader).dig(:status, :run_id)
    before = client.result(request_id: "#{run_id}:prepare")
    duplicate = client.submit(request_id: "#{run_id}:prepare", operation: 'prepare', arguments: {
      run_id: run_id, group: 'Trio', members: %w[Testfollower Testsecond], refuge_room: 324,
      hub_uri: @states.fetch(leader).dig(:status, :hub_uri)
    })
    expect(before).to include(ok: true, payload: include(state: 'settled', outcome: 'succeeded'))
    expect(duplicate).to eq(before)
    changed = client.submit(request_id: "#{run_id}:prepare", operation: 'prepare', arguments: {
      run_id: run_id, group: 'Trio', members: %w[Testfollower Testsecond], refuge_room: 325,
      hub_uri: @states.fetch(leader).dig(:status, :hub_uri)
    })
    expect(changed).to include(ok: false, error: 'request_conflict')
    cycle(peers)
    expect(@states.fetch(first)[:launches]).to eq(1)

    # A safe child report is insufficient while that same native child still
    # owns teardown. The actual cancel receipt must remain unfinished.
    first.call('controls', teardown: false)
    leader.call('enqueue', action: 'stop')
    5.times { cycle(peers) }
    expect(@states.fetch(first).dig(:status, :report, :phase)).to eq('safe')
    expect(@states.fetch(first).dig(:status, :phase)).to eq('returning')
    expect(@states.fetch(leader).dig(:runtime, :group, :phase)).to eq('returning')
    expect(client.result(request_id: "#{run_id}:cancel")[:payload]).to include(state: 'running')
    expect(@states.fetch(first)[:journal]).not_to be_nil

    first.call('controls', teardown: true)
    until_phase(peers, leader, :safe)
    expect(client.result(request_id: "#{run_id}:cancel")[:payload]).to include(
      state: 'settled', outcome: 'succeeded', cleanup: 'complete'
    )
    %w[prepare commit hunt].each do |operation|
      expect(client.result(request_id: "#{run_id}:#{operation}")[:payload]).to include(cleanup: 'complete')
    end
    peers.each { |process| expect(@states.fetch(process)[:journal]).to be_nil }

    # The same persistent receivers must release every local slot and create
    # a new outing identity without needing a receiver restart or relog.
    leader.call('enqueue', action: 'start', arguments: ['Trio'])
    until_phase(peers, leader, :hunting)
    expect(@states.fetch(leader).dig(:status, :run_id)).not_to eq(run_id)
    peers.each { |process| expect(@states.fetch(process)[:launches]).to eq(2) }
    leader.call('enqueue', action: 'stop')
    until_phase(peers, leader, :safe)
    peers.each do |process|
      expect(@states.fetch(process)[:journal]).to be_nil
      expect(@states.fetch(process).dig(:status, :child_pending)).to be(false)
    end
  end

  it 'ends the outing on a lost required process and keeps that member unconfirmed across restart' do
    leader, first, second = start_trio
    peers = [leader, first, second]
    until_phase(peers, leader, :hunting)
    second.terminate

    12.times { cycle([leader, first], elapsed: 1) }
    expect(@states.fetch(leader).dig(:runtime, :group, :phase)).to eq('returning')
    expect(@states.fetch(leader).dig(:status, :phase)).to eq('safe')
    expect(@states.fetch(first).dig(:status, :phase)).to eq('safe')
    cycle([leader, first], elapsed: 181)
    expect(@states.fetch(leader).dig(:runtime, :group, :phase)).to eq('unresolved')

    restarted = peer('Testsecond')
    expect(restarted.initial[:status]).to include(phase: 'unresolved', reason: 'unreconciled previous outing')
    restarted.call('enqueue', action: 'start', arguments: ['Trio'])
    cycle([restarted])
    expect(@states.fetch(restarted)[:launches]).to eq(0)
    expect(@states.fetch(restarted)[:journal]).to include(profile: 'LocalHunt', hands: %w[sword shield])

    restarted.call('enqueue', action: 'recover', arguments: ['LocalHunt'])
    2.times { cycle([restarted]) }
    expect(@states.fetch(restarted)).to include(launches: 1, roles: ['recover'], commands: [['return']], journal: nil)
    expect(@states.fetch(restarted).dig(:status, :phase)).to eq('safe')
  end

  it 'starts exactly one recovery child only after the crashed native owner has finished teardown' do
    process = peer('Testfollower', runtime: false)
    identity = { game: 'GS3', character: 'Testleader', incarnation: 'leader-one', connection_generation: 0, run_id: 'outing-one' }
    process.call('prepare', run_id: 'outing-one', role: 'tail', profile: 'LocalHunt',
                 leader_identity: identity, members: %w[Testfollower], refuge_room: 324)
    process.call('tick')
    process.call('controls', teardown: false)
    result = process.call('crash', teardown: false)
    expect(result).to include(launches: 1, journal: include(run_id: 'outing-one'))
    expect(result[:status]).to include(phase: 'unresolved', child_pending: true)
    expect(process.call('tick')[:launches]).to eq(1)

    process.call('controls', teardown: true)
    result = process.call('tick')
    expect(result).to include(launches: 2, roles: %w[tail recover])
    expect(result[:status]).to include(phase: 'returning', child_pending: true)
    result = process.call('tick')
    expect(result[:status]).to include(phase: 'safe', child_pending: false)
    expect(result[:journal]).to be_nil
    expect(process.call('tick')[:launches]).to eq(2)
  end

  it 'does not let a fresh transport ticket revive an expired startup reservation' do
    leader, first, second = start_trio
    cycle([leader, first, second])
    client = client_for(leader, first)
    run_id = @states.fetch(leader).dig(:status, :run_id)
    first.call('advance', elapsed: 91)
    submitted = client.submit(request_id: "#{run_id}:prepare", operation: 'prepare', arguments: {
      run_id: run_id, group: 'Trio', members: %w[Testfollower Testsecond], refuge_room: 324,
      hub_uri: 'druby://127.0.0.1:12345'
    })
    expect(submitted[:ok]).to be(true)
    cycle([first])
    expect(@states.fetch(first)[:launches]).to eq(0)
    expect(@states.fetch(first)[:journal]).to be_nil
  end

  it 'preserves accepted return authority when participation is disabled mid-outing' do
    leader, first, second = start_trio
    peers = [leader, first, second]
    until_phase(peers, leader, :hunting)
    first.call('enqueue', action: 'disable')
    cycle(peers)
    expect(@states.fetch(first).dig(:runtime, :enabled)).to be(false)
    expect(@states.fetch(first).dig(:runtime, :autostart)).to eq('verified')
    expect(@states.fetch(first).dig(:status, :phase)).to eq('hunting')

    leader.call('enqueue', action: 'stop')
    until_phase(peers, leader, :safe)
    expect(@states.fetch(first).dig(:status, :phase)).to eq('safe')
    expect(@states.fetch(first)[:journal]).to be_nil
  end

  it 'detects a stalled hunter even while its receiver keeps publishing fresh heartbeats' do
    leader, first, second = start_trio
    peers = [leader, first, second]
    until_phase(peers, leader, :hunting)
    first.call('controls', stalled: true)
    first_sequence = @publications.fetch(first).dig(:eohunter_group_start, :sequence)
    32.times { cycle(peers, elapsed: 4) }
    expect(@publications.fetch(first).dig(:eohunter_group_start, :sequence)).to be > first_sequence
    expect(@states.fetch(first).dig(:status, :phase)).to eq('returning')
    expect(@states.fetch(first).dig(:status, :reason)).to include('stopped completing turns')
    expect(@states.fetch(leader).dig(:runtime, :group, :phase)).to eq('returning')
    expect(@states.fetch(first)[:journal]).not_to be_nil
  end
end
