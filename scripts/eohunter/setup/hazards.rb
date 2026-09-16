# frozen_string_literal: true

module EO
  module HunterSetup
    # Small, advisory supplement for documented environmental interactions.
    # This does not prevent casts, infer live conditions, or certify a hunt.
    class Hazards
      # Date the bounded interaction supplement was checked against its sources.
      REVISION = '2026-09-16'.freeze
      # Primary documentation for each supported spell or room condition.
      SOURCES = {
        '719' => 'https://gswiki.play.net/Dark_Catalyst_(719)',
        '713' => 'https://gswiki.play.net/Balefire_(713)',
        'wet' => 'https://gswiki.play.net/Category:Ruined_Temple_creatures'
      }.freeze
      # Explicit spell numbers and display names covered by this supplement.
      SPELLS = { '719' => 'Dark Catalyst', '713' => 'Balefire' }.freeze

      # Use the installed profile parser to retain native routine normalization.
      # @param profile_class [Class] installed native profile parser
      def initialize(profile_class:)
        @profile_class = profile_class
      end

      # Inspect all effective routine slots, including creature-specific slots.
      # Area names establish only possible scope. A caller may supply verified
      # footprint conditions, but an absent condition never becomes an all-clear.
      # @param raw [Hash] complete effective raw profile
      # @param area [String] selected mapped area's name
      # @param conditions [Hash] verified footprint conditions: gas/wet true/false
      # @param uid_ids [#call, nil] read-only UID resolver for native loading
      # @return [Hash{String => Object}] advisory warnings and explicit coverage
      def check(raw, area:, conditions: {}, uid_ids: nil)
        result = {
          'warnings' => [],
          'coverage' => {
            'status' => 'partial', 'revision' => REVISION, 'checked_spells' => SPELLS.keys,
            'not_checked' => ['Other spells, equipment flares, scripts, custom commands, and live room conditions are not checked.'],
            'checked_steps' => 0
          }
        }
        settings = @profile_class.new(raw, uid_ids: uid_ids).settings
        settings.each do |key, commands|
          next unless key.match?(/\Ahunting_commands(?:_[b-j])?\z/) || %w[quick_commands disable_commands].include?(key)
          Array(commands).each_with_index do |entry, index|
            Array(entry).each do |command|
              spell = spell_in(command)
              next unless spell
              result['coverage']['checked_steps'] += 1
              warning = conflict(spell, area.to_s, conditions)
              next unless warning
              result['warnings'] << warning.merge('key' => key, 'step' => index + 1, 'command' => command,
                                                  'spell' => spell, 'source' => SOURCES.fetch(spell), 'revision' => REVISION)
            end
          end
        end
        result
      rescue ArgumentError, TypeError, RegexpError => e
        result['coverage']['status'] = 'not_checked'
        result['coverage']['not_checked'] << "Native profile could not be loaded: #{e.message}"
        result
      end

      private

      def spell_in(command)
        text = command.to_s.strip
        # The native language can wrap commands in conditions and prefixes.
        # Recognize explicit spell tokens only; a script named 719 is opaque.
        return nil if text.match?(/\bscript\s/i)
        match = text.match(/(?:\A|\b(?:incant|cast|channel|prep)\s+)(719|713)(?=\b|\()/i)
        return match[1] if match
        return '719' if text.match?(/\b(?:incant|cast|channel|prep)\s+(?:darkcat|dark catalyst)\b/i)
        return '713' if text.match?(/\b(?:incant|cast|channel|prep)\s+balefire\b/i)

        nil
      end

      def conflict(spell, area, conditions)
        if area.match?(/\bbowels\b/i)
          condition = conditions.fetch('gas', conditions[:gas])
          return nil if condition == false
          return {
            'kind'    => condition == true ? 'known_conflict' : 'possible_conflict',
            'message' => "#{SPELLS.fetch(spell)} (#{spell}) may ignite gas in the Bowels. This depends on gas being present in the selected rooms."
          }
        end
        return unless spell == '719' && area.match?(/\b(?:nelemar|ruined temple)\b/i)
        condition = conditions.fetch('wet', conditions[:wet])
        return if condition == false

        {
          'kind'             => condition == true ? 'known_conflict' : 'possible_conflict',
          'message'          => 'Dark Catalyst (719) can electrify water in wet or submerged Nelemar rooms. The selected footprint and room conditions determine this risk.',
          'condition_source' => SOURCES.fetch('wet')
        }
      end
    end
  end
end
