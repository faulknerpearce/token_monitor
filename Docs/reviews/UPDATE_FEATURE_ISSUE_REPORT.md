# TokenMon Update Feature — Issue Report

**Date:** 2026-09-27
**Component:** `TokenMon/Features/Update/` (`UpdateChecker`, `ReleaseFeed`, `AppInstaller`)
**Reported symptom:** "The check-for-update / update feature doesn't auto-update, and it redirects the user to GitHub."

---

## Summary

The report is confirmed and has two independent causes:

1. **The update never installs in place for most users; it falls back to opening the GitHub release page.** The installer is gated behind `AppInstaller.canReplaceRunningApp()`, which is false for an App-Translocated or non-writable copy. Because TokenMon is distributed **ad-hoc signed** (no Developer ID / not notarized), a browser-downloaded zip is quarantined and macOS runs it from a read-only translocated copy — so the gate is false and the user is sent to GitHub. This is the common case, not the edge case.

2. **The automatic check is silent and the in-app update affordance was removed.** `UpdateChecker` only auto-*checks* every 6 hours; it never auto-*installs*. The menu-bar row that surfaced an available update was deleted in the "cog-only menu" refactor (commit `86e695b`, v1.7.0). The only remaining UI is Settings → System, so a background check that finds an update is never surfaced.

There is also a latent correctness bug in the writability check that can leave the app terminated but un-replaced.

---

## Evidence

All checks were run against the live repository `faulknerpearce/token_monitor`.

### The latest release is well-formed (so the asset logic is not the problem)

`GET https://api.github.com/repos/faulknerpearce/token_monitor/releases/latest`:

```
tag: v1.7.1   draft: false   prerelease: false
assets:
  TokenMon-1.7.1.pkg -> .../releases/download/v1.7.1/TokenMon-1.7.1.pkg
  TokenMon-1.7.1.zip -> .../releases/download/v1.7.1/TokenMon-1.7.1.zip
```

`ReleaseFeed.archiveURL(in:)` correctly selects `TokenMon-1.7.1.zip` (prefers the `tokenmon*` prefix, host is trusted).

### The download path works

Reproduced the app's exact `URLSession` + `TrustedReleaseRedirect` configuration against the live asset:

```
status: 200
bytes: 3185590
finalURL: https://release-assets.githubusercontent.com/github-production-release-asset/...
```

The `github.com` → `release-assets.githubusercontent.com` redirect is trusted by `ReleaseFeed.isTrustedDownload`. The zip extracts to a valid `TokenMon.app`. So neither `archiveURL == nil` nor a download error is the trigger.

### The shipped build is ad-hoc signed, so it gets Translocation

Installed copy:

```
Identifier=com.modelmonitor.app
CodeDirectory v=20500 ... flags=0x10002(adhoc,runtime)
Signature=adhoc
TeamIdentifier=not set
```

The release zip payload is the same:

```
Signature=adhoc
TeamIdentifier=not set
```

`.github/workflows/release.yml` documents this: *"The runner has no Developer ID certificate, so these files are ad-hoc signed."*

A quarantined, ad-hoc/non-notarized app is run by macOS from a read-only translocated path (`/private/var/folders/.../AppTranslocation/<UUID>/d/TokenMon.app`). That path contains `/AppTranslocation/`, so `AppInstaller.isRunningTranslocated` is `true`.

---

## Root cause 1 — the GitHub redirect

`TokenMon/Features/Update/UpdateChecker.swift:94-118`:

```swift
func installAvailableUpdate() async {
    guard let release = availableRelease, !isInstalling else { return }
    guard let archiveURL = release.archiveURL else {
        statusMessage = "No installer was published — opening the release page."
        NSWorkspace.shared.open(release.pageURL)      // :98
        return
    }
    guard AppInstaller.canReplaceRunningApp() else {
        statusMessage = AppInstaller.isRunningTranslocated
            ? "Move TokenMon into Applications, then update."
            : AppInstaller.Failure.notWritable.localizedDescription
        NSWorkspace.shared.open(release.pageURL)      // :105  <-- fires for translocated copies
        return
    }
    isInstalling = true
    defer { isInstalling = false }
    do {
        let app = try await AppInstaller.downloadApp(from: archiveURL, session: downloadSession)
        try AppInstaller.replaceAndRelaunch(newApp: app)
    } catch {
        statusMessage = error.localizedDescription
        logger.error("Update install failed: \(error.localizedDescription, privacy: .public)")
        NSWorkspace.shared.open(release.pageURL)      // :116
    }
}
```

`TokenMon/Features/Update/AppInstaller.swift:25-34`:

```swift
static var isRunningTranslocated: Bool {
    Bundle.main.bundleURL.path.contains("/AppTranslocation/")
}

static func canReplaceRunningApp(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
    guard bundleURL.pathExtension == "app", !isRunningTranslocated else { return false }
    let parent = bundleURL.deletingLastPathComponent()
    return FileManager.default.isWritableFile(atPath: parent.path)
}
```

**Chain:** browser download → quarantine → ad-hoc/unnotarized → App Translocation → `isRunningTranslocated == true` → `canReplaceRunningApp() == false` → `NSWorkspace.shared.open(release.pageURL)`.

