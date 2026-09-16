# frozen_string_literal: true

require_relative 'store'

# EO scripts and their reusable support libraries.
module EO
  # Configuration editing and persistence, independent of the resettable engine.
  module HunterSetup
    # Resolves a saved setup into the flat input consumed by Engine::Profile.
    # Each inherited setting is replaced as a whole; arrays and structured maps
    # are never recursively merged. Geometry, targets and destinations stay local.
    class Composition
      # Native copies take precedence for both ordinary and managed launches.
      # @param name [String] local profile name
      # @param data_dir [String] Lich data root
      # @param game [String] game instance
      # @param character [String] owning character
      # @return [String] native profile path or legacy compatibility fallback
      def self.profile_path(name, data_dir:, game:, character:)
        safe = File.basename(name.to_s.tr("\\\\", '/')).sub(/\A[.\s]+/, '')
        raise ArgumentError, "bad profile name: #{name.inspect}" if safe.empty?

        root = File.join(data_dir, game, character)
        native = File.join(root, 'eohunter', 'profiles', "#{safe}.yaml")
        File.exist?(native) ? native : File.join(root, 'bigshot_profiles', "#{safe}.yaml")
      end

      # Resolve profile data without loading the hunting engine or running work.
      # Invalid native documents never silently fall back to a legacy namesake.
      # @param path [String] selected profile path
      # @return [Hash] effective raw settings, before engine policy conversion
      def self.read_profile(path)
        raw = YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: false) || {}
        raise ArgumentError, 'profile must contain a mapping' unless raw.is_a?(Hash)

        return raw unless raw.key?('schema_version') || raw.key?('settings')

        store = Store.new(root: File.dirname(File.dirname(path)))
        resolved = new(store: store).resolve(raw)
        raise ArgumentError, resolved.errors.join('; ') unless resolved.valid?

        resolved.raw
      end

      # Settings character defaults may supply; each value is replaced as a whole.
      INHERITABLE = %w[
        resting_commands resting_scripts fog_return custom_fog fog_optional fog_rift
        fried overkill lte_boost oom encumbered wounded_eval creeping_dread
        encumbrance_grace_seconds field_rest_for field_rest_commands field_rest_scripts
        field_hunting_prep_commands field_rest_timeout_seconds town_rest_required_eval
        after_town_rest combat_buffs preparations crushing_dread wot_poison confusion
        box_in_hand rest_till_exp rest_till_mana rest_till_spirit rest_till_percentstamina
        hunting_stance wander_stance stand_stance hunting_right_hand hunting_left_hand
        hunting_aim hunting_loadout_sets hunting_loadout_rules hunting_prep_commands
        hunting_scripts signs loot_script wracking_spirit priority delay_loot use_wracking
        loot_stance pull deader sneaky_sneaky check_favor ambush archery_aim flee_count
        flee_message wander_wait flee_clouds flee_vines flee_webs flee_voids bless
        lone_targets_only weapon_reaction hunting_commands hunting_commands_b
        hunting_commands_c hunting_commands_d hunting_commands_e hunting_commands_f
        hunting_commands_g hunting_commands_h hunting_commands_i hunting_commands_j
        quick_commands disable_commands tier3 aim uac_smite uac_mstrike
        mstrike_stamina_cooldown mstrike_stamina_quickstrike mstrike_mob
        mstrike_cooldown mstrike_quickstrike ammo_container ammo wand wand_if_oom
        fresh_wand_container dead_wand_container final_loot dead_man_switch
        depart_switch ignore_disks troubadours_rally recovery
      ].freeze

      # Captured immutable inputs and their origins; runtime policy validation
      # still follows composition and never executes commands during resolution.
      Result = Struct.new(:raw, :provenance, :errors, :revisions, :warnings, keyword_init: true) do
        # Reports whether composition succeeded, independently of advisory warnings.
        # @return [Boolean] whether references and composition were valid
        def valid? = errors.empty?
      end

      # Uses one character's native storage to resolve shared configuration references.
      # @param store [Store] native documents, scoped to the active character
      def initialize(store:)
        @store = store
      end

      # Native documents use schema_version: 1, settings: {}, and optional
      # defaults/combat_plan names and creature_plans: { creature => plan name }.
      # Plain legacy raw hashes remain standalone. Plans contain commands: text.
      # @param profile [Hash] standalone raw profile or versioned setup document
      # @return [Result] flat settings, origins, errors, revisions and override warnings
      def resolve(profile)
        raw = {}
        provenance = {}
        errors = []
        revisions = {}
        warnings = []
        begin
          local, envelope = settings_for(profile)
          defaults = {}
          if envelope && reference?(profile['defaults'])
            name = profile['defaults']
            record = @store.read(:defaults, name)
            defaults = record.fetch(:data)
            inherited, = settings_for(defaults)
            revisions["defaults/#{name}"] = record.fetch(:revision)
            inherited.slice(*INHERITABLE).each do |key, value|
              raw[key] = value
              provenance[key] = "defaults/#{name}"
            end
          end
          local.each do |key, value|
            raw[key] = value
            provenance[key] = 'profile'
          end
          if envelope
            cache = {}
            selected = if profile.key?('combat_plan')
                         profile['combat_plan']
                       elsif !local.key?('hunting_commands')
                         defaults['combat_plan']
                       end
            if reference?(selected)
              raw['hunting_commands'] = plan_commands(selected, cache, revisions)
              provenance['hunting_commands'] = "plans/#{selected}"
              if local.key?('hunting_commands')
                warnings << "Selected Combat Plan #{selected} replaces this profile's hunting_commands override"
              end
            end
            apply_creature_plans(profile.fetch('creature_plans', {}), raw, provenance, cache, revisions)
          end
        rescue Store::Error, ArgumentError => e
          errors << e.message
        end
        Result.new(raw: snapshot(raw), provenance: snapshot(provenance), errors: snapshot(errors), revisions: snapshot(revisions), warnings: snapshot(warnings)).freeze
      end

      # Build a draft-only creature routine using the engine's existing a-j slots.
      # Shared plans and other creatures' routines are never edited or overwritten.
      # @param profile [Hash] native setup envelope
      # @param creature [String] exact eligible target entry
      # @param commands [String] custom routine text, never executed here
      # @return [Hash] new draft; callers still explicitly save it
      def assign_creature_sequence(profile, creature:, commands:)
        local, envelope = settings_for(profile)
        raise ArgumentError, 'custom sequences require a native setup document' unless envelope
        raise ArgumentError, 'custom sequence must contain action text' unless commands.is_a?(String) && !commands.strip.empty?
        raise ArgumentError, 'creature name must be text' unless creature.is_a?(String)

        name = creature.downcase.strip
        targets = target_slots(local['targets'])
        raise ArgumentError, 'duplicate target names must be resolved before assigning a custom sequence' unless targets.size == local['targets'].split(',').size

        links = profile.fetch('creature_plans', {})
        raise ArgumentError, 'creature_plans must be a mapping' unless links.is_a?(Hash)

        draft = profile.merge('creature_plans' => links.reject { |key, _| key.to_s.downcase.strip == name })
        resolved = resolve(draft)
        raise ArgumentError, resolved.errors.join('; ') unless resolved.valid?

        validate_creature!(name, targets, resolved.raw)
        effective_targets = target_slots(resolved.raw['targets'])
        current = targets[name]
        reusable = current != 'a' && local[slot_key(current)].is_a?(String) &&
                   targets.values.count(current) == 1 && effective_targets.values.count(current) == 1
        occupied = targets.values | effective_targets.values | ('b'..'j').select { |slot| !resolved.raw[slot_key(slot)].to_s.empty? }
        slot = reusable ? current : ('b'..'j').find { |letter| !occupied.include?(letter) }
        raise ArgumentError, 'No free a-j routine slot for this creature; existing routines are preserved' unless slot

        targets[name] = slot
        draft['settings'] = local.merge('targets' => targets.map { |target, letter| "#{target}(#{letter})" }.join(', '), slot_key(slot) => commands)
        checked = resolve(draft)
        raise ArgumentError, checked.errors.join('; ') unless checked.valid?

        draft
      end

      private

      def settings_for(document)
        raise ArgumentError, 'profile/defaults must be a mapping' unless document.is_a?(Hash)

        envelope = document.key?('schema_version') || document.key?('settings')
        return [document, false] unless envelope

        raise ArgumentError, 'unsupported setup schema_version (expected 1)' unless document['schema_version'] == 1
        raise ArgumentError, 'settings must be a mapping' unless document['settings'].is_a?(Hash)

        [document['settings'], true]
      end

      def reference?(name)
        return false if name.nil? || name == ''
        raise ArgumentError, 'document references must be names or null' unless name.is_a?(String)

        true
      end

      def plan_commands(name, cache, revisions)
        raise ArgumentError, 'creature plan must name a saved Combat Plan' unless reference?(name)

        cache.fetch(name) do
          record = @store.read(:plans, name)
          commands = record.fetch(:data)['commands']
          raise ArgumentError, "Combat Plan #{name} commands must be text" unless commands.is_a?(String)

          revisions["plans/#{name}"] = record.fetch(:revision)
          cache[name] = commands
        end
      end

      def apply_creature_plans(exceptions, raw, provenance, cache, revisions)
        raise ArgumentError, 'creature_plans must be a mapping' unless exceptions.is_a?(Hash)
        return if exceptions.empty?
        targets = target_slots(raw['targets'])
        # Reserve all nonempty legacy routines, even when not currently selected.
        used = targets.values | ('b'..'j').select { |slot| !raw[slot_key(slot)].to_s.empty? }
        assignments = {}
        seen = []
        exceptions.each do |creature, plan|
          raise ArgumentError, 'creature plan names must be text' unless creature.is_a?(String)

          name = creature.downcase.strip
          raise ArgumentError, "duplicate creature exception: #{creature}" if seen.include?(name)

          seen << name
          validate_creature!(name, targets, raw)
          commands = plan_commands(plan, cache, revisions)
          slot = assignments[plan] || ('a'..'j').find { |letter| raw[slot_key(letter)] == commands }
          slot ||= ('b'..'j').find { |letter| !used.include?(letter) }
          raise ArgumentError, 'Combat Plans exceed the available a-j routine slots; existing routines are preserved' unless slot

          assignments[plan] = slot
          used |= [slot]
          raw[slot_key(slot)] = commands
          provenance[slot_key(slot)] = "plans/#{plan}"
          targets[name] = slot
          provenance["targets/#{name}"] = "creature_plans/#{plan}"
        end
        raw['targets'] = targets.map { |name, slot| "#{name}(#{slot})" }.join(', ')
      end

      def target_slots(raw)
        raise ArgumentError, 'creature plans require an explicit text target list' unless raw.is_a?(String) && !raw.strip.empty?

        # Follow Profile#targets, retaining pattern order and complete names.
        raw.split(/,/).each_with_object({}) do |entry, result|
          match = entry.match(/(.*)\(([a-jA-J])\)/)
          result[match ? match[1].downcase.strip : entry.downcase.strip] = match ? match[2].downcase : 'a'
        end
      end

      def validate_creature!(name, targets, raw)
        raise ArgumentError, "creature exception is not an explicit eligible target: #{name}" unless targets.key?(name)

        invalid = raw.fetch('invalid_targets', '').to_s.split(/,\s*/)
        if invalid.any? { |entry| [name, name.split.last].include?(entry.downcase.strip) }
          raise ArgumentError, "creature exception is excluded by invalid_targets: #{name}"
        end
        targets.each_key do |pattern|
          break if pattern == name
          if Regexp.new("^#{pattern}$", Regexp::IGNORECASE).match?(name)
            raise ArgumentError, "creature exception is shadowed by earlier target pattern #{pattern}: #{name}"
          end
        end
      rescue RegexpError => e
        raise ArgumentError, "invalid target pattern: #{e.message}"
      end

      def slot_key(slot)
        slot == 'a' ? 'hunting_commands' : "hunting_commands_#{slot}"
      end

      def snapshot(value)
        case value
        when Hash then value.to_h { |key, item| [snapshot(key), snapshot(item)] }.freeze
        when Array then value.map { |item| snapshot(item) }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end
  end
end
