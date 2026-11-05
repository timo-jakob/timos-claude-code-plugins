# Chain steps — the root, its steps and their two files (#2940)

Read this file when a run's origin is `human` (§0a): a human invoked
`/development:resolve-issue`. A pipeline-started run never reads it. It stops at
§0b, E1b and §2 exactly as it always did, and runs every step in-session.

## The step model (#2940)

In a human-started run, the session the human invoked is the **root**, and it
only drives the chain. Every unit of work is a **step**: the named issue's own
run, each chained refinement and each E3 child's run. The root dispatches each
step as a fresh subagent, with the Agent tool, `subagent_type: general-purpose`.
The root keeps Step 0's classification and, for an epic, E1 to E5's control
flow. Each child's run is still a step. In a human-started run, attended and
unattended behave alike, whatever `resolve_session` says (#2907). A step
resolves its session mode as an E3 child does: §0a's
`scripts/resolve-session.zsh` with the inferred mode `unattended`, autonomous
whatever its line says, so no step ever asks.

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

An issue-run step's handoff carries the step-handoff/v1 fields and three more,
which a reader that does not read them ignores:

```json
{ "schema": "step-handoff/v1", "issue": 2940, "chained_from": 2907,
  "origin": "human", "scratch_dir": "/abs/scratch", "answers": [],
  "kind": "issue", "parent_run_id": "<the root's run_id>",
  "start_at": "0a", "risk": null }
```

`start_at` is `"0a"` for a first run, or `"1"` for the fresh step that follows a
refinement's `ready`. That step skips §0a and §0b, carries `risk` from the
`ready` verdict, and records `dependency_precheck: PROCEED` and
`gate_verdict: READY`. It never runs a second gate. A step whose handoff `issue`
differs from its `chained_from` is an E3 child's run, which §2 parks by
terminal (c). A refinement step's handoff is the plain step-handoff/v1 object
plus `"kind": "refinement"`.

**Read every verdict against the contract** before acting on it:

```bash
jq -e -s --argjson n <N> 'length == 1 and (.[0] | (.schema == "step-verdict/v1")
  and (.issue == $n)
  and (.follow_ups | type == "array" and all(type == "number" and . >= 1 and . == floor))
  and ((has("run_id") | not) or (.run_id | type == "string" or . == null))
  and (if .verdict == "done" then (.pr | type == "number")
       elif .verdict == "needs-refinement" then (.reason | IN("gate", "size"))
       elif .verdict == "ready" then (.risk | IN("low", "normal", "elevated")) and (.auto_accepted | type == "array")
       elif .verdict == "split" then (.children | type == "array" and length > 0)
       elif .verdict == "blocked" then (.blockers | type == "array")
       elif .verdict == "questions-pending" then (.questions | type == "array" and length > 0) and (.resume | type == "string") and (.round | type == "number" and . >= 1)
       elif .verdict == "stopped" then (.reason | type == "string" and test("\\S"))
       else false end))' <scratch_dir>/step-<N>-verdict.json
```

**A step that ends its turn with no verdict file is messaged to carry on, not
counted as failed.** Send it one SendMessage asking it to finish and write the
verdict file. A verdict the check above rejects gets the same message, naming
the field that fails. Only a step that still writes no valid verdict is a
failure: report it and emit nothing on the step's behalf. A single-issue root
then stops the chain. In an epic, the root treats it as a tooling failure of
that child: it parks the child, quotes the failure in the epic summary, and
continues E3.

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
  its own.

## The issue step (#2940)

The brief the root dispatches for an issue-run step, whether the named issue's
own run or an E3 child's run:

```text
You are a step of a human-started /development:resolve-issue chain (#2940).
STEP_HANDOFF=<scratch_dir>/step-<N>-handoff.json
Invoke the development:resolve-issue skill with "<N>" plus the root's telemetry
flags and its --no-review when given, and run its Single-issue flow as a step.
Read the handoff first with
"<skill-base-dir>/../refine-issue/scripts/chain-result.zsh" read-handoff --file "$STEP_HANDOFF",
where <skill-base-dir> is the resolve-issue skill's base directory. On its exit 1
or 2, write verdict stopped with the reason "unreadable step handoff".
Take its origin and parent_run_id. In place of Step 0's start, run
story-telemetry.zsh start --run-file <scratch_dir>/story-run-<N>.json
--parent-run-id <parent_run_id> --origin <origin> with the telemetry flags,
then start at its start_at. Resolve the session mode as an E3 child does
(inferred unattended, autonomous whatever the line says), but move any kept
state aside without --resume, deleting nothing, as an attended run does.
Never ask the human anything, never dispatch a step, and never launch a
headless claude. Before you end your turn, write <scratch_dir>/step-<N>-verdict.json
(step-verdict/v1, ARCHITECTURE.md *Step verdict contract*), listing every
follow-up issue you filed in follow_ups and your run's run_id in run_id.
```

The step ends with one of these verdicts:

- `done` with the PR.
- `needs-refinement`, with `reason: "gate"` after §0b's park or
  `reason: "size"` after §2's park.
- `blocked`, with the blockers §0a found.
- `stopped`, with the reason, for any other ending: an escalation, a clean
  stop, a red gate or a failure.

How the root handles each:

- **`done`** → report the PR. In an epic, continue E3.
- **`needs-refinement`** → dispatch *The chained refinement step (#2940)* on
  the same issue.
- **`blocked`** → until #2941 lands, the root handles it as §0a's autonomous
  arm handles a rejection: the step already posted the comment and the label,
  so the root reports the blockers and stops, offering no remediation. In an
  epic, the root parks the child as E3 parks a dependency rejection and
  continues with the children that don't depend on it.
- **`stopped`** → report the reason and stop. In an epic, triage the child as
  E3 triages an escalation.

## The chained refinement step (#2940)

The root dispatches a chained refinement step in three places:

- on a `needs-refinement` verdict, whether its reason is the §0b gate or the §2
  size park;
- once per unready leaf at E1b;
- on an E3 child that comes back parked by §2.

**One refinement per issue and reason.** A second `needs-refinement` for the
same issue and reason in one run, or a leaf already refined in this run that
re-gates `NEEDS_REFINEMENT` at E1b, is never chained again. The root takes the
`stopped` arm below, with the reason that the park recurred after a `ready`
refinement.

The brief:

```text
You are a chained refinement step of a human-started /development:resolve-issue
chain (#2940). Run /development:refine-issue <N> --chained-from <root>
--handoff <scratch_dir>/step-<N>-handoff.json. Never ask the human anything.
When it prints its chain-result/v1 document, write it as the step verdict:
  jq '{schema: "step-verdict/v1", issue, verdict: .outcome, follow_ups: []}
      + del(.schema, .issue, .outcome)' > <scratch_dir>/step-<N>-verdict.json
and end your turn.
```

A refinement step's `follow_ups` is always `[]`: a chain-result/v1 document
lists no filed issues other than a split's children.

A refinement step ends with the verdict its chain-result outcome names, and with
no other:

- **`ready`** → the issue is ready to build.
  - **A single-issue entry:** dispatch a fresh issue step with `start_at: "1"`
    and the verdict's `risk`.
  - **A leaf at E1b:** the leaf is READY for E1b, with the verdict's `risk`.
    Nothing is dispatched for it until E3 builds it.
  - **An E3 child:** dispatch its fresh issue step with `start_at: "1"` and the
    verdict's `risk`, in the child's place in the walk.
- **`split`** → the issue is now a parent.
  - **A single-issue entry:** the root resolves the parent with the Epic flow as
    written. Its children are the new leaves.
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
