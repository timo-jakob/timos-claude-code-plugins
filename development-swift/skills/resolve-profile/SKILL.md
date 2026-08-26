---
name: resolve-profile
description: >
  Loaded by /development:resolve-issue — not for direct use. The swift repo
  type's driver rules for the resolve-issue conductor: which test gate is
  blessed for each build system, what §4's version bump means here, and which
  review panel applies. The conductor detects the repo type at §1b and loads the
  matching `development-<repo_type>:resolve-profile` by name; a type with no
  profile keeps the conductor's generic behaviour.
disable-model-invocation: false
---

You are the **swift resolve profile**. `/development:resolve-issue` loaded you
at its §1b step because this repo detected as `swift`. You do not drive the run
— the conductor does. You supply the rules that are true of **this repo type and
no other**, so a Go or claude-plugin run never reads them, and so every
swift-side edit lands here rather than in the shared conductor.

Every heading below is part of the profile contract (ARCHITECTURE.md, *Resolve
profile contract*). A heading with nothing to say says **none** — it is never
dropped, because the contract's readers key on the roster, not on presence.

## Gate

These are the §3 rules for this repo type. The conductor's generic bullet says
*the whole suite, never a subset*; what follows is how that is spelled here.

- **SwiftPM — the whole suite is `swift build && swift test
  --enable-code-coverage`** — the same command
  `development-swift/agents/swift-ci-fixer.md` already runs, so the gate and
  that agent cannot drift apart.
- **Judge pass/fail by the exit status, never by a `| tail` pipeline's.** The
  anchor writes `… 2>&1 | tail -80` because a fixer *reads* that output; this
  gate *branches* on it, and a pipeline's status is its last command's — always
  `tail`'s `0`. Capture the build's own status.
- **Xcode project — `xcodebuild [-workspace <name>.xcworkspace] -scheme <scheme>
  -destination <dest> -enableCodeCoverage YES build test`**, discovering the
  scheme with
  `xcodebuild -list`. Which of the two applies is a property of the repo, not a
  choice: a `Package.swift` at the root means SwiftPM. **Close the enumeration
  rather than assuming the common case** — two ordinary shapes fall outside a
  bare `-scheme … -destination 'platform=macOS'`:
  - a repo whose only container is an `.xcworkspace` needs `-workspace`, or
    `xcodebuild` resolves the wrong container (or no scheme at all);
  - an iOS/watchOS-only target has **no** macOS destination, so a hardcoded
    `platform=macOS` cannot resolve. Take the destination from the scheme's own
    supported platforms (`xcodebuild -showdestinations`).

  A failure to *resolve* a scheme or destination is **neither green nor §3's
  red**: the change is not at fault, so do not consolidate, commit or open a PR
  on it — **report the unresolved scheme/destination and stop** (interactive:
  ask the user which to use). That is a halt-and-report, distinct from §3's
  abandon-the-PR arm.
- **This gate does not produce the coverage artifact §6's push may need.** A
  bootstrapped Swift repo carries a `coverage-floor-swift` pre-push hook that
  reads `coverage.lcov`; neither command above writes one. Both arms above do
  leave **profdata** — SwiftPM's `--enable-code-coverage` under `.build/`, the
  Xcode arm's `-enableCodeCoverage YES` under DerivedData — and
  `xcrun llvm-cov export -format=lcov` turns that into `coverage.lcov`.

  **Producing it is §6's decision, not this gate's — do not run it here.**
  `/development:open-pr` step 3 owns that call and forbids eagerly running the
  whole suite "just so the push succeeds", because the hook skips itself when
  the branch's diff touches no Swift. This bullet exists so §6 knows what to
  reach for, and so the gate's own commands leave profdata for it to export
  rather than forcing a second full run.
- **`--gate-attest`: not applicable.** No attestable single-run runner of the
  `run-gate.zsh` shape (#981) ships for this type, so there is no `tree`
  identity to carry into the next round's `--resume`, and the loop re-runs the
  gate each round. Pass no `--gate-attest`: the flag is fail-closed on a
  mismatch, but a value that never came from a green gate is not a mismatch —
  it is a false attestation, and the loop would skip a re-run it never earned.
- **Epic verification (§E4) uses this heading's gate unchanged — and on an app
  or service, more than it.** The conductor dereferences this heading at both §3
  and E4. E4's bullet list names no arm for this *language*, which is an absence,
  **not a licence**: the reason its **Java / Python app** bullet asks for "a real
  end-to-end exercise of the affected behaviour" on top of the suite is the
  **shape** of the repo — a deployable thing whose children can integrate badly
  — and a shipped Swift app or service is that shape. So where this repo ships a
  runnable artifact — an app, or a server-side service — rather than a library
  consumed only by other code, run that exercise too. **Do not read "package" as
  the exempt side**: every SwiftPM repo is a package, deployables included, so
  that word names the distribution shape and never the repo's. A green suite
  alone is not E4 evidence for either, and closing an epic on one would be the
  very integration blindness E4 exists to prevent.

## Version bump

This is §4's procedure for this repo type. The conductor keeps the `### 4.`
heading as the anchor its reference files cross-reference; the rule lives here.

**none — *unless this repo also ships installable plugin content*.** Ordinarily
a swift repo has no `<plugin>/` tree, so §4's subject does not exist and the
step is a no-op.

**Check rather than assume, because the premise is falsifiable.**
`claude-plugin` is a *fallback* repo type: a detected language always wins, so a
repo that is both a swift codebase **and** ships plugin content detects as
`swift` and loads *this* profile — not the plugin one. If the change touched a
`<plugin>/` tree carrying `.claude-plugin/plugin.json`, apply the conductor's §4
floor: bump that plugin's `plugin.json` **and** its matching
`.claude-plugin/marketplace.json` entry, or installs never see the change. Size
it by MAINTAINING.md's tiers — §4's floor supersedes nothing about sizing, and
deliberately states none of it.

An unconditional `none` here would *supersede* that floor rather than narrow it,
which is why it is written as a condition and not as a fact.

## Panel

**`/development-swift:review`** — that skill is the panel, and its agents under
`development-swift/agents/` carry their own severity bars. It is the same value
`review-dispatch.zsh plan` emits as `review_skill` (the script builds it as
`development-${repo_type}:review`), which is what §3.5 actually dispatches; this
heading **records** that, it does not override it.

This profile deliberately states **no** dimension list and **no** bar. Each of
those rules already has exactly one home, with the agent that applies it;
restating them here would mint the second statement that drifts (#1432). Read
them where they live.

## Fix-pass rules

**none** — no swift-specific fix-pass rule has been established. #1502's
read-out is the evidence that would produce one; until it arrives, a rule here
would encode a guess as contract. This position has no dereference site today
either (#1506 decides which of the last three acquire one), so a rule written
here would be one no step is contracted to consult.

## Documentation expectations

**none** *beyond* the conductor's generic §2 same-PR user-docs step (#767),
which applies to every repo type and is not restated here. No swift-specific
documentation duty has been established; #1502's read-out is where one would
come from.

## Residue

**none** — the residue procedure (#1435) in
`development/skills/resolve-issue/reference/residue.md` is repo-type-agnostic:
issue filing, labels and the dossier, with nothing swift-specific in it. If a
type-specific rule ever exists, #1502's read-out is where it would come from.
