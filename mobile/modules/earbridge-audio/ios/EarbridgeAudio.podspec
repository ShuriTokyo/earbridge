require 'fileutils'

# What the voice checks need and the repository doesn't hold: sherpa-onnx's iOS framework
# (fetched by get-sherpa-onnx.sh, checked by its SHA-256) and the separation model, the
# same file as Android's (copied from its assets). Both are git-ignored.
here = __dir__
unless File.directory?(File.join(here, 'Frameworks', 'SherpaOnnxC.xcframework'))
  system('/bin/bash', File.join(here, 'get-sherpa-onnx.sh')) or raise 'Could not get sherpa-onnx for iOS: see get-sherpa-onnx.sh'
end
separator = File.join(here, 'Resources', 'convtasnet.onnx')
unless File.exist?(separator)
  FileUtils.mkdir_p(File.dirname(separator))
  FileUtils.cp(File.join(here, '..', 'android', 'src', 'main', 'assets', 'convtasnet.onnx'), separator)
end

Pod::Spec.new do |s|
  s.name           = 'EarbridgeAudio'
  s.version        = '1.0.0'
  s.summary        = "Alo's on-phone engines for iPhone"
  s.description    = "Apple's SpeechAnalyzer and Translation framework behind Alo's on-device engine (iOS 26 and newer); " \
                     'voice prints (sherpa-onnx), voice separation (ONNX Runtime) and two-microphone capture for the voice checks.'
  s.license        = { type: 'Proprietary' }
  s.author         = 'EarBridge'
  s.homepage       = 'https://github.com/OreNoMochii/earbridge'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/OreNoMochii/earbridge.git' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  # Separating voices (VoiceIsolator.swift). sherpa-onnx keeps its own runtime inside its
  # framework, hidden, so this one is apart from it.
  s.dependency 'onnxruntime-objc', '~> 1.30.0'

  s.frameworks      = 'AVFoundation', 'Speech', 'SwiftUI', 'CoreMotion', 'CryptoKit'
  # Translation exists from iOS 17.4: weak, so the app still opens on older iPhones.
  s.weak_frameworks = 'Translation'
  # Voice prints for "Only our voices": sherpa-onnx 1.13.8, as on Android.
  s.vendored_frameworks = 'Frameworks/SherpaOnnxC.xcframework'
  s.resource_bundles = { 'EarbridgeAudio' => ['Resources/convtasnet.onnx'] }

  s.source_files  = '*.swift'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
