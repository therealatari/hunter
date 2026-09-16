# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../tools/build_setup'

RSpec.describe EOHunter::SetupBuild do
  let(:root) { File.expand_path('..', __dir__) }
  let(:result) { described_class.build(root: root, sha: 'review') }

  it 'builds valid standalone Ruby with every local asset and no engine reset' do
    expect { RubyVM::InstructionSequence.compile(result.source) }.not_to raise_error
    expect(result.source).not_to include('remove_const, :Engine')
    expect(result.source).not_to match(/^require_relative /)
    expect(result.source).to include('ASSETS = ', 'index.html', 'routine-editor.js', 'app.js', 'style.css')
  end

  it 'keeps policy dependency order aligned with the engine distribution' do
    parts = EOHunter::Build.parts_of(File.read(File.join(root, 'scripts/eohunter/engine.rb')))
    expect(EO::HunterSetup::Runtime::PROFILE_PARTS).to eq(parts.reject { |part| part.start_with?('setup/') })
  end

  it 'loads bundled policy and editor definitions without installed source files' do
    run_definition_check(false)
  end

  it 'preserves the active engine and profile classes when setup opens' do
    run_definition_check(true)
  end

  def run_definition_check(active)
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'eohunter-setup.lic')
      described_class.write(root: root, out: path, sha: 'review')
      harness = <<~RUBY
        module Lich; module Common; end; end
        class Script
          def self.current = Object.new
          def self.list = []
        end
        module EO; module Engine; class Profile; end; end; end if #{active}
        previous = EO::Engine if #{active}
        previous_profile = EO::Engine::Profile if #{active}
        source = File.read(#{path.inspect}).split(/^EO::HunterSetup::Runtime.load_support/).first
        Lich::Common.module_eval(source, #{path.inspect})
        abort 'missing root setup namespace' unless defined?(::EO::HunterSetup::Server)
        abort 'missing bundled catalog' unless defined?(::EO::HunterSetup::AreaCatalogData::RECORDS)
        EO::HunterSetup::AreaCatalog.new
        abort 'missing profile' unless defined?(::EO::Engine::Profile)
        abort 'replaced active engine' if #{active} && !EO::Engine.equal?(previous)
        abort 'replaced active profile' if #{active} && !EO::Engine::Profile.equal?(previous_profile)
        EO::HunterSetup::Runtime.load_support('/no-installed-sources')
        puts 'ok'
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, '-e', harness, chdir: directory)
      expect(status).to be_success, err
      expect(out.strip).to eq('ok')
    end
  end
end
