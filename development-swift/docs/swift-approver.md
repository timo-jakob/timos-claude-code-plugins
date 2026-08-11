# Swift Approver — runtime behaviour

Operator-facing reference for the `swift-approver` agent. The
implementation lives in
[`agents/swift-approver.md`](../agents/swift-approver.md).

**Shared behaviour is documented once, not three times.** The Swift
Approver runs the same procedure, invocation contract, output schema,
hard-fail conditions, refusal patterns, and cost profile as the Python
Approver — read
[`development-python/docs/python-approver.md`](../../development-python/docs/python-approver.md)
for all of that (including the epic-#476 local-invocation model: the
`/development-swift:approve` skill mints the Approver App token from
your Keychain and the verdict posts as `claude-approver-<owner>[bot]`).
This file records only the **Swift deltas**:

## What differs from the Python Approver

- **Cheap local checks** (procedure step 5): `swift-format lint
  --strict` + `swiftlint lint --strict --quiet` on changed `.swift`
  files, and a `swift build` smoke when the toolchain is present —
  instead of ruff / `pytest --collect-only`.
- **API stability** (step 4): no Swift gate exists yet (a
  `swift-api-digester`-based check is a future addition). The agent
  records the informational "gate not configured" finding and verifies
  no-public-break directly via LSP on touched `public`/`open` symbols.
- **Test-quality detection** (step 7) reads XCTest patterns
  (`XCTAssertTrue(true)` filler, stubbed-unit tests, `@Disabled`-less
  equivalents) rather than pytest ones.
- **The risk register is fed by the review dimensions (#448).** Step
  10 walks the seven lenses of the standalone
  `/development-swift:review` panel — bugs, security, performance,
  code quality, tests, swift6_compliance, resilience — one bounded
  pass each, and emits at most the top 3 risks overall, each tagged
  `"dimension": "<lens>"` in the hidden JSON block. `dimension` is
  **not a closed enum**: the lens list tracks the panel's dimension
  table, so a new dimension becomes a new lens — and a legal value —
  on arrival (#1147). The review skill itself stays a standalone
  deep-dive capability (owner decision on #448); the Approver borrows
  its lenses for breadth at synthesis time, not its depth.
- **`suggested_agent` mapping** targets the Swift agents:
  `test_quality`/`coverage` → `swift-coverage-improver`, Sonar
  baseline findings → `swift-sonar-triage`, CodeQL / Code Scanning
  baseline alerts → `swift-code-scanning-triage`; semgrep has no Swift
  rows (deferred, #443).
- **Security guard (#457)** applies as everywhere: a PR closing a
  security BLOCKER/CRITICAL by suppression is never approved.

## Wiring status

Everything the Swift Approver needs ships with epic #297: this agent,
the `/development-swift:approve` skill (user-triggered, posts the
verdict — it takes an optional PR number and nothing else, since the
`--dry-run` flag is Go-only today), and the Swift
`approver-policy.md` template rendered by
`/development:bootstrap --claude-approver true` (Swift is an
Approver-capable language as of #448). There is no CI wiring to do —
epic #476 made local invocation the only path on every language.
