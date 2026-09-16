# frozen_string_literal: true

require_relative '../../../scripts/eohunter/setup/society_abilities'

RSpec.describe EO::HunterSetup::SocietyAbilities do
  let(:entry) do
    { short_name: 'courage', long_name: 'Symbol of Courage', spell_number: 9805,
      duration: 100, cost: 42, summary: 'Raises AS.', cost_type: :invoked }
  end
  let(:reader) { double('native society', member?: true, all: [entry], known?: true) }
  let(:spell) { double('native spell', duration: 'Society.rank / 6.0', msgup: /You feel more courageous/, type: 'offense', known?: true) }

  it 'reads native names, learned state and costs for each society without casting' do
    %w[CouncilOfLight OrderOfVoln GuardiansOfSunfist].each do |name|
      result = described_class.capture(providers: { name => reader }, spells: { 9805 => spell })
      choice = result[:groups].first[:abilities].first
      expect(choice).to include(id: 9805, name: 'Symbol of Courage', cost: 42, maintainable: true)
      expect(choice[:description]).to eq('Raises AS.')
    end
  end

  it 'does not confuse no membership, unlearned abilities and unavailable data' do
    allow(reader).to receive(:member?).and_return(false)
    expect(reader).not_to receive(:all)
    expect(described_class.group('Voln', reader, {})).to include(available: true, member: false, abilities: [])
    expect(described_class.group('Voln', nil, {})).to include(available: false, abilities: [])
  end

  it 'omits unlearned abilities rather than offering all society ranks' do
    allow(reader).to receive(:known?).with('courage').and_return(false)
    expect(described_class.group('Voln', reader, { 9805 => spell })[:abilities]).to eq([])
  end

  it 'keeps one-shot, untracked and targeted powers visible but not selectable as upkeep' do
    allow(spell).to receive(:duration).and_return('0')
    expect(described_class.ability(entry, { 9805 => spell })[:maintainable]).to be(false)
    allow(spell).to receive(:duration).and_return('1')
    allow(spell).to receive(:type).and_return('attack')
    expect(described_class.ability(entry, { 9805 => spell })[:maintainable]).to be(false)
    expect(described_class.ability(entry, {})[:maintainable]).to be(false)
  end

  it 'reports a reader failure without turning missing data into an empty known list' do
    allow(reader).to receive(:all).and_raise(RuntimeError, 'uninitialized rank')
    result = described_class.group('Voln', reader, {})
    expect(result[:available]).to be(false)
    expect(result[:error]).to include('Existing settings are preserved')
  end

  it 'does not offer rest-only or cooldown abilities just because Spell tracks their duration' do
    expect(described_class.ability(entry.merge(duration: nil), { 9805 => spell })[:maintainable]).to be(false)
    expect(described_class.ability(entry.merge(cooldown_duration: 180), { 9805 => spell })[:maintainable]).to be(false)
  end
end
