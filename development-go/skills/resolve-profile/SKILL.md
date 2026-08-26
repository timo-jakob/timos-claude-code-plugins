---
name: resolve-profile
description: >
  Loaded by /development:resolve-issue — not for direct use. The go repo type's
  driver rules for the resolve-issue conductor: which test gate is blessed and
  how to judge its result, what §4's version bump means here, and which review
  panel applies. The conductor detects the repo type at §1b and loads the
  matching `development-<repo_type>:resolve-profile` by name; a type with no
  profile keeps the conductor's generic behaviour.
disable-model-invocation: false
---

You are the **go resolve profile**. `/development:resolve-issue` loaded you at
its §1b step because this repo detected as `go`. You do not drive the run — the
conductor does. You supply the rules that are true of **this repo type and no
other**, so a Java or claude-plugin run never reads them, and so every go-side
edit lands here rather than in the shared conductor.

Every heading below is part of the profile contract (ARCHITECTURE.md, *Resolve
profile contract*). A heading with nothing to say says **none** — it is never
dropped, because the contract's readers key on the roster, not on presence.

## Gate

These are the §3 rules for this repo type. The conductor's generic bullet says
*the whole suite, never a subset*; what follows is how that is spelled here.

- **The whole suite is `go build ./... && go test ./...`** — the same command
  `development-go/agents/go-ci-fixer.md` already runs to confirm a CI fix
  locally, so the gate and the fixer cannot drift apart. `./...` is the whole
  module; never narrow it to the changed package, which can pass while a
  dependent package no longer compiles.
- **Run the race detector too — `go test -race ./...` — unconditionally**, not
  only where you notice CI doing it: this family's own bootstrapped `test` task
  runs `-race` on every invocation, so a run that skips it gates more weakly
  than the repo's own tooling.
- **Judge pass/fail by the exit status, never by a `| tail` pipeline's.** A
  pipeline's status is its last command's — always `tail`'s `0` — so gating on
  `$?` of a `… | tail` reports green on a failed suite. Capture the suite's own
  status. The same rule is why `run-gate.zsh` exists for the plugin type; Go has
  no such runner, so the discipline is stated here instead.
- **A `-race` failure is a real defect, not gate flake**, and never silenced
  with a mutex you have not reasoned about. A race the **story's own change**
  introduced is an in-scope red like any other, so §3's rule applies unchanged:
  fix it. A race that also reproduces on `origin/main` is **pre-existing** —
  report it and **stop** per §3's abandon-and-report; do not fix it inside this
  story, and do not accept it as a red you ship past.

  `go-ci-fixer` escalates a race rather than fixing it, but do **not** import
  that rule wholesale: it repairs *someone else's* PR through a
  `resolved: false` envelope that does not exist here, where the racy code is
  usually the run's own §2 output.
