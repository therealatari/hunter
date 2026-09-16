# frozen_string_literal: true

require_relative '../spec_helper'
require 'ostruct'
require_relative '../../scripts/eocoordination/protocol'
require_relative '../../scripts/eocoordination/parser_projection'

module CoordinationProjectionSpecSupport
  Event = Struct.new(:monotonic_received_at, keyword_init: true)

  class ProjectionHook
    attr_reader :handlers, :options

    def initialize
      @handlers = {}
      @options = {}
    end

    def add(name, action, **options)
      raise ArgumentError, "not a Proc (#{action.inspect})" unless action.is_a?(Proc)

      @handlers[name] = action
      @options[name] = options
    end

    def remove(name)
      @options.delete(name)
      @handlers.delete(name)
    end

    def run(*args)
      @handlers.values.reduce(args.first) do |value, handler|
        result = handler.call(value, *args.drop(1))
        args.length == 1 ? result : value
      end
    end
  end

  class LegacyProjectionHook < ProjectionHook
    def add(name, action, persist: nil)
      super(name, action, persist: persist)
    end
  end
end

RSpec.describe EO::Coordination::ParserProjection do
  include CoordinationProjectionSpecSupport

  def worker
    inbox = Queue.new
    thread = Thread.new do
      loop do
        work, answer = inbox.pop
        break if work == :stop

        answer << work.call
      rescue StandardError => e
        answer << e
      end
    end
    [thread, lambda do |&block|
      answer = Queue.new
      inbox << [block, answer]
      result = answer.pop
      raise result if result.is_a?(Exception)

      result
    end, -> { inbox << [:stop, nil]; thread.join }]
  end

  let(:socket_hook) { CoordinationProjectionSpecSupport::ProjectionHook.new }
  let(:downstream_hook) { CoordinationProjectionSpecSupport::ProjectionHook.new }
  let(:parser_parts) { worker }
  let(:reader_parts) { worker }
  let(:parser) { parser_parts[0] }
  let(:on_parser) { parser_parts[1] }
  let(:reader) { reader_parts[0] }
  let(:on_reader) { reader_parts[1] }
  let(:game) do
    Struct.new(:thread, :reader_thread, :ingress, :game_instance, :closed, :eof, keyword_init: true) do
      def current_ingress_time = ingress
      def closed? = closed
      def remote_eof? = eof
    end.new(thread: parser, reader_thread: reader, ingress: nil, game_instance: nil, closed: false, eof: false)
  end
  let(:xml) do
    OpenStruct.new(room_id: 324, room_count: 7, room_title: 'Cul-de-Sac', room_exits: ['north'],
                   room_exits_string: 'Obvious exits: north', roundtime_end: 0,
                   cast_roundtime_end: 0, indicator: { 'IconSTANDING' => 'y' },
                   health: 120, max_health: 130)
  end
  let(:staff) { OpenStruct.new(id: 42, noun: 'staff', name: 'an ossified vermilion staff') }
  let(:game_objects) { OpenStruct.new(right_hand: staff, left_hand: nil) }
  let(:room_lock) { Mutex.new }
  let(:projection) do
    described_class.new(game: game, xml: xml, game_objects: game_objects,
                        socket_hook: socket_hook, downstream_hook: downstream_hook, room_lock: room_lock)
  end

  after do
    projection.close
    parser_parts[2].call
    reader_parts[2].call
  end

  def receive_input(at)
    on_reader.call do
      socket_hook.run('raw', CoordinationProjectionSpecSupport::Event.new(monotonic_received_at: at))
    end
  end

  def complete_dispatch(at, string = 'parsed')
    game.ingress = at
    on_parser.call { downstream_hook.run(string) }
  end

  it 'is inert until explicitly installed and removes both hooks on close' do
    expect(socket_hook.handlers).to be_empty
    expect(downstream_hook.handlers).to be_empty

    projection.install!
    expect(socket_hook.handlers.size).to eq(1)
    expect(downstream_hook.handlers.size).to eq(1)
    expect(downstream_hook.options.values).to contain_exactly(
      persist: false, priority: described_class::HOOK_PRIORITY
    )

    projection.close
    expect(socket_hook.handlers).to be_empty
    expect(downstream_hook.handlers).to be_empty
  end

  it 'serializes concurrent installs so each hook is registered once' do
    entered = Queue.new
    release = Queue.new
    calls = 0
    allow(socket_hook).to receive(:add).and_wrap_original do |original, *args, **options|
      calls += 1
      if calls == 1
        entered << true
        release.pop
      end
      original.call(*args, **options)
    end

    first = Thread.new { projection.install! }
    entered.pop
    second = Thread.new { projection.install! }
    expect(second.join(0.1)).to be_nil
    release << true
    [first, second].each(&:join)

    expect(calls).to eq(1)
    expect(socket_hook.handlers.size).to eq(1)
    expect(downstream_hook.handlers.size).to eq(1)
  ensure
    release << true if release && release.empty?
    first&.join(0.5)
    second&.join(0.5)
  end

  it 'serializes close with an install in progress' do
    entered = Queue.new
    release = Queue.new
    allow(socket_hook).to receive(:add).and_wrap_original do |original, *args, **options|
      result = original.call(*args, **options)
      entered << true
      release.pop
      result
    end

    installer = Thread.new { projection.install! }
    entered.pop
    closer = Thread.new { projection.close }
    expect(closer.join(0.1)).to be_nil
    release << true
    [installer, closer].each(&:join)

    expect(socket_hook.handlers).to be_empty
    expect(downstream_hook.handlers).to be_empty
    expect(projection.read).to be_nil
  ensure
    release << true if release && release.empty?
    installer&.join(0.5)
    closer&.join(0.5)
  end

  it 'fails before registration when deterministic downstream priority is unavailable' do
    legacy = CoordinationProjectionSpecSupport::LegacyProjectionHook.new
    projection = described_class.new(game: game, xml: xml, game_objects: game_objects,
                                     socket_hook: socket_hook, downstream_hook: legacy)

    expect { projection.install! }.to raise_error(ArgumentError, /DownstreamHook\.add\(priority:/)
    expect(socket_hook.handlers).to be_empty
    expect(legacy.handlers).to be_empty
  ensure
    projection&.close
  end

  it 'publishes one immutable cut after the newest received input completes parsing' do
    projection.install!
    receive_input(10.0)
    expect(projection.read).to be_nil
    expect(complete_dispatch(10.0)).to eq('parsed')

    sample = projection.read
    expect(projection.call).to equal(sample)
    expect(sample.dig(:source, :sequence)).to eq(1)
    expect(sample.dig(:source, :received_at)).to eq(10.0)
    expect(sample.dig(:fields, :room, :value)).to include(uid: 324, epoch: 7)
    expect(sample.dig(:fields, :right_hand, :value)).to eq(id: '42', noun: 'staff', name: staff.name)
    expect(sample.dig(:fields, :left_hand, :value)).to be_nil
    expect(sample.dig(:fields, :health, :value)).to eq(health: 120, max_health: 130)
    expect(sample).to be_frozen
    expect(sample[:fields]).to be_frozen
  end

  it 'does not republish an older dispatch while newer socket input is queued' do
    projection.install!
    receive_input(10.0)
    receive_input(11.0)

    complete_dispatch(10.0)
    expect(projection.read).to be_nil

    complete_dispatch(11.0)
    expect(projection.read.dig(:source, :sequence)).to eq(2)
  end

  it 'withdraws a completed cut as soon as the next socket line arrives' do
    projection.install!
    receive_input(10.0)
    complete_dispatch(10.0)
    expect(projection.read).not_to be_nil

    receive_input(11.0)
    expect(projection.read).to be_nil
  end

  it 'keeps buffered and provenance-free dispatches unknown' do
    instance = OpenStruct.new(input_was_buffered: true)
    game.game_instance = instance
    projection.install!
    receive_input(10.0)
    complete_dispatch(10.0)
    expect(projection.read).to be_nil

    instance.input_was_buffered = false
    game.ingress = nil
    on_parser.call { downstream_hook.run('parsed') }
    expect(projection.read).to be_nil
  end

  it 'does not publish a completed input line while native room arrival is unfinished' do
    projection.install!
    receive_input(10.0)
    complete_dispatch(10.0)
    expect(projection.read).not_to be_nil

    receive_input(11.0)
    on_parser.call { room_lock.lock } # XMLParser NAV opens Claim::Lock.
    xml.room_id = 325
    complete_dispatch(11.0) # NAV can finish before room players arrive.
    expect(projection.read).to be_nil

    receive_input(12.0)
    complete_dispatch(12.0) # Unrelated completed lines cannot reopen it.
    expect(projection.read).to be_nil

    receive_input(13.0)
    on_parser.call { room_lock.unlock } # Native compass/Claim completion.
    xml.room_count = 8
    complete_dispatch(13.0)
    expect(projection.read.dig(:fields, :room, :value)).to include(uid: 325, epoch: 8)
  ensure
    on_parser.call { room_lock.unlock if room_lock.owned? }
  end

  it 'invalidates permanently stale worker bindings and starts a new generation on new input' do
    projection.install!
    receive_input(10.0)
    complete_dispatch(10.0)
    old_connection = projection.read.dig(:source, :connection_id)

    replacement_parts = worker
    game.reader_thread = replacement_parts[0]
    expect(projection.read).to be_nil
    replacement_parts[2].call
    expect(old_connection).not_to be_nil
  end

  it 'returns unknown after disconnect or EOF' do
    projection.install!
    receive_input(10.0)
    complete_dispatch(10.0)

    game.eof = true
    expect(projection.read).to be_nil
  end
end
