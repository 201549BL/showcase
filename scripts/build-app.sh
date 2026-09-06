#!/bin/bash
set -euo pipefail

repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;; esac
distribution="${SHOWCASE_DISTRIBUTION:-0}"
signing_identity="${SHOWCASE_SIGNING_IDENTITY:-${SMOOTHSCREEN_SIGNING_IDENTITY:-}}"
build_args=(-c "$configuration")
app_dir="$repository_dir/.build/Showcase.app"

if [[ "$distribution" == 1 ]]; then
    [[ "$configuration" == release ]] || { echo 'Distribution requires release configuration.' >&2; exit 1; }
    build_args+=(--scratch-path "$repository_dir/.build/distribution" --arch arm64 --arch x86_64)
    app_dir="$repository_dir/.build/distribution/Showcase.app"
    if [[ -z "$signing_identity" ]]; then
        signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' | head -1)"
    fi
    [[ -n "$signing_identity" && "$signing_identity" != - ]] || {
        echo 'A Developer ID Application certificate is required for distribution.' >&2; exit 1;
    }
elif [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' | head -1)"
fi

cd "$repository_dir"
swift build "${build_args[@]}"
build_dir="$(swift build "${build_args[@]}" --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/Showcase" "$app_dir/Contents/MacOS/Showcase"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"

if [[ "$distribution" == 1 ]]; then
    codesign --force --sign "$signing_identity" --options runtime --timestamp \
        --entitlements Resources/Showcase.entitlements "$app_dir"
    codesign --verify --deep --strict --verbose=2 "$app_dir"
    signature_details="$(codesign --display --verbose=4 "$app_dir" 2>&1)"
    [[ "$signature_details" == *'Authority=Developer ID Application:'* ]] || {
        echo 'The distribution app must be signed with Developer ID Application.' >&2; exit 1;
    }
    lipo "$app_dir/Contents/MacOS/Showcase" -verify_arch arm64 x86_64
else
    codesign --force --sign "${signing_identity:--}" "$app_dir"
fi
printf '%s\n' "$app_dir"
