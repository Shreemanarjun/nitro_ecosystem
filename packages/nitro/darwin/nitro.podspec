#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'nitro'
  s.version          = '0.3.3'
  s.summary          = 'High-performance Native Modules for Flutter.'
  s.description      = <<-DESC
Runtime support for .native.dart spec generated bridges.
                       DESC
  s.homepage         = 'https://nitro.shreeman.dev'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Shreemanarjun' => 'Shreemanarjunsahu@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.14'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/../src/native"'
  }
  s.swift_version = '5.0'
end
