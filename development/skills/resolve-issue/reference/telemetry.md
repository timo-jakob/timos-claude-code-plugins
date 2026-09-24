# resolve-issue — story-mode telemetry

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it
when the step that points here is reached, never up front. The conductor points
here from Step 0 and from the Single-issue flow's endings. The contract this
implements — the payload keys, the outcome mapping and the per-pipeline
conventions every later pipeline copies — is stated in ARCHITECTURE.md,
*Resolve-issue telemetry (#1226)*; this file is only the procedure.

## Story telemetry (#1226)

A single-issue run that reaches Step 0a (the dependency precheck) appends
**exactly one** `telemetry/v1` record, `pipeline: "resolve-issue"`, at whichever
ending it reaches. A run that stops **in Step 0** appends **none**. Every
review-loop invocation of the run is parented to it and writes to the same sink.
All of it goes through `<skill-base-dir>/scripts/story-telemetry.zsh` — never
hand-roll an envelope, a run_id or a payload.

**Telemetry is never fatal.** Nothing `start` or `emit` does may change what
the run does or reports: a telemetry failure costs the record, never the run.
(`args` is different in kind. It is the skill's **invocation** parser, the one
place the issue reference is read from, so its failures stop the run like any
other malformed invocation.)

### 1. Step 0 — parse the arguments

Parse `$ARGUMENTS` **before** classifying the target. Pass each word of it as
its own **single-quoted** argument, and never paste the words unquoted. A shell
reads an unquoted `#123` as the start of a comment, and `&`, `;` or `$` in a
URL or a path would be mangled the same way. Rules for building the words:

- A leading `#` is part of the issue reference.
- A word the user quoted (`'/a b/x.jsonl'`) stays **one** argument, re-quoted
  as a whole.
- An embedded `'` is written `'\''`.
- A `~` is passed as it is; the script expands a leading one itself.

```bash
"<skill-base-dir>/scripts/story-telemetry.zsh" args '<word 1>' '<word 2>' …
```

- **Exit 0** → a JSON object. `issue_ref` is the target Step 0 classifies.
  `telemetry_file` / `telemetry_dir` are the sink flags, already made
  absolute, or `null`. `no_review` is `true` when `--no-review` was given,
  and it is what §3.5's skip reads.
- **Exit 2** → a malformed invocation: for example no arguments, an unknown
  flag, a sink flag with no value or a flag-shaped one, a repeated sink flag,
  an empty issue reference, or more than one issue reference. **Two things can
  be malformed here, and you own one of them.** First re-check your own
  word-building against the four rules above — a user-quoted path split in two
  reads as a second issue reference — and re-run **once**. Only a second exit 2
  is the user's invocation: its stderr **is** the invocation help, so relay it
  and stop. Either way there is no record — this is a Step 0 stop.
- **Exit 1** → an internal failure (jq). Report its stderr and stop, with no
  record.

**Step 0 stops leave no record.** Empty arguments, a usage error, an issue that
is not `OPEN`, an issue outside the session repo, a failed classification, and
the near-miss halt all stop before Step 0a, so never call `start` or `emit`
for them.

**An epic takes no part in this.** A target classified as an epic takes the
Epic flow and emits no resolve-issue record. The children E3 drives through the
Single-issue flow emit none either, and their loops get **no** `loop_args`: no
`--parent-run-id` and none of the sink flags. Epic-mode records and their
parentage are child (b) of epic #741. Until it lands, an epic's sink flags are
parsed and unused, and its loop records go to the local default sink.

### 2. Once the target is a single issue — stamp the start

Immediately after Step 0 classifies the target as a **single issue**, and
before Step 0a, stamp the run's start and pre-mint its `run_id`. The run file is
keyed by the issue number and lives in the session scratch directory, **never**
inside the repo (a file there moves the tree identity and would be committed):

```bash
"<skill-base-dir>/scripts/story-telemetry.zsh" start \
  --run-file <scratch>/story-run-<N>.json \
  [--telemetry-file <telemetry_file>] [--telemetry-dir <telemetry_dir>]
```

**Omit either sink flag when `args` reported it `null`** — pass only the ones
it gave a path. (`start` drops a literal `null` for you, but the flag is
meaningless without a value.)

It prints `{run_id, ts, telemetry_file, telemetry_dir, loop_args}` and touches
no sink. **Call `start` exactly once per invocation.** Every call mints a new
run and overwrites the file. A fresh invocation of the same issue therefore
starts fresh, whatever an earlier run left behind. If you re-enter this step
within the same invocation — say, after a compacted context — **re-read the
run file**; never call `start` again. A second call would move the `run_id`
out from under loops already parented to the first.

- **Exit 2** is your own malformed invocation. Fix it and re-run once. A second
  exit 2 is handled as exit 1.
- **Exit 1** is an internal failure: for example no clock, an unwritable run
  file, or jq failing. Say so in one line and run **without** a resolve-issue
  record. **Skip the `emit` of step 4 below entirely** for this run, since a
  run file left over from an earlier run of the same issue would otherwise be
  emitted with that run's id and start time. The loops still get the sink flags: take them
  from the `args` output, since the run file that would have carried them was
  never written. They get no `--parent-run-id`.

**A remediation rung is its own run.** When §0a's interactive remediation runs
the Single-issue flow on a blocker, that rung calls `start` with its **own**
issue's run file (`story-run-<blocker>.json`) and the **same** sink flags this
run was given. It emits its own record. It never overwrites this run's file,
and so never takes over this run's `run_id`.

Append the run file's `loop_args` to **every** `resolve-story-loop.zsh`
invocation of this run. They are `--parent-run-id <run_id>` plus exactly the
sink flags the run was given:

```bash
jq -r '.loop_args[]' <scratch>/story-run-<N>.json
```

That covers the blocking phase's first invocation and every `--resume`: each
step-mode round, each granted extension, each `STALE_FINDINGS` recovery. It also
covers the promotion sub-loop and each of its resumes. A missed invocation
leaves that loop's record unparented and, under a sink flag, in the wrong file,
and the emitter exits 0 either way, so nothing surfaces the loss.

The promotion enrichment (`reference/promotion.md` step 3) emits through the
emitter directly, not through the loop. Pass it the same `--telemetry-file` and
`--telemetry-dir` the run was given, so it lands beside the record it enriches.
It stays joined to its loop record by that record's `run_id`, as before, and it
carries no `--parent-run-id` of its own.

### 3. Keep the run's facts as you go

The record describes what happened, so note these at the step where each is
decided. None may be guessed at the end.

| Fact | Where it is decided | Value |
|---|---|---|
| `dependency_precheck` | Step 0a | the decision string (`PROCEED` / `REJECT_BLOCKED` / `REJECT_CYCLE`) of the **last** precheck this run ran; `null` when that last precheck exited 1, or 2 twice, and so decided nothing |
| `gate_verdict`, `risk` | Step 0b | the verdict, and the verdict's `risk` when `READY` |
| `story_spec_present` | Step 2 | `true` when `read-story-spec.zsh` exited 0 |
| `fallbacks_fired` | Steps 2 and 3 | `acceptance_tests` when the acceptance planner exited 1; `user_docs` when the user-docs step no-oped for any of its reasons; `c4_currency` when the C4 check no-oped (`[]`, exit 1, or skipped on a detection failure) |
| `escalation_status` | §3.5 | the `ESCALATE_*` / `BUDGET_EXHAUSTED` status the run **ended** on, and **only** when step 4 below picks the `escalated` row. It is `null` on every other ending, including after either of §3.5's PR-opening terminals, a `--no-review` `SKIPPED`, a loop `ERROR`, and an escalation that a later grant superseded. Never write a non-escalation status here: the builder refuses it and the record is lost |
| `pr` | Step 6 | the opened PR's number |

"The last precheck this run ran" includes §0a's re-verification after an
interactive remediation. When the human picks "Both" and the blockers merge,
the re-verification that returns `PROCEED` is the decision the run continues
on.

### 4. At the ending, emit once

Write the state to `<scratch>/story-state-<N>.json` and emit. The state's
`outcome` names the ending the run actually reached. **Take the first row that
matches:**

| The run ended … | `outcome` |
|---|---|
| with the last precheck a rejection (`REJECT_BLOCKED` / `REJECT_CYCLE`), whatever followed it: the run is autonomous; the human declined remediation; the human chose "just the dependency"; a remediation rung failed, halted or paused awaiting a human merge; or the re-verification rejected again | `precheck-parked` |
| on a §0b `NEEDS_REFINEMENT` | `gate-parked` |
| on a **loop invocation that exited** `ESCALATE_*` / `BUDGET_EXHAUSTED`, with no PR (after the interactive extension, if one ran) | `escalated` |
| with a PR opened — after either of §3.5's PR-opening terminals, or after a `--no-review` skip of the loop | `pr-opened` |
| any other way after Step 0a: the last precheck errored (`null`, the re-verification included), a red gate was abandoned, a §2 stop on an under-specified story or a size pre-flight split (its own `story-preflight` record, parented to this run, carries the `parked`), a gate or loop errored, or **the round protocol stopped before any loop invocation** — a `review-dispatch.zsh plan` that exited 1, 2 or 3 (its exit 3 is the same condition the loop would have called `ESCALATE_AMBIGUOUS`, but no loop ran), an unreadable carry, or a panel that could not be dispatched | `failed` |

A granted escalation that later converges ends `pr-opened`. `AWAITING_FIX` and
`STALE_FINDINGS` are never endings. Once the row is picked, **set
`escalation_status` to `null` unless the row is `escalated`**, whatever was
noted along the way — a stop before any loop ran therefore records `failed`
with a `null` status, however the stopping condition was named. The builder refuses a state whose facts
contradict its `outcome` (ARCHITECTURE.md lists the rules). A refused state
emits nothing, so pick the row before writing the state, not after.

```json
{ "outcome": "pr-opened",
  "dependency_precheck": "PROCEED", "gate_verdict": "READY", "risk": "elevated",
  "pr": 413, "story_spec_present": true,
  "escalation_status": null, "fallbacks_fired": ["c4_currency"] }
```

```bash
"<skill-base-dir>/scripts/story-telemetry.zsh" emit \
  --run-file <scratch>/story-run-<N>.json --state <scratch>/story-state-<N>.json \
  --repo-dir <the repo PATH the loop was given, never the owner/name identity> \
  --issue <N> [--repo-type <repo_type from §1b>] \
  --loop-work-dir <blocking-phase work-dir> \
  [--loop-work-dir <promotion work-dir>]
```

- **Pass a `--loop-work-dir` for every loop work-dir this run used, and only
  those.** A remediation rung's work-dir belongs to the rung's own run: the
  rung passes it to its own `emit`, never this one. The ids come from each
  work-dir's `.telemetry-run-ids` ledger, which the loop appends to on every
  record it emits. That is how `payload.review_loop_run_ids` joins the run to
  its loops. A run that never reached §3.5 passes none. A path that is not a
  directory is warned about on stderr and contributes nothing.
- **`--repo-type`** is the `repo_type` §1b detected. Omit it when §1b never ran
  or exited 3.
- **Exit 0 always**, past argument parsing. On success it prints the record and
  marks the run file emitted. On any failure it prints one
  `resolve-issue record NOT emitted` advisory on stderr and emits nothing. That
  covers:
  - a builder that rejects the state;
  - a run already emitted;
  - an emitter that is absent, not executable or exits non-zero, including its
    exit 2 for a `--telemetry-dir` that names a file, and its exit 2 for a
    `--repo-dir` that is not a directory — which is what passing the
    `owner/name` identity there produces.

  Relay the advisory in one line and carry on. The run's own result stands.
- **Exit 2** is your own malformed invocation. Fix it and re-run once. A second
  exit 2 costs the record, like any other failure here: say so in one line.
- **Emit exactly once per run.** On a PR-opening run, emit **after** Step 6 has
  the PR number. On every other ending, emit **at** that ending, before you
  report it. A repeat call is refused by the run file's `emitted` mark, so it
  cannot append a second record for one story.
