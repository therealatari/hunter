# frozen_string_literal: true

# ============================================================================
# profile (a bigshot profile YAML into the engine's policies)
# ============================================================================

#
# bigshot keeps one YAML per profile under data/<game>/<char>/
# bigshot_profiles and reads every key through load_settings and
# clean_value: "split" is a comma list, "split_xx" a comma list
# with (xN) and (xx) repeats and "a and b" arrays, "targets" a name(letter)
# list, to_i / to_f, and "u1234" room uids resolve to ids. The engine reads
# the same file with the same rules and hands each behavior its Policy,
# so a profile that runs under bigshot runs here unchanged. Rules in
# hunting-engine-plan.md, "Profile compatibility".
#
module EO::Engine
  # A bigshot profile YAML read with load_settings' rules, handed out as
  # one Policy per behavior. `self[key]` is the cleaned value.
  #
  # @bigshot load_settings
  # @bigshot clean_value
  class Profile
    # Lich's Stance::NAMES (lib/gemstone/stance.rb 25), the set its
    # normalize matches a three-letter prefix against.
    STANCES = %w[offensive advance forward neutral guarded defensive].freeze

    # load_settings' rule per key: [cleaner, default]
    #
    # @bigshot load_settings
    RULES = {
      'return_waypoint_ids' => [:rooms, []], 'resting_room_id' => [:room, nil], 'resting_commands' => [:split_xx, []],
      'resting_scripts' => [:split, []], 'fog_return' => [:to_i, 0], 'custom_fog' => [:split_xx, []],
      'fog_optional' => [:bool, false], 'fog_rift' => [:bool, false],
      'fried' => [:to_i, 100], 'overkill' => [:to_i, 0], 'lte_boost' => [:to_i, 0], 'oom' => [:to_i, 0],
      'encumbered' => [:to_i, 101], 'wounded_eval' => [:string, nil], 'creeping_dread' => [:to_i, 0],
      'encumbrance_grace_seconds' => [:seconds, 5.0],
      'field_rest_room_id' => [:room, nil], 'field_rest_for' => [:list, %w[fried mana]],
      'field_rest_commands' => [:split_xx, []], 'field_rest_scripts' => [:split, []],
      'field_return_waypoint_ids' => [:strict_rooms, []], 'field_rallypoint_room_ids' => [:strict_rooms, []],
      'field_hunting_prep_commands' => [:split_xx, []], 'field_rest_timeout_seconds' => [:seconds, 900.0],
      'town_rest_required_eval' => [:string, nil], 'after_town_rest' => [:string, 'resume'],
      'combat_buffs' => [:structured, {}],
      'preparations' => [:structured, {}],
      'crushing_dread' => [:to_i, 0], 'wot_poison' => [:bool, false], 'confusion' => [:bool, false], 'box_in_hand' => [:bool, false],
      'hunting_room_id' => [:room, nil], 'rallypoint_room_ids' => [:rooms, []], 'hunting_boundaries' => [:rooms, []],
      'rest_till_exp' => [:to_i, 0], 'rest_till_mana' => [:to_i, 0], 'rest_till_spirit' => [:to_i, 0], 'rest_till_percentstamina' => [:to_i, 0],
      'hunting_stance' => [:stance, 'defensive'], 'wander_stance' => [:stance, 'defensive'], 'stand_stance' => [:stance, 'defensive'],
      'hunting_right_hand' => [:string, 'keep'], 'hunting_left_hand' => [:string, 'keep'],
      'hunting_aim' => [:string, ''],
      'hunting_loadout_sets' => [:structured, {}], 'hunting_loadout_rules' => [:structured, []],
      'hunting_prep_commands' => [:split_xx, []], 'hunting_scripts' => [:split, []], 'signs' => [:split, []],
      'loot_script' => [:string, nil], 'wracking_spirit' => [:to_i, 0],
      'priority' => [:bool, false], 'delay_loot' => [:bool, false], 'use_wracking' => [:bool, false], 'loot_stance' => [:bool, false],
      'pull' => [:bool, true], 'deader' => [:bool, false], 'sneaky_sneaky' => [:bool, false], 'check_favor' => [:bool, false],
      'ambush' => [:split, []], 'archery_aim' => [:split, []], 'flee_count' => [:to_i, 100], 'invalid_targets' => [:split, []],
      'always_flee_from' => [:split, []], 'flee_message' => [:regex, nil], 'wander_wait' => [:to_f, 0.3],
      'flee_clouds' => [:bool, false], 'flee_vines' => [:bool, false], 'flee_webs' => [:bool, false], 'flee_voids' => [:bool, false],
      'bless' => [:bool, false], 'lone_targets_only' => [:bool, false], 'weapon_reaction' => [:bool, true],
      'hunting_commands' => [:split_xx, []], 'hunting_commands_b' => [:split_xx, []], 'hunting_commands_c' => [:split_xx, []],
      'hunting_commands_d' => [:split_xx, []], 'hunting_commands_e' => [:split_xx, []], 'hunting_commands_f' => [:split_xx, []],
      'hunting_commands_g' => [:split_xx, []], 'hunting_commands_h' => [:split_xx, []], 'hunting_commands_i' => [:split_xx, []],
      'hunting_commands_j' => [:split_xx, []], 'targets' => [:targets, {}], 'quickhunt_targets' => [:qtargets, {}],
      'quick_commands' => [:split_xx, []], 'disable_commands' => [:split_xx, []],
      'tier3' => [:string, 'punch'], 'aim' => [:split, []], 'uac_smite' => [:bool, false], 'uac_mstrike' => [:bool, false],
      'mstrike_stamina_cooldown' => [:to_i, nil], 'mstrike_stamina_quickstrike' => [:to_i, nil], 'mstrike_mob' => [:to_i, 2],
      'mstrike_cooldown' => [:bool, false], 'mstrike_quickstrike' => [:bool, false],
      'ammo_container' => [:string, nil], 'ammo' => [:string, nil], 'wand' => [:split, []], 'wand_if_oom' => [:bool, false],
      'fresh_wand_container' => [:string, nil], 'dead_wand_container' => [:string, nil],
      'final_loot' => [:bool, false], 'dead_man_switch' => [:bool, false], 'depart_switch' => [:bool, false],
      'ignore_disks' => [:bool, false], 'boons_ignore' => [:list, []], 'boons_flee' => [:list, []],
      'troubadours_rally' => [:bool, false],
      # MA Grouping
      'independent_travel' => [:bool, false], 'independent_return' => [:bool, false], 'group_deader' => [:bool, false],
      'ma_looter' => [:string, nil], 'never_loot' => [:split_xx, []], 'random_loot' => [:bool, false], 'quiet_followers' => [:bool, true],
      'group_fried_trigger' => [:split, ['any']], 'group_strict_movement' => [:bool, false],
      'group_members' => [:list, []]
    }.freeze

    # The profile's name (the YAML's basename) and every RULES key with
    # its cleaned value.
    #
    # @return [String, nil, Hash{String => Object}]
    attr_reader :name, :settings, :source

    # The profile YAML at +path+, named by its basename.
    #
    # @param path [String] the profile YAML
    # @param uid_ids [#call] (uid) -> [lich ids]; World#uid_ids
    # @return [Profile]
    def self.load(path, uid_ids: nil)
      require 'yaml'
      new(YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}, name: File.basename(path, '.yaml'), uid_ids: uid_ids)
    end

    # @param raw [Hash{String => Object}] the YAML as loaded
    # @param name [String, nil] the profile's name
    # @param uid_ids [#call, nil] (uid) -> [lich ids]; default answers
    #   none, so a "u1234" room resolves to nil
    def initialize(raw, name: nil, uid_ids: nil)
      @name = name
      @source = Marshal.load(Marshal.dump(raw))
      @uid_ids = uid_ids || ->(_uid) { [] }
      # RULES.freeze is shallow, so the [], {} and ['any'] defaults are one
      # object shared by every Profile in the process. A Policy that appends
      # to what it takes for its own list then edits the default itself, and
      # the next Profile - the bounty swap, a reload - inherits it. Hand out
      # a copy.
      @settings = RULES.to_h do |key, (cleaner, default)|
        own = default.is_a?(Array) || default.is_a?(Hash) ? default.dup : default
        value = cleaner == :structured ? raw.fetch(key, own) : raw[key]
        [key, clean(cleaner, value, own)]
      end
      if !raw['field_rest_room_id'].to_s.strip.empty? && self['field_rest_room_id'].nil?
        raise ArgumentError, 'field rest room could not be resolved through the map'
      end
      rest_sites
      buff_policy
      if buff_policy.enabled? && !(self['resting_room_id'].is_a?(Integer) && self['resting_room_id'].positive?)
        raise ArgumentError, 'combat_buffs requires a positive resting_room_id for safe recovery'
      end
      if self['field_rest_room_id'] && !(self['resting_room_id'].is_a?(Integer) && self['resting_room_id'].positive?)
        raise ArgumentError, 'Field/Town Rest requires a positive resting_room_id for town'
      end
      @loadout_selection = Loadout::Selection.new(default: loadout_policy, sets: self['hunting_loadout_sets'], rules: self['hunting_loadout_rules'])
      @preparations = Preparations.new(self['preparations'])
      validate_preparation_words!
      if !preparations.empty? && !(self['resting_room_id'].is_a?(Integer) && self['resting_room_id'].positive?)
        raise ArgumentError, 'preparations requires a positive resting_room_id for safe recovery'
      end
    end

    # The cleaned value for a RULES key; nil for a key not in RULES.
    #
    # @param key [String, Symbol]
    # @return [Object, nil]
    def [](key) = @settings[key.to_s]

    # Refuse unsupported coordination before group registration or game actions.
    # The two-site protocol is opt-in; legacy groups and LAB retain one refuge.
    # @param mode [String, nil] head/tail for coordinated groups
    # @param controlled [Boolean] LAB fixed-refuge controller is active
    # @param bounty [Boolean] ebounty owns a single town handoff
    # @return [true]
    def validate_rest_mode!(mode, controlled: false, bounty: false)
      if !preparations.empty? && (%w[head tail].include?(mode) || controlled || bounty)
        raise ArgumentError, 'preparations currently supports ordinary solo hunts only; group, LAB and bounty recovery contracts are unchanged'
      end
      if buff_policy.enabled? && (%w[head tail].include?(mode) || controlled || bounty)
        raise ArgumentError, 'combat_buffs currently supports ordinary solo hunts only; group, LAB and bounty recovery contracts are unchanged'
      end
      if self['field_rest_room_id'] && (%w[head tail].include?(mode) || controlled || bounty)
        raise ArgumentError, 'Field/Town Rest currently supports ordinary solo hunts only; groups, LAB and ebounty require a single refuge'
      end
      true
    end

    # --- the policies ------------------------------------------------------

    # @return [BuffPolicy::Policy] validated opt-in combat requirements
    def buff_policy = @buff_policy ||= BuffPolicy::Policy.new(self['combat_buffs'])

    # @return [Preparations] validated event-confirmed profile commands
    attr_reader :preparations

    # The Rest behavior's Policy from the rest, fog, resting-room and
    # prep keys. rest_interval is fixed at 30.
    #
    # @param wounded_binding [Binding, nil] where wounded_eval runs (the
    #   script's binding, so bleeding?, Char and Injured resolve)
    # @return [Rest::Policy]
    def rest_policy(wounded_binding: nil)
      evaluator = self['wounded_eval'] && wounded_binding ? -> { eval(self['wounded_eval'], wounded_binding) ? true : false } : nil
      Rest::Policy.new(
        fried: self['fried'], overkill: self['overkill'], lte_boost: self['lte_boost'], oom: self['oom'], encumbered: self['encumbered'],
        encumbrance_grace: self['encumbrance_grace_seconds'],
        sites: rest_sites(wounded_binding),
        use_wracking: self['use_wracking'], wracking_spirit: self['wracking_spirit'],
        creeping_dread: self['creeping_dread'], crushing_dread: self['crushing_dread'], wot_poison: self['wot_poison'],
        confusion: self['confusion'], wounded: evaluator,
        rest_till_exp: self['rest_till_exp'], rest_till_mana: self['rest_till_mana'], rest_till_spirit: self['rest_till_spirit'],
        rest_till_stamina: self['rest_till_percentstamina'],
        resting_room: self['resting_room_id'], return_waypoints: self['return_waypoint_ids'], hunting_room: self['hunting_room_id'],
        rally_rooms: self['rallypoint_room_ids'], fog_return: self['fog_return'], fog_optional: self['fog_optional'],
        fog_rift: self['fog_rift'], custom_fog: self['custom_fog'],
        resting_commands: self['resting_commands'], resting_scripts: self['resting_scripts'],
        hunting_prep_commands: self['hunting_prep_commands'], hunting_scripts: self['hunting_scripts'], preparations: preparations,
        wander_stance: self['wander_stance'], rest_interval: 30, sneaky: self['sneaky_sneaky']
      )
    end

    # The Targets Policy from targets, invalid_targets and boons_ignore.
    #
    # @param untargetable [Array<String>] names the game refused to
    #   TARGET, persisted by the caller
    # @return [Targets::Policy]
    def targets_policy(untargetable: [])
      Targets::Policy.new(wanted: self['targets'], invalid: self['invalid_targets'], untargetable: untargetable,
                          boons_ignore: self['boons_ignore'])
    end

    # The Flee Policy from flee_count, the hazard toggles, always_flee_from,
    # boons_flee, flee_message and hunting_boundaries.
    #
    # @return [Flee::Policy]
    def flee_policy
      Flee::Policy.new(flee_count: self['flee_count'], lone_targets_only: self['lone_targets_only'], always_flee_from: self['always_flee_from'],
                       clouds: self['flee_clouds'], vines: self['flee_vines'], webs: self['flee_webs'], voids: self['flee_voids'],
                       boons_flee: self['boons_flee'], message: self['flee_message'], boundaries: self['hunting_boundaries'])
    end

    # The Wander Policy from hunting_room_id, hunting_boundaries,
    # wander_wait, sneaky_sneaky, ignore_disks and wander_stance.
    #
    # @return [Wander::Policy]
    def wander_policy
      Wander::Policy.new(hunting_room: self['hunting_room_id'], boundaries: self['hunting_boundaries'], wander_wait: self['wander_wait'],
                         sneaky: self['sneaky_sneaky'], ignore_disks: self['ignore_disks'], wander_stance: self['wander_stance'])
    end

    # The Loot Policy from loot_script, delay_loot, loot_stance and
    # final_loot.
    #
    # box_in_hand is deliberately not passed. bigshot uses it to choose
    # between a watched loot - one that breaks on a pause, a kill or a
    # forced rest - and a plain wait for the script to finish. The engine
    # always watches, which is the safer of the two, so the key would
    # select between one behaviour and the same behaviour. It stays in
    # RULES so an existing profile still loads.
    #
    # @return [Loot::Policy]
    def loot_policy
      Loot::Policy.new(script: self['loot_script'], delay: self['delay_loot'], stance: self['loot_stance'], final: self['final_loot'])
    end

    # The optional hunting hand baseline. Missing and blank keys resolve to
    # keep/keep, so existing bigshot profiles remain unmanaged.
    #
    # @return [Loadout::Policy]
    def loadout_policy
      Loadout::Policy.new(right: self['hunting_right_hand'], left: self['hunting_left_hand'], aim: self['hunting_aim'])
    end

    # Named sets and ordered target rules, validated during profile loading.
    # The legacy hunting hands remain the default policy.
    #
    # @return [Loadout::Selection]
    def loadout_selection = @loadout_selection

    # The Maintain Policy from signs, bless, use_wracking,
    # wracking_spirit, check_favor and ammo.
    #
    # @return [Maintain::Policy]
    def maintain_policy
      Maintain::Policy.new(signs: self['signs'], bless: self['bless'], use_wracking: self['use_wracking'],
                           wracking_spirit: self['wracking_spirit'], check_favor: self['check_favor'], ammo: self['ammo'])
    end

    # The Survival Policy from stand_stance, pull, deader and
    # group_deader; on_death is :depart with depart_switch, else :quit
    # with dead_man_switch, else :stop.
    #
    # @return [Survival::Policy]
    def survival_policy
      on_death = if self['depart_switch'] then :depart
                 elsif self['dead_man_switch'] then :quit
                 else :stop
                 end
      Survival::Policy.new(stand_stance: self['stand_stance'], pull: self['pull'], deader: self['deader'],
                           group_deader: self['group_deader'], on_death: on_death)
    end

    # The Group Policy from the MA Grouping keys; never_loot is
    # flattened out of its split_xx arrays.
    #
    # @return [Group::Policy]
    # @bigshot MA Grouping
    def group_policy
      Group::Policy.new(independent_travel: self['independent_travel'], independent_return: self['independent_return'],
                        group_deader: self['group_deader'], looter: self['ma_looter'], quiet_followers: self['quiet_followers'],
                        never_loot: self['never_loot'].flatten, random_loot: self['random_loot'], fried_trigger: self['group_fried_trigger'])
    end

    # The Engage Policy: hunting_commands as routine 'a' and
    # hunting_commands_b..j as 'b'..'j', with the quick and disable
    # commands, the stances, the wand, ammo, aim and mstrike keys.
    #
    # @return [Engage::Policy]
    def engage_policy
      routines = { 'a' => self['hunting_commands'] }
      ('b'..'j').each { |l| routines[l] = self["hunting_commands_#{l}"] }
      Engage::Policy.new(routines: routines, quick_commands: self['quick_commands'], disable_commands: self['disable_commands'],
                         priority: self['priority'], hunting_stance: self['hunting_stance'], wander_stance: self['wander_stance'],
                         wand_if_oom: self['wand_if_oom'], use_wracking: self['use_wracking'], wracking_spirit: self['wracking_spirit'],
                         oom: self['oom'], ambush: self['ambush'],
                         archery_aim: self['archery_aim'], aim: self['aim'], tier3: self['tier3'], uac_smite: self['uac_smite'],
                         uac_mstrike: self['uac_mstrike'], ammo_container: self['ammo_container'],
                         fresh_wand_container: self['fresh_wand_container'], dead_wand_container: self['dead_wand_container'],
                         wand: self['wand'], weapon_reaction: self['weapon_reaction'], preparations: preparations)
    end

    # The Mstrike Policy from the mstrike_* keys.
    #
    # @return [Actions::Mstrike::Policy]
    def mstrike_policy
      Actions::Mstrike::Policy.new(cooldown: self['mstrike_cooldown'], quickstrike: self['mstrike_quickstrike'],
                                   stamina_cooldown: self['mstrike_stamina_cooldown'], stamina_quickstrike: self['mstrike_stamina_quickstrike'],
                                   mob: self['mstrike_mob'])
    end

    private

    # A prefixed line that would repeat or re-dispatch a preparation. The
    # prefix words come from Routines::PREFIX_WORDS so this guard cannot
    # drift from the words the dispatcher actually treats as prefixes;
    # force and eachtarget are matched at their own dispatch sites.
    PREPARE_PREFIX = /\A(?:force|eachtarget|#{Regexp.union(Engage::Routines::PREFIX_WORDS).source})\b.*\bprepare\s+[a-z]/i

    def validate_preparation_words!
      return if preparations.empty?

      @settings.each do |key, entries|
        next unless key.include?('commands') || key == 'custom_fog'

        routine = key.match?(/\Ahunting_commands(?:_[b-j])?\z/) || %w[quick_commands disable_commands].include?(key)
        if !routine && Array(entries).any? { |entry| entry.is_a?(Array) && entry.flatten.any? { |command| Preparations.name(command.to_s.strip) } }
          raise ArgumentError, "named preparations in #{key} cannot use 'and' arrays; use comma-separated prepare NAME entries"
        end
        Engage::Routine.parse(Array(entries).flatten).each do |line|
          if routine && line.text.match?(PREPARE_PREFIX)
            raise ArgumentError, "preparations cannot use routine prefixes in #{key}; use modifiers on prepare NAME"
          end
          name = Preparations.name(routine ? line.text : line.raw)
          raise ArgumentError, "unknown preparation #{name} in #{key}" if name && !preparations[name]
        end
      end
    end

    def rest_sites(context = nil)
      expression = self['town_rest_required_eval']
      town_required = expression && context ? -> { eval(expression, context) ? true : false } : nil
      Rest::Sites.new(room: self['field_rest_room_id'], reasons: self['field_rest_for'],
                      commands: self['field_rest_commands'], scripts: self['field_rest_scripts'],
                      waypoints: self['field_return_waypoint_ids'], rally: self['field_rallypoint_room_ids'],
                      prep: self['field_hunting_prep_commands'], timeout: self['field_rest_timeout_seconds'],
                      town_required: town_required, after_town: self['after_town_rest'])
    end

    # clean_value, plus the uid resolution bigshot does in
    # convert_from_uid. A missing or blank value is the default
    # for legacy types, booleans included: pull, weapon_reaction
    # and quiet_followers default to true. Structured Hunter settings bypass
    # normalization so explicit null/wrong types fail Selection validation;
    # missing structured keys receive their default in initialize.
    #
    # @bigshot clean_value
    # @bigshot convert_from_uid
    def clean(cleaner, value, default)
      return value if cleaner == :structured

      blank = value.nil? || (value.respond_to?(:empty?) && value.empty?) || value.to_s =~ /\A\s*\z/
      return default if blank

      case cleaner
      when :seconds
        seconds = Float(value)
        raise ArgumentError, 'seconds must be finite and nonnegative' unless seconds.finite? && seconds >= 0

        seconds
      when :to_i then value.to_i
      when :to_f then value.to_f
      when :bool then value == true || value.to_s =~ /\Atrue\z/i ? true : false
      when :string then value.to_s
      # bigshot's flee_message: the text is a case-insensitive pattern
      # against each game line. A malformed one used to kill the script at
      # load with a raw RegexpError from the parser; say which setting it
      # was and treat the line as unset.
      when :regex then regex(value, default)
      when :stance then stance(value, default)
      when :split then value.to_s.split(/,\s*/)
      when :list then value.is_a?(Array) ? value.map(&:to_s) : value.to_s.split(/,\s*/)
      when :room then room_id(value)
      when :rooms then value.to_s.split(/,\s*/).map { |v| room_id(v) }.compact
      when :strict_rooms
        value.to_s.split(/,\s*/).map do |entry|
          room_id(entry) || raise(ArgumentError, "field route room could not be resolved: #{entry}")
        end
      when :split_xx then split_xx(value.to_s)
      when :targets, :qtargets then targets(value.to_s, cleaner == :targets ? 'a' : 'quick')
      else value
      end
    end

    # Lich's Stance.normalize RAISES ArgumentError on a word it does not
    # recognise, a string under three characters, or a percentage that is
    # not a multiple of ten - and it is called from the stance lambdas on
    # every hunting, wander, stand and flee transition. A typo in a profile
    # used to surface as a dead engine mid-hunt, at the first stance change,
    # far from the setting that caused it. Reject it here instead: the
    # documented default stands, and the run continues.
    #
    # @return [String] a stance Lich can parse
    # @return [Regexp, nil] the pattern, or the default when it will not
    #   compile - the setting is named on the front end either way
    def regex(value, default)
      Regexp.new(value.to_s, Regexp::IGNORECASE)
    rescue RegexpError => e
      warn("eohunter: ignoring an unusable pattern #{value.inspect}: #{e.message}")
      default
    end

    def stance(value, default)
      name = value.to_s.strip.downcase
      return name if name =~ /\A\d+\z/ && name.to_i.between?(0, 100) && (name.to_i % 10).zero?
      return name if name.length >= 3 && STANCES.any? { |s| s.start_with?(name[0, 3]) }

      default
    end

    def room_id(value)
      v = value.to_s.strip
      return v.to_i if v =~ /\A\d+\z/
      return @uid_ids.call(v[1..].to_i).first if v =~ /\Au\d+\z/i

      v.empty? ? nil : v
    end

    def split_xx(value)
      value.split(/,\s*/).flat_map do |entry|
        rep = 1
        cmd = entry
        if entry =~ /(.*)\(x(\d+)\)$/i
          rep = Regexp.last_match(2).to_i
          cmd = Regexp.last_match(1)
        elsif entry =~ /(.*)\(xx\)/i
          rep = 5
          cmd = Regexp.last_match(1)
        end
        ands = cmd.split(/\sand\s/)
        cmd = ands.size == 1 ? ands[0] : ands
        Array.new(rep, cmd)
      end
    end

    def targets(value, default)
      value.split(/,/).each_with_object({}) do |entry, h|
        if entry =~ /(.*)\(([a-jA-J])\)/
          h[Regexp.last_match(1).downcase.strip] = Regexp.last_match(2).downcase.strip
        else
          h[entry.downcase.strip] = default
        end
      end
    end
  end
end
