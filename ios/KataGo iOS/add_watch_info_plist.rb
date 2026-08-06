#!/usr/bin/env ruby
# Switches the "KataGo Anytime Watch" target from a generated Info.plist to a
# real one, so it can declare CFBundleURLTypes (an array of dictionaries, which
# has no INFOPLIST_KEY_ equivalent) for the katago-anytime scheme the
# complication's widgetURL uses.
#
# Both configurations, and the four generated keys are carried into the plist
# itself — dropping WKApplication or WKCompanionAppBundleIdentifier silently
# breaks pairing. Idempotent.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
TARGET  = 'KataGo Anytime Watch'
PLIST   = 'KataGo Anytime Watch/Info.plist'
GENERATED_KEYS = %w[
  INFOPLIST_KEY_CFBundleDisplayName
  INFOPLIST_KEY_UISupportedInterfaceOrientations
  INFOPLIST_KEY_WKApplication
  INFOPLIST_KEY_WKCompanionAppBundleIdentifier
].freeze

abort("missing #{PLIST} — write it before running this") \
  unless File.exist?(File.join(__dir__, PLIST))

project = Xcodeproj::Project.open(PROJECT)
target = project.targets.find { |t| t.name == TARGET } or abort("missing #{TARGET}")

target.build_configurations.each do |config|
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['INFOPLIST_FILE'] = PLIST
  GENERATED_KEYS.each { |key| config.build_settings.delete(key) }
end

project.save
puts "#{TARGET} now uses #{PLIST} in #{target.build_configurations.map(&:name).join(' and ')}."
