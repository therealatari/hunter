# frozen_string_literal: true

# Process fixture: only native Script ownership/completion and the game child
# are simulated. Mailboxes, supervision, journals and network grants are real.
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'shellwords'
require_relative '../../scripts/eocoordination/protocol'
require_relative '../../scripts/eohunter_group/settings'
require_relative '../../scripts/eohunter_group/rendezvous'
require_relative '../../scripts/eohunter_group/supervisor'
require_relative '../../scripts/eohunter_group/coordinator'
require_relative '../../scripts/eohunter_group/runtime'

module HunterGroupProcessSupport
  class Child
    attr_accessor :done, :success
    attr_reader :commands, :role

    def initialize(role)
      @role = role
      @commands = []
      @done = false
      @success = true
    end

    def join(_timeout) = @done ? self : nil
    def completed_successfully? = @done && @success
  end

  class Scripts
    attr_reader :children, :autostart_entries
    attr_accessor :ready, :return_safe, :teardown, :stalled

    def initialize
      @owner = Object.new
      @children = []
      @ready = @return_safe = @teardown = true
      @tick = 0
      @stalled = false
      @autostart_entries = [{ name: 'eohunter-ma-group' }]
    end

    def current = @owner
    def list = []
    def start(_name, _arguments) = true

    def start_child(name, arguments)
      if name == 'autostart'
        action, receiver = Shellwords.split(arguments)
        raise 'unexpected autostart target' unless receiver == 'eohunter-ma-group' && %w[add remove].include?(action)

        if action == 'add'
          @autostart_entries.push(name: receiver)
        else
          @autostart_entries.reject! { |entry| entry[:name] == receiver }
        end
        child = Child.new('autostart')
        child.done = true
        return child
      end
      raise 'unexpected child' unless name == 'eohunter'

      child = Child.new(arguments.fetch(:args)[1])
      @children << child
      child
    end

    def step
      return if @stalled

      @tick += 1
      @children.each do |child|
        next if child.done

        context = EO::HunterGroup.await_context(child, timeout: 0.01)
        command = context.command
        child.commands << command if child.commands.last != command
        context.pin_profile({ 'resting_room_id' => 324 }, 'pinned-profile') unless context.profile_settings
        context.report_hub('druby://127.0.0.1:12345') if context.role == :head && !context.hub_uri
        case command
        when :prepare
          context.report_ready(ready: true, room: 324, owner_tick: @tick, hands: %w[sword shield]) if @ready
        when :commit
          context.report_committed(ready: true, room: 324, owner_tick: @tick) if @ready
        when :return
          context.report_safe(safe: true, room: 324, owner_tick: @tick) if @return_safe
          child.done = true if @teardown
        end
        phase = { prepare: @ready ? :ready : :preparing, commit: :committed, hunt: :hunting, return: :returning }.fetch(command)
        context.report_state(phase: phase, ready: @ready, room: 324, hands: %w[sword shield], owner_tick: @tick,
                             native_children_pending: false)
      end
    end
  end

  class NativeSettings
    def initialize(data) = @data = data

    def get_scoped_setting(_scope, _key, script_name:)
      raise 'wrong native settings namespace' unless script_name == 'eohunter'

      @data
    end

    def set_script_settings(_scope, _key, data, script_name:)
      raise 'wrong native settings namespace' unless script_name == 'eohunter'

      @data = data
    end
  end

  class Discovery
    attr_accessor :records
    attr_reader :publication

    def initialize = @records = []
    def query_snapshot = { source: 'ActiveSessionsAPI', sessions: @records }

    def register_session(pid:, eohunter_group_start:)
      @publication = { pid: pid, session_name: eohunter_group_start.dig(:identity, :character),
                       game_code: eohunter_group_start.dig(:identity, :game), connected: true,
                       eohunter_group_start: eohunter_group_start }
      true
    end
  end

  class PeerProcess
    def initialize(configuration)
      @input, @output, @errors, @waiter = Open3.popen3(RbConfig.ruby, __FILE__)
      @error_reader = Thread.new { @errors.read }
      @input.puts(JSON.generate(configuration))
      @initial = receive
    end

    attr_reader :initial

    def call(command, **arguments)
      @input.puts(JSON.generate({ command: command }.merge(arguments)))
      receive
    end

    def terminate
      return if @waiter.join(0)

      Process.kill('TERM', @waiter.pid)
      raise 'peer did not terminate' unless @waiter.join(3)
    rescue Errno::ESRCH
      nil
    end

    def close
      call('close') unless @waiter.join(0)
      raise 'peer did not exit' unless @waiter.join(3)
    ensure
      terminate
      [@input, @output, @errors].each { |io| io.close unless io.closed? }
      @error_reader.join(1)
    end

    private

    def receive
      line = Timeout.timeout(5) { @output.gets }
      raise "peer exited: #{@error_reader.value}" unless line

      response = JSON.parse(line, symbolize_names: true)
      raise "peer failed: #{response[:error]}\n#{response[:backtrace]&.join("\n")}" if response[:error]

      response
    end
  end
