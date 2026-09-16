# frozen_string_literal: true

require_relative '../../../scripts/eohunter/setup/area_catalog'

RSpec.describe EO::HunterSetup::AreaCatalog do
  let(:record) do
    { id: 'forest-path', label: 'Forest path', parent_label: 'Woodland',
      native_habitat_names: %w[Forest Meadow], map_sheets: %w[west.png east.png],
      uids: [101, 102, 103], excluded_uids: [104], status: 'draft',
      notes: ['Transit rooms retained.'], evidence: ['https://example.test/map'],
      source: { map_sha256: 'snapshot', research_path: 'research/woodland.json' },
      static_check: { result: 'partial', missing_member_room_ids: [3] } }
  end

  it 'preserves independent overlapping areas and immutable evidence without freezing input' do
    other = record.merge(id: 'overlap', uids: [102, 103, 105])
    catalog = described_class.new(records: [record, other])
    expect(catalog.parents).to eq(['Woodland'])
    expect(catalog.for('Woodland').map { |entry| entry[:uids] }).to eq([[101, 102, 103], [102, 103, 105]])
    expect { catalog.for('Woodland').first[:source][:map_sha256].replace('wrong') }.to raise_error(FrozenError)
    record[:uids] << 109
    expect(catalog.for('Woodland').first[:uids]).to eq([101, 102, 103])
  end

  it 'accepts JSON string keys and retains source metadata' do
    input = record.transform_keys(&:to_s).merge('static_check' => { 'result' => 'pass' })
    expect(described_class.new(records: [input]).for('Woodland').first[:static_check]).to eq('result' => 'pass')
  end

  it 'withholds special candidates from ordinary selections' do
    catalog = described_class.new(records: [record.merge(status: 'special_candidate')])
    expect(catalog.parents).to eq([])
    expect(catalog.for('Woodland')).to eq([])
  end

  it 'rejects malformed membership, evidence, statuses and duplicate identities' do
    [record.merge(uids: []), record.merge(uids: [101, 101]), record.merge(uids: ['101']),
     record.merge(uids: [0]), record.merge(uids: (101..103)), record.merge(status: 'safe'),
     record.merge(native_habitat_names: []), record.merge(excluded_uids: [101]),
     record.merge(static_check: { result: 'safe' }), record.merge(source: { callback: -> { raise 'never execute' } }),
     record.merge(unknown_field: true), record.reject { |key, _| key == :notes }].each do |invalid|
      expect { described_class.new(records: [invalid]) }.to raise_error(ArgumentError)
    end
    expect { described_class.new(records: [record, record]) }.to raise_error(ArgumentError, /duplicate catalog area/)
  end

  it 'validates the bundled catalog as plain data' do
    expect { described_class.new }.not_to raise_error
  end
end
