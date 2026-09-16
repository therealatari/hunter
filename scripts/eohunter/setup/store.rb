# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tempfile'
require 'yaml'
require 'securerandom'

# EO scripts and their reusable support libraries.
module EO
  # Configuration editing and persistence, independent of the resettable engine.
  module HunterSetup
    # Owns native setup documents; compatibility inputs are always read-only.
    # Revisions identify exact file contents, including edits made outside setup.
    class Store
      # Supported native document directories beneath the character's setup root.
      KINDS = %w[profiles defaults plans injury_policies].freeze
      # Maximum serialized size of any single setup document, in bytes.
      MAX_BYTES = 1_048_576
      # Portable basename syntax; traversal and trailing punctuation are checked separately.
      NAME = /\A[a-zA-Z0-9][a-zA-Z0-9 _.-]{0,79}\z/
      # Additional symlink protection where the host Ruby exposes the open flag.
      NOFOLLOW = File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0

      # Base error for configuration storage failures callers can report directly.
      class Error < StandardError; end
      # A document name, kind, source or storage path violates the storage boundary.
      class InvalidName < Error; end
      # A document contains malformed YAML, unsupported values or excessive data.
      class InvalidData < Error; end
      # An explicitly requested document or compatibility source does not exist.
      class NotFound < Error; end
      # The expected revision no longer matches, or creation would overwrite a file.
      class Conflict < Error; end

      # Binds native documents and optional compatibility inputs to separate roots.
      # @param root [String] EOHunter-owned setup directory
      # @param legacy_root [String, nil] read-only Bigshot profiles directory
      def initialize(root:, legacy_root: nil)
        @root = File.expand_path(root)
        @legacy_root = legacy_root && File.expand_path(legacy_root)
        if @legacy_root && (within?(@root, @legacy_root) || within?(@legacy_root, @root))
          raise InvalidName, 'native and legacy storage must be separate directories'
        end
      end

      # Lists available names without creating directories or loading document data.
      # @param kind [String, Symbol] profiles, defaults or plans
      # @param source [Symbol] :native or :legacy (profiles only)
      # @return [Array<String>] safe names, ordered without opening documents
      def list(kind, source: :native)
        return [] if source == :legacy && kind.to_s == 'profiles' && @legacy_root.nil?

        directory = directory_for(kind, source)
        return [] unless File.directory?(directory)

        Dir.children(directory).filter_map do |entry|
          next unless entry.end_with?('.yaml')

          name = entry.delete_suffix('.yaml')
          path = File.join(directory, entry)
          name if valid_name?(name) && File.file?(path) && !File.symlink?(path)
        end.sort
      end

      # Reads exactly the requested source and captures its content revision.
      # @param kind [String, Symbol] document kind
      # @param name [String] basename, without .yaml
      # @param source [Symbol] :native or :legacy; no implicit fallback
      # @return [Hash] name, kind, source, revision and full unfiltered data
      def read(kind, name, source: :native)
        path = path_for(kind, name, source)
        contents = read_contents(path)
        record(kind, name, source, contents)
      end

      # Saves the entire document atomically; callers retain unknown keys in data.
      # Omission removes an override, so this deliberately does not merge documents.
      # @param kind [String, Symbol] document kind
      # @param name [String] safe basename
      # @param data [Hash] complete document, including unrecognized extension keys
      # @param expected_revision [String, nil] digest from read; nil creates only
      # @return [Hash] the saved record
      # @raise [Conflict] an existing document changed or a create would overwrite
      def save(kind, name, data, expected_revision:)
        path = path_for(kind, name, :native)
        validate_injury_policy!(data) if kind.to_s == 'injury_policies'
        contents = YAML.dump(normalize(data))
        raise InvalidData, 'document exceeds size limit' if contents.bytesize > MAX_BYTES

        directory = File.dirname(path)
        with_write_lock(path) do
          current = File.exist?(path) ? Digest::SHA256.hexdigest(read_contents(path)) : nil
          raise Conflict, "#{kind}/#{name} changed; reload before saving" unless current == expected_revision

          Tempfile.create(['.setup-', '.yaml'], directory) do |temporary|
            temporary.write(contents)
            temporary.flush
            temporary.fsync
            temporary.close
            rename_with_retry(temporary.path, path)
          end
        end
        record(kind, name, :native, contents)
      end

      # Editor-only visibility, deliberately outside runtime profile folders.
      # @return [Hash] hidden native/legacy names and optimistic revision
      def profile_visibility
        saved = visibility_store.read(:profiles, 'visibility')
        hidden = saved[:data]['hidden']
        unless hidden.is_a?(Hash) && hidden.keys.sort == %w[legacy native] &&
               hidden.values.all? { |names| names.is_a?(Array) && names.all? { |name| valid_name?(name) } }
          raise InvalidData, 'invalid profile visibility metadata'
        end
        active = saved[:data]['active_profile']
        raise InvalidData, 'invalid active profile name' unless active.nil? || valid_name?(active)

        { hidden: hidden, active_profile: active, revision: saved[:revision] }
      rescue NotFound
        { hidden: { 'native' => [], 'legacy' => [] }, active_profile: nil, revision: nil }
      end

      # Hide/show a list entry without modifying either profile source.
      # @param name [String] profile basename
      # @param source [Symbol] :native or :legacy
      # @param hidden [Boolean] desired visibility state
      # @param expected_revision [String, nil] editor metadata revision
      # @return [Hash] updated visibility state
      def set_profile_visibility(name, source:, hidden:, expected_revision:)
        raise InvalidData, 'hidden must be true or false' unless [true, false].include?(hidden)

        path_for(:profiles, name, source)
        with_write_lock(path_for(:profiles, name, :native)) do
          read_contents(path_for(:profiles, name, source))
          current = profile_visibility
          raise Conflict, 'clear or change the active profile before hiding it' if hidden && source == :native && current[:active_profile] == name

          names = current[:hidden].fetch(source.to_s)
          names.delete(name)
          names << name if hidden
          save_profile_preferences(current, expected_revision)
        end
      end

      # Select the native default used only by argument-free launches.
      # @param name [String, nil] saved native profile, or nil to clear
      # @param expected_revision [String, nil] editor metadata revision
      # @return [Hash] updated preferences
      def set_active_profile(name, expected_revision:)
        if name && (!valid_name?(name) || %w[setup bounty].include?(name.downcase))
          raise InvalidName, 'choose a saved native profile without a reserved command name'
        end
        with_write_lock(path_for(:profiles, name || 'management', :native)) do
          read(:profiles, name) if name
          current = profile_visibility
          current[:active_profile] = name
          current[:hidden]['native'].delete(name)
          save_profile_preferences(current, expected_revision)
        end
      end

      # Character-wide runtime defaults, independent of editor visibility.
      # @return [Hash] selected injury policy and content revision
      def character_preferences
        saved = character_store.read(:profiles, 'preferences')
        name = saved[:data]['injury_policy']
        raise InvalidData, 'invalid character injury policy name' unless name.nil? || valid_name?(name)

        { injury_policy: name, revision: saved[:revision] }
      rescue NotFound
        { injury_policy: nil, revision: nil }
      end

      # Select an existing policy for subsequent hunts, never a running engine.
      # @param name [String, nil] saved policy name, or nil to clear
      # @param expected_revision [String, nil] character preferences revision
      # @return [Hash] updated character preferences
      def set_character_injury_policy(name, expected_revision:)
        with_write_lock(path_for(:injury_policies, name || 'preferences', :native)) do
          validate_injury_policy!(read(:injury_policies, name)[:data]) if name
          current = character_preferences
          raise Conflict, 'character preferences changed; reload before selecting a policy' unless current[:revision] == expected_revision

          saved = character_store.save(:profiles, 'preferences', { 'injury_policy' => name }, expected_revision: expected_revision)
          { injury_policy: name, revision: saved[:revision] }
        end
      end

      # Validate the document without evaluating its Ruby expression.
      # @param data [Hash] reusable injury policy
      # @return [String] expression for the existing runtime evaluator
      def validate_injury_policy!(data)
        unless data.is_a?(Hash) && data['schema_version'] == 1 && data['settings'].is_a?(Hash) &&
               data['settings'].keys == ['wounded_eval'] && data['settings']['wounded_eval'].is_a?(String) &&
               !data['settings']['wounded_eval'].strip.empty?
          raise InvalidData, 'injury policy needs schema_version: 1 and settings containing a nonempty wounded_eval expression only'
        end

        data['settings']['wounded_eval']
      end

      # Capture deletion identity without parsing possibly broken profile YAML.
      # @param name [String] native profile basename
      # @return [Hash] revision and same-name legacy fallback warning
      def profile_delete_preview(name)
        delete_preview(:profiles, name)
      end

      # Capture an exact native file and report references before confirmation.
      # @param kind [String, Symbol] profiles, defaults or plans
      # @param name [String] native basename
      # @return [Hash] revision, dependents and fallback warning
      def delete_preview(kind, name)
        { name: name, revision: Digest::SHA256.hexdigest(read_contents(path_for(kind, name, :native))),
          dependents: references_to(kind, name),
          legacy_fallback: kind.to_s == 'profiles' && list(:profiles, source: :legacy).include?(name) }
      end

      # Remove only a native hunt profile, retaining its exact bytes in a backup.
      # Shares save's lock and rejects stale or missing revisions.
      # @param name [String] native profile basename
      # @param expected_revision [String] digest from deletion preview
      # @return [Hash] removed name and relative recovery backup location
      def delete_profile(name, expected_revision:)
        delete_document(:profiles, name, expected_revision: expected_revision)
      end

      # Delete native configuration only when its content and saved references
      # still match a safe removal. Backups remain outside selectable folders.
      # @param kind [String, Symbol] profiles, defaults or plans
      # @param name [String] native basename
      # @param expected_revision [String] preview revision
      # @return [Hash] deletion receipt with recovery location
      def delete_document(kind, name, expected_revision:)
        path = path_for(kind, name, :native)
        backup = nil
        with_write_lock(path) do
          if kind.to_s == 'profiles' && profile_visibility[:active_profile] == name
            raise Conflict, 'clear or change the active profile before deleting it'
          end
          dependents = references_to(kind, name)
          raise Conflict, "still used by #{dependents.join(', ')}; unlink these saved references first" unless dependents.empty?

          revision = Digest::SHA256.hexdigest(read_contents(path))
          raise Conflict, 'profile changed; reload before deleting' unless expected_revision.is_a?(String) && revision == expected_revision

          backup = File.join('.deleted', kind.to_s, "#{name}-#{SecureRandom.hex(12)}.yaml")
          destination = File.join(@root, backup)
          check_path!(destination)
          FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
          check_path!(destination)
          rename_with_retry(path, destination)
        end
        { name: name, deleted: true, backup: backup }
      end

      # Copies a compatibility profile into native storage without linking defaults.
      # @param name [String] existing legacy profile name
      # @param as [String] destination name; collisions raise Conflict
      # @return [Hash] newly created native profile record
      def import(name, as: name)
        legacy = read(:profiles, name, source: :legacy)
        save(:profiles, as, legacy.fetch(:data), expected_revision: nil)
      end

      private

      def references_to(kind, name)
        return [] if kind.to_s == 'profiles'

        references = %w[profiles defaults].flat_map do |candidate_kind|
          list(candidate_kind).filter_map do |candidate|
            next if candidate_kind == kind.to_s && candidate == name

            begin
              data = read(candidate_kind, candidate)[:data]
            rescue Error => error
              raise InvalidData, "cannot check references in #{candidate_kind}/#{candidate}: #{error.message}"
            end
            next unless data.key?('settings') || data.key?('schema_version')

            linked = case kind.to_s
                     when 'defaults' then data['defaults'] == name
                     when 'injury_policies' then data['injury_policy'] == name
                     else data['combat_plan'] == name || (data['creature_plans'].is_a?(Hash) && data['creature_plans'].value?(name))
                     end
            "#{candidate_kind}/#{candidate}" if linked
          end
        end
        references << 'character default injury policy' if kind.to_s == 'injury_policies' && character_preferences[:injury_policy] == name
        references
      end

      def character_store
        self.class.new(root: File.join(@root, '.character'))
      end

      def visibility_store
        self.class.new(root: File.join(@root, '.editor'))
      end

      def save_profile_preferences(current, expected_revision)
        raise Conflict, 'profile list preferences changed; reload the list' unless current[:revision] == expected_revision

        saved = visibility_store.save(:profiles, 'visibility', { 'hidden' => current[:hidden], 'active_profile' => current[:active_profile] }, expected_revision: expected_revision)
        { hidden: saved[:data]['hidden'], active_profile: saved[:data]['active_profile'], revision: saved[:revision] }
      end

      def with_write_lock(path)
        directory = File.dirname(path)
        check_path!(directory)
        FileUtils.mkdir_p(directory, mode: 0o700)
        check_path!(directory)
        # A root lock also serializes reference edits with shared-file deletion.
        lock_path = File.join(@root, '.write.lock')
        check_path!(lock_path)
        File.open(lock_path, File::RDWR | File::CREAT | NOFOLLOW, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          check_path!(path)
          yield
        end
      end

      def within?(path, parent)
        path == parent || path.start_with?(parent + File::SEPARATOR)
      end

      def valid_name?(name)
        name.is_a?(String) && name.match?(NAME) && !name.include?('..') && !name.end_with?('.', ' ')
      end

      def directory_for(kind, source)
        kind = kind.to_s
        raise InvalidName, 'unknown document kind' unless KINDS.include?(kind)

        directory = case source
                    when :native then File.join(@root, kind)
                    when :legacy
                      raise InvalidName, 'legacy input supports profiles only' unless kind == 'profiles'
                      raise NotFound, 'legacy storage is not configured' unless @legacy_root

                      @legacy_root
                    else raise InvalidName, 'unknown document source'
                    end
        check_path!(directory)
        directory
      end

      def path_for(kind, name, source)
        raise InvalidName, 'use a simple profile name of at most 80 characters' unless valid_name?(name)

        path = File.join(directory_for(kind, source), "#{name}.yaml")
        check_path!(path)
        path
      end

      def check_path!(path)
        current = path
        loop do
          raise InvalidName, 'symlinks are not supported in setup storage paths' if File.symlink?(current)
          parent = File.dirname(current)
          break if current == parent

          current = parent
        end
      end

      def read_contents(path)
        raise InvalidData, 'document must be a regular file' unless File.lstat(path).file?

        File.open(path, File::RDONLY | NOFOLLOW) do |file|
          raise InvalidData, 'document must be a regular file' unless file.stat.file?
          raise InvalidData, 'document exceeds size limit' if file.size > MAX_BYTES

          contents = file.read(MAX_BYTES + 1) || ''
          raise InvalidData, 'document exceeds size limit' if contents.bytesize > MAX_BYTES

          contents
        end
      rescue Errno::ENOENT
        raise NotFound, "document not found: #{File.basename(path)}"
      end

      def rename_with_retry(source, destination)
        attempts = 0
        begin
          File.rename(source, destination)
        rescue Errno::EACCES
          # Windows readers may hold the destination briefly. Keep the old
          # document intact and bound retries rather than unlinking it first.
          attempts += 1
          raise if attempts >= 3

          sleep 0.01
          retry
        end
      end

      def record(kind, name, source, contents)
        data = YAML.safe_load(contents, permitted_classes: [Symbol], aliases: false)
        { name: name, kind: kind.to_s, source: source, revision: Digest::SHA256.hexdigest(contents), data: normalize(data) }
      rescue Psych::Exception => e
        raise InvalidData, "invalid YAML: #{e.message}"
      end

      def normalize(data)
        raise InvalidData, 'document must be a mapping' unless data.is_a?(Hash)

        normalize_value(data, 0)
      end

      def normalize_value(value, depth)
        raise InvalidData, 'document nesting exceeds limit' if depth > 30

        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            # Legacy profiles use integer spell IDs (notably combat_buffs).
            # JSON object keys are strings; normalize without losing collisions.
            unless key.is_a?(String) || key.is_a?(Symbol) || key.is_a?(Integer)
              raise InvalidData, 'mapping keys must be strings, symbols or integers'
            end
            raise InvalidData, "duplicate mapping key: #{key}" if result.key?(key.to_s)

            result[key.to_s] = normalize_value(item, depth + 1)
          end
        when Array then value.map { |item| normalize_value(item, depth + 1) }
        when String, Integer, TrueClass, FalseClass, NilClass then value
        when Float
          raise InvalidData, 'numbers must be finite' unless value.finite?

          value
        else raise InvalidData, "unsupported value type: #{value.class}"
        end
      end
    end
  end
end
