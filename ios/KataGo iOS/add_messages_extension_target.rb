#!/usr/bin/env ruby
# Adds the "KataGoAnytimeMessages" iMessage app-extension target
# (com.apple.message-payload-provider), links the bridge-free
# KataGoGameStore + GoRulesKit products, and embeds it into the iOS app
# (KataGo Anytime). iOS-only — Messages extensions do not exist on the
# other platforms. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
EXT     = 'KataGoAnytimeMessages'
TEAM    = '6F82AZ9Z52'
IOS_APP = 'KataGo Anytime'

project = Xcodeproj::Project.open(PROJECT)
if project.targets.any? { |t| t.name == EXT }
  puts "Target '#{EXT}' already exists — nothing to do."
  exit 0
end

ios_app = project.targets.find { |t| t.name == IOS_APP } or abort("missing #{IOS_APP}")

pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

# 1. Create the app-extension target (iOS only).
ext = project.new_target(:app_extension, EXT, :ios, '26.0')

ext.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']                        = EXT
  s['PRODUCT_BUNDLE_IDENTIFIER']           = 'chinchangyang.KataGo-iOS.tw.messages'
  s['INFOPLIST_FILE']                      = "#{EXT}/Info.plist"
  s['GENERATE_INFOPLIST_FILE']             = 'NO'
  s['CODE_SIGN_ENTITLEMENTS']              = "#{EXT}/#{EXT}.entitlements"
  s['CODE_SIGN_STYLE']                     = 'Automatic'
  s['DEVELOPMENT_TEAM']                    = TEAM
  s['SUPPORTED_PLATFORMS']                 = 'iphoneos iphonesimulator'
  s['SUPPORTS_MACCATALYST']                = 'NO'
  s['IPHONEOS_DEPLOYMENT_TARGET']          = '26.0'
  s['SWIFT_VERSION']                       = '6.0'
  s['SKIP_INSTALL']                        = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']             = ['$(inherited)', '@executable_path/Frameworks',
                                              '@executable_path/../../Frameworks']
  s['SWIFT_EMIT_LOC_STRINGS']              = 'YES'
  s['MARKETING_VERSION']                   = '7.0'
  s['CURRENT_PROJECT_VERSION']             = '307'
  s['ASSETCATALOG_COMPILER_APPICON_NAME']  = 'iMessage App Icon'
  s['TARGETED_DEVICE_FAMILY']              = '1,2'
end

# 2. Link the bridge-free products (never KataGoUICore/GobanRecogKit —
#    they drag in the C++ engine / OpenCV).
%w[KataGoGameStore GoRulesKit].each do |product|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = product
  ext.package_product_dependencies << dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  ext.frameworks_build_phase.files << bf
end

# 3. Register sources + Info.plist/entitlements/assets in a group.
group = project.main_group.find_subpath(EXT, true)
group.set_source_tree('SOURCE_ROOT')
%w[
  MessagesViewController.swift MessagesRootView.swift SetupCardView.swift
  GameScreenView.swift BubbleRenderer.swift AppHandoff.swift
].each do |f|
  ref = group.new_reference("#{EXT}/#{f}")
  ext.source_build_phase.add_file_reference(ref)
end
group.new_reference("#{EXT}/Info.plist")
group.new_reference("#{EXT}/#{EXT}.entitlements")
assets = group.new_reference("#{EXT}/Assets.xcassets")
ext.resources_build_phase.add_file_reference(assets)

# 4. Embed into the iOS app's PlugIns + add a build dependency.
ios_app.add_dependency(ext)
phase = ios_app.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
unless phase
  phase = ios_app.new_copy_files_build_phase('Embed Foundation Extensions')
  phase.symbol_dst_subfolder_spec = :plug_ins
  phase.dst_path = ''
end
ebf = phase.add_file_reference(ext.product_reference)
ebf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "Added #{EXT}, linked KataGoGameStore + GoRulesKit, embedded into #{IOS_APP}."
