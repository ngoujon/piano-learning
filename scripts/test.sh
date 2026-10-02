#!/bin/bash
# Runs the unit tests. Works with Command Line Tools only (no Xcode) by pointing at its Testing.framework.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$DEV/Frameworks/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test -Xswiftc -F"$DEV/Frameworks" \
    -Xlinker -F"$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
fi
exec swift test "$@"