end

if $PROGRAM_NAME == __FILE__
  STDOUT.sync = true
  configuration = JSON.parse(STDIN.gets, symbolize_names: true)
  scripts = HunterGroupProcessSupport::Scripts.new
  now = [0.0]
  journal = EO::HunterGroup::RunJournal.new(root: configuration.fetch(:root), game: 'GS3',
                                            character: configuration.fetch(:character), windows: false)
  if configuration[:runtime]
    Object.const_set(:DATA_DIR, File.join(configuration.fetch(:root), 'profiles'))
    discovery = HunterGroupProcessSupport::Discovery.new
    native_settings = HunterGroupProcessSupport::NativeSettings.new(configuration.fetch(:policy))
    settings = EO::HunterGroup::Settings.new(native: native_settings, game: 'GS3', character: configuration.fetch(:character))
    logs = []
    runtime = EO::HunterGroup::Runtime.new(scripts: scripts, settings: settings, discovery: discovery,
                                           game: 'GS3', character: configuration.fetch(:character), root: configuration.fetch(:root), journal: journal,
                                           clock: -> { now.first }, busy: -> { false }, room: -> { 324 }, connection: -> { true },
                                           log: ->(message) { logs << message }, autostart_reader: -> { scripts.autostart_entries })
    supervisor = runtime.instance_variable_get(:@supervisor)
  else
    supervisor = EO::HunterGroup::Supervisor.new(scripts: scripts, journal: journal,
                                                 busy: -> { false }, clock: -> { now.first })
  end
  puts JSON.generate(status: supervisor.status, pid: Process.pid)
  while (line = STDIN.gets)
    begin
      request = JSON.parse(line, symbolize_names: true)
      command = request.delete(:command)
      case command
      when 'advance' then now[0] += request.fetch(:elapsed)
      when 'enqueue' then runtime.enqueue(request.fetch(:action).to_sym, *request.fetch(:arguments, []))
      when 'prepare' then supervisor.prepare(**request)
      when 'commit' then supervisor.commit(**request)
      when 'hunt' then supervisor.hunt(**request)
      when 'cancel' then supervisor.cancel(**request)
      when 'controls'
        request.each { |key, value| scripts.public_send("#{key}=", value) }
      when 'tick'
        now[0] += request.fetch(:elapsed, 0.1)
        scripts.step
        if runtime
          discovery.records = request.fetch(:records, [])
          runtime.tick
        else
          supervisor.tick
        end
      when 'crash'
        supervisor.child.success = false
        supervisor.child.done = request.fetch(:teardown, true)
        supervisor.context.report_unresolved('simulated child crash')
        supervisor.tick
      when 'close'
        runtime&.close
        puts JSON.generate(closed: true)
        break
      else raise "unknown fixture command: #{command}"
      end
      puts JSON.generate(status: supervisor.status, launches: scripts.children.size,
                         roles: scripts.children.map(&:role), commands: scripts.children.map(&:commands),
                         journal: journal.pending, runtime: runtime&.status, publication: discovery&.publication,
                         logs: logs)
    rescue StandardError => error
      puts JSON.generate(error: error.message, backtrace: error.backtrace)
    end
  end
end
