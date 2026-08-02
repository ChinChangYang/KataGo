#!/usr/bin/env ruby
# Registers a source file with one or more Xcode targets.
#
#   ruby scripts/add_project_file.rb <path-relative-to-project-dir> <target> [<target>...]
#
# This project has NO file-system-synchronized groups, so a .swift file that is
# not explicitly referenced here is silently never compiled — tests in an
# unregistered file simply do not run, and the suite still reports success.
# Always confirm the executed test COUNT went up after adding a test file.
#
# Idempotent: re-running for an already-registered file is a no-op.

require 'xcodeproj'

PROJECT = 'KataGo Anytime.xcodeproj'

path = ARGV[0]
target_names = ARGV[1..] || []

abort 'usage: add_project_file.rb <path> <target> [<target>...]' if path.nil? || target_names.empty?
abort "no such file: #{path}" unless File.exist?(path)

project = Xcodeproj::Project.open(PROJECT)

targets = target_names.map do |name|
  project.targets.find { |t| t.name == name } or abort "missing target: #{name}"
end

dir = File.dirname(path)
basename = File.basename(path)

group = project.main_group.find_subpath(dir, true)
group.set_source_tree('SOURCE_ROOT')
group.set_path(dir)

ref = group.files.find { |f| f.path == basename }
if ref.nil?
  ref = group.new_reference(basename)
  puts "created reference #{path}"
else
  puts "reference #{path} already present"
end

targets.each do |target|
  already = target.source_build_phase.files.any? { |f| f.file_ref == ref }
  if already
    puts "  #{target.name}: already a member"
  else
    target.add_file_references([ref])
    puts "  #{target.name}: added"
  end
end

project.save
