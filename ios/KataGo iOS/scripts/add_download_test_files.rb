#!/usr/bin/env ruby
# Adds the download-feature test files to the "KataGo AnytimeTests" target.
# The project has no filesystem-synchronized groups (objectVersion = 60), so a
# new .swift file in an app or test folder is invisible until it has a
# PBXFileReference, a PBXGroup child entry and a PBXBuildFile. Idempotent.
#
#   gem install xcodeproj      # once
#   ruby scripts/add_download_test_files.rb
require 'xcodeproj'

PROJECT = File.expand_path('../KataGo Anytime.xcodeproj', __dir__)
TARGET  = 'KataGo AnytimeTests'
GROUP   = 'KataGo iOSTests'
FILES   = %w[
  DownloadDecisionTests.swift
]

project = Xcodeproj::Project.open(PROJECT)
target  = project.targets.find { |t| t.name == TARGET }
raise "target #{TARGET.inspect} not found" unless target

group = project.main_group[GROUP] ||
        project.groups.find { |g| g.path == GROUP } ||
        project.main_group.recursive_children.find { |g| g.respond_to?(:path) && g.path == GROUP }
raise "group #{GROUP.inspect} not found" unless group

FILES.each do |name|
  if group.files.any? { |f| f.display_name == name }
    puts "skip  #{name} (already referenced)"
    next
  end
  ref = group.new_reference(name)
  target.add_file_references([ref])
  puts "add   #{name}"
end

project.save
puts "saved #{PROJECT}"
