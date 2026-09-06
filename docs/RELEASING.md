# Releasing Showcase

The release workflow creates a universal macOS app for Apple silicon and Intel, signs it with Developer ID Application and hardened runtime, notarizes it with Apple, staples the ticket, and verifies it with Gatekeeper before producing the download ZIP and checksum.

## Prerequisites

- Xcode 26 or newer, with the selected command-line tools.
- A valid **Developer ID Application** identity and its private key in the local Keychain.
- Apple notarization credentials stored in a Keychain profile.
- GitHub CLI authenticated to the repository owner.

An Apple Development certificate is sufficient for local development, but not for distribution.

## Set up notarization once

Run this command in your own Terminal. It prompts for your Apple ID and an **app-specific password**; do not place the password in a shell command, repository, or chat. Create the app-specific password in your Apple Account's Sign-In and Security settings if needed.

```bash
xcrun notarytool store-credentials Showcase --team-id YOUR_TEAM_ID
```

The command validates the credentials before storing them in Keychain. `SHOWCASE_NOTARY_PROFILE` can select another existing profile. An App Store Connect API key is also supported by `notarytool store-credentials`.

## Prepare and verify

1. Update `CFBundleShortVersionString` and increase `CFBundleVersion` in `Resources/Info.plist`.
2. Write version-specific notes in `docs/releases/`.
3. Run `swift test` and check the recorder, editor, and an export on a Mac.
4. Build and notarize:

```bash
./scripts/package-release.sh
```

To prepare the signed universal build before credentials are available:

```bash
./scripts/package-release.sh --prepare
```

The prepared app is **not yet ready for distribution**. Run the normal command after setting up notarization.

Final downloads are written to `.build/releases/VERSION/`:

- `Showcase-VERSION-universal.zip` — the signed, stapled application.
- `SHA256SUMS.txt` — SHA-256 checksum of that ZIP.
- `notarization.json` — Apple's submission result, for local release records.

Do not upload the `*-notarization.zip` submission archive. The packaging script only writes the final asset after Apple returns `Accepted`, stapling succeeds, and `spctl` accepts the app. If submission times out, use the submission ID with `notarytool info` / `notarytool log` to inspect its state before trying again.

The distribution build uses a separate `.build/distribution/` directory so it does not replace a running development app. Camera and audio-input hardened-runtime entitlements are declared explicitly. The app is not sandboxed because it records global input events.

## Publish

Commit the tested source, push it to `main`, and wait for the GitHub build checks. Create an annotated version tag on that commit, then upload the verified assets:

```bash
git tag -a v0.1.0 -m 'Showcase 0.1.0'
git push origin v0.1.0
gh release create v0.1.0 \
  .build/releases/0.1.0/Showcase-0.1.0-universal.zip \
  .build/releases/0.1.0/SHA256SUMS.txt \
  --verify-tag --title 'Showcase 0.1.0' \
  --notes-file docs/releases/0.1.0.md
```

For an initial review before notarization is complete, create a **draft** release and keep it unpublished until the verified download exists. Signing credentials remain local; GitHub CI only runs tests and an ad hoc-signed build.

## Icon

`Resources/AppIcon.icns` is generated from the vector drawing in `scripts/generate-icon.swift`:

```bash
swift scripts/generate-icon.swift
iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
```

## References

- [Apple: Developer ID distribution](https://developer.apple.com/developer-id/)
- [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
