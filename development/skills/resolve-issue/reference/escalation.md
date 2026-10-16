# Escalation

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

It carries the escalation terminal — the typed comment taken directly on an
`ESCALATE_CONFLICT` / `ESCALATE_AMBIGUOUS` exit, and on a `BUDGET_EXHAUSTED` /
`ESCALATE_NO_CONVERGENCE` of an attended run only once the interactive
extension, pointed at below, has not converged it. An unattended
`BUDGET_EXHAUSTED` / `ESCALATE_NO_CONVERGENCE` that the automatic grant does
not converge takes the clean stop below instead of the terminal.

Every `<!-- moved: … -->` block below is byte-identical to the text it was
carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit, and is what keeps this file honest.

## Escalation (any `ESCALATE_*` / `BUDGET_EXHAUSTED` status) — typed, no PR (#564)

Whether a human is present is §0a's determination, read from
`scripts/resolve-session.zsh`: `attended` takes the interactive arm, `unattended`
takes the autonomous arm and never prompts.

**An unattended run first tries an automatic grant (#2576).** On a
`BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE` exit in mode `unattended`, run
`build-escalation.zsh --status <status.json> --format verdict` before any
comment. On `"converging": true`, run `record-grant.zsh --work-dir <work-dir>
--status <status.json> --add 3 --source automatic`. Then, exactly as a human
grant does (step 5 in `reference/interactive/extension-grant.md`, with its
amendments in `reference/interactive/extension-ceiling.md`: the run's
`loop_args` and `--carry-accounting`), apply one fix pass and take the next
round's boundary, resuming with `--max-rounds` set to the ceiling
`record-grant.zsh` echoed, and never prompt. Another `BUDGET_EXHAUSTED` or
`ESCALATE_NO_CONVERGENCE` comes back to this paragraph, never to the extension's
steps 1–2. A failing verdict, and `record-grant.zsh`'s exit 3 (no headroom under
its cap of 2 × the original `--max-rounds`), both take the clean stop in the
next paragraph. An attended run never takes this branch; it gets the interactive
extension.

**An unattended run that cannot converge stops cleanly (#2579).** When that
automatic grant is not taken — the verdict fails, or `record-grant.zsh` exits 3
— a `BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE` exit in mode `unattended`
takes this clean stop instead of the terminal below. It ships nothing and keeps
the run resumable:

1. Push the branch as the bot and create no PR object, exactly as the
   terminal's step 1.
2. Write the marker beside the durable work-dir the run has been using
   (`clean-stop.zsh dir`, §3.5):

   ```bash
   "<skill-base-dir>/scripts/clean-stop.zsh" write --repo-dir <worktree> \
     --issue <N> --branch <branch> --run-id <this run's run_id> [--cap-reached]
   ```

   Pass `--cap-reached` exactly when `record-grant.zsh` exited 3. The marker's
   `convergence_failures` are the failing conditions, plus `cap`. An exit 2 is
   your own call: a passing verdict without `--cap-reached` was a grant, not a
   stop.
3. Build the comment with the clean-stop format, then post it and add
   `needs-human-decision` as the terminal's step 3 does:

   ```bash
   "<skill-base-dir>/scripts/build-escalation.zsh" --status <status.json> \
     --format clean-stop --issue <N> --branch <branch> \
     --compare-url "https://github.com/$REPO/tree/<branch>" \
     --work-dir <the marker's work_dir> [--cap-reached]
   ```

   It names the failing conditions (or the cap), the remaining blockers, the
   round history and class histogram, the branch and the attended resume
   command, `/development:resolve-issue <N> --resume`.
4. Emit the run's record with `clean_stop: true` and the marker's
   `convergence_failures` (`reference/telemetry.md` step 4), then stop.

`ESCALATE_CONFLICT` and `ESCALATE_AMBIGUOUS` on an unattended run, and every
escalation on an attended run, take the terminal below unchanged; their records
carry `clean_stop: false`.

<!-- moved: escalation-head -->
A bad escalation costs a human an afternoon; a good one costs two minutes. On
any `ESCALATE_*` / `BUDGET_EXHAUSTED` status, produce **one** decision-ready
issue comment and nothing else — **no PR, no auto-merge exposure**:

**Only those statuses escalate.** Exit 1/2 are operational, never escalations:
`STALE_FINDINGS` (exit 2) follows §3.5's *Each round* step 2 recover-and-re-invoke, and any
other exit 1/2 is reported in the conversation. Never build an escalation comment
from a status file the failed invocation did not write. **`CONVERGED_WITH_RESIDUE`
(exit 14) is not an escalation either** — it is the ending that *replaced* one,
so it opens the PR: take its residue branch above, never this terminal.
`build-escalation.zsh` deliberately has no arm for it, so a comment built from
one would fall through to the generic "exited without converging" wording and
tell the human the opposite of what happened.
<!-- /moved: escalation-head -->

Read the extension first when the run is interactive and the loop exited
`BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE`:
see `reference/interactive/extension.md` § Interactive extension (#562-resume)

<!-- moved: escalation-terminal -->
If the interactive extension ended in `CONVERGED`, skip the terminal below,
offer the suggestion-promotion phase under its own gate (as above — once per
story), and continue to §4. A `STALE_FINDINGS` exit never ends it — recover and resume as
step 5 says. If it ended in another **operational error**, it was already
reported in-session (step 5) — stop, with **no** typed comment. Otherwise (a
Stop / decline, or a `CONFLICT` / `AMBIGUOUS` exit):

1. **Push the branch as the bot** (so the diff-so-far is linkable) but **create
   no PR object** — a draft would trigger CI and defeat the local loop. Use the
   `open-pr` token mint + `git push`, then stop before `gh pr create`.
2. **Build the comment** from the loop's status JSON:

   ```bash
   "<skill-base-dir>/scripts/build-escalation.zsh" --status <status.json> \
     --issue <N> --branch <branch> --compare-url "https://github.com/$REPO/tree/<branch>"
   ```

   It emits the typed header, a summary, the round history, and 2–3 concrete
   options tailored to the escalation type.
3. **Post it and label**, idempotently (the repo's ensure-label idiom):

   ```bash
   gh label create needs-human-decision --color b60205 \
     --description "A review-loop escalation is waiting on a human decision" \
     2>/dev/null || true
   gh issue comment <N> --body-file <comment.md>
   gh issue edit <N> --add-label needs-human-decision
   ```

4. **Stop.** The human answers in the thread and re-runs
   `/development:resolve-issue <N>`; because step 2 (and the readiness gate) read
   the issue's **comments**, their decision becomes implementation context and
   the next run can converge. No PR exists until it does.
<!-- /moved: escalation-terminal -->

**Before step 4's stop, emit the run's record (#1226).** The terminal above
predates story-mode telemetry and sits in a byte-frozen span, so this is
recorded here: an escalation is one of the run's endings. Emit its single
`resolve-issue` record (`outcome: escalated`, the typed status in
`escalation_status`) before stopping. An operational-error stop with no typed
comment is an ending too, and emits `failed`. The procedure is
`reference/telemetry.md` step 4. It is never fatal, and an epic child that E3
drives emits from its own child run (`reference/epic-telemetry.md` step 2).
