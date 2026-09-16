# frozen_string_literal: true

require_relative 'engine_helper'

RSpec.describe 'the eohunter setup entry point' do
  it 'also dispatches MA startup before duplicate checks without reloading the engine' do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    before_reload = source.split("load File.join(SCRIPT_DIR, 'eohunter', 'engine.rb')").first
    context = Object.new
    script = Struct.new(:vars).new([nil, 'Trio', 'group'])
    context.define_singleton_method(:script) { script }
    receiver = Module.new
    receiver.const_set(:Supervisor, Class.new)
    receiver.define_singleton_method(:dispatch_group) { |_name| }
    stub_const('EO::HunterGroup', receiver)
    previous = EO::Engine
    expect(receiver).to receive(:dispatch_group).with('Trio').once
    expect(Script).not_to receive(:current)
    expect(Script).not_to receive(:start)
    expect { context.instance_eval(before_reload) }.to raise_error(SystemExit)
    expect(EO::Engine).to equal(previous)
  end

  it 'dispatches through native supervision before inspecting or reloading an active engine' do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    before_reload = source.split("load File.join(SCRIPT_DIR, 'eohunter', 'engine.rb')").first
    context = Object.new
    script = Struct.new(:vars).new([nil, 'setup'])
    context.define_singleton_method(:script) { script }
    previous = EO::Engine
    allow(Script).to receive(:running?).with('eohunter-setup').and_return(false)
    expect(Script).to receive(:start).with('eohunter-setup').once
    expect(Script).not_to receive(:current)
    expect { context.instance_eval(before_reload) }.to raise_error(SystemExit)
    expect(EO::Engine).to equal(previous)
  end

  it 'does not start another copy of an existing editor' do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    before_reload = source.split("load File.join(SCRIPT_DIR, 'eohunter', 'engine.rb')").first
    context = Object.new
    script = Struct.new(:vars).new([nil, 'setup'])
    context.define_singleton_method(:script) { script }
    allow(Script).to receive(:running?).with('eohunter-setup').and_return(true)
    expect(Script).not_to receive(:start)
    expect { context.instance_eval(before_reload) }.to raise_error(SystemExit)
  end
end
