# frozen_string_literal: true

require_relative 'area_zones'

# Elanthia Online scripts and shared services.
module EO
  # Read-only setup services, independent of the running hunting engine.
  module HunterSetup
    # Resolves native creature habitats against one supplied map snapshot.
    # CreatureTemplate#rooms_by_area silently discards missing UIDs and caches
    # results across map revisions; inspect its underlying #areas instead.
    # The perimeter follows CreatureTemplate#boundary_rooms / BSProfiles.perimeter:
    # every exterior room joined to the footprint by an edge in either direction.
    # Neither movement commands nor executable movement/timing entries are run.
    class Geography
      # Evidence label; static facts never imply a live-world verification.
      VERIFICATION = 'Data-derived; not field-checked'

      # Settings displayed by the persistent profile map, not target suggestions.
      MAP_SETTINGS = %w[hunting_room_id hunting_boundaries resting_room_id field_rest_room_id].freeze

      # Static adapter for the existing hunting-area walker. Reads exit keys,
      # never invokes a movement expression or a live-world passability check.
      class StaticMap
        # @param rooms [Hash<Integer, Object>] native map snapshot
        def initialize(rooms) = @rooms = rooms

        # @param id [Integer] source room
        # @return [Hash<Integer, nil>] recorded destinations, not guaranteed usable
        def exits_from(id)
          (@rooms[id]&.wayto || {}).each_key.filter_map do |key|
            target = Integer(key.to_s, 10)
            [target, nil] if @rooms.key?(target)
          end.to_h
        end

        # @param id [Integer] source room
        # @return [String, nil] descriptive location only
        def room_location(id)
          room = @rooms[id]
          room.location if room.respond_to?(:location)
        end
      end

      # Binds habitat resolution to caller-supplied native data and revisions.
      # @param templates [Enumerable] native CreatureTemplate instances
      # @param rooms [Enumerable] native Map.list rooms (nil entries allowed)
      # @param uid_resolver [#call] native Map.ids_from_uid-compatible callable
      # @param data_revision [String, nil] caller-supplied creature revision
      # @param map_revision [String, nil] caller-supplied map revision
      # @param catalog [AreaCatalog] validated geographical area definitions
      def initialize(templates:, rooms:, uid_resolver:, data_revision: nil, map_revision: nil, catalog: AreaCatalog.new)
        @templates = templates.to_a
        @rooms = rooms.to_a.compact.to_h { |room| [room.id.to_i, room] }
        @uid_resolver = uid_resolver
        @data_revision = data_revision
        @map_revision = map_revision
        @catalog = catalog
        @map_labels = {}
        @rooms.each_value do |room|
          next unless room.respond_to?(:image) && room.image

          label = Array(room.respond_to?(:tags) ? room.tags : []).find { |tag| tag.to_s.start_with?('meta:mapname:') }
          @map_labels[room.image] = label.delete_prefix('meta:mapname:') if label
        end
      end

      # Lists habitats, retaining exact creature names instead of matching nouns.
      # Level filters include a habitat when any known creature fits the band.
      # Unknown levels are included only when no level filter was requested.
      # @param query [String, nil] case-insensitive habitat or creature search
      # @param min_level [Integer, nil] inclusive lower known creature level
      # @param max_level [Integer, nil] inclusive upper known creature level
      # @return [Array<Hash>] names and native creature metadata
      def areas(query: nil, min_level: nil, max_level: nil)
        names = @templates.flat_map { |t| Array(t.areas).map { |a| a[:name].to_s } }.reject(&:empty?).uniq.sort
        names = (names + @catalog.parents.select do |parent|
          @catalog.for(parent).any? { |entry| !(entry[:native_habitat_names] & names).empty? || !resolve_uids(entry[:uids])[:room_ids].empty? }
        end).uniq.sort
        names.filter_map do |name|
          definitions = AreaZones.for(name, catalog: @catalog)
          candidates = definitions.empty? ? templates_for(name) : definitions.flat_map { |entry| zone_templates(entry, name) }.uniq
          creatures = candidates.sort_by { |t| t.name.to_s }.map { |t| creature(t) }
          text = ([name] + definitions.flat_map { |entry| [entry[:label], *entry[:native_habitat_names]] } + creatures.map { |t| t[:name] }).join(' ').downcase
          next unless query.to_s.empty? || text.include?(query.to_s.downcase)
          if min_level || max_level
            next unless creatures.any? do |t|
              t[:level] && (!min_level || t[:level] >= min_level) && (!max_level || t[:level] <= max_level)
            end
          end
          habitat_uids = templates_for(name).flat_map do |template|
            Array(template.areas).select { |habitat| habitat[:name].to_s == name }.flat_map { |habitat| area_uids(habitat) }
          end.uniq
          { name: name, creatures: creatures, verification: VERIFICATION,
            maps: definitions.empty? ? maps_for_uids(habitat_uids) : definitions.flat_map { |entry| zone_maps(entry, name) }.uniq,
            zones: definitions.map { |entry| zone_metadata(entry, name) } }
        end
      end

      # Display/edit existing profile geometry without a creature catalog or
      # replacing custom boundaries. Sheet names are native metadata, not paths
      # opened by this method. All persisted markers remain visible across sheets.
      # @param settings [Hash] raw geometry settings (IDs or UIDs)
      # @param sheet [String, nil] optional additional native map sheet
      # @return [Hash] room diagrams, normalized markers and explicit diagnostics
      def profile_map(settings:, sheet: nil)
        raise ArgumentError, 'map settings must be an object' unless settings.is_a?(Hash)

        diagnostics = []
        markers = {}
        refs = []
        MAP_SETTINGS.each do |key|
          raw = settings[key]
          entries = key == 'hunting_boundaries' ? (raw.is_a?(Array) ? raw : raw.to_s.split(',')) : [raw]
          ids = entries.filter_map do |entry|
            ref = entry.to_s.strip
            next if ref.empty? || ref == '0'

            mapped = if ref.match?(/\Au\d+\z/i)
                       Array(@uid_resolver.call(ref[1..].to_i)).uniq
                     elsif ref.match?(/\A\d+\z/)
                       [ref.to_i]
                     else
                       []
                     end
            unless mapped.length == 1 && @rooms.key?(mapped.first)
              diagnostics << "#{key}: #{ref} is missing, ambiguous, or not a mapped room. Correct it before editing on the map."
              next
            end
            refs << { ref: ref, id: mapped.first } if key == 'hunting_boundaries'
            mapped.first
          end
          markers[key] = key == 'hunting_boundaries' ? ids.uniq.sort : ids.first
        end
        catalog = @rooms.values.filter_map { |room| room.image.to_s if room.respond_to?(:image) && !room.image.to_s.empty? }.uniq.sort
        raise ArgumentError, 'unknown map sheet' if sheet && !sheet.empty? && !catalog.include?(sheet)

        start = markers['hunting_room_id']
        boundaries = markers['hunting_boundaries']
        editable = diagnostics.empty?
        if start && boundaries.include?(start)
          diagnostics << 'The hunting start is also a boundary. Move the start or turn off that boundary.'
        end
        area = if start && diagnostics.empty?
                 EO::Engine::Wander::Area.new(start: start, boundaries: boundaries).build(StaticMap.new(@rooms))
               end
        hunting = area ? area.rooms : []
        anchors = (markers.values.flatten.compact + hunting).uniq
        sheets = anchors.filter_map do |id|
          room = @rooms[id]
          room.image.to_s if room.respond_to?(:image) && !room.image.to_s.empty?
        end
        sheets << sheet if sheet && !sheet.empty?
        sheets.uniq!
        visible = (@rooms.values.select { |room| room.respond_to?(:image) && sheets.include?(room.image.to_s) }.map(&:id) + anchors).uniq.sort
        visible_index = visible.to_h { |id| [id, true] }
        edges = footprint_graph(visible)[:edges].select { |from, to| visible_index[from] && visible_index[to] }
        { markers: markers, boundary_refs: refs, rooms: visible.map { |id| room_description(id) }, room_edges: edges,
          hunting_room_ids: hunting, truncated: area ? area.too_big? : false,
          sheets: catalog, sheet_labels: @map_labels.slice(*catalog), diagnostics: diagnostics, editable: editable, verification: VERIFICATION }
      end

      # Calculate boundaries for explicit manual membership using native map
      # edges and the same walker as profiles. Never executes movement strings.
      # @param room_ids [Array<Integer>] desired hunting rooms
      # @param start_room_id [Integer] selected hunting start
      # @return [Hash] exact representable footprint or an explicit refusal
      def room_geometry(room_ids:, start_room_id:)
        unless room_ids.is_a?(Array) && !room_ids.empty? && room_ids.all? { |id| id.is_a?(Integer) && @rooms.key?(id) }
          raise ArgumentError, 'Choose mapped hunting rooms first.'
        end
        ids = room_ids.uniq.sort
        raise ArgumentError, 'Choose another starting room before excluding the current start.' unless ids.include?(start_room_id)

        graph = footprint_graph(ids)
        raise ArgumentError, 'This selection has missing map exits; review the area before applying it.' unless graph[:missing_room_ids].empty?

        boundaries = (graph[:incoming] + graph[:outgoing]).uniq.sort
        area = EO::Engine::Wander::Area.new(start: start_room_id, boundaries: boundaries).build(StaticMap.new(@rooms))
        unless !area.too_big? && area.rooms.sort == ids
          raise ArgumentError, 'These rooms cannot form one reachable hunt from the selected start. Keep connecting rooms or choose a smaller area.'
        end
        { room_ids: ids, boundary_ids: boundaries, start_room_id: start_room_id, verification: VERIFICATION }
      end

      # Resolves a geographical zone or a legacy creature habitat. Zone member
      # UIDs are independent of target choices, including an empty target list.
      # In an unzoned habitat, selecting creatures retains legacy footprint
      # filtering. Explicit empty room subsets remain empty. Invalid selections raise rather than silently
      # broadening the footprint. Connectivity is weak graph connectivity: even a
      # single component need not be reachable from every possible starting room.
      # Callers must compare the chosen entrance against Hunter's directed area
      # builder before offering a ready-to-launch profile.
      # @param area [String] exact catalog parent or native habitat name
      # @param creature_names [Array<String>, nil] target choices, or legacy habitat subset
      # @param room_ids [Array<Integer>, nil] further restriction of resolved rooms
      # @param zone [String, nil] explicit named subarea, required for subdivided suggestions
      # @param map_image [String, nil] selected classic map context for an unpartitioned habitat
      # @param added_room_ids [Array<Integer>, nil] explicit manual additions on the selected map sheet
      # @return [Hash] JSON-compatible footprint, perimeter, co-spawns and evidence
      # @raise [ArgumentError] unknown habitat, creature, or room subset
      def resolve(area:, creature_names: nil, room_ids: nil, zone: nil, map_image: nil, added_room_ids: nil)
        raise ArgumentError, 'creature_names must be an array' unless creature_names.nil? || creature_names.is_a?(Array)
        raise ArgumentError, 'room_ids must be an array' unless room_ids.nil? || room_ids.is_a?(Array)
        raise ArgumentError, 'added_room_ids must be an array' unless added_room_ids.nil? || added_room_ids.is_a?(Array)
        selected = templates_for(area.to_s)
        zones = AreaZones.for(area.to_s, catalog: @catalog)
        raise ArgumentError, "Unknown habitat: #{area}" if selected.empty? && zones.empty?
        chosen = zones.find { |entry| entry[:id] == zone } unless zone.to_s.empty?
        raise ArgumentError, "Unknown subarea for #{area}: #{zone}" if !zone.to_s.empty? && !chosen
        if !zones.empty? && !chosen && (!creature_names.nil? || !room_ids.nil?)
          raise ArgumentError, 'Choose a named subarea before suggesting hunting rooms.'
        end
        selected = zone_templates(chosen, area.to_s) if chosen
        visitors = AreaZones.visitors(area.to_s, chosen && chosen[:id]).map do |entry|
          template = @templates.find { |candidate| candidate.name.to_s == entry[:name] }
          entry.merge(template ? creature(template) : { level: nil, undead: nil })
        end
        selected_names = (selected.map { |template| template.name.to_s } + visitors.map { |entry| entry[:name] }).uniq
        unless creature_names.nil?
          names = Array(creature_names).map(&:to_s)
          unknown = names - selected_names
          raise ArgumentError, "Creatures not in habitat: #{unknown.join(', ')}" unless unknown.empty?
          selected = selected.select { |t| names.include?(t.name.to_s) }
          selected_names &= names
        end
        uids = selected.flat_map do |template|
          Array(template.areas).select { |a| a[:name].to_s == area.to_s }.flat_map { |a| area_uids(a) }
        end.uniq.sort
        uids = zone_uids(chosen, area.to_s) if chosen
        mapping = resolve_uids(uids)
        ids = mapping[:room_ids]
        if map_image && !map_image.empty?
          unless @rooms.values.any? { |room| room.respond_to?(:image) && room.image == map_image }
            raise ArgumentError, 'Unknown hunting map'
          end
          if chosen
            unless zone_maps(chosen, area.to_s).any? { |map| map[:id] == map_image }
              raise ArgumentError, 'Subarea is not on the selected hunting map'
            end
            # An explicit UID-defined zone also retains its unpositioned rooms.
          else
            ids = ids.select { |id| @rooms[id].respond_to?(:image) && @rooms[id].image == map_image }
          end
        end
        additions = Array(added_room_ids).map { |id| Integer(id.to_s, 10) }.uniq.sort
        unless additions.empty?
          valid = map_image && !map_image.empty? && additions.all? do |id|
            room = @rooms[id]
            room && room.respond_to?(:image) && room.image == map_image
          end
          raise ArgumentError, 'Manual additions must be rooms on the selected hunting map' unless valid
          raise ArgumentError, 'Choose a named subarea before editing hunting rooms.' if !zones.empty? && !chosen
          ids = (ids + additions).uniq.sort
        end
        unless room_ids.nil?
          subset = Array(room_ids).map { |id| Integer(id.to_s, 10) }.uniq.sort
          outside = subset - ids
          raise ArgumentError, "Rooms not in resolved habitat: #{outside.join(', ')}" unless outside.empty?
          ids = subset
        end
        graph = footprint_graph(ids)
        boundaries = (graph[:incoming] + graph[:outgoing]).uniq.sort
        portions = components(ids, graph[:edges])
        complete = !ids.empty? && mapping[:unresolved_uids].empty? && mapping[:missing_room_ids].empty? &&
                   mapping[:ambiguous_uids].empty? && graph[:missing_room_ids].empty?
        residents = co_spawns(ids)
        {
          area: area.to_s, selected_creature_names: selected_names.sort,
          map_image: map_image,
          zones: zones.map { |entry| zone_metadata(entry, area.to_s) }, zone_id: chosen && chosen[:id], zone_label: chosen && chosen[:label],
          zone_metadata: chosen && zone_metadata(chosen, area.to_s), added_room_ids: additions,
          zone_selection_required: !zones.empty? && !chosen,
          room_ids: ids, boundary_ids: boundaries,
          rooms: ids.map { |id| room_description(id) },
          context_rooms: @rooms.values.select { |room| map_image && room.respond_to?(:image) && room.image == map_image }.map { |room| room_description(room.id.to_i) },
          boundary_rooms: boundaries.filter_map { |id| room_description(id) if @rooms.key?(id) },
          context_edges: graph[:edges],
          room_edges: graph[:edges].select { |source, target| ids.include?(source) && ids.include?(target) },
          incoming_boundary_ids: graph[:incoming], outgoing_boundary_ids: graph[:outgoing],
          components: portions, opaque_edges: graph[:opaque_edges],
          creatures: residents,
          visitors: visitors.reject { |entry| residents.any? { |resident| resident[:name] == entry[:name] } },
          coverage: { complete: complete, uid_count: uids.length, room_count: ids.length,
                      unresolved_uids: mapping[:unresolved_uids], ambiguous_uids: mapping[:ambiguous_uids],
                      missing_room_ids: mapping[:missing_room_ids], missing_edge_room_ids: graph[:missing_room_ids] },
          diagnostics: diagnostics(ids, mapping, graph, portions) + catalog_diagnostics(chosen) +
            (additions.empty? ? [] : [{ code: 'manual_area_edit', message: 'Room membership was manually extended; review the resulting area and boundaries.' }]),
          data_revision: @data_revision, map_revision: @map_revision, verification: VERIFICATION
        }
      end

      private

      def zone_uids(entry, parent)
        return entry[:uids] unless entry[:uids].is_a?(Range)

        # Legacy Rift ranges are selectors over known native UIDs, not evidence
        # that every number in an interval is an existing room.
        native = templates_for(parent).flat_map do |template|
          Array(template.areas).select { |habitat| habitat[:name].to_s == parent }.flat_map { |habitat| area_uids(habitat) }
        end
        mapped = @rooms.values.flat_map { |room| Array(room.uid) }.compact.map { |uid| Integer(uid.to_s, 10) }
        (native + mapped).uniq.select { |uid| entry[:uids].cover?(uid) }.sort
      end

      def zone_templates(entry, parent)
        aliases = entry.fetch(:native_habitat_names, [parent])
        members = zone_uids(entry, parent).to_h { |uid| [uid, true] }
        @templates.select do |template|
          Array(template.areas).any? do |habitat|
            aliases.include?(habitat[:name].to_s) && area_uids(habitat).any? { |uid| members[uid] }
          end
        end.sort_by { |template| template.name.to_s }
      end

      def zone_maps(entry, parent)
        names = Array(entry[:map_sheets])
        (maps_for_uids(zone_uids(entry, parent)) + names.map { |name| { id: name, name: @map_labels.fetch(name, name) } }).uniq.sort_by { |map| map[:id] }
      end

      def zone_metadata(entry, parent)
        entry.reject { |key, _| key == :uids }.merge(maps: zone_maps(entry, parent), diagnostics: catalog_diagnostics(entry))
      end

      def catalog_diagnostics(entry)
        return [] unless entry && entry[:status]

        result = []
        if entry[:status] == 'draft'
          result << { code: 'catalog_draft', message: 'Research draft: review and edit this geographical baseline before applying it. It is not field-checked.' }
        end
        check = entry[:static_check][:result] || entry[:static_check]['result']
        unless check == 'pass'
          result << { code: 'catalog_static_check', message: "The catalog static check is #{check}; membership or reachability remains incomplete." }
        end
        result
      end

      def maps_for_uids(uids)
        ids = resolve_uids(uids)[:room_ids]
        ids.filter_map do |id|
          room = @rooms[id]
          room.image if room.respond_to?(:image) && !room.image.to_s.empty?
        end.uniq.sort.map { |name| { id: name, name: @map_labels.fetch(name, name) } }
      end

      def room_description(id)
        room = @rooms.fetch(id)
        box = room.respond_to?(:image_coords) ? room.image_coords : nil
        coords = if box.is_a?(Array) && box.length == 4 && box.all? { |value| value.is_a?(Numeric) && value.finite? }
                   [(box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0]
                 end
        title = room.respond_to?(:title) ? Array(room.title).first : nil
        { id: id, title: title.to_s.empty? ? "Room #{id}" : title.to_s,
          location: room.respond_to?(:location) ? room.location : nil,
          image: room.respond_to?(:image) ? room.image : nil, coords: coords, image_coords: coords ? box : nil }
      end

      def templates_for(name)
        @templates.select { |t| Array(t.areas).any? { |a| a[:name].to_s == name } }.sort_by { |t| t.name.to_s }
      end

      def creature(template)
        { name: template.name.to_s, level: template.level,
          undead: template.respond_to?(:undead) ? template.undead : nil }
      end

      def area_uids(area)
        Array(area[:uids]).flat_map { |entry| entry.is_a?(Range) ? entry.to_a : [entry] }.map { |uid| Integer(uid.to_s, 10) }
      end

      def resolve_uids(uids)
        result = { room_ids: [], unresolved_uids: [], ambiguous_uids: {}, missing_room_ids: [] }
        uids.each do |uid|
          mapped = Array(@uid_resolver.call(uid)).map { |id| Integer(id.to_s, 10) }.uniq.sort
          known, missing = mapped.partition { |id| @rooms.key?(id) }
          result[:unresolved_uids] << uid if known.empty?
          result[:ambiguous_uids][uid] = mapped if mapped.length > 1
          result[:room_ids].concat(known)
          result[:missing_room_ids].concat(missing)
        end
        result[:room_ids] = result[:room_ids].uniq.sort
        result[:missing_room_ids] = result[:missing_room_ids].uniq.sort
        result
      end

      def footprint_graph(ids)
        inside = ids.to_h { |id| [id, true] }
        result = { incoming: [], outgoing: [], edges: [], opaque_edges: [], missing_room_ids: [] }
        @rooms.each do |source, room|
          (room.wayto || {}).each do |destination, movement|
            target = Integer(destination.to_s, 10)
            next unless inside[source] || inside[target]
            result[:edges] << [source, target]
            result[:outgoing] << target if inside[source] && !inside[target]
            result[:incoming] << source if !inside[source] && inside[target]
            result[:missing_room_ids] << target unless @rooms.key?(target)
            timing = room.respond_to?(:timeto) ? (room.timeto || {})[destination] : nil
            if !movement.instance_of?(String) || timing.respond_to?(:call)
              result[:opaque_edges] << { from: source, to: target }
            end
          end
        end
        [:incoming, :outgoing, :missing_room_ids].each { |key| result[key] = result[key].uniq.sort }
        result
      end

      def components(ids, edges)
        adjacency = ids.to_h { |id| [id, []] }
        edges.each do |source, target|
          next unless adjacency.key?(source) && adjacency.key?(target)
          adjacency[source] << target
          adjacency[target] << source
        end
        unseen = ids.to_h { |id| [id, true] }
        result = []
        until unseen.empty?
          queue = [unseen.keys.first]
          portion = []
          until queue.empty?
            id = queue.pop
            next unless unseen.delete(id)
            portion << id
            queue.concat(adjacency[id])
          end
          result << portion.sort
        end
        result
      end

      def co_spawns(ids)
        uids = ids.flat_map { |id| Array(@rooms.fetch(id).uid) }.compact.map { |uid| Integer(uid.to_s, 10) }.uniq
        @templates.select { |t| uids.any? { |uid| t.found_at_uid?(uid) } }.sort_by { |t| t.name.to_s }.map { |t| creature(t) }
      end

      def diagnostics(ids, mapping, graph, portions)
        result = [{ code: 'unverified', message: VERIFICATION },
                  { code: 'static_map', message: 'Mapped links do not establish current access, traversability, or exhaustive creature spawns.' }]
        if ids.length > 1
          arrivals = graph[:edges].filter_map { |from, to| to if from != to && ids.include?(from) && ids.include?(to) }
          no_entry = ids - arrivals
          unless no_entry.empty?
            result << { code: 'no_mapped_entry', message: "Rooms #{no_entry.join(', ')} have no mapped entrance from other selected rooms. Review them before applying; they may not be reachable from your chosen start." }
          end
        end
        result << { code: 'empty_footprint', message: 'No mapped rooms selected; this is not unrestricted hunting permission.' } if ids.empty?
        result << { code: 'unresolved_uids', message: 'Some habitat UIDs have no room in the supplied map.' } unless mapping[:unresolved_uids].empty?
        result << { code: 'ambiguous_uids', message: 'Some habitat UIDs map to multiple room IDs; all candidates are shown.' } unless mapping[:ambiguous_uids].empty?
        result << { code: 'missing_rooms', message: 'Some mapped room or exit IDs are absent from the supplied map.' } unless (mapping[:missing_room_ids] + graph[:missing_room_ids]).empty?
        result << { code: 'disconnected', message: 'The footprint has disconnected portions; one hunt entrance cannot cover them all.' } if portions.length > 1
        result << { code: 'opaque_exits', message: 'Executable or unknown map exits were not evaluated; their traversal is unknown.' } unless graph[:opaque_edges].empty?
        result << { code: 'revision_unknown', message: 'Creature or map revision is unavailable.' } unless @data_revision && @map_revision
        result
      end
    end
  end
end