- **This gate does not produce the coverage artifact §6's push may need.** A
  bootstrapped Go repo carries a `coverage-floor-go` pre-push hook that reads
  `coverage.xml`; the commands above never write one. What does is the repo's
  own `task test` — or, where `task` is not installed (go-task is a convenience
  the family depends on nowhere), the two commands it wraps:
  `go test -race ./... -coverprofile=coverage.out -covermode=atomic`, then
  `go run github.com/boumenot/gocover-cobertura@v1.3.0 < coverage.out > coverage.xml`.
  That second one is a **pinned `go run`, not an installed binary**, which is
  what makes the fallback usable on the bare machine it exists for. Do not
  install a toolchain to get past this: the run does not mutate the machine it
  runs on, and if neither form is available, report the missing exporter and
  stop rather than pushing into a rejection or reaching for `--no-verify`.

  **Do not produce it here, and not for every story.** §3 asks whether the
  suite is green, not whether the push will be accepted, and the hook **skips
  itself when the branch's diff touches no `*.go`** — so a report built for a
  docs-only story is pure waste, which `/development:open-pr` step 3 forbids on
  exactly that reasoning. Produce it at §6, and only when that diff does touch
  `*.go`. **Do not reach for open-pr's coverage guard to make that call:** its
  `--lang` arms are python, java and swift, and `--lang go` is a usage error,
  not a verdict. The hook's own trigger, above, is this type's condition.
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
  — and a Go service is that shape. So where this repo ships a runnable artifact
  — a service, or any `cmd/` binary — run that exercise too, against a binary you
  **build for it**: `go build -o <scratch>/<name> <main-package>`, outside the
  repo, since this Gate's own `go build ./...` compiles every package and writes
  **no** executable, so there is no "the built binary" left on disk for E4 to
  pick up.

  **The race rule above is correct at §3 and misfires here unless it is
  re-based.** It calls a race **pre-existing** when it also reproduces on
  `origin/main` — sound at §3, where the story branch is cut from `main` and the
  story's own change is not on it. At E4 that same test inverts, because
  `origin/main` by then **carries every child's merged diff**: a race a child
  introduced reproduces there **by construction**, reads as pre-existing, and is
  reported instead of halting — so the epic closes on the very race it added.
  **At E4, attribute the race against the epic's pre-epic baseline instead**,
  spelled as the commit on `main` immediately **before the epic's first child
  merged** (`git rev-parse <first-child-merge>^`) — never a merge-base against
  that child's branch, which this family's squash merge deleted.

  **Derive `<first-child-merge>` here, not by consulting another repo type's
  profile** — §1b loads exactly one profile by name, so a Go run never reads
  the kubernetes one and need not have that plugin installed at all. Take each
  child's merge commit (`gh pr view <child-pr> --json mergeCommit`), order them
  by **commit date**, and use the **earliest** — first by merge time, never the
  lowest issue number, which on an out-of-order epic yields a baseline already
  carrying other children's diffs.

  **Every child must yield a merge commit.** If any child's `mergeCommit` is
  null, or its PR cannot be identified, the earliest of the *rest* is not a
  pre-epic baseline — it may already carry the unresolved child's diff, so every
  regression that child introduced would read as pre-existing. That is an
  unresolvable baseline: take the halt below, naming the child that did not
  resolve, and never derive the baseline from the children that did.

  **Decide *present on the baseline* with §3's own verb, not from file
  history**: re-run `go test -race ./...` **at the baseline commit in a scratch
  worktree**, never by checking that commit out in the epic's tree. Nothing here
  turns on when a file was last edited — a race a child merely **exposed** in a
  file no child touched is still present on the baseline if it reproduces there.
  And **one green baseline run is not absence**: a race is nondeterministic, so
  re-run under **`-count=20`, never `-count=1`** — that one is the cache-buster
  and runs each test exactly once, which is the single clean pass this sentence
  just refused — and call **that race** absent only when it appears in **no
  iteration** of the run. Treat one clean pass as undecided rather than as
  proof.

  **Absence is a property of the RACE, never of the run.** Other races the
  baseline run reports, and any non-race failure it reports, do **not** make the
  race under attribution present: on a module already carrying an unrelated
  pre-existing race, no baseline run is ever wholly clean, and reading that as
  presence sorts the epic's own new race to case 1 and closes the epic on it.

  **Two race reports are the same race when the detector names the same pair of
  conflicting accesses** — the same variable or field, reached through the same
  two goroutine roots — **and never by the package path the report prints**,
  which a child moving or renaming a package changes without changing the race.
  Matched by path, an inherited race looks absent from the baseline and sorts to
  case 2, halting a delivered epic for a race it did not introduce.

  **A baseline run that does not COMPLETE is never read as producing no race**:
  a build failure, an unresolvable module graph, a panic before the tests run.
  That is an unestablishable baseline and takes the halt below — read as
  absence instead, every pre-existing race looks new and sorts to case 2,
  halting a delivered epic and blaming it for a race it inherited.

  **That baseline sorts a race into three, not two**, because `main` moves
  under a long epic just as it does under a kubernetes one.

  **Derive the changed-package set in IMPORT paths, or it can never intersect
  anything.** The union of the children's merged diffs — what this heading's
  other diff-shaped tests read at E4 — yields repo-relative **file** paths
  (`internal/db/db.go`), while `go list -deps` below emits **import** paths
  (`github.com/x/server/internal/db`). The two domains never meet. So take the
  set as the **packages containing those `*.go` files**, expressed as import
  paths — `go list ./<dir>` once per directory holding a changed `*.go` file,
  and **never `go list ./...`, which is recursive** and pulls in nested
  packages no child touched, so a stranger's race in one of them satisfies case
  2 and halts a delivered epic. Then intersect *that*. Compared raw, the
  intersection is empty by construction for every failing package, and every
  race a child introduced sorts to case 3 and closes the epic.

  **Two ordinary inputs need closing, or `go list` simply errors.** A directory
  a child **deleted**, and a changed directory holding **no Go package** at all
  (`docs/`, testdata): neither contributes a package, and neither is a failure —
  skip both. **Any other `go list` failure means the set could not be derived**,
  which is not an empty set: treat it exactly as an unestablishable baseline and
  take the halt below, rather than intersecting against a partial set and
  calling the misses case 3.

  1. **Present on the baseline** — genuinely pre-existing: **report it and let E5 close**,
     on the same reasoning §3 gives for a race it will not own.
  2. **Absent from the baseline, and the failing package is IN or transitively
     IMPORTS the changed-package set** — the epic's own:
     **halt E4, file it, and do NOT close the epic**.
  3. **Absent from the baseline, and the failing package neither is in nor
     imports that set** — it arrived on `main` from work outside this epic
     while the epic ran:
     **file it as an INDEPENDENT issue, name it in the E4 report, and let E5 close**,
     never as the epic's own. Halting here
     would strand a fully delivered epic on a stranger's race, which no re-run
     clears.

  **A run reports several races, and they sort into different cases.** Keep the
  halves apart exactly as the kubernetes sibling does: **every race's own filing
  action is performed whatever the others reached**, and **only the run's
  outcome takes the strictest terminal** — a single case-2 race halts E4 and
  leaves the epic open however many others sort to case 1 or 3, with the E4
  report naming each group. Take case 1's close on the first race you sort and
  you never reach case 2's halt for the second.

  **Read the direction from what `go test` actually prints.** It reports a
  failure under the **test binary's** package (`FAIL github.com/x/server`), and
  the ordinary E4 shape is a child changing a leaf package whose race surfaces
  in an unchanged consumer. So ask whether the **failing** package reaches the
  changed set — `go list -deps <failing package>` intersected with it — and not
  whether a changed package reaches the failure, which is the same edge read
  backwards and sorts that ordinary case to 3, closing the epic on its own race.
  A failing package that is **itself** in the changed set satisfies case 2
  trivially.

  **Cases 1 and 3 narrow the conductor's E4 rule** — its *file it, the epic
  stays open* governs the epic's own combined effect, which is case 2; a race
  the baseline places outside the epic is **reported (case 1) or filed as an
  independent issue (case 3)**, and the epic closes. **They narrow E5's *only
  after E4 is green* with it**: E4 is green **for closure purposes** when every
  race it reported sorts to case 1 or 3 and each case-3 race has been filed.

  **Only where there is a race to attribute.** A green `-race` run has none,
  **so a baseline that cannot be established is no halt and that epic closes**.
  Where
  there IS one, and no pre-epic baseline can be established at all — no first
  child merge is identifiable, the history was rewritten under it, **or `go test
  -race` cannot
  be run to completion at that commit** — **halt E4, report the race AND that no
  baseline could be established, and do NOT close the epic. Do not file it as
  the epic's own**, on evidence you have just said you lack, and
  **never fall back to `origin/main`**, whose whole defect at E4 is the
  paragraph above. The
  §3 sentence is left exactly as it stands — it is right where it runs, and only
  its reading at E4 is corrected here.

  **Close the enumeration rather than assuming the common case.**
  `<main-package>` is `./cmd/<name>` in the usual layout and plain `.` where
  `package main` sits at the module root, which is ordinary for a single-binary
  service — the trigger says *a service, or any `cmd/` binary*, so a recipe that
  only spells `./cmd/<name>` fails on half of what it triggers on. And **a module
  may ship several**: build and exercise **every** `cmd/` binary whose package
  graph includes a package the epic's children touched, and **name them in the
  E4 report**. Exercising one of three and reporting E4 green leaves the other
  two's integration untested while the report implies otherwise; where that set
  is too large to drive fully, exercise what you can and record which were
  smoke-run only, per the partial-exercise rule below. A module with **no**
  `package main` anywhere is the library-only exemption, stated observably.

  **The repo's shape decides whether the arm applies; what the epic's
  children touched decides only what to exercise through it.** One rule, so
  there is nothing to reconcile on the case that would otherwise read two ways:
  a module with a `cmd/` binary whose children touched only internal packages is
  still on the deployable arm — that code is compiled into the binary — so drive
  the binary down the subcommands that reach the changed behaviour, rather than
  reading "no subcommand was edited" as an exemption. Only a repo consumed
  **solely** as a library is exempt, and **a repo that is both takes the
  deployable arm**: being importable exempts nothing. A green
  suite alone is not E4 evidence for a deployable, and closing an epic on one
  would be the very integration blindness E4 exists to prevent.

  **And say so when no subcommand reaches the change** — the case this very
  rule creates, on a repo that is both: children touched internal packages the
  *library* half consumes and no command path exercises. Do not invent an
  exercise to fill the gap, and do not silently fall back to the suite. Smoke-run
  the binary (it still proves the module builds and starts with the change in
  it), and record in the E4 report that the exercise was **partial** and why, so
  the epic closes on evidence that is named for what it is.

