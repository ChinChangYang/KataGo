#!/usr/bin/env ruby
# Registers the shared Icon Composer `AppIcon.icon` (already used by the iOS
# app target) as a resource of the "KataGo Anytime Watch" target, so the
# watch app ships an icon. The watch target already sets
# ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
WATCH   = 'KataGo Anytime Watch'

project = Xcodeproj::Project.open(PROJECT)
watch = project.targets.find { |t| t.name == WATCH } or abort("missing #{WATCH}")

# The watch target has no asset catalog, so actool warns about the default
# AccentColor lookup. Empty it out (same as the tvOS targets). Idempotent.
watch.build_configurations.each do |c|
  c.build_settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = ''
end

# Reuse the existing AppIcon.icon file reference the iOS app already owns.
icon_ref = project.files.find { |f| f.path == 'AppIcon.icon' } \
  or abort('missing AppIcon.icon file reference')

res = watch.resources_build_phase
unless res.files_references.include?(icon_ref)
  res.add_file_reference(icon_ref)
end

project.save
puts "Registered AppIcon.icon + emptied AccentColor lookup on #{WATCH}."
