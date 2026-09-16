# frozen_string_literal: true

module ::EO
  module HunterGroup
    # A bounded two-barrier startup. Operation receipts, rather than discovery
    # registration, prove preparation and commitment. Every retry retains its ID.
    class Coordinator
      # Exact bounded startup intent; contains no credentials.
      attr_reader :intent

      # Pins the required peers and begins the local leader's preparation.
      def initialize(identity:, group:, profile:, members:, refuge_room:, peers:, supervisor:, rendezvous:,
                     clock: nil, client_factory: nil)
        @identity, @supervisor, @rendezvous = identity, supervisor, rendezvous
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @client_factory = client_factory || ->(grant) do
          grant = JSON.parse(JSON.generate(grant), symbolize_names: true)
          Coordination::Operations::Client.new(descriptor: grant.fetch(:descriptor),
                                               control_token: grant.fetch(:control_token), local_identity: @identity)
        end
        @intent = Coordination::Schema.immutable(protocol: 1, run_id: identity[:run_id], leader: identity,
                                                 group: group, members: members, refuge_room: refuge_room,
                                                 peers: peers.map { |peer| peer.fetch(:identity) })
        @peers = peers.to_h { |peer| [peer[:identity][:character], { identity: peer[:identity], sequence: peer[:sequence], seen: @clock.call }] }
        @deadline = @clock.call + 90
        @phase = :preparing
        @profile = profile
        @supervisor.prepare(run_id: identity[:run_id], role: :head, profile: profile, leader_identity: identity,
                            members: members, refuge_room: refuge_room, join_at_rally: false)
      end

      # A settled return receipt supersedes the last discovery advertisement.
      # This projects confirmed completion; it does not alter admission or
      # infer a safe return from discovery alone.
      # @return [Hash] group outcome including unconfirmed peers
      def status
        members = @peers.transform_values { |peer| peer[:safe_confirmed] ? :safe : (peer[:status] || :unconfirmed) }
        { run_id: @intent[:run_id], phase: @phase, reason: @reason, members: members }
      end

      # @return [Boolean] whether the bounded group attempt has ended
      def finished? = %i[safe unresolved].include?(@phase)

      # Closes departure and requests each accepted participant's local return.
      def cancel(reason = 'operator stop')
        return if finished?

        @reason = reason
        @phase = :returning
        @return_deadline ||= @clock.call + 180
        @supervisor.cancel(reason: reason)
      end

      # Advances barriers or recovery using exact operation receipts.
      def tick(records)
        return status if finished?

        observe_peers(records)
        cancel('startup deadline exceeded') if @clock.call >= @deadline && !%i[hunting returning].include?(@phase)
        local = @supervisor.status
        cancel(local[:reason] || 'required local hunter ended') if %i[unresolved returning safe].include?(local[:phase]) && @phase != :returning
        case @phase
        when :preparing then prepare_peers(local)
        when :committing then commit_peers(local)
        when :releasing then release_peers
        when :hunting
          cancel('required follower ended') if @peers.values.any? { |peer| %w[safe returning unresolved].include?(peer[:status].to_s) }
        when :returning then return_peers(local)
        end
        status
      rescue StandardError => error
        cancel(error.message)
        status
      end

      private

      def observe_peers(records)
        @peers.each_value do |peer|
          matches = records.select { |record| record[:identity] == peer[:identity] }
          if matches.size == 1 && matches.first[:sequence].is_a?(Integer) && matches.first[:sequence] > peer[:sequence].to_i
            peer[:sequence], peer[:seen] = matches.first[:sequence], @clock.call
            run = matches.first[:status]
            peer[:status] = run[:phase] if run.is_a?(Hash) && run[:run_id] == @intent[:run_id]
          end
          cancel('required peer disappeared or stopped progressing') if @clock.call - peer[:seen] > 8 && @phase != :returning
        end
      end

      def connect(peer)
        return peer[:client] if peer[:client]

        id = @rendezvous.id(receiver: peer[:identity], leader: @identity)
        grant = @rendezvous.read(id: id, receiver: peer[:identity], leader: @identity)
        peer[:client] = @client_factory.call(grant) if grant
      rescue Errno::ENOENT
        nil
      end

      def operation(peer, name, extra = {})
        client = connect(peer)
        return false unless client

        request_id = "#{@intent[:run_id]}:#{name}"
        response = if peer[name] == :submitted
                     client.result(request_id: request_id)
                   else
                     client.submit(request_id: request_id, operation: name.to_s,
                                   arguments: { run_id: @intent[:run_id] }.merge(extra))
                   end
        return false unless response[:ok]

        receipt = response.fetch(:payload)
        peer[name] = :submitted
        if %w[expired revoked].include?(receipt[:state]) || (receipt[:state] == 'settled' && receipt[:outcome] != 'succeeded')
          raise "#{peer[:identity][:character]} refused #{name}: #{receipt[:reason]}" unless name == :cancel

          peer[:status] = :unresolved
        end
        receipt[:state] == 'settled' && receipt[:outcome] == 'succeeded'
      end

      def prepare_peers(local)
        return unless local[:hub_uri]

        all_ready = @peers.values.map do |peer|
          operation(peer, :prepare, group: @intent[:group], members: @intent[:members],
                    refuge_room: @intent[:refuge_room], hub_uri: local[:hub_uri])
        end.all?
        return unless all_ready && local[:phase] == :ready

        @supervisor.commit(run_id: @intent[:run_id])
        @phase = :committing
      end

      def commit_peers(local)
        all_committed = @peers.values.map { |peer| operation(peer, :commit) }.all?
        @phase = :releasing if all_committed && local[:phase] == :committed
      end

      def release_peers
        return unless @peers.values.map { |peer| operation(peer, :hunt) }.all?

        @supervisor.hunt(run_id: @intent[:run_id])
        @phase = :hunting
      end

      def return_peers(local)
        @peers.each_value { |peer| peer[:safe_confirmed] ||= operation(peer, :cancel) }
        if local[:phase] == :safe && @peers.values.all? { |peer| peer[:safe_confirmed] }
          @phase = :safe
        elsif @clock.call >= @return_deadline
          @phase = :unresolved
          @reason ||= 'required members have no confirmed safe receipt'
        end
      end
    end
  end
end
