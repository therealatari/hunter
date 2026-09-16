# frozen_string_literal: true

require 'rbconfig'

module EO
  module HunterSetup
    # Native script adapter: loads definitions, snapshots read-only game data,
    # and owns the editor listener without starting or altering a hunt.
    module Runtime
      # Policy dependencies in the same order as Engine::PARTS. Loading these
      # files defines classes only; engine.rb itself resets live hunt state.
      PROFILE_PARTS = %w[
        events world targets actions preparations combat maneuvers behavior
        rest_decision buff_policy rest watch flee wander tracking loot loadout
        loadout_selection maintain survival engage routines travel profile
        cleanse group runner coordination_hold coordination controller managed_group
      ].freeze
      # Browser application modules; shared readers are loaded first.
      SETUP_PARTS = %w[store composition schema society_abilities area_catalog_data area_catalog area_zones geography map_images hazards app server].freeze

      module_function

      # Reuse the running hunt's policy classes, if present, without reloading.
      # @param script_dir [String] Lich script directory
      # @return [void]
      def load_support(script_dir)
        dir = File.join(script_dir, 'eohunter')
        unless defined?(::EO::Engine::Profile)
          ::EO.const_set(:Engine, Module.new) unless defined?(::EO::Engine)
          PROFILE_PARTS.each { |part| load File.join(dir, "#{part}.rb") }
        end
        SETUP_PARTS.each do |part|
          name = part.split('_').map(&:capitalize).join
          require File.join(dir, 'setup', "#{part}.rb") unless HunterSetup.const_defined?(name, false)
        end
      end

      # Build an editor with this character's native storage and read-only map
      # and recovery inputs. The caller starts and shuts down the listener.
      # @param data_dir [String] Lich data directory
      # @param game [String] active game instance
      # @param character [String] active character name
      # @param char_settings [Hash] read-only compatibility defaults
      # @param templates [Enumerable] native creature records
      # @param rooms [Enumerable] native map records
      # @param uid_resolver [#call] native UID lookup, without travel
      # @param map_dir [String, nil] installed Lich MAP_DIR for classic artwork
      # @return [Server] unstarted local server; caller owns cleanup
      def server(data_dir:, game:, character:, char_settings:, templates:, rooms:, uid_resolver:, map_dir: nil)
        root = File.join(data_dir, game, character)
        store = Store.new(root: File.join(root, 'eohunter'), legacy_root: File.join(root, 'bigshot_profiles'))
        schema = Schema.new(profile_class: EO::Engine::Profile, cleanse_policy_class: EO::Engine::Cleanse::Policy)
        room_list = rooms.to_a.compact
        room_index = room_list.to_h { |room| [room.id.to_i, room] }
        geography = Geography.new(templates: templates, rooms: room_list, uid_resolver: uid_resolver)
        images = MapImages.new(root: map_dir, names: room_list.filter_map { |room| room.image if room.respond_to?(:image) })
        recovery_path = File.join(root, 'ecleanse.yaml')
        recovery = EO::Engine::Cleanse::Policy.load(recovery_path, char_settings: char_settings)
        recovery_resolver = lambda do |raw|
          EO::Engine::Profile.new(raw, uid_ids: uid_resolver).recovery_policy(path: recovery_path, char_settings: char_settings).to_h
        end
        app = App.new(store: store, schema: schema, geography: geography,
                      context: { character: character, game: game }, recovery_fallback: recovery.to_h,
                      uid_ids: uid_resolver, room_lookup: ->(id) { room_index[id.to_i] },
                      hazards: Hazards.new(profile_class: EO::Engine::Profile), recovery_resolver: recovery_resolver, map_images: images,
                      society_abilities: SocietyAbilities.capture)
        Server.new(app: app)
      end

      # Ask the default desktop browser to open the editor. Keep the URL as one
      # argument, never a shell command. Windows reuses Lich's native URL opener.
      # Launch acceptance is not proof a tab rendered; the printed URL remains.
      # @param url [String] local URL
      # @param host [Object] script execution context
      # @param platform [String] Ruby host OS, injectable for offline tests
      # @return [Boolean] whether an opener accepted the launch request
      def open_browser(url, host:, platform: RbConfig::CONFIG['host_os'])
        return true if host.respond_to?(:open_url, true) && host.__send__(:open_url, url) != false

        if platform.match?(/mswin|mingw|cygwin/i)
          return false unless defined?(::Win32) && ::Win32.respond_to?(:ShellExecute)

          ::Win32.ShellExecute(lpOperation: 'open', lpFile: url, nShowCmd: 1).to_i > 32
        else
          opener = platform.match?(/darwin/i) ? '/usr/bin/open' : 'xdg-open'
          Process.detach(Process.spawn(opener, url, out: File::NULL, err: File::NULL))
          true
        end
      rescue StandardError
        false
      end
    end
  end
end
