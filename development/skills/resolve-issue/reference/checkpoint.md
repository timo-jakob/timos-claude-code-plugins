# resolve-issue — checkpoints

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it
when the step that points here is reached, never up front. The marker contract
is stated once in `scripts/checkpoint.zsh`'s header and in ARCHITECTURE.md,
*Resolve-issue telemetry (#1226)*; this file is only the procedure.

## Checkpoints — the recoverable round (#2920)

A run killed from outside — the usage limit, a closed terminal, a crash — never
reaches the clean stop, so without a checkpoint it loses everything it has not
committed and pushed. A checkpoint caps that loss at the round in progress.

**The contract.** No PR is opened until the loop exits `CONVERGED`. The only
earlier pushes are wip checkpoint commits to the feature branch, with no PR. A
wip commit carries no `[skip ci]`: in a repo whose CI runs on every push, the
push-time run is accepted. Squash auto-merge folds the wip commits into one when
the PR merges.

**Every single-issue run checkpoints, attended or unattended.** Its loop
work-dir and status file are the durable pair `clean-stop.zsh dir` prints, so
the state a checkpoint keeps is one a later session can find.

- **Round 0 — the first green gate.** The moment §3's first gate reports green,
  before round 1 consolidates, run:

  ```bash
  "<skill-base-dir>/scripts/checkpoint.zsh" write --repo-dir <worktree> --issue <N> \
    --round 0 --mode <mode> --run-id <the run's run_id>
  ```

  It commits `wip(resolve-issue #<N>): implementation`, pushes it as the
  Maintenance App and records `last_round: 0`. Omit `--run-id` when `start`
  failed and there is no run id.
- **Round k — every round the loop consolidates.** Pass `--checkpoint <mode>`
  on every invocation of the blocking loop, round 1 and every `--resume` alike,
  and never on the promotion sub-loop, whose work-dir is not the one the marker
  keeps. After a round consolidates on a green gate, the loop commits
  `wip(resolve-issue #<N>): round <k>`, pushes it and records `last_round: k`.
  A round whose gate is red never consolidates, so it commits nothing and the
  marker stays as it was.

**A checkpoint is never fatal.** On exit 0 it printed the marker. On exit 1 —
the push failed, say — the previous marker stands and the commit stays local,
so the next checkpoint pushes it too. Relay the stderr line once and carry on:
the run loses only that recovery point. When no Maintenance App token can be
minted, the script pushes to `origin` as the user and says so; open-pr still
pushes the final commit as the bot. Exit 2 is your own malformed call: fix it
and re-run once.

## Resuming from a checkpoint (#2920)

Reached from §0a when `--resume` finds no kept clean stop (`clean-stop.zsh read`
exit 3). The marker written last wins, because writing either one deletes the
other. When both are found anyway, `clean-stop.zsh read` resumes the clean
stop, says so and deletes the checkpoint.

1. **Read the checkpoint:**

   ```bash
   "<skill-base-dir>/scripts/checkpoint.zsh" read --repo-dir <worktree> --issue <N> --mode <mode>
   ```

   Exit 3 (no checkpoint either) and exit 4 (mode `unattended`) refuse the
   resume. Exit 5 refuses it too: the remote branch head is not the marker's
   SHA, so something moved the branch after the checkpoint. Exit 1 is an
   internal failure. On any of them, relay the stderr line, emit the run's
   record as `failed` and stop. Exit 2 is your own malformed call: fix it and
   re-run once.
2. **On exit 0**, the script has already dropped any half-finished later round
   from the work-dir and restored the checkpoint's work-dir and status file.
   Note `resumed_from: checkpoint` for the run's record, run §0a's dependency
   precheck as usual and, on `PROCEED`, check out the marker's `branch` from
   `origin`. The working tree must be clean first. Its uncommitted changes are
   the half-finished round, so ask the human before you discard them. Then run
   §1b. Skip §0b, §1, §2 and §3, and record `gate_verdict: READY`: the
   interrupted run passed the readiness gate and implemented the story.
3. **From `last_round: 0`** (`loop_resume: false`), enter §3.5 at round 1 and
   start the loop fresh, **without** the loop's `--resume`. Round 1's boundary
   starts the gate as usual.
4. **From `last_round: k`, with k >= 1** (`loop_resume: true`), round k ended
   on the restored status file's `status`. Take that exit's branch in §3.5,
   exactly as the interrupted run would have: an `AWAITING_FIX` lost its fix
   pass, so redo it, then run round k+1's boundary and invoke the loop **with**
   `--resume` and `--max-rounds <the marker's ceiling>`. Every other status is
   that terminal's own path with the restored status file. Pass the marker's
   `work_dir` and `status_file`, `--checkpoint <mode>` and the run's
   `loop_args` on every invocation. A grant the interrupted run recorded is in
   the restored work-dir, and the loop adopts it.

The run's record passes the marker's `work_dir` as `--loop-work-dir`.

## A fresh run on kept state (#2920)

A run without `--resume` never adopts kept state. An unattended one has already
cleared the durable folder (§0a); an attended one deletes nothing. Once §1 has
cut the branch, and before round 1, either one runs:

```bash
"<skill-base-dir>/scripts/checkpoint.zsh" supersede --repo-dir <worktree> --issue <N> --branch <branch>
```

- **Exit 3** — nothing is kept and the branch is not on the remote. Start fresh.
- **Exit 0** — when a clean-stop marker or `checkpoint.json` was kept, the
  script moved the whole durable folder to `<N>.superseded-<UTC stamp>/` and
  printed it as `superseded_to`; say once that kept state existed and where it
  went. With nothing kept, the branch's remote head is a killed run's own
  `wip(resolve-issue #<N>)` commit and no PR is open on it. The new durable
  folder holds a `lease.json` naming the head the run's first checkpoint push
  may replace — the kept checkpoint's SHA, else the branch's remote head — and
  that push uses
  `--force-with-lease=<branch>:<that SHA>`. It can replace only that head, so a
  branch someone pushed to since is refused.
- **Exit 1** — report the stderr line and stop before round 1. One cause is a
  branch on the remote with nothing kept whose head is not a killed run's wip
  checkpoint, or has an open PR: no lease may replace it, so the run could
  neither checkpoint nor open its PR. Exit 2 is your own malformed call:
  fix it and re-run once.

§1's branch script stops when the old run's branch still exists locally. In an
attended run, ask the human whether to delete it: its loop state stays in the
superseded folder, and the run's first checkpoint push replaces its remote branch.

## The final commit and the PR (#2920)

A run that pushed checkpoints has wip commits on its branch, and they stay
there. **Never rewrite a pushed checkpoint** — no `reset`, no amend, no rebase
of your own. open-pr's Step 1b refuses to push when the remote branch holds a
commit HEAD does not contain, so folding the wip commits into one would stop
every converged run without a PR. At §5, make the one Conventional Commit **on
top of** them:

```bash
git add -A
git commit --allow-empty   # §5's message, with `Closes #N`
```

`--allow-empty` is for the run whose last checkpoint already holds the whole
change: the commit then carries only the message. Pre-commit still runs, and §3
already ran it over the whole tree. Squash auto-merge folds the wip commits and
this one into a single commit on `main`, titled from the PR.

**Once the run's record is emitted (§7), clear the durable folder** —
checkpoint, work-dir and status file together. §6's dossier and parked-issue
links and §7's follow-up refinement and record all read that work-dir, so the
clear is the run's last step:

```bash
"<skill-base-dir>/scripts/clean-stop.zsh" clear --repo-dir <worktree> --issue <N>
```

Every other ending keeps the folder, so a later `--resume` can find it.
