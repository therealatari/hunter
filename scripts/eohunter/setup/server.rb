# frozen_string_literal: true

require 'webrick'
require 'json'
require 'securerandom'

module EO
  module HunterSetup
    # Local browser transport for the editor. Not a game-command endpoint.
    # A random session token and same-origin checks prevent unrelated web pages
    # from using the loopback listener. They are not a hostile-same-user sandbox.
    class Server
      # Maximum JSON request bytes before a configuration request is refused.
      MAX_BODY = 1_048_576
      # The complete static resource allowlist; arbitrary file reads are absent.
      TYPES = { 'index.html' => 'text/html', 'routine-editor.js' => 'text/javascript', 'injury-editor.js' => 'text/javascript', 'settings-editor.js' => 'text/javascript', 'app.js' => 'text/javascript', 'style.css' => 'text/css' }.freeze

      # Prepare a loopback listener and a fresh browser-session token.
      # @param app [App] injected configuration operations
      # @param assets [Hash, nil] bundled assets, otherwise local files
      def initialize(app:, assets: nil)
        @app = app
        @assets = assets || (HunterSetup.const_defined?(:ASSETS, false) ? HunterSetup::ASSETS : nil)
        @token = SecureRandom.hex(32)
        @server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
                                          AccessLog: [], Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL),
                                          MaxClients: 8, RequestTimeout: 5)
        @port = @server.listeners.first.addr[1]
        @origin = "http://127.0.0.1:#{@port}"
        @server.mount_proc('/') { |req, res| handle(req, res) }
      end

      # Start independently of the script's lifecycle loop.
      # @return [Server] self
      def start
        raise ArgumentError, 'setup server already started' if @thread

        @thread = Thread.new { @server.start }
        self
      end

      # The fragment keeps the token out of HTTP request/access-log URLs.
      # @return [String] local URL for this editor instance
      def url = "#{@origin}/#token=#{@token}"

      # Stop accepting edits and join the owned worker.
      # @return [void]
      def shutdown
        @server.shutdown
        @thread&.join
      end

      # Wait for the editor listener to finish.
      # @return [void]
      def join = @thread&.join

      private

      def handle(req, res)
        res['Cache-Control'] = 'no-store'
        res['X-Content-Type-Options'] = 'nosniff'
        res['Referrer-Policy'] = 'no-referrer'
        res['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        return failure(res, 403, 'unexpected host') unless req['host'] == "127.0.0.1:#{@port}"

        if req.path == '/api'
          api(req, res)
        elsif req.request_method == 'GET'
          name = req.path == '/' ? 'index.html' : req.path.delete_prefix('/')
          return failure(res, 404, 'not found') unless TYPES.key?(name)

          res['Content-Type'] = "#{TYPES.fetch(name)}; charset=utf-8"
          res.body = @assets ? @assets.fetch(name) : File.binread(File.join(__dir__, 'assets', name))
        else
          failure(res, 405, 'method not allowed')
        end
      rescue StandardError => error
        status = error.class.name.end_with?('Conflict') ? 409 : 422
        failure(res, status, error.message, error.class.name.split('::').last)
      end

      def api(req, res)
        return failure(res, 405, 'POST required') unless req.request_method == 'POST'
        return failure(res, 403, 'unexpected origin') unless req['origin'] == @origin
        return failure(res, 403, 'invalid editor token') unless secure_equal?(req['x-setup-token'], @token)
        return failure(res, 415, 'JSON required') unless req['content-type'].to_s.split(';').first == 'application/json'
        return failure(res, 413, 'request too large') if req.content_length.to_i > MAX_BODY

        # Accumulate with a limit, including chunked requests with no length.
        body = +''
        req.body do |chunk|
          raise ArgumentError, 'request too large' if body.bytesize + chunk.bytesize > MAX_BODY
          body << chunk
        end
        result = @app.call(JSON.parse(body, max_nesting: 64))
        res['Content-Type'] = 'application/json; charset=utf-8'
        res.body = JSON.generate(result)
      end

      def secure_equal?(given, expected)
        return false unless given.is_a?(String) && given.bytesize == expected.bytesize

        given.bytes.zip(expected.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
      end

      def failure(res, status, message, kind = 'RequestError')
        res.status = status
        res['Content-Type'] = 'application/json; charset=utf-8'
        res.body = JSON.generate(error: message, kind: kind)
      end
    end
  end
end
