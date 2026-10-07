#!/bin/bash
# Builds Varlatch.app from this checkout: `swift build -c release`, then the
# app bundle around the binary (Info.plist and icons), signed ad hoc. Needs
# the Command Line Tools only.
#
#   scripts/bundle.sh [--version X.Y.Z] [--output DIR] [-- <swift build options>]
#
# The version defaults to the latest vX.Y.Z tag, or 0.0.0 without one. The
# app lands in DIR/Varlatch.app (default: build/Varlatch.app). Options after
# `--` go to `swift build`, such as --disable-sandbox inside Homebrew's own
# sandbox.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version=""
output="$root/build"
swift_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version=${2:?--version needs X.Y.Z}; shift 2 ;;
    --output) output=${2:?--output needs a directory}; shift 2 ;;
    --) shift; swift_args=("$@"); break ;;
    *) echo "usage: scripts/bundle.sh [--version X.Y.Z] [--output DIR] [-- <swift build options>]" >&2; exit 64 ;;
  esac
done

revision=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)
if [ -z "$version" ]; then
  version=$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
  version=${version#v}
  version=${version:-0.0.0}
fi
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "bundle.sh: the version must look like 1.2.3, not \"$version\"" >&2
  exit 64
fi

cd "$root"
# bash 3.2 (macOS's /bin/bash) treats an empty array as unset under set -u.
swift build -c release --product Varlatch ${swift_args[@]+"${swift_args[@]}"}
bin=$(swift build -c release --show-bin-path ${swift_args[@]+"${swift_args[@]}"})

app="$output/Varlatch.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Varlatch" "$app/Contents/MacOS/Varlatch"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$app/Contents/Resources/"
sed -e "s/__VERSION__/$version/g" -e "s/__REVISION__/${revision}/g" Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"

# Ad hoc: no Apple Developer ID. An app built on this Mac is not quarantined,
# so Gatekeeper lets it run; notifications and login items need the bundle
# identifier the signature carries.
codesign --force --sign - --identifier com.varlatch.menubar "$app"
codesign --verify --strict "$app"
echo "$app"
