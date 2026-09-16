# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tempfile'
require 'yaml'

# EO scripts and their reusable support libraries.
module EO
  # Configuration editing and persistence, independent of the resettable engine.
  module HunterSetup
    # Owns native setup documents; compatibility inputs are always read-only.
    # Revisions identify exact file contents, including edits made outside setup.
    class Store
      # Supported native document directories beneath the character's setup root.
      KINDS = %w[profiles defaults plans].freeze
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
        contents = YAML.dump(normalize(data))
        raise InvalidData, 'document exceeds size limit' if contents.bytesize > MAX_BYTES

        directory = File.dirname(path)
        FileUtils.mkdir_p(directory, mode: 0o700)
        check_path!(directory)
        lock_path = File.join(directory, '.write.lock')
        check_path!(lock_path)
        File.open(lock_path, File::RDWR | File::CREAT | NOFOLLOW, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          check_path!(path)
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

      # Copies a compatibility profile into native storage without linking defaults.
      # @param name [String] existing legacy profile name
      # @param as [String] destination name; collisions raise Conflict
      # @return [Hash] newly created native profile record
      def import(name, as: name)
        legacy = read(:profiles, name, source: :legacy)
        save(:profiles, as, legacy.fetch(:data), expected_revision: nil)
      end

      private

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
