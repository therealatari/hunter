# frozen_string_literal: true

require 'tmpdir'
require_relative '../../../scripts/eohunter/setup/map_images'

RSpec.describe EO::HunterSetup::MapImages do
  around { |example| Dir.mktmpdir('setup-map-images') { |dir| @dir = dir; example.run } }
  let(:bytes) { [137, 80, 78, 71, 13, 10, 26, 10].pack('C*') + 'fixture bytes' }
  let(:root) { File.join(@dir, 'maps') }
  before do
    Dir.mkdir(root)
    File.binwrite(File.join(root, 'classic.png'), bytes)
  end
  subject(:images) { described_class.new(root: root, names: ['classic.png', 'missing.png', '../secret.png', 'link.png', 'document.svg']) }

  it 'serves the exact native-listed raster as an image data URL' do
    result = images.read('classic.png')
    expect(result[:name]).to eq('classic.png')
    expect(result[:data_url]).to start_with('data:image/png;base64,')
    expect(Base64.strict_decode64(result[:data_url].split(',').last)).to eq(bytes)
  end

  it 'rejects arbitrary paths, unknown files, and traversal even if metadata names it' do
    ['../secret.png', '/classic.png', 'C:\\classic.png', 'other.png', nil].each do |name|
      expect { images.read(name) }.to raise_error(ArgumentError, /unknown map/)
    end
  end

  it 'does not follow a map symlink outside the map directory' do
    File.binwrite(File.join(@dir, 'secret.png'), bytes)
    File.symlink(File.join(@dir, 'secret.png'), File.join(root, 'link.png'))
    expect { images.read('link.png') }.to raise_error(ArgumentError, /inside/)
  end

  it 'reports missing images without downloading anything or reading another file' do
    expect { images.read('missing.png') }.to raise_error(ArgumentError, /not installed/)
    absent = described_class.new(root: File.join(@dir, 'absent'), names: ['classic.png'])
    expect { absent.read('classic.png') }.to raise_error(ArgumentError, /folder is unavailable/)
  end

  it 'refuses active documents and oversized images' do
    File.write(File.join(root, 'document.svg'), '<svg><script>alert(1)</script></svg>')
    expect { images.read('document.svg') }.to raise_error(ArgumentError, /supported raster/)
    stub_const('EO::HunterSetup::MapImages::MAX_BYTES', 4)
    expect { images.read('classic.png') }.to raise_error(ArgumentError, /size limit/)
  end
end
