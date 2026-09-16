# frozen_string_literal: true

require 'base64'

module EO
  module HunterSetup
    # Reads only installed raster maps named by native map metadata. Access is
    # through the authenticated configuration API, never an arbitrary file URL.
    class MapImages
      # Bound memory used for one image, before Base64 encoding.
      MAX_BYTES = 16 * 1024 * 1024

      # @param root [String, nil] Lich MAP_DIR, not a browser-supplied path
      # @param names [Array<String>] native Map image filenames
      def initialize(root:, names:)
        @names = names.compact.map(&:to_s).uniq.freeze
        @root = root && File.realpath(root)
      rescue Errno::ENOENT
        @root = nil
      end

      # Read a known installed map without downloading or evaluating anything.
      # SVG and other active document formats are deliberately unsupported.
      # @param name [String] exact native image filename
      # @return [Hash] browser-decodable raster, retaining its original dimensions
      def read(name)
        unless name.is_a?(String) && @names.include?(name) && !name.match?(/[\\\/:\x00]/) && name != '.' && name != '..'
          raise ArgumentError, 'unknown map image'
        end
        raise ArgumentError, 'The classic map folder is unavailable in this installation.' unless @root

        path = File.realpath(File.join(@root, name))
        raise ArgumentError, 'map image must stay inside the installed map folder' unless File.dirname(path) == @root

        bytes = File.open(path, 'rb') do |file|
          raise ArgumentError, 'map image is not a regular file' unless file.stat.file?
          raise ArgumentError, 'map image exceeds the size limit' if file.stat.size > MAX_BYTES

          file.read(MAX_BYTES + 1)
        end
        raise ArgumentError, 'map image exceeds the size limit' if bytes.bytesize > MAX_BYTES

        mime = if bytes.start_with?([137, 80, 78, 71, 13, 10, 26, 10].pack('C*'))
                 'image/png'
               elsif bytes.start_with?([255, 216, 255].pack('C*'))
                 'image/jpeg'
               elsif bytes.start_with?('GIF87a', 'GIF89a')
                 'image/gif'
               elsif bytes.start_with?('RIFF') && bytes.byteslice(8, 4) == 'WEBP'
                 'image/webp'
               end
        raise ArgumentError, 'The installed map is not a supported raster image (PNG, JPEG, GIF or WebP).' unless mime

        { name: name, data_url: "data:#{mime};base64,#{Base64.strict_encode64(bytes)}" }
      rescue Errno::ENOENT
        raise ArgumentError, "Classic map #{name} is not installed. Install it through your normal map tools, then retry."
      end
    end
  end
end
