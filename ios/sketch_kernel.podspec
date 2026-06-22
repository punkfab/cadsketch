#
# Compiles the durable C++ geometry kernel (native/sketch_kernel.cpp) into the
# iOS app as a static library. The kernel is the one artifact that survives the
# eventual native rebuild; on iOS it is statically linked and its symbols are
# resolved at runtime via `DynamicLibrary.process()` (see lib/ffi).
#
# Source of truth stays in native/ (shared with the Linux harness). The pod
# references it directly — no copies, no drift.
#
Pod::Spec.new do |s|
  s.name             = 'sketch_kernel'
  s.version          = '0.0.1'
  s.summary          = 'ai-sketcher geometry kernel (LM constraint solver, fits)'
  s.description      = 'Flat C ABI geometry kernel shared by the Flutter harness and the native iOS build.'
  s.homepage         = 'https://github.com/dnewcome/ai-sketcher'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Dan Newcome' => 'djn125@yahoo.com' }
  s.source           = { :path => '.' }

  # The .cpp/.h live one level up from ios/ (single source of truth).
  s.source_files        = '../native/sketch_kernel.{cpp,h}'
  s.public_header_files  = '../native/sketch_kernel.h'

  s.requires_arc     = false
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY'           => 'libc++',
    # Don't let the compiler strip the exported sk_* symbols.
    'GCC_SYMBOLS_PRIVATE_EXTERN'  => 'NO',
  }
end
