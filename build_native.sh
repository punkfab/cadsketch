#!/usr/bin/env bash
# Quick standalone build of the native kernel into build/native/, for iterating
# on sketch_kernel.cpp without a full `flutter run`. The Flutter Linux build
# (linux/CMakeLists.txt) builds and bundles it automatically too — this is just
# the fast path. After running this, `flutter run -d linux` picks up the .so.
set -euo pipefail
cd "$(dirname "$0")/native"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -G Ninja
cmake --build build
echo "built -> $(cd .. && pwd)/build/native/"
