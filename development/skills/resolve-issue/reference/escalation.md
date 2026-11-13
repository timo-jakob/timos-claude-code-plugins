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
`build-escalation.zsh --status <status.json> --format verdict --work-dir
<work-dir>` before any comment. On `"converging": true`, run `record-grant.zsh --work-dir <work-dir>
--status <status.json> --add 3 --source automatic`. Then, exactly as a human
grant does (step 5 in `reference/interactive/extension-grant.md`, with its
amendments in `reference/interactive/extension-ceiling.md`: the run's
`loop_args` and `--carry-accounting`), apply one fix pass and take the next
round's boundary, resuming with `--max-rounds` set to the ceiling
`record-grant.zsh` echoed, and never prompt. Another `BUDGET_EXHAUSTED` or
`ESCALATE_NO_CONVERGENCE` comes back to this paragraph, never to the extension's
steps 1–2. A failing verdict, and `record-grant.zsh`'s exit 3 (no headroom under
its cap of 2 × the original `--max-rounds`), both take the clean stop below,
unless the failing verdict buys the self-guided retry in the next paragraph. An
attended run never takes this branch; it gets the interactive extension.

**A stuck run with a falling trend gets one self-guided retry (#3076).** When
the verdict fails and its `self_guided.eligible` is `true`, the run does not
stop. That holds only when `stuck` is the one failure, the trend is falling, no
Critical is open or carried, and every carried blocker has a `suggested_fix`.
Instead:

1. Build the automatic guidance into a file, before the grant's ledger line
   makes the verdict refuse it as `already-retried`:
   `build-escalation.zsh --status <status.json> --format guidance --work-dir
   <work-dir>`. It holds each carried blocker's `suggested_fix` and evidence,
   tagged `<!-- review-loop-guidance-source: automatic -->`. For a parked
   blocker it asks the fix pass to re-judge the park against the story's
   acceptance criteria and its base behaviour.
2. Record the grant:
   `record-grant.zsh --work-dir <work-dir> --status <status.json> --add 3
   --source automatic --guided`. Its exit 3 takes the clean stop with
   `--cap-reached`, and its exit 4 (the ledger already holds a guided grant)
   takes the clean stop. Either way the guidance is never posted.
3. On its exit 0, post the file on the issue with `gh issue comment <N>
   --body-file`, as a human's guidance is posted (step 4 in
   `reference/interactive/extension.md`). Apply one fix pass with that comment
   as fix context, then resume exactly as the automatic grant above does.

The retry is once per run. A second `stuck` after it finds the guided line in
the ledger and is refused as `already-retried`, so the run takes the clean stop
below as it always did. Every review-loop record the run emits after the retry
carries `auto_guided_retry: true`, and its `outcome` is the retry's outcome.

