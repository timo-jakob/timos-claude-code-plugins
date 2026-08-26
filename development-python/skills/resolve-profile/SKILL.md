---
name: resolve-profile
description: >
  Loaded by /development:resolve-issue — not for direct use. The python repo
  type's driver rules for the resolve-issue conductor: which test gate is
  blessed and how to run it, what §4's version bump means here, and which review
  panel applies. The conductor detects the repo type at §1b and loads the
  matching `development-<repo_type>:resolve-profile` by name; a type with no
  profile keeps the conductor's generic behaviour.
disable-model-invocation: false
---

You are the **python resolve profile**. `/development:resolve-issue` loaded you
at its §1b step because this repo detected as `python`. You do not drive the run
— the conductor does. You supply the rules that are true of **this repo type and
no other**, so a Go or claude-plugin run never reads them, and so every
python-side edit lands here rather than in the shared conductor.

Every heading below is part of the profile contract (ARCHITECTURE.md, *Resolve
profile contract*). A heading with nothing to say says **none** — it is never
dropped, because the contract's readers key on the roster, not on presence.

## Gate

These are the §3 rules for this repo type. The conductor's generic bullet says
*the whole suite, never a subset*; what follows is how that is spelled here.

- **The whole suite is `pytest --cov --cov-report=xml --tb=short`** — the same
  command `development-python/agents/python-ci-fixer.md` already runs, so the
  gate and that agent cannot drift apart. **Never** narrow it to
  `pytest tests/unit`: a subset can pass while the change breaks integration
  tests whose fixtures exercise it, and that stays invisible until CI, after the
  bot PR is open (#604).
- **Run it through the repo's own interpreter, not the ambient one** — the same
  `<repo>/.venv/bin/python -m pytest` form that agent uses, with `PYTHONPATH`
  set as it shows. Resolve `<repo>` in this order and say which one you used:
  the **main clone** (from `git rev-parse --git-common-dir`, since a fresh
  worktree normally has no `.venv` of its own), else the worktree itself, else
  fall back to a bare `pytest`. Getting this wrong produces import/collection
  errors that read as a red gate on a change that is fine.
- **Judge pass/fail by the exit status, never by a `| tail` pipeline's.** The
  anchor writes `… 2>&1 | tail -80` because a fixer *reads* that output; this
  gate *branches* on it, and a pipeline's status is its last command's — always
  `tail`'s `0`. Capture the suite's own status.
- **A missing `pytest-cov` is not a red gate.** `--cov` then fails with
  *unrecognized arguments* before a single test runs: drop the coverage flags,
  run the suite, and report that you did. Adding the plugin is a separate
  change, never part of this story's fix pass.

  **Carry that forward to §6, because §6 will not work it out for itself.**
  open-pr's coverage precondition decides on the *diff* and the *report's
  absence*; it never checks whether the toolchain could produce one, so where it
  asks at all it asks for a report this repo cannot generate. Do **not** satisfy
  it by installing `pytest-cov` — that is the separate change above, now
  smuggled in — and do **not** push with `--no-verify`, which walks past the
  coverage floor.

  **Halt on the guard's own verdict, not on the absent tooling alone**, and
  read all **three** of its exits rather than the one you expect.
  `ensure-coverage-precondition.zsh --lang python` exits **0** for **two
  different reasons**, and only one of them is *nothing owed*: the branch's diff
  carries no covered-language files — exactly the docs-or-config story a
  `pytest-cov`-less repo most often ships, where the `coverage-floor` hook keys
  on that same `origin/<default>...HEAD` diff and no-ops when it carries no
  `*.py` (its **own entry guard**, not pre-commit's `files:` filter, which #713
  replaced because it over-fires on a brand-new branch push) — **or**
  `coverage.xml` is already on disk.
  The second is reachable here even without `pytest-cov` (plain `coverage.py`, a
  committed report, a CI artifact), so **read the guard's message rather than
  assuming which zero you got**: on *no covered-language files*, push normally;
  on *report already present* with `*.py` in the diff, confirm that report came
  from **this** tree's run before treating the push as covered — a stale one
  measures this branch's new lines against a run that never saw them, walking
  past the same coverage floor `--no-verify` would. If you cannot confirm it,
  treat it as the missing-tooling case: report and stop.

  **Exit 1 is the only exit that halts WITHOUT further checking** — that is what
  the exclusivity is about, not the action. Covered-language files present and
  no report: report the missing coverage tooling and stop, with nothing left to
  establish. Exit 0's unconfirmable-report branch above reaches the same halt,
  but only *after* the confirmation it demands; reading the exclusivity as a
  claim about the *action* would discard that branch and push on a stale report.
  Exit **2** is your own bad invocation (a bad `--lang`, an unresolvable
  `--compare-branch`): it is neither verdict, so fix the command and re-run
  before deciding anything — never read *not 1* as *push*.
  Reading the halt as unconditional abandons stories that never owed a coverage
  report at all.
- **`--gate-attest`: not applicable.** No attestable single-run runner of the
  `run-gate.zsh` shape (#981) ships for this type, so there is no `tree`
  identity to carry into the next round's `--resume`, and the loop re-runs the
  gate each round. Pass no `--gate-attest`: the flag is fail-closed on a
  mismatch, but a value that never came from a green gate is not a mismatch —
  it is a false attestation, and the loop would skip a re-run it never earned.
- **Epic verification (§E4) uses this same command, and needs more than it.**
  The conductor dereferences this heading at both §3 and E4, and E4 carries a
  **Java / Python app** bullet that applies here: it asks for the whole suite
  **plus a real end-to-end exercise of the affected behaviour**, so integration
  regressions between an epic's children surface there. This command is the
  first half; read that bullet for the second. A green suite alone is not E4
  evidence.

## Version bump

This is §4's procedure for this repo type. The conductor keeps the `### 4.`
heading as the anchor its reference files cross-reference; the rule lives here.

**none — *unless this repo also ships installable plugin content*.** Ordinarily
a python repo has no `<plugin>/` tree, so §4's subject does not exist and the
step is a no-op.

**Check rather than assume, because the premise is falsifiable.**
`claude-plugin` is a *fallback* repo type: a detected language always wins, so a
repo that is both a python codebase **and** ships plugin content detects as
`python` and loads *this* profile — not the plugin one. If the change touched a
`<plugin>/` tree carrying `.claude-plugin/plugin.json`, apply the conductor's §4
floor: bump that plugin's `plugin.json` **and** its matching
`.claude-plugin/marketplace.json` entry, or installs never see the change. Size
it by MAINTAINING.md's tiers — §4's floor supersedes nothing about sizing, and
deliberately states none of it.

An unconditional `none` here would *supersede* that floor rather than narrow it,
which is why it is written as a condition and not as a fact.

## Panel

**`/development-python:review`** — that skill is the panel, and its agents under
`development-python/agents/` carry their own severity bars. It is the same value
`review-dispatch.zsh plan` emits as `review_skill` (the script builds it as
`development-${repo_type}:review`), which is what §3.5 actually dispatches; this
heading **records** that, it does not override it.

This profile deliberately states **no** dimension list and **no** bar. Each of
those rules already has exactly one home, with the agent that applies it;
restating them here would mint the second statement that drifts (#1432). Read
them where they live.

## Fix-pass rules

**none** — no python-specific fix-pass rule has been established. #1502's
read-out is the evidence that would produce one; until it arrives, a rule here
would encode a guess as contract. This position has no dereference site today
either (#1506 decides which of the last three acquire one), so a rule written
here would be one no step is contracted to consult.

## Documentation expectations

**none** *beyond* the conductor's generic §2 same-PR user-docs step (#767),
which applies to every repo type and is not restated here. No python-specific
documentation duty has been established; #1502's read-out is where one would
come from.

## Residue

**none** — the residue procedure (#1435) in
`development/skills/resolve-issue/reference/residue.md` is repo-type-agnostic:
issue filing, labels and the dossier, with nothing python-specific in it. If a
type-specific rule ever exists, #1502's read-out is where it would come from.
