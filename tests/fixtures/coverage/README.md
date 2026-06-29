# Coverage Fixtures

Test fixtures for the Swift region-coverage parser (`parse-swift-coverage.py`).

## Files

- `swiftpm-llvmcov.json` — **Real** `llvm-cov export` output from a SwiftPM build, trimmed to one
  source file and two functions.
- `xcode-xccov.json` — **Synthetic** `xccov view --report --json` fixture (see note below).

---

## swiftpm-llvmcov.json

**Status: Real capture** (Swift 6.3.3 / Xcode toolchain, llvm-cov 3.0.1 format)

### How to regenerate

```bash
TMP=$(mktemp -d) && cd "$TMP"
xcrun swift package init --type library --name Demo

cat > Sources/Demo/Demo.swift <<'SWIFT'
public struct Demo {
    public func covered(_ x: Int) -> Int { x > 0 ? x : -x }
    public func uncovered(_ x: Int) -> Int { x * 2 }
}
SWIFT

cat > Tests/DemoTests/DemoTests.swift <<'SWIFT'
import XCTest; @testable import Demo
final class DemoTests: XCTestCase {
    func testCovered() { XCTAssertEqual(Demo().covered(-3), 3) }
}
SWIFT

xcrun swift test --enable-code-coverage

BIN=$(xcrun swift build --show-bin-path)
PROF="$BIN/codecov/default.profdata"
XCTEST=$(find "$BIN" -name '*.xctest' -print -quit)

xcrun llvm-cov export -instr-profile "$PROF" "$XCTEST/Contents/MacOS/DemoPackageTests" \
    2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
demo_src = 'Sources/Demo/Demo.swift'
trimmed = {'data': [], 'type': data['type'], 'version': data['version']}
for entry in data['data']:
    fns = [f for f in entry.get('functions', []) if any(demo_src in p for p in f['filenames'])]
    files = [f for f in entry.get('files', []) if demo_src in f['filename']]
    trimmed['data'].append({'files': files, 'functions': fns, 'totals': entry.get('totals', {})})
print(json.dumps(trimmed, indent=2))
" > swiftpm-llvmcov.json
```

### llvm-cov key shape

Top-level keys: `data`, `type`, `version`

`data[].functions[]` entry keys:

```text
branches, count, filenames, mcdc_records, name, regions
```

- `name` — Swift mangled symbol (e.g. `$s4DemoAAV7coveredyS2iF`)
- `count` — total execution count across all regions
- `regions` — array of 8-element arrays: `[startLine, startCol, endLine, endCol, count, fileID, expandedFileID, kind]`
- `filenames` — array of source paths

`data[].files[]` entry keys:

```text
branches, expansions, filename, mcdc_records, segments, summary
```

- `segments` — array of 6-element arrays: `[line, col, count, hasCount, isRegionEntry, isGapRegion]`
- `summary.regions` — `{count, covered, notcovered, percent}`
- `summary.functions` — `{count, covered, percent}`
- `summary.lines` — `{count, covered, percent}`

---

## xcode-xccov.json

**Status: Synthetic** — no Xcode `.xcresult` bundle is available in the CLI environment used to
capture the SwiftPM fixture. This fixture was hand-authored to match the documented
`xcrun xccov view --report --json` output shape.

Pending: replace with a real capture from an Xcode project build. See epic #462.

### Real capture command (when an xcresult is available)

```bash
xcrun xccov view --report --json /path/to/Build/Products/Debug/Demo.xcresult \
    > xcode-xccov.json
```

Then trim to one target / one file / two functions.

### xccov key shape

Top-level key: `targets`

`targets[].files[].functions[]` entry keys:

```text
name, lineNumber, executableLines, coveredLines, lineCoverage, executionCount
```

- `name` — human-readable Swift function signature (e.g. `covered(_:)`)
- `lineNumber` — 1-based line number of function definition
- `executableLines` — total executable lines in function
- `coveredLines` — lines executed during test run
- `lineCoverage` — `coveredLines / executableLines` (float 0.0–1.0)
- `executionCount` — how many times the function was called
