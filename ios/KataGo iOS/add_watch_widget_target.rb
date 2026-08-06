#!/usr/bin/env ruby
# Adds the "KataGoAnytimeWatchWidget" WidgetKit extension (the score-lead
# complication) and embeds it into the watch app's PlugIns. Dependency-free:
# it reads only App Group UserDefaults, so it links NO package products.
# Idempotent.
require 'xcodeproj'

PROJECT   = File.join(__dir__, 'KataGo Anytime.xcodeproj')
WIDGET    = 'KataGoAnytimeWatchWidget'
TEAM      = '6F82AZ9Z52'
WATCH_APP = 'KataGo Anytime Watch'

project = Xcodeproj::Project.open(PROJECT)
if project.targets.any? { |t| t.name == WIDGET }
  puts "Target '#{WIDGET}' already exists — nothing to do."
  exit 0
end

watch_app = project.targets.find { |t| t.name == WATCH_APP } or abort("missing #{WATCH_APP}")

# 1. Extension target on the watchOS platform.
widget = project.new_target(:app_extension, WIDGET, :watchos, '26.0')

widget.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']              = WIDGET
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'chinchangyang.KataGo-iOS.tw.watchkitapp.widget'
  s['INFOPLIST_FILE']            = "#{WIDGET}/Info.plist"
  s['GENERATE_INFOPLIST_FILE']   = 'NO'
  s['CODE_SIGN_ENTITLEMENTS']    = "#{WIDGET}/#{WIDGET}.entitlements"
  s['CODE_SIGN_STYLE']           = 'Automatic'
  s['DEVELOPMENT_TEAM']          = TEAM
  s['SDKROOT']                   = 'watchos'
  s['TARGETED_DEVICE_FAMILY']    = '4'
  s['WATCHOS_DEPLOYMENT_TARGET'] = '26.0'
  s['SWIFT_VERSION']             = '6.0'
  s['SKIP_INSTALL']              = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']   = ['$(inherited)', '@executable_path/Frameworks',
                                    '@executable_path/../../Frameworks']
  s['MARKETING_VERSION']         = '7.0'
  s['CURRENT_PROJECT_VERSION']   = '293'
end

# 2. Register sources + Info.plist/entitlements.
group = project.main_group.find_subpath(WIDGET, true)
group.set_source_tree('SOURCE_ROOT')
%w[KataGoAnytimeWatchWidgetBundle.swift LastGameWidget.swift].each do |f|
  ref = group.new_reference("#{WIDGET}/#{f}")
  widget.source_build_phase.add_file_reference(ref)
end
group.new_reference("#{WIDGET}/Info.plist")
group.new_reference("#{WIDGET}/#{WIDGET}.entitlements")

# 3. Embed into the WATCH app's PlugIns + build dependency.
watch_app.add_dependency(widget)
phase = watch_app.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
unless phase
  phase = watch_app.new_copy_files_build_phase('Embed Foundation Extensions')
  phase.symbol_dst_subfolder_spec = :plug_ins   # PlugIns/
  phase.dst_path = ''
end
ebf = phase.add_file_reference(widget.product_reference)
ebf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "Added #{WIDGET}, embedded into #{WATCH_APP}."
