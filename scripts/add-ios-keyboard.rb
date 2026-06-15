#!/usr/bin/env ruby
# Adds the VoxKeyboard app-extension target to ios/Vox.xcodeproj (run with /usr/bin/ruby).
require 'xcodeproj'

project_path = File.expand_path('../../ios/Vox.xcodeproj', __FILE__)
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'Vox' }
abort('Vox app target not found') unless app_target

if project.targets.any? { |t| t.name == 'VoxKeyboard' }
  puts 'VoxKeyboard target already exists — nothing to do.'
  exit 0
end

ext = project.new_target(:app_extension, 'VoxKeyboard', :ios, '16.4', nil, :swift)

group = project.main_group.find_subpath('VoxKeyboard', true)
group.set_source_tree('SOURCE_ROOT')
swift_ref = group.new_reference('VoxKeyboard/KeyboardViewController.swift')
group.new_reference('VoxKeyboard/Info.plist')
group.new_reference('VoxKeyboard/VoxKeyboard.entitlements')
ext.source_build_phase.add_file_reference(swift_ref)

ext.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'ai.localvoice.app.VoxKeyboard'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = 'VoxKeyboard/Info.plist'
  s['CODE_SIGN_ENTITLEMENTS'] = 'VoxKeyboard/VoxKeyboard.entitlements'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '16.4'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SKIP_INSTALL'] = 'YES'
  s['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'NO'
  s['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  s['SWIFT_OPTIMIZATION_LEVEL'] = config.name == 'Debug' ? '-Onone' : '-O'
end

app_target.add_dependency(ext)

embed = app_target.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
bf = embed.add_file_reference(ext.product_reference)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "Added VoxKeyboard target. Targets now: #{project.targets.map(&:name).join(', ')}"