The user sees the app open GitHub instead of updating. `performPrimaryAction()` (`UpdateChecker.swift:85-91`) routes both the menu action and the Settings button through this same code, so every entry point behaves identically.

**Who is affected:** anyone running a zip-downloaded copy (Downloads / translocated), a copy on a read-only volume, or a copy in a non-writable folder — i.e. the normal install path for the published release. Users who built locally (`make run`) or installed via `make install` / a user-owned `.pkg` into a writable `/Applications` are unaffected.

---

## Root cause 2 — "doesn't auto update"

1. **No auto-install exists.** `UpdateChecker.start()`/`checkNow()` only call `performCheck`, which publishes `availableRelease`. Installing always requires a manual click (`performPrimaryAction`). The 6-hour `checkInterval` is a *check* cadence only.

2. **The update surface was removed in v1.7.0.** Commit `86e695b` ("cog-only menu") deleted the dropdown footer, including:

   ```swift
   panelButton(updateChecker.actionTitle, shortcut: nil, disabled: !updateChecker.canAct) {
       Task { await updateChecker.performPrimaryAction() }
   }
   ```

   No file under `TokenMon/Features/MenuBar/` references `updateChecker` any more. The only remaining update UI is `PreferencesView.swift:263-281` (Settings → System). A background check that finds a newer release therefore produces no visible prompt unless the user happens to open Settings.

---

## Latent bug — the writability check is insufficient

`canReplaceRunningApp()` (`AppInstaller.swift:30-34`) only checks that the *parent directory* is writable. Replacing the app also requires deleting the existing bundle's contents. For a `.pkg`-installed app owned by root, the parent (`/Applications`, mode `drwxrwxr-x root admin`) can pass the check while `rm -rf` on the root-owned bundle fails. The post-exit script (`AppInstaller.swift:75-85`) runs under `set -euo pipefail`:

```bash
while kill -0 <pid> 2>/dev/null; do sleep 0.2; done
rm -rf '<destination>'
ditto '<newApp>' '<destination>'
...
open '<destination>'
```

If `rm -rf` fails, the script aborts **after the app has already been terminated**, leaving it partially deleted and never relaunched. This produces a different symptom (app vanishes / won't reopen) rather than a GitHub redirect, but it is a real failure mode of the same feature.

---

## Recommended fixes (ranked)

| # | Fix | Why |
|---|-----|-----|
| 1 | **Sign with a Developer ID and notarize** the release; optionally detect `isRunningTranslocated` and offer to move the app to `/Applications` first. | Removes App Translocation, which is the root cause. Nothing else fully fixes the zip-install path. |
| 2 | **Fall back to the published `.pkg`, not the browser.** The release already contains `TokenMon-*.pkg`; download it and `NSWorkspace.shared.open(...)` to hand off to Installer (handles the privileged write to `/Applications`). | Immediately unblocks translocated and non-writable installs without requiring a signed build. Replace the three `NSWorkspace.shared.open(release.pageURL)` calls with a pkg hand-off, keeping the browser as a last resort only. |
| 3 | **Restore an update affordance** in the menu bar (or post a `UNUserNotification`) when `availableRelease != nil`. | The auto-check currently has no visible result; this is what makes the feature feel like "it doesn't auto update." |
| 4 | **Harden `canReplaceRunningApp()`** to verify the bundle is actually replaceable (or pre-flight the move) and never call `NSApp.terminate` until replacement is guaranteed; on failure, keep the app running and report it. | Prevents the half-deleted / un-relaunched failure in the latent bug above. |
| 5 | Consider adopting **Sparkle**. | Handles signed appcasts, atomic replacement, and no-translocation update prompts out of the box; the hand-rolled installer is where all of these bugs live. |

---

## Verification notes

- Reproduction requires a translocated or non-writable copy. On a dev machine with a locally built/installed copy in a writable folder, the install path succeeds — which is why this was not caught in CI or by the maintainer.
- There is no test coverage for `canReplaceRunningApp()` beyond `AppInstaller.shellQuote` (`TokenMonTests/Update/ReleaseFeedTests.swift:79-82`). A unit test asserting the false branches would have surfaced the gate.
- `TOKENMON_AUDIT.md:54` still describes the updater as "notify-only (no download/install)" — it was written before the install feature landed (commit `a695220`, v1.6.3) and is now stale.

## Key references

| Location | Role |
|----------|------|
| `TokenMon/Features/Update/UpdateChecker.swift:94-118` | Install path + GitHub fallbacks |
| `TokenMon/Features/Update/AppInstaller.swift:25-34` | Translocation / writability gate |
| `TokenMon/Features/Update/AppInstaller.swift:72-97` | Post-exit replace-and-relaunch script |
| `TokenMon/Features/Shared/PollingLoop.swift` | 6-hour silent check loop |
| `TokenMon/Features/Settings/PreferencesView.swift:263-281` | Only remaining update UI |
| `.github/workflows/release.yml` | Ad-hoc signing without Developer ID |
| commit `86e695b` (v1.7.0) | Removed the menu-bar update row |
| commit `a695220` (v1.6.3) | Introduced in-place install |
