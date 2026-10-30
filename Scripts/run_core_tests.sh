#!/usr/bin/env bash
# Compiles every source under TokenMon/Core (the layer that imports no UI
# framework) plus the Grok parsers CoreTestsMain exercises, with
# Tests/Manual/CoreTestsMain.swift, and runs the result. The script fails with
# the missing path when a listed provider file has moved or been removed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/manual"
mkdir -p "$OUT"

PROVIDER_SOURCES=(
  TokenMon/Providers/Registry/MonitorProvider.swift
  TokenMon/UI/Components/ColorPalette.swift
  TokenMon/UI/Components/ProviderColors.swift
  TokenMon/Providers/Grok/GrokModels.swift
  TokenMon/Providers/Grok/GrokUsageClient.swift
  TokenMon/Providers/Grok/GrokUsageResponseParser.swift
  TokenMon/Providers/Grok/GRPCWebParser.swift
  TokenMon/Providers/Grok/GrokDailyUsageBuilder.swift
  TokenMon/Providers/Grok/GrokDailyUsagePreview.swift
  TokenMon/Providers/Grok/GrokExportService.swift
  Tests/Manual/CoreTestsMain.swift
)

SOURCES=()
while IFS= read -r source; do
  SOURCES+=("$source")
done < <(find "$ROOT/TokenMon/Core" -name '*.swift' | sort)
for source in "${PROVIDER_SOURCES[@]}"; do
  if [[ ! -f "$ROOT/$source" ]]; then
    echo "run_core_tests.sh: listed source is missing: $source" >&2
    echo "Update PROVIDER_SOURCES in Scripts/run_core_tests.sh." >&2
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
