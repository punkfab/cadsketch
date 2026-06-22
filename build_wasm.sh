#!/usr/bin/env bash
# Compiles the durable C++ geometry kernel to WebAssembly for the Flutter web
# build. Output (web/kernel/sketch_kernel.{js,wasm}) is gitignored and produced
# here and in CI; the hand-written web/kernel/kernel_glue.js bridges it to Dart
# (lib/ffi/sketch_kernel_web.dart). Same single source as the native FFI path.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p web/kernel

emcc native/sketch_kernel.cpp -O3 -std=c++17 \
  -o web/kernel/sketch_kernel.js \
  -sMODULARIZE=1 -sEXPORT_NAME=createSketchKernel \
  -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,getValue,setValue,HEAPF64 \
  -sEXPORTED_FUNCTIONS=_sk_version,_sk_fit_line,_sk_fit_circle,_sk_create,_sk_destroy,_sk_add_point,_sk_fix_point,_sk_add_constraint,_sk_solve,_sk_point,_sk_add_radius,_sk_radius,_sk_constrain_radius,_sk_constrain_point_on_circle,_sk_constrain_tangent_line,_malloc,_free \
  -sALLOW_MEMORY_GROWTH=1 -sENVIRONMENT=web

echo "Built web/kernel/sketch_kernel.{js,wasm}"
