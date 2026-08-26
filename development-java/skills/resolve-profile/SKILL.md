---
name: resolve-profile
description: >
  Loaded by /development:resolve-issue — not for direct use. The java repo
  type's driver rules for the resolve-issue conductor: which test gate is
  blessed and how to run it, what §4's version bump means here, and which review
  panel applies. The conductor detects the repo type at §1b and loads the
  matching `development-<repo_type>:resolve-profile` by name; a type with no
  profile keeps the conductor's generic behaviour.
disable-model-invocation: false
---

You are the **java resolve profile**. `/development:resolve-issue` loaded you at
its §1b step because this repo detected as `java`. You do not drive the run —
the conductor does. You supply the rules that are true of **this repo type and
no other**, so a Go or claude-plugin run never reads them, and so every java-side
edit lands here rather than in the shared conductor.

Every heading below is part of the profile contract (ARCHITECTURE.md, *Resolve
profile contract*). A heading with nothing to say says **none** — it is never
dropped, because the contract's readers key on the roster, not on presence.

## Gate

These are the §3 rules for this repo type. The conductor's generic bullet says
*the whole suite, never a subset*; what follows is how that is spelled here.

- **The whole suite is `./gradlew build test jacocoTestReport`** — the same
  command `development-java/agents/java-ci-fixer.md` already runs, so the gate
  and that agent cannot drift apart. Use the wrapper when it is present and the
  system `gradle` (`gradle build test jacocoTestReport`) only when it is not.
  `build` already implies `test`; naming both keeps this string identical to the
  agent's, so a reader comparing the two sees one command rather than two.
- **Judge pass/fail by the exit status, never by a `| tail` pipeline's.** The
  anchor writes `… 2>&1 | tail -80` because a fixer *reads* that output; this
  gate *branches* on it, and a pipeline's status is its last command's — always
  `tail`'s `0`. Capture the build's own status.
- **A missing JaCoCo plugin is not a red gate.** Gradle then fails with *Task
  'jacocoTestReport' not found* before a single test runs: drop that task, run
  `./gradlew build test`, and report that you did. Applying JaCoCo to the
  project is a separate change, never part of this story's fix pass.

  **Carry that forward to §6, because §6 will not work it out for itself.**
  open-pr's coverage precondition decides on the *diff* and the *report's
  absence*; it never checks whether the build could produce one, so where it
  asks at all it asks for a report this project cannot generate. Do **not**
  satisfy it by applying JaCoCo — that is the separate change above, now
  smuggled in — and do **not** push with `--no-verify`, which walks past the
  coverage floor.

  **Halt on the guard's own verdict, not on the absent tooling alone**, and
  read all **three** of its exits rather than the one you expect.
  `ensure-coverage-precondition.zsh --lang java` exits **0 — nothing owed**
  when the branch's diff carries no covered-language files, which is exactly the
  docs-or-config story a JaCoCo-less repo most often ships: the
  `coverage-floor-java` hook keys on that same `origin/<default>...HEAD` diff and
  no-ops when it carries no `*.java`/`*.kt` — its **own entry guard**, not
  pre-commit's `files:` filter, which #713 replaced because it over-fires on a
  brand-new branch push — so no report is wanted and there is
  nothing to stop over. Push normally.

  **Exit 0's other cause needs its own action, not a footnote.** The guard also
  exits 0 when the *report is already on disk*, and that is why you read its
  message rather than assume which zero you got. Do not talk yourself out of the
  branch on the grounds that JaCoCo writes `jacocoTestReport.xml` and JaCoCo is
  absent: the file can be committed, restored from a CI artifact, or left over
  from before JaCoCo was removed. So on the *report … found* message with
  `*.java`/`*.kt` in the diff, **confirm that report came from THIS tree's run**
  before treating the push as covered; a stale one has `diff-cover` measure this
  branch's new lines against a run that never saw them, which walks past the very
  coverage floor `--no-verify` would. If you cannot confirm it, treat it as the
  missing-tooling case: report and stop.

  **Exit 1 is the only exit that halts WITHOUT further checking** — that is what
  the exclusivity is about, not the action. Covered-language files present, and
  the report this build cannot generate is the one being asked for: report the
  missing coverage tooling and stop, with nothing left to establish. Exit 0's
  unconfirmable-report branch above reaches the same halt, but only *after* the
  confirmation it demands; reading the exclusivity as a claim about the *action*
  would discard that branch and push on a report no run in this tree produced.
  Exit **2** is your own bad invocation (a bad `--lang`, an unresolvable
  `--compare-branch`): it is neither verdict, so fix the command and re-run
  before deciding anything — never read *not 1* as *push*. Reading the halt as
  unconditional abandons stories that never owed a coverage report at all.
