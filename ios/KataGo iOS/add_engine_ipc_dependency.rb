#!/usr/bin/env ruby
# Wires the KataGoEngineIPC local SwiftPM package into the Mac app target and
# registers SubprocessKataGoEngine.swift in its Sources phase. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
APP = 'KataGo Anytime Mac'
project = Xcodeproj::Project.open(PROJECT)
app = project.targets.find { |t| t.name == APP } or abort("missing #{APP}")

# 1. Local package reference.
pkg = project.root_object.package_references.find do |r|
  r.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) && r.relative_path == 'KataGoEngineIPC'
end
unless pkg
  pkg = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  pkg.relative_path = 'KataGoEngineIPC'
  project.root_object.package_references << pkg
  puts 'added XCLocalSwiftPackageReference KataGoEngineIPC'
end

# 2. Product dependency + link into the Mac app's Frameworks phase.
dep = app.package_product_dependencies.find { |d| d.product_name == 'KataGoEngineIPC' }
unless dep
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = 'KataGoEngineIPC'
  app.package_product_dependencies << dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  app.frameworks_build_phase.files << bf
  puts 'linked KataGoEngineIPC product into Mac app'
end

# 3. Register SubprocessKataGoEngine.swift in the same group as MainWindowController.swift.
already = app.source_build_phase.files.any? do |bf|
  bf.file_ref&.path&.end_with?('SubprocessKataGoEngine.swift')
end
unless already
  mwc = project.files.find { |f| f.path&.end_with?('MainWindowController.swift') } or abort('cannot locate MainWindowController.swift')
  group = mwc.parent
  ref = group.new_reference('SubprocessKataGoEngine.swift')
  app.source_build_phase.add_file_reference(ref)
  puts "added SubprocessKataGoEngine.swift to #{APP} sources (group: #{group.display_name})"
end

project.save
puts 'done.'