## Version bump

This is §4's procedure for this repo type. The conductor keeps the `### 4.`
heading as the anchor its reference files cross-reference; the rule lives here.

**none — *unless this repo also ships installable plugin content*.** Ordinarily
a go repo has no `<plugin>/` tree, so §4's subject does not exist and the
step is a no-op.

**Check rather than assume, because the premise is falsifiable.**
`claude-plugin` is a *fallback* repo type: a detected language always wins, so a
repo that is both a go codebase **and** ships plugin content detects as
`go` and loads *this* profile — not the plugin one. If the change touched a
`<plugin>/` tree carrying `.claude-plugin/plugin.json`, apply the conductor's §4
floor: bump that plugin's `plugin.json` **and** its matching
`.claude-plugin/marketplace.json` entry, or installs never see the change. Size
it by MAINTAINING.md's tiers — §4's floor supersedes nothing about sizing, and
deliberately states none of it.

An unconditional `none` here would *supersede* that floor rather than narrow it,
which is why it is written as a condition and not as a fact.

## Panel

**`/development-go:review`** — that skill is the panel, and its agents under
`development-go/agents/` carry their own severity bars. It is the same value
`review-dispatch.zsh plan` emits as `review_skill` (the script builds it as
`development-${repo_type}:review`), which is what §3.5 actually dispatches; this
heading **records** that, it does not override it.

This profile deliberately states **no** dimension list and **no** bar. Each of
those rules already has exactly one home, with the agent that applies it;
restating them here would mint the second statement that drifts (#1432). Read
them where they live.

## Fix-pass rules

**none** — no go-specific fix-pass rule has been established. #1502's read-out
is the evidence that would produce one; until it arrives, a rule here would
encode a guess as contract. This position has no dereference site today either
(#1506 decides which of the last three acquire one), so a rule written here
would be one no step is contracted to consult.

## Documentation expectations

**none** *beyond* the conductor's generic §2 same-PR user-docs step (#767),
which applies to every repo type and is not restated here. No go-specific
documentation duty has been established; #1502's read-out is where one would
come from.

## Residue

**none** — the residue procedure (#1435) in
`development/skills/resolve-issue/reference/residue.md` is repo-type-agnostic:
issue filing, labels and the dossier, with nothing go-specific in it. If a
type-specific rule ever exists, #1502's read-out is where it would come from.
