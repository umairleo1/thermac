#!/bin/sh
# Runs the test suite.
#
# With only the Command Line Tools installed, SwiftPM's explicit-module build sometimes
# omits the swift-testing macro plugin ("plugin for module 'TestingMacros' not found").
# Loading it explicitly makes `swift test` reliable. Tests use their own scratch path so
# they never fight with release builds in .build/.
set -e
cd "$(dirname "$0")/.."
PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ]; then
  exec swift test --scratch-path .build/test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
else
  exec swift test --scratch-path .build/test "$@"
fi
