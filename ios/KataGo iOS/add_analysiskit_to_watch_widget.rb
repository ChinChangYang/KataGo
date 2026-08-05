#!/usr/bin/env ruby
# Links the Foundation-only KataGoAnalysisKit product into the
# "KataGoAnytimeWatchWidget" target (the last-game complication).
#
# The complication must NEVER link KataGoGameStore, KataGoUICore, or
# GoRulesKit: it is a wrist-sized appex with a hard memory ceiling, and
# KataGoGameStore alone would drag in SwiftData, CoreData, AppIntents and an
# image asset catalog. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
TARGET  = 'KataGoAnytimeWatchWidget'
PRODUCT = 'KataGoAnalysisKit'

project = Xcodeproj::Project.open(PROJECT)
target = project.targets.find { |t| t.name == TARGET } or abort("missing #{TARGET}")

pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

if target.package_product_dependencies.any? { |d| d.product_name == PRODUCT }
  puts "#{PRODUCT} already linked into #{TARGET} — nothing to do."
  exit 0
end

dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = PRODUCT
target.package_product_dependencies << dep

bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
target.frameworks_build_phase.files << bf

project.save
puts "Linked #{PRODUCT} into #{TARGET}."
