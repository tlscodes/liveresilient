#
# Vendors the native transport core for iOS. CocoaPods picks the right slice out
# of the xcframework (device vs simulator) and the standard "Embed Pods
# Frameworks" phase embeds and code-signs it into Runner.app.
#
Pod::Spec.new do |s|
  s.name             = 'pt_transport_darwin'
  s.version          = '1.0.0'
  s.summary          = 'Native transport core for iOS.'
  s.description      = <<-DESC
Carries PtTransport.xcframework into the app bundle. No Objective-C or Swift
API: the Dart side reaches the library through dart:ffi over @rpath.
                       DESC
  s.homepage         = 'https://example.com/voice_call_kit'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Voice Call Kit' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.vendored_frameworks = 'Frameworks/PtTransport.xcframework'
  s.source_files = 'Sources/*.{c,h}'
  s.public_header_files = 'Sources/pt_shim.h'

  #
  # The pinned backend is NOT vendored here. A written decision names an
  # external clone at a pinned commit and forbids copying its source into this
  # repository, so the archives are referenced where they were built, by
  # absolute paths this file resolves at `pod install` time. Nothing large and
  # nothing machine-specific enters version control: the generated xcconfigs
  # live under the ignored Pods directory, and the checksum in Podfile.lock
  # hashes this text, which is identical on every machine.
  #
  # The flags are attached ONLY under the device SDK. A simulator build links
  # nothing and compiles the stub, so the pod cannot half-link archives built
  # for another architecture — a failure whose message is famously unhelpful.
  # The existence check runs at install time; if the cache appears or
  # disappears later, `pod install` again. The notice below makes the stub case
  # visible rather than silent.
  #
  boringssl_pin = 'b0760837'
  boringssl_cache = File.expand_path('~/.cache/tlsapi/boringssl')
  boringssl_libdir = File.join(boringssl_cache, 'build-ios-arm64')
  boringssl_include = File.join(boringssl_cache, 'include')
  boringssl_present = File.exist?(File.join(boringssl_libdir, 'libssl.a')) &&
                      File.exist?(File.join(boringssl_libdir, 'libcrypto.a'))

  base_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  if boringssl_present
    link_flags = %("#{boringssl_libdir}/libssl.a" "#{boringssl_libdir}/libcrypto.a" -lc++)
    s.pod_target_xcconfig = base_xcconfig.merge(
      'HEADER_SEARCH_PATHS[sdk=iphoneos*]' => %("#{boringssl_include}"),
      'GCC_PREPROCESSOR_DEFINITIONS[sdk=iphoneos*]' =>
        "$(inherited) PT_SHIM_HAVE_BORINGSSL=1 PT_SHIM_BORINGSSL_PIN=#{boringssl_pin}",
      'OTHER_LDFLAGS[sdk=iphoneos*]' => "$(inherited) #{link_flags}",
    )
    s.user_target_xcconfig = {
      'OTHER_LDFLAGS[sdk=iphoneos*]' => "$(inherited) #{link_flags}",
    }
  else
    s.pod_target_xcconfig = base_xcconfig
    Pod::UI.puts '[pt_transport_darwin] pinned backend cache absent — building the stub shim, pt_shim_backend_linked() will answer 0.'
  end
end
