#!/usr/bin/env ruby
# Adds the "KataGoAnytimeSafariExtIOS" iOS Safari web-extension target
# (com.apple.Safari.web-extension), links the in-process engine, and embeds it
# into the iOS app ("KataGo Anytime"). Idempotent.
#
# Unlike the macOS KataGoAnytimeSafariExt — which spawns the `katago-engine`
# child and therefore links only KataGoEngineIPC — iOS app extensions cannot
# posix_spawn/fork, so this target runs the engine IN-PROCESS. That means
# linking the KataGoUICore product AND the three things the app links directly:
# katago.framework + KataGoSwift.framework + libz.tbd. (The C++ engine symbols
# — Sgf::parse, MainCmds::gtp, katagocoreml_* — live in those frameworks, not
# in the SwiftPM product, so every executable needs them.) The mlx-swift Cmlx
# resource bundle rides along with KataGoUICore automatically.
#
# Web-bundle layout mirrors add_safari_extension_target.rb: top-level FILES in
# Resources/ become individual file references (so manifest.json lands at the
# appex Resources ROOT where Safari expects it); top-level DIRECTORIES become
# folder references preserving their paths.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
EXT     = 'KataGoAnytimeSafariExtIOS'
TEAM    = '6F82AZ9Z52'
IOS_APP = 'KataGo Anytime'
# The tiny b24c64 net lives in the shared Resources/ (the appex bundles its own
# trimmed default_gtp.cfg from EXT/Resources instead of the shared one).
SHARED_RES = ['Resources/lionffen_b24c64_3x3_v3_12300.bin.gz'].freeze

project = Xcodeproj::Project.open(PROJECT)
if project.targets.any? { |t| t.name == EXT }
  puts "Target '#{EXT}' already exists — nothing to do."
  exit 0
end

ios_app = project.targets.find { |t| t.name == IOS_APP } or abort("missing #{IOS_APP}")

ui_pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

# 1. Create the iOS app-extension target.
ext = project.new_target(:app_extension, EXT, :ios, '26.0')
ext.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']               = EXT
  s['PRODUCT_BUNDLE_IDENTIFIER']  = 'chinchangyang.KataGo-iOS.tw.safariweb'
  s['INFOPLIST_FILE']             = "#{EXT}/Info.plist"
  s['GENERATE_INFOPLIST_FILE']    = 'NO'
  s['CODE_SIGN_ENTITLEMENTS']     = "#{EXT}/#{EXT}.entitlements"
  s['CODE_SIGN_STYLE']            = 'Automatic'
  s['DEVELOPMENT_TEAM']           = TEAM
  s['SUPPORTED_PLATFORMS']        = 'iphoneos iphonesimulator'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  s['TARGETED_DEVICE_FAMILY']     = '1,2'
  s['SWIFT_VERSION']              = '6.0'
  s['SWIFT_OBJC_INTEROP_MODE']    = 'objcxx' # KataGoUICore uses Swift/C++ interop
  s['SKIP_INSTALL']               = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']    = ['$(inherited)', '@executable_path/Frameworks',
                                     '@executable_path/../../Frameworks']
  s['SWIFT_EMIT_LOC_STRINGS']     = 'YES'
  # Must track the app (App Store validation compares appex vs app versions).
  s['MARKETING_VERSION']          = '7.0'
  s['CURRENT_PROJECT_VERSION']    = '320'
end

# 2. Link the engine-bearing products.
[[ui_pkg, 'KataGoUICore'], [ui_pkg, 'KataGoAnalysisKit'], [ui_pkg, 'KataGoGameStore']].each do |pkg, product|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = product
  ext.package_product_dependencies << dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  ext.frameworks_build_phase.files << bf
end

# 2b. The C++ engine frameworks the app links directly (NOT in the SwiftPM
#     product). Reuse the app's existing file references.
['katago.framework', 'KataGoSwift.framework', 'libz.tbd'].each do |name|
  src = ios_app.frameworks_build_phase.files.find { |f| (f.display_name rescue nil) == name }
  abort("could not find #{name} in #{IOS_APP}'s frameworks phase") unless src
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.file_ref = src.file_ref
  ext.frameworks_build_phase.files << bf
end

# 3. Sources + Info.plist/entitlements + the web bundle.
group = project.main_group.find_subpath(EXT, true)
group.set_source_tree('SOURCE_ROOT')
%w[SafariWebExtensionHandler.swift IOSEngineController.swift IOSAnalysisService.swift].each do |f|
  ext.source_build_phase.add_file_reference(group.new_reference("#{EXT}/#{f}"))
end
group.new_reference("#{EXT}/Info.plist")
group.new_reference("#{EXT}/#{EXT}.entitlements")

res_dir = File.join(__dir__, EXT, 'Resources')
Dir.children(res_dir).sort.each do |entry|
  next if entry == '.DS_Store'
  ext.resources_build_phase.add_file_reference(group.new_reference("#{EXT}/Resources/#{entry}"))
end

# 3b. The shared net.
SHARED_RES.each do |rel|
  ext.resources_build_phase.add_file_reference(group.new_reference(rel))
end

# 4. Embed into the iOS app's PlugIns + build dependency.
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
puts "Added #{EXT}, linked the in-process engine, embedded into #{IOS_APP}."
