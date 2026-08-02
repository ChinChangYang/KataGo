#!/usr/bin/env ruby
# Links the bridge-free GoRulesKit product into the "KataGo Anytime Watch"
# target (SGF replay for the standalone library browser). The watch must NEVER
# link KataGoUICore. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
WATCH   = 'KataGo Anytime Watch'
PRODUCT = 'GoRulesKit'

project = Xcodeproj::Project.open(PROJECT)
watch = project.targets.find { |t| t.name == WATCH } or abort("missing #{WATCH}")

pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

if watch.package_product_dependencies.any? { |d| d.product_name == PRODUCT }
  puts "#{PRODUCT} already linked into #{WATCH} — nothing to do."
  exit 0
end

dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = PRODUCT
watch.package_product_dependencies << dep

bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
watch.frameworks_build_phase.files << bf

project.save
puts "Linked #{PRODUCT} into #{WATCH}."
