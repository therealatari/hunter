# frozen_string_literal: true

require_relative 'area_catalog_data'

module EO
  module HunterSetup
    # Validates research metadata without executing data or reading local paths.
    # Membership is explicit geography, independent of creature footprints.
    class AreaCatalog
      # Accepted review states; special candidates are never ordinary choices.
      STATUSES = %w[draft reviewed special_candidate].freeze
      # Fields required for an auditable, explicit geographical record.
      REQUIRED = %i[id label parent_label native_habitat_names map_sheets uids status notes source static_check].freeze
      # Additional evidence carried through to the editor.
      OPTIONAL = %i[excluded_uids evidence].freeze

      # @param records [Array<Hash>] compiled records or isolated test fixtures
      def initialize(records: AreaCatalogData::RECORDS)
        raise ArgumentError, 'catalog records must be an array' unless records.is_a?(Array)

        @records = records.map { |entry| validate(entry) }
        keys = @records.map { |entry| [entry[:parent_label], entry[:id]] }
        raise ArgumentError, 'duplicate catalog area id' unless keys.uniq.length == keys.length
        @records.freeze
      end

      # @return [Array<String>] selectable parent labels; aliases remain evidence
      def parents = @records.reject { |entry| entry[:status] == 'special_candidate' }.map { |entry| entry[:parent_label] }.uniq.sort

      # @param parent [String] exact geographical parent label
      # @return [Array<Hash>] immutable selectable areas, preserving overlaps
      def for(parent)
        @records.select { |entry| entry[:parent_label] == parent && entry[:status] != 'special_candidate' }
      end

      private

      def validate(raw)
        raise ArgumentError, 'catalog area must be an object' unless raw.is_a?(Hash)
        raise ArgumentError, 'catalog keys must be strings or symbols' unless raw.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }

        entry = raw.transform_keys(&:to_sym)
        raise ArgumentError, 'duplicate catalog fields' unless entry.length == raw.length
        raise ArgumentError, 'invalid catalog fields' unless (REQUIRED - entry.keys).empty? && (entry.keys - REQUIRED - OPTIONAL).empty?

        %i[id label parent_label status].each { |key| nonempty_string(entry[key], key) }
        raise ArgumentError, 'invalid catalog id' unless entry[:id].match?(/\A[a-z0-9][a-z0-9_-]*\z/)
        raise ArgumentError, 'invalid catalog status' unless STATUSES.include?(entry[:status])
        %i[native_habitat_names map_sheets notes evidence].each do |key|
          next unless entry.key?(key)
          raise ArgumentError, "catalog #{key} must be a string array" unless entry[key].is_a?(Array) && entry[key].all? { |item| item.is_a?(String) && !item.strip.empty? }
        end
        raise ArgumentError, 'catalog requires native habitat aliases' if entry[:native_habitat_names].empty?
        %i[uids excluded_uids].each do |key|
          next unless entry.key?(key)
          raise ArgumentError, "catalog #{key} must be positive integer UIDs" unless entry[key].is_a?(Array) && entry[key].all? { |uid| uid.is_a?(Integer) && uid.positive? } && entry[key].uniq.length == entry[key].length
        end
        raise ArgumentError, 'catalog requires geographical UIDs' if entry[:uids].empty?
        raise ArgumentError, 'excluded catalog UIDs cannot be members' unless (entry[:uids] & Array(entry[:excluded_uids])).empty?
        %i[source static_check].each do |key|
          raise ArgumentError, "catalog #{key} must be an object" unless entry[key].is_a?(Hash)
        end
        result = entry[:static_check][:result] || entry[:static_check]['result']
        raise ArgumentError, 'invalid catalog static check result' unless %w[pass partial fail].include?(result)

        immutable_data(entry)
      end

      def nonempty_string(value, key)
        raise ArgumentError, "catalog #{key} must be a nonempty string" unless value.is_a?(String) && !value.strip.empty?
      end

      def immutable_data(value)
        case value
        when Hash
          value.to_h do |key, item|
            raise ArgumentError, 'catalog metadata keys must be strings or symbols' unless key.is_a?(String) || key.is_a?(Symbol)
            [key.is_a?(String) ? key.dup.freeze : key, immutable_data(item)]
          end.freeze
        when Array then value.map { |item| immutable_data(item) }.freeze
        when String then value.dup.freeze
        when Integer, TrueClass, FalseClass, NilClass then value
        else raise ArgumentError, 'catalog metadata must contain plain data only'
        end
      end
    end
  end
end
