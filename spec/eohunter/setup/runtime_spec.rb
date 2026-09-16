# frozen_string_literal: true

require 'tmpdir'
require_relative '../engine_helper'
require_relative '../../../scripts/eohunter/setup/runtime'
EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

RSpec.describe EO::HunterSetup::Runtime do
  around { |example| Dir.mktmpdir('setup-runtime') { |dir| @dir = dir; example.run } }

  def app
    allow(EO::HunterSetup::Server).to receive(:new) { |app:| app }
    described_class.server(data_dir: @dir, game: 'TEST', character: 'Fixture', char_settings: { 'cleanse_poison' => true },
                           templates: [], rooms: [Struct.new(:id).new(1), Struct.new(:id).new(2)],
                           uid_resolver: ->(uid) { uid == 101 ? [1] : [] })
  end

  let(:raw) do
    { 'hunting_room_id' => 'u101', 'resting_room_id' => '2', 'hunting_boundaries' => '2',
      'targets' => 'kobold', 'hunting_commands' => 'attack target' }
  end

  it 'validates UID-backed profiles against the supplied map without creating files' do
    result = app.call('action' => 'validate', 'data' => raw)
    expect(result[:errors]).to eq([])
    expect(result[:missing]).to eq([])
    expect(result[:ready]).to be(true)
    expect(Dir.children(@dir)).to eq([])
  end

  it 'does not report absent numeric map rooms as ready' do
    result = app.call('action' => 'validate', 'data' => raw.merge('hunting_room_id' => '999'))
    expect(result[:ready]).to be(false)
    expect(result[:missing]).to include(include('key' => 'hunting_room_id', 'message' => /absent/))
  end

  it 'reports effective recovery with explicit overrides rather than only the legacy fallback' do
    result = app.call('action' => 'validate', 'data' => raw.merge('recovery' => { 'cleanse_poison' => false }))
    expect(result[:recovery_fallback]['cleanse_poison']).to be(true)
    expect(result[:effective_recovery][:cleanse_poison]).to be(false)
    expect(result[:effective_recovery][:troubadours_rally]).to be(false)
  end

  it 'reuses an active engine without loading any source files' do
    engine = EO::Engine
    profile = EO::Engine::Profile
    expect(described_class).not_to receive(:load)
    described_class.load_support('/not-installed')
    expect(EO::Engine).to equal(engine)
    expect(EO::Engine::Profile).to equal(profile)
  end

  it 'prefers an available host browser helper without also launching a desktop opener' do
    host = Object.new
    host.define_singleton_method(:open_url) { |_url| true }
    expect(Process).not_to receive(:spawn)
    expect(described_class.open_browser('http://127.0.0.1:123/', host: host)).to be(true)
  end

  it 'opens the Linux default browser with an intact URL argument and reaps the launcher' do
    url = 'http://127.0.0.1:123/#token=abc&not_a_shell_command'
    expect(Process).to receive(:spawn).with('xdg-open', url, out: File::NULL, err: File::NULL).and_return(123)
    expect(Process).to receive(:detach).with(123)
    expect(described_class.open_browser(url, host: Object.new, platform: 'linux')).to be(true)
  end

  it 'uses the macOS default-browser opener when no host helper accepts the request' do
    host = Object.new
    host.define_singleton_method(:open_url) { |_url| false }
    url = 'http://127.0.0.1:123/'
    expect(Process).to receive(:spawn).with('/usr/bin/open', url, out: File::NULL, err: File::NULL).and_return(124)
    expect(Process).to receive(:detach).with(124)
    expect(described_class.open_browser(url, host: host, platform: 'darwin')).to be(true)
  end

  it 'reuses Lich ShellExecute on Windows without invoking a command shell' do
    native = stub_const('Win32', Class.new)
    url = 'http://127.0.0.1:123/#token=abc'
    expect(native).to receive(:ShellExecute).with(lpOperation: 'open', lpFile: url, nShowCmd: 1).and_return(33)
    expect(Process).not_to receive(:spawn)
    expect(described_class.open_browser(url, host: Object.new, platform: 'mingw')).to be(true)
  end

  it 'leaves manual opening available when the Windows opener reports an error' do
    native = stub_const('Win32', Class.new)
    allow(native).to receive(:ShellExecute).and_return(31)
    expect(described_class.open_browser('http://127.0.0.1:123/', host: Object.new, platform: 'mingw')).to be(false)
  end

  it 'leaves manual opening available when no desktop opener can be spawned' do
    allow(Process).to receive(:spawn).and_raise(Errno::ENOENT)
    expect(Process).not_to receive(:detach)
    expect(described_class.open_browser('http://127.0.0.1:123/', host: Object.new, platform: 'linux')).to be(false)
  end
end
