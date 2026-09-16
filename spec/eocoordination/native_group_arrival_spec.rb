# frozen_string_literal: true

require_relative '../spec_helper'
require 'open3'
require 'rbconfig'

RSpec.describe 'native fragmented group arrival' do
  it 'keeps Follow idle through NAV, but permits catch-up after a completed empty room' do
    root = ENV['LICH_ROOT']
    skip 'set LICH_ROOT to run native XMLParser/Claim integration' unless root && File.file?(File.join(root, 'lib/gemstone/claim.rb'))

    # Isolate native Lich globals from the engine suite's deliberately small
    # fakes. This drives real XMLParser, Claim, ParserProjection and Follow;
    # only transport and the command-producing travel seam are inert doubles.
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path('../support/native_group_arrival_replay.rb', __dir__))
    expect(status.success?).to be(true), output
    expect(output).to include('PASS: arrival completed without catch-up',
                              'PASS: completed empty room still starts catch-up')
  end
end
