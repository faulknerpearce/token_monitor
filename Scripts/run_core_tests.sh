#!/usr/bin/env bash
# Compiles the host-free core sources with Tests/Manual/CoreTestsMain.swift and
# runs the result. The list below is every app source CoreTestsMain needs; the
# script fails with the missing path when a listed file has moved or been
# removed, so the list cannot silently drift from the tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/manual"
mkdir -p "$OUT"

CORE_SOURCES=(
  TokenMon/Features/Shared/AppLog.swift
  TokenMon/Features/Shared/StaticURL.swift
  TokenMon/Features/Grok/Usage/UsageModels.swift
  TokenMon/Features/Grok/Usage/UsageClient.swift
  TokenMon/Features/Grok/Usage/DailyUsageBuilder.swift
  TokenMon/Features/Grok/History/ExportService.swift
  TokenMon/Features/Shared/Percent.swift
  TokenMon/Features/Shared/Format.swift
  TokenMon/Features/Shared/JSON.swift
  TokenMon/Features/Shared/ColorPalette.swift
  TokenMon/Features/Shared/ISO8601.swift
  TokenMon/Features/Shared/UsageError.swift
  TokenMon/Features/Shared/AuthenticatedRequest.swift
  TokenMon/Features/Shared/ProviderError.swift
  Tests/Manual/CoreTestsMain.swift
)

SOURCES=()
for source in "${CORE_SOURCES[@]}"; do
  if [[ ! -f "$ROOT/$source" ]]; then
    echo "run_core_tests.sh: listed core source is missing: $source" >&2
    echo "Update CORE_SOURCES in Scripts/run_core_tests.sh." >&2
    exit 1
  fi
  SOURCES+=("$ROOT/$source")
done

# Prefer the active developer directory (Xcode on CI after xcode-select).
# Hardcoding CommandLineTools/SDKs/MacOSX.sdk breaks when that SDK is newer
# than the Swift compiler on PATH.
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"

"$SWIFTC" -sdk "$SDK" -target "$TARGET" -parse-as-library \
  -o "$OUT/CoreTests" \
  "${SOURCES[@]}"

"$OUT/CoreTests"
