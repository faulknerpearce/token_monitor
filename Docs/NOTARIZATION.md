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

./Scripts/notarize.sh "build/export/TokenMon.app"
```

The script zips the app, submits with `notarytool`, waits, then staples the ticket.

## 3. Ship

- Zip or DMG the stapled `.app`
- Publish SHA-256 checksum alongside the download
- Optional later: Sparkle for auto-updates (not included in v1)

## Entitlements

The current build intentionally uses an empty entitlements file and is not App Sandbox-enabled. This is required for the OpenCode local usage reader to access `~/.local/share/opencode/opencode.db` without a security-scoped file picker. The app uses hardened runtime and ad-hoc signing for local Debug builds; configure Developer ID signing before distribution.

## Gatekeeper check

```bash
spctl --assess --type execute -v "TokenMon.app"
stapler validate "TokenMon.app"
```
