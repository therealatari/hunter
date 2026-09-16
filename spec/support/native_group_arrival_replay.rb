# frozen_string_literal: true

# Offline diagnostic: real native XML/Claim callbacks, real projection and
# Follow/Travel. No network, logged-in session, or game command is used.
require 'ostruct'
require 'rexml/document'
require 'rexml/streamlistener'
LIB_DIR = File.join(ENV.fetch('LICH_ROOT'), 'lib')
require File.join(LIB_DIR, 'common/gameobj')
GameObj = Lich::Common::GameObj
require File.join(LIB_DIR, 'common/xmlparser')
XMLData = Lich::Common::XMLParser.new
require File.join(LIB_DIR, 'gemstone/claim')
hunter_root = File.expand_path('../..', __dir__)
require File.join(hunter_root, 'spec/eohunter/engine_helper')
require File.join(hunter_root, 'scripts/eocoordination/protocol')
require File.join(hunter_root, 'scripts/eocoordination/parser_projection')

def respond(message) = raise(message)
def Lich.log(message) = raise(message)

class Hook
  def initialize = @handlers = {}
  def add(name, fn, **_) = @handlers[name] = fn
  def remove(name) = @handlers.delete(name)
  def run(*args) = @handlers.each_value { |fn| fn.call(*args) }
end

XMLData.instance_variable_set(:@game, 'GSIV')
XMLData.instance_variable_set(:@room_id, 3955)
XMLData.instance_variable_set(:@room_count, 7)
GameObj.new_pc('-1', 'Lead', 'Lead')
$room_count = 7
socket = Hook.new
downstream = Hook.new
game = OpenStruct.new(thread: Thread.current, reader_thread: Thread.current,
                      closed?: false, remote_eof?: false, game_instance: nil)
projection = EO::Coordination::ParserProjection.new(game: game, xml: XMLData, game_objects: GameObj,
                                                    socket_hook: socket, downstream_hook: downstream)
projection.install!
dispatch = lambda do |xml|
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  socket.run(xml, OpenStruct.new(monotonic_received_at: now))
  REXML::Document.parse_stream("<root>#{xml}</root>", XMLData)
  game.current_ingress_time = now
  downstream.run(xml)
end
hub = EO::Engine::Group::Hub.new
hub.open_hunt(leader: 'Lead', expected: ['Tail'], rooms: {})
member = EO::Engine::Group::Member.new(hub, name: 'Tail', native_reader: projection)
member.register
hub.activate!
hub.heartbeat!(name: 'Lead', room: 3955, phase: :hunting)
member.leader_state
room = Object.new
def room.id = XMLData.room_id
def room.uid = XMLData.room_id
def room.count = XMLData.room_count
def room.players = Array(GameObj.pcs)
world = OpenStruct.new(room: room, group_leader_noun: 'Lead', group_nouns: ['Lead'],
                       me: OpenStruct.new(in_rt?: false, in_cast_rt?: false))
trips = []
follow = EO::Engine::Behaviors::Follow.new(member: member, travel: ->(r) { trips << r; true })

dispatch.call('')
# A complete network line can contain NAV without the subsequent room-player
# component: the parser has caught up to ingress, but arrival is unfinished.
dispatch.call('<nav rm="3956"/>')
follow.tick(world)
puts({ stage: 'after_nav', claim_pending: Lich::Claim::Lock.locked?,
       published: !projection.read.nil?, players: room.players.map(&:noun), trips: trips }.inspect)
raise 'BUG: Follow backtracked before the room arrival completed' unless trips.empty?

dispatch.call('<component id="room players"><a exist="-1" noun="Lead">Lead</a></component><compass></compass>')
follow.tick(world)
puts({ stage: 'after_players', claim_pending: Lich::Claim::Lock.locked?,
       published: !projection.read.nil?, players: room.players.map { |p| [p.noun, p.name] }, trips: trips }.inspect)
raise 'BUG: normal group arrival triggered catch-up' unless trips.empty?
puts 'PASS: arrival completed without catch-up'
# A genuinely empty completed arrival must still permit catch-up.
dispatch.call('<nav rm="3957"/><component id="room players"></component><compass></compass>')
follow.tick(world)
raise 'BUG: real separation no longer starts catch-up' unless trips == [3955]
puts 'PASS: completed empty room still starts catch-up'
projection.close
