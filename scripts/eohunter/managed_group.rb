# frozen_string_literal: true

module EO::Engine
  # Owner-thread adapter for one admitted run. The stable receiver owns the
  # mailbox and Script handle; all game work stays in this reloadable child.
  module ManagedGroup
    # Admission, preparation, native child or final handoff could not be proven.
    class Failed < StandardError; end

    # Rest, Loot and Travel's existing script seam with exact native ownership.
    # A stopping child remains busy until native teardown (including its own
    # children and before_dying handlers) actually completes.
    class Children
      # @param owner [Script] exact hunter which owns all activity children
      # @param scripts [Class] native Script API; injectable in offline tests
      def initialize(owner:, scripts: ::Script)
        @owner, @scripts, @children = owner, scripts, {}
      end

      # @param name [String] locally configured script name
      # @param args [String, nil] locally configured arguments
      # @return [Script] exact native owned handle
      # @raise [Failed] called outside its owner, duplicate, or native refusal
      def start(name, args = nil)
        raise Failed, 'child start outside the hunter owner' unless @scripts.current.equal?(@owner)
        key = name.to_s.downcase
        raise Failed, "owned child #{key} still cleaning up" if running?(key)

        child = @scripts.start_child(key, args, quiet: true)
        raise Failed, "could not start owned child #{key}" unless child

        @children[key] = child
      end

      # @param name [String] previously owned script name
      # @return [Boolean] includes asynchronous cleanup, not just execution
      # @raise [Failed] the completed native child has an exit error
      def running?(name)
        child = @children[name.to_s.downcase]
        return false unless child
        return true unless child.join(0)
        raise Failed, "owned child #{name} failed: #{child.exit_error}" if child.exit_error

        false
      end

      # @param name [String] previously owned script name
      # @return [Boolean] native paused state for that exact handle
      def paused?(name) = @children[name.to_s.downcase]&.paused? == true

      # Request native teardown; completion must still be observed separately.
      # @param name [String] previously owned script name
      # @return [Object, nil] native kill result, or no work to stop
      def kill(name)
        child = @children[name.to_s.downcase]
        child.kill(async: true) if child && !child.join(0) && !child.stopping?
      end

      # @return [Boolean] all retained children have completed native teardown
      def idle? = @children.keys.none? { |name| running?(name) }

      # Permit long-lived hunting helpers until Rest stops them in :leave.
      # @param names [Array<String>] profile hunting-script entries
      # @return [Boolean] every other child has released its native ownership
      def idle_except?(names)
        allowed = names.map { |entry| entry.to_s.split(/\s+/).first.downcase }
        (@children.keys - allowed).none? { |name| running?(name) }
      end

      # Cooperatively requested native teardown of all exact retained children.
      # @return [Array<String>] tracked names; this does not prove completion
      def stop_all
        @children.keys.each { |name| kill(name) }
      end
    end

    # Wins arbitration during startup and terminal recovery only. It delegates
    # each action to existing behaviors, and releases ordinary arbitration for
    # the entire hunting/rest cycle after the roster-wide commit.
    class Adapter < Behavior
      # @return [Symbol] local preparing/ready/committed/hunting/returning/safe
      attr_reader :phase

      # @param context [EO::HunterGroup::Context] stable exact-child mailbox
      # @param behaviors [Hash<Symbol, Object>] ordinary leader/follower builder output
      # @param world [World] native local observations
      # @param children [Children] exact local child lifecycle adapter
      # @param native_reader [#call] coordination parser projection
      # @param identity_reader [#call] live native connection/owner pin
      # @param leader [Group::Leader, nil] ordinary head, absent during recovery
      # @param member [Group::Member, nil] ordinary tail, absent during recovery
      def initialize(context:, behaviors:, world:, children:, native_reader:, identity_reader:, leader: nil, member: nil)
        super()
        @context, @behaviors, @world, @children = context, behaviors, world, children
        @leader, @member, @identity_reader = leader, member, identity_reader
        @cut = Group::NativeCut.new(reader: native_reader)
        @local_rest = Behaviors::Rest.new(policy: behaviors.fetch(:rest_policy), loot: behaviors.fetch(:loot),
                                          scripts: children, travel: ->(room) { Travel::Trip.new(room, scripts: children) })
        @local_rest.prepare_hands = behaviors.fetch(:loadout).method(:prepare)
        @phase = context.recovery? ? :returning : :preparing
        @local_rest.prepare_managed! unless context.recovery?
        @hands = context.prepared_hands if context.respond_to?(:prepared_hands)
        @hands ||= hand_ids(world) unless context.recovery?
        @return_started = false
        @candidate = nil
        @committed = false
        @completed_tick = 0
      end

      # @return [Integer] below urgent native survival, cleanse and flee
      def priority = 15
      # @return [String] arbiter status name
      def name = 'managed group'
      # @return [nil] preparation/return waits have no action-fire budget
      def fire_budget = nil
      # @return [Boolean] hold ordinary work while urgent native recovery runs
      def runs_muckled? = true
      # @param _world [World] unused; the mailbox phase owns the barrier
      # @return [Boolean] ordinary work is admitted only during hunting
      def wants_control?(_world) = @phase != :hunting
      # @return [Object] cancels only this adapter's local Rest travel
      def cancel! = @local_rest.cancel!

      # Once this adapter wins a cooperative handoff it owns subsequent
      # preemption notifications. Preserve native emergency cancellation of
      # the Loot transaction it is draining, and suspend its local Rest trip.
      # @param world [World] current observation supplied by the runner
      # @return [Object] local Rest suspension result, not cleanup completion
      def preempted!(world)
        begin
          @behaviors.fetch(:loot).preempted!(world) if @draining_loot
        ensure
          @draining_loot = false
          @local_rest.preempted!(world)
        end
      end

      # @param engine [Engine] exact local runner, attached once before execution
      # @return [Adapter] self, after installing owner tick and error observers
      def attach(engine)
        @engine = engine
        engine.on_tick { |world| observe(world) }
        engine.on_tick_completed { |world, tick, state| completed(world, tick, state) }
        Events.on(:engine_error) { |event| @failure = "#{event.data[:error]}: #{event.data[:message]}" }
        Events.on(:rest_stranded) { @failure = 'refuge return stranded' if @phase == :returning }
        self
      end

      # End the outing while retaining local native recovery authority.
      # @param reason [String] diagnostic reason retained until terminal handoff
      # @return [Object] local phase update; not proof of arrival or cleanup
      def request_return(reason = 'managed stop')
        return if @phase == :safe

        if @phase != :returning && @engine&.status&.dig(:behavior) == 'loot'
          @behaviors.fetch(:loot).preserve_next_preemption! { @engine.status[:behavior] == name }
        end
        @phase = :returning
        ::Lich::Messaging.msg('info', "eohunter: managed return: #{reason}") unless @reason
        @reason ||= reason
        @candidate = nil
      end

      # Consume the supervisor command and publish current local evidence.
      # @param world [World] current owner-thread observation
      # @return [Object] local mailbox report result
      def observe(world)
        command = @context.command
        request_return('supervisor requested return') if command == :return || @context.cancelled?
        request_return('local connection identity changed') unless @identity_reader.call
        if @phase == :hunting
          request_return('leader unavailable') if @member && (!@member.leader_alive? || @member.lost?)
          request_return('required member unavailable') if @leader && @leader.online.map(&:downcase).sort != @context.members.map(&:downcase).sort
          # The native party may temporarily disband under the existing
          # independent-travel/rest policy; check while actually hunting.
          resting = @behaviors.fetch(:rest).resting?
          # Room presence is not membership: native Muster/Follow owns
          # movement barriers and reunion. A room refresh can temporarily
          # clear PCs even though the physical party remains intact.
          request_return('physical party changed') unless resting || membership_valid?(world, require_presence: false)
        elsif %i[preparing ready committed].include?(@phase)
          ready = @candidate && ready_sample(world)
          @committed = false unless ready
          @context.report_ready(ready.merge(owner_tick: @candidate[:owner_tick])) if ready && !@committed
          if command == :commit && ready
            @context.report_committed(ready.merge(owner_tick: @candidate[:owner_tick]))
            @committed = true
            @phase = :committed
          elsif command == :hunt
            if @committed && ready
              raise Failed, 'required registrations changed before activation' if @leader && !@leader.hub.ready?

              @leader&.hub&.activate!
              @behaviors.fetch(:rest).depart_managed! if @leader
              @phase = :hunting
            else
              request_return('readiness changed before activation')
            end
          end
        end
        publish_state(world)
      end

      # Capture only after a real runner turn. Never a transport-worker callback.
      # @param world [World] native observations after the completed action
      # @param tick [Integer] monotonically increasing engine owner turn
      # @param state [Hash] native engine status from its completion callback
      # @return [Object, nil] local mailbox update, or stopped/held turn ignored
      def completed(world, tick, state)
        unless state[:state] == :running
          @candidate = nil
          @committed = false
          return publish_state(world)
        end

        @completed_tick = tick
        if %i[preparing ready committed].include?(@phase)
          sample = ready_sample(world)
          @candidate = sample && sample.merge(owner_tick: tick)
          @phase = :ready if sample && @phase == :preparing
          @phase = :preparing if !sample && @phase == :ready
        elsif @phase == :returning && @return_started && @local_rest.phase == :resting
          sample = safe_sample(world)
          if sample
            @phase = :safe
            @context.report_safe(sample.merge(owner_tick: tick))
            @engine.stop!(:managed_safe)
          end
        end
        publish_state(world)
      end

      # @param world [World] current native observations
      # @return [Actions::Result, nil] one existing preparation/recovery action
      # @raise [Failed] unsafe admission, failed prep, or unresolved local return
      def tick(world)
        if @phase == :returning
          return return_tick(world)
        end
        raise Failed, 'managed preparation left the approved refuge' unless world.room.id == @context.refuge_room
        raise Failed, 'managed preparation lost its native connection' unless @identity_reader.call

        unless @local_rest.managed_prepared?
          result = @local_rest.tick(world)
          raise Failed, 'local preparation failed' if result && !result.success?
          return result
        end
        loadout = @behaviors.fetch(:loadout)
        result = loadout.prepare(world)
        raise Failed, 'local equipment preparation failed' if loadout.stuck? || (result && !result.success?)
        return result if result
        return Actions::Stand.new(world).call unless world.me.standing?
        return nil if @children.idle? != true

        join_at_refuge(world) if @member && !membership_valid?(world)
        nil
      end

      # Called after engine.run, before native hunter teardown. The receiver
      # additionally waits for that exact native completion before clearing its
      # unresolved receipt. Errors never masquerade as a successful child exit.
      # @return [true] verified local return (receiver still awaits native exit)
      # @raise [Failed] the runner stopped without a verified local return
      def finish!
        return true if @phase == :safe

        reason = @failure || @engine.stop_reason || 'managed child ended without verified return'
        @context.report_unresolved(reason.to_s)
        raise Failed, reason.to_s
      end

      private

      def publish_state(world)
        @context.report_state(phase: @phase, room: world.room.id, hands: @hands,
                              reason: @reason,
                              ready: !!(@candidate && ready_sample(world)), owner_tick: @completed_tick,
                              native_children_pending: !@children.idle?)
      end

      def hand_ids(world)
        [world.hands.right, world.hands.left].map { |item| item&.id&.to_s }
      end

      def native_safe?(world)
        @identity_reader.call && world.room.id == @context.refuge_room &&
          world.me.dead? == false && world.me.standing? == true && world.me.muckled? == false &&
          world.me.in_rt? == false && world.me.in_cast_rt? == false &&
          world.room.targets.empty? && !world.hiders? &&
          !Travel.underway? && @children.idle? && !@behaviors.fetch(:loot).looting? &&
          !@behaviors.fetch(:engage).owns_hands?(world) && @behaviors.fetch(:loadout).satisfied?(world)
      end

      def ready_sample(world)
        @cut.capture(world) do
          next if @engine && (@engine.paused? || @engine.stopping?)
          next unless @local_rest.managed_prepared? && native_safe?(world) && membership_valid?(world)
          next unless EO::Engine::Rest::Predicates.not_hunting_reason(world.me, @behaviors.fetch(:rest_policy)).nil?

          { room: world.room.id, room_epoch: world.room.count, hands: hand_ids(world), ready: true }
        end
      end

      def safe_sample(world)
        @cut.capture(world) do
          next unless native_safe?(world) && @hands
          policy = @behaviors.fetch(:loadout_policy)
          actual = hand_ids(world)
          next unless [policy.right, policy.left].each_with_index.all? { |ref, index| ref.kind != :keep || actual[index] == @hands[index] }

          { room: world.room.id, room_epoch: world.room.count, hands: actual, safe: true }
        end
      end

      def membership_valid?(world, require_presence: true)
        grouped = world.group_nouns.map(&:downcase).sort
        if @member
          expected = ([@context.leader] + @context.members).map(&:downcase) - [@member.name.downcase]
          return false unless world.group_leader_noun.to_s.casecmp?(@context.leader)
        else
          expected = @context.members.map(&:downcase)
          return false unless world.group_leader_noun.nil?
        end
        return false unless grouped == expected.sort
        return true unless require_presence

        here = world.room.players.map { |player| player.noun.to_s.downcase }
        (expected - here).empty?
      end

      def join_at_refuge(world)
        raise Failed, 'conflicting native group membership' if world.group_leader_noun || world.group_nouns.any?
        raise Failed, 'local policy does not allow joining at refuge' unless @context.join_at_rally

        result = Actions::Join.new(world, leader: @context.leader).call
        raise Failed, "could not join approved leader: #{result.reason}" unless result.success?
      end

      def return_tick(world)
        raise Failed, @failure if @failure
        raise Failed, 'local connection unavailable for recovery' unless @identity_reader.call

        # Let eloot finish its owned transaction, including native teardown.
        loot = @behaviors.fetch(:loot)
        @draining_loot = loot.looting?
        return loot.tick(world) if @draining_loot
        unless @return_started
          Travel.active&.cancel!
          return nil unless @children.idle_except?(@behaviors.fetch(:rest_policy).hunting_script_list)
          # Every member returns independently, including a follower whose
          # Hub no longer exists. No remote orders are needed for this path.
          if world.group_leader_noun
            return Actions::LeaveGroup.new(world).call
          elsif world.group_nouns.any?
            return Actions::Disband.new(world).call
          end
          @behaviors.fetch(:engage).stand_down! if @behaviors.fetch(:engage).respond_to?(:stand_down!)
          @local_rest.request_return!(@reason || 'recovery-only return')
          @return_started = true
        end
        if @local_rest.phase == :resting
          @children.stop_all
          return nil unless @children.idle?
          result = @behaviors.fetch(:loadout).prepare(world)
          raise Failed, 'final equipment recovery failed' if @behaviors.fetch(:loadout).stuck? || (result && !result.success?)
          return result if result
          return Actions::Stand.new(world).call unless world.me.standing?
          return nil
        end
        @local_rest.tick(world)
      end
    end
  end
end
