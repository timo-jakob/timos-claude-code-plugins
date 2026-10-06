# resolve-issue — epic-mode telemetry

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it
when the Epic flow points here, never up front. Each child run it starts follows
`reference/telemetry.md` § Story telemetry (#1226).

## Epic telemetry (#1227)

An Epic-flow invocation appends **exactly one** `telemetry/v1` record,
`pipeline: "resolve-issue"`, `payload.mode: "epic"`, at whichever ending it
reaches: an E1 halt, the E1b halt, a stop mid-E3, an E4 regression, or E5's
close. It is one record per **invocation**, not per epic: the flow is resumable,
so an epic that takes three runs leaves three records, each measuring the work
its own run did. Every child E3 drives is a story run of its own
(`reference/telemetry.md`), **parented to the epic run**. The contract — the
payload keys, the closed `e1_classification` table and the outcome precedence — is
ARCHITECTURE.md's *Resolve-issue telemetry*; this is the procedure. The same
never-fatal rule holds: nothing here may change what the epic run does or
reports.

### 1. Before E1 — stamp the epic run

Once Step 0 has classified the target as an epic, and before E1, stamp the
run with the sink flags `args` reported (omit a `null` one). The run file is
keyed by the epic's number and lives in the session scratch directory:

```bash
"<skill-base-dir>/scripts/story-telemetry.zsh" start \
  --run-file <scratch>/epic-run-<N>.json \
  [--telemetry-file <telemetry_file>] [--telemetry-dir <telemetry_dir>]
```

Call it once per invocation and re-read the file on re-entry, exactly as
`reference/telemetry.md` step 2 says. Exit 2 is your own malformed call: fix it and re-run once. **Exit
1** costs the epic record and nothing else: say so in one line, skip step 4's
`emit`, and keep going — the children still get their own runs and the sink
flags (from `args`), but no `--parent-run-id`.

### 2. In E3 — start each child's run, parented to the epic run

Each child E3 drives stamps its **own** story run before its step 0a, in place
of the Single-issue flow's own Step 0 `start`. It takes the epic run file's
`child_start_args` — `--parent-run-id <epic run_id>` plus the epic's sink
flags:

```bash
"<skill-base-dir>/scripts/story-telemetry.zsh" start \
  --run-file <scratch>/story-run-<child>.json \
  $(jq -r '.child_start_args[]' <scratch>/epic-run-<N>.json)
```

`start` stores the parent, and the child's `emit` hands it to the emitter, so
the **child record's own** `parent_run_id` is the epic run. From there the child
follows `reference/telemetry.md` steps 2–4 with its own run file: its loops take
**its** `loop_args` (parented to the child run, never to the epic), and it emits
its own record at its own ending. When the epic `start` failed, pass only the
sink flags from `args`, with no `--parent-run-id`.

- **A parallel sub-agent** gets, in its prompt, the epic `run_id` and the sink
  flags — the `child_start_args` list, verbatim — and runs that `start` itself
  in its worktree's session, with a scratch run file of its own. It reports the
  child run's `run_id` back with its result.
- **Note every child run's `run_id`** in `child_run_ids`, in start order (a
  parallel batch in dispatch order) — escalated and parked children included.
  A child that never reached its `start` has no run and is not listed.

### 3. Keep the epic's facts as you go

