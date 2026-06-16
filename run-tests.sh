#!/bin/bash
# Runs the test suite via `swift test`.
#
# The Command Line Tools toolchain ships Swift Testing (Testing.framework +
# lib_TestingInterop.dylib) but doesn't put them on SwiftPM's default search
# path, so we point the compiler and dynamic loader at the developer-dir
# location explicitly. No full Xcode required. If a full Xcode IS selected
# (Testing.framework not under the CLT layout), the flags are skipped and
# plain `swift test` resolves everything itself.
#
# Any extra args are forwarded, e.g. ./run-tests.sh --filter TitleParser
set -euo pipefail

DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

ARGS=()
if [ -d "$FW/Testing.framework" ]; then
    ARGS+=(
        -Xswiftc -F -Xswiftc "$FW"
        -Xlinker -F -Xlinker "$FW"
        -Xlinker -rpath -Xlinker "$FW"
        -Xlinker -rpath -Xlinker "$LIB"
    )
fi

exec swift test "${ARGS[@]}" "$@"
