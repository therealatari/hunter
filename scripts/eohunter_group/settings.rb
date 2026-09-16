# frozen_string_literal: true

module ::EO
  # Stable group startup policy and local supervision, outside the hunter engine.
  module HunterGroup
    # Participation is character data, never part of an imported hunting profile.
    class Policy
      # A malformed local participation policy, rejected before persistence.
      class Invalid < ArgumentError; end

      # Validated values, recursively frozen without freezing caller objects.
      attr_reader :data

      # Validate opt-in, exact allowed leaders, local mappings and passive scripts.
      def initialize(data = nil)
        source = hash(data || {}, 'participation')
        keys(source, %w[enabled leaders allowed_background_scripts])
        enabled = source.fetch('enabled', false)
        boolean(enabled)
        leaders = hash(source.fetch('leaders', {}), 'leaders')
        raise Invalid, 'too many allowed leaders' if leaders.size > 32
        background = source.fetch('allowed_background_scripts', [])
        raise Invalid, 'allowed_background_scripts must be an array of at most 32 script names' unless background.is_a?(Array) && background.size <= 32
        background = background.map { |script| name(script, 'background script').downcase }.uniq
        @data = { enabled: enabled, allowed_background_scripts: background, leaders: leaders.to_h do |leader, entry|
          name(leader, 'leader')
          entry = hash(entry, 'leader configuration')
          keys(entry, %w[game groups])
          game = name(entry.fetch('game'), 'game')
          groups = hash(entry.fetch('groups'), 'groups')
          raise Invalid, 'too many group mappings' if groups.size > 64
          [leader, { game: game, groups: groups.to_h do |group, mapping|
            profile_name(group, 'group')
            mapping = hash(mapping, 'group mapping')
            keys(mapping, %w[profile refuge_room join_at_rally])
            profile = profile_name(mapping.fetch('profile'), 'profile')
            refuge = mapping.fetch('refuge_room')
            raise Invalid, 'refuge_room must be a positive integer' unless refuge.is_a?(Integer) && refuge.positive?
            join = mapping.fetch('join_at_rally', false)
            boolean(join)
            [group, { profile: profile, refuge_room: refuge, join_at_rally: join }]
          end }]
        end }
        deep_freeze(@data)
        freeze
      rescue KeyError
        raise Invalid, 'incomplete leader or group mapping'
      end

      # Whether this character explicitly permits startup requests.
      def enabled?
        data[:enabled]
      end

      # Additional scripts explicitly approved as passive by this character.
      def background_scripts
        data[:allowed_background_scripts]
      end

      # Return a frozen local mapping, or nil when admission is not allowed.
      def resolve(leader:, game:, group:)
        return nil unless enabled?
        entry = data[:leaders][leader.to_s]
        return nil unless entry && entry[:game] == game.to_s
        entry[:groups][group.to_s]
      end

      private

      def hash(value, label)
        value = value.to_h if value.respond_to?(:to_h)
        raise Invalid, "#{label} must be a hash" unless value.is_a?(Hash)
        result = value.to_h { |key, item| [key.to_s.dup, item] }
        raise Invalid, 'duplicate configuration keys' unless result.size == value.size
        result
      end

      def keys(value, allowed)
        raise Invalid, 'unknown configuration field' unless (value.keys - allowed).empty?
      end

      def name(value, label)
        unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,79}\z/)
          raise Invalid, "#{label} must be a local name, without paths or command arguments"
        end
        value.dup
      end

      def boolean(value)
        raise Invalid, 'expected true or false' unless value == true || value == false
      end

      def profile_name(value, label)
        unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9 _-]{0,127}\z/)
          raise Invalid, "#{label} must be a local name without paths or command separators"
        end
        value.dup
      end

      def deep_freeze(value)
        value.each { |key, item| deep_freeze(key); deep_freeze(item) } if value.is_a?(Hash)
        value.each { |item| deep_freeze(item) } if value.is_a?(Array)
        value.freeze
      end
    end

    # Native Settings adapter shared by setup, receiver and hunting entry points.
    class Settings
      # One namespace across scripts; never inferred from Script.current.
      NAMESPACE = 'eohunter'
      # Character-level participation data, separate from imported profiles.
      KEY = 'group_startup'

      # Bind native Settings to the fixed EOHunter namespace and character scope.
      def initialize(native: nil, game: nil, character: nil)
        @native = native || Lich::Common::Settings
        @scope = "#{game || XMLData.game}:#{character || XMLData.name}"
        raise Policy::Invalid, 'invalid character settings scope' unless @scope.match?(/\A[A-Za-z0-9_-]+:[A-Za-z0-9_-]+\z/)
      end

      # Read the current character policy without importing hunting profiles.
      def policy
        Policy.new(@native.get_scoped_setting(@scope, KEY, script_name: NAMESPACE))
      end

      # Validate before persisting only this character's participation setting.
      def configure(enabled: policy.enabled?, leaders: policy.data[:leaders], allowed_background_scripts: policy.background_scripts)
        result = Policy.new(enabled: enabled, leaders: leaders, allowed_background_scripts: allowed_background_scripts)
        @native.set_script_settings(@scope, KEY, result.data, script_name: NAMESPACE)
        result
      end

      # Open saved admission; the runtime manages receiver autostart separately.
      def enable
        configure(enabled: true)
      end

      # Close saved admission while preserving mappings and accepted recovery.
      def disable
        configure(enabled: false)
      end

      # Replace this character's explicit passive script approvals.
      def background(scripts:)
        configure(allowed_background_scripts: scripts)
      end

      # Add or update one local mapping without implicitly enabling admission.
      def allow(leader:, game:, group:, profile:, refuge_room:, join_at_rally: false)
        current = policy
        leaders = current.data[:leaders].dup
        prior = leaders[leader.to_s]
        if prior && prior[:game] != game
          raise Policy::Invalid, 'leader already mapped to another game instance'
        end
        groups = prior ? prior[:groups].dup : {}
        groups[group.to_s] = { profile: profile, refuge_room: refuge_room, join_at_rally: join_at_rally }
        leaders[leader.to_s] = { game: game, groups: groups }
        configure(enabled: current.enabled?, leaders: leaders)
      end
    end
  end
end
