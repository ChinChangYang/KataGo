#!/usr/bin/env ruby
# Embeds the KataGoAnytimeWidget appex into the visionOS app (PlugIns/), the
# same shape as the iOS/Mac "Embed Foundation Extensions" phases. Idempotent:
# re-running never duplicates the dependency or the copy-files entry.
require 'xcodeproj'

PROJECT = File.join(__dir__, 'KataGo Anytime.xcodeproj')
project = Xcodeproj::Project.open(PROJECT)

vision = project.targets.find { |t| t.name == 'KataGo Anytime Vision' } or abort('missing Vision target')
widget = project.targets.find { |t| t.name == 'KataGoAnytimeWidget' }   or abort('missing widget target')

changed = false

unless vision.dependencies.any? { |d| d.target && d.target.uuid == widget.uuid }
  vision.add_dependency(widget)
  changed = true
  puts 'added target dependency: KataGo Anytime Vision -> KataGoAnytimeWidget'
end

phase = vision.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
unless phase
  phase = vision.new_copy_files_build_phase('Embed Foundation Extensions')
  phase.symbol_dst_subfolder_spec = :plug_ins # PlugIns/ — appex layout is iOS-shaped on visionOS
  phase.dst_path = ''
  changed = true
  puts 'created Embed Foundation Extensions phase on KataGo Anytime Vision'
end

unless phase.files.any? { |bf| bf.file_ref && bf.file_ref.uuid == widget.product_reference.uuid }
  build_file = phase.add_file_reference(widget.product_reference)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  changed = true
  puts 'added KataGoAnytimeWidget.appex to the embed phase'
end

if changed
  project.save
  puts 'saved project'
else
  puts 'no changes (already embedded)'
end
