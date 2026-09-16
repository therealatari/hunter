# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../../../scripts/eohunter/setup/store'

RSpec.describe EO::HunterSetup::Store do
  around do |example|
    Dir.mktmpdir('hunter-store') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:root) { File.join(@directory, 'eohunter') }
  let(:legacy) { File.join(@directory, 'bigshot_profiles') }
  let(:store) { described_class.new(root: root, legacy_root: legacy) }

  def write_legacy(name, contents)
    FileUtils.mkdir_p(legacy)
    File.write(File.join(legacy, "#{name}.yaml"), contents)
  end

  it 'keeps native profiles, defaults and plans separate without creating directories while browsing' do
    expect(store.list(:profiles)).to eq([])
    expect(File.exist?(root)).to be(false)
    %i[profiles defaults plans].each do |kind|
      store.save(kind, 'Usual combat', { 'kind' => kind.to_s }, expected_revision: nil)
      expect(store.list(kind)).to eq(['Usual combat'])
      expect(store.read(kind, 'Usual combat')[:data]).to eq('kind' => kind.to_s)
    end
  end

  it 'treats an unconfigured legacy catalog as empty without hiding missing explicit reads' do
    native_only = described_class.new(root: root)
    expect(native_only.list(:profiles, source: :legacy)).to eq([])
    expect { native_only.read(:profiles, 'missing', source: :legacy) }.to raise_error(described_class::NotFound)
  end

  it 'round trips unknown extension values and explicit false, empty lists and null' do
    data = { 'future_extension' => { 'list' => [1, 'two'], 'enabled' => false }, 'empty' => [], 'unset' => nil }
    saved = store.save(:profiles, 'forest', data, expected_revision: nil)
    expect(store.read(:profiles, 'forest')).to eq(saved)
    expect(saved[:data]).to eq(data)
    expect(saved).to include(name: 'forest', kind: 'profiles', source: :native)
  end

  it 'replaces a document with revision checking and allows override removal' do
    first = store.save(:profiles, 'forest', { 'enabled' => false, 'override' => [] }, expected_revision: nil)
    second = store.save(:profiles, 'forest', { 'enabled' => true }, expected_revision: first[:revision])
    expect(second[:revision]).not_to eq(first[:revision])
    expect(second[:data]).to eq('enabled' => true)
    expect { store.save(:profiles, 'forest', {}, expected_revision: first[:revision]) }.to raise_error(described_class::Conflict)
    expect { store.save(:profiles, 'forest', {}, expected_revision: nil) }.to raise_error(described_class::Conflict)
    expect(store.read(:profiles, 'forest')).to eq(second)
  end

  it 'detects external content changes even when the parsed data stays the same' do
    first = store.save(:profiles, 'forest', { 'enabled' => true }, expected_revision: nil)
    File.open(File.join(root, 'profiles', 'forest.yaml'), 'a') { |file| file.write("# external edit\n") }
    expect { store.save(:profiles, 'forest', {}, expected_revision: first[:revision]) }.to raise_error(described_class::Conflict)
  end

  it 'serializes competing updates so exactly one expected revision succeeds' do
    first = store.save(:profiles, 'forest', { 'value' => 0 }, expected_revision: nil)
    results = 2.times.map do |index|
      Thread.new do
        begin
          store.save(:profiles, 'forest', { 'value' => index + 1 }, expected_revision: first[:revision])
          :saved
        rescue described_class::Conflict
          :conflict
        end
      end
    end.map(&:value)
    expect(results.sort).to eq(%i[conflict saved])
  end

  it 'keeps the previous document intact if atomic replacement cannot complete' do
    first = store.save(:profiles, 'forest', { 'value' => 'original' }, expected_revision: nil)
    allow(File).to receive(:rename).and_raise(Errno::EACCES)
    expect { store.save(:profiles, 'forest', { 'value' => 'replacement' }, expected_revision: first[:revision]) }.to raise_error(Errno::EACCES)
    expect(File).to have_received(:rename).exactly(3).times
    expect(store.read(:profiles, 'forest')).to eq(first)
    expect(Dir.children(File.join(root, 'profiles')).sort).to eq(['.write.lock', 'forest.yaml'])
  end

  it 'imports into native storage, preserves legacy bytes, and refuses destination collisions' do
    contents = "---\nhunting_commands: attack\nfuture_extension: false\n"
    write_legacy('forest', contents)
    expect { store.read(:profiles, 'forest') }.to raise_error(described_class::NotFound)
    expect(store.list(:profiles, source: :legacy)).to eq(['forest'])
    expect(store.read(:profiles, 'forest', source: :legacy)[:source]).to eq(:legacy)
    imported = store.import('forest')
    expect(imported[:data]).to eq('hunting_commands' => 'attack', 'future_extension' => false)
    expect(imported[:source]).to eq(:native)
    expect(File.read(File.join(legacy, 'forest.yaml'))).to eq(contents)
    expect { store.import('forest') }.to raise_error(described_class::Conflict)
    expect(store.import('forest', as: 'forest copy')[:name]).to eq('forest copy')
    expect(File.read(File.join(legacy, 'forest.yaml'))).to eq(contents)
  end

  it 'rejects unsafe names, kinds and legacy access outside profiles' do
    ['../forest', '/tmp/forest', 'a/b', 'a\\b', '.hidden', 'a..b', "a\n", 'a' * 81].each do |name|
      expect { store.save(:profiles, name, {}, expected_revision: nil) }.to raise_error(described_class::InvalidName)
    end
    expect { store.list('../ecleanse') }.to raise_error(described_class::InvalidName)
    expect { store.list(:defaults, source: :legacy) }.to raise_error(described_class::InvalidName)
    expect { store.list(:profiles, source: :automatic) }.to raise_error(described_class::InvalidName)
    expect(File.exist?(root)).to be(false)
  end

  it 'rejects overlapping native and legacy ownership roots' do
    [legacy, @directory, File.join(legacy, 'native')].each do |overlap|
      expect { described_class.new(root: overlap, legacy_root: legacy) }.to raise_error(described_class::InvalidName)
    end
  end

  it 'rejects symlink documents and symlink destination directories' do
    write_legacy('original', "---\nvalue: unchanged\n")
    FileUtils.mkdir_p(root)
    File.symlink(legacy, File.join(root, 'profiles'))
    expect { store.save(:profiles, 'original', {}, expected_revision: nil) }.to raise_error(described_class::InvalidName)
    expect(File.read(File.join(legacy, 'original.yaml'))).to include('unchanged')
    FileUtils.mkdir_p(File.join(root, 'plans'))
    File.symlink(File.join(legacy, 'original.yaml'), File.join(root, 'plans', 'linked.yaml'))
    expect { store.read(:plans, 'linked') }.to raise_error(described_class::InvalidName)
    expect(store.list(:plans)).to eq([])
  end

  it 'rejects executable objects, aliases, malformed YAML, and non-mapping documents' do
    ["--- !ruby/object:Object {}\n", "---\na: &a []\nb: *a\n", "---\na: [\n", "---\n- one\n", ''].each do |contents|
      write_legacy('bad', contents)
      expect { store.import('bad') }.to raise_error(described_class::InvalidData)
    end
    expect(File.exist?(root)).to be(false)
  end

  it 'accepts old symbol keys without unsafe object loading' do
    write_legacy('symbols', YAML.dump({ enabled: false }))
    expect(store.import('symbols')[:data]).to eq('enabled' => false)
  end

  it 'opens and imports legacy numeric spell keys without modifying the original' do
    contents = YAML.dump('combat_buffs' => { 'enabled' => true, 'spells' => { 101 => { 'action' => 'recast', 'required' => true } } })
    write_legacy('buffs', contents)
    expected = { 'combat_buffs' => { 'enabled' => true, 'spells' => { '101' => { 'action' => 'recast', 'required' => true } } } }
    expect(store.read(:profiles, 'buffs', source: :legacy)[:data]).to eq(expected)
    expect(store.import('buffs')[:data]).to eq(expected)
    expect(store.read(:profiles, 'buffs')[:data]).to eq(expected)
    expect(File.read(File.join(legacy, 'buffs.yaml'))).to eq(contents)
  end

  it 'rejects numeric and string key collisions rather than losing a rule' do
    write_legacy('collision', YAML.dump('spells' => { 101 => 'recast', '101' => 'ignore' }))
    expect { store.read(:profiles, 'collision', source: :legacy) }.to raise_error(described_class::InvalidData, /duplicate mapping key/)
  end

  it 'continues to reject ambiguous boolean and compound mapping keys' do
    [true, nil, 1.5, ['spell']].each do |key|
      write_legacy('invalid-key', YAML.dump({ key => 'value' }))
      expect { store.read(:profiles, 'invalid-key', source: :legacy) }.to raise_error(described_class::InvalidData, /mapping keys/)
    end
  end

  it 'bounds input sizes and rejects unserializable or recursive values before writing' do
    [{ 'object' => Object.new }, { 'number' => Float::INFINITY }, { 'text' => 'a' * described_class::MAX_BYTES }].each do |data|
      expect { store.save(:profiles, 'bad', data, expected_revision: nil) }.to raise_error(described_class::InvalidData)
    end
    recursive = {}
    recursive['self'] = recursive
    expect { store.save(:profiles, 'bad', recursive, expected_revision: nil) }.to raise_error(described_class::InvalidData)
    expect(File.exist?(root)).to be(false)
  end
end
