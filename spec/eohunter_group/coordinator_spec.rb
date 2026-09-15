# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../scripts/eocoordination/protocol'
require_relative '../../scripts/eohunter_group/coordinator'

RSpec.describe EO::HunterGroup::Coordinator do
  let(:identity) { { game: 'GS3', character: 'Leader', run_id: 'outing', incarnation: 'leader-session', connection_generation: 0 } }
  let(:peer_identity) { identity.merge(character: 'Follower', incarnation: 'follower-session') }
  let(:supervisor) { double('local supervisor', prepare: nil, cancel: nil, status: { phase: :safe }) }
  let(:rendezvous) { double('rendezvous', id: 'grant', read: {}) }
  let(:receipt) { { ok: true, payload: { state: 'settled', outcome: 'succeeded' } } }
  let(:client) { double('exact operation client', submit: receipt, result: receipt) }
  let(:coordinator) do
    described_class.new(identity: identity, group: 'Trio', profile: 'Local', members: ['Follower'],
                        refuge_room: 324, peers: [{ identity: peer_identity, sequence: 1 }], supervisor: supervisor,
                        rendezvous: rendezvous, clock: -> { 1.0 }, client_factory: ->(*) { client })
  end

  def discovery(phase)
    [{ identity: peer_identity, sequence: 2, status: { run_id: 'outing', phase: phase } }]
  end

  it 'displays the confirmed safe receipt instead of an older returning advertisement' do
    coordinator.cancel
    result = coordinator.tick(discovery(:returning))

    expect(result).to include(phase: :safe, members: { 'Follower' => :safe })
    expect(client).to have_received(:submit).with(request_id: 'outing:cancel', operation: 'cancel', arguments: { run_id: 'outing' })
    expect(coordinator.tick([])).to eq(result)
  end

  it 'does not declare the outing safe from a safe advertisement without its receipt' do
    receipt[:payload] = { state: 'running' }
    coordinator.cancel

    expect(coordinator.tick(discovery(:safe))[:phase]).to eq(:returning)
    expect(coordinator.finished?).to be false
  end

  it 'keeps failed return receipts unresolved in the member display' do
    receipt[:payload] = { state: 'settled', outcome: 'failed' }
    coordinator.cancel

    expect(coordinator.tick(discovery(:returning))).to include(phase: :returning, members: { 'Follower' => :unresolved })
  end
end
