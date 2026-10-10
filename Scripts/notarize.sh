#!/usr/bin/env bash
# Usage: ./Scripts/notarize.sh <TokenMon.app | TokenMon.pkg> [keychain-profile]
#
# Submits the app (zipped in a temporary folder) or the signed pkg to the
# notary service, waits for the verdict, then staples and validates the ticket.
# On any verdict other than Accepted it prints the notary log and exits 1.
set -euo pipefail

TARGET="${1:?Path to .app or .pkg required}"
PROFILE="${2:-AC_PASSWORD}"

if [[ ! -e "$TARGET" ]]; then
  echo "Not found: $TARGET" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tokenmon-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

case "$TARGET" in
  *.app)
    SUBMISSION="$WORK/$(basename "${TARGET%.app}").zip"
    ditto -c -k --keepParent "$TARGET" "$SUBMISSION"
    ;;
  *.pkg)
    if ! pkgutil --check-signature "$TARGET" >/dev/null; then
      echo "Notarization needs a pkg signed with a Developer ID Installer identity: $TARGET" >&2
      exit 1
    fi
    SUBMISSION="$TARGET"
    ;;
  *)
    echo "Expected a .app or .pkg: $TARGET" >&2
    exit 1
    ;;
esac

RESULT="$WORK/submission.json"
echo "Submitting $(basename "$TARGET") to the notary service (profile: $PROFILE)…"
submit_status=0
xcrun notarytool submit "$SUBMISSION" \
  --keychain-profile "$PROFILE" \
  --wait \
  --output-format json >"$RESULT" || submit_status=$?

ID="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"

if [[ $submit_status -ne 0 || "$STATUS" != "Accepted" ]]; then
  echo "Notarization failed (status: ${STATUS:-unknown}, exit: $submit_status)." >&2
  cat "$RESULT" >&2 || true
  if [[ -n "$ID" ]]; then
    echo "Notary log for submission $ID:" >&2
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  fi
  exit 1
fi

echo "Accepted (submission $ID). Stapling…"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
