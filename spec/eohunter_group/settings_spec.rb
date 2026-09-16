# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../scripts/eohunter_group/settings'

RSpec.describe EO::HunterGroup::Settings do
  let(:native) do
    Class.new do
      attr_reader :calls, :values

      def initialize
        @calls = []
        @values = {}
      end

      def get_scoped_setting(scope, key, script_name:)
        @calls << [:read, scope, key, script_name]
        @values[[scope, key, script_name]]
      end

      def set_script_settings(scope, key, value, script_name:)
        @calls << [:write, scope, key, script_name]
        @values[[scope, key, script_name]] = value
      end
    end.new
  end
  subject(:settings) { described_class.new(native: native, game: 'GS3', character: 'Testfollower') }

  def allow_profile(**overrides)
    settings.allow(**{ leader: 'Testleader', game: 'GS3', group: 'Leveling-Trio', profile: 'Local-Trio',
                       refuge_room: 324, join_at_rally: true }.merge(overrides))
  end

  it 'defaults off and reads the same explicit character namespace from any script' do
    expect(settings.policy.enabled?).to be(false)
    expect(native.calls).to eq([[:read, 'GS3:Testfollower', 'group_startup', 'eohunter']])
    expect(native.values).to be_empty
  end

  it 'stores participation for only the selected character and leaves mappings disabled until enabled' do
    allow_profile
    expect(settings.policy.resolve(leader: 'Testleader', game: 'GS3', group: 'Leveling-Trio')).to be_nil
    settings.enable
    mapping = settings.policy.resolve(leader: 'Testleader', game: 'GS3', group: 'Leveling-Trio')
    expect(mapping).to eq(profile: 'Local-Trio', refuge_room: 324, join_at_rally: true)
    expect(mapping).to be_frozen
    expect(mapping[:profile]).to be_frozen
    other = described_class.new(native: native, game: 'GS3', character: 'Testsecond')
    expect(other.policy.enabled?).to be(false)
    expect(native.calls.select { |call| call.first == :write }.map(&:last).uniq).to eq(['eohunter'])
  end

  it 'refuses wrong leader, game, or group and preserves mappings when disabled' do
    allow_profile
    settings.enable
    expect(settings.policy.resolve(leader: 'Other', game: 'GS3', group: 'Leveling-Trio')).to be_nil
    expect(settings.policy.resolve(leader: 'Testleader', game: 'GSF', group: 'Leveling-Trio')).to be_nil
    expect(settings.policy.resolve(leader: 'Testleader', game: 'GS3', group: 'Other')).to be_nil
    settings.disable
    expect(settings.policy.data[:leaders].keys).to eq(['Testleader'])
    expect(settings.policy.enabled?).to be(false)
  end

  it 'rejects executable input, remote paths, malformed booleans and unsupported fields before saving' do
    ['../elsewhere', '/tmp/profile', 'profile;kill', "profile\narg", 'profile.lic', '..'].each do |profile|
      expect { allow_profile(profile: profile) }.to raise_error(EO::HunterGroup::Policy::Invalid)
    end
    expect { allow_profile(join_at_rally: 'true') }.to raise_error(EO::HunterGroup::Policy::Invalid)
    expect { allow_profile(refuge_room: '324') }.to raise_error(EO::HunterGroup::Policy::Invalid)
    expect { settings.configure(enabled: 'yes') }.to raise_error(EO::HunterGroup::Policy::Invalid)
    expect { EO::HunterGroup::Policy.new(enabled: true, script: 'other') }.to raise_error(EO::HunterGroup::Policy::Invalid)
    expect(native.values).to be_empty
  end

  it 'pins immutable values without freezing the caller configuration' do
    profile = +'My-Profile'
    allow_profile(profile: profile)
    profile.replace('Changed')
    expect(settings.policy.data[:leaders]['Testleader'][:groups]['Leveling-Trio'][:profile]).to eq('My-Profile')
  end

  it 'rejects an accidental game reassignment without changing the saved mapping' do
    allow_profile
    expect { allow_profile(game: 'GSF') }.to raise_error(EO::HunterGroup::Policy::Invalid)
    expect(settings.policy.data[:leaders]['Testleader'][:game]).to eq('GS3')
  end

  it 'accepts existing profile and group names with spaces up to 128 characters' do
    group = 'Leveling Trio'
    allow_profile(group: group, profile: 'A' * 128)
    settings.enable
    expect(settings.policy.resolve(leader: 'Testleader', game: 'GS3', group: group)[:profile]).to eq('A' * 128)
    expect { allow_profile(profile: 'A' * 129) }.to raise_error(EO::HunterGroup::Policy::Invalid)
    expect { allow_profile(group: 'A' * 129) }.to raise_error(EO::HunterGroup::Policy::Invalid)
    expect { allow_profile(leader: 'Other Leader') }.to raise_error(EO::HunterGroup::Policy::Invalid)
    expect { allow_profile(game: 'Other Game') }.to raise_error(EO::HunterGroup::Policy::Invalid)
  end

  it 'requires explicit per-character approval of background scripts and preserves it across mapping changes' do
    expect(settings.policy.background_scripts).to eq([])
    scripts = [+'LAB', +'watcher']
    settings.background(scripts: scripts)
    scripts.first.replace('other')
    scripts << 'later'
    allow_profile
    settings.enable
    settings.disable
    expect(settings.policy.background_scripts).to eq(%w[lab watcher])
    expect(settings.policy.background_scripts).to be_frozen
    expect(settings.policy.background_scripts.first).to be_frozen
    expect(described_class.new(native: native, game: 'GS3', character: 'Testsecond').policy.background_scripts).to eq([])
    settings.background(scripts: [])
    expect(settings.policy.background_scripts).to eq([])
  end

  it 'rejects invalid or unbounded background script names without changing approved scripts' do
    settings.background(scripts: ['lab'])
    ['lab', ['../lab'], ['lab;kill'], ['lab arg'], ['lab.lic'], ['a'] * 33].each do |scripts|
      expect { settings.background(scripts: scripts) }.to raise_error(EO::HunterGroup::Policy::Invalid)
    end
    expect(settings.policy.background_scripts).to eq(['lab'])
  end
end
