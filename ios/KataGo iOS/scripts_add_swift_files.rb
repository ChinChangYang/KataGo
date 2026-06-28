#!/usr/bin/env ruby
# Idempotently add Swift source files to a target's compile-sources phase.
# Each file is placed in the project group whose on-disk folder matches the
# file's parent directory (reusing a sibling file's group when one exists).
#
# Usage:
#   ruby scripts_add_swift_files.rb "<target name>" <file1> [file2 ...]
#
# Paths may be absolute or relative to this script's directory (the dir that
# contains "KataGo Anytime.xcodeproj"). Shared SwiftPM package sources under
# KataGoUICore/Sources are auto-discovered and must NOT be passed here.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')

target_name = ARGV.shift or abort('usage: ruby scripts_add_swift_files.rb "<target>" <files...>')
files = ARGV.map { |p| File.expand_path(p, __dir__) }
abort('no files given') if files.empty?

project = Xcodeproj::Project.open(PROJECT)
target = project.targets.find { |t| t.name == target_name } or abort("no target '#{target_name}'")

def real(file)
  file.real_path.to_s
rescue StandardError
  nil
end

changed = false
files.each do |abs|
  abort("missing file on disk: #{abs}") unless File.exist?(abs)

  existing = project.files.find { |f| real(f) == abs }
  if existing
    in_phase = target.source_build_phase.files.any? { |bf| real(bf.file_ref) == abs }
    unless in_phase
      target.add_file_references([existing])
      changed = true
      puts "added existing ref to #{target_name}: #{File.basename(abs)}"
    else
      puts "already in #{target_name}: #{File.basename(abs)}"
    end
    next
  end

  dir = File.dirname(abs)
  sibling = project.files.find { |f| (p = real(f)) && File.dirname(p) == dir }
  group = sibling ? sibling.parent : project.main_group
  ref = group.new_reference(abs)
  target.add_file_references([ref])
  changed = true
  puts "added new ref to #{target_name}: #{File.basename(abs)} (group: #{group.display_name})"
end

if changed
  project.save
  puts 'saved project'
else
  puts 'no changes'
end
