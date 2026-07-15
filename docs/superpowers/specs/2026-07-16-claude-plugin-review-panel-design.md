# claude-plugin review panel — closing the step-3.5 gap for plugin repos

**Date:** 2026-07-16
**Relation:** surfaced by the `/development:resolve-issue 798` run on 2026-07-15,
where step 3.5's local review loop no-oped. Extends the autonomous review loop
(epic #557: finding schema #558, dispatch #560, consolidator #561, loop #562,
dossier #563). Independent of the WebUI, telemetry, docs, and
release-engineering tracks.

## Motivation

`/development:resolve-issue`'s step 3.5 runs a local review panel before any PR
is opened, so CI minutes are only ever spent on code a reviewer panel has already
converged on. In **this repo it never runs**:

```console
$ development/skills/resolve-issue/scripts/review-dispatch.zsh plan --repo . --base origin/main
{"error":"unsupported_repo_type","languages":[],
 "supported":["swift","python","java"],
 "detail":"no review panel exists for the detected languages"}
```

`review-dispatch.zsh` derives `repo_type` solely from `detect-stack.sh`'s
`.languages` array. A claude-plugin repo detects **no language** — its content is
instructional prose, agent definitions, zsh scripts, and JSON manifests — so
every plugin-repo PR skips the panel and reaches review unreviewed.

This is not hypothetical. **#798 was a prose-logic bug**: the epic flow's E1
terminal case treated "zero open children" as proof the work had merged, with no
failure branch for the inline-slice case. It was caught by a human noticing a
live run, not by any gate. A reviewer reading that diff could plausibly have
caught it — but no panel existed to read it.

The gap compounds: this repo is where the plugins themselves are authored, so it
is the one repo whose defects propagate to every other repo the family touches.

## Decisions (settled in brainstorming, 2026-07-16)

1. **Prose-logic defects are the panel's headline**, not an afterthought. In a
   plugin repo the shipped artifact is mostly instructions; a skill's prose *is*
   its behaviour. Script/manifest dimensions support that core, and mechanical
   validation alone was rejected precisely because it would not have caught #798.
2. **claude-plugin is a fallback `repo_type`, not a composing topic.**
   ARCHITECTURE.md treats claude-plugin as a topic plugin composing *alongside* a
   language, but the review descriptor names exactly one `review_skill`.
   Generalizing to `review_skills[]` would change the contract and every
   consumer. A repo that is both a language repo and a plugin repo keeps its
   language panel and gets no plugin review — accepted as YAGNI until such a repo
   exists.
3. **Five agents, full parity** with the language panels' shape.
4. **prose_logic severity is bounded by a behavioural bar** (below) so the loop
   converges instead of drowning in wording nitpicks.
5. **The panel is verified against #798 as a golden fixture**, not asserted.
6. **Two issues under an epic**, child 2 `blockedBy` child 1.

## Architecture

### The ordering constraint

If dispatch returns `claude-plugin` before `development-claude-plugin:review`
exists, the loop invokes a skill that is not there — strictly worse than today's
clean typed error. **The panel must land before the flip.** This is a real
`blockedBy` edge (#583: declare it natively), not a preference.

The two halves live in different plugins (`development-claude-plugin` vs
`development`), so they bump separate version manifests and cannot collide on the
version line.

### Child 1 — `development-claude-plugin:review` (the panel)

`development-claude-plugin/skills/review/SKILL.md`, modelled on
`development-python/skills/review/SKILL.md`:

- **Step 1** launches all five agents in a single message, injecting the #558
  JSON-emission directive into each launch prompt, substituting that agent's
  `dimension` and `reviewer` name. Per ARCHITECTURE.md, this directive lives in
  the skill and **not** in the agent definitions, so the agents stay pure prose
  reviewers.
- **Step 2** concatenates every agent's array into one findings array for the
  round and writes it to the caller-supplied `findings_path` (default
  `review-findings-round-<round>.json`). Aggregation is flat concatenation — each
  finding is self-describing.

Five new read-only agents (`tools: Read, Grep, Glob`):

| Agent | Dimension | Model | Reviews |
| --- | --- | --- | --- |
| `claude-plugin-prose-logic` | `prose_logic` | fable | Skill/agent instructions as behaviour: missing failure branches, unstated assumptions presented as verified fact, contradictions between sections, model-ambiguous decision rules |
| `claude-plugin-contract-integrity` | `contract` | opus | Dangling skill/agent/script references, prose-vs-script flag and subcommand drift, ARCHITECTURE.md schema drift |
| `claude-plugin-script-reviewer` | `script_quality` | fable | zsh logic: exit codes, quoting, error paths, unhandled failure modes — logic review, not a shellcheck re-run |
| `claude-plugin-test-reviewer` | `tests` | opus | bats coverage for changed scripts, weak assertions, untested failure branches |
| `claude-plugin-manifest-check` | `manifest` | sonnet | `plugin.json` ↔ `marketplace.json` lockstep, semver bump appropriateness |

**Model tiers follow the #804 ladder**, not convenience:

- `prose-logic` → **fable**: judging whether instructions will make a model act
  wrongly is architectural judgment, fable's stated row.
- `script-reviewer` → **fable**: it is bug-hunting in zsh, and #804 established
  that bug-hunter-shaped agents run on fable (it moved the security reviewers up
  so the bug-hunters were not alone there).
- `contract-integrity`, `test-reviewer` → **opus**: context-aware work that reads
  surrounding code to decide what is wrong.
- `manifest-check` → **sonnet**, *not* haiku: haiku's row is "no judgment", but
  judging patch-vs-minor requires reading the diff for intent — sonnet's row,
  whose own example ("summarize a diff into a commit message") is the same shape.
  The lockstep half alone would be haiku; the semver half raises it.

**Agent naming avoids the maintenance fixers.** `claude-plugin-script-quality`
and `claude-plugin-reference-checker` already exist as maintenance **fixers**
(they hold `Edit` and act on findings). Review agents are read-only and need
distinct names; the table above is collision-free against the existing five.

### Child 2 — the dispatch flip

`review-dispatch.zsh` gains one fallback rung. Selection ladder, in order:

| Condition | Result |
| --- | --- |
| a supported language matched | that language (today's behaviour, bit-for-bit) |
| 2+ supported languages | existing `.maintenance.yml primary` tiebreak, then `ambiguous_repo_type` (exit 3) |
| no language + `is_claude_plugin` | `claude-plugin` |
| no language, not a plugin | `unsupported_repo_type` (exit 3), as today |
| `detect-stack` failed | exit 1, as today |

**No new detection is needed** — `detect-stack.sh` already emits a top-level
`is_claude_plugin` boolean (it drives the Renovate path). The descriptor keeps
its shape; only the set of possible `repo_type` values widens:

```json
{
  "repo_type": "claude-plugin",
  "review_skill": "development-claude-plugin:review",
  "round": 1,
  "base": "origin/main",
  "findings_path": ".review/findings-round-1.json",
  "changed_files": ["development/skills/resolve-issue/SKILL.md"]
}
```

`is_claude_plugin` is read with a `// false` default so an older `detect-stack`
that omits the key falls through to the clean typed error instead of crashing.

Child 2 also corrects `resolve-issue`'s §3.5, which says to "use the dispatch
plan to pick `development-<lang>:review`" — the panel is no longer always a
language.

## The behavioural bar (prose_logic severity)

A prose reviewer can generate unbounded wording nitpicks. The loop blocks on
`CRITICAL`+`WARNING` and escalates after `MAX_REVIEW_ROUNDS=3`, so a chatty
prose-logic agent would make every plugin PR escalate — turning the panel into an
obstacle. The agent definition therefore encodes an explicit, falsifiable rule:

| Severity | Bar | Example |
| --- | --- | --- |
| `CRITICAL` | a model following this **will** act wrongly | #798: a terminal case with no failure branch; two sections licensing opposite actions |
| `WARNING` | a model following this **may** act wrongly | ambiguous antecedent on a decision rule; step order implied but not stated |
| `SUGGESTION` | wording, tone, or clarity with **no behavioural delta** | never blocks; waived by the loop and reported in the dossier |

**The rule:** a finding may not carry a severity `≥ WARNING` without naming the
concrete wrong action a model would take. If the reviewer cannot state the wrong
action, the finding is a `SUGGESTION`.

## Data flow

Unchanged from the language panels — that is the point of the fallback design:

```text
resolve-story-loop.zsh
  └─ --review-cmd
       ├─ review-dispatch.zsh plan          → descriptor names the panel
       ├─ invoke $review_skill (scope = changed_files)
       │    └─ 5 agents in parallel → prose + JSON array each
       │         └─ skill concatenates    → findings_path
       └─ review-dispatch.zsh scope-findings → drops findings outside the diff
  └─ consolidate-findings.zsh              → CRITICAL+WARNING = blockers
  └─ --fix-cmd → --test-cmd (full bats)    → converge, or escalate at round 3
```

`resolve-story-loop.zsh` needs **no change**: it already takes the panel as a
hook, and the dispatch descriptor is what names the panel.

## Testing

### Child 2 — dispatch selection (bats)

Extends the existing `tests/review-dispatch.bats` (not a new file), stubbing
detection through the `DETECT_STACK_BIN` seam that is already there for this:

| Case | Expect |
| --- | --- |
| `languages: []`, `is_claude_plugin: true` | `repo_type: claude-plugin`, `review_skill: development-claude-plugin:review` |
| `languages: ["python"]`, `is_claude_plugin: true` | `repo_type: python` — the no-regression case |
| `languages: []`, `is_claude_plugin: false` | exit 3, `unsupported_repo_type` |
| `languages: []`, key absent entirely | exit 3, no crash |

### Child 1 — the #798 golden fixture

The five agents are prose and cannot be unit-tested. #798 itself showed the trap
of writing behavioural acceptance criteria that are never actually run, so the
panel is **measured against a defect whose answer we already know**.

The panel takes a **scope**, not a diff — diff-scoping is `scope-findings`' job,
downstream. So the fixture needs no dispatch, which is what lets it ride with the
agent it measures rather than waiting on child 2:

- **Fixture:** `development/skills/resolve-issue/SKILL.md` as of `4202beb`
  (pre-#798), which contains the terminal case with no failure branch.
- **Driver:** `/development-claude-plugin:test`, which drives a headless session
  with the local plugins loaded via `--plugin-dir`.
- **PASS** iff `claude-plugin-prose-logic` reports a `prose_logic` finding at
  `≥ WARNING` naming the absent failure branch.
- **FAIL** on silence, or on `SUGGESTION`-only.

### Known limit — precision is not covered

The fixture proves **recall** on one known defect. It cannot prove
`claude-plugin-prose-logic` will not be chatty on ordinary diffs. A negative
control (a clean diff the panel must not flag) was considered and deliberately
deferred as speculative fixture work.

The real precision signal is the loop's own telemetry, which already exists:
`.claude/telemetry/review-loop.jsonl` (#566) records rounds-to-converge and
escalation breakdown per run. If plugin PRs begin escalating on `prose_logic`,
the behavioural bar is miscalibrated — a tuning question against real data,
rather than one to guess at now.

## Documentation deliverables

These are contract surfaces, not nice-to-haves:

- **ARCHITECTURE.md dimension enum** must list claude-plugin's extension. The
  core five dimensions never change meaning; a plugin may extend the enum the way
  Swift did with `swift6_compliance`. `tests` **reuses** the core dimension and
  its `*-test-reviewer` naming convention; `prose_logic`, `contract`,
  `script_quality`, and `manifest` are the documented extension. Omitting this
  drifts the schema contract silently.
- **`docs/reference/agents.md`** and **`docs/reference/plugins.md`** list every
  agent with model and tools — five new rows each. mkdocs builds `--strict`, so
  this is enforced, not optional.

## Scope — out

- **No `review_skills[]` composition** (decision 2). A language+plugin repo keeps
  its language panel.
- **No change to the language panels** (swift/python/java), their agents, or
  their dimensions.
- **No change to `resolve-story-loop.zsh`**, `consolidate-findings.zsh`, or the
  #558 schema itself — only the dimension enum's documented extension.
- **No wiring into `/development:maintenance`.** This panel serves the story
  loop; the maintenance validators already cover the whole-repo mechanical pass.
- **No negative-control fixture** (see Known limit).

## Delivery

| Issue | Deliverable | Plugin | Bump | Depends on |
| --- | --- | --- | --- | --- |
| Epic | Tracks both children | — | — | — |
| Child 1 | `development-claude-plugin:review` skill + 5 agents + #798 golden fixture + agent/dimension docs | `development-claude-plugin` | minor | — |
| Child 2 | `review-dispatch.zsh` fallback + bats + §3.5 wording fix | `development` | minor | Child 1 (`blockedBy`) |

Each child touches **one plugin's installable content** and bumps only that
plugin (root-level docs — ARCHITECTURE.md, `docs/reference/*` — carry no version
and ride with child 1). Each is independently reviewable, and the repo is never
in a broken intermediate state: child 1 is inert until dispatched and separately
useful (`/development-claude-plugin:review` is invocable by hand the day it
lands).

## Success criteria

- `review-dispatch.zsh plan --repo .` on this repo returns
  `repo_type: claude-plugin` and exits 0.
- A `/development:resolve-issue` run in this repo reports a **converged review
  loop with a dossier**, not `SKIPPED`.
- The #798 golden fixture passes: the panel flags the pre-#798 terminal case at
  `≥ WARNING`.
- `languages: ["python"]` still dispatches `development-python:review`.
