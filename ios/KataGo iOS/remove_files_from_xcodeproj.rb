#!/usr/bin/env ruby
# Removes file references — and every build-phase entry that points at them —
# from the Xcode project, by basename. Idempotent: a basename that is not in
# the project is silently skipped, so re-running after a partial failure is
# safe.
#
# Hand-editing project.pbxproj is not an option in this repo; this is the
# deletion counterpart to the add_*.rb scripts alongside it.
#
# Usage: ruby remove_files_from_xcodeproj.rb Foo.swift Bar.swift
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
abort("usage: #{$PROGRAM_NAME} <basename> [<basename>...]") if ARGV.empty?

project = Xcodeproj::Project.open(PROJECT)
removed = []
missing = []

ARGV.each do |name|
  refs = project.files.select { |f| File.basename(f.path.to_s) == name }
  if refs.empty?
    missing << name
  else
    warn "warning: #{refs.size} references match basename #{name}; removing all of them" if refs.size > 1
    refs.each(&:remove_from_project)
    removed << name
  end
end

project.save
puts "Removed: #{removed.join(', ')}" unless removed.empty?
puts "Not present (skipped): #{missing.join(', ')}" unless missing.empty?
