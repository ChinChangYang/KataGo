#!/usr/bin/env ruby
# Adds the "KataGo Anytime Watch" watchOS app target (modern single-target
# watch app), links the bridge-free KataGoGameStore product, embeds it into
# the iOS app's Watch directory, and writes a shared scheme. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
WATCH   = 'KataGo Anytime Watch'
TEAM    = '6F82AZ9Z52'
IOS_APP = 'KataGo Anytime'

project = Xcodeproj::Project.open(PROJECT)
if project.targets.any? { |t| t.name == WATCH }
  puts "Target '#{WATCH}' already exists — nothing to do."
  exit 0
end

ios_app = project.targets.find { |t| t.name == IOS_APP } or abort("missing #{IOS_APP}")
pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

# 1. Watch app target. new_target(:application, …, :watchos) sets SDKROOT and
#    the plain com.apple.product-type.application; WKApplication=YES in the
#    generated Info.plist is what makes it a single-target watch app.
watch = project.new_target(:application, WATCH, :watchos, '26.0')

watch.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']                                   = WATCH
  s['PRODUCT_BUNDLE_IDENTIFIER']                      = 'chinchangyang.KataGo-iOS.tw.watchkitapp'
  s['GENERATE_INFOPLIST_FILE']                        = 'YES'
  s['INFOPLIST_KEY_WKApplication']                    = 'YES'
  s['INFOPLIST_KEY_WKCompanionAppBundleIdentifier']   = 'chinchangyang.KataGo-iOS.tw'
  s['INFOPLIST_KEY_CFBundleDisplayName']              = 'KataGo Anytime'
  s['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait'
  s['CODE_SIGN_ENTITLEMENTS']                         = "#{WATCH}/#{WATCH}.entitlements"
  s['CODE_SIGN_STYLE']                                = 'Automatic'
  s['DEVELOPMENT_TEAM']                               = TEAM
  s['SDKROOT']                                        = 'watchos'
  s['TARGETED_DEVICE_FAMILY']                         = '4'
  s['WATCHOS_DEPLOYMENT_TARGET']                      = '26.0'
  s['SWIFT_VERSION']                                  = '6.0'
  s['SKIP_INSTALL']                                   = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']                        = ['$(inherited)', '@executable_path/Frameworks']
  s['MARKETING_VERSION']                              = '7.0'
  s['CURRENT_PROJECT_VERSION']                        = '293'
end

# 2. Link KataGoGameStore (bridge-free — the watch must NEVER link KataGoUICore).
dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = 'KataGoGameStore'
watch.package_product_dependencies << dep
bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
watch.frameworks_build_phase.files << bf

# 3. Register sources + entitlements.
group = project.main_group.find_subpath(WATCH, true)
group.set_source_tree('SOURCE_ROOT')
%w[
  KataGoAnytimeWatchApp.swift WatchLiveModel.swift WatchRootView.swift
  WatchBoardPage.swift WatchMovesPage.swift
].each do |f|
  ref = group.new_reference("#{WATCH}/#{f}")
  watch.source_build_phase.add_file_reference(ref)
end
group.new_reference("#{WATCH}/#{WATCH}.entitlements")

# 4. Embed into the iOS app: modern watch apps copy into
#    $(CONTENTS_FOLDER_PATH)/Watch via a products-directory copy phase.
#    The shared "KataGo Anytime" scheme also builds visionOS, which rejects a
#    watchOS binary embedded in a visionOS app. So constrain BOTH the target
#    dependency and the embed copy to iOS via a platform filter (exactly what
#    Xcode writes when you add a watch app). The xcodeproj gem exposes
#    platform_filters on PBXTargetDependency / PBXBuildFile, not on the copy
#    phase object, so set it there.
ios_app.add_dependency(watch)
ios_app.dependencies.each do |d|
  d.platform_filters = ['ios'] if d.respond_to?(:target) && d.target == watch
end
phase = ios_app.copy_files_build_phases.find { |p| p.name == 'Embed Watch Content' }
unless phase
  phase = ios_app.new_copy_files_build_phase('Embed Watch Content')
  phase.symbol_dst_subfolder_spec = :products_directory
  phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
end
ebf = phase.add_file_reference(watch.product_reference)
ebf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
ebf.platform_filters = ['ios']

# 5. Shared scheme so xcodebuild -scheme works headlessly.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(watch)
scheme.set_launch_target(watch)
scheme.save_as(PROJECT, WATCH, true)

project.save
puts "Added #{WATCH}, linked KataGoGameStore, embedded into #{IOS_APP}, shared scheme written."
