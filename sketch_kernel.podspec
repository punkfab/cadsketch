#
# Compiles the durable C++ geometry kernel (native/sketch_kernel.cpp) into the
# iOS app as a static library. The kernel is the one artifact that survives the
# eventual native rebuild; on iOS it is statically linked and its symbols are
# resolved at runtime via `DynamicLibrary.process()` (see lib/ffi).
#
# Source of truth stays in native/ (shared with the Linux harness). The pod
# references it directly — no copies, no drift.
#
# IMPORTANT: this podspec lives at the REPO ROOT (not ios/) on purpose.
# CocoaPods silently excludes source_files that live outside the pod's root
# directory, so an ios/ podspec pointing at ../native/*.cpp produces an EMPTY
# library (build succeeds, zero symbols). Keeping it at the root means native/
# is inside the pod root and gets compiled. Referenced from ios/Podfile via
# `pod 'sketch_kernel', :path => '..'`.
#
Pod::Spec.new do |s|
  s.name             = 'sketch_kernel'
  s.version          = '0.0.1'
  s.summary          = 'ai-sketcher geometry kernel (LM constraint solver, fits)'
  s.description      = 'Flat C ABI geometry kernel shared by the Flutter harness and the native iOS build.'
  s.homepage         = 'https://github.com/punkfab/cadsketch'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Dan Newcome' => 'support@cadsketch.ai' }
  s.source           = { :path => '.' }

  # Paths are relative to this podspec (repo root) — native/ is inside it.
  s.source_files         = 'native/sketch_kernel.{cpp,h}'
  s.public_header_files  = 'native/sketch_kernel.h'

  s.requires_arc     = false
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY'           => 'libc++',
    # Don't let the compiler strip the exported sk_* symbols.
    'GCC_SYMBOLS_PRIVATE_EXTERN'  => 'NO',
  }
end
