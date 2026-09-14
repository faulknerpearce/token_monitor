#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/manual"
mkdir -p "$OUT"

# Prefer the active developer directory (Xcode on CI after xcode-select).
# Hardcoding CommandLineTools/SDKs/MacOSX.sdk breaks when that SDK is newer
# than the Swift compiler on PATH.
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"

"$SWIFTC" -sdk "$SDK" -target "$TARGET" -parse-as-library \
  -o "$OUT/CoreTests" \
  "$ROOT/TokenMon/Features/Shared/AppLog.swift" \
  "$ROOT/TokenMon/Features/Grok/Usage/UsageModels.swift" \
  "$ROOT/TokenMon/Features/Grok/Usage/UsageClient.swift" \
  "$ROOT/TokenMon/Features/Grok/Usage/DailyUsageBuilder.swift" \
  "$ROOT/TokenMon/Features/Grok/History/ExportService.swift" \
  "$ROOT/TokenMon/Features/Shared/Percent.swift" \
  "$ROOT/TokenMon/Features/Shared/Format.swift" \
  "$ROOT/TokenMon/Features/Shared/JSON.swift" \
  "$ROOT/TokenMon/Features/Shared/ColorPalette.swift" \
  "$ROOT/TokenMon/Features/Shared/ISO8601.swift" \
  "$ROOT/TokenMon/Features/Shared/UsageError.swift" \
  "$ROOT/TokenMon/Features/Shared/AuthenticatedRequest.swift" \
  "$ROOT/TokenMon/Features/Shared/ProviderError.swift" \
  "$ROOT/Tests/Manual/CoreTestsMain.swift"

"$OUT/CoreTests"
