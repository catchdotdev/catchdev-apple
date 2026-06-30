Pod::Spec.new do |spec|
  spec.name             = 'CatchDev'
  spec.version          = '0.2.0'
  spec.summary          = 'Shake-to-report user feedback for iOS apps, by catch.dev.'
  spec.description      = <<-DESC
    CatchDev lets your users shake their device to report a problem: it captures the
    current screen, lets them annotate it and add a note, then sends it straight to
    your catch.dev dashboard.
  DESC
  spec.homepage         = 'https://github.com/catchdotdev/catchdev-apple'
  spec.license          = { :type => 'MIT', :file => 'LICENSE' }
  spec.author           = { 'catch.dev' => 'support@catch.dev' }
  spec.source           = {
    :git => 'https://github.com/catchdotdev/catchdev-apple.git',
    :tag => spec.version.to_s
  }

  spec.ios.deployment_target = '15.0'
  spec.swift_versions   = ['5.9']
  spec.source_files     = 'Sources/CatchDev/**/*.swift'
  spec.frameworks       = 'UIKit', 'PencilKit'
  spec.resource_bundles = { 'CatchDev' => ['Sources/CatchDev/PrivacyInfo.xcprivacy'] }
end
