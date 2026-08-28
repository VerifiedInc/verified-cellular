Pod::Spec.new do |s|
  s.name           = 'VerifiedCellular'
  s.version        = '2.0.0'
  s.summary        = 'Runs a request, and its whole redirect chain, over cellular.'
  s.description    = 'Local Expo module wrapping the VerifiedCellular snippet — every hop an NWConnection pinned to the cellular interface, with hand-rolled HTTP/1.1.'
  s.author         = 'Verified'
  s.homepage       = 'https://docs.verified.inc/'
  # 16.0 because the snippet builds request targets with URL.path(percentEncoded:),
  # which does not exist before iOS 16.
  s.platforms      = {
    :ios => '16.0'
  }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
end
