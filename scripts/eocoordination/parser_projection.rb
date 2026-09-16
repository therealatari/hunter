# frozen_string_literal: true

require 'securerandom'

module EO
  module Coordination
    # Opt-in immutable projection built entirely outside Lich core from its
    # existing synchronous parser seams. SocketReadHook withdraws the preceding
    # cut before parsing; DownstreamHook publishes only after the parser catches
    # up to that exact, newest input. Unknown or buffered provenance stays nil.
    class ParserProjection
      # Namespace used to make every installed hook name unique.
      HOOK_PREFIX = 'EO::Coordination::ParserProjection'
      # Parser-provenance hooks run before ordinary presentation consumers.
      HOOK_PRIORITY = 1_000

      # @param game [Object] native Game singleton
      # @param xml [Object] native XMLData singleton
      # @param game_objects [Object] native GameObj class
      # @param socket_hook [Object] Lich::Common::SocketReadHook
      # @param downstream_hook [Object] DownstreamHook
      # @param room_lock [Mutex, nil] native Claim arrival lock where available
      # @return [ParserProjection]
      def initialize(game: default_game, xml: default_xml, game_objects: default_game_objects,
                     socket_hook: default_socket_hook, downstream_hook: default_downstream_hook,
                     room_lock: default_room_lock)
        @game = game
        @xml = xml
        @game_objects = game_objects
        @socket_hook = socket_hook
        @downstream_hook = downstream_hook
        @room_lock = room_lock
        @mutex = Mutex.new
        @hook_name = "#{HOOK_PREFIX}:#{object_id}"
        @installed = false
        @snapshot = nil
        @sequence = 0
        @connection_id = nil
        @parser = nil
        @reader = nil
        @latest_received_at = nil
      end

      # Install both passive hooks. No listener, thread, script or game command
      # is started. The caller owns this object and must call {#close}.
      # @return [Boolean] true when installed
      def install!
        @mutex.synchronize do
          return true if @installed

          ensure_priority_support!
          begin
            if @socket_hook.respond_to?(:add_script_hook)
              @socket_hook.add_script_hook(@hook_name, &method(:input_received))
            else
              @socket_hook.add(@hook_name, method(:input_received).to_proc)
            end
            @downstream_hook.add(@hook_name, method(:dispatch_completed).to_proc,
                                 persist: false, priority: HOOK_PRIORITY)
            @installed = true
          rescue StandardError
            @socket_hook.remove(@hook_name) rescue nil
            @downstream_hook.remove(@hook_name) rescue nil
            @installed = false
            invalidate_locked
            raise
          end
        end
        true
      end

      # Return the exact frozen publication only while its native connection
      # workers remain current. Reading never refreshes evidence.
      # @return [Hash, nil] immutable parser cut, or unknown
      def read
        @mutex.synchronize do
          unless @installed && live_binding_locked?
            invalidate_locked
            return nil
          end

          @snapshot
        end
      rescue StandardError
        nil
      end

      # Callable-reader adapter used by EOHunter's native-state seams.
      # @return [Hash, nil] immutable parser cut, or unknown
      def call = read

      # Remove both hooks and permanently withdraw the current publication.
      # @return [nil]
      def close
        @mutex.synchronize do
          @socket_hook.remove(@hook_name) rescue nil
          @downstream_hook.remove(@hook_name) rescue nil
          @installed = false
          invalidate_locked
        end
        nil
      end

      private

      def ensure_priority_support!
        parameters = @downstream_hook.method(:add).parameters
        supported = parameters.any? { |kind, name| name == :priority || kind == :keyrest }
        return if supported

        raise ArgumentError, 'ParserProjection requires DownstreamHook.add(priority:) support'
      end

      # Runs inline on Lich's socket reader before the line enters the parser
      # queue. A new input makes every preceding parser cut stale immediately.
      def input_received(_raw, event)
        @mutex.synchronize do
          return nil unless @installed

          bind_current_workers_locked
          invalidate_locked(reset_binding: false)
          @sequence += 1
          @latest_received_at = event.monotonic_received_at
        end
        nil
      rescue StandardError
        @mutex.synchronize { invalidate_locked }
        nil
      end

      # Runs inline after XML and game-specific parsing. DownstreamHook is a
      # transforming chain, so always return the supplied string unchanged.
      def dispatch_completed(server_string)
        received_at = @game.current_ingress_time
        @mutex.synchronize do
          unless publishable_locked?(received_at)
            @snapshot = nil
            return server_string
          end

          source = { connection_id: @connection_id, sequence: @sequence,
                     received_at: received_at }
          fields = {
            room: observed(room_value),
            right_hand: observed(item_value(@game_objects.right_hand)),
            left_hand: observed(item_value(@game_objects.left_hand)),
            roundtime_end: observed(@xml.roundtime_end),
            cast_roundtime_end: observed(@xml.cast_roundtime_end),
            standing: observed(@xml.indicator['IconSTANDING']),
            health: observed(health: @xml.health, max_health: @xml.max_health)
          }
          @snapshot = Schema.immutable(source: source, fields: fields)
        end
        server_string
      rescue StandardError
        @mutex.synchronize { @snapshot = nil }
        server_string
      end

      def publishable_locked?(received_at)
        @installed && live_binding_locked? && Thread.current.equal?(@parser) &&
          @connection_id && @sequence.positive? &&
          received_at.is_a?(Numeric) && received_at.finite? && received_at >= 0 &&
          received_at == @latest_received_at && !buffered_input? && !room_arrival_pending?
      end

      # XMLParser acquires Claim::Lock at NAV and releases it at compass after
      # collecting arriving players. One parsed input line is not necessarily a
      # completed room. Never wait on this mutex from the parser callback: that
      # same thread must continue parsing to release it.
      def room_arrival_pending? = @room_lock && @room_lock.locked?

      def buffered_input?
        instance = @game.game_instance
        instance && instance.respond_to?(:input_was_buffered) && instance.input_was_buffered
      end

      def bind_current_workers_locked
        parser = @game.thread
        reader = @game.reader_thread
        unless parser&.alive? && reader&.alive? && Thread.current.equal?(reader)
          invalidate_locked
          return false
        end

        unless parser.equal?(@parser) && reader.equal?(@reader)
          @parser = parser
          @reader = reader
          @connection_id = SecureRandom.hex(16).freeze
          @sequence = 0
        end
        true
      end

      def live_binding_locked?
        @parser && @reader && @parser.alive? && @reader.alive? &&
          @game.thread.equal?(@parser) && @game.reader_thread.equal?(@reader) &&
          !@game.closed? && !@game.remote_eof?
      end

      def invalidate_locked(reset_binding: true)
        @snapshot = nil
        @latest_received_at = nil
        return unless reset_binding

        @connection_id = nil
        @parser = nil
        @reader = nil
        @sequence = 0
      end

      def observed(value)
        { value: value, received_at: @latest_received_at, sequence: @sequence }
      end

      def room_value
        { uid: @xml.room_id, epoch: @xml.room_count, title: @xml.room_title,
          exits: Array(@xml.room_exits), exits_text: @xml.room_exits_string }
      end

      def item_value(item)
        return nil unless item && item.respond_to?(:id) && item.id

        { id: item.id.to_s, noun: item.noun, name: item.name }
      end

      def default_game = ::Game
      def default_xml = ::XMLData
      def default_game_objects = ::GameObj
      def default_socket_hook = ::Lich::Common::SocketReadHook
      def default_downstream_hook = ::DownstreamHook
      def default_room_lock = defined?(::Lich::Claim::Lock) ? ::Lich::Claim::Lock : nil
    end
  end
end
