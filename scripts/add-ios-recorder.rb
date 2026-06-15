#!/usr/bin/env ruby
# Add ScribeAudioRecorder.swift + .m to the Vox app target's Sources phase.
require 'xcodeproj'

project_path = File.expand_path('../ios/Vox.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'Vox' } or abort 'Vox target not found'
group = project.main_group['Vox'] or abort 'Vox group not found'

%w[ScribeAudioRecorder.swift ScribeAudioRecorder.m].each do |name|
  already = target.source_build_phase.files.any? do |bf|
    bf.file_ref && bf.file_ref.path && File.basename(bf.file_ref.path) == name
  end
  if already
    puts "skip (already in target): #{name}"
    next
  end
  ref = group.files.find { |f| f.path && File.basename(f.path) == name } || group.new_reference("Vox/#{name}")
  target.add_file_references([ref])
  puts "added: #{name}"
end

project.save
puts 'saved Vox.xcodeproj'
