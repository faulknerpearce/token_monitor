#!/usr/bin/env bash
# Compiles the host-free core sources with Tests/Manual/CoreTestsMain.swift and
# runs the result. The list below is every app source CoreTestsMain needs; the
# script fails with the missing path when a listed file has moved or been
# removed, so the list stays in sync with the tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/manual"
mkdir -p "$OUT"

CORE_SOURCES=(
  TokenMon/Features/Shared/Utilities/AppLog.swift
  TokenMon/Features/Shared/Networking/StaticURL.swift
  TokenMon/Features/Grok/Usage/UsageModels.swift
  TokenMon/Features/Grok/Usage/UsageClient.swift
  TokenMon/Features/Grok/Usage/DailyUsageBuilder.swift
  TokenMon/Features/Grok/History/ExportService.swift
  TokenMon/Features/Shared/Usage/Percent.swift
  TokenMon/Features/Shared/Utilities/Format.swift
  TokenMon/Features/Shared/Utilities/JSON.swift
  TokenMon/Features/Shared/UI/ColorPalette.swift
  TokenMon/Features/Shared/Utilities/ISO8601.swift
  TokenMon/Features/Shared/Networking/UsageError.swift
  TokenMon/Features/Shared/Networking/AuthenticatedRequest.swift
  TokenMon/Features/Shared/Networking/ProviderError.swift
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

# Uses the compiler and SDK of the active developer directory (Xcode on CI
# after xcode-select), so the SDK matches the Swift compiler on PATH even when
# CommandLineTools/SDKs/MacOSX.sdk is newer.
SWIFTC="${SWIFTC:-$(xcrun --find swiftc)}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"

"$SWIFTC" -sdk "$SDK" -target "$TARGET" -parse-as-library \
  -o "$OUT/CoreTests" \
  "${SOURCES[@]}"

"$OUT/CoreTests"
