# frozen_string_literal: true

require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../tools/build_hunter_group'
require_relative '../tools/build_coordination'

RSpec.describe EOHunter::GroupBuild do
  let(:root) { File.expand_path('..', __dir__) }

  it 'builds the optional library as syntax-valid standalone Ruby' do
    built = described_class.build(root: root, sha: 'fixture')
    expect { RubyVM::InstructionSequence.compile(built.source) }.not_to raise_error
    expect(built.source).not_to match(/^require_relative /)
    expect(built.source).not_to include('# BEGIN SOURCE PARTS')
    expect(built.sections).not_to be_empty
  end

  it 'loads the flat libraries with no source tree, game runtime or new worker' do
    Dir.mktmpdir do |dir|
      coordination = EOCoordination::Build.write(root: root, out: File.join(dir, 'libeocoordination.lic'))
      group = described_class.write(root: root, out: File.join(dir, 'libeohuntergroup.lic'))
      program = <<~'RUBY'
        before = Thread.list
        ARGV.each { |path| load path }
        abort 'started worker on library load' unless Thread.list == before
        abort 'loaded hunting engine' if defined?(EO::Engine)
        abort 'missing group library' unless defined?(EO::HunterGroup)
      RUBY
      _out, err, status = Open3.capture3(RbConfig.ruby, '-e', program, coordination, group, chdir: dir)
      expect(status.success?).to be(true), err
    end
  end

  it 'rejects loader drift rather than shipping a partial library' do
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, 'scripts'))
      File.write(File.join(dir, 'scripts/libeohuntergroup.lic'), 'PARTS = %w[missing].freeze')
      expect { described_class.build(root: dir) }.to raise_error(ArgumentError, /source loader/)
    end
  end

  it 'keeps its namespace global when evaluated inside the native Lich script binding' do
    Dir.mktmpdir do |dir|
      coordination = EOCoordination::Build.write(root: root, out: File.join(dir, 'libeocoordination.lic'))
      group = described_class.write(root: root, out: File.join(dir, 'libeohuntergroup.lic'))
      program = <<~'RUBY'
        module Lich
          module Common
            def self.evaluate(path)
              eval(File.read(path), binding, path)
            end
          end
        end
        Lich::Common.evaluate(ARGV[0])
        Lich::Common.evaluate(ARGV[1])
        abort 'group library shadowed under Lich::Common' if Lich::Common.const_defined?(:EO, false)
        abort 'missing global group library' unless defined?(::EO::HunterGroup)
        context = ::EO::HunterGroup::Context.new(run_id: 'run', role: :head, profile: 'test', leader_identity: {}, members: [], refuge_room: 324)
        abort 'mailbox failed' unless context.command == :prepare
      RUBY
      _out, err, status = Open3.capture3(RbConfig.ruby, '-e', program, coordination, group, chdir: dir)
      expect(status.success?).to be(true), err
    end
  end
end
