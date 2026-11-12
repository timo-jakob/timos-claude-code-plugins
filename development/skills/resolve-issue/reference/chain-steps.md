# Chain steps — the root, its steps and their two files (#2940)

Read this file when a run's origin is `human` (§0a): a human invoked
`/development:resolve-issue`. A pipeline-started run never reads it. It stops at
§0b, E1b and §2 exactly as it always did, and runs every step in-session.

## The step model (#2940)

In a human-started run, the session the human invoked is the **root**, and it
only drives the chain. Every unit of work is a **step**: the named issue's own
run, each chained refinement and each E3 child's run. The root dispatches each
step as a fresh subagent, with the Agent tool and the step's own plugin agent
(#3014): `subagent_type: development:resolve-step` for an issue-run step,
`subagent_type: development:refine-step` for a chained refinement. Each agent's
definition carries the step's whole contract and pins its model and tools, so
the brief names only what differs between steps.
Before its first dispatch it starts or resumes the chain queue (#2942):
see `reference/checkpoint.md` § The chain queue in a human-started run (#2942)
The root keeps Step 0's classification and, for an epic, E1 to E5's control
flow. Each child's run is still a step. In a human-started run, attended and
unattended behave alike, whatever `resolve_session` says (#2907). A step
resolves its session mode as an E3 child does: §0a's
`scripts/resolve-session.zsh` with the inferred mode `unattended`, and it stays
autonomous whatever the line says, so no step ever asks. **A step's mode is
`unattended` for every branch keyed on the mode**, even when the line says
`attended`: §0a's arms, §3.5's extension and suggestion promotion, and
the escalation's automatic grant and clean stop. **The one exception is §0a's
kept-state arm without `--resume`:** a step moves any kept state aside as an
attended run does, deleting nothing, and never runs `clean-stop.zsh clear`,
so it never deletes state a human could still resume. It records
`session_mode: unattended`, with the line's source, or `inferred` when the line
says `attended`, and quotes the line it set aside. An epic's walk mode does not
reach a step.

**A parallel child's step runs in its own worktree.** The root dispatches the
step of each child in E3's parallel set with the Agent tool's
`isolation: "worktree"` beside `subagent_type: development:resolve-step`, so
each runs in a worktree of its own and their edits can't collide. Every other
step runs in the root's checkout, one at a time. Either way the step's §1 runs
`init-submodules.zsh` in that work tree before its first gate (#3080), since a
new worktree initialises no submodules.

**`--resume` is the exception.** A human-started run given `--resume` does not
chain: the session the human invoked runs §0a's `--resume` check itself and
resumes in-session, because the interactive extension asks the human, which a
step never does.

**Two files, nothing else.** The root and a step exchange work only through a
step handoff file and a step verdict file. Both are contracts in ARCHITECTURE.md:
*Step handoff contract (`step-handoff/v1`)*, adopted unchanged from #2939, and
*Step verdict contract (#2940)*. The root writes the handoff to
`<scratch_dir>/step-<N>-handoff.json` and reads the result only from
`<scratch_dir>/step-<N>-verdict.json`, never from the step's transcript.
`scratch_dir` is the root's own scratch directory, outside the repository, and
every step of the run shares it. Before each dispatch the root deletes the
issue's old verdict file, so it never reads a previous step's result as the new
one.

An issue-run step's handoff carries the step-handoff/v1 fields and five more,
which a reader that does not read them ignores:

```json
{ "schema": "step-handoff/v1", "issue": 2940, "chained_from": 2907,
  "origin": "human", "scratch_dir": "/abs/scratch", "answers": [],
  "kind": "issue", "parent_run_id": "<the root's run_id>",
  "start_at": "0a", "risk": null, "after": null }
```

`start_at` is `"0a"` for a first run, a leaf refined `ready` at E1b included.
It is `"1"` only for the issue step re-dispatched after a refinement's `ready`
on an issue whose own step already passed §0a: the single-issue entry, the
E3 child and a blocker (#2941). That step skips §0a and §0b, carries `risk` from the
`ready` verdict, and records `dependency_precheck: PROCEED` and
`gate_verdict: READY`. It never runs a second gate. A step whose handoff `issue`
differs from its `chained_from` is an E3 child's run, which §2 parks by
terminal (c). A blocker step's `chained_from` is the blocker itself
(#2941). `after` is `null`, or, for a child of E3's sequential chain, the
merge commit of the child before it (the PR's `mergeCommit.oid`), which the step
passes to step 1's branch script as `--after`. A refinement step's handoff is the
plain step-handoff/v1 object plus `"kind": "refinement"`.

**Read every verdict against the contract** before acting on it:

```bash
jq -e -s --argjson n <N> --arg kind <issue|refinement> 'length == 1 and (.[0] | (.schema == "step-verdict/v1")
  and (.issue == $n)
  and ($kind | IN("issue", "refinement"))
  and (.verdict | IN(if $kind == "issue" then ("done", "needs-refinement", "blocked", "stopped")
       else ("ready", "split", "questions-pending", "stopped") end))
  and (.follow_ups | type == "array" and all(type == "number" and . >= 1 and . == floor))
  and ((has("run_id") | not) or (.run_id | type == "string" or . == null))
  and (if .verdict == "done" then (.pr | type == "number" and . >= 1 and . == floor)
       elif .verdict == "needs-refinement" then (.reason | IN("gate", "size"))
       elif .verdict == "ready" then (.risk | IN("low", "normal", "elevated")) and (.auto_accepted | type == "array")
       elif .verdict == "split" then (.children | type == "array" and length > 0 and all(type == "object"))
       elif .verdict == "blocked" then (.blockers | type == "array")
       elif .verdict == "questions-pending" then (.questions | type == "array" and length > 0 and all(type == "object")) and (.resume | type == "string") and (.round | type == "number" and . >= 1 and . == floor)
       elif .verdict == "stopped" then (.reason | type == "string" and test("\\S"))
         and (if $kind == "issue" then (.cause | IN("escalation", "clean-stop", "tooling", "failed"))
              else (has("cause") | not) end)
       else false end))' <scratch_dir>/step-<N>-verdict.json
```

`kind` is the step's handoff `kind`, `issue` or `refinement`. An issue-run
step ends only `done`, `needs-refinement`, `blocked` or `stopped`, a refinement
step only `ready`, `split`, `questions-pending` or `stopped`, so the root never
holds a verdict it has no arm for. An issue-run step's `stopped` must carry its
`cause`, a refinement step's never does.

**A step that ends its turn with no verdict file is messaged to carry on, not
counted as failed.** Send it one SendMessage asking it to finish and write the
verdict file. A verdict the check above rejects gets the same message, naming
the field that fails. Only a step that still writes no valid verdict is a
failure: report it and emit nothing on the step's behalf. A single-issue root
then stops the chain. In an epic, the root treats it as a tooling failure of
that child: it parks the child, quotes the failure in the epic summary, and
continues E3. That message is not a retry or a recovery: the same agent finishes
its own unfinished work, and nothing is run again. Any retry after it is a new
dispatch.

**A retry or a recovery is a new dispatch, never a resumed agent.** A step
dispatches no further step, so the depth stays root (0) → step (1) → panel or
refiner (2) → reviewers (3). The human follows each step through its
`progress.md` and the root's status lines. In a human-started run, §2's rule
that model-driven work stays in-session gives way to this model. The rule
against a headless `claude` still holds: a step is an Agent-tool subagent, never
a separate `claude` process.

**Each step emits its own story record**, parented to the root run.

- **The root stamps the chain.** It runs `story-telemetry.zsh start --run-file
  <scratch_dir>/chain-run-<N>.json --origin human` once, with the sink flags it
  was given, and passes its `run_id` as every handoff's `parent_run_id`. For an
  epic entry, that run is the epic run `reference/epic-telemetry.md` step 1
  stamps, in `epic-run-<N>.json`.
- **Each issue-run step stamps its own run.** It runs `start --parent-run-id
  <parent_run_id> --origin <origin>` and emits its record at its ending.
- **What the root emits.** For an epic entry, the root emits the epic record.
  For a single-issue entry, it emits no story record of its own: its `run_id`
  is a correlation key that groups the chain's step records, with no record of
  its own. The root never stamps or emits `story-run-<N>.json`: that file is the
  issue step's (`reference/telemetry.md` step 2).
- **A single-issue entry that splits.** When a refinement `split`s the named
  issue, the chain run becomes the epic run. The root stamps no
  `epic-run-<N>.json`, and uses `chain-run-<N>.json` wherever
  `reference/epic-telemetry.md` names the epic run file: its `child_start_args`,
  and its `run_id` as each child handoff's `parent_run_id`. It emits the epic
  record from it when the walk ends. `child_run_ids` lists only the children's
  runs, in start order, as the epic record's contract defines it: the named
  issue's own step runs are not children, and their records reach the run
  through their `parent_run_id`.

## The issue step (#2940)

The root dispatches an issue-run step, whether the named issue's own run, an E3
child's run or a blocker's, with `subagent_type: development:resolve-step`. The
agent's definition (`development/agents/resolve-step.md`) carries the step's
procedure: the handoff read, the telemetry start, the unattended mode, the
`BLOCKERS_FIRST=1` handling, the bans and the verdict file. The brief is only:

```text
STEP_HANDOFF=<scratch_dir>/step-<N>-handoff.json
FLAGS=<the root's telemetry flags and its --no-review, when given>
BLOCKERS_FIRST=1
```

The `FLAGS` line is left out when the root was given none of those flags, and
the `BLOCKERS_FIRST=1` line is left out of every brief but the named issue's
first step's and a blocker step's.

The step ends with one of these verdicts:

- `done` with the PR.
- `needs-refinement`, with `reason: "gate"` after §0b's park or
  `reason: "size"` after §2's park.
- `blocked`, with the blockers §0a found.
- `stopped`, with the reason, for any other ending: an escalation, a clean
  stop, a red gate or a failure. Its `cause` names which, for E3's triage:
  - `escalation`: a typed escalation other than the clean stop;
  - `clean-stop`: #2579's clean stop;
  - `tooling`: a precheck exit 1, or an exit 2 that recurs after the fixed
    re-run; a size pre-flight error; an unreadable step handoff; a submodule
    initialisation that exits 3, an environment error (#3080);
  - `failed`: any other ending `reference/telemetry.md` step 4 records `failed`,
    such as an abandoned red gate, a gate or loop error, or a round protocol
    that stopped before any loop ran.

How the root handles each, once it has queued the verdict's `follow_ups` in the
chain queue (#2942), which replaces §7's `refine-issue --follow-up` call in a
human-started run:

- **`done`** → report the PR. In an epic, continue E3. Queue step 3 alone says
  when an entry, epic-kind or not, is marked `done` and `next` is taken.
- **`needs-refinement`** → dispatch *The chained refinement step (#2940)* on
  the same issue.
- **`blocked`** → on the named issue's step, or a blocker's, the root runs
  the blockers-first procedure. The root puts `BLOCKERS_FIRST=1` in the brief
  of the named issue's first step and of every blocker step:
  see `reference/interactive/blockers-first.md` § Blockers first in a human-started run (#2941)
  An E3 child's brief never names that line, so the child posted the comment
  and the label: the root parks the child as E3 parks a dependency rejection
  and continues with the children that don't depend on it. On a follow-up's
  step, the root adds each open local blocker `--before` the follow-up,
  deepest first, and takes `next`; the re-run follow-up's §0a clears its label.
  A cycle or an open foreign blocker parks it (queue step 5).
- **`stopped`** → report the reason and stop. In an epic, triage the child by
  its `cause`, as E3 triages that ending, and count it in the bucket
  `reference/epic-telemetry.md` step 3 names:
  - `escalation` → as E3 triages an escalation, counted `escalated`;
  - `clean-stop` → the same, and the child joins `epic-clean-stop-triage.zsh`'s
    `--clean-stopped` list;
  - `tooling` → as E3 parks a tooling failure: no label, the reason quoted in
    the epic summary, counted `parked`;
  - `failed` → as E3 treats a child whose run ended `failed` for a cause its
    triage does not park, counted `queued`.

## The chained refinement step (#2940)

The root dispatches a chained refinement step in three places:

- on a `needs-refinement` verdict, whether its reason is the §0b gate or the §2
  size park;
- once per unready leaf at E1b;
- on an E3 child that comes back parked by §2;
- on each follow-up entry, before it is built (#2942).

**A first dispatch starts with no resume state.** Before every refinement
dispatch other than the questions-pending relay's re-dispatch, the root deletes
the issue's old resume file, so a refinement of an issue refined earlier in the
run starts as a first dispatch rather than restoring that refinement's state:

```bash
rm -f -- <scratch_dir>/refine-<N>-resume.json
```

**One refinement per issue and reason.** A second `needs-refinement` for the
same issue and reason in one run, or a leaf already refined in this run that
re-gates `NEEDS_REFINEMENT` at E1b, is never chained again. The root takes the
`stopped` arm below, but the verdict file holds no refinement's `stopped`, so
it posts the comment with a fixed body that names the park's reason:

```bash
printf 'chained refinement stopped: the %s park recurred after a ready refinement\n' <gate|size> \
  | gh issue comment <N> --body-file -
```

The root dispatches a chained refinement step with
`subagent_type: development:refine-step`. The agent's definition
(`development/agents/refine-step.md`) carries the step's procedure: it runs
`/development:refine-issue <N> --chained-from <root> --handoff <file>` and
converts the chain-result/v1 document it prints into the step verdict. The
brief is only:

```text
STEP_HANDOFF=<scratch_dir>/step-<N>-handoff.json
```

A refinement step's `follow_ups` is always `[]`: a chain-result/v1 document
lists no filed issues other than a split's children.

A refinement step ends with the verdict its chain-result outcome names, and with
no other:

- **`ready`** → the issue is ready to build.
  - **A single-issue entry:** dispatch a fresh issue step with `start_at: "1"`
    and the verdict's `risk`. A follow-up entry, whose step never passed §0a,
    gets `start_at: "0a"`.
  - **A leaf at E1b:** the leaf is READY for E1b, with the verdict's `risk`.
    Nothing is dispatched for it until E3 builds it. Its E3 step is a first run,
    `start_at: "0a"`, so §0a's dependency precheck runs; §0b then takes the
    READY stamp the refinement's re-gate left as a cache hit.
  - **An E3 child:** dispatch its fresh issue step with `start_at: "1"` and the
    verdict's `risk`, in the child's place in the walk.
- **`split`** → the issue is now a parent.
  - **A single-issue entry, a follow-up entry included:** the root resolves
    the parent with the Epic flow as written. Its children are the new leaves.
  - **A leaf at E1b:** re-read the tree with E1's `read-sub-issues.zsh --tree`,
    then re-gate every open leaf.
  - **An E3 child:** that child becomes an inner node. The root gates its new
    leaves by E1b's rule and builds them as E3 leaves in the same walk, before
    any child that is `blockedBy` the split child.
- **`questions-pending`** → *The questions-pending relay (#2940)*.
- **`stopped`** → the run keeps the label it posted and posts one comment that
  begins `chained refinement stopped:` with the reason, read from the verdict
  file so no shell expands it:

  ```bash
  jq -r '"chained refinement stopped: " + .reason' <scratch_dir>/step-<N>-verdict.json \
    | gh issue comment <N> --body-file -
  ```

  A single-issue root emits nothing more, because the step already emitted its
  record. An epic root emits the epic record when the walk ends. Where the run
  stops, or for an E3 child goes on:

  - **at §0b:** with `needs-refinement`, and the step's record already says
    outcome `gate-parked`;
  - **at §2:** with `needs-split`, the branch un-pushed, no PR, and the step's
    record already says outcome `failed`;
  - **at E1b:** with `needs-refinement` on each stopped child. The epic halt
    summary names each stopped child and its reason, and nothing is built;
  - **on an E3 child:** the child stays parked, as E3 parks a size-stopped
    child, and the walk continues with the children that don't depend on it.

## The questions-pending relay (#2940)

**Only the root asks the human.** A refinement step that reaches a
below-threshold intent or gap question ends with verdict `questions-pending`
and lists the questions. A step never asks, neither with AskUserQuestion nor
through a side channel such as an OS dialog.

The relay:

1. The root asks the verdict's `questions` with AskUserQuestion, at most four
   to a call. Each option offers the entry's `recommended_answer`.
2. It appends each answer to the handoff's `answers` list as one
   `{issue, question, answer}` entry. `question` is the pending ask entry's
   `question` text, verbatim.
3. It writes a fresh handoff with the **same** `scratch_dir` and `chained_from`
   as the dispatch that returned `questions-pending`, so the refinement finds
   its `<scratch_dir>/refine-<N>-resume.json` (#2939).
4. It dispatches a fresh refinement step: a new dispatch, never a resumed agent.
