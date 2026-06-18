#!/usr/bin/env ruby
# Adds the "KataGo Engine Helper" command-line-tool target (product:
# katago-engine) to the project, links it against katago.framework, and embeds
# it into the macOS app's Contents/MacOS so the app can spawn it as a
# subprocess. Idempotent: re-running detects the existing target and exits.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
HELPER_NAME = 'KataGo Engine Helper'
PRODUCT_NAME = 'katago-engine'
APP_TARGET = 'KataGo Anytime Mac'
TEAM = '6F82AZ9Z52'

project = Xcodeproj::Project.open(PROJECT)

if project.targets.any? { |t| t.name == HELPER_NAME }
  puts "Target '#{HELPER_NAME}' already exists — nothing to do."
  exit 0
end

app    = project.targets.find { |t| t.name == APP_TARGET }    or abort("missing app target #{APP_TARGET}")
katago = project.targets.find { |t| t.name == 'katago' }      or abort('missing katago framework target')
raise 'app target is not the macOS app' unless app.product_type == 'com.apple.product-type.application'

# 1. Create the command-line tool target (macOS).
helper = project.new_target(:command_line_tool, HELPER_NAME, :osx, '26.0')

# 2. Build settings (applied to every configuration).
helper.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME']                = PRODUCT_NAME
  s['PRODUCT_BUNDLE_IDENTIFIER']   = 'chinchangyang.KataGo-iOS.tw.mac.engine'
  s['SDKROOT']                     = 'macosx'
  s['SUPPORTED_PLATFORMS']         = 'macosx'
  s['MACOSX_DEPLOYMENT_TARGET']    = '26.0'
  s['ARCHS']                       = '$(ARCHS_STANDARD)'
  s['CODE_SIGN_STYLE']             = 'Automatic'
  s['DEVELOPMENT_TEAM']            = TEAM
  s['ENABLE_HARDENED_RUNTIME']     = 'YES'
  s['CLANG_CXX_LANGUAGE_STANDARD'] = 'gnu++20'
  s['CLANG_CXX_LIBRARY']           = 'libc++'
  s['FRAMEWORK_SEARCH_PATHS']      = ['$(inherited)', '$(BUILT_PRODUCTS_DIR)']
  # @executable_path: run straight from the build dir (frameworks colocated).
  # @executable_path/../Frameworks: when embedded in App.app/Contents/MacOS,
  # the app's embedded frameworks live in Contents/Frameworks.
  s['LD_RUNPATH_SEARCH_PATHS']     = ['$(inherited)', '@executable_path',
                                      '@executable_path/../Frameworks',
                                      '@loader_path/../Frameworks']
  s['SKIP_INSTALL']                = 'YES'
end

# 3. Source: main.cpp (forward-declares MainCmds::gtp; links against katago).
group = project.main_group.find_subpath('KataGoEngineHelper', true)
main_ref = group.new_reference('KataGoEngineHelper/main.cpp')
helper.source_build_phase.add_file_reference(main_ref)

# 4. Link katago.framework (which pulls KataGoSwift.framework via @rpath at
#    load time, exactly like the verified spike) and build it first.
helper.frameworks_build_phase.add_file_reference(katago.product_reference)
helper.add_dependency(katago)

# 5. Embed the helper into the app's Contents/MacOS and make the app build it
#    first. Do NOT set CodeSignOnCopy: the helper self-signs (in its own target)
#    with app-sandbox + inherit entitlements, and Xcode's CodeSignOnCopy re-sign
#    would STRIP those during embed. Leaving ATTRIBUTES empty lets the helper's
#    own signature survive the app's final seal (verified: codesign -d on the
#    embedded helper shows app-sandbox + inherit; app passes --verify --deep).
app.add_dependency(helper)
embed = app.new_copy_files_build_phase('Embed Engine Helper')
embed.symbol_dst_subfolder_spec = :executables   # Contents/MacOS
embed.dst_path = ''
bf = embed.add_file_reference(helper.product_reference)
bf.settings = { 'ATTRIBUTES' => [] }

project.save
puts "Added target '#{HELPER_NAME}' (product '#{PRODUCT_NAME}'), linked katago, embedded into '#{APP_TARGET}'."
