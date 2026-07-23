#!/usr/bin/env ruby
# Registers later-added KataGoAnytimeSafariExt source files and the
# KataGoAnalysisKit package product with the existing appex target
# (add_safari_extension_target.rb created it with the T1 file set). Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
EXT = 'KataGoAnytimeSafariExt'
NEW_SOURCES = %w[ExtensionEngineController.swift AnalysisJobRunner.swift]

project = Xcodeproj::Project.open(PROJECT)
ext = project.targets.find { |t| t.name == EXT } or abort("missing #{EXT}")
group = project.main_group.find_subpath(EXT, false) or abort("missing #{EXT} group")

NEW_SOURCES.each do |f|
  next if ext.source_build_phase.files.any? { |bf| bf.file_ref&.path&.end_with?(f) }
  ref = group.new_reference("#{EXT}/#{f}")
  ext.source_build_phase.add_file_reference(ref)
  puts "added #{f}"
end

unless ext.package_product_dependencies.any? { |d| d.product_name == 'KataGoAnalysisKit' }
  pkg = project.root_object.package_references.find do |r|
    r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
  end or abort('missing KataGoUICore package reference')
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = 'KataGoAnalysisKit'
  ext.package_product_dependencies << dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  ext.frameworks_build_phase.files << bf
  puts 'linked KataGoAnalysisKit'
end

project.save
puts 'done.'
