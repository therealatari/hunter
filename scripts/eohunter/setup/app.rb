# frozen_string_literal: true

module EO
  module HunterSetup
    # Transport-independent editor operations. This module never sends commands
    # or evaluates profile expressions: execution remains the hunter's job.
    class App
      # Bind read-only native facts and character-scoped configuration storage.
      # @param store [Store] native-only persistence and legacy read access
      # @param schema [Schema] metadata and native profile validation
      # @param geography [Geography, nil] optional native map facts
      # @param context [Hash] character/game identity bound at editor startup
      # @param recovery_fallback [Hash] snapshot of read-only legacy recovery
      # @param uid_ids [#call, nil] native read-only UID resolver
      # @param room_lookup [#call, nil] native map lookup by room ID
      # @param hazards [Hazards, nil] optional advisory coverage
      # @param recovery_resolver [#call, nil] native effective recovery policy
      # @param map_images [MapImages, nil] allowlisted installed raster maps
      # @param society_abilities [Hash] read-only native ability snapshot
      def initialize(store:, schema:, geography: nil, context: {}, recovery_fallback: {}, uid_ids: nil, room_lookup: nil, hazards: nil, recovery_resolver: nil, map_images: nil, society_abilities: {})
        @store = store
        @schema = schema
        @geography = geography
        @context = context.freeze
        @recovery_fallback = recovery_fallback.transform_keys(&:to_s)
        @uid_ids = uid_ids
        @room_lookup = room_lookup
        @hazards = hazards
        @recovery_resolver = recovery_resolver
        @map_images = map_images
        @society_abilities = society_abilities
      end

      # Execute a whitelisted configuration operation, never a Ruby method name.
      # @param request [Hash] JSON request
      # @return [Hash, Array] JSON-serializable response
      def call(request)
        raise ArgumentError, 'request must be an object' unless request.is_a?(Hash)

        case request['action']
        when 'bootstrap' then bootstrap
        when 'read'
          source = request.fetch('source', 'native')
          raise ArgumentError, 'unknown source' unless %w[native legacy].include?(source)

          @store.read(request.fetch('kind'), request.fetch('name'), source: source.to_sym)
        when 'save'
          @store.save(request.fetch('kind'), request.fetch('name'), request.fetch('data'),
                      expected_revision: request['revision'])
        when 'profile_visibility'
          source = request.fetch('source', 'native')
          raise ArgumentError, 'unknown source' unless %w[native legacy].include?(source)

          @store.set_profile_visibility(request.fetch('name'), source: source.to_sym,
                                        hidden: request.fetch('hidden'), expected_revision: request['revision'])
        when 'set_active_profile'
          raise ArgumentError, 'active profiles must be EOHunter-owned' unless request.fetch('source', 'native') == 'native'

          @store.set_active_profile(request.fetch('name'), expected_revision: request['revision'])
        when 'set_character_injury_policy'
          @store.set_character_injury_policy(request.fetch('name'), expected_revision: request['revision'])
        when 'delete_preview', 'delete_document'
          raise ArgumentError, 'legacy inputs remain read-only' unless request.fetch('source', 'native') == 'native'

          kind = request.fetch('kind', 'profiles')
          return @store.delete_preview(kind, request.fetch('name')) if request['action'] == 'delete_preview'

          raise ArgumentError, 'explicit delete confirmation is required' unless request['confirm'] == true

          @store.delete_document(kind, request.fetch('name'), expected_revision: request.fetch('revision'))
        when 'validate' then validate(request.fetch('data'), request.fetch('mode', 'solo'), request['area'], request.fetch('kind', 'profiles'))
        when 'creature_sequence'
          Composition.new(store: @store).assign_creature_sequence(request.fetch('data'), creature: request.fetch('creature'), commands: request.fetch('commands'))
        when 'areas' then @geography ? @geography.areas : []
        when 'map_image'
          raise ArgumentError, 'Classic map images are unavailable in this installation.' unless @map_images

          @map_images.read(request.fetch('name'))
        when 'profile_map'
          raise ArgumentError, 'native map data is unavailable' unless @geography

          @geography.profile_map(settings: request.fetch('settings'), sheet: request['sheet'])
        when 'room_geometry'
          raise ArgumentError, 'native map data is unavailable' unless @geography

          @geography.room_geometry(room_ids: request.fetch('room_ids'), start_room_id: request.fetch('start_room_id'))
        when 'area'
          raise ArgumentError, 'native creature/map data is unavailable' unless @geography

          @geography.resolve(area: request.fetch('area'), creature_names: request['creature_names'], room_ids: request['room_ids'], zone: request['zone'], map_image: request['map_image'], added_room_ids: request['added_room_ids'])
        else raise ArgumentError, 'unknown setup action'
        end
      end

      private

      def bootstrap
        {
          context: @context, fields: @schema.fields,
          profiles: @store.list('profiles'), defaults: @store.list('defaults'), plans: @store.list('plans'),
          injury_policies: @store.list('injury_policies'), character_preferences: @store.character_preferences,
          legacy_profiles: legacy_profiles,
          profile_visibility: @store.profile_visibility,
          recovery_fallback: @recovery_fallback,
          capabilities: @schema.capabilities,
          routine_maneuvers: @schema.routine_maneuvers,
          boon_abilities: @schema.boon_abilities,
          routine_buff_conditions: @schema.routine_buff_conditions,
          society_abilities: @society_abilities,
          notice: 'Saves only EOHunter files. Area suggestions are not field-verified. Saving does not start a hunt.'
        }
      end

      def legacy_profiles
        # Store owns directory/name checks; the read-only catalog is optional.
        @store.list('profiles', source: :legacy)
      end

      def validate(data, mode, area, kind)
        raise ArgumentError, 'unknown hunting mode' unless %w[solo head tail].include?(mode)
        raise ArgumentError, 'unknown validation kind' unless %w[profiles defaults injury_policies].include?(kind)

        if kind == 'injury_policies'
          expression = @store.validate_injury_policy!(data)
          return { errors: [], warnings: ['Custom Ruby is preserved, not executed or verified by setup.'], effective: { 'wounded_eval' => expression }, provenance: { 'wounded_eval' => 'injury policy' } }
        end

        result = Composition.new(store: @store).resolve(data, character_policy: kind == 'profiles')
        return { errors: result.errors, warnings: [], effective: {}, provenance: result.provenance } unless result.valid?

        checked = if kind == 'defaults'
                    @schema.validate_defaults(result.raw, uid_ids: @uid_ids)
                  else
                    @schema.validate(result.raw, uid_ids: @uid_ids, mode: mode == 'solo' ? nil : mode)
                  end
        checked = checked.transform_keys(&:to_sym)
        missing = Array(checked[:missing]) + missing_map_rooms(checked[:normalized] || {})
        warnings = Array(checked[:warnings])
        warnings += result.warnings if result.respond_to?(:warnings)
        advisory = @hazards&.check(result.raw, area: area || data['area'], uid_ids: @uid_ids)
        warnings += Array(advisory['warnings']) if advisory
        {
          errors: Array(checked[:errors]), missing: missing,
          warnings: warnings, valid: checked[:valid], ready: checked[:ready] && missing.empty?,
          effective: result.raw, provenance: result.provenance, revisions: result.revisions,
          hazard_coverage: advisory && advisory['coverage'],
          recovery_fallback: @recovery_fallback,
          effective_recovery: kind == 'profiles' && checked[:valid] && @recovery_resolver ? @recovery_resolver.call(result.raw) : nil,
          note: 'Configuration validation does not prove combat effectiveness or area safety.'
        }
      end

      def missing_map_rooms(normalized)
        return [] unless @room_lookup

        @schema.fields.flat_map do |field|
          next [] unless %w[room rooms strict_rooms].include?(field['cleaner'])

          Array(normalized[field['key']]).filter_map do |id|
            next unless id.is_a?(Integer) && id.positive? && !@room_lookup.call(id)

            { 'key' => field['key'], 'message' => "Room #{id} is absent from the installed map.", 'kind' => 'missing' }
          end
        end
      end
    end
  end
end