| Fact | Where it is decided | Value |
|---|---|---|
| `e1_classification` | E1 | the row from the table below |
| `children` | E1, then E3 | `total` and `completed_before` are `summary.total` / `summary.completed` of the invocation's **first** `read-sub-issues.zsh` read — after a live backfill's re-read when one ran and succeeded. Every child **open** at that read is counted in exactly one bucket: `resolved_this_run` (closed as completed during this run), `escalated` (ended on a typed escalation), `parked` (parked by E3's triage — a child stopped by a §0a rejection, a precheck tooling failure, or a §2 size pre-flight stop or error, and every child that depends on an escalated or stopped child), or `queued` (everything else still open: a PR awaiting a human merge, a child whose own story run ended `failed`, and every child when E1b halts). Review-residue sub-issues filed mid-run are not in that read, so they count nowhere |
| `readiness_preflight` | E1b | `{gated, needs_refinement}`: the children `story-readiness` ran on, and how many came back `NEEDS_REFINEMENT`; `null` when E1b never ran (every E1 halt, and the rows that go straight to E4/E5) |
| `split` | E3 | `{parallel, sequential}`: only children whose PR E3 **opened this run**, by the path each took |
| `child_run_ids` | E3 | step 2 |
| `e4` | E4 | `{ran, result}`: `ran` is true only when E4 reached a verdict — one that started and then errored is `ran: false`; `result` is the last verdict this invocation's E4 reached, `green` or `regression`, and `null` exactly when `ran` is false |
| `e5_closed` | E5 | `true` once `gh issue close` succeeded |
| `failure_cause` | wherever the run broke after E1b — its final break only, so an E4 break a later E4 turned `green` leaves no cause | `e4_regression`, `e4_error` (E4 reached no verdict), `e5_error` (the close failed), `error` (any other error in the epic flow's own steps after E1b — never a child's own failed run); else `null` |

**`e1_classification`** — the E1 row this invocation took, decided by its
**first** read. A later run of an epic an earlier run backfilled reads native
children, and records `native_children`. A backfill exit 2 is your own
malformed call, fixed and re-run, so it has no value.

| Value | E1 branch |
|---|---|
| `native_children` | the first read has `total > 0`: the in-progress row **and** the `N == N` row, with or without inline slices beside them |
| `backfilled` | `total: 0`, case 1's dry run passed every vet, the live backfill exited 0 with every child accounted for and `skipped_cross_repo` empty, and the re-read continued |
| `inline_slices` | `total: 0`, case 2, every slice confirmed merged |
| `halt_undecomposed` | case 3 |
| `halt_unrealized_slices` | case 2 with a slice unrealized; also a mixed body's `N == N` row halting on an unrealized slice before E4 |
| `halt_near_miss` | case 4; case 1's reverse vet; a `skipped_self_ref` line judged a mistyped child |
| `halt_backfill_vet` | case 1's forward `would_add` vet, an empty `markdown_children`, or a non-empty `skipped_cross_repo` on the dry run |
| `halt_backfill_error` | the backfill dry run exited 1 |
| `halt_backfill_partial` | after the live run: exit 5 or 1, or `skipped_cross_repo` non-empty |
| `halt_unclassified` | the otherwise fall-through, a criteria-only body included |

### 4. At the epic run's ending, emit once

Write the state to `<scratch>/epic-state-<N>.json`, its `outcome` the **first
matching row** — worst state wins:

| # | `outcome` | When |
|---|---|---|
| 1 | `failed` | `e4.result` is `regression`, or `failure_cause` is set |
| 2 | `escalated` | `children.escalated > 0` |
| 3 | `parked` | a `halt_*` classification; `readiness_preflight.needs_refinement > 0`; `children.parked + children.queued > 0`; or `e5_closed` false |
| 4 | `success` | `e5_closed` is true |

An E1 halt — `halt_backfill_error` and `halt_backfill_partial` included — is
`parked`, never `failed`: the epic is left open for a human. The builder
derives the row from the facts too, and **refuses** a state whose `outcome` is
not that row, or whose facts contradict each other (ARCHITECTURE.md lists the
rules); a refused state emits nothing, so pick the row before writing it.

```json
{ "outcome": "parked", "e1_classification": "native_children",
  "children": { "total": 11, "completed_before": 1, "resolved_this_run": 0,
                "escalated": 0, "parked": 0, "queued": 10 },
  "split": { "parallel": 0, "sequential": 0 }, "child_run_ids": [],
  "e4": { "ran": false, "result": null }, "e5_closed": false,
  "readiness_preflight": { "gated": 10, "needs_refinement": 6 },
  "failure_cause": null }
```

```bash
"<skill-base-dir>/scripts/story-telemetry.zsh" emit --epic \
  --run-file <scratch>/epic-run-<N>.json --state <scratch>/epic-state-<N>.json \
  --repo-dir <the repo PATH> --issue <N> [--repo-type <repo_type from E4's detect>]
```

- **No `--loop-work-dir`.** The loops belong to the child runs, which list them;
  `--epic` with one is a usage error.
- **`--repo-type`** only when E4 ran §1b's `detect` and it exited 0.
- `issue` is the epic and `pr` is `null`: the children's PRs are their own
  records' to carry.
- **Exit 0 always** past argument parsing, as for a story: a builder refusal,
  a repeat call or an emitter failure prints one `NOT emitted` advisory. Relay
  it in one line and carry on. Exit 2 is your own call: fix it and re-run once.
- **Emit at the ending, before you report it** — after the epic summary
  comment, the E1/E1b halt comment, or E5's close. A run that opens a child's PR
  and stops to await a human merge has ended: emit it, with that child
  `queued`.
