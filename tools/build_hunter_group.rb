# frozen_string_literal: true

require_relative 'build'

module EOHunter
  # Assemble the optional multi-account receiver library for flat Lich installs.
  # Source parts remain separately reviewable; the artifact needs no folders.
  module GroupBuild
    # Delimiters for the source-only loader replaced in flat distributions.
    BEGIN_MARKER = '# BEGIN SOURCE PARTS'
    # End of the one loader region eligible for bundling.
    END_MARKER = '# END SOURCE PARTS'
    # Read the library's declared dependency order rather than duplicate it.
    PARTS_PATTERN = /PARTS\s*=\s*%w\[([^\]]+)\]/

    module_function

    # @param root [String] checkout root
    # @param sha [String, nil] source revision for the generated header
    # @return [EOHunter::Build::Result] complete library and source section map
    def build(root:, sha: nil)
      script = Build.read(root, 'scripts/libeohuntergroup.lic')
      parts = script.match(PARTS_PATTERN)&.captures&.first&.split
      unless parts && !parts.empty? && parts.uniq == parts && parts.all? { |part| /\A[a-z][a-z0-9_]*\z/.match?(part) }
        raise ArgumentError, 'missing or invalid HunterGroup PARTS list'
      end

      lines = script.lines
      starts = lines.each_index.select { |i| lines[i].strip == BEGIN_MARKER }
      ends = lines.each_index.select { |i| lines[i].strip == END_MARKER }
      unless starts.size == 1 && ends.size == 1 && starts.first < ends.first
        raise ArgumentError, 'expected one ordered HunterGroup source loader block'
      end

      result = lines.take(starts.first)
      result << "# Built from scripts/eohunter_group/ (commit #{sha || 'unknown'}).\n"
      sections = {}
      %w[store composition].each do |part|
        path = "eohunter/setup/#{part}.rb"
        source = Build.setup_source(Build.strip_pragma(Build.read(root, "scripts/#{path}")), "setup/#{part}")
        Build.append_marked(result, sections, path, source)
      end
      parts.each do |part|
        source = Build.strip_pragma(Build.read(root, "scripts/eohunter_group/#{part}.rb"))
        source = source.lines.reject do |line|
          match = line.match(/^require_relative ['"]([^'"]+)['"]\s*$/)
          next false unless match
          next true if match[1] == '../eohunter/setup/composition'
          raise ArgumentError, "unbundled HunterGroup dependency: #{match[1]}" unless parts.include?(match[1])

          true
        end.join
        Build.append_marked(result, sections, "eohunter_group/#{part}.rb", source)
      end
      result.concat(lines.drop(ends.first + 1))
      Build::Result.new(source: result.join, sections: sections)
    end

    # @param root [String] checkout root
    # @param out [String] flat script output path
    # @param sha [String, nil] source revision
    # @return [String] written artifact path
    def write(root:, out: File.join(root, 'dist', 'libeohuntergroup.lic'), sha: Build.git_sha(root))
      result = build(root: root, sha: sha)
      Dir.mkdir(File.dirname(out)) unless Dir.exist?(File.dirname(out))
      File.write(out, result.source, mode: 'wb')
      File.write("#{out}.map", Build.map_text(result.sections), mode: 'wb')
      out
    end
  end
end
