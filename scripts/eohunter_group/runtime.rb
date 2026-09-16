# frozen_string_literal: true

require 'securerandom'
require 'json'
require 'yaml'

module ::EO
  module HunterGroup
    # User-visible persistent multi-account receiver script name.
    RECEIVER_NAME = 'eohunter-ma-group'
    # Startup metadata version; not the independent Operations wire version.
    PROTOCOL = 1
    # Fixed typed network operations; no script names or command strings.
    OPERATIONS = {
      prepare: { required: %i[run_id group members refuge_room hub_uri], optional: [] },
      commit: { required: [:run_id], optional: [] },
      hunt: { required: [:run_id], optional: [] },
      cancel: { required: [:run_id], optional: [] }
    }.freeze
    @boot_mutex = Mutex.new

    # Reads only startup roster fields. The child still validates and pins the
    # complete native profile; the receiver never loads EO::Engine while idle.
    def self.read_group_profile(profile, game: XMLData.game, character: XMLData.name, data_dir: DATA_DIR)
      raise ArgumentError, 'invalid local profile name' unless profile.to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9 _-]{0,127}\z/)

      path = File.join(data_dir, game, character, 'bigshot_profiles', "#{profile}.yaml")
      data = YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: false)
      raise ArgumentError, 'profile must contain a mapping' unless data.is_a?(Hash)

      data = data.transform_keys(&:to_s)
      members = data['group_members']
      members = members.split(',').map(&:strip).reject(&:empty?) if members.is_a?(String)
      unless members.is_a?(Array) && members.size.between?(1, 7) && members.uniq.size == members.size &&
             members.all? { |name| name.is_a?(String) && name.match?(/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/) } && !members.include?(character)
        raise ArgumentError, 'profile group_members must name 1 to 7 distinct required followers'
      end
      refuge = Integer(data.fetch('resting_room_id'))
      raise ArgumentError, 'group startup requires a positive numeric resting_room_id' unless refuge.positive?

      { members: members, refuge_room: refuge }
    end

    # The CLI only queues local data. Script.start deliberately creates a root
    # receiver; hunting and recovery use start_child from its own owner loop.
    def self.dispatch_group(profile)
      unless @runtime
        raise 'receiver startup refused' unless Script.start(RECEIVER_NAME, 'local')

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until @runtime
          raise 'receiver failed to initialize' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.05
        end
      end
      @runtime.enqueue(:start, profile)
      true
    end

    # Runs one persistent native owner, or forwards a local command to it.
    def self.run_receiver(arguments = [])
      arguments = arguments.to_a.map(&:to_s)
      runtime = @boot_mutex.synchronize do
        if @runtime
          @runtime.enqueue(arguments.first.to_s.empty? ? :status : arguments.shift.to_sym, *arguments) unless arguments.first == 'local'
          return
        end
        Script.loadlib('libeocoordination')
        Coordination.require_version('0.1.0')
        unless Script.respond_to?(:start_child) && Script.current.respond_to?(:join) && defined?(Lich::InternalAPI::ActiveSessions)
          raise 'group startup requires native child supervision and ActiveSessions'
        end
        @runtime = Runtime.new(scripts: Script, settings: Settings.new, discovery: Lich::InternalAPI::ActiveSessions,
                               game: XMLData.game, character: XMLData.name,
                               root: File.join(DATA_DIR, 'eohunter-group-private'))
      end
      begin
        runtime.enqueue(arguments.shift.to_sym, *arguments) unless arguments.empty? || arguments.first == 'local'
        loop do
          runtime.tick
          sleep 0.1
        end
      ensure
        begin
          runtime.close
        ensure
          @runtime = nil if @runtime.equal?(runtime)
        end
      end
    end

    # Native owner loop plus dependency-injected policy and transport seams.
    # Network workers belong to Operations::Grant and never invoke this class.
    class Runtime
      # Injected native services remain inert until the owner calls tick.
      def initialize(scripts:, settings:, discovery:, game:, character:, root:, rendezvous: nil, journal: nil,
                     clock: nil, busy: nil, room: nil, log: nil, connection: nil, autostart_reader: nil)
        @scripts, @settings, @discovery = scripts, settings, discovery
        @game, @character = game, character
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @room = room || -> { Room.current&.id }
        @connection = connection || native_connection
        @autostart_reader = autostart_reader || -> do
          Lich::Common::Settings.get_scoped_setting("#{@game}:#{@character}", 'scripts', script_name: 'autostart')
        end
        @log = log || ->(message) { Lich::Messaging.msg('info', "#{RECEIVER_NAME}: #{message}") }
        @rendezvous = rendezvous || Rendezvous.new(root: root)
        @journal = journal || RunJournal.new(root: root, game: game, character: character)
        @queue = SizedQueue.new(8)
        @grants = {}
        @owner_tick = 0
        @sequence = 0
        @supervisor = Supervisor.new(scripts: scripts, journal: @journal, clock: @clock,
                                     busy: busy || method(:busy?))
        @session = new_session
        @last_publication = -Float::INFINITY
      end

      # Adds a bounded local CLI request; peers cannot call this command path.
      def enqueue(command, *arguments)
        raise ArgumentError, 'unknown local group command' unless %i[start stop status enable disable allow background recover].include?(command)

        @queue.push([command, arguments, @scripts.current], true)
      rescue ThreadError
        raise 'local group command queue is full'
      end

      # Progresses local children, rendezvous, grants and group barriers once.
      def tick
        @owner_tick += 1
        consume_local
        progress_autostart
        @supervisor.tick
        unless @connection.call
          @coordinator&.cancel('native connection replaced or unavailable')
          @supervisor.cancel(reason: 'native connection replaced or unavailable') if @supervisor.run_id
        end
        records = discover
        progress_start(records)
        @coordinator&.tick(records)
        policy = @settings.policy
        consider_intents(records, policy) if policy.enabled? && @connection.call && !@admission_error
        progress_grants(policy, records)
        publish(policy) if @clock.call - @last_publication >= 0.5
      end

      # Closes owned endpoints and credentials, preserving unresolved journals.
      def close
        # Native parent teardown owns children. Persisted journal intentionally
        # survives an owner kill; no safe result is inferred here.
        @grants.each_value { |entry| entry[:grant].close }
        @rendezvous.cleanup
        @session.close
      end

      # @return [Hash] saved preference, live availability, and current outcomes
      def status
        { enabled: @settings.policy.enabled?, available: @published == true, local: @supervisor.status,
          group: @coordinator&.status, pending_grants: @grants.size, admission_error: @admission_error,
          autostart: @autostart_status }
      end

      private

      def new_session(run_id = SecureRandom.hex(16))
        Coordination::Session.new(game: @game, character: @character, run_id: run_id,
                                  read_token: SecureRandom.hex(32), enabled: true)
      end

      def busy?
        # Explicit passive allowlist: unknown scripts may own hands or travel.
        passive = %w[lnet narost uberspells infomon spellmonitor autostart]
        passive += @settings.policy.background_scripts if @settings.policy.respond_to?(:background_scripts)
        @scripts.list.any? { |script| !script.equal?(@scripts.current) && !passive.include?(script.name.to_s.downcase) }
      end

      def native_connection
        parser, reader = Game.thread, Game.reader_thread
        valid = parser&.alive? && reader&.alive?
        -> do
          valid &&= Game.thread.equal?(parser) && Game.reader_thread.equal?(reader) && parser.alive? && reader.alive? &&
                    XMLData.game.to_s == @game && XMLData.name.to_s == @character
        end
      end

      def consume_local
        item = begin
          @queue.pop(true)
        rescue ThreadError
          nil
        end
        return unless item

        command, arguments, sender = item
        case command
        when :start
          raise 'an outing is already active or unresolved' unless @supervisor.available? && !@pending_start && (!@coordinator || @coordinator.finished?)

          @pending_start = { profile: arguments.fetch(0), deadline: @clock.call + 10,
                             sender: sender.equal?(@scripts.current) ? nil : sender }
        when :stop
          @pending_start = nil
          if @coordinator && !@coordinator.finished? && @coordinator.intent[:run_id] == @supervisor.run_id
            @coordinator.cancel
          else
            @supervisor.cancel
          end
        when :status then @log.call(JSON.generate(status))
        when :enable, :disable
          raise 'previous autostart settings update still owns its child' if @autostart_job

          @settings.public_send(command)
          child = @scripts.start_child('autostart', "#{command == :enable ? 'add' : 'remove'} #{RECEIVER_NAME}")
          raise 'participation saved, but autostart update failed to launch' unless child

          @autostart_job = { child: child, enabled: command == :enable, deadline: @clock.call + 10 }
          @autostart_status = :pending
          @log.call(command == :enable ? 'participation enabled' : 'new participation disabled; accepted recovery remains owned')
        when :allow
          leader, game, group, profile, refuge, join = arguments
          @settings.allow(leader: leader, game: game, group: group, profile: profile,
                          refuge_room: Integer(refuge), join_at_rally: join == 'join')
          @log.call('local leader/group mapping saved')
        when :background
          @settings.background(scripts: arguments)
          @log.call('local background script approvals replaced')
        when :recover
          raise 'restart recovery needs explicit local profile' if arguments.empty?
          recover_previous(arguments.first)
        end
      rescue StandardError => error
        @log.call(error.message)
      end

      def recover_previous(profile)
        pending = @journal.pending
        raise 'no unresolved recovery record' unless pending

        @supervisor.recover(run_id: pending.fetch('run_id'), profile: profile,
                            leader_identity: JSON.parse(JSON.generate(pending.fetch('leader')), symbolize_names: true),
                            refuge_room: pending.fetch('refuge_room'), profile_settings: pending['settings'],
                            prepared_hands: pending['hands'])
      end

      def progress_autostart
        return unless @autostart_job

        job = @autostart_job
        unless job[:child].join(0)
          if @clock.call >= job[:deadline] && @autostart_status != :unresolved
            @autostart_status = :unresolved
            @log.call('autostart update still pending native completion; check status')
          end
          return
        end
        @autostart_job = nil
        entries = @autostart_reader.call
        present = entries.is_a?(Array) && entries.any? do |entry|
          entry.is_a?(Hash) && (entry[:name] || entry['name']).to_s.downcase == RECEIVER_NAME
        end
        raise 'participation saved, but native autostart update was not verified' unless job[:child].completed_successfully? && present == job[:enabled]

        @autostart_status = :verified
      rescue StandardError => error
        @autostart_status = :unresolved
        @log.call(error.message)
      end

      def progress_start(records)
        return unless @pending_start
        raise 'native connection unavailable; restart receiver after reconnection' unless @connection.call
        # The eohunter CLI must leave its native single-instance slot first.
        if @scripts.list.any? { |script| script.name == 'eohunter' || script.equal?(@pending_start[:sender]) }
          raise 'existing hunter did not release its native script slot' if @clock.call >= @pending_start[:deadline]

          return
        end
        profile = @pending_start.fetch(:profile)
        config = HunterGroup.read_group_profile(profile, game: @game, character: @character)
        raise 'leader must already be at the configured refuge' unless @room.call == config[:refuge_room]

        peers = config[:members].map do |name|
          matches = records.select { |record| record.dig(:identity, :character) == name && record.dig(:identity, :game) == @game }
          raise "required receiver #{name} missing or ambiguous" unless matches.size == 1 && matches.first[:enabled] == true
          raise "required receiver #{name} is not at the refuge" unless matches.first[:room] == config[:refuge_room]

          matches.first
        end
        @session.close
        @session = new_session
        @coordinator = Coordinator.new(identity: @session.identity, group: profile, profile: profile,
                                       members: config[:members], refuge_room: config[:refuge_room], peers: peers,
                                       supervisor: @supervisor, rendezvous: @rendezvous, clock: @clock)
        @pending_start = nil
      rescue StandardError => error
        @pending_start = nil
        @log.call("startup refused: #{error.message}")
      end

      def discover
        snapshot = @discovery.query_snapshot
        return [] unless snapshot.is_a?(Hash) && snapshot[:source] == 'ActiveSessionsAPI' && !snapshot[:error] && snapshot[:sessions].is_a?(Array)

        records = snapshot[:sessions].filter_map do |record|
          metadata = record[:eohunter_group_start]
          next unless record[:pid].is_a?(Integer) && record[:pid].positive? && metadata.is_a?(Hash)
          metadata = JSON.parse(JSON.generate(metadata), symbolize_names: true)
          next unless metadata[:protocol] == PROTOCOL && Coordination::Schema.identity?(metadata[:identity])
          next if record.key?(:connected) && record[:connected] != true
          next if record[:session_name] && record[:session_name] != metadata[:identity][:character]
          next if record[:game_code] && record[:game_code] != metadata[:identity][:game]
          duplicates = snapshot[:sessions].count do |candidate|
            candidate[:session_name] == metadata[:identity][:character] && candidate[:game_code] == metadata[:identity][:game]
          end
          next if duplicates > 1

          metadata
        end
        # Ambiguous names are never reduced to whichever record was first.
        records.reject do |record|
          records.count { |candidate| candidate[:identity].values_at(:game, :character) == record[:identity].values_at(:game, :character) } > 1
        end
      rescue StandardError
        []
      end

      def consider_intents(records, policy)
        records.each do |record|
          intent = record[:intent]
          next unless valid_intent?(intent, record)
          next if @grants.key?(intent[:run_id]) || @grants.size >= 4
          mapping = policy.resolve(leader: intent[:leader][:character], game: intent[:leader][:game], group: intent[:group])
          next unless mapping && mapping[:refuge_room] == intent[:refuge_room]

          token = SecureRandom.hex(32)
          grant = Coordination::Operations::Grant.new(session: @session, peer: intent[:leader], control_token: token,
                                                      operations: OPERATIONS, enabled: true, capacity: 8, clock: @clock)
          raise 'operation listener unavailable; restart receiver after resolving runtime support' unless grant.start

          begin
            id = @rendezvous.publish(receiver: @session.identity, leader: intent[:leader],
                                     grant: { descriptor: grant.descriptor, control_token: token })
          rescue StandardError
            grant.close
            raise
          end
          @grants[intent[:run_id]] = { grant: grant, id: id, intent: intent, mapping: mapping,
                                      created: @clock.call, seen: @clock.call, sequence: record[:sequence], requests: {}, cleanup_requests: [] }
        end
      rescue StandardError => error
        @admission_error = error.message
        @log.call("rendezvous unavailable: #{error.message}")
      end

      def valid_intent?(intent, record)
        intent.is_a?(Hash) && intent[:protocol] == PROTOCOL && intent[:leader] == record[:identity] &&
          intent[:run_id] == intent.dig(:leader, :run_id) && intent[:members].is_a?(Array) &&
          intent[:members].size.between?(1, 7) && intent[:members].uniq == intent[:members] &&
          intent[:members].include?(@character) && intent[:peers].is_a?(Array) &&
          intent[:peers].include?(@session.identity) && intent[:peers].size == intent[:members].size &&
          intent[:peers].all? { |identity| Coordination::Schema.identity?(identity) && identity[:game] == @game } &&
          intent[:peers].map { |identity| identity[:character] }.sort == intent[:members].sort &&
          intent[:group].is_a?(String) && intent[:refuge_room].is_a?(Integer)
      end

      def progress_grants(policy, records)
        @grants.delete_if do |run_id, entry|
          record = records.find { |candidate| candidate[:identity] == entry[:intent][:leader] }
          if record && record[:sequence].to_i > entry[:sequence].to_i
            entry[:seen], entry[:sequence] = @clock.call, record[:sequence]
          end
          if entry[:accepted] && @supervisor.run_id == run_id && @clock.call - entry[:seen] > 8
            @supervisor.cancel(reason: 'leader receiver stopped progressing')
          end
          if !entry[:accepted] && (!policy.enabled? || @clock.call - entry[:created] >= 90 || @clock.call - entry[:seen] > 8)
            entry[:grant].close
            @rendezvous.remove(id: entry[:id])
            next true
          end
          request = entry[:grant].next_request(owner_tick: @owner_tick)
          process_request(entry, request, policy) if request
          settle_requests(entry)
          terminal = %i[safe unresolved].include?(@supervisor.status[:phase]) && @supervisor.run_id == run_id && !@supervisor.child
          entry[:terminal_at] ||= @clock.call if terminal
          expired = !entry[:accepted] && (!policy.enabled? || @clock.call - entry[:created] > 90)
          expired ||= entry[:terminal_at] && @clock.call - entry[:terminal_at] > 30
          if expired
            entry[:grant].close
            @rendezvous.remove(id: entry[:id])
          end
          expired
        end
      end

      def process_request(entry, request, policy)
        arguments = JSON.parse(JSON.generate(request[:arguments]), symbolize_names: true)
        raise 'wrong admitted run' unless arguments[:run_id] == entry[:intent][:run_id]

        operation = request[:operation].to_sym
        case operation
        when :prepare
          raise 'native connection replaced or unavailable' unless @connection.call
          mapping = policy.resolve(leader: entry[:intent][:leader][:character], game: @game, group: arguments[:group])
          raise 'participation mapping changed or disabled' unless mapping && mapping == entry[:mapping]
          raise 'roster or refuge changed' unless arguments[:members] == entry[:intent][:members] && arguments[:refuge_room] == mapping[:refuge_room]
          raise 'follower must already be at approved refuge' unless @room.call == mapping[:refuge_room]

          @supervisor.prepare(run_id: arguments[:run_id], role: :tail, profile: mapping[:profile],
                              leader_identity: entry[:intent][:leader], members: arguments[:members],
                              refuge_room: mapping[:refuge_room], join_at_rally: mapping[:join_at_rally], hub_uri: arguments[:hub_uri])
          @coordinator = nil if @coordinator&.finished?
          entry[:accepted] = true
        when :commit, :hunt
          raise 'run was not prepared by this grant' unless entry[:accepted]

          @supervisor.public_send(operation, run_id: arguments[:run_id])
        when :cancel
          raise 'run was not prepared by this grant' unless entry[:accepted]

          @supervisor.cancel(run_id: arguments[:run_id], reason: 'leader requested return')
        end
        entry[:requests][request[:request_id]] = operation
      rescue StandardError => error
        entry[:grant].settle(request_id: request[:request_id], owner_tick: @owner_tick,
                             outcome: :failed, cleanup: :not_required, reason: error.message)
      end

      def settle_requests(entry)
        state = @supervisor.status
        if state[:phase] == :safe && state[:run_id] == entry[:intent][:run_id]
          entry[:cleanup_requests].each do |request_id|
            entry[:grant].finish_cleanup(request_id: request_id, owner_tick: @owner_tick)
          end
          entry[:cleanup_requests].clear
        end
        entry[:requests].delete_if do |request_id, operation|
          target = { prepare: :ready, commit: :committed, hunt: :hunting, cancel: :safe }.fetch(operation)
          reached = state[:phase] == target
          failed = %i[returning unresolved safe].include?(state[:phase]) && !reached && operation != :cancel
          failed ||= state[:phase] == :unresolved && operation == :cancel
          next false unless reached || failed

          entry[:grant].settle(request_id: request_id, owner_tick: @owner_tick,
                               outcome: reached ? :succeeded : :failed,
                               cleanup: state[:phase] == :safe ? :complete : :pending,
                               reason: reached ? nil : state[:reason] || 'run ended before barrier',
                               result: { run_id: state[:run_id], phase: state[:phase].to_s })
          entry[:cleanup_requests] << request_id unless state[:phase] == :safe
          true
        end
      end

      def publish(policy)
        @last_publication = @clock.call
        @sequence += 1
        metadata = { protocol: PROTOCOL, identity: @session.identity, sequence: @sequence,
                     enabled: policy.enabled? && @connection.call && !@admission_error, room: @room.call, status: @supervisor.status.slice(:run_id, :phase, :reason),
                     intent: @coordinator && !@coordinator.finished? ? @coordinator.intent : nil }
        @published = @discovery.register_session(pid: Process.pid, eohunter_group_start: metadata) == true
      rescue StandardError
        @published = false
      end
    end
  end
end