- **Gradle-only, Kotlin-DSL-only.** This family does not maintain Maven builds,
  so there is no `mvn` arm of this gate. A repo whose build is Groovy DSL still
  gates the same way; converting it is a separate concern, never smuggled into
  a story's fix pass.
- **`--gate-attest`: not applicable.** No attestable single-run runner of the
  `run-gate.zsh` shape (#981) ships for this type, so there is no `tree`
  identity to carry into the next round's `--resume`, and the loop re-runs the
  gate each round. Pass no `--gate-attest`: the flag is fail-closed on a
  mismatch, but a value that never came from a green gate is not a mismatch —
  it is a false attestation, and the loop would skip a re-run it never earned.
- **Epic verification (§E4) uses this same command, and needs more than it.**
  The conductor dereferences this heading at both §3 and E4, and E4 carries a
  **Java / Python app** bullet that applies here: it asks for the full build and
  suite **plus a real end-to-end exercise of the affected behaviour**, so
  integration regressions between an epic's children surface there. This command
  is the first half; read that bullet for the second. A green suite alone is not
  E4 evidence.

## Version bump

This is §4's procedure for this repo type. The conductor keeps the `### 4.`
heading as the anchor its reference files cross-reference; the rule lives here.

**none — *unless this repo also ships installable plugin content*.** Ordinarily
a java repo has no `<plugin>/` tree, so §4's subject does not exist and the
step is a no-op.

**Check rather than assume, because the premise is falsifiable.**
`claude-plugin` is a *fallback* repo type: a detected language always wins, so a
repo that is both a java codebase **and** ships plugin content detects as
`java` and loads *this* profile — not the plugin one. If the change touched a
`<plugin>/` tree carrying `.claude-plugin/plugin.json`, apply the conductor's §4
floor: bump that plugin's `plugin.json` **and** its matching
`.claude-plugin/marketplace.json` entry, or installs never see the change. Size
it by MAINTAINING.md's tiers — §4's floor supersedes nothing about sizing, and
deliberately states none of it.

An unconditional `none` here would *supersede* that floor rather than narrow it,
which is why it is written as a condition and not as a fact.

## Panel

**`/development-java:review`** — that skill is the panel, and its agents under
`development-java/agents/` carry their own severity bars. It is the same value
`review-dispatch.zsh plan` emits as `review_skill` (the script builds it as
`development-${repo_type}:review`), which is what §3.5 actually dispatches; this
heading **records** that, it does not override it.

This profile deliberately states **no** dimension list and **no** bar. Each of
those rules already has exactly one home, with the agent that applies it;
restating them here would mint the second statement that drifts (#1432). Read
them where they live.

## Fix-pass rules

**none** — no java-specific fix-pass rule has been established. #1502's read-out
is the evidence that would produce one; until it arrives, a rule here would
encode a guess as contract. This position has no dereference site today either
(#1506 decides which of the last three acquire one), so a rule written here
would be one no step is contracted to consult.

## Documentation expectations

**none** *beyond* the conductor's generic §2 same-PR user-docs step (#767),
which applies to every repo type and is not restated here. No java-specific
documentation duty has been established; #1502's read-out is where one would
come from.

## Residue

**none** — the residue procedure (#1435) in
`development/skills/resolve-issue/reference/residue.md` is repo-type-agnostic:
issue filing, labels and the dossier, with nothing java-specific in it. If a
type-specific rule ever exists, #1502's read-out is where it would come from.
