#!/bin/bash

set -euo pipefail

repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
app_dir="$repository_dir/.build/SmoothScreen.app"

cd "$repository_dir"
swift build -c "$configuration"
build_dir="$(swift build -c "$configuration" --show-bin-path)"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/SmoothScreen" "$app_dir/Contents/MacOS/SmoothScreen"
cp "$repository_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

signing_identity="${SMOOTHSCREEN_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' \
        | head -1)"
fi

if [[ -n "$signing_identity" ]]; then
    codesign --force --deep --sign "$signing_identity" "$app_dir"
else
    codesign --force --deep --sign - "$app_dir"
fi

echo "$app_dir"
