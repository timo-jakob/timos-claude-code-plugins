<!-- Shard of reference/promotion.md (#2057), read in its index's order:
     the gate, the enable_suggestions condition, the telemetry id, steps 1-2. -->

## Suggestion promotion on convergence — human-curated, opt-in (#994)

> **Read the #1226 amendment in `reference/promotion/step-8-status-files.md`
> BEFORE acting on steps 3 and 4** (`reference/promotion/step-3-select.md` and
> `reference/promotion/step-4-sub-loop.md`). Two things the frozen text says or
> shows are superseded there. The enrichment of step 3 passes the run's
> `--telemetry-dir` as well as its `--telemetry-file`, where the frozen text
> says to pass no `--telemetry-dir`. And every sub-loop invocation of step 4
> carries the run's `loop_args`.

**A third gate condition — the `enable_suggestions` setting.** The frozen text
below says *both conditions*; there are now three. Before offering the phase,
run:

```bash
"<skill-base-dir>/scripts/suggestions-enabled.zsh"
```

It prints `on` or `off` from the `enable_suggestions` environment variable,
which a human sets in the `env` block of their Claude Code settings. It is on by
default — unset, `""`, and any unrecognised value are `on`; `0`, `false`, `no`
and `off`, in any case, are `off`. Take its word; do not judge the variable
yourself.

- **`on`** → the gate is unchanged: offer the phase when the run is interactive
  and the waived set is non-empty.
- **`off`** → **skip the phase entirely**, exactly as an autonomous run does:
  present no prompt, pass no `--promote`, emit **no** step 3 enrichment record
  (nothing was offered, so nothing was declined), and converge with every
  suggestion waived. Say so in one line in the conversation — "suggestion
  promotion skipped: `enable_suggestions` is off; N suggestion(s) waived" — and
  continue to the version bump (§4). The waived suggestions still
  land in the dossier's *Waived suggestions* list, as on any run that promotes
  nothing.

Whether a human is present is §0a's determination, read from
`scripts/resolve-session.zsh`: `attended` takes the interactive arm, `unattended`
takes the autonomous arm and never prompts.

<!-- moved: suggestion-promotion -->
Low suggestions never block, so every one the panel raises is **waived** the
moment it is surfaced — logged and never actioned. That is the right default,
but it leaves a human no way to say *"actually, do that one"* at the one moment
they have the full picture and the PR is otherwise ready. This phase is that
opt-in, and nothing else: **suggestions stay non-blocking by default and nothing
is ever auto-promoted.**

**Gate — both conditions, or skip the phase entirely.** Offer it only when the
run is **interactive** (the same human-present determination §0a's remediation
uses) **and** the waived set is non-empty. An **autonomous / headless run never
prompts and never passes `--promote`**: it converges with its suggestions
waived, byte-identically to before this feature existed. Selecting *none* skips
the sub-loop and converges unchanged — but it is still a **presented prompt**, so
step 3's enrichment record (`suggestions_promoted: 0`) is emitted *first*
(subject to step 3's no-id rule — an absent or empty sidecar means no record at
all). Only
an autonomous / headless run, which never prompts, is byte-identical to before
this feature existed.

**First, locate the run's telemetry id (#995).** The blocking phase's terminal
exit wrote the `run_id` of the record it just emitted to
`<blocking-phase-work-dir>/.telemetry-run-id`. Step 3 reads it **directly from
there**, inline, at the moment it emits:

```bash
cat <blocking-phase-work-dir>/.telemetry-run-id     # the join key, read at emit time
```

Two things not to do with it, each of which silently breaks the join:

- **Do not hold it in a shell variable.** Step 3's emit runs after one or more
  `AskUserQuestion` turns, and each `bash` invocation is its own shell — a
  `RUN_ID=…` set here is unset there, the emitter refuses the empty `--run-id`
  with exit 2, and the "never fatal" rule below swallows it, so the enrichment
  silently never lands, on every run.
- **Do not copy it to a fixed scratch path first.** A scratch dir is reused
  within a session (a human resolving several issues back to back; a re-run
  after an escalation), and a copy that fails — the source is absent whenever
  telemetry was skipped, and it fails *silently* — leaves an **earlier story's**
  id at that path to be read as this run's. The work-dir path has no such
  hazard: it is per-run, and the loop clears it on a fresh start and rewrites it
  on every terminal exit.

**Absent or empty is not an error.** Most often it means no record was emitted —
telemetry is best-effort — and there is then nothing to join to: skip the
enrichment entirely and run the phase as normal. Before concluding that, confirm
the path you are reading is the **blocking phase's** `--work-dir` (the one you
passed at §3.5), not a defaulted temp dir or the sub-loop's. Never mint or invent
a `run_id` to fill the gap; a fresh id would validate cleanly and be permanently
orphaned.

