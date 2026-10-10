#!/usr/bin/env python3
"""Writes the line coverage in an .xcresult bundle as LCOV for Codecov.

Usage: Scripts/xccov_to_lcov.py <Test.xcresult> [source-root] > coverage.lcov

Reads `xcrun xccov view --archive --json`, keeps only files under
<source-root>/TokenMon/ (the app target only), and
emits paths relative to <source-root> (default: the current directory).
Exits non-zero when no app source has coverage data.
"""
import json
import os
import subprocess
import sys


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    result = sys.argv[1]
    root = os.path.realpath(sys.argv[2] if len(sys.argv) == 3 else os.getcwd())
    app_prefix = os.path.join(root, "TokenMon") + os.sep

    archive = json.loads(
        subprocess.check_output(["xcrun", "xccov", "view", "--archive", "--json", result])
    )

    records = 0
    out = sys.stdout
    for path in sorted(archive):
        real = os.path.realpath(path)
        if not real.startswith(app_prefix):
            continue
        lines = [entry for entry in archive[path] if entry.get("isExecutable")]
        if not lines:
            continue
        out.write("TN:\n")
        out.write(f"SF:{os.path.relpath(real, root)}\n")
        hit = 0
        for entry in lines:
            count = int(entry.get("executionCount", 0))
            hit += 1 if count > 0 else 0
            out.write(f"DA:{entry['line']},{count}\n")
        out.write(f"LF:{len(lines)}\nLH:{hit}\nend_of_record\n")
        records += 1

    if records == 0:
        print(f"No coverage for sources under {app_prefix} in {result}", file=sys.stderr)
        return 1
    print(f"Wrote LCOV for {records} source files", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
