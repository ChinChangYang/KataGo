#!/usr/bin/env ruby
# Removes visionOS from the "KataGo Anytime" iOS target — visionOS is served
# by the dedicated "KataGo Anytime Vision" target instead. Touches ONLY the
# iOS app target: katago/KataGoSwift/KataGoUICore keep visionOS support.
# Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
IOS_APP = 'KataGo Anytime'

project = Xcodeproj::Project.open(PROJECT)
target = project.targets.find { |t| t.name == IOS_APP } or abort("missing #{IOS_APP}")

changed = false
target.build_configurations.each do |c|
  s = c.build_settings
  unless s['SUPPORTED_PLATFORMS'] == 'iphoneos iphonesimulator'
    s['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
    changed = true
  end
  unless s['TARGETED_DEVICE_FAMILY'] == '1,2'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
    changed = true
  end
  if s.key?('XROS_DEPLOYMENT_TARGET')
    s.delete('XROS_DEPLOYMENT_TARGET')
    changed = true
  end
  # Explicit NO (not deleted): the default is YES, which would re-surface a
  # "Designed for iPad" Vision Pro destination — the native "KataGo Anytime
  # Vision" target (same bundle id) serves visionOS now.
  unless s['SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD'] == 'NO'
    s['SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD'] = 'NO'
    changed = true
  end
end

if changed
  project.save
  puts "Stripped visionOS from '#{IOS_APP}' (#{target.build_configurations.map(&:name).join(', ')})."
else
  puts "'#{IOS_APP}' already stripped — nothing to do."
end
