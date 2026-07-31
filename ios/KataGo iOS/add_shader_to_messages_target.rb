#!/usr/bin/env ruby
# Adds the existing "KataGo iOS/Shaders.metal" to the KataGoAnytimeMessages
# target's Sources build phase, so the appex builds its own default.metallib
# and `ShaderLibrary.stone` resolves inside the extension process (an appex's
# Bundle.main is the appex, not the host app).
#
# The SAME file reference is reused — Shaders.metal already belongs to the
# iOS, Mac, TV and Vision app targets, and one source of truth is the point.
# Idempotent: re-running is a no-op.

require 'xcodeproj'

project_path = File.join(__dir__, 'KataGo Anytime.xcodeproj')
project = Xcodeproj::Project.open(project_path)

TARGET_NAME = 'KataGoAnytimeMessages'
SHADER_PATH = 'Shaders.metal'

target = project.targets.find { |t| t.name == TARGET_NAME }
abort "Target #{TARGET_NAME} not found" unless target

shader_ref = project.files.find do |f|
  f.path == SHADER_PATH && f.last_known_file_type == 'sourcecode.metal'
end
abort "Shaders.metal file reference not found" unless shader_ref

already = target.source_build_phase.files.any? { |bf| bf.file_ref == shader_ref }
if already
  puts "Shaders.metal is already in #{TARGET_NAME} — nothing to do."
else
  target.source_build_phase.add_file_reference(shader_ref)
  project.save
  puts "Added Shaders.metal to #{TARGET_NAME}."
end

memberships = project.targets.select do |t|
  t.source_build_phase.files.any? { |bf| bf.file_ref == shader_ref }
end
puts "Shaders.metal target membership: #{memberships.map(&:name).join(', ')}"
