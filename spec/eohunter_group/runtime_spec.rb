# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../scripts/eocoordination/protocol'
require_relative '../../scripts/eohunter_group/settings'
require_relative '../../scripts/eohunter_group/rendezvous'
require_relative '../../scripts/eohunter_group/supervisor'
require_relative '../../scripts/eohunter_group/coordinator'
require_relative '../../scripts/eohunter_group/runtime'

RSpec.describe EO::HunterGroup::Runtime do
  let(:scripts) { double('native scripts', current: Object.new, list: []) }
  let(:policy) { EO::HunterGroup::Policy.new }
  let(:settings) { double('settings', policy: policy) }
  let(:discovery) { double('discovery', query_snapshot: { source: 'ActiveSessionsAPI', sessions: [] }, register_session: true) }
  let(:journal) { double('journal', pending: nil) }
  let(:runtime) do
    described_class.new(scripts: scripts, settings: settings, discovery: discovery,
                        game: 'GS3', character: 'Follower', root: '/unused', journal: journal,
                        rendezvous: double('rendezvous', cleanup: nil), connection: -> { true }, room: -> { 324 }, log: ->(_message) {})
  end

  it 'remains inert when disabled and refuses unknown local commands' do
    expect(EO::Coordination::Operations::Grant).not_to receive(:new)
    expect(scripts).not_to receive(:start_child)
    runtime.tick
    expect(runtime.status[:enabled]).to be(false)
    expect { runtime.enqueue(:eval, 'anything') }.to raise_error(/unknown local/)
  end

  it 'routes local stop to the current follower after an old leader outing finished' do
    old = double('old coordinator', finished?: true)
    current = runtime.instance_variable_get(:@supervisor)
    runtime.instance_variable_set(:@coordinator, old)
    expect(old).not_to receive(:cancel)
    expect(current).to receive(:cancel)
    runtime.enqueue(:stop)
    runtime.send(:consume_local)
  end

  it 'rejects native duplicate characters even when one has no receiver metadata' do
    identity = { game: 'GS3', character: 'Leader', run_id: 'run', incarnation: 'one', connection_generation: 0 }
    metadata = { protocol: 1, identity: identity }
    native = { pid: 1, session_name: 'Leader', game_code: 'GS3', connected: true }
    allow(discovery).to receive(:query_snapshot).and_return(source: 'ActiveSessionsAPI', sessions: [
                                                              native.merge(eohunter_group_start: metadata), native.merge(pid: 2)
                                                            ])
    expect(runtime.send(:discover)).to eq([])
  end

  it 'clears the stable runtime slot if the initial command is invalid' do
    module_api = EO::HunterGroup
    stub_const('Script', double('Script', current: double('owner', join: nil), loadlib: true, start_child: nil))
    stub_const('XMLData', double('XMLData', game: 'GS3', name: 'Follower'))
    stub_const('DATA_DIR', '/unused')
    stub_const('Lich::InternalAPI::ActiveSessions', Object.new)
    allow(EO::Coordination).to receive(:require_version)
    allow(EO::HunterGroup::Settings).to receive(:new).and_return(settings)
    failed = double('runtime', close: nil)
    allow(failed).to receive(:enqueue).and_raise(ArgumentError, 'unknown local group command')
    allow(described_class).to receive(:new).and_return(failed)
    module_api.instance_variable_set(:@runtime, nil)
    expect { module_api.run_receiver(['invalid']) }.to raise_error(ArgumentError, /unknown local/)
    expect(failed).to have_received(:close)
    expect(module_api.instance_variable_get(:@runtime)).to be_nil
  ensure
    module_api&.instance_variable_set(:@runtime, nil)
  end
end
