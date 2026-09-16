# frozen_string_literal: true

require_relative '../spec_helper'
require 'tmpdir'
require_relative '../../scripts/eohunter_group/rendezvous'

RSpec.describe EO::HunterGroup::Rendezvous do
  around do |example|
    Dir.mktmpdir('hunter-rendezvous-') do |directory|
      @root = File.join(directory, 'group')
      example.run
    end
  end
  let(:receiver) { { game: 'GS3', character: 'Testfollower', incarnation: 'receiver-1', connection_generation: 0, run_id: 'run-1' } }
  let(:leader) { receiver.merge(character: 'Testleader', incarnation: 'leader-1') }
  let(:grant) { { descriptor: { port: 1234 }, control_token: 'private-secret' } }
  subject(:store) { described_class.new(root: @root, windows: false) }

  def publish
    store.publish(receiver: receiver, leader: leader, grant: grant)
  end

  it 'creates and closes a private immutable file before returning an opaque lookup id' do
    key = publish
    expect(key).to match(/\A[0-9a-f]{64}\z/)
    expect(key).to eq(store.id(receiver: receiver, leader: leader))
    expect(key).not_to include('private-secret')
    filename = File.join(@root, "#{key}.json")
    expect(File.stat(@root).mode & 0o777).to eq(0o700)
    expect(File.stat(filename).mode & 0o777).to eq(0o600)
    independent = described_class.new(root: @root, windows: false)
    expect(independent.read(id: key, receiver: receiver, leader: leader)).to eq('descriptor' => { 'port' => 1234 }, 'control_token' => 'private-secret')
    expect { publish }.to raise_error(Errno::EEXIST)
    expect(independent.remove(id: key)).to be(false)
    expect(File.exist?(filename)).to be(true)
    expect(store.remove(id: key)).to be(true)
  end

  it 'rejects stale receiver or leader connection identities' do
    key = publish
    expect { store.read(id: key, receiver: receiver.merge(incarnation: 'receiver-2'), leader: leader) }.to raise_error(described_class::Invalid)
    expect { store.read(id: key, receiver: receiver, leader: leader.merge(connection_generation: 1)) }.to raise_error(described_class::Invalid)
  end

  it 'rejects arbitrary paths and malformed identity fields' do
    expect { store.read(id: '../../secret', receiver: receiver, leader: leader) }.to raise_error(described_class::Invalid)
    expect { store.id(receiver: receiver.merge(incarnation: '../bad'), leader: leader) }.to raise_error(described_class::Invalid)
    expect { store.id(receiver: receiver.merge(connection_generation: '0'), leader: leader) }.to raise_error(described_class::Invalid)
  end

  it 'bounds credential payloads before creating availability' do
    expect { store.publish(receiver: receiver, leader: leader, grant: { control_token: 'a' * 16_384 }) }.to raise_error(described_class::Invalid, /too large/)
    expect(File.exist?(@root)).to be(false)
  end

  it 'defers a Windows sharing violation and retries only its owned file' do
    calls = 0
    unlink = lambda do |path|
      calls += 1
      raise Errno::EACCES if calls == 1
      File.unlink(path)
    end
    owner = described_class.new(root: @root, windows: false, unlink: unlink)
    key = owner.publish(receiver: receiver, leader: leader, grant: grant)
    expect(owner.remove(id: key)).to be(false)
    expect(store.read(id: key, receiver: receiver, leader: leader)).to include('control_token')
    owner.cleanup
    expect(File.exist?(File.join(@root, "#{key}.json"))).to be(false)
    expect(calls).to eq(2)
  end

  it 'requires verified Windows privacy rather than assuming mode bits establish an ACL' do
    verifier = instance_double(EO::HunterGroup::WindowsPrivacy)
    allow(EO::HunterGroup::WindowsPrivacy).to receive(:new).and_return(verifier)
    allow(verifier).to receive(:call).and_return(false)
    unverified = described_class.new(root: @root, windows: true)
    expect { unverified.publish(receiver: receiver, leader: leader, grant: grant) }.to raise_error(described_class::Invalid, /private/)
    checked = []
    verified = described_class.new(root: @root, windows: true, privacy_check: ->(path) { checked << path; true })
    key = verified.publish(receiver: receiver, leader: leader, grant: grant)
    expect(checked).to contain_exactly(@root, File.join(@root, "#{key}.json"))
  end

  it 'passes Windows paths as data and bounds a hung ACL verifier' do
    path = 'C:\\Users\\Player\\$(untrusted); group'
    verifier = EO::HunterGroup::WindowsPrivacy.new(timeout: 0.05)
    waiter = double('process waiter')
    expect(Process).to receive(:spawn).with(
      { 'EOHUNTER_PRIVATE_PATH' => path, 'EOHUNTER_PRIVATE_CREATE' => '1' },
      'powershell.exe', '-NoProfile', '-NonInteractive', '-Command', EO::HunterGroup::WindowsPrivacy::PROGRAM,
      in: File::NULL, out: File::NULL, err: File::NULL
    ).and_return(99)
    expect(Process).to receive(:detach).with(99).and_return(waiter)
    expect(waiter).to receive(:join).with(0.05).and_return(nil)
    expect(Process).to receive(:kill).with('KILL', 99)
    expect(waiter).to receive(:join).with(0.25)
    expect(verifier.call(path, create: true)).to be(false)
    expect(EO::HunterGroup::WindowsPrivacy::PROGRAM).not_to include(path)
  end

  it 'rejects permissive directories and symlink files' do
    FileUtils.mkdir_p(@root, mode: 0o755)
    expect { publish }.to raise_error(described_class::Invalid, /private/)
    File.chmod(0o700, @root)
    key = publish
    original = File.join(@root, "#{key}.json")
    target = File.join(@root, 'target.json')
    File.rename(original, target)
    File.symlink(target, original)
    expect { store.read(id: key, receiver: receiver, leader: leader) }.to raise_error(described_class::Invalid)
  end

  it 'blocks restart across process incarnations until explicit matching safe confirmation' do
    journal = EO::HunterGroup::RunJournal.new(root: @root, game: 'GS3', character: 'Testfollower', windows: false)
    expect(journal.pending).to be_nil
    journal.record(run_id: 'outing-1', leader: leader, refuge_room: 324)
    restarted = EO::HunterGroup::RunJournal.new(root: @root, game: 'GS3', character: 'Testfollower', windows: false)
    expect(restarted.pending).to include('run_id' => 'outing-1', 'refuge_room' => 324)
    expect { restarted.record(run_id: 'outing-2', leader: leader, refuge_room: 324) }.to raise_error(Errno::EEXIST)
    expect { restarted.clear(run_id: 'outing-1', safe: false) }.to raise_error(described_class::Invalid)
    expect { restarted.clear(run_id: 'outing-2', safe: true) }.to raise_error(described_class::Invalid)
    expect(restarted.clear(run_id: 'outing-1', safe: true)).to be(true)
    expect(journal.pending).to be_nil
  end

  it 'keeps an unresolved journal blocking when cleanup cannot finish' do
    journal = EO::HunterGroup::RunJournal.new(root: @root, game: 'GS3', character: 'Testfollower', windows: false,
                                              unlink: ->(_path) { raise Errno::EACCES })
    journal.record(run_id: 'outing-1', leader: leader, refuge_room: 324)
    expect(journal.clear(run_id: 'outing-1', safe: true)).to be(false)
    expect(journal.pending).to include('run_id' => 'outing-1')
  end

  it 'persists original recovery evidence immutably across receiver restarts' do
    journal = EO::HunterGroup::RunJournal.new(root: @root, game: 'GS3', character: 'Testfollower', windows: false)
    journal.record(run_id: 'outing-1', leader: leader, refuge_room: 324)
    evidence = { run_id: 'outing-1', profile: 'Local Trio', settings: { 'resting_room_id' => 324 }, hands: { right: 'sword', left: nil } }
    expect(journal.record_evidence(**evidence)).to be(true)
    expect(journal.record_evidence(**evidence)).to be(true)
    restarted = EO::HunterGroup::RunJournal.new(root: @root, game: 'GS3', character: 'Testfollower', windows: false)
    expect(restarted.pending).to include('profile' => 'Local Trio', 'settings' => { 'resting_room_id' => 324 }, 'hands' => { 'right' => 'sword', 'left' => nil })
    expect { restarted.record_evidence(**evidence.merge(hands: { right: 'other' })) }.to raise_error(described_class::Invalid, /cannot change/)
    expect(restarted.clear(run_id: 'outing-1', safe: true)).to be(true)
    expect(Dir.children(File.join(@root, 'unresolved'))).to be_empty
  end

  it 'retains the safety hold when evidence is oversized or for a stale run' do
    journal = EO::HunterGroup::RunJournal.new(root: @root, game: 'GS3', character: 'Testfollower', windows: false)
    journal.record(run_id: 'outing-1', leader: leader, refuge_room: 324)
    evidence = { run_id: 'outing-1', profile: 'Local', settings: { 'large' => 'a' * 65_536 }, hands: {} }
    expect { journal.record_evidence(**evidence) }.to raise_error(described_class::Invalid, /too large/)
    expect { journal.record_evidence(**evidence.merge(run_id: 'outing-2', settings: {})) }.to raise_error(described_class::Invalid, /another run/)
    expect(journal.pending).to include('run_id' => 'outing-1')
    expect(journal.pending).not_to have_key('settings')
    expect(Dir.children(File.join(@root, 'unresolved')).size).to eq(1)
  end

  it 'retains the journal and evidence when Windows blocks evidence cleanup' do
    journal = EO::HunterGroup::RunJournal.new(root: @root, game: 'GS3', character: 'Testfollower', windows: false,
                                              unlink: ->(_path) { raise Errno::EACCES })
    journal.record(run_id: 'outing-1', leader: leader, refuge_room: 324)
    journal.record_evidence(run_id: 'outing-1', profile: 'Local', settings: {}, hands: {})
    expect(journal.clear(run_id: 'outing-1', safe: true)).to be(false)
    expect(journal.pending).to include('run_id' => 'outing-1', 'settings' => {})
  end

  it 'creates, reads and removes files with actual Windows ACL verification' do
    skip 'requires native Windows PowerShell and NTFS ACLs' unless Gem.win_platform?

    native = described_class.new(root: @root)
    key = native.publish(receiver: receiver, leader: leader, grant: grant)
    expect(EO::HunterGroup::WindowsPrivacy.new(timeout: 1.5).call(@root)).to be(true)
    independent = described_class.new(root: @root)
    expect(independent.read(id: key, receiver: receiver, leader: leader)).to include('control_token' => 'private-secret')
    expect(independent.remove(id: key)).to be(false)
    expect(native.remove(id: key)).to be(true)
    expect(File.exist?(File.join(@root, "#{key}.json"))).to be(false)

    journal = EO::HunterGroup::RunJournal.new(root: @root, game: 'GS3', character: 'Testfollower')
    journal.record(run_id: 'outing-native', leader: leader, refuge_room: 324)
    journal.record_evidence(run_id: 'outing-native', profile: 'Local', settings: {}, hands: {})
    expect(journal.pending).to include('run_id' => 'outing-native', 'settings' => {})
    expect(journal.clear(run_id: 'outing-native', safe: true)).to be(true)
  ensure
    native&.cleanup
  end
end
