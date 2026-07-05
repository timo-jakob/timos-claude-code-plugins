# Runbook — #567 live validation of the review loop on `ai-doc-organizer`

Goal: prove the autonomous story-delivery loop (epic #557) works on a real repo,
end to end, and produce the evidence #567 requires (three scenarios with run
links + measurements), then close the epic (E4/E5).

Test bed: `timo-jakob/ai-doc-organizer` (public, Python + web, Approver-configured).

---

## 0. Prerequisites (do these first — the test bed is behind the just-merged work)

1. **Driving machine on the new plugin versions.** The loop lives in the
   `development` plugin at **1.70.1** and the panels in `development-python`
   **1.19.0**. Update the installed marketplace so `/development:resolve-issue`
   runs the merged code, not a cached older copy:
   - refresh the family marketplace + plugins (the repo's own refresh path), or
     reinstall from the marketplace; confirm with the plugin version shown for
     `development`.
2. **Re-render `ai-doc-organizer`'s Approver policy** so it carries the #563
   *"Review dossier (when present)"* section (its current
   `.claude/approver-policy.md` predates it). On the driving machine, render
   `approver-policy-core.md.tmpl` + the Python overlay via the bootstrap
   `render.zsh` and commit the updated `.claude/approver-policy.md` to
   `ai-doc-organizer` (a normal PR there). Without this the Approver can't
   *reference dossier dimensions* — which is one of the things we're validating.
3. **Confirm the loop can run there:** `development-python:review` panel available,
   Approver App installed, branch protection + squash auto-merge on, CI green on
   `main`.
4. **Baseline for "CI minutes saved":** note the wall-clock/CI-minutes of one
   typical PR CI run on `ai-doc-organizer` (look at a recent merged PR's checks
   duration). Call it `CI_MIN`. Savings per story ≈ `(rounds_that_would_have_been_pushed - 1) * CI_MIN`,
   because pre-convergence rounds happen locally instead of on CI.

---

## 1. Scenario A — well-specified story → merged dossier PR

Pick a **small, real, testable** improvement to `ai-doc-organizer` (scan the repo
first). Shape of the issue (concrete acceptance, bounded scope, no deps):

> **Title:** `feat: <small concrete capability>`
> **Body:** motivation + **explicit acceptance criteria** (measurable), naming
> the file(s) in scope. Example candidates (confirm one fits the code):
>
> - add a `--dry-run` flag to a specific CLI entrypoint that prints planned moves
>   without writing;
> - validate a specific config field on load with a clear error message;
> - handle a named edge case (empty input dir) with a defined behavior + a test.

Run: `/development:resolve-issue <A#>` (loop on; **no** `--no-review`).

**Expect:** gate `READY` → implement → review loop **converges** (round 1, ideally)
→ **dossier PR** opened → Approver **APPROVE** → auto-merge on green CI.

**Capture:** rounds used; the PR's **Review dossier** section + hidden JSON;
whether the Approver's review text **references dossier dimensions** (a `clean`
lens lowering weight); CI minutes actually spent (should be one run, post-convergence).

---

## 2. Scenario B — underspecified story → `needs-refinement` halt

File a **deliberately vague** issue (no measurable acceptance, open scope):

> **Title:** `improve the organizer`
> **Body:** "It feels slow and the output is messy — please make it better and
> tidy things up, maybe add caching where it makes sense."

Run: `/development:resolve-issue <B#>`.

**Expect:** the **story-readiness gate** returns `NEEDS_REFINEMENT` → posts the
concrete refinement questions as an issue comment, applies the
**`needs-refinement`** label, and **stops** — **no branch, no PR**.

**Capture:** the refinement-questions comment (link); the label; confirm **no
branch and no PR** were created (`gh pr list`, `git branch -r`).

---

## 3. Scenario C — seeded blocker → at least one fix round → merged

Pick a story whose **naive first implementation predictably trips a reviewer**,
so round 1 has a blocker and round 2 clears it. Choose the flaw to match a panel
lens, e.g.:

> **Title:** `feat: add an endpoint/CLI that reads a user-supplied path`
> **Body:** testable acceptance, but the obvious implementation reads/join a
> request-supplied path directly → `python-security-reviewer` flags **path
> traversal** (CRITICAL) → fix adds the guard → round 2 converges.

(Alternatives that reliably draw a blocker: an N+1 loop the perf lens flags; a
new branch with no test the tests lens flags.)

Run: `/development:resolve-issue <C#>`.

**Expect:** round 1 → **blocker** (Critical/High) → fix pass → round 2 →
**CONVERGED** → dossier PR (dossier shows *blocker found & fixed* in that
dimension) → Approver → auto-merge.

**Capture:** the two-round history from the dossier; the fix diff; confirm the
loop opened the PR **only after** convergence (not on round 1).

---

## 4. (Optional but recommended) Scenario D — loop escalation → `needs-human-decision`

The motivation asks the **escalation path** be exercised too. Scenario B exercises
the *gate* escalation; this exercises the *loop* escalation (#564). Use a story
whose blocker **can't be cleared** by the fix passes (e.g. a genuinely conflicting
requirement, or a blocker that recurs) so the loop hits
`ESCALATE_NO_CONVERGENCE` or `BUDGET_EXHAUSTED`.

**Expect:** a **typed `needs-human-decision`** comment (type + round history +
2–3 options), branch pushed for the linkable diff, **no PR object**. Then reply in
the thread with a decision and **re-run** — confirm it **resumes and converges**
(the implement step re-reads the comment).

---

## 5. Measurements to record (for #567's final PR)

| Scenario | Issue | Outcome | PR / halt-comment | Rounds | CI runs | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| A well-specified | #… | merged w/ dossier | #… | | 1 | Approver referenced dims? |
| B underspecified | #… | needs-refinement | comment link | 0 | 0 | no branch/PR ✓ |
| C seeded blocker | #… | merged after fix round | #… | 2 | 1 | dossier shows found→fixed |
| D escalation (opt) | #… | needs-human-decision → resumed | comment link | | | resume converged ✓ |

- **CI minutes saved** = Σ over stories of `(rounds − 1) × CI_MIN` (rounds that
  would have hit CI in the old open-PR-immediately flow now run locally).
- **Approver + dossier**: quote the Approver's risk-register lines that cite
  dossier dimensions; note any `clean` lens that lowered weight.

---

## 6. Wrap-up — finish #567 and close the epic

1. Open **#567's final PR** (bot-authored): the measurements table above with the
   run links. (README's "how implemented" entry already merged in #599 — just drop
   the inline "validation remaining (#567)" caveat.) `Closes #567`.
2. After it merges → **E4 (holistic verification):** the epic's own gate — full
   `bats tests/` here **and** `/development-claude-plugin:test` driving
   `/development:resolve-issue` against a scratch target to confirm the wired flow
   end to end. (The ai-doc-organizer runs above ARE the real E4 for the loop's
   domain; the bats/test-skill pass guards the plugin repo itself.)
3. **E5:** `gh issue close 557` with the completed child checklist + the
   validation results table. Epic done.

---

## Guardrails for the session

- These are **live mutations of a public external repo** — go one scenario at a
  time, confirm each outcome before the next.
- Scenario B must leave **no branch/PR** — verify explicitly.
- Don't fabricate CI-minute figures; if a run's CI didn't execute, say so.
- If the loop isn't actually wired to run end to end from the skill (panel/fix are
  model-driven hooks), the driver is **you-as-Claude performing each hook step**;
  budget for that (5 Opus review agents per round × stories).
