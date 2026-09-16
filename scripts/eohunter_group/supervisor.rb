# frozen_string_literal: true

module ::EO
  # Persistent ownership for managed hunters, independent of Engine reloads.
  module HunterGroup
    # A mailbox shared only with the exact native child returned to its owner.
    # Child reports are evidence; only Supervisor changes commands.
    class Context
      # Immutable local startup policy and exact outing identity.
      attr_reader :run_id, :role, :profile, :leader_identity, :members, :refuge_room, :join_at_rally

      # Builds an inert mailbox; only a Supervisor may attach it to a child.
      def initialize(run_id:, role:, profile:, leader_identity:, members:, refuge_room:, join_at_rally: false,
                     hub_uri: nil, profile_settings: nil, prepared_hands: nil, clock: nil)
        @run_id, @role, @profile = run_id.freeze, role.to_sym, profile.freeze
        @leader_identity = Coordination::Schema.immutable(leader_identity)
        @members = Coordination::Schema.immutable(members)
        @refuge_room, @join_at_rally = refuge_room, join_at_rally
        @mutex = Mutex.new
        @command = recovery? ? :return : :prepare
        @report = { phase: :preparing }
        @hub_uri = hub_uri
        @profile_settings = profile_settings
        @prepared_hands = prepared_hands
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @progress_at = @clock.call
        @owner_tick = 0
        report_hub(hub_uri) if hub_uri
      end

      # @return [String] approved leader character
      def leader = @leader_identity[:character]
      # @return [Boolean] whether ordinary preparation/hunting is prohibited
      def recovery? = @role == :recover
      # @return [Boolean] whether cooperative return was requested
      def cancelled? = command == :return
      # @return [Symbol] current prepare, commit, hunt or return instruction
      def command = @mutex.synchronize { @command }
      # @return [String, nil] exact outing's loopback group hub
      def hub_uri = @mutex.synchronize { @hub_uri }
      # @return [Hash, nil] immutable original profile source
      def profile_settings = @mutex.synchronize { @profile_settings }
      # @return [Array, nil] original hand identifiers used by keep policy
      def prepared_hands = @mutex.synchronize { @prepared_hands }
      # @return [Hash] immutable latest child evidence
      def snapshot = @mutex.synchronize { Coordination::Schema.immutable(@report) }
      # @return [Float] monotonic seconds since the last native observation
      def observation_age = @mutex.synchronize { @observed_at ? @clock.call - @observed_at : Float::INFINITY }
      # @return [Float] monotonic seconds since a completed engine turn
      def progress_age = @mutex.synchronize { @clock.call - @progress_at }

      # Publishes the leader's local hub before follower preparation begins.
      def report_hub(uri)
        raise ArgumentError, 'invalid local hub URI' unless uri.to_s.match?(%r{\Adruby://127\.0\.0\.1:\d{1,5}\z})

        @mutex.synchronize { @hub_uri = uri.dup.freeze }
      end

      # Pins the child's validated source for crash recovery without reloading.
      def pin_profile(settings, digest)
        @mutex.synchronize do
          raise ArgumentError, 'profile already pinned' if @profile_settings && @report[:profile_digest] != digest

          @profile_settings = Coordination::Schema.immutable(settings)
          @report[:profile_digest] = digest
        end
      end

      # @return [Boolean] whether barrier evidence still has fresh native state
      def readiness_current?
        @mutex.synchronize do
          @observed_at && @clock.call - @observed_at <= 2.0 && @report.dig(:state, :ready) == true &&
            %i[ready committed].include?(@report[:phase])
        end
      end

      # Records native state; repeated owner ticks do not renew engine liveness.
      def report_state(payload)
        @mutex.synchronize do
          @report[:state] = Coordination::Schema.immutable(payload)
          @observed_at = @clock.call
          if payload[:owner_tick].is_a?(Integer) && payload[:owner_tick] > @owner_tick
            @owner_tick = payload[:owner_tick]
            @progress_at = @clock.call
          end
          @prepared_hands ||= Coordination::Schema.immutable(payload[:hands]) if payload[:hands]
          unless %i[safe unresolved].include?(@report[:phase])
            if payload[:phase] == :hunting && @command == :hunt
              @report[:phase] = :hunting
            elsif payload[:phase] == :returning
              @report[:phase] = :returning
            elsif payload[:ready] == false && %i[ready committed].include?(@report[:phase])
              @report[:phase] = :preparing
            end
          end
        end
      end

      # Reports a completed preparation turn with room and hand evidence.
      def report_ready(payload = {}) = report(:ready, payload)
      # Acknowledges commitment without authorizing departure.
      def report_committed(payload = {}) = report(:committed, payload)
      # Reports verified return; native teardown must still complete separately.
      def report_safe(payload = {}) = report(:safe, payload)
      # Retains an unconfirmed recovery condition for local intervention.
      def report_unresolved(reason) = report(:unresolved, { reason: reason.to_s })

      # Used by the owner, never by network callbacks.
      def instruct(command)
        raise ArgumentError, 'invalid managed command' unless %i[prepare commit hunt return].include?(command)

        @mutex.synchronize do
          return false if @command == :return && command != :return

          @command = command
        end
      end

      private

      def report(phase, payload)
        @mutex.synchronize do
          return false if %i[safe unresolved].include?(@report[:phase])
          return false if @command == :return && %i[ready committed].include?(phase)

          @report = @report.merge(phase: phase, evidence: Coordination::Schema.immutable(payload))
          @prepared_hands = Coordination::Schema.immutable(payload[:hands]) if phase == :ready && payload[:hands]
        end
      end
    end

    @bindings_mutex = Mutex.new
    @bindings = {}.compare_by_identity

    # Publishing happens after native startup returns. A fast child waits here;
    # a guessed command-line token or another eohunter instance cannot bind.
    def self.await_context(script, timeout: 10.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        context = @bindings_mutex.synchronize { @bindings[script] }
        return context if context
        raise 'managed hunter has no exact supervisor binding' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end

    # Associates only the native handle actually returned to the owner.
    def self.bind(script, context)
      raise ArgumentError, 'missing child handle' unless script

      @bindings_mutex.synchronize do
        raise 'child already bound' if @bindings.key?(script)

        @bindings[script] = context
      end
    end

    # Releases a binding only after the owner observed native completion.
    def self.unbind(script)
      @bindings_mutex.synchronize { @bindings.delete(script) }
    end

    # One local run slot with nonblocking native lifecycle observation. Recovery
    # may start only after join(0) confirms all native teardown has completed.
    class Supervisor
      # Current mailbox, exact native child, and outing identifier.
      attr_reader :context, :child, :run_id

      # Captures the required native Script owner and restores any safety hold.
      def initialize(scripts:, journal:, busy:, clock: nil, startup_seconds: 90, recovery_seconds: 180)
        @scripts, @journal, @busy = scripts, journal, busy
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @owner_thread, @owner_script = Thread.current, scripts.current
        raise 'supervisor requires a native Script owner' unless @owner_script

        @startup_seconds, @recovery_seconds = startup_seconds, recovery_seconds
        @phase = @journal.pending ? :unresolved : :idle
        @reason = 'unreconciled previous outing' if @phase == :unresolved
      end

      # @return [Boolean] whether the local run slot can accept new preparation
      def available? = %i[idle safe].include?(@phase) && @child.nil?

      # @return [Hash] run outcome separate from native child completion
      def status
        { run_id: @run_id, phase: @phase, reason: @reason, hub_uri: @context&.hub_uri,
          report: @context&.snapshot, child_pending: !@child.nil? }
      end

      # Reserves the local slot, persists its hold, and starts one owned child.
      def prepare(**configuration)
        assert_owner!
        if @run_id == configuration[:run_id]
          raise 'run configuration changed' unless @configuration == configuration

          return status
        end
        raise 'local run is busy or unresolved' unless available?
        raise 'unrelated local activity owns the character' if @busy.call

        @configuration = Coordination::Schema.immutable(configuration)
        @run_id = configuration.fetch(:run_id)
        @reason = nil
        @context = Context.new(**configuration, clock: @clock)
        @journal.record(run_id: @run_id, leader: configuration.fetch(:leader_identity),
                        refuge_room: configuration.fetch(:refuge_room))
        @phase = :preparing
        @deadline = @clock.call + @startup_seconds
        @recovery_started = false
        @evidence_recorded = false
        @evidence_failed = false
        launch(@context)
        status
      rescue StandardError => error
        if @run_id == configuration[:run_id] && @phase == :preparing
          @phase, @reason = :unresolved, error.message
        end
        raise
      end

      # Explicit local restart recovery uses the previously pinned policy and
      # original hand evidence; missing evidence never becomes a fresh hunt.
      def recover(run_id:, profile:, leader_identity:, refuge_room:, profile_settings:, prepared_hands:)
        assert_owner!
        raise 'recovery requires an unresolved run with completed native teardown' unless @phase == :unresolved && !@child
        raise 'unrelated local activity owns the character' if @busy.call
        unless profile_settings.is_a?(Hash) && prepared_hands.is_a?(Array) && prepared_hands.size == 2
          raise 'original profile or hand evidence unavailable; manual intervention required'
        end
        pending = @journal.pending
        unless pending && pending['run_id'] == run_id && pending['profile'] == profile &&
               pending['settings'] == profile_settings && pending['hands'] == prepared_hands
          raise 'recovery does not match the persisted original outing'
        end

        @configuration = { run_id: run_id, role: :recover, profile: profile, leader_identity: leader_identity,
                           members: [], refuge_room: refuge_room, profile_settings: profile_settings, prepared_hands: prepared_hands }
        @run_id = run_id
        @context = Context.new(**@configuration, clock: @clock)
        @phase, @deadline = :returning, @clock.call + @recovery_seconds
        @recovery_started = @evidence_recorded = true
        launch(@context)
        status
      rescue StandardError => error
        @phase, @reason = :unresolved, error.message
        raise
      end

      # Requests acknowledgment from a currently prepared child.
      def commit(run_id:)
        assert_run!(run_id)
        return status if %i[committed hunting].include?(@phase)
        raise 'local child is not ready' unless @phase == :ready && @context.snapshot[:phase] == :ready && @context.readiness_current?

        @context.instruct(:commit)
        @phase = :committing
        status
      end

      # Opens hunting only after the child acknowledged fresh commitment.
      def hunt(run_id:)
        assert_run!(run_id)
        return status if @phase == :hunting
        raise 'local child has not acknowledged commitment' unless @phase == :committed && @context.snapshot[:phase] == :committed && @context.readiness_current?

        @context.instruct(:hunt)
        @phase = :hunting
        status
      end

      # Requests cooperative local return without interrupting native teardown.
      def cancel(run_id: @run_id, reason: 'operator stop')
        assert_run!(run_id)
        return status if @phase == :safe

        @reason = reason.to_s
        @context&.instruct(:return)
        unless %i[returning unresolved].include?(@phase)
          @deadline = @clock.call + @recovery_seconds
          @phase = :returning
        end
        status
      end

      # Advances the owner once, using only nonblocking child observation.
      def tick
        assert_owner!
        return status unless @child

        report = @context.snapshot
        persist_evidence
        cancel(reason: 'hunter owner stopped completing turns') if @phase == :hunting && @context.progress_age > 120
        cancel(reason: 'hunter requested local return') if report[:phase] == :returning && @phase != :returning
        if report[:phase] == :unresolved
          @reason = report.dig(:evidence, :reason) || 'child could not confirm recovery'
          @phase = :unresolved
          @context.instruct(:return)
        elsif @phase == :preparing && report[:phase] == :ready
          @phase = :ready
        elsif %i[ready committed].include?(@phase) && (!@context.readiness_current? || report[:phase] == :preparing)
          @phase = :preparing
        elsif @phase == :committing && report[:phase] == :committed
          @phase = :committed
        end

        # running? alone is insufficient: registry removal may precede cleanup.
        if @child.join(0)
          finish_child(report)
        elsif @deadline && @clock.call >= @deadline && @phase != :hunting
          if %i[returning unresolved].include?(@phase)
            @phase, @reason = :unresolved, 'recovery or native teardown deadline exceeded'
          else
            cancel(reason: 'startup deadline exceeded')
          end
        end
        status
      end

      private

      def assert_owner!
        raise ThreadError, 'run progression requires exact native owner' unless Thread.current == @owner_thread && @scripts.current.equal?(@owner_script)
      end

      def persist_evidence
        return if @evidence_recorded || @evidence_failed || !@journal.respond_to?(:record_evidence)
        return unless @context.profile_settings && @context.prepared_hands

        @journal.record_evidence(run_id: @run_id, profile: @context.profile,
                                 settings: @context.profile_settings, hands: @context.prepared_hands)
        @evidence_recorded = true
      rescue StandardError => error
        @evidence_failed = true
        cancel(reason: "could not persist original recovery evidence: #{error.message}")
      end

      def assert_run!(run_id)
        assert_owner!
        raise ArgumentError, 'wrong run' unless run_id && run_id == @run_id
      end

      def launch(context)
        assert_owner!
        # The fixed script and mode are implementation policy, never peer data.
        @child = @scripts.start_child('eohunter', args: [context.profile, context.role.to_s, 'managed'])
        raise 'native hunter startup refused' unless @child

        HunterGroup.bind(@child, context)
      end

      def finish_child(report)
        completed = @child.completed_successfully?
        HunterGroup.unbind(@child)
        @child = nil
        if completed && report[:phase] == :safe && report.dig(:evidence, :safe) == true
          raise 'safe handoff journal could not be cleared' unless @journal.clear(run_id: @run_id, safe: true)
          @phase = :safe
        elsif !@recovery_started && @context.profile_settings
          @reason ||= 'hunter exited without verified safe handoff'
          @recovery_started = true
          @phase, @deadline = :returning, @clock.call + @recovery_seconds
          @context = Context.new(**@configuration.merge(role: :recover, profile_settings: @context.profile_settings,
                                                        prepared_hands: @context.prepared_hands), clock: @clock)
          launch(@context)
        else
          @phase = :unresolved
          @reason ||= 'child exited without verified recovery'
        end
      rescue StandardError => error
        @phase, @reason = :unresolved, error.message
      end
    end
  end
end