**An unattended run that cannot converge stops cleanly (#2579).** When that
automatic grant is not taken — the verdict fails with no self-guided retry left
to take, or `record-grant.zsh` exits 3 — a `BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE` exit in mode `unattended`
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

**A chain step's clean stop goes up to its root (#3077).** In a human-started
run the step takes the same clean stop, and its `stopped` verdict also carries
the `escalation` payload (ARCHITECTURE.md, *Step verdict contract*). The step
itself never asks: its root does, when the root is attended.

- **The step builds the payload** after the marker is written, from the marker
  (the `marker` path `clean-stop.zsh dir` prints), the marker's status file and
  the convergence verdict:

  ```bash
  "<skill-base-dir>/scripts/build-escalation.zsh" --status <the marker's status_file> \
    --format verdict --work-dir <the marker's work_dir> > <scratch_dir>/step-<N>-convergence.json
  jq -n --slurpfile m <the marker> --slurpfile s <the marker's status_file> \
    --slurpfile c <scratch_dir>/step-<N>-convergence.json '{status: $m[0].status,
      trigger: $m[0].convergence_failures, trend: $c[0].trend, series: $c[0].series,
      carried_blockers: [ ((($s[0].round_changelists // [])[-1] // {}).blocking // [])[]
        | select(.non_converging == true and .possible_false_trip != true)
        | {title, file, line, dimension, severity: (.severity // .priority), suggested_fix} ],
      work_dir: $m[0].work_dir, status_file: $m[0].status_file}
    | .proposal = {recommend: (if $c[0].converging then "grant" else "guidance" end), add: 3,
        guidance: ([ .carried_blockers[] | select((.suggested_fix // "") | tostring | test("\\S"))
          | "- \(.title) (`\(.file):\(.line)`): \(.suggested_fix)" ]
          | if length == 0 then null else join("\n") end)}' > <scratch_dir>/step-<N>-escalation.json
  ```

  `trigger` is the marker's `convergence_failures`. `proposal.recommend` is the
  option a direct attended run recommends: `grant` only when the convergence
  verdict passes (the automatic grant hit its cap), `guidance` otherwise.
  `proposal.guidance` drafts guidance from the carried blockers' suggested
  fixes, `null` when none has one.
- **The root's mode decides what happens next.** The root resolves its own mode
  once, before its first dispatch, with `scripts/resolve-session.zsh --inferred
  attended`. An unattended root takes the `stopped` arm as before, and the chain
  stops. An attended root runs the interactive extension
  (`reference/interactive/extension.md`) on the step's kept state, with the
  same options and recommendation as a direct attended run:
  1. Show `build-escalation.zsh --status <escalation.status_file> --format
     summary --grants <grants>`, where `grants` counts this issue's grants in
     this run, starting at 0.
  2. Ask the extension's step 2 question with AskUserQuestion, marking
     `proposal.recommend`'s option recommended. A non-null `proposal.guidance`
     is offered as the draft guidance. A question the human asks is answered
     and the question re-asked, as step 3 says.
  3. On a grant, post any guidance as step 4 says, then record it:
     `record-grant.zsh --work-dir <escalation.work_dir> --status
     <escalation.status_file> --add 3`. Remove the `needs-human-decision` label
     the clean stop added, delete the step's old verdict file, write a fresh
     handoff for the same issue with the same `scratch_dir`, `chained_from` and
     `parent_run_id`, `start_at: "0a"`, `after: null` and `resume:
     "clean_stop"`, and dispatch a fresh issue step. Its verdict is read as any
     other, so a second clean stop comes back here.
  4. Only **Stop** ends the chain: the root then takes the `stopped` arm.
- **The re-dispatched step resumes the kept clean stop** in place of a fresh
  run, as §0a's `--resume` arm does. It runs `clean-stop.zsh read --repo-dir
  <worktree> --issue <N> --mode attended`, since the root's human made the
  grant, and its exit 3 or 4 ends the step `stopped` with cause `tooling`. It
  moves no kept state aside. It notes `resumed_from: clean_stop`, runs §0a's
  precheck, checks out the marker's `branch` from `origin`, runs §1b, skips
  §0b, §1, §2 and §3, and records `gate_verdict: READY`. Then it continues at
  the extension's step 5 (`reference/interactive/extension-grant.md`), with the
  grant already recorded and any guidance already posted: one fix pass that
  reads the issue's comments, the next round's boundary, and the loop's
  `--resume` with the marker's `work_dir` and `status_file` and `--max-rounds`
  set to the ceiling in `<work_dir>/.max-rounds`. Its mode stays `unattended`
  for everything after, so a second failure takes the automatic grant or the
  clean stop again.

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

**The residue terminal is retired (#2580).** The block above still sends a
`CONVERGED_WITH_RESIDUE` exit to the residue branch; that can no longer happen.
The loop never emits it, and a residue-shaped round ends `ESCALATE_NO_CONVERGENCE`
or `BUDGET_EXHAUSTED`, which this terminal handles after the automatic grant and
the clean stop above (unattended) or the interactive extension (attended).

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
Then run `checkpoint.zsh clear --repo-dir <worktree> --issue <N>` (#2920), so a
later `--resume` never re-runs an escalation that already ended.
