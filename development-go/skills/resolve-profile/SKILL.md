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
