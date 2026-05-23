require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "NitroWebrtcVad"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported, :visionos => 1.0 }
  s.source       = { :git => "https://github.com/enfpdev/react-native-nitro-webrtc-vad.git", :tag => "#{s.version}" }

  s.source_files = [
    # Implementation (Swift)
    "ios/**/*.{swift}",
    # Autolinking/Registration (Objective-C++)
    "ios/**/*.{m,mm}",
    # Implementation (C++ objects)
    "cpp/**/*.{hpp,cpp}",
    # Vendored WebRTC VAD C/C++ source
    "third_party/webrtcvad/webrtc/**/*.h",
    "third_party/webrtcvad/webrtc/common_audio/**/*.c",
    "third_party/webrtcvad/webrtc/rtc_base/checks.cc",
  ]

  s.pod_target_xcconfig = {
    "HEADER_SEARCH_PATHS" => "\"$(PODS_TARGET_SRCROOT)/third_party/webrtcvad\"",
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) WEBRTC_POSIX=1"
  }

  load 'nitrogen/generated/ios/NitroWebrtcVad+autolinking.rb'
  add_nitrogen_files(s)

  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'
  s.frameworks = 'AVFoundation'
  install_modules_dependencies(s)
end
