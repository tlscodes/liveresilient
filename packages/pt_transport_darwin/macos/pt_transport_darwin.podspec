#
# Vendors the native transport core for macOS. Same shape as the iOS podspec;
# CocoaPods selects the macos-arm64_x86_64 slice from the xcframework.
#
Pod::Spec.new do |s|
  s.name             = 'pt_transport_darwin'
  s.version          = '1.0.0'
  s.summary          = 'Native transport core for macOS.'
  s.description      = <<-DESC
Carries PtTransport.xcframework into the app bundle. No Objective-C or Swift
API: the Dart side reaches the library through dart:ffi over @rpath.
                       DESC
  s.homepage         = 'https://example.com/voice_call_kit'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Voice Call Kit' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.vendored_frameworks = 'Frameworks/PtTransport.xcframework'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
