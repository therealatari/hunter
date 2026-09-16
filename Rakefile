# frozen_string_literal: true

require_relative 'tools/build'
require_relative 'tools/build_coordination'
require_relative 'tools/build_setup'
require_relative 'tools/build_hunter_group'

desc 'Build the single-file EOHunter, browser setup and coordination scripts'
task :build do
  require 'fileutils'
  root = __dir__
  [EOHunter::Build, EOCoordination::Build, EOHunter::SetupBuild, EOHunter::GroupBuild].each do |builder|
    path = builder.write(root: root)
    puts "built #{path} (#{File.read(path).lines.size} lines), map at #{path}.map"
  end
  FileUtils.cp(File.join(root, 'scripts', 'eohunter-ma-group.lic'), File.join(root, 'dist', 'eohunter-ma-group.lic'))
end

desc 'Build EOHunter, setup, and its optional multi-account receiver and libraries'
task 'build:group' => :build

desc 'Remove dist/'
task :clean do
  require 'fileutils'
  FileUtils.rm_rf(File.join(__dir__, 'dist'))
end

task default: :build

begin
  require 'yard'
  YARD::Rake::YardocTask.new(:doc) do |t|
    t.options = [] # everything is in .yardopts
  end
  # The guides' markdown links, pointed at YARD's file.<name>.html pages.
  Rake::Task[:doc].enhance do
    require_relative 'tools/doclinks'
    changed = EOHunter::DocLinks.rewrite_dir('doc', names: EOHunter::DocLinks.names_from('.yardopts'))
    puts "doc links: #{changed} pages rewritten"
  end
  desc 'YARD coverage, listing what is undocumented'
  task 'doc:stats' do
    sh 'bundle exec yard stats --list-undoc'
  end
rescue LoadError
  desc 'YARD is not installed'
  task(:doc) { abort 'bundle install first: yard is missing' }
end
