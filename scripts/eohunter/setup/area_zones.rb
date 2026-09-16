# frozen_string_literal: true

require_relative 'area_catalog'

module EO
  module HunterSetup
    # Named subdivisions of broad native creature habitats. Membership
    # is explicit game UIDs, never guessed from connectivity, image pixels or
    # generated plane numbers. See docs/setup-area-zones.md for evidence/gaps.
    module AreaZones
      # Data catalog: additional places can use the same consumer interface.
      DEFINITIONS = {
        'The Rift' => [
          { id: 'plane-1', label: 'Plane 1', uids: (4566001..4566055) },
          { id: 'plane-2', label: 'Plane 2', uids: (4567001..4567055) },
          { id: 'plane-3', label: 'Plane 3', uids: (4568001..4568055) },
          { id: 'plane-4', label: 'Plane 4', uids: (4569001..4569023) },
          { id: 'plane-5', label: 'Plane 5', uids: (4570001..4570014) },
          { id: 'scatter', label: 'The Scatter', uids: (4571001..4571030) }
        ].map(&:freeze).freeze
      }.freeze

      # Encounter evidence is deliberately separate from geographical membership.
      # Do not infer visitors from adjacent map edges or union their home rooms.
      RIFT_CRAWLER_VISITOR = {
        name: 'enormous rift crawler',
        reason: 'Can burrow from Plane 4 onto an adjacent plane; not a regular resident.',
        source_url: 'https://gswiki.play.net/The_Rift/saved_posts#Preview',
        verification: 'Documented possible visitor; not field-checked'
      }.freeze
      POSSIBLE_VISITORS = {
        'The Rift' => { 'plane-3' => [RIFT_CRAWLER_VISITOR].freeze, 'plane-5' => [RIFT_CRAWLER_VISITOR].freeze }.freeze
      }.freeze

      module_function

      # @param area [String] exact native habitat name
      # @param catalog [AreaCatalog] validated research records
      # @return [Array<Hash>] named UID memberships, empty for undivided places
      def for(area, catalog: AreaCatalog.new)
        researched = catalog.for(area)
        researched.empty? ? DEFINITIONS.fetch(area, []) : researched
      end

      # @param area [String] exact geographical parent name
      # @param zone [String, nil] explicit named subarea
      # @return [Array<Hash>] documented visitors, never room memberships
      def visitors(area, zone)
        POSSIBLE_VISITORS.fetch(area, {}).fetch(zone, [])
      end
    end
  end
end
