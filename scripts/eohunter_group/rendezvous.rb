# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

module ::EO
  module HunterGroup
    # Windows PowerShell is part of supported Windows installations. Paths are
    # passed as environment data, never interpolated into executable commands.
    class WindowsPrivacy
      # Fixed native ACL program; all target paths arrive as environment values.
      PROGRAM = <<~'POWERSHELL'.freeze
        $ErrorActionPreference = 'Stop'
        try {
          $target = $env:EOHUNTER_PRIVATE_PATH
          $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
          $allowed = @($user.Value, 'S-1-5-18', 'S-1-5-32-544')
          $item = Get-Item -LiteralPath $target -Force
          if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { exit 1 }
          if ($env:EOHUNTER_PRIVATE_CREATE -eq '1') {
            if (-not $item.PSIsContainer) { exit 1 }
            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $acl.SetOwner($user)
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in $allowed) {
              $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
              $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
              $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $target -AclObject $acl
          }
          $acl = Get-Acl -LiteralPath $target
          if ($allowed -notcontains $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value) { exit 1 }
          $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
          if ($rules.Count -eq 0) { exit 1 }
          foreach ($rule in $rules) {
            if ($rule.AccessControlType -eq 'Allow' -and $allowed -notcontains $rule.IdentityReference.Value) { exit 1 }
          }
          exit 0
        } catch { exit 1 }
      POWERSHELL

      # Bound each native ACL query or initialization attempt.
      def initialize(timeout: 1.5)
        @timeout = timeout
      end

      # Verify privacy, optionally protecting a directory newly created by us.
      def call(path, create: false)
        environment = { 'EOHUNTER_PRIVATE_PATH' => path, 'EOHUNTER_PRIVATE_CREATE' => create ? '1' : '0' }
        pid = Process.spawn(environment, 'powershell.exe', '-NoProfile', '-NonInteractive', '-Command', PROGRAM,
                            in: File::NULL, out: File::NULL, err: File::NULL)
        waiter = Process.detach(pid)
        return waiter.value.success? if waiter.join(@timeout)
        Process.kill('KILL', pid)
        waiter.join(0.25)
        false
      rescue SystemCallError
        false
      end
    end

    # A private local credential channel. Discovery carries only identities.
    class Rendezvous
      # An unsafe, oversized, malformed or stale local credential record.
      class Invalid < StandardError; end
      # Credentials share the coordination transport's bounded frame size.
      MAX_BYTES = 16_384
      # Exact session fields needed to distinguish stale endpoint incarnations.
      IDENTITY_KEYS = %w[character connection_generation game incarnation run_id].freeze

      # Use only the caller's agreed installation directory, never a peer path.
      def initialize(root:, privacy_check: nil, windows: Gem.win_platform?, unlink: nil)
        @root = File.expand_path(root)
        @windows = windows
        @privacy_check = privacy_check || (WindowsPrivacy.new if windows)
        @unlink = unlink || File.method(:unlink)
        @owned = {}
        @mutex = Mutex.new
      end

      # Derive an opaque filename from both exact endpoint identities.
      def id(receiver:, leader:)
        Digest::SHA256.hexdigest(JSON.generate([identity(receiver), identity(leader)]))
      end

      # Exclusively create and close a credential file before exposing its id.
      def publish(receiver:, leader:, grant:)
        receiver = identity(receiver)
        leader = identity(leader)
        key = id(receiver: receiver, leader: leader)
        value = { version: 1, receiver: receiver, leader: leader, grant: grant }
        @mutex.synchronize do
          create(key, value)
          @owned[key] = true
        end
        key
      end

      # Read a bounded private grant only for the expected endpoint pair.
      def read(id:, receiver:, leader:)
        raise Invalid, 'stale rendezvous identity' unless id == self.id(receiver: receiver, leader: leader)
        value = read_file(id)
        unless value['version'] == 1 && value['receiver'] == identity(receiver) && value['leader'] == identity(leader) && value['grant'].is_a?(Hash)
          raise Invalid, 'stale or invalid rendezvous record'
        end
        value['grant']
      end

      # A sharing violation leaves the file owned and retries on a later tick.
      def remove(id:)
        @mutex.synchronize do
          return false unless @owned[id]
          return false unless delete(id)
          @owned.delete(id)
          true
        end
      end

      # Retry removal of this instance's files after sharing violations.
      def cleanup
        @mutex.synchronize { @owned.keys }.each { |key| remove(id: key) }
      end

      protected

      # Canonicalize the exact session fields before deriving a filename.
      # @api private
      def identity(value)
        value = value.to_h if value.respond_to?(:to_h)
        raise Invalid, 'invalid rendezvous identity' unless value.is_a?(Hash)
        result = value.to_h { |key, item| [key.to_s, item] }.sort.to_h
        raise Invalid, 'invalid rendezvous identity' unless result.keys == IDENTITY_KEYS && result.size == value.size
        result.each do |key, item|
          valid = if key == 'connection_generation'
                    item.is_a?(Integer) && item >= 0
                  else
                    item.is_a?(String) && item.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/)
                  end
          raise Invalid, 'invalid rendezvous identity' unless valid
        end
        result
      end

      # Establish and verify the caller's private local rendezvous directory.
      # @api private
      def directory!
        existed = File.exist?(@root)
        FileUtils.mkdir_p(@root, mode: 0o700)
        if @windows && !existed && @privacy_check.is_a?(WindowsPrivacy)
          raise Invalid, 'cannot establish private Windows rendezvous directory' unless @privacy_check.call(@root, create: true)
        end
        stat = File.lstat(@root)
        raise Invalid, 'rendezvous directory is not private' unless stat.directory? && !stat.symlink? && private?(stat, @root)
      end

      # Check native permissions on a directory or already opened file.
      # @api private
      def private?(stat, path)
        if @windows
          # POSIX mode bits cannot establish a Windows directory ACL.
          @privacy_check && @privacy_check.call(path)
        else
          stat.uid == Process.uid && (stat.mode & 0o077).zero?
        end
      end

      # Resolve only an opaque identifier beneath the fixed local directory.
      # @api private
      def path(key)
        raise Invalid, 'invalid rendezvous identifier' unless key.is_a?(String) && key.match?(/\A[0-9a-f]{64}\z/)
        File.join(@root, "#{key}.json")
      end

      # Write a new immutable record and close its handle before returning.
      # @api private
      def create(key, value, max_bytes: MAX_BYTES)
        bytes = JSON.generate(value)
        raise Invalid, 'rendezvous payload too large' if bytes.bytesize > max_bytes
        directory!
        filename = path(key)
        created = false
        begin
          File.open(filename, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            created = true
            raise Invalid, 'rendezvous file is not private' unless private?(file.stat, filename)
            file.write(bytes)
            file.flush
            file.fsync
          end
        rescue StandardError
          delete(key) if created
          raise
        end
        true
      end

      # Read a bounded record while rejecting symlinks and identity replacement.
      # @api private
      def read_file(key, max_bytes: MAX_BYTES)
        directory!
        filename = path(key)
        stat = File.lstat(filename)
        raise Invalid, 'invalid private rendezvous file' unless stat.file? && !stat.symlink? && private?(stat, filename)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        bytes = File.open(filename, flags) do |file|
          raise Invalid, 'rendezvous file changed while opening' unless file.stat.ino == stat.ino && file.stat.dev == stat.dev
          file.read(max_bytes + 1)
        end
        raise Invalid, 'rendezvous payload too large' if bytes.bytesize > max_bytes
        value = JSON.parse(bytes, max_nesting: 12)
        raise Invalid, 'invalid rendezvous record' unless value.is_a?(Hash)
        value
      rescue JSON::ParserError
        raise Invalid, 'invalid rendezvous record'
      end

      # Attempt exact-file cleanup, leaving sharing violations for a later tick.
      # @api private
      def delete(key)
        @unlink.call(path(key))
        true
      rescue Errno::ENOENT
        true
      rescue Errno::EACCES, Errno::EPERM
        false
      end
    end

    # The fixed character filename survives receiver incarnation changes. A
    # partial/corrupt record also blocks restart; only confirmed safety clears it.
    class RunJournal < Rendezvous
      # Bound pinned recovery configuration independently of runtime credentials.
      EVIDENCE_MAX_BYTES = 65_536

      # Keep the unresolved marker stable across receiver restarts.
      def initialize(root:, character:, game:, **options)
        super(root: File.join(root, 'unresolved'), **options)
        @key = Digest::SHA256.hexdigest(JSON.generate([game.to_s, character.to_s]))
      end

      # Return the unresolved marker and any immutable original recovery evidence.
      # Missing or malformed evidence never authorizes automatic restart.
      def pending
        current = base_record
        return nil unless current
        evidence = begin
          read_file(evidence_key(current.fetch('run_id')), max_bytes: EVIDENCE_MAX_BYTES)
        rescue Errno::ENOENT
          nil
        end
        return current unless evidence
        raise Invalid, 'journal evidence belongs to another run' unless evidence['run_id'] == current['run_id']
        current.merge(evidence.slice('profile', 'settings', 'hands'))
      end

      # Persist the safety hold before admitting preparation or hunting.
      def record(run_id:, leader:, refuge_room:)
        raise Invalid, 'invalid journal run id' unless run_id.is_a?(String) && run_id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/)
        raise Invalid, 'invalid journal refuge' unless refuge_room.is_a?(Integer) && refuge_room.positive?
        @mutex.synchronize do
          create(@key, { version: 1, run_id: run_id, leader: identity(leader), refuge_room: refuge_room })
        end
        pending
      end

      # Pin the original local profile and hand evidence once, in a separate
      # exclusive file. Failed writes leave the original safety hold intact.
      def record_evidence(run_id:, profile:, settings:, hands:)
        raise Invalid, 'invalid evidence profile' unless profile.is_a?(String) && profile.match?(/\A[A-Za-z0-9][A-Za-z0-9 _-]{0,127}\z/)
        raise Invalid, 'missing recovery evidence' unless settings.is_a?(Hash) && (hands.is_a?(Hash) || hands.is_a?(Array))
        value = JSON.parse(JSON.generate(version: 1, run_id: run_id, profile: profile, settings: settings, hands: hands), max_nesting: 12)
        @mutex.synchronize do
          current = base_record
          raise Invalid, 'journal belongs to another run' unless current && current['run_id'] == run_id
          key = evidence_key(run_id)
          begin
            create(key, value, max_bytes: EVIDENCE_MAX_BYTES)
          rescue Errno::EEXIST
            raise Invalid, 'original recovery evidence cannot change' unless read_file(key, max_bytes: EVIDENCE_MAX_BYTES) == value
          end
        end
        true
      end

      # Clear only the matching run after explicit safe confirmation. A sharing
      # violation retains the marker and retries on the next safe handoff.
      def clear(run_id:, safe:)
        raise Invalid, 'confirmed local safety is required' unless safe == true
        @mutex.synchronize do
          current = base_record
          return true unless current
          raise Invalid, 'journal belongs to another run' unless current['run_id'] == run_id
          return false unless delete(evidence_key(run_id))
          delete(@key)
        end
      end

      private

      def evidence_key(run_id)
        Digest::SHA256.hexdigest("#{@key}:#{run_id}:evidence")
      end

      def base_record
        current = read_file(@key)
        unless current['version'] == 1 && current['run_id'].is_a?(String) && current['run_id'].match?(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/)
          raise Invalid, 'invalid unresolved journal'
        end
        current
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
