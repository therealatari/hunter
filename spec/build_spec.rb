# frozen_string_literal: true

require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../tools/build'

RSpec.describe EOHunter::Build do
  let(:root) { File.expand_path('..', __dir__) }
  let(:result) { described_class.build(root: root, sha: 'abc1234') }
  let(:built) { result.source }
  let(:parts) { described_class.parts_of(File.read(File.join(root, 'scripts/eohunter/engine.rb'))) }

  it 'is valid Ruby' do
    expect { RubyVM::InstructionSequence.compile(built, 'eohunter.lic') }.not_to raise_error
  end

  it 'keeps the script header, the constant check and the tail around the inlined engine' do
    expect(built).to start_with("=begin\n")
    expect(built).to include("install the eohunter test package")
    # the script's own tail after the inlined parts: the run path, not a
    # literal last line, which moves whenever the teardown changes
    expect(built).to include("  engine.run\n")
    expect(built).to end_with("end\n")
    expect(built.lines.map(&:chomp)).not_to include(described_class::LOAD_LINE)
  end

  it 'inlines engine.rb and every part in load order, each behind a marker the map points at' do
    # split once: built.lines re-splits the whole ~17k-line string on every
    # call, and calling it inside the index scan made this example alone
    # 19 of the suite's 20 seconds
    lines = built.lines
    markers = lines.each_index.select { |i| lines[i].start_with?('# ==== ') }.map { |i| lines[i].chomp }
    expect(markers).to eq(['# ==== eohunter/engine.rb ===='] + parts.map { |p| "# ==== eohunter/#{p}.rb ====" } + ['# ==== eohunter.lic ===='])
    parts.each do |part|
      first, last = result.sections.fetch("eohunter/#{part}.rb")
      body = lines[(first - 1)...last].join
      source = described_class.strip_pragma(File.read(File.join(root, "scripts/eohunter/#{part}.rb")).gsub("\r\n", "\n"))
      source = described_class.setup_source(source, part) if part.start_with?('setup/')
      expect(body).to eq(source.sub(/\n*\z/, "\n"))
    end
  end

  it 'replaces the disk loader with a no-op and records the commit' do
    expect(built).not_to match(/^EO::Engine\.load_parts$/)
    expect(built).to include("BUILT_FROM = \"abc1234\".freeze")
    expect(built).to include('def self.load_parts(_dir = nil) = true')
    expect(built).to include('::EO.send(:remove_const, :Engine) if defined?(::EO::Engine)')
    expect(built.scan('# frozen_string_literal: true')).to be_empty
  end

  it 'defines the same modules and classes as the parts' do
    names = ->(src) { src.scan(/^\s*(?:module|class) (?:::)?([A-Z][\w:]*)/).flatten.sort }
    from_parts = parts.flat_map { |p| names.call(File.read(File.join(root, "scripts/eohunter/#{p}.rb"))) }.sort
    expect(names.call(built)).to include(*from_parts)
  end

  it 'writes the file and its map' do
    Dir.mktmpdir do |dir|
      out = File.join(dir, 'dist', 'eohunter.lic')
      expect(described_class.write(root: root, out: out, sha: 'abc1234')).to eq(out)
      expect(File.read(out, mode: 'rb')).to eq(built)
      map = File.read("#{out}.map")
      expect(map.lines.size).to eq(parts.size + 1)
      expect(map).to match(/^eohunter\/engine\.rb\s+\d+\s+\d+$/)
    end
  end

  # The CLI had no flag parsing: every first argument was expanded into an
  # output path, so `build.rb --check` wrote a file literally named
  # "--check" into the repo root.
  describe 'the command line' do
    def run_build(*args, dir:)
      Open3.capture3(RbConfig.ruby, File.join(root, 'tools', 'build.rb'), *args, chdir: dir)
    end

    it 'checks without writing anything' do
      Dir.mktmpdir do |dir|
        out, _err, status = run_build('--check', dir: dir)
        expect(status).to be_success
        expect(out).to match(/nothing written/)
        expect(Dir.children(dir)).to be_empty
      end
    end

    it 'does not turn a flag into a file name' do
      Dir.mktmpdir do |dir|
        run_build('--check', dir: dir)
        expect(File.exist?(File.join(root, '--check'))).to be false
        expect(File.exist?(File.join(dir, '--check'))).to be false
      end
    end

    it 'refuses an unknown flag instead of writing to it' do
      Dir.mktmpdir do |dir|
        _out, err, status = run_build('--nope', dir: dir)
        expect(status).not_to be_success
        expect(err).to include('unknown option')
        expect(Dir.children(dir)).to be_empty
      end
    end

    it 'still writes to a named path' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'out.lic')
        _out, _err, status = run_build(target, dir: dir)
        expect(status).to be_success
        expect(File.exist?(target)).to be true
      end
    end
  end
end
