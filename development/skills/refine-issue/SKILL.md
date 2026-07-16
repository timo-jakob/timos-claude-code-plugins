---
name: refine-issue
description: >
  Take a GitHub issue the readiness gate sent back (`needs-refinement`) and drive
  it interactively to READY — the guided path from "no" back to "ready". A human
  is present throughout: you diagnose the story with `story-readiness`, then loop
  the `issue-refiner` agent (per-turn: explanation, questions, recommendations, a
  draft rewrite, a proposed `story-spec/v1` block) relaying between it and the
  human until they approve a rewrite. Then you write back the human-approved prose
  plus a provenance-stamped `story-spec` block (a human-authored issue edit, NOT a
  bot PR), re-gate, remove the `needs-refinement` label only if READY, and post a
  before/after comment trail. When a session can't converge, take a typed parked
  exit (needs-decision / split-recommended / deferred) that a later run resumes
  from (#578). Pointed at an epic, it walks each needs-refinement child through
  that single-issue flow and posts an epic-level summary (#580). The intelligence lives in the
  agent, this skill is the conductor. Composes story-readiness (#559) and
  issue-refiner (#575); consumes the story-spec/v1 contract (#574).
disable-model-invocation: false
---

You are the **conductor** of an interactive refinement session. A story failed
the `story-readiness` gate and carries `needs-refinement`; a human wants to fix
it. The **intelligence is in the `issue-refiner` agent** (#575) — a per-turn pure
function; **you** relay between it and the human, and **you** own every GitHub
write. The payoff of doing this well: the story reaches the implementer precisely
specified, and a durable machine-readable `story-spec/v1` block rides along.

**User input:** an issue number or URL. Operate on the session's repo
(`gh repo view --json nameWithOwner`); the issue must belong to it. If empty,
print `/development:refine-issue <issue-number|url>` and stop.

**Epic or single issue? (#580)** First classify the target
(`gh issue view <N> --json labels,body`): it is an **epic** when it has
**native sub-issues** (the resolve-issue shared reader,
`read-sub-issues.zsh --repo "$REPO" --epic <N>`, reports `summary.total > 0` —
the authoritative signal, #802), when it carries the `epic` label, or when its
body holds a task list of child issues (`- [ ] #N` — the un-backfilled shape).
A **failed** reader call (nonzero exit) is a classification failure — report
it and stop; never fall back to the label/task-list signals as if the native
signal were checked and absent (a native-only epic would misclassify as a
single issue, and you'd refine the epic body itself — which the guardrails
forbid). An epic → the **Epic walk** below; anything else → the single-issue
flow (Steps 0–7).

## Epic walk — refine every needs-refinement child (#580)

When pointed at an epic, you don't refine the epic itself — you **walk its
`needs-refinement` children** through the single-issue flow, then report. The
story-readiness epic pre-flight (#559) can park several children at once, and
this is the guided pass that clears them.

1. **Enumerate the refinable children** with the enumerator (it reads the
   epic's **native sub-issues** through the shared reader — the #802 contract;
   the body's markdown task list is only the human-readable view — and keeps
   the **open** ones carrying `needs-refinement`, in sub-issue order):

   ```bash
   "<skill-base-dir>/scripts/list-refinement-children.zsh" --repo "$REPO" --epic <N>
   ```

   **Branch on the exit code, not just the output.** A **nonzero** exit (3:
   gh/jq/reader failed) is an enumeration **failure** — report it and stop
   *without* claiming the epic has no refinable children; an empty result is
   only meaningful on exit 0.

   **Exit 0 with no children returned** → classify the zero before concluding
   (#798's lesson — an un-backfilled epic and a nothing-to-refine epic
   enumerate identically). Read
   `read-sub-issues.zsh --repo "$REPO" --epic <N>`: when `summary.total == 0`
   **and** the body still holds `- [ ] #N` task-list lines, the epic is
   **un-backfilled** — its `needs-refinement` children are invisible to the
   native enumerator. Run resolve-issue's
   `backfill-sub-issues.zsh --repo "$REPO" --epic <N>` (`--dry-run` first and
   vet the plan, per resolve-issue E1's hazard note — context refs are not
   children), then **gate on its outcome exactly as E1 does**: re-enumerate
   only after the backfill exits 0 with every markdown child accounted for in
   `added`/`already_present` and `skipped_cross_repo` empty. On exit 5
   (partial) or 1, or with cross-repo leftovers, report the **backfill
   failure** to the human, naming the unattached children — never the
   "no children to refine" terminal, which a failed backfill would satisfy
   vacuously — and stop. Only when a *clean* backfill's re-enumeration is
   still empty tell the human the epic has no `needs-refinement` children to
   refine, and stop.

2. **Walk each child in turn** through the **single-issue flow** (Steps 0–7) —
   reuse it as written, one child fully before the next. A child either reaches
   `READY` (its label cleared, Step 5) or takes a **typed parked exit** (Step 2);
   a parked child does not halt the walk — record it and continue to the next.

3. **Post an epic-level summary** on the epic issue: for each child, whether it is
   now **ready** (label cleared) or **still parked** (with the park type), plus
   any that had no work to do. **A ready child's line also notes its expected
   docs pages (#768)** — the refiner's `expected_docs_pages` from that child's
   final turn (e.g. `· docs: docs/how-to/use-the-rest-api.md`), omitted when the
   field is `[]` (a no-surface child has no docs duty) — so the epic's docs
   impact is legible at refinement time, before resolve-issue's same-PR
   user-docs step (#767) enforces it at build time. Then re-run the enumerator
   (or note the still-open
   `needs-refinement` set) so the summary reflects the true post-walk state. This
   is the roll-up a human reads to see the epic's refinement progress at a glance.

The walk is **resumable**: re-running on the epic re-enumerates and continues
from whichever children are still `needs-refinement`.

## Step 0 — fetch, and check the precondition

```bash
gh issue view <N> --json number,title,body,state,labels,url,comments
```

- If `state` is not `OPEN`, stop — nothing to refine.
- **Precondition — the `needs-refinement` label.** This skill is for stories the
  gate sent back. If the label is **absent**, **warn and confirm** before
  proceeding ("this issue isn't marked `needs-refinement`; refine it anyway?") —
  you can refine a story that was never formally gated, but the human should
  choose that deliberately. If they decline, stop.
- Read the issue's **prior gate comment(s)** in the thread — the refinement
  questions the gate already posted are the objections you start from.
- **Resume a parked session if one exists (#578).** A prior run may have taken a
  **typed parked exit** (Step 2 below) rather than converging. Check the comments
  for its machine-findable resume state and, if present, carry it into this
  session so you continue instead of restarting:

  ```bash
  gh issue view <N> --json comments -q '.comments[].body' \
    | "<skill-base-dir>/scripts/read-parked-state.zsh" > /tmp/parked.json
  case $? in
    0) : ;;  # parked previously — /tmp/parked.json has {type, open_questions, conversation, …}
    1) : ;;  # never parked — a fresh session, nothing to resume
    *) echo "parked-state read errored"; exit 1 ;;
  esac
  ```

  When a state is present, seed the Step 2 loop with it: its `conversation`
  becomes the refiner's initial `conversation`, and its `open_questions` (plus
  the park `type` and any `decision`/`owner`/`candidate_children`) are context
  the human is resuming from. Tell the human what the prior run parked on before
  continuing the loop.

## Step 1 — diagnose (fresh objections)

Spawn **`story-readiness`** (Task tool, `subagent_type: story-readiness`) on the
repo + issue to get a **current** verdict — the thread's comment may be stale
against the latest body. Take its `refinement_questions` as the authoritative
**objections** for this session. If it already returns `READY`, tell the human
the story now passes and offer to just clear the label (Step 5) — no loop needed.

## Step 2 — the refinement loop (human present)

Each round is one call to the **`issue-refiner`** agent (Task tool,
`subagent_type: issue-refiner`). Pass it **one JSON object**:

```json
{
  "repo": "owner/name",
  "issue": { "number": <N>, "title": "…", "body": "… current body …" },
  "objections": ["… from Step 1 (or the still-open ones next round) …"],
  "conversation": [ { "role": "refiner"|"human", "text": "…" } ],
  "human_reply": "… the human's latest reply (empty on the first round) …"
}
```

Then relay its returned JSON to the human in readable form:

- **`explanation`** — *why* each objection blocks the story (so the human
  understands the gap);
- **`questions`** — surface them and **collect the human's answers**;
- **`recommendations`** — the concrete rewrites it suggests;
- **`proposed_prose`** / **`proposed_story_spec`** — the draft, when it has one.

Append this round (your relayed summary + the human's reply) to `conversation`
and call the agent again with the human's `human_reply`. **Converge when the
agent reports every objection `resolved: true` AND `questions == []`** — its
`resolved_objections` drives this decision (that is its whole purpose). Then
present the **final `proposed_prose` + `proposed_story_spec`** and get the
human's **explicit approval of the exact rewrite**. Nothing is written until they
approve. If they want changes, feed their reply back for another round.

### Step 2 — the typed parked exit (#578)

Not every session reaches `READY` in one sitting. When the human decides it
**can't converge now**, take a **typed parked exit** — an early exit from this
loop (not the Step 5 post-re-gate path) that captures the state so a later run
resumes (Step 0) instead of losing the conversation. Mirrors resolve-issue's
typed escalation (#564), for the human-present refinement loop. Three types:

- **`needs-decision`** — an absent stakeholder / upstream decision blocks a
  testable spec. The state names the `decision` and its `owner`.
- **`split-recommended`** — the story is really an epic; it can't be one bounded
  spec. The state lists the `candidate_children`.
- **`deferred`** — the human pauses without converging. The `conversation`
  so far is preserved.

Build the parked comment with the script (never hand-roll the marker) and post
it as the human, exactly like every other refine-issue side effect. The state
object carries the type, the still-**`open_questions`**, the `conversation`, and
the type-specific fields:

```bash
# /tmp/parked-state.json — the structured state (type + open_questions +
# conversation + type-specific decision/owner or candidate_children)
# Guard the post on the build succeeding — a non-zero build (validation failure)
# must NOT post a blank/markerless comment, which would silently lose the resume.
if "<skill-base-dir>/scripts/build-parked-comment.zsh" \
     --issue <N> --state /tmp/parked-state.json > /tmp/parked-comment.md; then
  gh issue comment <N> --body-file /tmp/parked-comment.md
else
  echo "parked-comment build failed (see stderr) — not posting; fix the state and retry"
  exit 1
fi
```

A parked exit is deliberately **distinct from the Step 3 write-back and the
Step 5/6 path**:

- it **skips Step 3 entirely** — **no `story-spec` block is stamped** (the prose
  isn't finalized, so provenance never records an unfinished spec);
- it **keeps the `needs-refinement` label** (the story still isn't ready) — do
  **not** remove it;
- the comment it posts carries the machine-findable `<!-- refine-parked: <TYPE>
  -->` marker + hidden resume state, which Step 0 of the next run reads back.

Then **emit telemetry** (Step 7, `outcome: "parked"` with the `park_type`) and
**stop** — tell the human the session is parked and how to resume
(`/development:refine-issue <N>`). Do not run Steps 3–6 on a parked exit.

> **Missing-persona routing (#668).** When the refiner flags that the story needs
> a persona the target repo's `personas/v1` registry lacks or fits poorly
> (typically in its `recommendations`), relay it and **route the human to
> `/development:define-personas`** to add or adjust the persona — you never invoke
> that skill automatically. Personas are **advisory**: the human may run it and
> come back with a real persona id, or proceed without one. Never block on it,
> and never let the refiner invent a persona id the registry doesn't contain.
>
> The agent is a **pure function** — it never touches GitHub. Do not ask it to
> post or edit; that is Step 3, and it is yours.

## Step 2.5 — spin out the test cases (hybrid model, #671)

Once the human approves the rewrite, and **before** you write the block back
(Step 3), reconcile the approved `proposed_story_spec`'s `test_cases[]` into
linked **`test-case` issues** — the hybrid model (#671): the cases live *both*
structured in the block (the gate-validatable source of truth) *and* as separate
backlog-visible issues, while staying implemented in the **same PR** as the story
(#577/#696), so tests and feature never drift.

A **surface-touching** story has outside-in `test_cases[]`; a **no-surface**
story has `test_cases: []` and this step creates nothing (proportionality). Drive
the reconcile primitive — never hand-roll the `gh issue create`/`close` calls:

```bash
# The NEW approved spec (from proposed_story_spec) and, if the issue already
# carried a story-spec block, the OLD one (for reuse + orphan detection):
"<skill-base-dir>/scripts/test-case-spinout.zsh" \
  --repo "$REPO" --story <N> \
  --spec <approved-spec.json> [--old-spec <current-block.json>]
```

It is **idempotent, keyed on `test_cases[].id`**: a new case is created, a case
whose id already links to an issue is edited in place, and a case dropped since
the last round has its orphaned `test-case` issue **closed with a comment**. It
prints the **reconciled `test_cases` array** (each entry's `issue` now populated)
to stdout — splice that back into `proposed_story_spec.test_cases` so the block
you write in Step 3 carries the issue links. (The `id` is the stable key across
rounds; keep it stable so reconciliation reuses rather than re-creates.)

There is deliberately **no `blockedBy`** between the story and its test-case
issues — same-PR closure (`resolve-issue`, #577/#696) makes ordering moot.

## Step 3 — write back the approved rewrite (human-authored)

This edit is **human-approved and human-authored** — you run it with the
session's own `gh` auth (the human's identity), **not** a bot token and **not** a
PR. You are editing the issue in place.

Assemble the new body from the approved prose and `proposed_story_spec` — with
its `test_cases[]` replaced by the **reconciled array from Step 2.5** (issue links
now filled in), so the block you write records which `test-case` issue each case
spun out to:

1. **Wrap the approved prose in the provenance sentinels** and drop any prior
   story-spec block (replace, never duplicate):

   ```text
   <!-- story-spec:prose:start -->
   … the human-approved prose …
   <!-- story-spec:prose:end -->
   ```

2. **Stamp provenance.** Write the prose region (the bytes *between* the
   sentinels, sentinel lines excluded) to a temp file and compute the canonical
   hash — the same primitive the gate recomputes with, so staleness stays
   detectable:

   ```bash
   PROSE_HASH=$("<skill-base-dir>/scripts/story-spec-prose-hash.zsh" --file <prose.txt>)
   ```

   Set the block's `provenance`: `generated_by` (e.g.
   `"issue-refiner via /development:refine-issue"`), `generated_at` (an ISO-8601
   UTC timestamp), and `prose_sha256` = `$PROSE_HASH`. The agent left these
   `null` on purpose — **you** finalize the hash over the *approved* prose,
   because the approved prose (not the agent's draft) is authoritative.

3. **Render the block** below the sentinel-wrapped prose, per the ARCHITECTURE.md
   *Story-spec contract*:

   ```text
   <details>
   <summary>🤖 machine-readable story spec (story-spec/v1) — generated, do not hand-edit</summary>

   <!-- a fenced ```json block holding proposed_story_spec, provenance now filled in -->

   </details>
   ```

4. **Write it** — the full body is sentinel-wrapped prose, a blank line, then the
   `<details>` block:

   ```bash
   gh issue edit <N> --body-file <new-body.md>
   ```

Confirm the block is valid JSON (`jq -e` the fenced object) before writing.

## Step 4 — re-gate

Spawn **`story-readiness`** again on the freshly-edited issue. Its verdict is now
authoritative — and, because a `story-spec` block now exists, its validation also
checks the block against the prose (it will pass: you just stamped the hash over
this exact prose).

**Relay the verdict's `advisories` to the human (#668).** The re-gate may return
non-blocking `advisories` — e.g. a `story-spec` `personas` reference to a persona
id that isn't in the target repo's `personas/v1` registry, or a stale registry.
These **never** block (the story can still be `READY`), but the human should see
them: surface each advisory's `message`, and when it names a missing/ill-fitting
persona, route the human to **`/development:define-personas`** (as in Step 2) so
they can add or fix it and, optionally, re-run refine-issue to reference it.

## Step 5 — resolve the label, honestly

- **`READY`** → remove the label; the story is buildable:

  ```bash
  gh issue edit <N> --remove-label needs-refinement
  ```

- **`NEEDS_REFINEMENT`** → **keep the label** and report the remaining reasons to
  the human. Do not remove it on a story the gate still rejects — the label is
  the honest signal. Offer another loop (back to Step 2) or to stop here.

## Step 6 — the before/after comment trail

Post one durable comment recording **what changed and why**, so the issue is a
self-contained record: the objections you started from, a short before/after of
the prose (or a note that the full diff is in the edit history), the re-gate
verdict, and the resulting label state. This is the audit trail a later reader —
or `resolve-issue` — relies on.

## Step 7 — emit telemetry (both endings, #579)

Every refine-issue run — whether it reached `refined-ready` (Steps 3–6) **or**
took a typed parked exit (Step 2) — appends **one** JSONL record so the plugin
self-improvement handoff can learn where refinement helps and where it stalls.
Mirror the review-loop telemetry (#566): same sink convention, and **never let a
telemetry failure break the run** (`|| true`).

Build the record from the run's summary and append it to the git-ignored sink:

```bash
# /tmp/refine-state.json — this run's summary:
#   {rounds, objections_raised, objections_resolved,
#    outcome: "refined-ready"|"parked", park_type|null, risk_classification}
mkdir -p "$REPO_ROOT/.claude/telemetry"
"<skill-base-dir>/scripts/build-refine-telemetry-record.zsh" \
  --state /tmp/refine-state.json --issue <N> --wall-s <seconds> \
  >> "$REPO_ROOT/.claude/telemetry/refine-issue.jsonl" || true
```

- `outcome` is `refined-ready` when Step 5 re-gated `READY` and the label was
  cleared; `parked` when Step 2 took a typed parked exit (carry the `park_type`).
- `objections_raised` / `objections_resolved` come from the Step 2 loop's
  `resolved_objections` tally; `rounds` is the loop's round count.
- Emit **exactly one** record per run, at whichever ending the run reached. On a
  parked exit, emit it as part of stopping (after Step 2 posts the parked
  comment).

## Guardrails

- **The intelligence is the agent; you are the conductor.** Never invent the
  refinement judgment yourself — spawn `issue-refiner`. Never let the agent
  write to GitHub — every side effect (edit, label, comment) is yours.
- **Human-approved, human-authored write-back.** No bot token, no PR: you edit
  the issue with the human's auth, and only after they approve the exact rewrite.
- **The label tells the truth.** Remove `needs-refinement` **only** on a `READY`
  re-gate; otherwise it stays.
- **One canonical hash.** Compute `prose_sha256` with
  `scripts/story-spec-prose-hash.zsh` — never hand-roll it, or the gate's
  staleness check will disagree with what you wrote.
- **No `dependencies` in the block** — dependencies are GitHub-native `blockedBy`
  (#583), never in `story-spec`.
- **Spin out test cases with the script, not by hand (#671).** Step 2.5 runs
  `scripts/test-case-spinout.zsh` to create/reconcile/close the linked
  `test-case` issues; splice its reconciled `test_cases[]` (with issue links)
  into the block before write-back. Never open or close a `test-case` issue with
  a raw `gh` call — the script keeps the reconcile idempotent and orphan-closing
  consistent. Keep each case's `id` stable so re-runs reuse rather than duplicate.
- **A parked exit skips write-back and keeps the label (#578).** When a session
  can't converge, take the typed parked exit (Step 2): build the comment with
  `scripts/build-parked-comment.zsh` (never hand-roll the `refine-parked` marker),
  post it, **keep** `needs-refinement`, stamp **no** `story-spec` block, and stop.
  A later run's Step 0 resumes from it via `scripts/read-parked-state.zsh`.
- **Epic → walk the children (#580)** — pointed at an epic, enumerate its
  `needs-refinement` children with `scripts/list-refinement-children.zsh` and run
  each through the single-issue flow, then post an epic-level summary. Never
  refine the epic issue itself; a parked child doesn't halt the walk.
