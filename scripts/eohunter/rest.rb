# frozen_string_literal: true

# ============================================================================
# rest (bigshot's ready_to_rest? / ready_to_hunt? and the rest cycle)
# ============================================================================

#
# EO::Engine::Rest - when to stop hunting, when to start again, and the
# trip between. The predicates are pure (a Me, a Policy, the counters);
# the cycle is a Behavior that takes one step per tick. Rules and bigshot
# line references in hunting-engine-plan.md, "Rest".
#
module EO::Engine
  # When to stop hunting, when to start again, and the trip between. The
  # predicates are pure (a Me, a Policy, the counters); the cycle is a
  # Behavior that takes one step per tick. Rules and bigshot line
  # references in hunting-engine-plan.md, "Rest".
  module Rest
    # The profile's rest settings. Thresholds are percentages unless noted.
    # +wounded+ is a callable (the profile's wounded_eval, compiled once);
    # nil means never wounded.
    Policy = Struct.new(
      :fried, :overkill, :lte_boost, :oom, :encumbered, :use_wracking, :wracking_spirit,
      :creeping_dread, :crushing_dread, :wot_poison, :confusion, :wounded,
      :rest_till_exp, :rest_till_mana, :rest_till_spirit, :rest_till_stamina,
      :resting_room, :return_waypoints, :hunting_room, :rally_rooms,
      :fog_return, :fog_optional, :fog_rift, :custom_fog,
      :resting_commands, :resting_scripts, :hunting_prep_commands, :hunting_scripts,
      :wander_stance, :rest_interval, :sneaky, :encumbrance_grace, :sites, :preparations,
      keyword_init: true
    ) do
      # The fried threshold; 101 (never) when the profile leaves it blank.
      # @return [Integer] mind percentage
      def fried_pct     = (fried || 101).to_i
      # Kills past fried before resting; 0 when blank.
      # @return [Integer]
      def overkill_max  = (overkill || 0).to_i
      # LTE boosts the profile allows per rest cycle; 0 when blank.
      # @return [Integer]
      def lte_boost_max = (lte_boost || 0).to_i
      # The out-of-mana threshold; -1 (off) when blank.
      # @return [Integer] mana percentage
      def oom_pct       = (oom || -1).to_i
      # The encumbrance threshold; 101 (never) when blank.
      # @return [Integer] encumbrance percentage
      def encumbered_pct = (encumbered || 101).to_i
      # The Creeping Dread level that rests us; 0 (off) when blank.
      # @return [Integer]
      def creeping_dread_at = (creeping_dread || 0).to_i
      # The Crushing Dread level that rests us; 0 (off) when blank.
      # @return [Integer]
      def crushing_dread_at = (crushing_dread || 0).to_i
      # Mind must fall to this before hunting again; 0 when blank.
      # @return [Integer] mind percentage
      def rest_till_exp_pct     = (rest_till_exp || 0).to_i
      # Mana must reach this before hunting again; 0 when blank.
      # @return [Integer] mana percentage
      def rest_till_mana_pct    = (rest_till_mana || 0).to_i
      # Spirit must reach this before hunting again; 0 when blank.
      # @return [Integer] spirit points, not a percentage
      def rest_till_spirit_min  = (rest_till_spirit || 0).to_i
      # Stamina must reach this before hunting again; 0 when blank.
      # @return [Integer] stamina percentage
      def rest_till_stamina_pct = (rest_till_stamina || 0).to_i
      # The return waypoints as a list, empty when blank.
      # @return [Array<Integer>] Lich room ids
      def return_waypoint_ids = Array(return_waypoints)
      # The rally rooms as a list, empty when blank.
      # @return [Array<Integer>] Lich room ids
      def rally_room_ids      = Array(rally_rooms)
      # The commands sent at the resting room, empty when blank.
      # @return [Array<String>]
      def resting_command_list      = Array(resting_commands)
      # The scripts started at the resting room, empty when blank.
      # @return [Array<String>] "name args" entries
      def resting_script_list       = Array(resting_scripts)
      # The commands sent before a hunt, empty when blank.
      # @return [Array<String>]
      def hunting_prep_command_list = Array(hunting_prep_commands)
      # The scripts started before a hunt, empty when blank.
      # @return [Array<String>] "name args" entries
      def hunting_script_list       = Array(hunting_scripts)
      # Seconds between ready_to_hunt? checks while resting; 30 when blank.
      # @return [Float]
      def interval = (rest_interval || 30).to_f
    end

    # The fog home (bigshot fog_return 6463 for methods 1-5): Lich's
    # Lich::Gemstone::Fog (lich-5 #1584). The custom method (6) is Rest's own.
    # @bigshot fog_return
    module Fog
      # One blocking fog trip home by the policy's method.
      #
      # @param policy [Rest::Policy] fog_return, fog_rift and resting_room
      # @return [Boolean] whether Lich's Fog reports the room changed
      def self.return(policy)
        ::Lich::Gemstone::Fog.return(policy.fog_return, rift: policy.fog_rift, resting_room: policy.resting_room)
      end
    end

    # Per-run counters bigshot keeps in globals: kills past fried
    # (add_overkill 7302) and LTE boosts redeemed (use_lte_boost 7083).
    # Both reset when a rest begins (rest 6261-6263).
    # @bigshot add_overkill
    # @bigshot use_lte_boost
    Counters = Struct.new(:overkill, :lte_boosts, keyword_init: true) do
      # Both counters start at zero.
      #
      # @param overkill [Integer] kills past fried so far
      # @param lte_boosts [Integer] boosts redeemed so far
      def initialize(overkill: 0, lte_boosts: 0) = super
      # Zero both counters, as a rest beginning does (rest 6261-6263).
      # @return [Integer] 0
      def reset! = self.overkill = self.lte_boosts = 0
    end

    # bigshot's rest tests, pure: each reads a Me, a Policy and the
    # counters and never sends anything.
    module Predicates
      class << self
        # bigshot fried?: mind at or past the fried threshold; a
        # threshold above 100 disables it.
        #
        # @bigshot fried?
        # @param me [World::Me]
        # @param policy [Rest::Policy]
        # @return [Boolean]
        def fried?(me, policy)
          return false if policy.fried_pct > 100

          me.fxp_pct >= policy.fried_pct
        end

        # bigshot lte_boost?: every boost the profile allows is spent.
        #
        # @bigshot lte_boost?
        # @param counters [Rest::Counters]
        # @param policy [Rest::Policy]
        # @return [Boolean]
        def lte_boosts_spent?(counters, policy) = counters.lte_boosts >= policy.lte_boost_max

        # bigshot overkill?: enough extra kills after the boosts.
        #
        # @bigshot overkill?
        # @param counters [Rest::Counters]
        # @param policy [Rest::Policy]
        # @return [Boolean]
        def overkill?(counters, policy) = counters.overkill >= policy.overkill_max && lte_boosts_spent?(counters, policy)

        # Mana below the oom threshold; a negative threshold disables it.
        #
        # @param me [World::Me]
        # @param policy [Rest::Policy]
        # @return [Boolean]
        def oom?(me, policy)
          return false if policy.oom_pct.negative?

          me.mana_pct < policy.oom_pct
        end

        # A stacking dread debuff at or past the profile's level; 0 disables it.
        #
        # @param me [World::Me]
        # @param kind [String] "Creeping Dread" or "Crushing Dread"
        # @param at [Integer] the level that counts
        # @return [Boolean]
        def dread?(me, kind, at)
          return false unless at.positive?

          level = me.debuff_level(kind)
          !level.nil? && level >= at
        end

        # bigshot ready_to_rest?, in its order. The first reason wins.
        #
        # @bigshot ready_to_rest?
        # @param me [World::Me]
        # @param policy [Rest::Policy]
        # @param counters [Rest::Counters]
        # @param forced [String, nil] a reason set from elsewhere
        #   ($bigshot_should_rest with $rest_reason)
        # @param looting [Boolean] the owned loot work has not finished stowing
        #   items; defer only the transient encumbrance check until it settles
        # @param encumbered [Boolean, nil] settled decision; nil uses raw weight
        # @return [String, nil] the rest reason, nil to keep hunting
        def rest_reason(me, policy, counters, forced: nil, looting: false, encumbered: nil)
          return forced if forced
          return 'wounded.' if policy.wounded&.call
          return 'fried.' if fried?(me, policy) && overkill?(counters, policy)
          overweight = encumbered.nil? ? me.encumbrance_pct >= policy.encumbered_pct : encumbered
          return 'encumbered.' if !looting && overweight
          return 'creeping dread limit.' if dread?(me, 'Creeping Dread', policy.creeping_dread_at)
          return 'crushing dread limit.' if dread?(me, 'Crushing Dread', policy.crushing_dread_at)
          return 'wall of thorns poison.' if policy.wot_poison && me.debuff_active?('Wall of Thorns Poison')
          return 'confusion debuff.' if policy.confusion && me.debuff_active?('Confused')
          return 'out of mana.' if oom?(me, policy)

          nil
        end

        # All active reasons for two-site routing. Legacy callers retain the
        # first-reason interface; only destination selection needs the full set.
        # @param me [World::Me] current character state
        # @param policy [Policy] shared recovery thresholds
        # @param counters [Counters] fried bookkeeping
        # @param encumbered [Boolean] settled overweight decision
        # @return [Array<String>] current reasons
        def rest_reasons(me, policy, counters, encumbered:)
          reasons = []
          reasons << 'wounded.' if policy.wounded&.call
          reasons << 'fried.' if fried?(me, policy) && overkill?(counters, policy)
          reasons << 'encumbered.' if encumbered
          reasons << 'creeping dread limit.' if dread?(me, 'Creeping Dread', policy.creeping_dread_at)
          reasons << 'crushing dread limit.' if dread?(me, 'Crushing Dread', policy.crushing_dread_at)
          reasons << 'wall of thorns poison.' if policy.wot_poison && me.debuff_active?('Wall of Thorns Poison')
          reasons << 'confusion debuff.' if policy.confusion && me.debuff_active?('Confused')
          reasons << 'out of mana.' if oom?(me, policy)
          reasons
        end

        # bigshot ready_to_hunt?, in its order: why we are still
        # resting, or nil when ready.
        #
        # @bigshot ready_to_hunt?
        # @param me [World::Me]
        # @param policy [Rest::Policy]
        # @param scripts_running [Array<String>] resting scripts still running
        # @return [String, nil] the reason to keep resting, nil when ready
        def not_hunting_reason(me, policy, scripts_running: [])
          return 'wounded.' if policy.wounded&.call
          return 'encumbered.' if me.encumbrance_pct >= policy.encumbered_pct
          return 'creeping dread active.' if dread?(me, 'Creeping Dread', policy.creeping_dread_at)
          return 'crushing dread active.' if dread?(me, 'Crushing Dread', policy.crushing_dread_at)
          return 'confusion debuff active.' if policy.confusion && me.debuff_active?('Confused')
          return 'wall of thorns poison active.' if policy.wot_poison && me.debuff_active?('Wall of Thorns Poison')
          return 'resting scripts are still running.' if scripts_running.any?
          return 'mind still above threshold.' if me.fxp_pct > policy.rest_till_exp_pct
          return 'mana still below threshold.' if me.mana_pct < policy.rest_till_mana_pct
          return 'spirit still below threshold.' if me.spirit < policy.rest_till_spirit_min
          return 'stamina still below threshold.' if me.stamina_pct < policy.rest_till_stamina_pct

          nil
        end
      end
    end
  end

  module Actions
    # One profile command line, sent through the ladder with no
    # confirmation beyond the first answer (bigshot prep_and_rest_commands
    # 5890: fput, then a 0.3 s breath).
    # @bigshot prep_and_rest_commands
    class Command < Base
      # @param world [World]
      # @param command [String, #to_s] the line to send
      # @param allow_dead [Boolean] send it even while dead (QUIT)
      # @param opts [Hash] passed to Base (interrupt and the rest)
      def initialize(world, command:, allow_dead: false, **opts)
        super(world, **opts)
        @command = command.to_s
        @allow_dead = allow_dead
      end

      # Dead blocks the send unless allow_dead was given.
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? && !@allow_dead ? :dead : :ok

      # Whether Base may run this while dead.
      # @return [Boolean] the allow_dead flag
      def dead_ok? = @allow_dead

      # The line through the ladder, then a 0.3 s breath.
      # @return [Actions::Result] success with the first answer as its line,
      #   or the ladder's failure
      def perform
        first = send_through_ladder(@command)
        return first if first.is_a?(Result)

        sleep 0.3
        Result.new(status: :success, line: first)
      end
    end

    # BOOST LONGTERM when fried and boosts remain (bigshot use_lte_boost
    # 7083). Updates the counters the way bigshot does: a redeemed boost
    # counts one and clears the overkill count; none left marks every
    # boost spent so overkill takes over.
    # @bigshot use_lte_boost
    class LteBoost < Base
      # The game's answer when no boosts remain.
      NONE_LEFT = /You do not have any Long-Term Experience Boosts to redeem\./
      # The game's answer when a boost was redeemed.
      REDEEMED  = /You have deducted 500 experience points from your field experience/

      # @param world [World]
      # @param counters [Rest::Counters] updated by perform
      # @param policy [Rest::Policy] the fried threshold and the boost cap
      # @param opts [Hash] passed to Base
      def initialize(world, counters:, policy:, **opts)
        super(world, **opts)
        @counters = counters
        @policy = policy
      end

      # Alive, fried, and boosts left to redeem.
      # @return [Symbol] :ok, :dead, :not_fried or :none_left
      def preconditions
        return :dead if me.dead?
        return :not_fried unless EO::Engine::Rest::Predicates.fried?(me, @policy)
        return :none_left if EO::Engine::Rest::Predicates.lte_boosts_spent?(@counters, @policy)

        :ok
      end

      # BOOST LONGTERM and read which answer came back.
      # @return [Actions::Result] the match result; :failed with :none_left
      #   when the game had no boost to redeem
      def perform
        result = send_and_match('boost longterm', Regexp.union(NONE_LEFT, REDEEMED), timeout: 3)
        return result unless result.success?

        if result.line =~ NONE_LEFT
          @counters.lte_boosts = @policy.lte_boost_max
          Result.new(status: :failed, reason: :none_left, line: result.line)
        else
          @counters.lte_boosts += 1
          @counters.overkill = 0
          result
        end
      end
    end
  end

  module Behaviors
    # The rest cycle (bigshot rest 7440 then hunt 7429 / pre_hunt 7242),
    # one step per tick so pause and stop land between steps:
    #
    #   final_loot -> wait_followers -> leave -> fog -> waypoints -> resting_room
    #   -> resting_prep -> resting -> hunting_prep -> rally -> hunting_room -> done
    #
    # The final loot (should_rest? 9041) is Rest's own phase: Rest outranks
    # Loot, so a request left for Loot to pick up would never get a tick
    # before we left the room. Rest drives Loot's ticks itself until Loot
    # has nothing more to do, then leaves. Trips go through Travel and
    # are suspended while a higher behavior holds control. The fog still
    # blocks (Lich's Fog module).
    #
    # With a group (a Group::Leader with followers), every wait bigshot's
    # leader makes is a :hold between phases: followers done looting and
    # out of roundtime before leaving, everyone present after each
    # waypoint and at the resting room, everyone rested
    # (7569), and the pre_hunt gathers; the
    # orders go out where bigshot's add_event calls are. Independent
    # travel and return disband instead and order the followers' own
    # trips.
    class Rest < Behavior
      GO2_ATTEMPTS = 5 # bigshot goto
      # Seconds to wait after a room's five attempts fail before trying again
      STUCK_RETRY_WAIT = 60
      # Rounds of five attempts before the return is given up where we stand
      STUCK_RETRIES = 3
      CUSTOM_FOG = 6 # bigshot fog_return 6: the profile's custom_fog commands
      # Rest reasons that get a final loot before leaving (should_rest? 9041)
      FINAL_LOOT_REASONS = /dread limit|bounty complete|fried|out of mana|encumbered/
      # Ticks the final loot may take before Rest leaves anyway
      FINAL_LOOT_TICKS = 60
      # Seconds between follow_now orders while holding for followers
      REORDER = 10
      # Departure phases are outside the field recovery timeout.
      DEPARTURE_PHASES = %i[hunting_prep hunting_prep_own rally_out rally hunting_scripts hunting_scripts_own hunting_room arrived done].freeze
      # Ticks to wait for the game's group to empty after DISBAND
      DISBAND_TICKS = 40
      # Phases moving from a refuge toward the hunting area. A new rest
      # condition in any of these aborts the outbound lifecycle.
      OUTBOUND_PHASES = %i[
        hunting_prep hunting_prep_own rally_out rally hunting_scripts
        hunting_scripts_own hunting_room arrived done
      ].freeze

      # The cycle's current step; :hunting between rests.
      # @return [Symbol]
      attr_reader :phase
      # Why this rest began; nil while hunting.
      # @return [String, nil]
      attr_reader :reason
      # A rest asked for from outside the predicates (rest!), not yet
      # begun; nil otherwise. A follower reports it to the leader.
      # @return [String, nil]
      attr_reader :forced_reason
      # Selected logical rest destination, independent of the actual room.
      # @return [Symbol] field or town
      attr_reader :rest_site

      # Native restoration remains owned by Maintain; called only at refuge.
      # @return [#call, nil] (World) -> Actions::Result or nil
      attr_writer :restore_buffs

      # Optional equipment preparation supplied by the profile's Loadout.
      # Only outbound Rest steps invoke it; go2 retains travel ownership.
      # @return [#call, nil] (World) -> Actions::Result or nil
      attr_writer :prepare_hands

      # @param policy [Rest::Policy]
      # @param counters [Rest::Counters]
      # @param travel [#call] (room) -> Trip or Boolean; default a Travel trip
      # @param fog [#call] (policy, reason) -> Boolean; default Rest::Fog.return
      # @param scripts [Object] start(name, args), running?(name), kill(name); default Lich's Script
      # @param stance [#call] (name) -> Boolean; default Lich::Gemstone::Stance.change
      # @param loot [Behaviors::Loot, nil] driven for the final loot; nil skips it
      # @param group [Group::Leader, nil] the followers to wait for and order
      # @param clock [#now] the time source for the rest interval and holds
      # @param buffs [BuffPolicy::Coordinator, nil] opt-in required effects
      def initialize(policy:, counters: EO::Engine::Rest::Counters.new, travel: nil, fog: nil, scripts: nil, stance: nil, loot: nil,
                     group: nil, clock: EO::Engine::Rest::Clock, buffs: nil)
        super()
        @policy = policy
        @town_policy = policy
        @sites = policy.sites || EO::Engine::Rest::Sites.new
        raise ArgumentError, 'Field/Town Rest currently requires solo mode' if @sites.enabled? && group && !group.solo?
        raise ArgumentError, 'combat_buffs currently requires solo mode' if buffs&.enabled? && group && !group.solo?

        @rest_site = :town
        @counters = counters
        @travel = travel || EO::Engine::Travel.default
        @trip = nil
        @loot = loot
        @group = group
        @fog = fog || ->(pol, _reason) { EO::Engine::Rest::Fog.return(pol) }
        @scripts = scripts || LichScripts
        @stance = stance || ->(name) { ::Lich::Gemstone::Stance.change(name) }
        @clock = clock
        @buffs = buffs
        @buff_serviced = false
        @buff_gate_started = nil
        @encumbrance = EO::Engine::Rest::Encumbrance.new(seconds: policy.encumbrance_grace || 5, clock: clock)
        @phase = :hunting
        @reason = nil
        @forced_reason = nil
        @hold = nil
        @next_rest_check_at = nil
      end

      # Rest sits between Muster (15) and Loot (30).
      # @return [Integer] 20
      def priority = 20

      # The trip home and back steps through rooms faster than the
      # engine's fire budget.
      # @return [nil] no budget
      def fire_budget = nil

      # Something outside the predicates decided we rest (bigshot's
      # $bigshot_should_rest): an unknown command result, an unreachable
      # room, a bounty complete.
      #
      # @param reason [String] the rest reason to report
      # @return [String] the reason
      def rest!(reason)
        @forced_reason = reason
      end

      # A required preparation was denied or uncertain. Use the existing town
      # return and suppress further preparations until the player restarts.
      # This records a terminal hunt failure, never an inferred item state.
      # @param reason [String] failed preparation and action outcome
      # @return [Boolean] true
      def preparation_failed!(reason)
        @preparation_failure ||= reason
        request_return!(@preparation_failure)
      end

      # A controller return is not a new hunting decision. Cancel only this
      # behavior's outbound trip and enter the existing return path directly;
      # the ordinary rest machinery still owns stance, waypoints, refuge and
      # resting preparation.
      #
      # @param reason [String] the reason recorded for this return
      # @param final_loot [Boolean] run Loot's final pass first, when Loot is wired
      # @param site [Symbol] :town by default; :field for an explicit buff recovery
      # @return [Boolean] true
      def request_return!(reason, final_loot: false, site: :town)
        raise ArgumentError, 'return site must be field or town' unless %i[field town].include?(site)
        site = :town if site == :field && !@sites.enabled?
        same_site = @rest_site == site
        select_site(site)
        @reason = reason
        @forced_reason = nil
        return true if same_site && %i[leave fog custom_fog disband waypoints resting_room resting_prep resting_prep_own rested resting].include?(@phase)

        EO::Engine::Travel.cancel(self)
        @remaining = nil
        @hold = nil
        @rested_emitted = false
        @next_rest_check_at = nil
        @stuck = nil
        @attempts = 0
        @stranded = false
        @buff_serviced = false
        @buff_gate_started = nil
        if final_loot && @loot
          @loot.final!
          @final_loot_ticks = 0
          @phase = :final_loot
        else
          @phase = :leave
        end
        true
      end

      # Any phase but :hunting is a rest in progress.
      # @return [Boolean]
      def resting? = @phase != :hunting

      # The phases where signs belong: standing in the hunting room, and
      # hunting from it. bigshot's pre_hunt casts them at the hunting room
      # (7315-7341), and Rest's :arrived issues the cast_signs group order
      # there. Everything else - the refuge wait, the trip home, the trip
      # back out - is either parked or travelling, and a sign cast then
      # burns for the whole walk and dissipates before the first fight.
      #
      # Anything wanted earlier goes in the hunting prep commands, which
      # are sent to the game verbatim, the way bigshot does it.
      # :hold is not listed: it is the shared wait for nine different
      # steps, including the disband and the rally on the way out. Only
      # the one that lands at the hunting room counts, so it is tested
      # through the hold's own destination rather than the phase.
      SIGNS_PHASES = %i[arrived done hunting].freeze

      # Whether signs are wanted now, as opposed to held for the walk.
      # @return [Boolean]
      def signs_phase?
        return true if SIGNS_PHASES.include?(@phase)

        @phase == :hold && @hold.is_a?(Hash) && @hold[:why] == :at_hunting_room
      end

      # bigshot pre_hunt: the hunting prep commands and scripts,
      # the rally rooms and the hunting room before the first fight. The
      # same cycle as the back half of a rest.
      # @bigshot pre_hunt
      # @param world [World, nil] selects field departure when starting there
      # @return [Symbol] :hunting_prep
      def start!(world = nil)
        select_site(:field) if @sites.enabled? && world&.room&.id == @sites.room
        @reason = 'starting'
        @phase = :hunting_prep
      end

      # Managed startup runs the same local prep commands, but cannot cross
      # the rally/departure boundary until every admitted owner commits.
      def prepare_managed!
        @reason = 'managed preparation'
        @remaining = nil
        @phase = :managed_preparation
      end

      def managed_prepared? = @phase == :managed_ready

      # The leader has already performed its local preparation at refuge.
      # Later ordinary rest cycles retain the normal group prep orders.
      def depart_managed!
        @reason = 'starting'
        @remaining = nil
        @phase = :rally_out
      end

      # The engine's stop: end a trip in flight.
      # @return [void]
      def cancel! = EO::Engine::Travel.cancel(self)

      # Another behavior took control (Survival, Cleanse, Flee): hold the
      # trip; it resumes with the next step.
      # @param _world [World] unused
      # @return [void]
      def preempted!(_world) = EO::Engine::Travel.suspend(self)

      # While resting, always; while hunting, when rest_reason (ours joined
      # with the followers' when grouped) names a reason.
      #
      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        return true if resting?

        @reason = current_rest_reason(world)
        !@reason.nil?
      end

      # One step of the phase we are in. From :hunting, a wracking mana
      # recovery is tried first when the policy allows; if it clears the
      # reason, no rest begins.
      #
      # @param world [World]
      # @return [Actions::Result, nil] the step's action result, nil when the
      #   step only advanced the phase
      def tick(world)
        return nil if %i[service_failed town_complete].include?(@phase)
        return Actions::Result.new(status: :success, reason: :town_escalation) if escalate_field(world)

        # Check preparation and travel handoffs, never while go2 owns a trip
        # or a preparation child is running. Disabled policies are inert.
        #
        # Ahead of the outbound abort below: a missing combat buff is this
        # policy's own business, and it prepares in place at the rally and
        # hunting-room phases rather than turning the trip around.
        if @buffs&.enabled? && !@trip && %i[rally_out hunting_room].include?(@phase)
          result = prepare_buffs(world)
          return result if result
        end

        # Stop the outbound trip now, but do not begin return commands in the
        # same tick. Survival or Cleanse gets the next arbitration pass first
        # if the event also knocked us down, stunned, webbed, or bound us.
        return nil if outbound? && abort_outbound_if_needed(world)

        case @phase
        when :managed_preparation then step_prep(world, @policy.hunting_prep_command_list, [], :managed_ready, wait_for_scripts: true)
        when :managed_ready then nil
        when :hunting
          # A buff loss never tears down an owned skin/loot hand transaction.
          return @loot.tick(world) if @buffs&.enabled? && @loot&.looting?

          if recover_mana?(world)
            result = Actions::Wrack.new(world, policy: @policy).call
            return result unless wants_control?(world)
          end
          begin_rest(world)
        when :final_loot then step_final_loot(world)
        when :wait_followers then step_wait_followers(world)
        when :leave then step_leave(world)
        when :fog then step_fog(world)
        when :custom_fog then step_custom_fog(world)
        when :disband then step_disband(world)
        when :waypoints then step_travel(world, @policy.return_waypoint_ids, :resting_room)
        when :resting_room then step_room(world, @policy.resting_room, :resting_prep)
        when :stuck then step_stuck(world)
        when :resting_prep then step_resting_prep(world)
        when :resting_prep_own then step_prep(world, @policy.resting_command_list, @policy.resting_script_list, :rested, wait_for_scripts: true)
        when :rested then step_rested(world)
        when :resting then step_resting(world)
        when :hunting_prep then step_hunting_prep(world)
        when :hunting_prep_own then step_prep(world, @policy.hunting_prep_command_list, [], :rally_out, wait_for_scripts: true)
        when :rally_out then step_rally_out(world)
        when :rally then step_travel(world, @policy.rally_room_ids, :hunting_scripts)
        when :hunting_scripts then step_hunting_scripts(world)
        when :hunting_scripts_own then step_prep(world, [], @policy.hunting_script_list, :hunting_room)
        when :hunting_room then prepare_departure(world) || step_room(world, @policy.hunting_room, :arrived)
        when :arrived then step_arrived(world)
        when :hold then step_hold(world)
        when :done then finish(world)
        end
      end

      private

      def rest_reasons(world, overweight)
        reasons = EO::Engine::Rest::Predicates.rest_reasons(world.me, @town_policy, @counters, encumbered: overweight)
        reasons.unshift('town service required.') if @sites.town_required?
        reasons.unshift(@forced_reason) if @forced_reason
        buff_reason = @buffs&.rest_reason(world)
        reasons << buff_reason if buff_reason
        reasons
      end

      def select_site(site)
        @rest_site = site
        @policy = @sites.policy(@town_policy, site)
      end

      # Field escalation waits for owned loot/travel and arrival scripts to
      # release their hands. Survival/Cleanse/Flee keep their higher priorities.
      def escalate_field(world)
        return false unless @sites.enabled? && @rest_site == :field
        return false if @phase == :hunting
        return false if @loot&.looting? || @trip || @policy.resting_script_list.any? { |entry| @scripts.running?(script_name(entry)) }
        return false if @prep_script && @scripts.running?(@prep_script)

        overweight = @encumbrance.ready?(world.me.encumbrance_pct, threshold: @town_policy.encumbered_pct)
        reasons = rest_reasons(world, overweight)
        reason = reasons.find { |entry| @sites.select([entry]) == :town }
        reason ||= 'field recovery timed out.' if !DEPARTURE_PHASES.include?(@phase) && @field_started && @sites.timeout.positive? && @clock.now - @field_started >= @sites.timeout
        return false unless reason

        request_return!(reason)
        Events.emit(:rest_destination, site: :town, room: @policy.resting_room, reason: reason)
        true
      end

      def service_failed(reason)
        @phase = :service_failed
        Events.emit(:rest_service_failed, site: @rest_site, reason: reason)
        Actions::Result.new(status: :failed, reason: :rest_service_failed, line: reason)
      end

      # A rest reason can appear after the character leaves the refuge but
      # before the hunting lifecycle finishes. Cancel that outbound trip and
      # enter the existing return path instead of delivering an injured,
      # drained, or otherwise unready character to the hunting area.
      def abort_outbound_if_needed(world)
        # Not every rest reason should turn an outbound trip around. A lost
        # combat buff is the buff policy's own business: it prepares at the
        # rally and hunting-room phases (prepare_buffs above) rather than
        # abandoning a trip already under way, and its spec pins that. The
        # abort is for the reasons that make arriving pointless - wounds,
        # no mana, no supplies.
        reason = travel_blocking_rest_reason(world)
        return false if reason.nil?

        followers = grouped? ? @group.rest_reasons : {}
        request_return!(reason)
        @counters.reset!
        @rested_emitted = false
        @any_wounded = reason.to_s.match?(/wounded/) || (grouped? && @group.any_wounded?)
        Events.emit(:rest_started, reason: reason, followers: followers)
        true
      end

      # The reason this tick, if any. Absorbs what wants_control? used to do
      # inline: with recovery sites enabled the reason comes from the site
      # list, and an opt-in buff policy can supply one when nothing else
      # does. Both are inert when their feature is off.
      def current_rest_reason(world)
        overweight = @encumbrance.ready?(world.me.encumbrance_pct, threshold: @policy.encumbered_pct,
                                                                   looting: @loot&.looting?)
        own = if @sites.enabled?
                rest_reasons(world, overweight).first
              else
                EO::Engine::Rest::Predicates.rest_reason(world.me, @policy, @counters, forced: @forced_reason,
                                                         looting: @loot&.looting?, encumbered: overweight)
              end
        reason = grouped? ? group_reason(world, own) : own
        reason || @buffs&.rest_reason(world)
      end

      # current_rest_reason without the buff policy's contribution; see
      # abort_outbound_if_needed for why the two differ.
      def travel_blocking_rest_reason(world)
        overweight = @encumbrance.ready?(world.me.encumbrance_pct, threshold: @policy.encumbered_pct,
                                                                   looting: @loot&.looting?)
        own = if @sites.enabled?
                # rest_reasons appends the buff policy's own reason; drop it
                # here, since that is the one reason that must not abort a
                # trip already under way.
                buff_reason = @buffs&.rest_reason(world)
                (rest_reasons(world, overweight) - [buff_reason].compact).first
              else
                EO::Engine::Rest::Predicates.rest_reason(world.me, @policy, @counters, forced: @forced_reason,
                                                         looting: @loot&.looting?, encumbered: overweight)
              end
        grouped? ? group_reason(world, own) : own
      end

      def outbound?
        return true if OUTBOUND_PHASES.include?(@phase)
        return false unless @phase == :hold && @hold

        OUTBOUND_PHASES.include?(@hold[:next])
      end

      # The threshold check outranks Maintain and Engage. Try their existing
      # recovery action once before committing this rest, then read mana again.
      # Forced reasons (including an already-failed combat recovery) and a
      # follower's rest request must not be cleared by our own mana recovery.
      def recover_mana?(world)
        @policy.use_wracking && @forced_reason.nil? && @reason == 'out of mana.' &&
          EO::Engine::Rest::Predicates.oom?(world.me, @policy) && (!grouped? || @group.rest_reasons.empty?)
      end

      def grouped? = !@group.nil? && !@group.solo?

      # The followers' reasons join ours. A profile can return when any
      # member, every live member, or designated members reach their own
      # fried thresholds. Other rest reasons always apply group-wide.
      # A wounded rest waits while a member is stunned. Ours names the
      # rest, else the first follower's.
      def group_reason(world, own)
        reasons = @group.rest_reasons
        reasons[@group.name] = own if own
        return nil if reasons.empty?

        list = reasons.values
        fried_names = reasons.filter_map { |name, reason| name if reason.to_s =~ /fried/ }
        return nil if list.all? { |reason| reason.to_s =~ /fried/ } && !@group.fried_rest?(fried_names)
        return nil if list.any? { |r| r.to_s =~ /wounded/ } && EO::Engine::Survival::Predicates.group_member_stunned?(world)

        # If the experience barrier is not met, a safety/resource reason is
        # what made us return. Do not hide it behind a support leader's fried
        # flag (which may deliberately be satisfied from the start).
        unless @group.fried_rest?(fried_names)
          urgent = reasons.reject { |_name, reason| reason.to_s =~ /fried/ }
          return own if own && own.to_s !~ /fried/
          return urgent.map { |name, reason| "#{name}: #{reason}" }.join(', ')
        end

        own || reasons.map { |n, r| "#{n}: #{r}" }.join(', ')
      end

      def begin_rest(world)
        if @sites.enabled?
          overweight = @encumbrance.ready?(world.me.encumbrance_pct, threshold: @town_policy.encumbered_pct, looting: @loot&.looting?)
          reasons = rest_reasons(world, overweight)
          # Known recovery requests (e.g. Engage's out-of-mana event) can
          # recover in the field; unknown failures default to town.
          site = @sites.select(reasons)
          select_site(site)
          @reason = reasons.find { |entry| @sites.select([entry]) == :town } || reasons.first || @reason
          @field_started = nil
          Events.emit(:rest_destination, site: site, room: @policy.resting_room, reason: @reason)
        end
        @reason ||= EO::Engine::Rest::Predicates.rest_reason(world.me, @policy, @counters, forced: @forced_reason, looting: @loot&.looting?)
        Events.emit(:rest_started, reason: @reason, followers: grouped? ? @group.rest_reasons : {})
        @counters.reset!
        @forced_reason = nil
        @remaining = nil
        @rested_emitted = false
        @stranded = false
        @buff_serviced = false
        @buff_gate_started = nil
        @stuck = nil
        @any_wounded = @reason.to_s =~ /wounded/ || (grouped? && @group.any_wounded?) ? true : false
        @phase = grouped? ? :wait_followers : :leave
        # should_rest? 9041: a final loot for these reasons, never wounded
        # (an ambusher here is Flee's, which outranks Rest; the claim is
        # Loot's own check)
        if @loot && @reason.to_s =~ FINAL_LOOT_REASONS && @reason.to_s !~ /wounded/
          @loot.final!
          @final_loot_ticks = 0
          @phase = :final_loot
        end
        nil
      end

      # Loot's ticks, from here, until it has nothing left in this room.
      def step_final_loot(world)
        @final_loot_ticks += 1
        if @final_loot_ticks <= FINAL_LOOT_TICKS && @loot.wants_control?(world)
          return @loot.tick(world)
        end

        Events.emit(:final_loot_done, ticks: @final_loot_ticks - 1)
        @phase = grouped? ? :wait_followers : :leave
        nil
      end

      # rest 7481-7484: the followers done looting and out of roundtime.
      def step_wait_followers(world)
        hold(world, :followers_looting, next_phase: :leave) { @group.looting_done? && !@group.roundtime? }
      end

      # bigshot rest 7469-7489 and prepare_for_movement 9276: autosneak off
      # when sneaking, stop the hunting scripts, drop to the wander stance;
      # the followers the same.
      def step_leave(world)
        stop_hunting(world)
        @phase = :fog
        if grouped?
          @group.order(:hunting_scripts_stop, room: world.room.id)
          @group.order(:prep_rest, room: world.room.id)
          if @group.policy.independent_return
            # 7493-7506: the followers' own way home, then disband
            %i[leave_group fog_return go2_waypoints go2_resting_room].each { |o| @group.order(o, room: world.room.id) }
            Actions::Disband.new(world).call
            @disband_ticks = 0
            @phase = :disband
          else
            # 7513-7514; the pulls are Survival's
            @group.order(:unhide, room: world.room.id)
            @group.order(:follow_now, room: world.room.id)
          end
        end
        Actions::Result.new(status: :success)
      end

      # The hunting teardown alone, no phase change: a follower runs it on
      # the leader's hunting_scripts_stop and stays where the leader's
      # next order puts it.
      def stop_hunting(world)
        Actions::Command.new(world, command: 'movement autosneak off').call if @policy.sneaky
        @policy.hunting_script_list.each { |s| @scripts.kill(script_name(s)) if @scripts.running?(script_name(s)) }
        @stance.call(@policy.wander_stance) if @policy.wander_stance
      end

      # 7503: until the game's group is empty.
      def step_disband(world)
        @disband_ticks += 1
        return nil if world.group_nouns.any? && @disband_ticks < DISBAND_TICKS

        @phase = :fog
        nil
      end

      # bigshot fog_return 6463: off when fog_return is 0; with fog_optional
      # only a wounded or encumbered rest fogs. Method 6 is the profile's
      # own command list, one line per tick (:custom_fog); 1-5 are the
      # Fog module's, one blocking call confirmed on the room changing.
      def step_fog(world)
        @phase = after_fog
        return nil if @policy.fog_return.to_i.zero?
        return nil if @policy.fog_optional && @reason.to_s !~ /wounded|encumbered/

        if @policy.fog_return.to_i == CUSTOM_FOG
          @fog_start = world.room.uid
          @remaining = nil
          @phase = :custom_fog
          return nil
        end

        fog_result(@fog.call(@policy, @reason))
      end

      # custom_fog: the profile's commands, as the prep lists are sent.
      def step_custom_fog(world)
        result = step_prep(world, Array(@policy.custom_fog), [], after_fog, wait_for_scripts: true)
        return result unless @phase == after_fog

        fog_result(world.room.uid != @fog_start)
      end

      # What follows the fog; Orders redirects it.
      def after_fog = :waypoints

      def fog_result(moved)
        Events.emit(:fog_return, moved: moved)
        Actions::Result.new(status: moved ? :success : :failed, reason: moved ? nil : :fog_failed)
      end

      # One waypoint at a time, a tick at a time (Travel.step). With a
      # group walking together, everyone present after each,
      # unless someone is wounded.
      def step_travel(world, rooms, next_phase)
        @remaining ||= rooms.dup
        if @remaining.empty? && @trip.nil?
          @remaining = nil
          @phase = next_phase
          return nil
        end
        @current_room = @remaining.shift if @trip.nil?
        case EO::Engine::Travel.step(self, @travel, @current_room, world)
        when :underway then nil
        when :arrived
          hold(world, :waypoint, next_phase: @phase, follow: true) { @group.all_present?(world) } if gathering?
          Actions::Result.new(status: :success)
        else Actions::Result.new(status: :failed, reason: :unreachable)
        end
      end

      # The followers walk with us and we wait for them: not on an
      # independent trip, not for a wounded rest.
      def gathering?
        return false unless grouped?
        return false if @any_wounded

        independent = @phase == :waypoints ? @group.policy.independent_return : @group.policy.independent_travel
        !independent
      end

      # bigshot goto 6681: up to five go2 attempts; not arriving is a rest
      # reason ("Could not reach"). A Trip spends the five itself
      # (:could_not_reach); the count here is for a blocking travel.
      def step_room(world, room, next_phase)
        if room.nil?
          @phase = next_phase
          return nil
        end
        outcome = EO::Engine::Travel.step(self, @travel, room, world)
        return nil if outcome == :underway

        @attempts = @attempts.to_i + 1
        if outcome == :arrived
          @attempts = 0
          @phase = next_phase
          return Actions::Result.new(status: :success)
        end
        return Actions::Result.new(status: :failed, reason: :unreachable) if outcome == :failed && @attempts < GO2_ATTEMPTS

        @attempts = 0
        Events.emit(:rest_stuck, room: room)
        # a retry that fails again keeps its count
        @stuck = { room: room, back: @phase, retries: @stuck && @stuck[:room] == room ? @stuck[:retries] : nil }
        @phase = stuck_phase(next_phase)
        Actions::Result.new(status: :failed, reason: :could_not_reach)
      end

      # Where an unreachable room leaves us: on the way out, hunting from
      # here (done); on the way home, the stuck phase, which retries
      # before giving up. Orders redirects both to idle.
      def stuck_phase(next_phase) = %i[done arrived].include?(next_phase) ? :done : :stuck

      # The return could not reach its room (bigshot goto 7946 records
      # "Could not reach" and rests where it stands, which reported the
      # character rested at a room it never reached). Wait, then try the
      # room again, STUCK_RETRIES rounds of GO2_ATTEMPTS; only then rest
      # where we stand, as stranded: prepped and waiting to hunt, but
      # never announced as :rested, since the bounty child exits on that.
      #
      # @bigshot goto
      def step_stuck(world)
        @stuck[:until] ||= @clock.now + STUCK_RETRY_WAIT
        return nil if @clock.now < @stuck[:until]

        @stuck[:until] = nil
        @stuck[:retries] = @stuck[:retries].to_i + 1
        if @stuck[:retries] <= STUCK_RETRIES
          Events.emit(:rest_retry, room: @stuck[:room], attempt: @stuck[:retries], of: STUCK_RETRIES)
          @attempts = 0
          @phase = @stuck[:back]
          return nil
        end

        Events.emit(:rest_stranded, room: @stuck[:room], here: world.room&.id)
        if @sites.enabled? && @rest_site == :field
          request_return!('field refuge unreachable.')
          Events.emit(:rest_destination, site: :town, room: @policy.resting_room, reason: @reason)
          return nil
        end
        @stranded = true
        @stuck = nil
        @phase = :resting_prep
        nil
      end

      # rest 7540-7564: with quiet_followers the leader preps and runs its
      # scripts first, the followers after; else the followers are told
      # first. Wounded, nobody waits.
      def step_resting_prep(world)
        if (@sites.enabled? || @buffs&.enabled?) && (@stranded || world.room&.id != @policy.resting_room)
          return service_failed('rest destination was not reached; refusing location-specific scripts')
        end
        @field_started ||= @clock.now if @rest_site == :field
        @remaining = nil
        unless grouped?
          @phase = :resting_prep_own
          return nil
        end
        if @group.policy.quiet_followers && !@any_wounded
          @after_prep = %i[resting_prep resting_scripts_start]
          Actions::GroupOpen.new(world).call
          hold(world, :quiet_gather, next_phase: :resting_prep_own, follow: true) { @group.all_present?(world) }
        else
          @group.order(:resting_prep, room: world.room.id)
          @group.order(:resting_scripts_start, room: world.room.id)
          @phase = :resting_prep_own
          nil
        end
      end

      # rest 7566-7576: everyone back, out of roundtime and prepped.
      def step_rested(world)
        @buff_serviced = true
        unless grouped?
          @phase = :resting
          return nil
        end
        Array(@after_prep).each { |o| @group.order(o, room: world.room.id) }
        @after_prep = nil
        Actions::GroupOpen.new(world).call
        hold(world, :followers_resting_prep, next_phase: :resting, follow: true) do
          @group.all_present?(world) && !@group.roundtime? && @group.rest_prep_complete?
        end
      end

      # bigshot prep_and_rest_commands 5890 and run_scripts 5855: each
      # command through the ladder; "script name args" starts a script.
      # One line per tick.
      def step_prep(world, commands, scripts, next_phase, wait_for_scripts: false)
        if wait_for_scripts && @prep_script
          return nil if @scripts.running?(@prep_script)

          @prep_script = nil
        end

        @remaining ||= commands.dup + scripts.map { |s| "script #{s}" }
        if @remaining.empty?
          @remaining = nil
          @prep_script = nil
          @phase = next_phase
          return nil
        end
        line = @remaining.shift
        if @policy.preparations && !@policy.preparations.empty? && (name = Preparations.name(line))
          return Actions::Result.new(status: :skipped, reason: :preparation_aborted) if @preparation_failure

          result = Actions::Prepare.new(world, name: name, preparations: @policy.preparations).call
          if result.skipped?
            @remaining.unshift(line)
          elsif result.failed?
            preparation_failed!("preparation #{name}: #{result.reason}")
            service_failed(@preparation_failure) if world.room.id.to_s == @town_policy.resting_room.to_s
          end
          return result
        end
        if line =~ /^script\s+(\S+)\s*(.*)/i
          name = Regexp.last_match(1)
          started = start_script(name, Regexp.last_match(2))
          return service_failed("could not start #{name}") if @sites.enabled? && !started

          @prep_script = name if wait_for_scripts
          Actions::Result.new(status: :success)
        else
          Actions::Command.new(world, command: line).call
        end
      end

      # bigshot rest 7592 and should_hunt? 8949: hold until ready_to_hunt?
      # says ready and every follower does too (group_should_hunt? 1197),
      # checking every rest_interval.
      def step_resting(world)
        # at the resting room, prepped: where bigshot's bounty mode exits
        # for ebounty (rest 7578). Never for a stranded rest: we are not
        # at the resting room, and :rest_stranded already said so.
        unless @rested_emitted
          @rested_emitted = true
          Events.emit(:rested, reason: @reason) unless @stranded
        end
        now = @clock.now
        return nil if @next_rest_check_at && now < @next_rest_check_at

        running = @policy.resting_script_list.map { |s| script_name(s) }.select { |n| @scripts.running?(n) }
        why = EO::Engine::Rest::Predicates.not_hunting_reason(world.me, @policy, scripts_running: running)
        why = 'town service required.' if @sites.enabled? && @rest_site == :town && @sites.town_required?
        followers = grouped? ? @group.not_hunting_reasons : {}
        if why || followers.any?
          Events.emit(:resting, reason: why, followers: followers)
          @next_rest_check_at = now + @policy.interval
          return nil
        end
        @next_rest_check_at = nil
        @remaining = nil
        # The rest is over and every reason for it is satisfied. begin_rest
        # cleared the forced reason on the way in, but a rest! landing after
        # that point - :rest_stuck on the way home, :too_many_items or
        # :loot_stuck during the final loot, :cleanse_stuck while Cleanse
        # preempted the trip - survived to here, and abort_outbound_if_needed
        # then read it on the way out and turned the departure straight back
        # around into a second rest. The rest it asked for is this one.
        # Ahead of the town stop below, which returns without reaching it.
        @forced_reason = nil
        if @sites.enabled? && @rest_site == :town && @sites.stop_after_town?
          @phase = :town_complete
          Events.emit(:town_rest_complete)
          return nil
        end
        @phase = :hunting_prep
        Actions::Result.new(status: :success)
      end

      # pre_hunt 7245-7250: the followers' prep first, then ours.
      def step_hunting_prep(world)
        @group.order(:hunting_prep, room: world.room.id) if grouped?
        @remaining = nil
        @phase = :hunting_prep_own
        nil
      end

      # pre_hunt 7252-7278: together, gather before the rally rooms;
      # independent, disband and send the followers on their own.
      def step_rally_out(world)
        result = prepare_departure(world)
        return result if result

        @remaining = nil
        unless grouped?
          @phase = :rally
          return nil
        end
        if @group.policy.independent_travel
          Actions::Disband.new(world).call
          @group.order(:go2_rally, room: world.room.id)
          @disband_ticks = 0
          return hold(world, :disband, next_phase: :rally) { world.group_nouns.empty? || (@disband_ticks += 1) >= DISBAND_TICKS }
        end
        hold(world, :before_rally, next_phase: :rally, follow: true) { @group.all_present?(world) }
      end

      # Verify required effects after safe-location work, not merely that a
      # spell-up script exited. Initial departures also get one recovery pass.
      # Failure holds at refuge through the existing service-failed event.
      def prepare_buffs(world)
        return nil unless @buffs&.enabled?

        missing = @buffs.missing_required(world)
        if missing.empty?
          @buff_gate_started = nil
          return nil
        end
        unless @buff_serviced && world.room&.id == @policy.resting_room
          reason = @buffs.rest_reason(world) || BuffPolicy::FIELD_REASON
          site = reason == BuffPolicy::TOWN_REASON ? :town : :field
          request_return!(reason, site: site)
          return Actions::Result.new(status: :success, reason: :buff_recovery)
        end

        @buff_gate_started ||= @clock.now
        if @clock.now - @buff_gate_started >= @buffs.policy.recovery_seconds
          return service_failed("required buffs still missing after recovery: #{missing.join(', ')}")
        end
        @restore_buffs&.call(world) || Actions::Result.new(status: :success, reason: :buff_verification)
      end

      # Profile loadout opt-in extends pre_hunt's preparation (bigshot),
      # rather than taking hands away from a running travel child. On failure
      # the loadout event has requested rest or stopped us at refuge. Use
      # the existing return transition to discard any suspended outbound trip.
      def prepare_departure(world)
        result = @prepare_hands&.call(world)
        request_return!('hunting loadout could not be established') if result && !result.success?
        result
      end

      # pre_hunt 7281-7297: group open, everyone here, then the scripts.
      def step_hunting_scripts(world)
        @remaining = nil
        unless grouped?
          @phase = :hunting_scripts_own
          return nil
        end
        Actions::GroupOpen.new(world).call
        after = [:hunting_scripts_start]
        after << :go2_hunting_room if @group.policy.independent_travel
        hold(world, :before_scripts, next_phase: :hunting_scripts_own, follow: true, after: after) { @group.all_present?(world) }
      end

      # pre_hunt 7315-7341: at the hunting room, group open, everyone here,
      # signs, and the sneaky followers hidden.
      def step_arrived(world)
        unless grouped?
          @phase = :done
          return nil
        end
        Actions::GroupOpen.new(world).call
        @group.order(:cast_signs, room: world.room.id)
        @group.order(:check_sneaky, room: world.room.id) if @group.need_sneaky?
        hold(world, :at_hunting_room, next_phase: :done, follow: true) do
          @group.all_present?(world) && !@group.need_sneaky? && !@group.roundtime?
        end
      end

      # A wait for the followers: follow_now on entering (bigshot's
      # add_event before each wait), the test each tick, follow_now and
      # an unhide again every REORDER seconds while it fails, and
      # +after+ orders once it passes.
      def hold(world, why, next_phase:, follow: false, after: [], &test)
        @hold = { why: why, next: next_phase, follow: follow, after: after, test: test, ordered_at: @clock.now }
        @group.order(:follow_now, room: world.room.id) if follow
        @phase = :hold
        step_hold(world)
      end

      def step_hold(world)
        if @hold[:test].call
          Events.emit(:followers_ready, reason: @hold[:why])
          @hold[:after].each { |o| @group.order(o, room: world.room.id) }
          @phase = @hold[:next]
          @hold = nil
          return Actions::Result.new(status: :success)
        end
        return nil if @clock.now - @hold[:ordered_at] < REORDER

        @hold[:ordered_at] = @clock.now
        Events.emit(:waiting_for_followers, reason: @hold[:why], room: world.room.id)
        if @hold[:follow]
          Actions::Command.new(world, command: 'unhide').call if world.me.hidden?
          @group.order(:follow_now, room: world.room.id)
        end
        nil
      end

      # pre_hunt 7310-7313: autosneak on at the hunting room when sneaking.
      def finish(world = nil)
        Events.emit(:rest_finished)
        @phase = :hunting
        @reason = nil
        select_site(:town)
        return nil unless @policy.sneaky && world

        Actions::Command.new(world, command: 'movement autosneak on').call
      end

      def script_name(entry) = entry.to_s.split(/\s+/).first

      # bigshot run_script 5835: a running or paused copy is killed first.
      def start_script(name, args)
        if @scripts.running?(name)
          @scripts.kill(name)
          20.times { break unless @scripts.running?(name); sleep 0.1 }
        end
        @scripts.start(name, args.to_s.empty? ? nil : args)
      end

      # Lich's Script, behind the seam specs replace.
      module LichScripts
        # Start a script, with its args when there are any.
        # @param name [String]
        # @param args [String, nil]
        # @return [Object] whatever Script.start returns
        def self.start(name, args) = args ? ::Script.start(name, args) : ::Script.start(name)
        # @param name [String]
        # @return [Boolean] Script.running?
        def self.running?(name) = ::Script.running?(name)
        # @param name [String]
        # @return [Boolean] Script.paused?
        def self.paused?(name) = ::Script.paused?(name)
        # @param name [String]
        # @return [Object] whatever Script.kill returns
        def self.kill(name) = ::Script.kill(name)
      end
    end
  end
end
