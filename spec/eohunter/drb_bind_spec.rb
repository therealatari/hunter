# frozen_string_literal: true

require 'drb/drb'
require 'socket'

# The leader serves its rally Hub over DRb. A nil URI binds every
# interface, which puts an unauthenticated order channel on the network:
# the Hub answers orders with no credential of any kind, and Order carries
# a :command type that runs an arbitrary game command on the follower
# (group.rb 1302). The engine never sends that order - the leader has
# fourteen order types and :command is not among them - so what the bind
# decides is the whole reachable surface, not one handler.
#
# These pin the socket behaviour scripts/eohunter.lic relies on, so a
# change to the URI it passes cannot quietly re-expose the port.
RSpec.describe 'the rally hub bind address' do
  # The exact URI form scripts/eohunter.lic passes to DRb.start_service.
  let(:loopback_uri) { 'druby://127.0.0.1:0' }
  let(:hub) { Class.new { def ping = :pong }.new }

  around do |example|
    example.run
  ensure
    begin
      DRb.stop_service
    rescue StandardError
      nil
    end
  end

  it 'serves the hub to this machine' do
    DRb.start_service(loopback_uri, hub)
    expect(DRb.uri).to start_with('druby://127.0.0.1:')
    expect(DRbObject.new_with_uri(DRb.uri).ping).to eq(:pong)
  end

  it 'does not answer on a routable address' do
    lan = Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? }
    skip 'no routable IPv4 address on this host' if lan.nil?

    DRb.start_service(loopback_uri, hub)
    port = DRb.uri[/:(\d+)\z/, 1].to_i
    expect do
      Socket.tcp(lan.ip_address, port, connect_timeout: 2, &:close)
    end.to raise_error(SystemCallError)
  end

  # A restart in the same Lich starts a second service. DRb replaces the
  # primary without closing the first, so the previous run's Hub keeps
  # answering hunt_id, register and report from a roster that is gone,
  # and a follower holding the old uri talks to a dead hunt. The teardown
  # in before_dying is what closes it.
  it 'leaves the previous hub serving when a second service starts' do
    DRb.start_service(loopback_uri, hub)
    first = DRb.uri
    DRb.start_service(loopback_uri, Class.new { def ping = :second }.new)
    expect(DRb.uri).not_to eq(first)
    expect(DRbObject.new_with_uri(first).ping).to eq(:pong)
  end

  # Lich kills the script's thread group - the DRb acceptor among them -
  # before it runs any at_exit proc, so the socket is still bound when
  # before_dying starts. stop_service closes it from there anyway, which
  # is why the teardown can live on the kill path without blocking.
  it 'closes the socket from a cleanup thread after the acceptor is killed' do
    group = ThreadGroup.new
    holder = Thread.new do
      group.add(Thread.current)
      DRb.start_service(loopback_uri, hub)
      sleep 5
    end
    sleep 0.5
    uri = DRb.uri
    group.list.each(&:kill)
    holder.join
    expect(DRbObject.new_with_uri(uri).ping).to eq(:pong) # the kill alone does not close it
    DRb.stop_service
    expect { DRbObject.new_with_uri(uri).ping }.to raise_error(DRb::DRbConnError)
  end

  # The teardown itself, which the socket tests above cannot reach: both
  # roles start a service and both must stop it.
  describe 'the script teardown' do
    let(:source) { File.read(File.expand_path('../../scripts/eohunter.lic', __dir__)) }

    it 'stops the leader service on the kill path' do
      teardown = source[/leader&\.finish!.*?fput\('movement autosneak off'/m]
      expect(teardown).to include('DRb.stop_service if leader')
    end

    it 'stops the follower service on the kill path' do
      teardown = source[/member\.stop_pulse!\r?\n.*?Watch\.uninstall!/m]
      expect(teardown).to include('DRb.stop_service')
    end
  end
end
