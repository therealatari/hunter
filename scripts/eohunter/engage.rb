# frozen_string_literal: true

# ============================================================================
# engage (bigshot's attack loop: find_routine, command_check, cmd,
#         cmd_spell, the TARGET probe, wait_for_swing)
# ============================================================================

#
# bigshot's fight is do_hunt -> attack -> cmd per
# routine line, with attack_break between lines. The routine is
# the profile's command list for the creature's letter (find_routine
# 5980); each line may carry modifiers in parentheses (command_check
# 3539, check_state_condition 3589); cmd dispatches the verb
# and registers "once" lines. The engine's Engage is that as the
# behavior at priority 50: one routine line per tick, so Survival, Flee,
# Rest, Loot and Maintain all land between lines the way attack_break
# lets them. Rules and bigshot line references in hunting-engine-plan.md,
# "Engage".
#
module EO::Engine
  # The fight: routine lines, their modifiers, the spell and coup gates,
  # and what the fight learned. Behaviors::Engage runs it.
  module Engage
    # hunting_commands(_b..j) / quick_commands / disable_commands /
    # priority / hunting_stance / wander_stance / wand_if_oom / oom /
    # use_wracking / ambush / aim from the profile.
    Policy = Struct.new(:routines, :quick_commands, :disable_commands, :priority, :hunting_stance, :wander_stance,
                        :wand_if_oom, :use_wracking, :wracking_spirit, :oom, :ambush, :quick,
                        :archery_aim, :aim, :tier3, :uac_smite, :uac_mstrike, :ammo_container, :fresh_wand_container,
                        :dead_wand_container, :wand, :weapon_reaction, :preparations, keyword_init: true) do
      def initialize(routines: {}, quick_commands: [], disable_commands: [], priority: false, hunting_stance: 'defensive',
                     wander_stance: 'defensive', wand_if_oom: false, use_wracking: false, wracking_spirit: 0, oom: 0, ambush: [], quick: false,
                     archery_aim: [], aim: [], tier3: 'punch', uac_smite: false, uac_mstrike: false, ammo_container: nil,
                     fresh_wand_container: nil, dead_wand_container: nil, wand: [], weapon_reaction: true, preparations: nil) = super

      # find_routine: the letter's list, else the default (a).
      #
      # @bigshot find_routine
      # @param letter [String] the creature's routine letter, or 'quick'
      # @return [Array<String>] the routine's raw lines
      def routine_for(letter)
        return Array(quick_commands) if letter == 'quick' && Array(quick_commands).any?

        list = routines[letter.to_s]
        list.nil? || list.empty? ? Array(routines['a']) : list
      end
    end

    # What the fight learned: per-room once/room registry, the once-per
    # target spell lists, the unarmed tier, Swift Justice charges.
    class State
      # The unarmed combat tier, 1 to 3, from the :unarmed_tier event.
      #
      # @return [Integer]
      attr_accessor :unarmed_tier
      # Held in place: a kick becomes a punch while this is set (cmd 3995).
      # @return [Boolean]
      attr_accessor :rooted
      # Swift Justice charges, from the :swift_justice event.
      #
      # @return [Integer]
      attr_accessor :swift_justice
      # Arcane Reflex is up, from the :arcane_reflex event.
      #
      # @return [Boolean]
      attr_accessor :arcane_reflex
      # The room where a spell came back :blocked; Engage stays out of it.
      #
      # @return [Integer, String, nil]
      attr_accessor :combat_blocked_room
      # The room a fight is on in: set when a target is taken here, so the
      # claim is not re-asked mid-fight (bs_wander 9362, new_room false).
      #
      # @bigshot bs_wander
      # @return [Integer, String, nil]
      attr_accessor :fight_room
      # npc id => { command => Time }: every line run on every creature here.
      #
      # @return [Hash{String => Hash{String => Time}}]
      attr_reader :registry
      # Ids of the creatures 703 has been cast on this fight.
      #
      # @return [Array<String>]
      attr_reader :cast_703
      # Ids of the creatures 1614 has been cast on this fight.
      #
      # @return [Array<String>]
      attr_reader :cast_1614
      # Creature names the game refused to TARGET, learned this session.
      #
      # @return [Array<String>]
      attr_reader :untargetable_learned

      def initialize
        @registry = {} # npc id => { command => Time }
        @cast_703 = []
        @cast_1614 = []
        @untargetable_learned = []
        @unarmed_tier = 1
        @rooted = false
        @swift_justice = 0
        @arcane_reflex = false
        @ally_attack_generation = Hash.new(0)
        @ally_cast_generation = {}
        @ally_cast_mutex = Mutex.new
        routines_reset!
      end

      # A new room: forget the registry and the once-per-target lists, and
      # the blocked room unless this is still it.
      #
      # @param room_id [Integer, String, nil] the room entered
      # @return [void]
      def new_room!(room_id = nil)
        @registry.clear
        @cast_703.clear
        @cast_1614.clear
        @combat_blocked_room = nil unless room_id && @combat_blocked_room.to_s == room_id.to_s
        @fight_room = nil
        @rooted = false
        routines_reset!
      end

      # "You bolt" (hunt_monitor 2801): every per-fight latch
      #
      # @bigshot hunt_monitor
      # @return [void]
      def bolted!
        @cast_703.clear
        @cast_1614.clear
        @unarmed_tier = 1
        @rooted = false
        routines_reset!
      end

      # Note a line as run on a creature, at a time.
      #
      # @param npc_id [#to_s] the creature's id
      # @param command [String] the line's raw text
      # @param at [Time] when it ran
      # @return [Time] the time recorded
      def register(npc_id, command, at = Time.now)
        (@registry[npc_id.to_s] ||= {})[command] = at
      end

      # The line has run on this creature.
      #
      # @param npc_id [#to_s] the creature's id
      # @param command [String] the line's raw text
      # @return [Boolean]
      def done_once?(npc_id, command) = @registry[npc_id.to_s]&.key?(command) || false

      # The line has run on any creature in this room.
      #
      # @param command [String] the line's raw text
      # @return [Boolean]
      def done_in_room?(command) = @registry.values.any? { |cmds| cmds.key?(command) }

      # The most recent time this line ran against anything in the room,
      # which is what a repeat delay is measured from. The per-creature
      # registries are searched rather than one room-wide stamp, so a line
      # that has only ever run on a single creature still blocks the next.
      #
      # @bigshot repeatdelay_blocked?
      # @param command [String] the line's raw text
      # @return [Time, nil] the latest run of the line on any creature here
      def last_run(command) = @registry.values.filter_map { |cmds| cmds[command] }.max

      # An afterattack allycast may run once initially, then once after each
      # observed attack by that named ally. Each routine line keeps its own
      # latch, so several support spells can all re-arm on the same attack.
      #
      # @param command [String] the line's raw text
      # @param name [String] the ally's name, matched case-insensitively
      # @return [Boolean] true when the line has not run since the ally's
      #   last attack
      def ally_cast_ready?(command, name)
        ally = name.to_s.downcase
        @ally_cast_mutex.synchronize do
          key = [command.to_s, ally]
          !@ally_cast_generation.key?(key) || @ally_cast_generation[key] < @ally_attack_generation[ally]
        end
      end

      # Latch the line to the ally's current attack generation.
      #
      # @param command [String] the line's raw text
      # @param name [String] the ally's name
      # @return [void]
      def ally_cast_done!(command, name)
        ally = name.to_s.downcase
        @ally_cast_mutex.synchronize { @ally_cast_generation[[command.to_s, ally]] = @ally_attack_generation[ally] }
      end

      # An ally attacked (the :ally_attacked event): bump their generation
      # so every afterattack line re-arms.
      #
      # @param name [String] the ally's name; blank is ignored
      # @return [void]
      def ally_attacked!(name)
        ally = name.to_s.downcase
        return if ally.empty?

        @ally_cast_mutex.synchronize { @ally_attack_generation[ally] += 1 }
      end
    end

    # One routine line: the text bigshot sends, and its modifiers.
    Line = Struct.new(:raw, :text, :modifiers, keyword_init: true)

    # The routine compiler: profile entries to Lines.
    module Routine
      # Opt-in cursor retention, not a blocking loop. Conditions and the engine
      # priority scheduler still run between every action. Failed/skipped steps
      # advance normally so this cannot trap a routine on an unavailable action.
      REPEAT_UNTIL_TARGET_GONE = 'untildead'
      # bigshot COMMAND_MODIFIER_REGEX, reduced to "the trailing
      # parenthesis holds the modifiers"; each known word is checked in
      # Conditions, unknown words are reported and ignored.
      MODIFIERS = /\((.*?)\)$/

      module_function

      # An "a and b" entry (clean_value 2993) is an Array: its lines run
      # in order, the way bigshot's cmd runs an Array.
      #
      # @bigshot clean_value
      # @param entries [Array<String, Array<String>>, String, nil] the profile's
      #   routine entries
      # @return [Array<Line>] one Line per entry, text downcased, modifiers split
      #   on whitespace outside double quotes
      def parse(entries)
        Array(entries).flatten.map do |raw|
          raw = raw.to_s.strip
          match = raw.match(MODIFIERS)
          mods = match ? match[1].scan(/(?:[^\s"]|"[^"]*")+/) : []
          Line.new(raw: raw, text: (match ? raw.sub(MODIFIERS, '') : raw).strip.downcase, modifiers: mods)
        end
      end
    end

    # command_check: every modifier that says "skip this line now".
    #
    # @bigshot command_check
    module Conditions
      # A threshold word: e, essence, h, k, m, mob, s, tier, v or valid,
      # negated with "!", followed by the amount.
      AMOUNT = /^(!?(?:e|essence|h|k|m|mob|s|tier|v|valid))(\d+)$/i
      # buffN: skip unless the command's buff has under N seconds left.
      BUFF = /^buff(\d+)$/i
      # repeatdelayN: skip when the line ran under N seconds ago.
      REPEAT = /^repeatdelay(\d+)$/i
      # ES/EB/EC/ED"name": a spell, buff, cooldown or debuff by pattern,
      # negated with "!".
      EFFECTS = /^(!?E[SBCD])"(.+)"$/i
      # empoweredN: skip when an Empowered buff of +N or more is up.
      EMPOWERED = /^(!?)empowered(\d+)$/i
      # thpN: skip while the target's HP percent is above N.
      THP = /^(!?)thp(\d+)$/i

      # bigshot 5.16 (4452-4509): crtrStatus statuses and classification
      # flags, and the Combat::Tracker facts, read off the CreatureInstance.
      # Positional statuses are read natively too (npc_prone? 8444). Lich
      # registers a creature the moment the feed names it, so a target
      # with no instance answers no status; nothing parses the GameObj
      # status string.
      STATUS_WORDS = %w[calm disoriented hovering immobilized kneeling sitting sleeping stunned webbed].freeze
      # Modifier words that are CreatureInstance classification flags.
      FLAG_WORDS = %w[ascended ascension_boss challenging disengaged inferior mini_boss mount rider sympathetic].freeze
      # The statuses that count as prone (npc_prone? 8444).
      PRONE_STATUSES = %w[sleeping webbed stunned kneeling sitting prone immobilized].freeze

      # bigshot COMMAND_BUFF_CHECKS: the buff each command word
      # grants, for the buffN modifier.
      BUFF_OF = {
        'barrage'     => 'Enh. Dexterity (+10)', 'bearhug' => 'Enh. Strength (+10)', 'coupdegrace' => /Empowered \(\+\d+\)/,
        'flurry'      => 'Slashing Strikes', 'fury' => 'Enh. Constitution (+10)', 'garrote' => 'Enh. Agility (+10)',
        'kweed'       => 'Tangleweed Vigor', 'pummel' => 'Concussive Blows', 'shout' => 'Empowered (+20)',
        'thrash'      => 'Forceful Blows', 'weed' => 'Tangleweed Vigor', 'yowlp' => "Yertie's Yowlp"
      }.freeze

      # check_state_condition: a word is a "skip" when its lambda is
      # true. Effects by buff name; creature facts by status and type.
      BUFF_WORDS = {
        'barrage' => 'Enh. Dexterity (+10)', 'celerity' => 506, '506' => 506, 'coupdegrace' => /Empowered \(\+\d+\)/,
        'flurry' => 'Slashing Strikes', 'fury' => 'Enh. Constitution (+10)', 'garrote' => 'Enh. Agility (+10)',
        'holler' => 'Enh. Health (+20)', 'momentum' => 'Glorious Momentum', 'pummel' => 'Concussive Blows',
        'rapid' => 'Rapid Fire', 'rebuke' => 'Righteous Rebuke', 'scourge' => 'Ardor of the Scourge',
        'shout' => 'Empowered (+20)', 'tailwind' => 'Breeze Archery Tailwind', 'thrash' => 'Forceful Blows',
        'vigor' => 'Tangleweed Vigor', 'yowlp' => "Yertie's Yowlp", 'animate' => 'Animate Dead'
      }.freeze

      module_function

      # The first modifier on the line that says skip.
      #
      # @param line [Line]
      # @param world [World]
      # @param target [#id, #name, #type, nil] the current creature
      # @param state [State]
      # @param targets_policy [Targets::Policy] for the mob and valid counts
      # @param now [Time] the clock, for repeatdelay
      # @return [String, nil] the modifier that blocks the line, or nil
      def blocked_by(line, world, target, state, targets_policy, now: Time.now)
        line.modifiers.find { |mod| skip?(mod, line, world, target, state, targets_policy, now) }
      end

      # One modifier: the amount, buff, empowered, thp, repeatdelay and
      # effects forms by regex, else a word.
      #
      # @param mod [String] the modifier
      # @param line [Line]
      # @param world [World]
      # @param target [#id, #name, #type, nil]
      # @param state [State]
      # @param targets_policy [Targets::Policy]
      # @param now [Time]
      # @return [Boolean] true to skip the line
      def skip?(mod, line, world, target, state, targets_policy, now)
        me = world.me
        # bigshot returns only when the amount check SKIPS, then falls
        # through to the word check (cmd 4249-4257). Returning either way
        # made the exact-tier words unreachable: AMOUNT matches 'tier2'
        # (both here and in bigshot's own regex), so 'tier2' was read as
        # the tier<N threshold and the word branch at 484 never ran.
        if (m = mod.match(AMOUNT))
          return true if amount_skip?(m[1].downcase, m[2].to_i, world, state, targets_policy)
        end
        if (m = mod.match(BUFF))
          # 5.16 fix: the buff comes from the command word, and
          # only a buff that is UP with N seconds left vetoes; time_left is
          # 0 for an absent buff, which would deadlock a command whose buff
          # comes from the command (coup de grace -> Empowered).
          key = BUFF_OF.keys.find { |k| line.text =~ /^#{Regexp.escape(k)}\b/i }
          buff = key && BUFF_OF[key]
          return false unless buff && me.effect_active?(buff)

          return me.buff_time_left(buff) <= (m[1].to_i / 60.0)
        end
        if (m = mod.match(EMPOWERED))
          # 5.16 (4336): skip when an Empowered buff of +N or more is up
          bonus = me.buff_bonus(/^Empowered \(\+(\d+)\)/)
          strong = !bonus.nil? && bonus >= m[2].to_i
          return m[1].empty? ? strong : !strong
        end
        if (m = mod.match(THP))
          # 5.16 (4353): target HP percent from the Creature registry
          pct = creature_of(world, target)&.hp_percent
          return true if pct.nil?

          return m[1].empty? ? pct > m[2].to_i : pct <= m[2].to_i
        end
        if (m = mod.match(REPEAT))
          last = state.last_run(line.raw)
          return !last.nil? && (now - last) < m[1].to_i
        end
        if (m = mod.match(EFFECTS))
          return effects_skip?(m[1].upcase, /#{m[2]}/i, me)
        end

        word_skip?(mod.downcase, line, world, target, state)
      end

      # A threshold word: skip while the value is under the amount (over
      # it when negated); k, mob, tier and valid have their own tests.
      #
      # @param key [String] the word, "!"-prefixed when negated
      # @param amount [Integer]
      # @param world [World]
      # @param state [State] for the unarmed tier
      # @param targets_policy [Targets::Policy] for mob and valid
      # @return [Boolean] true to skip the line
      def amount_skip?(key, amount, world, state, targets_policy)
        me = world.me
        neg = key.start_with?('!')
        base = key.delete_prefix('!')
        value = case base
                when 'e' then me.encumbrance_pct
                when 'essence' then me.shadow_essence
                when 'h' then me.health_pct
                when 'k' then return neg ? me.kneeling? : !me.kneeling?
                when 'm' then me.mana
                when 'mob' then return neg ? Targets.fightable_count(world.room.targets, targets_policy) > amount : Targets.fightable_count(world.room.targets, targets_policy) < amount
                when 's' then me.stamina
                when 'tier' then return neg ? state.unarmed_tier > amount : state.unarmed_tier < amount
                when 'v' then me.spirit
                when 'valid' then return neg ? Targets.candidates(world.room.targets, targets_policy).size > amount : Targets.candidates(world.room.targets, targets_policy).size < amount
                else return false
                end
        neg ? value >= amount : value < amount
      end

      # An effects word: skip when the effect is absent (present when
      # negated).
      #
      # @param kind [String] ES, EB, EC or ED, "!"-prefixed when negated
      # @param pattern [Regexp] the effect name
      # @param me [World::Me]
      # @return [Boolean] true to skip the line
      def effects_skip?(kind, pattern, me)
        active = case kind.delete_prefix('!')
                 when 'ES' then me.spell_effect_active?(pattern)
                 when 'EB' then me.effect_active?(pattern)
                 when 'EC' then me.cooldown_active?(pattern)
                 when 'ED' then me.debuff_active?(pattern)
                 end
        kind.start_with?('!') ? active : !active
      end

      # The target's CreatureInstance, when the world has a registry.
      #
      # @param world [World]
      # @param target [#id, nil]
      # @return [Lich::Gemstone::CreatureInstance, nil]
      def creature_of(world, target)
        return nil if target.nil? || !world.respond_to?(:creature)

        world.creature(target.id)
      end

      # The target's creature has the status; false with no creature.
      #
      # @param world [World]
      # @param target [#id, nil]
      # @param name [String] the status
      # @return [Boolean]
      def has_status?(world, target, name)
        c = creature_of(world, target)
        c ? (c.has_status?(name) ? true : false) : false
      end

      # The target's creature has the classification flag; false with no
      # creature.
      #
      # @param world [World]
      # @param target [#id, nil]
      # @param flag [Symbol] one of FLAG_WORDS
      # @return [Boolean]
      def crtr_flag?(world, target, flag)
        c = creature_of(world, target)
        c ? (c.crtr_flag?(flag) ? true : false) : false
      end

      # The target has any PRONE_STATUSES status; false with no creature.
      #
      # @param world [World]
      # @param target [#id, nil]
      # @return [Boolean]
      def prone?(world, target)
        c = creature_of(world, target)
        c ? PRONE_STATUSES.any? { |st| c.has_status?(st) } : false
      end

      # A bare word: a BUFF_WORDS buff, else one of the named tests on us,
      # the room, the target or the state. Unknown words never skip.
      #
      # @param word [String] the word, downcased, "!"-prefixed when negated
      # @param line [Line] for once and room
      # @param world [World]
      # @param target [#id, #name, #type, nil]
      # @param state [State]
      # @return [Boolean] true to skip the line
      def word_skip?(word, line, world, target, state)
        me = world.me
        neg = word.start_with?('!')
        base = word.delete_prefix('!')
        if (buff = BUFF_WORDS[base])
          # bigshot check_state_condition 4363-4408: every one of these
          # rows is `!active?`, and the return means SKIP - so the bare
          # word skips while the buff is DOWN and the line is the one
          # that puts it up. `shout (!shout)`, the natural "unless
          # already buffed" form a bigshot profile is written in, shouts
          # once and then stops. Inverted, it never shouted at all.
          active = buff.is_a?(Integer) ? me.spell_active?(buff) : me.effect_active?(buff)
          return neg ? active : !active
        end

        want = case base
               when 'burst' then neg ? me.cooldown_active?('Burst of Swiftness') : !me.buff_matching?(/Enh\. Dexterity/)
               when 'surge' then neg ? me.cooldown_active?('Surge of Strength') : !me.buff_matching?(/Enh\. Strength/)
               when 'bearhug' then (me.effect_active?('Enh. Strength (+10)') || me.effect_active?('Enh. Strength (+20)')) ^ !neg
               when 'voidweaver' then me.buff_matching?(/Voidweaver/) ^ neg
               when 'disease' then me.diseased? ^ !neg
               when 'poison' then me.poisoned? ^ !neg
               when 'hidden' then me.hidden? ^ !neg
               when 'outside' then world.room.outside? ^ !neg
               when 'ancient' then ((target.name.to_s =~ /^(?:grizzled|ancient) / && target.name != 'ancient ghoul master') ? true : false) ^ !neg
               when 'flying' then has_status?(world, target, 'flying') ^ !neg
               when 'frozen' then has_status?(world, target, 'immobilized') ^ neg
               when 'noncorporeal' then target.type.to_s.split(',').include?('noncorporeal') ^ !neg
               when 'undead' then target.type.to_s.split(',').include?('undead') ^ !neg
               when 'prone' then prone?(world, target) ^ neg
               when 'rooted' then has_status?(world, target, 'rooted') ^ neg
               when *STATUS_WORDS then has_status?(world, target, base) ^ !neg
               when *FLAG_WORDS then crtr_flag?(world, target, base.to_sym) ^ !neg
               when 'wounded' then (creature_of(world, target)&.low_hp?(25) ? true : false) ^ !neg
               when 'fatalcrit' then (creature_of(world, target)&.fatal_crit? ? true : false) ^ !neg
               when 'smote' then (creature_of(world, target)&.smote? ? true : false) ^ !neg
               when 'ucsdecent' then (creature_of(world, target)&.ucs_position == 1) ^ !neg
               when 'ucsgood' then (creature_of(world, target)&.ucs_position == 2) ^ !neg
               when 'ucsexcellent' then (creature_of(world, target)&.ucs_position == 3) ^ !neg
               when 'ucstierup' then creature_of(world, target)&.ucs_tierup.nil? ^ neg
               when 'tier1', 'tier2', 'tier3' then (state.unarmed_tier == base[-1].to_i) ^ !neg
               when 'once' then state.done_once?(target.id, line.raw)
               when 'room' then state.done_in_room?(line.raw)
               when 'splashy' then (world.room.respond_to?(:tags) && Array(world.room.tags).include?('meta:splashy')) ^ neg
               when 'pcs' then (Array(world.room.players).map(&:noun) - world.group_nouns).any? ^ !neg
               when 'justice' then neg ? state.swift_justice >= 1 : state.swift_justice.zero?
               when 'reflex' then state.arcane_reflex ^ !neg
               when 'censer', 'repeatdelay', 'buff', 'afterattack' then false
               else false
               end
        want ? true : false
      end
    end

    # bigshot 5.16's coup de grace gate (cmd_cmans 4990, npc_coup_ready?
    # 8371): re-test the skill's requirement at the moment of send and
    # hold the coup rather than spend 20 stamina on a refusal. The
    # requirement (at or below rank*10% HP incapacitated, rank*5%
    # otherwise, 200 HP cap) is Lich's CreatureInstance#coup_eligible?.
    # A target without creature or HP data passes through.
    #
    # @bigshot cmd_cmans
    # @bigshot npc_coup_ready?
    module Coup
      module_function

      # Our Coup de Grace rank from Lich's CMan; 0 when it cannot answer.
      #
      # @return [Integer]
      def rank
        ::Lich::Gemstone::CMan['coupdegrace'].to_i
      rescue StandardError
        0
      end

      # @param world [World]
      # @param target [#id, nil]
      # @param rank [Integer] our coup rank; 0 never holds
      # @return [Symbol, nil] :coup_not_ready, or nil to send
      def hold_reason(world, target, rank: self.rank)
        return nil unless rank.positive?

        c = world.respond_to?(:creature) ? world.creature(target&.id) : nil
        return nil if c.nil?

        return nil unless c.current_hp && c.max_hp && c.max_hp.positive?

        c.coup_eligible?(rank) ? nil : :coup_not_ready
      end
    end

    # cmd_spell's gates as a reason, or nil to cast.
    #
    # @bigshot cmd_spell
    module SpellGates
      # Short buffs held while their own cooldown runs.
      SHORT_BUFFS = [140, 211, 215, 219, 919, 1619, 1650].freeze
      # Self spells whose unaffordability is not "out of mana".
      SELF_OK_WHEN_OOM = [9605, 506, 902, 411].freeze

      module_function

      # The gates in bigshot's order; the first that refuses names itself.
      #
      # @param world [World]
      # @param num [Integer] the spell number
      # @param target [#id, #status, nil] the current creature
      # @param state [State] for the once-per-target lists
      # @param _policy [Policy] unused
      # @return [Symbol, nil] :unknown_spell, :penalty_597, :active,
      #   :cooldown, :hidden, :once_per_target, :target_gone, :unaffordable,
      #   or nil to cast
      def reason(world, num, target, state, _policy)
        me = world.me
        s = world.spell[num]
        return :unknown_spell if s.nil? || !s.known?
        return :penalty_597 if me.spell_active?(597) && s.mana_cost.to_i.positive? && s.mana_cost.to_i + 5 > me.mana
        return :active if num == 506 && s.active?
        return :cooldown if num == 9605 && me.cooldown_active?('Surge of Strength')
        return :cooldown if num == 9625 && me.cooldown_active?('Burst of Swiftness')
        return :cooldown if num == 335 && me.cooldown_active?(335)
        return :hidden if num == 608 && me.hidden?
        return :once_per_target if num == 703 && target && state.cast_703.include?(target.id.to_s)
        return :once_per_target if num == 1614 && target && state.cast_1614.include?(target.id.to_s)
        return :target_gone if ![902, 411].include?(num) && target && target.status.to_s =~ /dead|gone/
        return :cooldown if num == 720 && me.cooldown_active?('Implosion')
        return :cooldown if SHORT_BUFFS.include?(num) && me.cooldown_active?(s.name)
        return :unaffordable unless s.affordable?

        nil
      end

      # bigshot: unaffordable and not a self-buff that may wait means
      # "out of mana", the forced rest reason, unless oom is negative.
      #
      # @bigshot cmd_spell
      # @param num [Integer] the spell number
      # @param policy [Policy] its oom setting
      # @return [Boolean]
      def oom_rest?(num, policy) = !SELF_OK_WHEN_OOM.include?(num) && !policy.oom.to_i.negative?
    end
  end

  module Actions
    # TARGET #id: bigshot sets the game's target before a routine
    # and probes a creature it has not seen before (valid_target? 6928),
    # learning "untargetable" names it never tries again.
    #
    # @bigshot valid_target?
    class Target < Base
      # Every line that answers a TARGET.
      ANSWERS = /^You are now targeting|^You can't target|^You discern that you are the origin|^You are unable to discern the origin|^What were you referring to\?/
      # The answers that mean the creature cannot be targeted.
      REFUSED = /^You can't target|^You discern that you are the origin|^You are unable to discern the origin/

      # @param world [World]
      # @param target [#id] the creature
      # @param timeout [Numeric] seconds to wait for the game's answer
      # @param opts [Hash] passed through to Base
      def initialize(world, target:, timeout: 3, **opts)
        super(world, target: target, **opts)
        @target = target
        @timeout = timeout
      end

      # Only death refuses the probe.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # Send TARGET #id and name a refusal.
      #
      # @return [Actions::Result] success when targeting; failed with
      #   :untargetable or :referent_missing
      def perform
        result = send_and_match("target ##{@target.id}", ANSWERS, timeout: @timeout)
        return result unless result.success?
        return Result.new(status: :failed, reason: :untargetable, line: result.line) if result.line =~ REFUSED
        return Result.new(status: :failed, reason: :referent_missing, line: result.line) if result.line =~ /What were you/

        result
      end
    end

    # wait_for_swing: stand in the wander stance until the target
    # swings at us or a player (the Watch's :incoming_swing), the room
    # empties, the target goes prone, or the seconds run out.
    #
    # @bigshot wait_for_swing
    class WaitForSwing < Base
      # @param world [World]
      # @param target [#id] the creature to wait on
      # @param seconds [Numeric] the longest wait
      # @param stance [#call, nil] (name) -> Boolean, for the stance drop
      # @param wander_stance [String, nil] the stance to drop to; nil keeps it
      # @param opts [Hash] passed through to Base
      def initialize(world, target:, seconds:, stance: nil, wander_stance: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @seconds = seconds.to_f
        @stance = stance
        @wander_stance = wander_stance
      end

      # Only death refuses the wait.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # Drop stance unless the target is prone, then wait on the
      # :incoming_swing event for this target.
      #
      # @return [Actions::Result] success with :swung or :waited
      def perform
        @stance&.call(@wander_stance) if @wander_stance && !Engage::Conditions.prone?(@world, @target)
        swung = false
        off = Events.on(:incoming_swing) { |e| swung = true if e.data[:target_id].to_s == @target.id.to_s }
        deadline = clock_now + @seconds
        until swung || clock_now > deadline || interrupted? || me.dead?
          break if Engage::Conditions.prone?(@world, @target)
          break unless target_still_live?

          sleep 0.25
        end
        Result.new(status: :success, reason: swung ? :swung : :waited)
      ensure
        Events.off(off) if off && Events.respond_to?(:off)
      end
    end

    # AMBUSH / ATTACK at a body part from the profile's ambush list
    # (cmd_ambush 5479): a refused part moves to the next, roundtime
    # resets to the first.
    #
    # @bigshot cmd_ambush
    class Ambush < Base
      include CombatRt

      # The body parts tried when the profile lists none.
      DEFAULT_PARTS = ['head', 'right leg', 'left leg', 'chest'].freeze
      # Every line that answers an aimed attack: a roundtime, a refused
      # part, or a bad referent.
      ANSWERS = /round(?:time)?|You cannot aim that high!|does not have a head!|is already missing that!|does not have a .* leg!|does not have a .* arm!|^What were you referring to\?/i
      # The answers that refuse the part and move the cursor on.
      REFUSED = /You cannot aim that high!|does not have a head!|is already missing that!|does not have a (?:right|left) leg!|does not have a (?:right|left) arm!/i

      # @param world [World]
      # @param target [#id] the creature
      # @param parts [Array<String>] the body parts, in order; empty uses
      #   DEFAULT_PARTS
      # @param cursor [Integer] the part to start at, from the last call
      # @param timeout [Numeric] seconds to wait for the game's answer
      # @param opts [Hash] passed through to Base
      def initialize(world, target:, parts: [], cursor:, timeout: 2, **opts)
        super(world, target: target, **opts)
        @target = target
        @parts = parts.empty? ? DEFAULT_PARTS : parts
        @cursor = cursor
        @timeout = timeout
      end

      # The part to try next time: 0 after a swing, past the refused part
      # otherwise.
      #
      # @return [Integer]
      attr_reader :cursor

      # Dead or muckled refuses the attack.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      # AMBUSH when hidden, ATTACK otherwise, at the cursor's part; a
      # refused part moves on, and every part refused fails.
      #
      # @return [Actions::Result] success on a roundtime; failed with
      #   :no_part_left or :interrupted
      def perform
        tries = 0
        loop do
          @cursor = 0 if @cursor >= @parts.size
          verb = me.hidden? ? 'ambush' : 'attack'
          result = send_and_match("#{verb} ##{@target.id} #{@parts[@cursor]}", ANSWERS, timeout: @timeout)
          return result unless result.success?

          if result.line =~ REFUSED
            @cursor += 1
            tries += 1
            return Result.new(status: :failed, reason: :no_part_left, line: result.line) if tries > @parts.size
            return Result.new(status: :failed, reason: :interrupted) if interrupted?

            next
          end
          @cursor = 0
          return result
        end
      end
    end
  end

  module Behaviors
    # One routine line per tick.
    #
    # @bigshot attack
    class Engage < Behavior
      # The creature being fought, nil between fights.
      #
      # @return [#id, #name, nil]
      attr_reader :target
      # What the fight learned.
      #
      # @return [Engage::State]
      attr_reader :state
      # The next routine line to run.
      #
      # @return [Integer]
      attr_reader :cursor
      # The profile's engage settings.
      #
      # @return [Engage::Policy]
      attr_reader :policy
      # The profile's target settings.
      #
      # @return [Targets::Policy]
      attr_reader :targets_policy
      # The profile's mstrike settings.
      #
      # @return [Actions::Mstrike::Policy]
      attr_reader :mstrike_policy
      # (name) -> Boolean, the stance changer.
      #
      # @return [#call]
      attr_reader :stance

      # Lines sent as an Attack.
      VERBS = /^(?:attack|kill|jab|punch|kick|grapple|hurl)\b/
      # Lines that do not get the hunting stance first.
      STANCE_FREE = /^(?:\d+|wait|sleep|wand|berserk|script|hide|nudgeweapon)/i
      # Floor objects that mean a weed is already down (cmd_weed 4797).
      WEEDS = /\b(?:vine|bramble|widgeonweed|vathor club|swallowwort|smilax|creeper|briar|ivy|tumbleweed)\b/
      # A spell line: optional incant, the number, then the cast word and
      # element as the extra.
      # bigshot spell_is_selfcast? 5785: the spells cast on ourselves, not
      # at the creature. Only 506, 902 and 411 were handled here, so every
      # other one ("303", "1010", "1109") went out as `cast #12345` at the
      # kobold: the mana was spent, the creature took the buff, and ours
      # was never refreshed.
      #
      # @bigshot spell_is_selfcast?
      SELFCAST = [
        106, 109, 115, 117, 120, 130, 140,
        205, 206, 211, 213, 215, 218, 219, 220, 240,
        303, 307, 310, 313, 314, 319, 350,
        401, 402, 403, 404, 405, 406, 414, 418, 419, 425, 430,
        503, 506, 507, 508, 509, 511, 513, 515, 517, 520, 535, 540,
        601, 602, 604, 605, 606, 608, 612, 613, 617, 618, 620, 625, 630, 640, 650,
        707, 712,
        905, 911, 913, 916, 919,
        1003, 1006, 1007, 1009, 1010, 1011, 1012, 1014, 1017, 1018, 1019, 1020, 1025, 1035, 1040,
        1109, 1119, 1125, 1130, 1150,
        1202, 1204, 1208, 1213, 1214, 1215, 1216, 1220, 1235,
        1601, 1605, 1606, 1607, 1608, 1609, 1610, 1611, 1612, 1613, 1616, 1617, 1618, 1619, 1635
      ].freeze

      # A routine line naming a spell by number: an optional INCANT, the
      # number, and the trailing words that pick the form (open/closed,
      # cast/channel/evoke) or the element a bolt takes.
      SPELL = /^(incant)?\s?(\d+)\s?((?:open|closed)?\s?(?:cast|channel|evoke)?\s?(?:cast|channel|evoke)?\s?(?:open|closed)?\s?(?:acid|air|cold|earth|fire|lightning|steam|water)?)?.*$/i
      # "allycast NNN name": a support spell on a named group member.
      ALLY_CAST = /^allycast\s+(\d+)\s+(.+)$/i
      # Words that Routines (routines.rb) handles; fire has its aim there too
      UNSUPPORTED = /^(?:prepare|resonance|jewel|throw|wand|wandolier|unarmed|smite|caststop|unravel|barddispel|stomp|leech|rapid(?:fire)?|depress|phase|curse|efury|dhurl|briar|assume|wield|store|tether|sacrifice|nudgeweapons?|berserk|force|eachtarget|dislodge|fire|celerity|haste|506|slayer|240|tonis|1035)\b/i

      # @param policy [Engage::Policy]
      # @param targets_policy [Targets::Policy]
      # @param wander_policy [Wander::Policy] for the claim
      # @param mstrike_policy [Actions::Mstrike::Policy]
      # @param maintain_state [Maintain::State] for the stamina top-up
      # @param scripts [#start, #running?, #kill]
      # @param stance [#call] (name) -> Boolean
      # @param group [Group::Leader, nil] the followers to order to attack
      # @param fried [#call] -> Boolean, for disable_commands in a group
      # @param state [Engage::State] shared with Wander for the blocked room
      # @param area [Wander::Area, nil] the hunting area; a creature met
      #   outside it is passed by, so the walk home is not a fight
      # @param routine_selector [#call, nil] (creature, letter) -> letter, the
      #   script's override of the routine choice
      # @param clock [#now] the time source, injectable for specs
      def initialize(policy:, targets_policy:, wander_policy: EO::Engine::Wander::Policy.new, mstrike_policy: Actions::Mstrike::Policy.new,
                     state: EO::Engine::Engage::State.new, maintain_state: EO::Engine::Maintain::State.new, scripts: nil, stance: nil,
                     group: nil, fried: nil, routine_selector: nil, area: nil, clock: Time)
        super()
        @policy = policy
        @targets_policy = targets_policy
        @wander_policy = wander_policy
        @area = area
        @mstrike_policy = mstrike_policy
        @state = state
        @maintain_state = maintain_state
        @scripts = scripts || EO::Engine::Behaviors::Rest::LichScripts
        @stance = stance || ->(name) { ::Lich::Gemstone::Stance.change(name) }
        @group = group
        @fried = fried || -> { false }
        @routine_selector = routine_selector
        @attack_ordered_at = nil
        @called_at = nil
        @clock = clock
        @target = nil
        @routine = []
        @cursor = 0
        @ambush_cursor = 0
        @unsupported = []
        @on_fight = nil
        Events.on(:entered_room) { |event| @state.new_room!(event.data[:room]); @target = nil }
        # cmd 3995 reads a rooted latch that hunt_monitor sets and clears
        # (2842, 2844); Lich carries both as :rooted and :unrooted.
        Events.on(:rooted) { @state.rooted = true }
        Events.on(:unrooted) { @state.rooted = false }
        Events.on(:swift_justice) { |e| @state.swift_justice = e.data[:charges].to_i }
        Events.on(:unarmed_tier) { |e| @state.unarmed_tier = e.data[:tier].to_i }
        Events.on(:bolted) { @state.bolted! }
        Events.on(:weapon_reaction) { |e| @state.reaction = e.data[:reaction] }
        Events.on(:arcane_reflex) { |e| @state.arcane_reflex = e.data[:active] }
        Events.on(:haze_703) { |e| e.data[:on] ? (@state.cast_703 << e.data[:id].to_s) : @state.cast_703.delete(e.data[:id].to_s) }
        Events.on(:rebuke_1614) { |e| e.data[:on] ? (@state.cast_1614 << e.data[:id].to_s) : @state.cast_1614.delete(e.data[:id].to_s) }
        Events.on(:arrow_stuck) { |e| @state.archery_stuck << e.data[:where]; @state.dislodge_locations << e.data[:where]; @state.dislodge_target = e.data[:id] }
        Events.on(:aiming) { |e| @state.archery_location = e.data[:where] }
        Events.on(:bond_return) { @state.bond_returned = true }
        Events.on(:unarmed_followup) { |e| @state.unarmed_followup = true; @state.unarmed_followup_attack = e.data[:attack] }
        Events.on(:ally_attacked) { |e| @state.ally_attacked!(e.data[:name]) }
      end

      # eachtarget swaps the creature for one line (cmd_eachtarget 4220).
      #
      # @bigshot cmd_eachtarget
      # @param creature [#id, #name] the creature to run the line on
      # @return [Object] the creature
      def retarget(creature) = @target = creature

      # Below Survival, Flee, Loot and Rest; above Maintain and Wander.
      #
      # @return [Integer] 50
      def priority = 50

      # Called with a block when a fight begins in a room (Flee's
      # lone_targets_only rule).
      #
      # @yield each tick a fight is on, before the routine line
      # @return [Proc] the block
      def on_fight(&block) = @on_fight = block

      # Optional handoff before the selected target's next routine step.
      #
      # @return [#call, nil] (world, creature) -> Result or nil
      attr_writer :prepare_loadout

      # Installing the loadout failure sink enables bounded hurled-weapon
      # cleanup. Profiles without managed hands retain their attack path.
      #
      # @return [#call, nil] (world, result) -> void
      attr_writer :equipment_failed

      # Stop or urgent higher-priority work interrupts managed recovery.
      #
      # @return [#call, nil] (world) -> Boolean
      attr_writer :equipment_interrupt

      # The eligible creature chosen by this behavior, including Assist's
      # leader order. This only reads selection; it never starts a fight.
      #
      # @param world [World]
      # @return [Object, nil] the next selected target
      def loadout_target(world) = wants_control?(world) ? next_target(world) : nil

      # The room is ours (or a fight is already on here), combat is not
      # blocked here, and there is a creature to fight.
      #
      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        # Both sides .to_s, so an unmapped room (id nil) compared '' == ''
        # and every behaviour read the room as combat-blocked. Nothing is
        # blocked until something blocks it.
        return false if @state.combat_blocked_room && @state.combat_blocked_room.to_s == world.room.id.to_s
        return false unless in_bounds?(world)
        return false unless claimed_here?(world)

        !next_target(world).nil?
      end

      # Whether this fight currently owns temporary changes to the hands.
      # Loadout asks this before restoring the profile baseline, so a
      # multi-line wield/store routine is not undone between its lines. A
      # cached target from a completed fight owns nothing.
      #
      # @param world [World]
      # @return [Boolean]
      def owns_hands?(world)
        return false if @target.nil? || @routine.empty?

        candidate = loadout_target(world)
        !candidate.nil? && candidate.id.to_s == @target.id.to_s
      end

      # A creature met on the way to the hunting area is not our fight:
      # Wander is walking home, and stopping to kill it strands the walk
      # (it killed go2 to take the tick, then had to travel again). A
      # fight already under way in this room still finishes; so does a
      # profile with no area built, where every room is in bounds.
      #
      # @param world [World]
      # @return [Boolean]
      def in_bounds?(world)
        return true unless @area&.built?
        return true if @state.fight_room && @state.fight_room.to_s == world.room.id.to_s

        @area.include?(world.room.id)
      end

      # bigshot asks the claim on entering a room, not again once it is
      # fighting there (bs_wander 9362: new_room is false after a kill).
      # Another player walking in mid-fight does not hand the room over;
      # the next room is claimed afresh.
      #
      # @bigshot bs_wander
      # @param world [World]
      # @return [Boolean]
      def claimed_here?(world)
        return true if @state.fight_room && @state.fight_room.to_s == world.room.id.to_s

        EO::Engine::Wander::Predicates.claim_ours?(world, @wander_policy)
      end

      # One thing per tick: a pending boon assessment, the TARGET probe
      # for a new creature, a call to missing followers, or the next
      # routine line.
      #
      # @param world [World]
      # @return [Actions::Result] the line's result; failed with :no_target
      #   or :no_routine; the probe's failure; success with :called_back
      def tick(world)
        creature = next_target(world)
        handoff = @prepare_loadout&.call(world, creature)
        return handoff if handoff

        # bigshot check_boons: the ASSESS a boon creature needs before the
        # ignore and flee rules can judge it, sent now that we hold the
        # tick (never from a predicate, where a trip may still be walking)
        assessment = assess_boons(world)
        return assessment if assessment

        selected = next_target(world)
        if @prepare_loadout && selected&.id.to_s != creature&.id.to_s
          return Actions::Result.new(status: :skipped, reason: :loadout_target_changed)
        end
        creature = selected
        return Actions::Result.new(status: :failed, reason: :no_target) if creature.nil?

        if creature != @target
          switch_to(creature, world)
          probe = ensure_targeted(world)
          return probe if probe && !probe.success?
          # The successful TARGET used this tick's send. Keep a named
          # preparation pending so its consumptive command gets its own tick.
          return probe if probe && named_preparation?(@routine[@cursor]&.text)
        elsif @routine_disabled != disabled_routine?
          select_routine
        end
        @on_fight&.call
        called = call_followers(world)
        return called if called
        return Actions::Result.new(status: :failed, reason: :no_routine) if @routine.empty?

        line = @routine[@cursor]
        result = run_line(world, line)
        held_preparation = named_preparation?(line.text) && result&.skipped? && result.reason != :condition
        repeat_target = result&.success? && line.modifiers.any? { |mod| mod.casecmp?(EO::Engine::Engage::Routine::REPEAT_UNTIL_TARGET_GONE) }
        @cursor = (@cursor + 1) % @routine.size unless held_preparation || repeat_target
        result
      end

      private

      ATTACK_ORDER_EVERY = 10 # do_hunt 7383: a new target, or every ten seconds
      CALL_BACK_EVERY = 10
      # The longest a routine's `sleep N` may hold the tick. bigshot has no
      # literal cap but breaks every second on rest or a dead target, so a
      # runaway N never actually runs there (cmd_sleep 6548).
      MAX_ROUTINE_SLEEP = 60

      def grouped? = !@group.nil? && !@group.solo?

      # Followers participate in routine selection without gaining the
      # leader-only ability to issue attack or recall orders.
      def grouped_for_routines? = grouped?

      def disabled_routine?
        grouped_for_routines? && Array(@policy.disable_commands).any? && @fried.call
      end

      # One pending boon assessment in this room, as the tick's action.
      def assess_boons(world)
        cache = @targets_policy.boon_abilities
        return nil unless cache.respond_to?(:next_pending)

        creature = cache.next_pending(world.room.targets)
        creature && cache.assess!(creature)
      end

      # find_target with priority over the fightable, wanted
      # creatures the game has not refused.
      def next_target(world)
        Targets.choose(world.room.targets, @targets_policy, current: @target, priority: @policy.priority)
      end

      # find_routine: the creature's letter, quick_commands in
      # quick mode; disable_commands for a fried member of a group.
      def switch_to(creature, world)
        @target = creature
        @state.fight_room = world.room.id
        letter = @policy.quick ? 'quick' : Targets.routine_for(creature, @targets_policy)
        letter = @routine_selector.call(creature, letter) if @routine_selector
        @routine_letter = letter
        select_routine
        order_attack(world)
      end

      # Re-evaluate the configured fried routine without changing the target,
      # resending group orders, or resetting per-target modifier history.
      def select_routine
        @routine_disabled = disabled_routine?
        list = @routine_disabled ? @policy.disable_commands : @policy.routine_for(@routine_letter)
        @routine = EO::Engine::Engage::Routine.parse(list)
        @cursor = 0
        @ambush_cursor = 0
        Events.emit(:engaged, target: @target.id, name: @target.name, routine: @routine_disabled ? 'disabled' : @routine_letter)
      end

      def order_attack(world)
        return unless grouped?

        @attack_ordered_at = @clock.now
        @group.order(:attack, room: world.room.id)
      end

      # attack 7780-7792: the followers told to attack (again every ten
      # seconds), and a missing one called back: group open, unhide,
      # follow_now, without stopping the fight.
      def call_followers(world)
        return nil unless grouped?

        order_attack(world) if @attack_ordered_at.nil? || @clock.now - @attack_ordered_at >= ATTACK_ORDER_EVERY
        return nil if @group.all_present?(world)
        return nil if @called_at && @clock.now - @called_at < CALL_BACK_EVERY

        @called_at = @clock.now
        Events.emit(:waiting_for_followers, reason: :follower_missing, room: world.room.id)
        @group.order(:follow_now, room: world.room.id)
        Actions::GroupOpen.new(world).call
        Actions::Command.new(world, command: 'unhide').call if world.me.hidden?
        Actions::Result.new(status: :success, reason: :called_back)
      end

      # TARGET #id when the game is not already on it; a refusal teaches
      # the name (valid_target? 6928-6934) and drops the creature.
      def ensure_targeted(world)
        return nil if world.me.current_target_id.to_s == @target.id.to_s

        # bigshot's exact condition and its exact companion: when the game's
        # target is not the creature we are about to attack, every per-target
        # latch goes back to its starting value before the TARGET (attack
        # 7774-7777). Without this the unarmed tier, the armed follow-up, the
        # archery aim index and stuck list, the UAC aim, the dislodge state
        # and a pending weapon reaction all carried over from the creature
        # that just died onto the next one.
        @state.routines_reset!(moved: false)
        @state.unarmed_tier = 1

        result = Actions::Target.new(world, target: @target).call
        if result.failed? && result.reason == :untargetable
          # Another group member can kill the creature while TARGET is in
          # flight. The game then answers "You can't target ...", but that
          # is a transient dead-target race, not evidence that every creature
          # with this name is intrinsically untargetable. Match Bigshot's
          # post-probe dead/gone guard before persisting the species name.
          if @target.status.to_s =~ /dead|gone/
            @target = nil
            return Actions::Result.new(status: :skipped, reason: :target_gone, line: result.line)
          end

          @targets_policy.untargetable_set << @target.name unless @targets_policy.untargetable_set.include?(@target.name)
          @state.untargetable_learned << @target.name
          Events.emit(:untargetable_learned, name: @target.name)
          @target = nil
        end
        result
      end

      def run_line(world, line)
        blocked = EO::Engine::Engage::Conditions.blocked_by(line, world, @target, @state, @targets_policy, now: @clock.now)
        return Actions::Result.new(status: :skipped, reason: :condition, line: blocked) if blocked

        preparation = named_preparation?(line.text)
        text = preparation ? line.text : line.text.gsub(/\btarget\b/, "##{@target.id}")
        unless preparation
          soothe(world)
          reaction(world)
          @stance.call(@policy.hunting_stance) if @policy.hunting_stance && text !~ STANCE_FREE
        end
        if @routine_selector
          before = action_resources(world)
          Events.emit(:routine_action_started, target: @target.id.to_s, name: @target.name.to_s,
                                               routine: @routine_letter,
                                               command: line.raw.to_s, resources: before)
          result = dispatch(world, text, line)
          Events.emit(:routine_action_resolved, target: @target.id.to_s, name: @target.name.to_s,
                                                routine: @routine_letter,
                                                command: line.raw.to_s, status: result&.status,
                                                reason: result&.reason, line: result&.line.to_s,
                                                resources_before: before, resources_after: action_resources(world))
        else
          result = dispatch(world, text, line)
        end
        if result&.failed? && result.reason == :blocked
          @state.combat_blocked_room = world.room.id
          Events.emit(:combat_blocked, room: world.room.id, target: @target&.id)
        end
        unsent_preparation = named_preparation?(line.text) && result&.skipped?
        @state.register(@target.id, line.raw, @clock.now) if result && !(result.failed? && result.reason == :condition) && !unsent_preparation
        result
      end

      def named_preparation?(text)
        @policy.preparations && !@policy.preparations.empty? && !Preparations.name(text).nil?
      end

      def action_resources(world)
        %i[mana health spirit stamina].to_h do |name|
          value = world.me.respond_to?(name) ? world.me.public_send(name) : nil
          [name, value.nil? ? nil : value.to_i]
        end.freeze
      end

      public

      # bigshot sleeps in one-second slices and breaks on should_rest? or a
      # dead target (cmd_sleep 6548-6552). A bare Kernel#sleep held the tick
      # for the whole of N with no way out: a routine `sleep 20` kept the
      # engine in one line while the creature died, we were stunned, or a
      # stop was requested. N is also capped, since nothing else bounds it.
      #
      # @bigshot cmd_sleep
      # @param world [World]
      # @param seconds [Integer] the routine's N
      # @return [void]
      def routine_sleep(world, seconds)
        deadline = @clock.now + [seconds, MAX_ROUTINE_SLEEP].min
        while @clock.now < deadline
          sleep 0.25
          break if routine_sleep_over?(world)
        end
      end

      # The breaks: a stop or kill, our own death or muckle, and the target
      # dying or leaving - bigshot's dead_or_gone? check.
      def routine_sleep_over?(world)
        # The engine's stop seam, when one has been wired (Base.interrupt
        # is set at build time); nil outside that, which just means the
        # other breaks decide.
        return true if Actions::Base.respond_to?(:interrupt) && Actions::Base.interrupt&.call
        return true if world.me.dead? || world.me.muckled?
        return true if @target.nil? || @target.status.to_s =~ /dead|gone/

        world.room.targets.none? { |t| t.id.to_s == @target.id.to_s }
      end

      # cmd: the line's text to its action by verb: allycast,
      # a spell, mstrike, hide, weed, script, sleep, stance, wait, ambush,
      # a warcry or shield technique, a Routines word, an attack verb, a
      # maneuver word, else a bare Command.
      #
      # @bigshot cmd
      # @param world [World]
      # @param text [String] the line's text with "target" replaced by "#id"
      # @param line [Line] the line, for its modifiers and raw text
      # @return [Actions::Result, nil] the action's result
      def dispatch(world, text, line)
        # cmd 3995: held in place, a kick is a punch. bigshot swaps it on
        # the command text just before the verb switch.
        text = kick_to_punch(text)
        case text
        when ALLY_CAST then ally_spell(world, Regexp.last_match(1).to_i, Regexp.last_match(2), line)
        # Before SPELL: a prefix line ("506 attack", "240 cman bullrush")
        # also matches SPELL, which reads the number and drops everything
        # after it - the buff went up and the command never ran, and every
        # later pass failed the line with :active. Routines::PREFIX casts
        # the buff and then runs the command, which is bigshot's cmd
        # 3359-3387.
        when EO::Engine::Engage::Routines::PREFIX then EO::Engine::Engage::Routines.run(self, world, text, line)
        when SPELL then spell(world, Regexp.last_match(1), Regexp.last_match(2).to_i, Regexp.last_match(3).to_s.strip)
        when /^mstrike\b\s*(.*)$/ then mstrike(world, Regexp.last_match(1))
        when /^hide\s?(\d+)?/ then Actions::Hide.new(world, attempts: Regexp.last_match(1).to_i.zero? ? 3 : Regexp.last_match(1).to_i).call
        when /^(k?)weed\b/ then weed(world, Regexp.last_match(1) == 'k')
        when /^script\s+(.*?)(?:\s|$)(.*)/ then run_script(Regexp.last_match(1), Regexp.last_match(2))
        when /^sleep\s+(\d+)( nostance)?/
          @stance.call(@policy.wander_stance) unless Regexp.last_match(2)
          routine_sleep(world, Regexp.last_match(1).to_i)
          Actions::Result.new(status: :success, reason: :slept)
        when /^stance\s+(.*)/ then Actions::Result.new(status: @stance.call(Regexp.last_match(1)) ? :success : :failed, reason: :stance)
        when /^wait\s+(\d+)/
          Actions::WaitForSwing.new(world, target: @target, seconds: Regexp.last_match(1).to_i, stance: @stance, wander_stance: @policy.wander_stance).call
        when /^ambush\s?(.*)?/
          parts = Regexp.last_match(1).to_s.empty? ? Array(@policy.ambush) : [Regexp.last_match(1)]
          action = Actions::Ambush.new(world, target: @target, parts: parts, cursor: @ambush_cursor)
          result = action.call
          @ambush_cursor = action.cursor
          result
        when /^shield (?:bash|charge|pin|push|strike|throw|trample)\b|^(?:shout|yowlp|holler|bellow|growl|cry)\b/
          maneuver(world, text)
        when /^hurl\b/
          with_hurl_equipment(world) do |weapon_ids, interrupt|
            room = world.room.id
            result = Actions::Attack.new(world, target: @target, command: text, interrupt: interrupt).call
            if result.success? && weapon_ids
              recovery = Actions::RecoverHurl.new(world, state: @state, room: room,
                                                   expected_ids: weapon_ids, interrupt: interrupt).call
              # Preserve Attack's send stamp when automatic return needs no
              # recovery command; the thrown attack still counts as a fire.
              result.status = recovery.status
              result.reason = recovery.reason
              result.line = recovery.line
              result.event = recovery.event
            end
            result
          end
        when UNSUPPORTED then EO::Engine::Engage::Routines.run(self, world, text, line) || unsupported(line)
        when VERBS then Actions::Attack.new(world, target: @target, command: text).call
        else
          # a routine may name the category ("cman bullrush"); bigshot's
          # words are the bare technique
          words = text.split
          words.shift if %w[cman weapon feat shield warcry].include?(words.first) && words.size > 1 && text !~ /^shield /
          if Actions::Maneuver::WORDS.key?(words.first)
            maneuver(world, words.join(' '))
          else
            Actions::Command.new(world, command: text).call
          end
        end
      end

      # Keep the throw and its cleanup inside one action's ownership, so
      # Loot cannot occupy the returning weapon's hand after a killing hit.
      # A failed or uncertain return enters the existing loadout recovery.
      # Both hand IDs are recorded; recovery identifies the departed item.
      #
      # @param world [World]
      # @yieldparam weapon_ids [Array<String>, nil] exact hands before the throw
      # @yieldparam interrupt [#call, nil] recovery interruption callback
      # @yieldreturn [Actions::Result] throw and recovery outcome
      # @return [Actions::Result]
      def with_hurl_equipment(world)
        return yield(nil, nil) unless @equipment_failed

        originals = [world.hands.right&.id, world.hands.left&.id].compact.map(&:to_s)
        if originals.empty?
          result = Actions::Result.new(status: :failed, reason: :weapon_missing,
                                       line: 'managed hurl requires a held weapon')
          @equipment_failed.call(world, result)
          return result
        end

        @state.bond_returned = false
        interrupt = -> { @equipment_interrupt&.call(world) }
        result = yield(originals, interrupt)
        held = [world.hands.right&.id, world.hands.left&.id].compact.map(&:to_s)
        # Not only failed?: since #55 a gate that refuses before sending
        # answers :skipped, and three of the reasons below are exactly that
        # (a precondition refusing an interrupt, a changed room, an
        # ambiguous hand). The equipment is still displaced either way, so
        # the recovery has to hear about it.
        stranding = %i[equipment_return_timeout interrupted not_recovered
                       not_in_throw_room throw_hand_ambiguous].include?(result&.reason)
        if result && !result.success? && (result.status == :timeout || (originals - held).any? || stranding)
          @equipment_failed.call(world, result)
        end
        result
      end

      # A technique line: resolve the word, hold a coup that is not ready,
      # pick the target ('all', none for the self buffs and the untargeted
      # warcries, else the creature) and run the Maneuver.
      #
      # @param world [World]
      # @param text [String] the line's text, the word first
      # @return [Actions::Result] the Maneuver's result; failed with
      #   :coup_not_ready or :unsupported
      def maneuver(world, text)
        word = text =~ /^shield \w+/ ? text[/^shield \w+/] : text.split.first
        all = text.split.include?('all')
        pair = Actions::Maneuver.resolve(word)
        return unsupported(Line.new(raw: text, text: text, modifiers: [])) if pair.nil?

        category, name = pair
        if name == 'Coup de Grace'
          # The hold is the routine declining its own line (the target is
          # not hurt enough yet, Empowered is not up), not a refusal from
          # the game: nothing is sent, so it must not feed the
          # repeated-failures watchdog. bigshot just re-enters the routine.
          held = EO::Engine::Engage::Coup.hold_reason(world, @target)
          return Actions::Result.new(status: :skipped, reason: held) if held
        end
        target = if all then 'all'
                 elsif %w[burst surge].include?(word) then nil
                 elsif category == :warcry && %w[shout yowlp holler].include?(word) then nil
                 else @target
                 end
        Actions::Maneuver.new(world, category: category, name: name, target: target, skip_if_buff: %w[burst surge].include?(word)).call
      end

      # cmd_spell: the gates, then wand or wrack when unaffordable,
      # else the out-of-mana rest reason; then Cast.
      #
      # @bigshot cmd_spell
      # @param world [World]
      # @param incant [String, nil] "incant" when the line said so
      # @param num [Integer] the spell number
      # @param extra [String] the cast word and element, empty for none
      # @return [Actions::Result] the Cast's, Wand's or Wrack's result;
      #   failed with the gate's reason or :out_of_mana
      def spell(world, incant, num, extra)
        reason = EO::Engine::Engage::SpellGates.reason(world, num, @target, @state, @policy)
        if reason == :unaffordable
          # 5882: cmd_wand in the spell's place, its result the line's
          return Actions::Wand.new(world, target: @target, policy: @policy, state: @state, stance: @stance).call if @policy.wand_if_oom

          Actions::Wrack.new(world, policy: @policy).call if @policy.use_wracking
          unless world.spell[num].affordable?
            Events.emit(:out_of_mana, spell: num) if EO::Engine::Engage::SpellGates.oom_rest?(num, @policy)
            return Actions::Result.new(status: :failed, reason: :out_of_mana)
          end
        elsif reason
          return Actions::Result.new(status: :failed, reason: reason)
        end

        # bigshot cmd_spell 5900-5906: 506 and 902 cast bare, every other
        # self spell at our own name, and only the rest at the creature.
        # 411 casts on the weapon, so it is bare here too.
        target = if [506, 902, 411].include?(num) then nil
                 elsif SELFCAST.include?(num) then world.me.name
                 else @target
                 end
        result = Actions::Cast.new(world, spell: num, target: target, extra: extra.empty? ? nil : extra, incant: !incant.nil?).call
        if result.success?
          @state.cast_703 << @target.id.to_s if num == 703
          @state.cast_1614 << @target.id.to_s if num == 1614
          @stance.call(@policy.hunting_stance) if incant && @policy.hunting_stance
        end
        result
      end

      # A support spell on a named member of our current in-game group.
      # Resolve the profile's case-insensitive name against both the group
      # and room rosters, then preserve the game's canonical spelling.
      #
      # @param world [World]
      # @param num [Integer] the spell number
      # @param requested_name [String] the ally's name from the profile
      # @param line [Line] for the afterattack modifier and the latch key
      # @return [Actions::Result] the Cast's result; skipped with
      #   :ally_missing or :awaiting_ally_attack
      def ally_spell(world, num, requested_name, line)
        group_name = Array(world.group_nouns).map(&:to_s).find { |name| name.casecmp?(requested_name.to_s) }
        player = Array(world.room.players).find do |candidate|
          [candidate.respond_to?(:noun) ? candidate.noun : nil,
           candidate.respond_to?(:name) ? candidate.name : nil].compact.any? { |name| name.to_s.casecmp?(requested_name.to_s) }
        end
        return Actions::Result.new(status: :skipped, reason: :ally_missing) unless group_name && player

        name = player.respond_to?(:noun) && !player.noun.to_s.empty? ? player.noun.to_s : group_name
        after_attack = line.modifiers.any? { |modifier| modifier.casecmp?('afterattack') }
        if after_attack && !@state.ally_cast_ready?(line.raw, name)
          return Actions::Result.new(status: :skipped, reason: :awaiting_ally_attack)
        end

        result = Actions::Cast.new(world, spell: num, target: name).call
        @state.ally_cast_done!(line.raw, name) if after_attack && result.success?
        result
      end

      # cmd_weed: Tangleweed at the target, evoked for kweed,
      # unless a vine or weed is already on the floor.
      #
      # @bigshot cmd_weed
      # @param world [World]
      # @param evoke [Boolean] true for kweed
      # @return [Actions::Result] the Cast's result, or failed with :weed_present
      def weed(world, evoke)
        return Actions::Result.new(status: :failed, reason: :weed_present) if Array(world.room.loot).any? { |o| o.name.to_s =~ WEEDS }

        Actions::Cast.new(world, spell: 610, target: @target, extra: evoke ? 'evoke' : nil).call
      end

      # An mstrike line: Maintain's stamina top-up spell first when the
      # policy's floor wants it, then the Mstrike.
      #
      # @param world [World]
      # @param attack [String] the UAC attack word, empty for none
      # @return [Actions::Result] the Mstrike's result
      def mstrike(world, attack)
        floor = @mstrike_policy.stamina_cooldown || @mstrike_policy.stamina_quickstrike
        top_up = EO::Engine::Maintain::Stamina.top_up_spell(world, floor: floor || world.me.max_stamina, state: @maintain_state, now: @clock.now)
        if top_up
          @maintain_state.adrenal_at = @clock.now if top_up == 1107
          Actions::Cast.new(world, spell: top_up).call
        end
        Actions::Mstrike.new(world, policy: @mstrike_policy, target: @target, attack: attack.to_s.empty? ? nil : attack, targets_policy: @targets_policy).call
      end

      # cmd 3318: a kick while held in place is a punch
      #
      # @bigshot cmd
      # @param text [String] the line's text
      # @return [String] the text, kick swapped for punch when rooted
      def kick_to_punch(text) = @state.rooted ? text.gsub(/\bkick\b/i, 'punch') : text

      # cmd 3348: the Minor Mental soothe when a rage or a song holds us
      #
      # @bigshot cmd
      # @param world [World]
      # @return [void]
      def soothe(world)
        s = world.spell[1201]
        return unless s&.known? && s.affordable?
        return unless [201, 216, 1015, 1016, 1108, 1120].any? { |n| world.me.spell_active?(n) }

        s.cast
      end

      # perform_reaction before the command when the game offered one
      #
      # @bigshot perform_reaction
      # @param world [World]
      # @return [void]
      def reaction(world)
        return unless @policy.weapon_reaction && @state.reaction

        Actions::Reaction.new(world, reaction: @state.reaction, stance: @stance, hunting_stance: @policy.hunting_stance).call
        @state.reaction = nil
      end

      private

      # cmd_run_script: run it and wait for it, a tick at a time
      # would be better; bigshot blocks and so does this until Travel.
      def run_script(name, args)
        if @scripts.running?(name)
          @scripts.kill(name)
          20.times { break unless @scripts.running?(name); sleep 0.1 }
        end
        @scripts.start(name, args.to_s.empty? ? nil : args)
        200.times { break unless @scripts.running?(name); sleep 0.25 }
        Actions::Result.new(status: :success, reason: :script_ran)
      end

      def unsupported(line)
        unless @unsupported.include?(line.text)
          @unsupported << line.text
          Events.emit(:routine_unsupported, command: line.text)
        end
        Actions::Result.new(status: :failed, reason: :unsupported, line: line.text)
      end
    end
  end
end

# wait_for_swing: a creature's line that ends on us. Player names
# are M3's; the room description is excluded the way bigshot excludes it.
