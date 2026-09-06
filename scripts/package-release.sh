#!/bin/bash
# Builds a Developer ID-signed universal app. Only exports a release asset after notarization succeeds.
set -euo pipefail
repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_dir"
mode="${1:-publish-ready}"
case "$mode" in --prepare|publish-ready) ;; *) echo "Usage: $0 [--prepare]" >&2; exit 1 ;; esac
profile="${SHOWCASE_NOTARY_PROFILE:-Showcase}"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
release_dir="$repository_dir/.build/release/$version"
app_dir="$repository_dir/.build/distribution/Showcase.app"
mkdir -p "$release_dir"
SHOWCASE_DISTRIBUTION=1 ./scripts/build-app.sh release
submission="$release_dir/Showcase-$version-notarization.zip"
ditto -c -k --keepParent "$app_dir" "$submission"
if [[ "$mode" == --prepare ]]; then
    echo "Signed universal app prepared: $app_dir"
    echo "Notarization is still required before distribution. Run $0 after configuring profile '$profile'."
    exit 0
fi

xcrun notarytool submit "$submission" --keychain-profile "$profile" \
    --wait --timeout 20m --output-format json > "$release_dir/notarization.json"
status="$(plutil -extract status raw -o - "$release_dir/notarization.json")"
if [[ "$status" != Accepted ]]; then
    echo "Apple notarization did not accept the app. See $release_dir/notarization.json" >&2
    exit 1
fi
xcrun stapler staple "$app_dir"
xcrun stapler validate "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
spctl --assess --type execute --verbose=2 "$app_dir"
asset="$release_dir/Showcase-$version-universal.zip"
ditto -c -k --keepParent "$app_dir" "$asset"
(cd "$release_dir" && shasum -a 256 "$(basename "$asset")" > SHA256SUMS.txt)
printf 'Ready for release: %s\n' "$asset"
