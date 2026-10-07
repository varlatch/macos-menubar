#!/bin/bash
# Runs the tests (Swift Testing). Xcode finds the Testing framework by
# itself; with only the Command Line Tools, its paths are given here.
#
#   scripts/test.sh [<swift test options>]
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}
if [[ "$developer_dir" == *CommandLineTools* ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  libs="$developer_dir/Library/Developer/usr/lib"
  exec swift test \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xlinker -F -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$libs" \
    "$@"
fi
exec swift test "$@"
