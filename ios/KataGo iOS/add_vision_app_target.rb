#!/usr/bin/env ruby
# Adds the "KataGo Anytime Vision" visionOS app target (volumetric 3D goban):
# links KataGoUICore, links + embeds the katago/KataGoSwift engine frameworks,
# reuses the shared network/config resources, bundles the BoardAssets folder
# reference, and writes a shared scheme. Idempotent — re-run it after adding
# new Swift files to the "KataGo Anytime Vision" folder.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
VISION  = 'KataGo Anytime Vision'
TEAM    = '6F82AZ9Z52'
IOS_APP = 'KataGo Anytime'

project = Xcodeproj::Project.open(PROJECT)

def real(node)
  node.real_path.to_s
rescue StandardError
  nil
end

vision = project.targets.find { |t| t.name == VISION }
created = vision.nil?

if created
  ios_app = project.targets.find { |t| t.name == IOS_APP } or abort("missing #{IOS_APP}")
  ios_release = ios_app.build_configurations.find { |c| c.name == 'Release' }
  current_project_version = ios_release.build_settings['CURRENT_PROJECT_VERSION'] || '307'

  pkg = project.root_object.package_references.find do |r|
    r.respond_to?(:relative_path) && r.relative_path == 'KataGoUICore'
  end or abort('missing KataGoUICore package reference')

  katago      = project.targets.find { |t| t.name == 'katago' }      or abort('missing katago target')
  katago_swift = project.targets.find { |t| t.name == 'KataGoSwift' } or abort('missing KataGoSwift target')

  # 1. App target. new_target(:application, …, :visionos) sets SDKROOT=xros,
  #    the product type, and XROS_DEPLOYMENT_TARGET.
  vision = project.new_target(:application, VISION, :visionos, '26.0')

  vision.build_configurations.each do |c|
    s = c.build_settings
    s['PRODUCT_NAME']                              = 'KataGo Vision'
    s['PRODUCT_BUNDLE_IDENTIFIER']                 = 'chinchangyang.KataGo-iOS.tw' # universal purchase
    s['SUPPORTED_PLATFORMS']                       = 'xros xrsimulator'
    s['TARGETED_DEVICE_FAMILY']                    = '7'
    s['XROS_DEPLOYMENT_TARGET']                    = '26.0'
    s['SDKROOT']                                   = 'xros'
    s['GENERATE_INFOPLIST_FILE']                   = 'YES'
    s['INFOPLIST_FILE']                            = "#{VISION}/Info.plist"
    s['INFOPLIST_KEY_CFBundleDisplayName']         = 'KataGo Anytime'
    s['INFOPLIST_KEY_ITSAppUsesNonExemptEncryption'] = 'NO'
    s['ASSETCATALOG_COMPILER_APPICON_NAME']        = 'AppIcon'
    s['CODE_SIGN_ENTITLEMENTS']                    = "#{VISION}/KataGo Vision.entitlements"
    s['CODE_SIGN_STYLE']                           = 'Automatic'
    s['DEVELOPMENT_TEAM']                          = TEAM
    s['SWIFT_VERSION']                             = '6.0'
    # KataGoUICore's public interface carries C++ types (CKataGoBridge).
    s['SWIFT_OBJC_INTEROP_MODE']                   = 'objcxx'
    s['OTHER_LDFLAGS']                             = ['$(inherited)', '-lz'] # zlib for the engine
    s['LD_RUNPATH_SEARCH_PATHS']                   = ['$(inherited)', '@executable_path/Frameworks']
    s['ENABLE_PREVIEWS']                           = 'YES'
    s['MARKETING_VERSION']                         = '7.0'
    s['CURRENT_PROJECT_VERSION']                   = current_project_version
    if c.name == 'Release'
      s['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
      s['VALIDATE_PRODUCT']         = 'YES'
    end
  end

  # 2. Link the KataGoUICore package product (NOT GobanRecogKit — no camera
  #    import on Vision; it would drag OpenCV in).
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = 'KataGoUICore'
  vision.package_product_dependencies << dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  vision.frameworks_build_phase.files << bf

  # 3. Link + embed the engine frameworks. CKataGoBridge in KataGoUICore is a
  #    static target whose engine symbols resolve against these at app link
  #    (same shape as the iOS/TV targets).
  [katago, katago_swift].each do |ft|
    vision.add_dependency(ft)
    vision.frameworks_build_phase.add_file_reference(ft.product_reference)
  end
  embed = vision.new_copy_files_build_phase('Embed Frameworks')
  embed.symbol_dst_subfolder_spec = :frameworks
  [katago, katago_swift].each do |ft|
    ebf = embed.add_file_reference(ft.product_reference)
    ebf.settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }
  end

  # 4. Shared scheme so xcodebuild -scheme works headlessly.
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(vision)
  scheme.set_launch_target(vision)
  scheme.save_as(PROJECT, VISION, true)
