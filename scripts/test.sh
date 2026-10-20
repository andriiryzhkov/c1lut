#!/bin/sh
# Runs the tests. With only the Command Line Tools, SwiftPM sometimes doesn't tell the compiler
# where the swift-testing macros are ("plugin for module 'TestingMacros' not found"), so the
# folder is passed explicitly. With Xcode this isn't needed.
set -eu
cd "$(dirname "$0")/.."

plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
