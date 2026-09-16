# frozen_string_literal: true

module EO
  module HunterSetup
    # Read-only projection of native society and Spell readers for setup.
    # Does not cast, query the game, or replace Maintain's execution policy.
    module SocietyAbilities
      PROVIDERS = { 'CouncilOfLight' => 'Council of Light', 'OrderOfVoln' => 'Order of Voln',
                    'GuardiansOfSunfist' => 'Guardians of Sunfist' }.freeze

      module_function

      # Capture once on the script thread. Missing readers remain unavailable,
      # never an assertion that the character knows no abilities.
      # @param providers [Hash, nil] injectable native society readers
      # @param spells [#[], nil] injectable native Spell catalog
      # @return [Hash] serializable groups and diagnostics
      def capture(providers: nil, spells: nil)
        providers ||= PROVIDERS.to_h do |constant, label|
          reader = if defined?(::Lich::Gemstone::Societies) && ::Lich::Gemstone::Societies.const_defined?(constant, false)
                     ::Lich::Gemstone::Societies.const_get(constant, false)
                   end
          [label, reader]
        end
        spells ||= ::Lich::Common::Spell if defined?(::Lich::Common::Spell)
        { groups: providers.map { |name, reader| group(name, reader, spells) },
          notice: 'Learned abilities and costs were read when setup opened. Reopen setup after learning a new ability. Nothing is activated here.' }
      end

      # @param name [String] society display name
      # @param reader [Object, nil] native society class
      # @param spells [#[], nil] native spell catalog
      # @return [Hash] known entries, or an explicit unavailable result
      def group(name, reader, spells)
        return { name: name, available: false, abilities: [], error: 'Native society reader unavailable.' } unless reader
        return { name: name, available: true, member: false, abilities: [] } unless reader.member?

        abilities = reader.all.filter_map do |entry|
          next unless reader.known?(entry.fetch(:short_name))

          ability(entry, spells)
        end
        { name: name, available: true, member: true, abilities: abilities }
      rescue StandardError => e
        { name: name, available: false, abilities: [], error: "Could not read native abilities (#{e.class}). Existing settings are preserved." }
      end

      # A duration and tracked self effect are necessary for general upkeep.
      # One-shot, targeted and recovery abilities remain visible but unoffered.
      # @param entry [Hash] resolved native society metadata
      # @param spells [#[], nil] native spell catalog
      # @return [Hash] a checkbox choice or an explanation of why not
      def ability(entry, spells)
        id = Integer(entry.fetch(:spell_number))
        spell = spells && spells[id]
        tracked = spell && !spell.duration.to_s.empty? && spell.duration.to_s != '0' && !spell.msgup.to_s.empty?
        attack = spell && spell.type.to_s.include?('attack')
        timed = entry[:duration].is_a?(Numeric) && entry[:duration].positive?
        cooldown = entry[:cooldown_duration].is_a?(Numeric) && entry[:cooldown_duration].positive?
        maintainable = !!(tracked && timed && !attack && !cooldown && spell.known? && id != 9918)
        { id: id, name: entry.fetch(:long_name), description: entry[:summary].to_s,
          cost: entry[:cost], cost_type: entry[:cost_type]&.to_s,
          duration: entry[:duration], maintainable: maintainable,
          reason: maintainable ? nil : 'Not offered for automatic upkeep: no supported continuously renewable self buff. Use the appropriate combat, recovery or emergency policy instead.' }
      end
    end
  end
end
