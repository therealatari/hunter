# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Behaviors::Assist, 'individual fried routines' do
  let(:target) { OpenStruct.new(id: '1', noun: 'rat', name: 'giant rat', status: '', type: 'aggressive npc') }
  let(:me) { OpenStruct.new(current_target_id: '1', dead?: false, muckled?: false, hidden?: false, standing?: true, in_rt?: false, in_cast_rt?: false) }
  let(:world) { OpenStruct.new(me: me, room: OpenStruct.new(id: 324, targets: [target], players: [OpenStruct.new(noun: 'Lead')])) }
  let(:member) { double('member', leader_name: 'Lead', leader_target: { id: '1' }, strict_movement?: false, native_reader: nil) }
  let(:full) { [false] }
  let(:policy) { EO::Engine::Engage::Policy.new(routines: { 'a' => ['attack target'] }, disable_commands: ['stance defensive', 'sleep 1 nostance'], hunting_stance: nil) }
  let(:assist) { described_class.new(member: member, policy: policy, targets_policy: EO::Engine::Targets::Policy.new, fried: -> { full.first }) }

  before do
    allow(assist).to receive(:soothe)
    allow(assist).to receive(:reaction)
    allow(assist).to receive(:dispatch).and_return(EO::Engine::Actions::Result.new(status: :success))
    assist.attack!
  end

  # Building the follower also registers profile rules on the shared Watch.
  after { EO::Engine::Watch.clear! }

  it 'uses the configured nonattacking routine when this follower is already fried' do
    full[0] = true
    expect(assist.wants_control?(world)).to be true
    assist.tick(world)
    expect(assist).to have_received(:dispatch).with(world, 'stance defensive', anything)
    expect(assist).not_to have_received(:dispatch).with(world, 'attack #1', anything)
  end

  it 'changes routine on the same target when mind fills, without losing group orders' do
    assist.tick(world)
    full[0] = true
    assist.tick(world)
    assist.tick(world)
    expect(assist).to have_received(:dispatch).with(world, 'attack #1', anything).once
    expect(assist).to have_received(:dispatch).with(world, 'stance defensive', anything).once
    expect(assist).to have_received(:dispatch).with(world, 'sleep 1 nostance', anything).once
    assist.stand_down!
    expect(assist.wants_control?(world)).to be false
  end

  it 'resumes the ordinary routine when experience drains below the local threshold' do
    full[0] = true
    assist.tick(world)
    full[0] = false
    assist.tick(world)
    expect(assist).to have_received(:dispatch).with(world, 'stance defensive', anything).once
    expect(assist).to have_received(:dispatch).with(world, 'attack #1', anything).once
  end

  it 'lets the fried routine interrupt a repeat-until-dead step on the same target' do
    policy.routines = { 'a' => ['attack target(untildead)', 'jab target'] }
    assist.tick(world)
    assist.tick(world)
    full[0] = true
    assist.tick(world)
    expect(assist).to have_received(:dispatch).with(world, 'attack #1', anything).twice
    expect(assist).not_to have_received(:dispatch).with(world, 'jab #1', anything)
    expect(assist).to have_received(:dispatch).with(world, 'stance defensive', anything).once
  end

  it 'keeps ordinary combat for existing profiles without disable_commands' do
    policy.disable_commands = []
    full[0] = true
    assist.tick(world)
    expect(assist).to have_received(:dispatch).with(world, 'attack #1', anything)
  end

  it 'wires the follower builder to its own native mind percentage and profile threshold' do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    entry = Module.new.tap { |mod| mod.module_eval(source[/^module EOHunter\n.*?\nend\n/m]) }::EOHunter
    stub_const('CharSettings', {})
    stub_const('DATA_DIR', '/unused-by-this-test')
    stub_const('XMLData', OpenStruct.new(game: 'TEST'))
    stub_const('Char', OpenStruct.new(name: 'Learner'))
    stub_const('Lich::Gemstone::Stance', double('native stance', change: true))
    allow(EO::Engine::Cleanse::Policy).to receive(:load).and_return(EO::Engine::Cleanse::Policy.new)
    allow(EO::Engine::Targets::BoonCache).to receive(:new).and_return(nil)
    profile = EO::Engine::Profile.new({ 'fried' => 95, 'hunting_commands' => 'attack target',
                                       'disable_commands' => 'stance defensive', 'hunting_stance' => '' })
    built = entry.build_follower(profile, world, member).fetch(:engage)
    allow(built).to receive(:soothe)
    allow(built).to receive(:reaction)
    allow(built).to receive(:dispatch).and_return(EO::Engine::Actions::Result.new(status: :success))
    built.attack!
    me.fxp_pct = 94
    built.tick(world)
    me.fxp_pct = 95
    built.tick(world)
    expect(built).to have_received(:dispatch).with(world, 'attack #1', anything).once
    expect(built).to have_received(:dispatch).with(world, 'stance defensive', anything).once
  end
end
