# Notarization and distribution

Requires an Apple Developer Program membership and **Xcode.app** with a Developer ID Application certificate.

## 1. Archive

In Xcode:

1. Scheme **TokenMon** → Any Mac
2. Product → Archive
3. Distribute App → Developer ID → Upload / Export

Or from the command line (with Xcode selected via `xcode-select`):

```bash
xcodebuild -project TokenMon.xcodeproj -scheme TokenMon -configuration Release \
  -archivePath build/TokenMon.xcarchive archive

xcodebuild -exportArchive -archivePath build/TokenMon.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist Scripts/ExportOptions.plist
```

`make archive` and `make export` wrap these two steps (archive → `build/export`).

`Scripts/ExportOptions.plist` has no `teamID` — with `signingStyle: automatic` this is inferred from the archive's own signing identity. If your Apple ID belongs to more than one team, add a `teamID` key (`<key>teamID</key><string>YOURTEAMID</string>`) to disambiguate.

## 2. Notarize

```bash
# Create an app-specific password at appleid.apple.com and store it in Keychain:
# xcrun notarytool store-credentials "AC_PASSWORD" --apple-id YOU@email --team-id TEAMID

./Scripts/notarize.sh "build/export/TokenMon.app"   # or a Developer ID Installer-signed .pkg
```

`Scripts/notarize.sh` zips an app into a temporary folder (or submits a signed pkg as is), submits it with `notarytool --wait`, then staples and validates the ticket. On any verdict other than **Accepted** it prints the `notarytool log` for the submission and exits non-zero. Nothing is left behind next to the input.

`make release NOTARY=1` (or `make notarize` after `make release`) notarizes and staples `dist/TokenMon.app`, rebuilds the zip and pkg from the stapled app, and notarizes the pkg when a Developer ID Installer identity is available. Without a Developer ID Application identity `make notarize` refuses to run.

## 3. Ship

`make release` writes `dist/TokenMon-<version>.zip`, `.pkg`, and `-dSYM.zip`, and prints their SHA-256. Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`: every CI gate runs against the tagged commit, then the three files are attached to the GitHub release. The CI runner has no Developer ID certificate, so those files are **ad-hoc signed and not notarized**; Gatekeeper warns on a first manual download.

## In-app updates

TokenMon updates itself from GitHub releases (`UpdateChecker`, `ReleaseFeed`, `AppInstaller`); there is no Sparkle.

**Check.** Every 6 hours while automatic checks are on (Settings), and on demand from the menu or Settings, the app GETs `https://api.github.com/repos/<owner>/<repo>/releases/latest`. A release is offered when its tag parses as a version newer than the running `CFBundleShortVersionString` and is not a prerelease. Only assets whose download URL is one of this repository's `github.com/<owner>/<repo>/releases/download/…` URLs are considered; the zip and pkg named `TokenMon-*` are preferred and dSYM archives are skipped.

**Download.** The zip is streamed over an ephemeral session whose redirects may only stay on this repository's release downloads or GitHub's asset hosts (`objects.githubusercontent.com`, `release-assets.githubusercontent.com`). It is capped at 80 MB while downloading and 256 MB extracted, and an archive containing a symbolic link is refused.

**Verify.** Before anything on disk changes:

1. **Digest** — the SHA-256 of the downloaded zip must equal the `sha256:` digest GitHub records for that asset. A release without a digest is not installed; the release page opens instead.
2. **Signature** — the app's code signature must validate (all architectures, strict, nested code) against the requirement `identifier "com.modelmonitor.app"`, plus `anchor apple generic` and the running app's Team ID when the running copy is Developer ID signed. Ad-hoc builds are checked against the identifier only.
3. **Bundle id** — `CFBundleIdentifier` must be `com.modelmonitor.app`.
4. **Version** — `CFBundleShortVersionString` must be strictly newer than the running version.
5. **Quarantine** — an ad-hoc build carrying `com.apple.quarantine` is refused, because Gatekeeper would block its relaunch. The download is written by TokenMon itself, which does not quarantine its files; the app never strips quarantine attributes.

The checks run on a staged copy (`.TokenMon-update-<uuid>.app`) placed next to the installed app.

**Swap.** The verified copy replaces the installed app with a single `FileManager.replaceItemAt`, so a failure at any step leaves the installed app untouched and running. TokenMon then relaunches the new copy once the old process has exited.

**Fallbacks.**

- The installed copy cannot replace itself (its folder is not writable, or macOS is running it from App Translocation): a translocated copy is asked to move into Applications; otherwise the release's `.pkg` is downloaded for the user to open, or the release page opens when there is none.
- The zip is missing, has no digest, or fails any check: the release page opens with the reason.

**Keychain prompt after an update.** Ad-hoc signed builds have no stable signing identity, so macOS treats each update as a new app and asks once whether it may read the TokenMon Keychain item. Choose **Always Allow**. Developer ID builds keep access across updates.

## Entitlements

The current build intentionally uses an empty entitlements file and is not App Sandbox-enabled. This is required for the OpenCode local usage reader to access `~/.local/share/opencode/opencode.db` without a security-scoped file picker. The app uses hardened runtime and ad-hoc signing for local Debug builds; configure Developer ID signing before distribution.

## Gatekeeper check

```bash
spctl --assess --type execute -v "TokenMon.app"
stapler validate "TokenMon.app"
```
