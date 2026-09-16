# frozen_string_literal: true

require_relative 'build'
require_relative '../scripts/eohunter/setup/runtime'

module EOHunter
  # Packages the independent browser editor and assets for single-file installers.
  module SetupBuild
    # Source hook replaced with bundled policy and editor definitions.
    LOAD_LINE = "load File.join(SCRIPT_DIR, 'eohunter', 'setup', 'runtime.rb') unless defined?(::EO::HunterSetup::Runtime)"

    module_function

    # Assemble the standalone editor, policy definitions and browser assets in
    # memory, preserving an already loaded engine when the script later runs.
    # @param root [String] repository root
    # @param sha [String, nil] build revision
    # @return [Build::Result] complete script and source line map
    def build(root:, sha: nil)
      script = Build.read(root, 'scripts/eohunter-setup.lic')
      raise ArgumentError, 'expected one setup loader' unless script.lines.count { |line| line.chomp == LOAD_LINE } == 1

      head, tail = script.split("#{LOAD_LINE}\n", 2)
      lines = head.lines
      map = {}
      lines << "# Built setup editor (commit #{sha || 'unknown'}); edit sources and rebuild.\n"
      lines.concat("unless defined?(::EO::Engine::Profile)\nmodule ::EO\n  module Engine\n  end\nend\n".lines)
      EO::HunterSetup::Runtime::PROFILE_PARTS.each do |part|
        Build.append_marked(lines, map, "eohunter/#{part}.rb", Build.strip_pragma(Build.read(root, "scripts/eohunter/#{part}.rb")))
      end
      lines << "end\n"
      (EO::HunterSetup::Runtime::SETUP_PARTS + ['runtime']).each do |part|
        source = Build.setup_source(Build.strip_pragma(Build.read(root, "scripts/eohunter/setup/#{part}.rb")), "setup/#{part}")
        Build.append_marked(lines, map, "eohunter/setup/#{part}.rb", source)
      end
      assets = %w[index.html routine-editor.js injury-editor.js settings-editor.js app.js style.css].to_h do |name|
        [name, Build.read(root, "scripts/eohunter/setup/assets/#{name}")]
      end
      lines << "module ::EO::HunterSetup\n  ASSETS = #{assets.inspect}.freeze unless const_defined?(:ASSETS, false)\nend\n"
      lines.concat(tail.lines)
      Build::Result.new(source: lines.join, sections: map)
    end

    # Write the standalone editor and its source line map to the build directory.
    # @param root [String] repository root
    # @param out [String] standalone script destination
    # @param sha [String, nil] build revision
    # @return [String] written path
    def write(root:, out: File.join(root, 'dist', 'eohunter-setup.lic'), sha: Build.git_sha(root))
      result = build(root: root, sha: sha)
      Dir.mkdir(File.dirname(out)) unless Dir.exist?(File.dirname(out))
      File.write(out, result.source, mode: 'wb')
      File.write("#{out}.map", Build.map_text(result.sections), mode: 'wb')
      out
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('..', __dir__)
  if ARGV == ['--check']
    result = EOHunter::SetupBuild.build(root: root)
    puts "built #{result.source.lines.size} lines (nothing written)"
  elsif ARGV.any? { |arg| arg.start_with?('-') } || ARGV.size > 1
    abort 'usage: build_setup.rb [--check] [output path]'
  else
    out = ARGV.empty? ? File.join(root, 'dist', 'eohunter-setup.lic') : File.expand_path(ARGV.first)
    puts "built #{EOHunter::SetupBuild.write(root: root, out: out)}"
  end
end
