# frozen_string_literal: true

module EO
  module HunterSetup
    # Presentation metadata and a read-only adapter to the installed engine's
    # policy constructors. No command, expression or script is executed here.
    class Schema
      # Canonical page identities and their native profile setting keys.
      PAGES = {
        'area'         => %w[hunting_room_id hunting_boundaries targets quickhunt_targets invalid_targets always_flee_from boons_ignore boons_flee rallypoint_room_ids],
        'rest'         => %w[return_waypoint_ids resting_room_id resting_commands resting_scripts fog_return custom_fog fog_optional fog_rift
                             field_rest_room_id field_rest_for field_rest_commands field_rest_scripts field_return_waypoint_ids field_rallypoint_room_ids
                             field_hunting_prep_commands field_rest_timeout_seconds town_rest_required_eval after_town_rest
                             rest_till_exp rest_till_mana rest_till_spirit rest_till_percentstamina hunting_prep_commands hunting_scripts],
        'monitoring'   => %w[fried overkill lte_boost oom encumbered encumbrance_grace_seconds wounded_eval creeping_dread crushing_dread wot_poison confusion],
        'hunting'      => %w[hunting_stance wander_stance loot_script priority delay_loot loot_stance sneaky_sneaky flee_count flee_message wander_wait
                             flee_clouds flee_vines flee_webs flee_voids lone_targets_only final_loot ignore_disks box_in_hand],
        'equipment'    => %w[hunting_right_hand hunting_left_hand hunting_aim hunting_loadout_sets hunting_loadout_rules ammo_container ammo wand
                             wand_if_oom fresh_wand_container dead_wand_container],
        'buffs'        => %w[combat_buffs signs bless use_wracking wracking_spirit check_favor],
        'preparations' => %w[preparations],
        'recovery'     => %w[stand_stance pull deader dead_man_switch depart_switch weapon_reaction troubadours_rally],
        'team'         => %w[group_members independent_travel independent_return group_deader ma_looter never_loot random_loot quiet_followers group_fried_trigger group_strict_movement],
        'combat'       => %w[ambush archery_aim quick_commands disable_commands tier3 aim uac_smite uac_mstrike
                             mstrike_stamina_cooldown mstrike_stamina_quickstrike mstrike_mob mstrike_cooldown mstrike_quickstrike]
      }.freeze

      # Technical expressions and obsolete compatibility controls stay tucked
      # away even when they have friendly labels and descriptions.
      ADVANCED_FIELDS = %w[flee_message box_in_hand town_rest_required_eval].freeze

      # Descriptions reflect Profile and the pure Rest/Flee/Group policies. A
      # missing description deliberately exposes a raw advanced control.
      COPY = {
        'loot_script'                 => ['Looting script', 'Script to handle loot, for example eloot. Leave blank to use Hunter\'s built-in LOOT commands.'],
        'priority'                    => ['Switch to higher-priority creatures', 'Allow a creature earlier in your target list to take priority over the current target. Disabled keeps the current target while it remains valid.'],
        'delay_loot'                  => ['Loot less often during combat', 'While creatures remain, space out looting attempts using the native delay. This does not mean waiting until every creature is dead.'],
        'loot_stance'                 => ['Use defensive stance when looting in combat', 'Switch to defensive stance before looting while fightable creatures remain.'],
        'final_loot'                  => ['Check for loot before leaving a room', 'Request a final loot pass before wandering onward. Normal room-claim and looting restrictions still apply.'],
        'flee_clouds'                 => ['Leave rooms with dangerous clouds', 'Leave when the native room reader recognizes a cloud hazard. This does not identify every possible environmental danger.'],
        'flee_vines'                  => ['Leave rooms with vine hazards', 'Leave when the native room reader recognizes a vine hazard.'],
        'flee_webs'                   => ['Leave rooms with web hazards', 'Leave when the native room reader recognizes a web hazard.'],
        'flee_voids'                  => ['Leave rooms with voids', 'Leave when the native room reader recognizes a void hazard.'],
        'ignore_disks'                => ['Hunt despite other players\' disks', 'Ignore foreign disks when deciding whether to hunt in a room. Other room-claim rules still apply; this does not authorize taking another player\'s creatures.'],
        'fog_return'                  => ['Return method', 'Choose the native return method before the walk to your rest room. Availability and fallback behavior are handled by Lich; choosing a method does not grant the ability.'],
        'fog_optional'                => ['Teleport only when wounded or encumbered', 'Use the selected return method only for injury or encumbrance; otherwise walk.'],
        'fog_rift'                    => ['Use the native Rift escape option', 'Pass the Rift escape flag to Lich fog handling. Review this for your destination; this is not a general extra teleport switch.'],
        'custom_fog'                  => ['Custom return commands', 'Ordered commands used by the Custom return method. These are not combat routines.'],
        'return_waypoint_ids'         => ['Waypoints on the way home', 'Comma-separated mapped rooms visited in order before the rest room.'],
        'rallypoint_room_ids'         => ['Waypoints on the way to hunt', 'Comma-separated mapped rooms visited in order before the hunt starting room.'],
        'boons_ignore'                => ['Boon abilities to avoid targeting', 'Native boon names to exclude from deliberate targeting. Avoiding a target does not prevent it attacking you.'],
        'boons_flee'                  => ['Boon abilities to flee from', 'Native boon names that cause Hunter to leave the room.'],
        'tier3'                       => ['Attack at excellent UAC positioning', 'Move used by automatic unarmed combat at excellent positioning. Native follow-up logic still applies.'],
        'aim'                         => ['Unarmed aiming order', 'Comma-separated body locations used by automatic unarmed combat. Leave blank for no configured aiming order.'],
        'uac_smite'                   => ['Use Voln SMITE during unarmed combat', 'Allow native unarmed handling to attempt SMITE where applicable.'],
        'uac_mstrike'                 => ['Disable automatic unarmed MSTRIKE', 'This legacy flag is inverted: Enabled suppresses automatic unarmed MSTRIKE. Disabled allows native MSTRIKE checks. Explicit mstrike commands are separate.'],
        'mstrike_mob'                 => ['Use unfocused MSTRIKE at this many creatures', 'Creature threshold for the native multi-target MSTRIKE policy.', 'creatures'],
        'mstrike_cooldown'            => ['Allow MSTRIKE during cooldown', 'Permit the higher-cost cooldown action when the native stamina checks pass.'],
        'mstrike_quickstrike'         => ['Use QUICKSTRIKE with MSTRIKE', 'Enable the native QUICKSTRIKE option for MSTRIKE.'],
        'mstrike_stamina_cooldown'    => ['Stamina for cooldown MSTRIKE', 'Minimum stamina for the cooldown policy. Blank retains the native maximum-stamina fallback.', 'stamina points'],
        'mstrike_stamina_quickstrike' => ['Stamina for QUICKSTRIKE', 'Minimum stamina for the native QUICKSTRIKE policy. Blank retains its native fallback.', 'stamina points'],
        'ammo'                        => ['Ammunition noun', 'Legacy ammunition noun passed to native upkeep. FIRE itself uses the game ranged system; this does not create an ammo retrieval loop.'],
        'wand'                        => ['Wand types to use', 'Comma-separated wand names accepted by native wand handling.'],
        'wand_if_oom'                 => ['Use a wand when a spell is unaffordable', 'Allow the native wand fallback. Rest thresholds still apply; this does not override a return decision.'],
        'fresh_wand_container'        => ['Fresh wand container', 'Container where native wand handling looks for usable wands.'],
        'dead_wand_container'         => ['Used-up wand container', 'Container for depleted wands.'],
        'dead_man_switch'             => ['Log out on death', 'Current Hunter behavior: send QUIT on death. This is not a low-health logout trigger. Depart, if enabled, takes precedence.'],
        'depart_switch'               => ['DEPART on death', 'Send DEPART once on death, giving up the body and resurrection opportunity. This does not promise automatic restart.'],
        'group_deader'                => ['Stop for a dead team member', 'Enable the native group death check.'],
        'quiet_followers'             => ['Wait for leader services before follower services', 'Followers defer their rest work until the leader reaches the native service barrier.'],
        'never_loot'                  => ['Members never assigned looting', 'Comma-separated character names excluded from group looting assignments.'],
        'field_rest_commands'         => ['Commands at field rest', 'Ordered commands at the nearby rest site. Separate from town rest commands.'],
        'field_rest_scripts'          => ['Services at field rest', 'Ordered script names with arguments, without the script prefix.'],
        'field_hunting_prep_commands' => ['Commands before leaving field rest', 'Ordered preparation commands before returning to the hunt from the field site.'],
        'group_members'               => ['Required multi-account followers', 'Comma-separated character names, excluding this leader. Used by ;eohunter <profile> group. Each follower must separately enable its MA receiver and approve the leader and local profile. Saving this list does not grant control or start anyone.'],
        'signs'                       => ['Original upkeep entries', 'Comma-separated spell IDs or supported Hunter upkeep entries. The society checkboxes edit this same list. Custom entries are preserved; this is not a list of commands to send directly.'],
        'use_wracking'                => ['Use society mana recovery', 'Allow Hunter\'s existing mana-recovery policy to use Sign of Wracking, Sigil of Power or Symbol of Mana when applicable. Native knowledge, resource and cooldown checks still apply. Selecting an upkeep buff does not enable this switch.'],
        'wracking_spirit'             => ['Keep this much spirit for wracking', 'Native spirit floor used by the mana-recovery policy, including pending spirit loss from dissipating signs. This is not a blanket spirit reserve for every upkeep ability.', 'spirit points'],
        'check_favor'                 => ['Check favor for supported Voln upkeep', 'Use Lich\'s favor affordability reader for the symbols covered by Hunter\'s existing favor check. This is not a universal favor budget or a promise to check every symbol.'],
        'bless'                       => ['Renew weapon blessings', 'Enable Hunter\'s existing weapon-blessing upkeep when it detects that a blessing wore off. This does not automatically bless every item you carry.'],
        'hunting_stance'              => ['Stance before attacking', 'Hunter sets this before most attack actions. Numeric spell lines, hide, wait and sleep have separate native handling; Lich spell delivery may also change stance. Explicit stance steps do not disable this policy.'],
        'wander_stance'               => ['Stance between fights and while waiting', 'Used while wandering and by native wait/pause actions. This is not a guarantee that every action immediately returns to this stance.'],
        'stand_stance'                => ['Stance when recovering to standing', 'Stance used by native survival handling when getting back to your feet.'],
        'archery_aim'                 => ['Ranged aiming order', 'Comma-separated body parts used by the Hunter fire action, for example right eye, head, chest. Native logic can skip refused or missing parts. Do not add a body part after fire in a routine.'],
        'ambush'                      => ['Ambush and aimed-hurl order', 'Comma-separated body parts for ambush or dhurl without a per-action aim. Ambush uses an open ATTACK if not hidden; add the hidden condition if you require hiding.'],
        'ammo_container'              => ['Ammunition stow container', 'Container used by the native ranged action to stow ammunition after a refused shot. This setting does not itself retrieve, summon, or reload ammunition.'],
        'sneaky_sneaky'               => ['Hide before moving through hunting rooms', 'Uses the native hidden-wandering policy. It is not a stalking or follow-target feature, and does not replace hidden conditions on combat actions.'],
        'hunting_room_id'             => ['Hunt starting room', 'Travel to this mapped room to begin hunting. A room UID such as u1234 is resolved using the installed map.', 'room ID or UID'],
        'hunting_boundaries'          => ['Rooms to keep outside the hunt', 'Comma-separated boundary rooms Hunter will not step into. These are excluded edge rooms, not a list of rooms to hunt.', 'room IDs or UIDs'],
        'targets'                     => ['Creatures to hunt', 'Comma-separated creature names or anchored case-insensitive patterns. Add (b) through (j) to choose another routine. Empty means all otherwise eligible creatures.'],
        'invalid_targets'             => ['Creatures not to target', 'Comma-separated creature names or nouns excluded from deliberate targeting; this does not prevent their attacks or area effects.'],
        'always_flee_from'            => ['Leave when these are present', 'Comma-separated creature or player names or nouns that cause Hunter to leave the room.'],
        'resting_room_id'             => ['Town or main rest room', 'The mapped room used for ordinary rest and town recovery. Required when using combat buffs, preparations or field rest.', 'room ID or UID'],
        'fried'                       => ['Return when my mind is full', 'Return when mind percentage is at or above this threshold and the configured extra kills and LTE boosts are exhausted. Above 100 disables the mind trigger.', 'mind %'],
        'overkill'                    => ['Extra kills after a full mind', 'Additional kills before resting after reaching the mind threshold, also subject to the LTE boost allowance.', 'kills'],
        'lte_boost'                   => ['LTE boosts before resting', 'Number of LTE boosts allowed per rest cycle before the full-mind rest condition is satisfied.', 'boosts per cycle'],
        'oom'                         => ['Return below this mana', 'Return when mana percentage is strictly below this threshold. A negative value disables this trigger; the default 0 does not trigger at zero mana.', 'mana %'],
        'encumbered'                  => ['Return at this encumbrance', 'Return when encumbrance percentage is at or above this threshold after loot settles and the grace period passes.', 'encumbrance %'],
        'encumbrance_grace_seconds'   => ['Wait for carried weight to settle', 'Seconds of sustained encumbrance before returning. This does not delay unrelated emergency responses.', 'seconds'],
        'rest_till_exp'               => ['Leave rest at this mind level', 'Mind percentage must be at or below this value before hunting resumes. Other recovery checks must also pass.', 'mind %'],
        'rest_till_mana'              => ['Leave rest with this mana', 'Mana percentage must be at or above this value before hunting resumes.', 'mana %'],
        'rest_till_spirit'            => ['Leave rest with this spirit', 'Actual spirit points must be at or above this value before hunting resumes.', 'spirit points'],
        'rest_till_percentstamina'    => ['Leave rest with this stamina', 'Stamina percentage must be at or above this value before hunting resumes.', 'stamina %'],
        'resting_commands'            => ['Commands at rest', 'Ordered comma-separated game commands sent at the rest room. Supports (xN), (xx) and legacy and groups. Command replies do not prove recovery.'],
        'resting_scripts'             => ['Services at rest', 'Comma-separated script names with arguments, such as eherbs or eloot sell. Hunter waits for resting scripts before resuming; each script keeps its own settings.'],
        'hunting_prep_commands'       => ['Commands before hunting', 'Ordered comma-separated game commands sent during hunting preparation. Supports (xN), (xx) and legacy and groups.'],
        'hunting_scripts'             => ['Scripts while hunting', 'Comma-separated scripts started for the hunting phase. Their internal settings remain owned by those scripts.'],
        'field_rest_room_id'          => ['Nearby field rest room', 'Optional second rest site for ordinary solo hunts. Other recovery needs still use the town rest room.', 'room ID or UID'],
        'field_rest_for'              => ['Needs handled at field rest', 'Defaults to fried and mana. Native reason names also include wounded, creeping_dread, crushing_dread, poison and confusion. If any simultaneous need requires town, Hunter goes to town.'],
        'field_rest_timeout_seconds'  => ['Field rest time limit', 'Seconds allowed at field rest before escalating recovery to town. Zero disables the timeout.', 'seconds'],
        'after_town_rest'             => ['After town recovery', 'Use resume to continue hunting or stop to finish after town recovery.'],
        'wounded_eval'                => ['Custom injury return condition', 'Advanced Ruby expression evaluated only by the running hunt. Setup preserves this text and never evaluates or verifies it.'],
        'town_rest_required_eval'     => ['Custom town recovery condition', 'Advanced Ruby expression evaluated only by the running hunt. Setup preserves this text and never evaluates or verifies it.'],
        'hunting_commands'            => ['Usual combat sequence', 'Ordered comma-separated routine a commands. Supports Hunter routine conditions, (xN), (xx) and legacy and groups. Custom commands are preserved.'],
        'disable_commands'            => ['What I do after my mind is full', 'Optional alternative combat commands used by a full learner in a coordinated group while other members continue.'],
        'quick_commands'              => ['Quick-hunt combat sequence', 'Ordered commands for quick-hunt targets, with the native routine language preserved.'],
        'hunting_right_hand'          => ['Right hand', 'Use keep to leave the hand unmanaged, empty to clear it, ready:weapon or another supported ready slot, or an item name.'],
        'hunting_left_hand'           => ['Left hand', 'Use keep to leave the hand unmanaged, empty to clear it, a supported ready slot, or an item name.'],
        'hunting_aim'                 => ['Default aimed body part', 'Optional default body location for the hunting loadout. Empty leaves the aim unchanged.'],
        'hunting_loadout_sets'        => ['Named equipment sets', 'Advanced named right/left hand and aim settings validated by the installed loadout policy.'],
        'hunting_loadout_rules'       => ['Equipment rules for creatures', 'Ordered native rules selecting an equipment set for a target. The first matching rule selects the set.'],
        'combat_buffs'                => ['Required combat buffs', 'Native required-buff and recovery settings, validated by the installed buff policy. Currently supported only for ordinary solo hunts.'],
        'preparations'                => ['Confirmed item preparations', 'Named, event-confirmed preparation commands referenced by prepare NAME. Currently supported only for ordinary solo hunts.'],
        'flee_count'                  => ['Leave when too many targets gather', 'Leave when the number of fightable targets is strictly greater than this value.', 'creatures'],
        'lone_targets_only'           => ['Begin with only one target', 'On entering a room, use a crowd limit of one until a fight has begun.'],
        'flee_message'                => ['Leave on this game message', 'Case-insensitive regular expression matched against game lines. The engine ignores an invalid expression.'],
        'wander_wait'                 => ['Wait for a creature to appear', 'Seconds to stay in an unclaimed room before moving on. Hunter can engage as soon as a creature appears; a claimed room is left immediately.', 'seconds'],
        'group_fried_trigger'         => ['Whose full mind returns the team', 'Use any, all, or comma-separated member names. Names mean any listed member; all considers active reporting members plus the leader.'],
        'group_strict_movement'       => ['Wait for required members before moving', 'Enable the installed strict group movement coordination. This does not authorize control of independent party members.'],
        'independent_travel'          => ['Followers travel to the hunt themselves', 'Coordinated followers travel to the hunting room independently instead of relying on group travel.'],
        'independent_return'          => ['Followers return themselves', 'Coordinated followers travel back to rest independently.'],
        'ma_looter'                   => ['Team member who loots', 'Name of the coordinated looter, matched case-insensitively.'],
        'random_loot'                 => ['Let the least encumbered member loot', 'Assign group looting to the least encumbered member. Despite its legacy name, this is not a random choice.'],
        'box_in_hand'                 => ['Legacy box-in-hand compatibility', 'Preserved legacy setting. Hunter always watches loot completion, so this setting does not change its behavior.']
      }.freeze

      # Presentation choices for existing native values, not new execution policy.
      OPTIONS = {
        'fog_return'      => [
          [0, 'Walk'], [1, 'Spirit Guide (130)'], [2, 'Symbol of Return'],
          [3, "Traveler\'s Song (1020)"], [4, 'Sigil of Escape'],
          [5, 'Familiar Gate (930)'], [6, 'Custom return commands']
        ],
        'tier3'           => %w[jab punch grapple kick].map { |word| [word, word.capitalize] },
        'after_town_rest' => [['resume', 'Resume hunting'], ['stop', 'Finish after town recovery']]
      }.freeze

      # Browser control types for native cleaners; other cleaners use text.
      TYPES = { bool: 'boolean', to_i: 'integer', to_f: 'number', seconds: 'number', structured: 'structured' }.freeze
      # Pure native policy constructors checked without any game context.
      POLICIES = %i[rest_policy flee_policy wander_policy loot_policy loadout_policy loadout_selection maintain_policy
                    survival_policy group_policy engage_policy mstrike_policy buff_policy].freeze

      # Bind metadata and validation to the installed native policy classes.
      # @param profile_class [Class] the installed EO::Engine::Profile
      # @param cleanse_policy_class [Class, nil] the installed Cleanse::Policy
      def initialize(profile_class:, cleanse_policy_class: nil)
        @profile_class = profile_class
        @cleanse_policy_class = cleanse_policy_class
      end

      # Every native rule has exactly one canonical location. Unknown future
      # rules receive an explicitly raw editor instead of inferred behavior.
      # @return [Array<Hash{String => Object}>] JSON-ready field descriptions
      def fields
        @profile_class::RULES.reject { |key, _rule| key == 'recovery' }.map do |key, (cleaner, default)|
          copy = COPY[key]
          page = PAGES.find { |_name, keys| keys.include?(key) }&.first
          page = 'combat' if key.match?(/\Ahunting_commands(?:_[b-j])?\z/)
          aliases = [key]
          aliases += %w[fried full mind] if key == 'disable_commands'
          aliases += %w[tail head follower group multi-account] if page == 'team'
          {
            'key' => key, 'type' => TYPES.fetch(cleaner, 'string'), 'cleaner' => cleaner.to_s,
            'options' => field_options(key, cleaner),
            'default' => copy_value(default), 'label' => copy ? copy[0] : key.split('_').map(&:capitalize).join(' '),
            'help' => copy ? copy[1] : "Advanced native #{key} setting. Edit its raw value; the installed profile parser applies #{cleaner} normalization.",
            'page' => page || 'hunting', 'aliases' => aliases, 'editor' => copy && cleaner != :structured ? 'guided' : 'raw',
            'advanced' => ADVANCED_FIELDS.include?(key) || copy.nil? || cleaner == :structured,
            'units' => copy && copy[2], 'scope' => 'hunt or inherited character default'
          }
        end + [recovery_field]
      end

      # Find canonical controls by matching every search term in their metadata.
      # @param query [String] label, native key or familiar legacy term
      # @return [Array<Hash{String => Object}>] canonical matching fields
      def search(query)
        terms = query.to_s.downcase.split
        fields.select do |field|
          text = [field['key'], field['label'], field['help'], *field['aliases']].join(' ').downcase
          terms.all? { |term| text.include?(term) }
        end
      end

      # Describe supported contexts without promising unavailable recovery modes.
      # @return [Hash{String => Object}] baseline capability restrictions
      def capabilities
        {
          'field_rest' => 'ordinary solo hunts only', 'combat_buffs' => 'ordinary solo hunts only',
          'repeat_until_target_gone' => defined?(::EO::Engine::Engage::Routine::REPEAT_UNTIL_TARGET_GONE) ? true : false,
          'injury_checks' => %w[able_to_cast? able_to_use_ranged? able_to_sneak? get_injury_data].to_h do |method|
            [method, defined?(::Lich::Gemstone::Injured) && ::Lich::Gemstone::Injured.respond_to?(method) ? true : false]
          end,
          'preparations' => 'ordinary solo hunts only', 'configurable_dispel_recovery' => false,
          'dispel_recovery_note' => 'Immediate/post-combat rebuff strategies and bulk thresholds require a separate engine feature.',
          'group_note' => 'A physical party does not enroll other players in coordinated automation. Setup does not start their scripts.'
        }
      end

      # Use the installed dispatch vocabulary, not a separate technique list.
      # This does not query a character's skills or claim they are learned.
      # @return [Array<Hash{Symbol => String}>] native words and display names
      def routine_maneuvers
        return [] unless defined?(::EO::Engine::Actions::Maneuver::WORDS)

        ::EO::Engine::Actions::Maneuver::WORDS.map do |word, (category, name)|
          { word: word, category: category.to_s, name: name }
        end.sort_by { |entry| [entry[:category], entry[:name]] }
      end

      # Boons recognized by the installed target reader. Unknown imported names
      # remain editable separately; no wiki-only ability is advertised here.
      # @return [Array<Hash{Symbol => Object}>] native ability keys and adjectives
      def boon_abilities
        return [] unless defined?(::EO::Engine::Targets::BOON_ADJECTIVES)

        ::EO::Engine::Targets::BOON_ADJECTIVES.map do |key, adjectives|
          { key: key, label: key.split('_').map(&:capitalize).join(' '), adjectives: adjectives.dup }
        end
      end

      # Bare native buff checks with ordinary present/absent semantics.
      # @return [Array<String>] installed buff-condition words
      def routine_buff_conditions
        return [] unless defined?(::EO::Engine::Engage::Conditions::BUFF_WORDS)

        ::EO::Engine::Engage::Conditions::BUFF_WORDS.keys.dup
      end

      # Validate through native constructors, without runtime contexts or eval.
      # Missing geometry is distinct from malformed configuration so drafts
      # remain saveable. Ready means configuration-ready, not combat-safe.
      # @param raw [Hash{String => Object}] effective raw settings
      # @param uid_ids [#call, nil] read-only UID resolver
      # @param mode [String, nil] native head/tail mode, or solo
      # @param controlled [Boolean] LAB owns the hunt
      # @param bounty [Boolean] ebounty owns the hunt
      # @return [Hash{String => Object}] errors, missing data and warnings
      def validate(raw, uid_ids: nil, mode: nil, controlled: false, bounty: false)
        result = { 'valid' => false, 'ready' => false, 'errors' => [], 'missing' => [], 'warnings' => [], 'normalized' => {} }
        unless raw.is_a?(Hash)
          result['errors'] << issue(nil, 'Profile settings must be a mapping.')
          return result
        end
        profile = @profile_class.new(copy_value(raw), uid_ids: uid_ids)
        result['normalized'] = json_value(profile.settings)
        unless capabilities['repeat_until_target_gone']
          profile.settings.each do |key, value|
            next unless key.match?(/\Ahunting_commands(?:_[b-j])?\z/) || %w[quick_commands disable_commands].include?(key)
            next unless ::EO::Engine::Engage::Routine.parse(value).any? { |line| line.modifiers.any? { |mod| mod.casecmp?('untildead') } }

            result['errors'] << issue(key, 'This engine does not support untildead. Upgrade Hunter and setup together before using repeat-on-target.')
          end
        end
        POLICIES.each { |method| profile.public_send(method) }
        profile.targets_policy.matchers # Native regex compilation is lazy.
        profile.validate_rest_mode!(mode, controlled: controlled, bounty: bounty)
        validate_recovery(raw, result)
        validate_geometry(raw, profile, result, uid_ids)
        %w[hunting_stance wander_stance stand_stance].each do |key|
          next if raw[key].to_s.strip.empty? || raw[key].to_s.strip.downcase == profile[key]
          result['warnings'] << issue(key, "The native engine replaces this stance with #{profile[key].inspect}.", 'normalized')
        end
        if !raw['flee_message'].to_s.strip.empty? && profile['flee_message'].nil?
          result['warnings'] << issue('flee_message', 'The native engine ignores this invalid message pattern.', 'normalized')
        end
        %w[wounded_eval town_rest_required_eval].each do |key|
          next if raw[key].to_s.strip.empty?
          result['warnings'] << issue(key, 'Custom Ruby condition preserved but not evaluated or checked by setup.', 'not_checked')
        end
        unknown = raw.keys.map(&:to_s) - @profile_class::RULES.keys - ['recovery']
        unknown.each { |key| result['warnings'] << issue(key, 'Unknown extension setting preserved; its behavior is not checked.', 'not_checked') }
        result['valid'] = result['errors'].empty?
        result['ready'] = result['valid'] && result['missing'].empty?
        result
      rescue ArgumentError, TypeError, RegexpError => e
        key = (@profile_class::RULES.keys + ['recovery']).find { |candidate| e.message.include?(candidate) }
        result['errors'] << issue(key, e.message)
        result
      end

      # Check reusable character settings through the same native constructors.
      # Profile requires a rest destination while constructing enabled buff and
      # preparation policies. An omitted destination receives a temporary positive
      # ID solely for structural checking; it is never saved or returned. Every
      # composed hunt must pass #validate with its actual destinations and mode.
      # @param raw [Hash{String => Object}] reusable character settings
      # @param uid_ids [#call, nil] read-only UID resolver
      # @return [Hash{String => Object}] structural validity; ready is always false
      def validate_defaults(raw, uid_ids: nil)
        return validate(raw, uid_ids: uid_ids) unless raw.is_a?(Hash)

        context = copy_value(raw)
        temporary_rest = context['resting_room_id'].to_s.strip.empty?
        context['resting_room_id'] = 1 if temporary_rest
        result = validate(context, uid_ids: uid_ids)
        result['ready'] = false
        result['normalized'].select! { |key, _value| raw.key?(key) }
        result['normalized'].delete('resting_room_id') if temporary_rest
        result['missing'].each do |missing|
          result['warnings'] << missing.merge('kind' => 'context_required')
        end
        result['missing'] = []
        result['warnings'] << issue(nil, 'Character defaults are structurally checked only. Each composed hunt must supply its own mapped hunt and rest rooms and pass native capability validation before launch.', 'context_required')
        result
      end

      private

      def field_options(key, cleaner)
        return @profile_class::STANCES + (0..100).step(10).map(&:to_s) if cleaner == :stance

        OPTIONS[key]&.map { |value, label| { 'value' => value.to_s, 'label' => label } }
      end

      def recovery_field
        {
          'key' => 'recovery', 'type' => 'structured', 'cleaner' => 'structured', 'default' => {},
          'label' => 'Integrated recovery preferences', 'page' => 'recovery', 'editor' => 'raw', 'units' => nil,
          'scope' => 'hunt or inherited character default', 'aliases' => %w[recovery ecleanse cleanse dispel poison disease disarm],
          'help' => 'Hunter-owned overrides for integrated Cleanse. Missing keys inherit read-only ecleanse preferences; explicit false disables a preference. Saving does not change standalone ecleanse.',
          'keys' => @cleanse_policy_class ? @cleanse_policy_class.members.map(&:to_s) : []
        }
      end

      def validate_recovery(raw, result)
        return unless raw.key?('recovery')
        recovery = raw['recovery']
        unless recovery.is_a?(Hash)
          result['errors'] << issue('recovery', 'Recovery overrides must be a mapping; remove an override to inherit.')
          return
        end
        unless @cleanse_policy_class
          result['warnings'] << issue('recovery', 'Cleanse policy is unavailable; recovery settings have not been checked.', 'not_checked')
          return
        end
        @cleanse_policy_class.new(**recovery.to_h { |key, value| [key.to_sym, value] })
        unknown = recovery.keys.map(&:to_s) - @cleanse_policy_class.members.map(&:to_s)
        unknown.each { |key| result['warnings'] << issue("recovery.#{key}", 'Unknown recovery preference preserved; the installed Cleanse policy ignores it.', 'not_checked') }
      end

      def validate_geometry(raw, profile, result, uid_ids)
        %w[hunting_room_id resting_room_id].each do |key|
          value = profile[key]
          next if value.is_a?(Integer) && value.positive?
          result['missing'] << issue(key, 'Choose a positive mapped room ID or a resolvable room UID.', 'missing')
        end
        @profile_class::RULES.each do |key, (cleaner, _default)|
          next unless %i[rooms strict_rooms].include?(cleaner)
          raw[key].to_s.split(/,\s*/).each do |entry|
            entry = entry.strip
            next if entry.empty?
            valid = entry.match?(/\A\d+\z/) && entry.to_i.positive?
            if entry.match?(/\Au\d+\z/i)
              resolved = uid_ids&.call(entry[1..].to_i)&.first
              valid = resolved.is_a?(Integer) && resolved.positive?
            end
            result['missing'] << issue(key, "Room #{entry.inspect} could not be resolved to a positive room ID.", 'missing') unless valid
          end
        end
      end

      def issue(key, message, kind = 'invalid')
        { 'key' => key, 'message' => message, 'kind' => kind }
      end

      def copy_value(value)
        case value
        when Hash then value.to_h { |key, item| [key, copy_value(item)] }
        when Array then value.map { |item| copy_value(item) }
        when String then value.dup
        else value
        end
      end

      def json_value(value)
        case value
        when Regexp then value.source
        when Hash then value.to_h { |key, item| [key.to_s, json_value(item)] }
        when Array then value.map { |item| json_value(item) }
        else value
        end
      end
    end
  end
end
