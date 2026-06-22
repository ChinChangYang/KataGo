#!/usr/bin/env ruby
# Adds the "KataGoAnytimeWidget" WidgetKit app-extension target, links the
# bridge-free KataGoGameStore product, and embeds it into both the iOS app
# (KataGo Anytime) and the macOS app (KataGo Anytime Mac). Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
WIDGET  = 'KataGoAnytimeWidget'
TEAM    = '6F82AZ9Z52'
IOS_APP = 'KataGo Anytime'
MAC_APP = 'KataGo Anytime Mac'

project = Xcodeproj::Project.open(PROJECT)
if project.targets.any? { |t| t.name == WIDGET }
  puts "Target '#{WIDGET}' already exists — nothing to do."
  exit 0
end

ios_app = project.targets.find { |t| t.name == IOS_APP } or abort("missing #{IOS_APP}")
mac_app = project.targets.find { |t| t.name == MAC_APP } or abort("missing #{MAC_APP}")

# KataGoGameStore product dependency (from the existing KataGoUICore package ref).
pkg = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
end or abort('missing KataGoUICore package reference')

# 1. Create the app-extension target (declared iOS; SUPPORTED_PLATFORMS widened below).
widget = project.new_target(:app_extension, WIDGET, :ios, '26.0')

widget.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']                       = WIDGET
  s['PRODUCT_BUNDLE_IDENTIFIER']          = 'chinchangyang.KataGo-iOS.tw.widget'
  s['INFOPLIST_FILE']                     = "#{WIDGET}/Info.plist"
  s['GENERATE_INFOPLIST_FILE']            = 'NO'
  s['CODE_SIGN_ENTITLEMENTS']             = "#{WIDGET}/#{WIDGET}.entitlements"
  s['CODE_SIGN_STYLE']                    = 'Automatic'
  s['DEVELOPMENT_TEAM']                   = TEAM
  s['SUPPORTED_PLATFORMS']                = 'iphoneos iphonesimulator macosx xros xrsimulator'
  s['SUPPORTS_MACCATALYST']               = 'NO'
  s['IPHONEOS_DEPLOYMENT_TARGET']         = '26.0'
  s['MACOSX_DEPLOYMENT_TARGET']           = '26.0'
  s['XROS_DEPLOYMENT_TARGET']             = '26.0'
  s['SWIFT_VERSION']                      = '6.0'
  s['SKIP_INSTALL']                       = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']            = ['$(inherited)', '@executable_path/Frameworks',
                                             '@executable_path/../../Frameworks']
  s['SWIFT_EMIT_LOC_STRINGS']             = 'YES'
end

# 2. Link the bridge-free product.
dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = 'KataGoGameStore'
widget.package_product_dependencies << dep
bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.product_ref = dep
widget.frameworks_build_phase.files << bf

# 3. Register the widget source files + Info.plist/entitlements in a group.
group = project.main_group.find_subpath(WIDGET, true)
group.set_source_tree('SOURCE_ROOT')
%w[
  KataGoAnytimeWidgetBundle.swift SavedGameWidget.swift SelectGameIntent.swift
  SavedGameProvider.swift SavedGameWidgetView.swift
].each do |f|
  ref = group.new_reference("#{WIDGET}/#{f}")
  widget.source_build_phase.add_file_reference(ref)
end
group.new_reference("#{WIDGET}/Info.plist")
group.new_reference("#{WIDGET}/#{WIDGET}.entitlements")

# 4. Embed into BOTH apps' PlugIns + add a build dependency.
[ios_app, mac_app].each do |app|
  app.add_dependency(widget)
  phase = app.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
  unless phase
    phase = app.new_copy_files_build_phase('Embed Foundation Extensions')
    phase.symbol_dst_subfolder_spec = :plug_ins   # PlugIns/
    phase.dst_path = ''
  end
  ebf = phase.add_file_reference(widget.product_reference)
  ebf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

project.save
puts "Added #{WIDGET}, linked KataGoGameStore, embedded into #{IOS_APP} and #{MAC_APP}."
