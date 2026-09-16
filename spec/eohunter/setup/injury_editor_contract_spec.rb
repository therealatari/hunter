# frozen_string_literal: true

require 'json'
require 'open3'
require_relative '../engine_helper'

RSpec.describe 'Setup injury editor native contract' do
  def expressions
    js = <<~JS
      const c = require('./scripts/eohunter/setup/assets/injury-editor.js');
      const rules = Object.fromEntries(Object.entries(c.presets).map(([key, value]) => [key, c.encode(value.values)]));
      rules.scar = c.encode({...c.defaults(), health: '', wound: '', scar: '2'});
      process.stdout.write(JSON.stringify(rules));
    JS
    output, error, result = Open3.capture3('node', '-e', js, chdir: File.expand_path('../../..', __dir__))
    expect(result.success?).to be(true), error
    JSON.parse(output)
  rescue Errno::ENOENT
    skip 'Node is a development-only dependency; the setup-browser CI runs codec contracts'
  end

  def bleeding? = @bleeding == true

  it 'evaluates the generated general rule only through the existing rest-policy binding' do
    char = stub_const('Char', Struct.new(:percent_health).new(100))
    xml = stub_const('XMLData', Struct.new(:injuries).new({ 'head' => { 'wound' => 0, 'scar' => 0 } }))
    profile = EO::Engine::Profile.new({ 'wounded_eval' => expressions.fetch('general') })
    policy = profile.rest_policy(wounded_binding: binding)
    expect(policy.wounded.call).to be(false)
    char.percent_health = 70
    expect(policy.wounded.call).to be(true)
    char.percent_health = 71
    expect(policy.wounded.call).to be(false)
    xml.injuries['head']['wound'] = 2
    expect(policy.wounded.call).to be(true)
  end

  it 'delegates casting and ranged injury rules to native predicates, not copied wound arithmetic' do
    stub_const('Char', Struct.new(:percent_health).new(100))
    native = stub_const('Lich::Gemstone::Injured', double('native injury reader'))
    rules = expressions
    { 'caster' => :able_to_cast?, 'ranged' => :able_to_use_ranged? }.each do |name, predicate|
      allow(native).to receive(predicate).and_return(true)
      policy = EO::Engine::Profile.new({ 'wounded_eval' => rules.fetch(name) }).rest_policy(wounded_binding: binding)
      expect(native).not_to have_received(predicate)
      expect(policy.wounded.call).to be(false)
      allow(native).to receive(predicate).and_return(false)
      expect(policy.wounded.call).to be(true)
    end
    @bleeding = true
    expect(EO::Engine::Profile.new({ 'wounded_eval' => rules.fetch('caster') }).rest_policy(wounded_binding: binding).wounded.call).to be(true)
  end

  it 'uses the native cached scar projection instead of possibly hidden XML scar values' do
    scars = { 'head' => 1 }
    native = stub_const('Lich::Gemstone::Injured', double('native injury reader', get_injury_data: [{ 'head' => 3 }, scars]))
    policy = EO::Engine::Profile.new({ 'wounded_eval' => expressions.fetch('scar') }).rest_policy(wounded_binding: binding)
    expect(native).not_to have_received(:get_injury_data)
    expect(policy.wounded.call).to be(false)
    scars['head'] = 2
    expect(policy.wounded.call).to be(true)
  end
end