end

group = project.main_group.find_subpath(VISION, true)
group.set_source_tree('SOURCE_ROOT')

changed = created

# 5. Sources: every .swift directly in the target folder (idempotent by real
#    path), plus the shared CoreMLComputeHandleLoader.swift from the iOS
#    folder (reuse the existing file reference — do not duplicate the file).
existing_sources = vision.source_build_phase.files.map { |f| real(f.file_ref) }.compact
Dir[File.join(__dir__, VISION, '*.swift')].sort.each do |abs|
  next if existing_sources.include?(File.realpath(abs))
  ref = group.new_reference("#{VISION}/#{File.basename(abs)}")
  vision.source_build_phase.add_file_reference(ref)
  changed = true
  puts "added source: #{File.basename(abs)}"
end

coreml_loader = project.files.find { |f| (f.path || '').end_with?('CoreMLComputeHandleLoader.swift') }
abort('missing shared CoreMLComputeHandleLoader.swift reference') unless coreml_loader
unless existing_sources.include?(real(coreml_loader))
  vision.source_build_phase.add_file_reference(coreml_loader)
  changed = true
  puts 'added shared source: CoreMLComputeHandleLoader.swift'
end

# 6. Resources: shared engine nets/config (existing refs) + the Vision asset
#    catalog + the BoardAssets folder reference (preserved subdirectory).
existing_resources = vision.resources_build_phase.files.map { |f| real(f.file_ref) }.compact

%w[default_gtp.cfg default_model.bin.gz b18c384nbt-humanv0.bin.gz].each do |name|
  ref = project.files.find { |f| (f.path || '').end_with?(name) }
  abort("missing shared resource reference: #{name}") unless ref
  next if existing_resources.include?(real(ref))
  vision.resources_build_phase.add_file_reference(ref)
  changed = true
  puts "added shared resource: #{name}"
end

assets_path = "#{VISION}/Assets.xcassets"
assets_abs = File.realpath(File.join(__dir__, assets_path))
unless existing_resources.include?(assets_abs)
  ref = group.new_reference(assets_path)
  vision.resources_build_phase.add_file_reference(ref)
  changed = true
  puts 'added resource: Assets.xcassets'
end

board_assets_path = "#{VISION}/Resources/BoardAssets"
board_assets_abs = File.realpath(File.join(__dir__, board_assets_path))
unless existing_resources.include?(board_assets_abs)
  ref = group.new_reference(board_assets_path)
  ref.last_known_file_type = 'folder'
  vision.resources_build_phase.add_file_reference(ref)
  changed = true
  puts 'added resource folder reference: BoardAssets'
end

# 7. Non-compiled files visible in the Xcode navigator.
existing_group_paths = group.files.map { |f| real(f) }.compact
["#{VISION}/Info.plist", "#{VISION}/KataGo Vision.entitlements"].each do |p|
  abs = File.realpath(File.join(__dir__, p))
  next if existing_group_paths.include?(abs)
  group.new_reference(p)
  changed = true
end

if changed
  project.save
  puts created ? "Added #{VISION}: linked KataGoUICore, embedded katago+KataGoSwift, shared scheme written." : "Updated #{VISION}."
else
  puts "Target '#{VISION}' already up to date — nothing to do."
end
