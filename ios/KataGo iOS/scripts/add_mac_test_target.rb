#!/usr/bin/env ruby
# Adds the non-hosted macOS unit-test bundle "KataGo Anytime MacTests".
#
# Non-hosted on purpose: a TEST_HOST bundle launches the Mac app for every
# run, which boots SharedModelContainer/CloudKit, spawns the katago-engine
# subprocess, and touches the app-group preferences path. Those are the three
# flakiest things on this platform and none of them is under test here.
#
# Idempotent: re-running is a no-op once the target exists.

require 'xcodeproj'

PROJECT = 'KataGo Anytime.xcodeproj'
TEST_TARGET = 'KataGo Anytime MacTests'
APP_TARGET = 'KataGo Anytime Mac'
PRODUCTS = %w[KataGoGameStore KataGoAnalysisKit]

project = Xcodeproj::Project.open(PROJECT)

if project.targets.any? { |t| t.name == TEST_TARGET }
  puts "#{TEST_TARGET} already exists - nothing to do"
  exit 0
end

app = project.targets.find { |t| t.name == APP_TARGET }
raise "missing target #{APP_TARGET}" if app.nil?

app_bundle_id = app.build_configurations.first.build_settings['PRODUCT_BUNDLE_IDENTIFIER']
raise 'app target has no PRODUCT_BUNDLE_IDENTIFIER' if app_bundle_id.nil?

test = project.new_target(:unit_test_bundle, TEST_TARGET, :osx, '26.0',
                          project.products_group, :swift)

test.build_configurations.each do |c|
  s = c.build_settings
  # xcodeproj's :unit_test_bundle common settings never set PRODUCT_NAME
  # (only :framework does), so without this the Swift module name comes out
  # empty and the build fails with 'Module name "" is not a valid identifier'.
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{app_bundle_id}Tests"
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SWIFT_VERSION'] = '6.0'
  s['MACOSX_DEPLOYMENT_TARGET'] = '26.0'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
  # Non-hosted: these two must stay absent.
  s.delete('TEST_HOST')
  s.delete('BUNDLE_LOADER')
end

# The local package reference the app already uses; the test bundle borrows it
# to link the two bridge-free products directly.
pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end
raise 'local KataGoUICore package reference not found' if pkg.nil?

PRODUCTS.each do |name|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = name
  dep.package = pkg
  test.package_product_dependencies << dep

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  test.frameworks_build_phase.files << build_file
end

# KataGoAnalysisKit reaches the app only transitively today. The draft sources
# import it and are compiled into BOTH targets, so make the app's dependency
# explicit rather than relying on transitive module visibility.
unless app.package_product_dependencies.any? { |d| d.product_name == 'KataGoAnalysisKit' }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = 'KataGoAnalysisKit'
  dep.package = pkg
  app.package_product_dependencies << dep
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  app.frameworks_build_phase.files << build_file
end

group = project.main_group.find_subpath(TEST_TARGET, true)
group.set_source_tree('SOURCE_ROOT')
group.set_path(TEST_TARGET)

Dir.glob("#{TEST_TARGET}/**/*.swift").sort.each do |file|
  ref = group.new_reference(File.basename(file))
  test.add_file_references([ref])
end

project.save

# Join the shared Mac scheme's Test action, so
# `xcodebuild test -scheme "KataGo Anytime Mac"` picks the bundle up.
scheme_path = Xcodeproj::XCScheme.shared_data_dir(PROJECT).join('KataGo Anytime Mac.xcscheme')
scheme = Xcodeproj::XCScheme.new(scheme_path.to_s)
already = scheme.test_action.testables.any? do |t|
  t.buildable_references.any? { |r| r.target_name == TEST_TARGET }
end
unless already
  scheme.test_action.add_testable(
    Xcodeproj::XCScheme::TestAction::TestableReference.new(test))
  scheme.save_as(PROJECT, 'KataGo Anytime Mac', true)
end

puts "added #{TEST_TARGET} linking #{PRODUCTS.join(', ')}"
