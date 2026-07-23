#!/usr/bin/env ruby
# Adds the "KataGoAnytimeSafariExt" Safari web-extension target
# (com.apple.Safari.web-extension), links KataGoEngineIPC (engine subprocess
# transport) + the bridge-free KataGoGameStore, and embeds it into the Mac app
# (KataGo Anytime Mac). macOS-only. Idempotent.
#
# Web-bundle layout: top-level FILES in KataGoAnytimeSafariExt/Resources/
# (manifest.json, background.js, …) are registered as individual file
# references so they land at the appex's Contents/Resources ROOT (where Safari
# expects manifest.json); top-level DIRECTORIES (content/, images/, _locales/)
# become folder references preserving their relative paths. Adding a NEW
# top-level entry later requires re-registering (see scripts_add_swift_files.rb
# for the pattern) — files inside existing folder references need nothing.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
EXT     = 'KataGoAnytimeSafariExt'
TEAM    = '6F82AZ9Z52'
MAC_APP = 'KataGo Anytime Mac'

project = Xcodeproj::Project.open(PROJECT)
if project.targets.any? { |t| t.name == EXT }
  puts "Target '#{EXT}' already exists — nothing to do."
  exit 0
end

mac_app = project.targets.find { |t| t.name == MAC_APP } or abort("missing #{MAC_APP}")

ui_pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')
ipc_pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoEngineIPC'
end or abort('missing KataGoEngineIPC package reference')

# 1. Create the app-extension target (macOS only).
ext = project.new_target(:app_extension, EXT, :osx, '26.0')

ext.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']               = EXT
  s['PRODUCT_BUNDLE_IDENTIFIER']  = 'chinchangyang.KataGo-iOS.tw.safari'
  s['INFOPLIST_FILE']             = "#{EXT}/Info.plist"
  s['GENERATE_INFOPLIST_FILE']    = 'NO'
  s['CODE_SIGN_ENTITLEMENTS']     = "#{EXT}/#{EXT}.entitlements"
  s['CODE_SIGN_STYLE']            = 'Automatic'
  s['DEVELOPMENT_TEAM']           = TEAM
  s['SUPPORTED_PLATFORMS']        = 'macosx'
  s['MACOSX_DEPLOYMENT_TARGET']   = '26.0'
  s['SWIFT_VERSION']              = '6.0'
  s['SKIP_INSTALL']               = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']    = ['$(inherited)', '@executable_path/../Frameworks']
  s['SWIFT_EMIT_LOC_STRINGS']     = 'YES'
  # Must match the Mac app (App Store validation compares appex vs app versions).
  s['MARKETING_VERSION']          = '7.0'
  s['CURRENT_PROJECT_VERSION']    = '307'
end

# 2. Link package products: the engine subprocess transport + bridge-free
#    game store (never KataGoUICore/GobanRecogKit — they drag the C++ engine).
[[ipc_pkg, 'KataGoEngineIPC'], [ui_pkg, 'KataGoGameStore']].each do |pkg, product|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = product
  ext.package_product_dependencies << dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  ext.frameworks_build_phase.files << bf
end

# 3. Register sources + Info.plist/entitlements + the web bundle.
group = project.main_group.find_subpath(EXT, true)
group.set_source_tree('SOURCE_ROOT')
%w[SafariWebExtensionHandler.swift].each do |f|
  ref = group.new_reference("#{EXT}/#{f}")
  ext.source_build_phase.add_file_reference(ref)
end
group.new_reference("#{EXT}/Info.plist")
group.new_reference("#{EXT}/#{EXT}.entitlements")

res_dir = File.join(__dir__, EXT, 'Resources')
Dir.children(res_dir).sort.each do |entry|
  next if entry == '.DS_Store'
  ref = group.new_reference("#{EXT}/Resources/#{entry}")
  ext.resources_build_phase.add_file_reference(ref)
end

# 4. Embed into the Mac app's PlugIns + add a build dependency.
mac_app.add_dependency(ext)
phase = mac_app.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
unless phase
  phase = mac_app.new_copy_files_build_phase('Embed Foundation Extensions')
  phase.symbol_dst_subfolder_spec = :plug_ins
  phase.dst_path = ''
end
ebf = phase.add_file_reference(ext.product_reference)
ebf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "Added #{EXT}, linked KataGoEngineIPC + KataGoGameStore, embedded into #{MAC_APP}."