1. **Derive the waived set.** It is the **cross-round union of distinct Low
   findings**, keyed `[file, line, dimension, title]`, over the status JSON's
   `round_changelists[]` — the same set `build-telemetry-record.zsh` already
   counts as `waived`, so the prompt and the telemetry record can never
   disagree. It is **not** the final round's `suggestions[]`: that converged
   round holds only *its own* Lows, and a suggestion raised in round 1 and never
   re-raised is still un-actioned work.

   The pipeline must **dedup first, then filter** — the order
   `build-telemetry-record.zsh` uses. Filtering first would offer a key that was
   a *blocker* in an early round and Low in a later one; telemetry excludes it
   (its earliest occurrence wins), so the two surfaces would disagree and the
   human could be offered an item that was already fixed as a blocker. (The
   mirror case — Low early, blocking-and-fixed later — keeps its Low priority and
   is still offered, because the earliest occurrence wins; it falls out as
   unmatched in step 4, and telemetry counts it as waived for the same reason,
   so the two surfaces still agree.)

   ```bash
   jq -c '[ .round_changelists[]? | (.blocking[]?, .suggestions[]?)
            | {file, line, dimension, title, priority: (.priority // "Low")} ]
          | unique_by([.file, .line, .dimension, .title])
          | map(select(.priority == "Low"))
          | map({file, line, dimension, title})' <status.json>
   ```

   **If the derivation fails or yields `[]`** — a malformed status file, or a
   `--no-review`/`SKIPPED` status with no `round_changelists` — there is no
   waived set: **skip the phase and converge unchanged**. Never treat it as an
   error, and never invent a set.

2. **Render it** as a numbered list — title · `file:line` · dimension — and
   **state the stake in one line**: promoted items become blockers, so if the
   sub-loop cannot clear them the run escalates and **no PR is opened this
   run**. A human promoting one cosmetic Low from an already-PR-ready change is
   entitled to know that before they pick, not after.
<!-- /moved: suggestion-promotion -->

**A chain step hands its waived set to its root (#3077).** A step of a
human-started run never asks, so it never offers this phase. Its verdict
carries `deferred` instead, on any verdict of a run whose review loop ran:
`suggestions`, the waived set step 1 derives from the blocking phase's status
file, or `[]` when `suggestions-enabled.zsh` prints `off`, and
`suggested_follow_ups`, each `{title, body}`, for every follow-up the
run would otherwise name only in prose without filing it. Both are `[]` when
there are none, and a follow-up the run filed goes in `follow_ups`, never here.
The root, which resolves its own mode once with `scripts/resolve-session.zsh
--inferred attended`, handles them before the verdict's own arm, except on an
attended clean stop:

- **An attended root asks once per step.** When `deferred` holds any item, it
  renders one numbered list, each suggestion as title · `file:line` ·
  dimension and each suggested follow-up by its title, and asks one
  question with AskUserQuestion: **File all** · **File the suggested follow-ups
  only** · **File none**, with "Other" taking the numbers to file. Filing work
  is a question of what to build, an `intent` question under ARCHITECTURE.md's
  *Decision rights*, so it is asked and never decided for the human. On a
  clean stop it asks after the extension's answer, Stop included, and after a
  grant only about the items its earlier list did not hold: the re-dispatched
  step resumes on the same status file, so its verdict derives the earlier
  items again.
- **An unattended root files every suggested follow-up** and no suggestion,
  which stays waived as in any unattended run.
- **Each filed item** becomes an issue, `gh issue create --title <title>
  --body-file <file>`, whose body names the step's issue and its PR when there
  is one, and is queued like a listed follow-up: `chain-queue.zsh add --entry
  <new> --kind follow-up --after <the entry that filed it>` (for an E3 child,
  its epic-kind entry), as the chain queue's step 2 adds and stops on its exits,
  with `--finding` the suggestion's `{file, line, dimension, title}`, or for a
  suggested follow-up
  `{"file": "follow-up", "line": null, "dimension": "follow-up", "title":
  <its title>}`. Nothing in `deferred` is dropped without the human's answer.

**Read on, in this order.** The phase continues in other shards: step 3 in
`reference/promotion/step-3-select.md`, steps 4–6 in
`reference/promotion/step-4-sub-loop.md`, step 7 in
`reference/promotion/step-7-terminal.md`, and step 8 with the #1226 and #1935
notes in `reference/promotion/step-8-status-files.md`. The read order is listed
in `reference/promotion.md`.
