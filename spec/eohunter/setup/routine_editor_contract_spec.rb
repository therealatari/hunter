# frozen_string_literal: true

require 'json'
require 'open3'
require_relative '../engine_helper'

RSpec.describe 'Setup routine editor native contract' do
  it 'keeps spell methods and elements in the actual native dispatch captures' do
    script = <<~JS
      const c = require('./scripts/eohunter/setup/assets/routine-editor.js');
      process.stdout.write(JSON.stringify(['default', 'incant', 'cast', 'channel', 'evoke'].map(delivery =>
        c.encodeAction({...c.actionDefaults('incant'), spell: '903', delivery, element: 'fire'}))));
    JS
    output, error, result = Open3.capture3('node', '-e', script, chdir: File.expand_path('../../..', __dir__))
    expect(result.success?).to be(true), error
    captures = JSON.parse(output).map { |text| text.match(EO::Engine::Behaviors::Engage::SPELL).captures }
    expect(captures).to eq([
                             [nil, '903', 'fire'], ['incant', '903', 'fire'], [nil, '903', 'cast fire'],
                             [nil, '903', 'channel fire'], [nil, '903', 'evoke fire']
                           ])
  rescue Errno::ENOENT
    skip 'Node is a development-only dependency; this cross-language contract also runs in setup-browser CI'
  end

  it 'feeds generated conditional repeats to the real Profile and Engage parsers' do
    script = <<~JS
      const c = require('./scripts/eohunter/setup/assets/routine-editor.js');
      const line = c.parse('incant 711')[0];
      line.repeat = '2'; line.modifiers = ['m40', '!stunned'];
      process.stdout.write(JSON.stringify(['incant 719 (once)', c.serialize(line), 'incant 705'].join(', ')));
    JS
    output, error, result = Open3.capture3('node', '-e', script, chdir: File.expand_path('../../..', __dir__))
    expect(result.success?).to be(true), error
    commands = EO::Engine::Profile.new({ 'hunting_commands' => JSON.parse(output) })['hunting_commands']
    lines = EO::Engine::Engage::Routine.parse(commands)
    expect(lines.map(&:text)).to eq(['incant 719', 'incant 711', 'incant 711', 'incant 705'])
    expect(lines.map(&:modifiers)).to eq([['once'], ['m40', '!stunned'], ['m40', '!stunned'], []])
  rescue Errno::ENOENT
    skip 'Node is a development-only dependency; this cross-language contract also runs in setup-browser CI'
  end
end
