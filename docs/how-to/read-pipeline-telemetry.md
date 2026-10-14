# Read your pipeline telemetry

Every pipeline in the family's telemetry epic is instrumented — the review loop,
`/development:refine-issue`, `/development:resolve-issue` (story and epic mode),
`/development:maintenance`, `/development:bootstrap`, the acceptance stage and
the Approver; the [inventory](#which-pipelines-are-instrumented) below lists
what triggers each one's records. Each appends `telemetry/v1` JSONL records to a
local file outside every checkout (`~/.claude/telemetry/<repo-slug>.jsonl` —
see below), one per run **ending** — an extended review-loop run (escalate →
grant more rounds → resume) appends more than one such terminal record, so a
"run" here means one ending, not one whole loop. All of them share that one
file, so every query on this page names the `pipeline` it means.
`rollup-telemetry.zsh` gives you a one-command glance at how those pipelines are
doing — no Grafana, no infrastructure. (Cross-repo reporting via Grafana is a
separate, opt-in path — see the
[Grafana hand-off contract](../reference/telemetry-grafana-handoff.md).)

## Run it

```bash
zsh development/scripts/telemetry/rollup-telemetry.zsh
```

With no argument it reads every `*.jsonl` in `~/.claude/telemetry/` — the
user-level directory the pipelines write to by default — and shows **the repo
you are standing in**: run it from any checkout or worktree of the repo and it
reports every run of that repo, wherever it ran. Records of other repos are
left out, and stderr says how many (`note: excluded 3 record(s) of other
repos`). Pass `--repo OWNER/NAME` to look at another repo; run it outside any
git checkout and it shows every repo, saying so on stderr. If nothing has ever
emitted, that's silently an empty stream (`no records`), never an error.

```text
Pipeline: review-loop
  runs: 12
  outcome mix: success=9 parked=0 escalated=2 failed=1
  mean rounds: 3.4166666666666665
  mean wall_s: 612.5
  escalation rate: 0.16666666666666666
```

Point it at a specific file, a directory of files, or stdin:

```bash
zsh development/scripts/telemetry/rollup-telemetry.zsh path/to/stream.jsonl
zsh development/scripts/telemetry/rollup-telemetry.zsh path/to/shared-dir/     # every *.jsonl in it
cat path/to/stream.jsonl | zsh development/scripts/telemetry/rollup-telemetry.zsh -
```

## Filter it

```bash
zsh development/scripts/telemetry/rollup-telemetry.zsh --repo owner/name
zsh development/scripts/telemetry/rollup-telemetry.zsh --pipeline review-loop
zsh development/scripts/telemetry/rollup-telemetry.zsh --repo owner/name --pipeline review-loop
```

**`--repo` matches case-insensitively**, because GitHub identities are
case-insensitive but case-preserving — so `--repo Owner/Name` finds records
emitted as `owner/name`, and vice versa. (`--pipeline`, by contrast, matches
exactly: pipeline names are written verbatim by the pipelines themselves, not
supplied by a case-insensitive external identity provider.)

`--pipeline NAME` shows exactly one section for `NAME` — even with zero
matches, so "I looked, there's genuinely none" reads differently from a report
that's silently empty — **unless** no run records remain once `--repo` has been
applied: the stream held none at all, everything it held is excluded before any
filter runs (enrichment records, unrecognized `kind`s, non-`telemetry/v1`
schemas, malformed lines), or `--repo` excluded the rest. Then you get
`no records` instead, with no section at all: `--repo` emptying the stream wins
over the synthesized `--pipeline` section.

Every legacy (pre-contract) record — and any `telemetry/v1` record whose `repo`
is absent, `null`, empty or not a string — is attributed to an `unknown` repo
bucket. An unfiltered run counts
those normally; `--repo X` **excludes** them and prints a note to stderr naming
how many were excluded, so mixing old and new files never silently drops data.
`--repo unknown` is the one exception: it *selects* that bucket instead of
excluding it.

## Which pipelines are instrumented

Every pipeline of the instrumentation epic is **instrumented**; none was
deferred. The table says what appends a record, which envelope linkage the
record carries, and where its payload keys are listed. `issue`, `pr` and
`parent_run_id` are `null` wherever the table says so.

| Pipeline (`pipeline` value) | Status | A record is appended when | `issue` | `pr` | `parent_run_id` | Payload keys |
| --- | --- | --- | --- | --- | --- | --- |
| review loop (`review-loop`) | instrumented | each terminal exit of a review loop — never per round, and never on a resumable pause | the story | `null` | the resolve-issue run it ran under, else `null` | [review-loop](#review-loop) |
| `/development:refine-issue` (`refine-issue`) | instrumented | each single-issue refinement ends — an epic walk appends one per child | the issue | `null` | `null` | [refine-issue](#refine-issue) |
| `/development:resolve-issue`, story mode (`resolve-issue`, `payload.mode: "story"`) | instrumented | a single-issue run that reached the dependency precheck ends | the story | the opened PR, else `null` | the epic run for an epic's child, else `null` | [story mode](#resolve-issue-story-mode) |
| `/development:resolve-issue`, epic mode (`resolve-issue`, `payload.mode: "epic"`) | instrumented | each Epic-flow invocation ends — one record per invocation, not per epic | the epic | `null` | `null` | [epic mode](#resolve-issue-epic-mode) |
| `/development:maintenance` (`maintenance`) | instrumented | an invocation that passed the proceed/halt gate reaches its summary phase | `null` | `null` — its PRs are in the payload | `null` | [maintenance](#maintenance) |
| `/development:bootstrap` (`bootstrap`) | instrumented | every invocation, at whichever ending it reaches | `null` | the PR the run opened, else `null` | `null` | [bootstrap](#bootstrap) |
| acceptance stage (`acceptance`) | instrumented | you run `collect-acceptance-telemetry.zsh`: one record per completed `acceptance (<interface>)` check run attempt of the last 30 days | `null` | the run's PR | `null` | [acceptance](#acceptance) |
| Approver (`approve`) | instrumented | you run `collect-approver-telemetry.zsh`: one record per posted Approver review carrying its findings block, on PRs updated in the last 30 days | `null` | the reviewed PR | `null` | [approve](#approve) |

Two more record shapes share the sink without being pipelines of their own. The
**story size pre-flight** (`story-preflight`) appends one record per size
verdict a resolve-issue run reaches, parented to that run
([keys](#story-preflight)). The **suggestion-promotion enrichment** is a
`kind: "enrichment"` record on `pipeline: "review-loop"`, appended when a human
was shown the promotion prompt, and joined to its loop record by `run_id`
([keys](#review-loop-suggestion-promotion-enrichment)).

Three things decide where you find these records:

- **Bootstrap writes to the target repo's file**, not the plugin repo's: the
  record belongs to the repo it bootstrapped, so a rollup run from the plugin
  repo does not show it.
- **The acceptance and approve records exist only once you collect them.** Both
  stages run where the emitter is not — a CI job in the target repo, an
  Approver posting a review — so nothing is appended until you run the collector
  for a repo — `collect-acceptance-telemetry.zsh --repo OWNER/NAME` and
  `collect-approver-telemetry.zsh --repo OWNER/NAME`, both in
  `development/scripts/telemetry/`. Both are safe to re-run: a check run or
  review already in the sink file is skipped.
- **Every other skill emits nothing.** `/development:open-pr`,
  `/development:commit`, `/development:sync-prs`, `/development:cleanup`,
  `/development:define-personas` and the review panels are steps or tools, not
  pipelines of the epic, and are not instrumented — their work shows up, where
  it matters, inside a pipeline's own record.

## Payload keys by pipeline

`payload` is the part of a record each pipeline owns; the envelope around it is
the same for every pipeline. These tables list every top-level `payload` key of
each pipeline, so you can write a query without reading the emitting script.
The normative definitions, with every refusal rule, are the per-pipeline
sections of `ARCHITECTURE.md` named under each table.

### review-loop

| Key | Type | Meaning |
| --- | --- | --- |
| `status` | string | the loop's exact terminal status, before it is narrowed onto `outcome` |
| `escalation` | string or `null` | the escalation type on an escalation or budget exhaustion; `null` on every other status, a failed run included |
| `rounds` | integer | review rounds the loop ran — the key the rollup's `mean_rounds` reads |
| `max_rounds` | integer | the round budget the loop ran under |
| `promotion_phase` | boolean | `true` when this run is the suggestion-promotion sub-loop |
| `possible_false_trip_auto_continues` | integer | how often the loop auto-continued past a probable false trip |
| `findings_by_round` | array of objects | per round: `round`, `by_severity` (`Critical` / `Warning` / `Suggestion`), `promoted`, `by_dimension`, `by_class`, `new`, `carried`, `fixed_from_prev`, `false_trips` |
| `gate_by_round` | array of objects | per round: `round` and its test gate (`scope`, `attested`, `wall_s`, `slowest`, `jobs`), or `null` |
| `step_wall_s_by_round` | array of objects | per round: `round` and the `panel` / `decide` / `risk` / `fix` seconds, or `null` |
| `skipped_dimensions_by_round` | array of objects | per round: `round` and the review dimensions its panel left out, or `null` |
| `convergence_assessment` | object or `null` | `blocking_by_round`, `trend`, `blockers_moving`, `carried_final`, `possible_false_trips`; `null` when no round ran |
| `fixed` | integer | blocking findings found and cleared |
| `waived` | integer | distinct Low suggestions the loop logged |

Normative: `ARCHITECTURE.md`, *Review-loop telemetry*.

### review-loop suggestion-promotion enrichment

| Key | Type | Meaning |
| --- | --- | --- |
| `event` | string | always `suggestion_promotion` — which enrichment this is |
| `suggestions_offered` | integer | suggestions the human was shown; equal to the loop record's `waived` |
| `suggestions_promoted` | integer | how many the human picked — their answer, not work done |

Normative: `ARCHITECTURE.md`, *The suggestion-promotion enrichment*.

### refine-issue

| Key | Type | Meaning |
| --- | --- | --- |
| `rounds` | integer | refinement rounds the run took |
| `objections_raised` | integer | readiness objections raised over the run |
| `objections_resolved` | integer | how many of them were resolved |
| `park_type` | string or `null` | `needs-decision`, `split-recommended` or `deferred` on a parked run; `null` on a refined-ready one |
| `risk_classification` | string or `null` | the risk classification the refined story carries |

Normative: `ARCHITECTURE.md`, *Refine-issue telemetry*.

### resolve-issue, story mode

| Key | Type | Meaning |
| --- | --- | --- |
| `mode` | string | always `story` — what tells these records apart from epic mode's |
| `dependency_precheck` | string or `null` | `PROCEED`, `REJECT_BLOCKED` or `REJECT_CYCLE` — the last precheck the run ran; `null` when it errored |
| `gate_verdict` | string or `null` | the readiness gate's `READY` or `NEEDS_REFINEMENT`; `null` when the run ended before the gate |
| `risk` | string or `null` | the gate's risk on `READY`, else `null` |
| `story_spec_present` | boolean | the run consumed a `story-spec/v1` block |
| `review_loop_run_ids` | array of strings | the `run_id` of every review-loop record the run spawned |
| `escalation_status` | string or `null` | the escalation exit that ended the run; `null` on every run that did not end escalated |
| `fallbacks_fired` | array of strings | the same-PR steps that no-oped: drawn from `acceptance_tests`, `user_docs`, `c4_currency` |

Normative: `ARCHITECTURE.md`, *Resolve-issue telemetry*.

### resolve-issue, epic mode

| Key | Type | Meaning |
| --- | --- | --- |
| `mode` | string | always `epic` |
| `e1_classification` | string | how the invocation found the epic's children — `native_children`, `backfilled`, `inline_slices`, or a `halt_*` value |
| `children` | object | `total`, `completed_before`, `resolved_this_run`, `escalated`, `parked`, `queued` — every open child counted in exactly one bucket |
| `split` | object | `parallel` and `sequential`: how many children's PRs this run opened by each path (integers) |
| `child_run_ids` | array of strings | the `run_id` of every child run started this invocation |
| `e4` | object | `ran` (boolean) and `result` (`green`, `regression` or `null`) of the whole-epic verification |
| `e5_closed` | boolean | the epic was closed |
| `readiness_preflight` | object or `null` | `gated` and `needs_refinement` from the readiness pre-flight; `null` when the run never reached it |
| `failure_cause` | string or `null` | `e4_regression`, `e4_error`, `e5_error` or `error` — the run's final break; `null` otherwise |

Normative: `ARCHITECTURE.md`, *Epic mode (#1227)*.

### story-preflight

| Key | Type | Meaning |
| --- | --- | --- |
| `verdict` | string | `pass`, `stop` or `overridden` — `overridden` only on an explicit human answer |
| `triggers` | array of strings | which of `files`, `plugin`, `bootstrap-straddle` fired |
| `files` | integer | distinct files the change's inventory named |
| `plugins` | integer | distinct plugins owning them |
| `override_by` | string or `null` | `human` on `overridden`, else `null` |

Normative: `ARCHITECTURE.md`, *Story size pre-flight (#1437)*.

### maintenance

| Key | Type | Meaning |
| --- | --- | --- |
| `run_modifiers` | object | `dry_run`, `no_merge`, `batch`, `tool`, `concern`, `no_issues`, `resumed` — the invocation's flags |
| `resumed_from_run_id` | string or `null` | the interrupted run's `run_id` on a resume, when recoverable |
| `languages` | object | `detected` and `actionable`, each an array of strings |
| `topics` | array of strings | the topic plugins that dispatched |
| `findings_by_tool` | object | per tool, the findings dispatched, summed over targets |
| `groups` | object | `planned` (`null` on a dry run), `worked`, `deferred` |
| `prs` | object | `opened`, `merged`, `awaiting_approval`, `escalated` — arrays of PR numbers this invocation opened |
| `ci_fixer_rounds` | object | per opened PR, the ci-fixer rounds it took (0 to 3) |
| `escalations` | object | `human_action_required` (a count) and `ci_fixer_exhausted` (PR numbers) |
| `coverage_preflight` | object | `spawned`, `languages`, `pr` — the coverage improver this invocation ran first |

Normative: `ARCHITECTURE.md`, *Maintenance telemetry (#1228)*.

### bootstrap

| Key | Type | Meaning |
| --- | --- | --- |
| `mode` | string | `fresh`, or `gap_fill` on a re-run over a repo already bootstrapped |
| `target_repo` | string or `null` | the `owner/name` bootstrapped; `null` before it has a GitHub remote |
| `visibility` | string or `null` | `public` or `private` |
| `languages` | object | `primary` (string or `null`) and `auxiliary` (array of strings) |
| `topics` | array of strings | the topics the confirmed detection reported |
| `interfaces` | array of strings | the interfaces the confirmed detection reported |
| `host` | object | `os` and `homebrew` of the machine that ran it |
| `steps` | object | per applicable step, `written`, `merged`, `skipped`, `failed` or `already_present` |
| `files` | object | counts of files per disposition, over the same five values |
| `github_state` | object | `branch_protection`, `secrets`, `sonar_project`, `apps_installed` — each `applied`, `already_present`, `skipped`, `refused` or `failed` |
| `ending` | object | `stack`, `early_stop`, `approve_merge` — how the run ended |

Normative: `ARCHITECTURE.md`, *Bootstrap telemetry (#1229)*.

### acceptance

| Key | Type | Meaning |
| --- | --- | --- |
| `interface` | string | the leg's interface — `cli`, `rest`, `web-ui`, … |
| `conclusion` | string | the check run's conclusion, verbatim |
| `tests` | object | `passed`, `failed`, `skipped`, `total` from the JUnit report — all four `null` when it could not be read |
| `report_artifact` | object or `null` | `name` and `url` of the report artifact (the API URL, never a download link) |
| `harness` | string or `null` | `skeleton` when only the bootstrap smoke test ran, `real` when any other test did; `null` without a readable report |
| `check_run_id` | integer | the check run's id — what makes re-collecting safe |
| `head_sha` | string | the commit the check ran on |

Normative: `ARCHITECTURE.md`, *Acceptance telemetry (#1230)*.

### approve

| Key | Type | Meaning |
| --- | --- | --- |
| `verdict` | string | `APPROVE`, `REQUEST_CHANGES` or `COMMENT` |
| `confidence` | string | `HIGH`, `MEDIUM` or `LOW` |
| `risk_register_size` | integer | the review's risk-register findings |
| `dimensions` | array of strings | the review lenses the Approver walked, in order |
| `pr_type` | string | the PR type the Approver detected |
| `language` | string | which Approver posted it — `go`, `java`, `python`, `swift`, `claude-plugin`, … |
| `review_id` | integer | the review's id — what makes re-collecting safe |
| `head_sha` | string | the commit the review judged |
| `approver_version` | string | the findings block's version |

Normative: `ARCHITECTURE.md`, *Approver telemetry (#1231)*.

## Join nested runs through `parent_run_id`

Three pipelines nest. An epic run starts child story runs; a story run runs
review loops and size pre-flights. The **child** record carries its parent's
`run_id` as `parent_run_id`, and the parent lists its children in its payload,
so you can join from either end:

```text
resolve-issue (mode: epic)       payload.child_run_ids ----------+
  `- resolve-issue (mode: story)  parent_run_id = the epic run  <-+
       |                          payload.review_loop_run_ids ---+
       |- review-loop             parent_run_id = the story run <-+
       `- story-preflight         parent_run_id = the story run
```

Four things newcomers get wrong:

- **A review loop names its story run, never the epic.** To get from an epic to
  its review churn, go through the child runs.
- **Filter on `pipeline` as well as `parent_run_id`.** A story run's size
  pre-flight records carry the same `parent_run_id` as its review loops.
- **Filter on `kind == "run"`.** The promotion enrichment repeats its loop
  record's `run_id` and carries no `parent_run_id`, so it is reached through the
  loop record, never through the story.
- **One loop can leave several records.** An extended loop (escalate → grant
  more rounds → resume) appends a record per ending, each with its own
  `run_id` and the same parent, and their `wall_s` spans overlap — count them,
  never sum them.

A resolve-issue run together with its nested review-loop runs — set `S` to
your repo's file and `RUN` to the story run's `run_id`:

```bash
S=~/.claude/telemetry/timo-jakob-timos-claude-code-plugins.jsonl   # your repo's slug
RUN=resolve-issue-1791300100-1a2b
jq -s -c --arg id "$RUN" '
  map(select(.kind == "run")) as $runs
  | {run: ($runs[] | select(.pipeline == "resolve-issue" and .run_id == $id)
           | {run_id, issue, outcome, pr, mode: .payload.mode}),
     review_loops: [$runs[] | select(.pipeline == "review-loop" and .parent_run_id == $id)
                    | {run_id, outcome, rounds: .payload.rounds, wall_s}]}' "$S"
```

It prints one line — here a loop that escalated, was granted more rounds and
then converged, so the story has two loop records:

```json
{"run":{"run_id":"resolve-issue-1791300100-1a2b","issue":1226,"outcome":"success","pr":1765,"mode":"story"},"review_loops":[{"run_id":"review-loop-1791300200-0e1a","outcome":"escalated","rounds":5,"wall_s":2400},{"run_id":"review-loop-1791300200-7c3d","outcome":"success","rounds":7,"wall_s":3600}]}
```

It prints nothing when no resolve-issue run has that `run_id`. An epic run
with each of its child runs and the review loops of each — the same file, with
`EPIC` set to the epic run's `run_id`:

```bash
S=~/.claude/telemetry/timo-jakob-timos-claude-code-plugins.jsonl   # your repo's slug
EPIC=resolve-issue-1791300000-9f0e
jq -s -c --arg id "$EPIC" '
  map(select(.kind == "run")) as $runs
  | [$runs[] | select(.pipeline == "resolve-issue" and .parent_run_id == $id)
     | .run_id as $child
     | {child: $child, issue, outcome,
        review_loops: [$runs[] | select(.pipeline == "review-loop" and .parent_run_id == $child) | .run_id]}]' "$S"
```

```json
[{"child":"resolve-issue-1791300100-1a2b","issue":1226,"outcome":"success","review_loops":["review-loop-1791300200-0e1a","review-loop-1791300200-7c3d"]},{"child":"resolve-issue-1791303600-3c4d","issue":1227,"outcome":"success","review_loops":["review-loop-1791303700-5b6c"]}]
```

## Follow one story from outcome to review churn

`/development:resolve-issue` appends one `resolve-issue` record per story run
that reaches its dependency precheck. The record says whether the run opened a
PR (`success`), parked at the readiness gate or the precheck (`parked`),
escalated, or failed. A run that stops before the precheck, such as one on a
closed issue or a mistyped invocation, appends nothing. Every review-loop **run**
record the run spawned carries that record's `run_id` as its `parent_run_id`,
and the story record lists them in `payload.review_loop_run_ids`, so the join
works from either end. The one review-loop record outside that join is the
suggestion-promotion enrichment, which is reached through its loop record's
`run_id` instead:

```bash
S=~/.claude/telemetry/timo-jakob-timos-claude-code-plugins.jsonl   # your repo's slug
# the story runs: outcome, PR and how long each took — epic runs share the
# pipeline name, so the mode filter is what keeps them out
jq -c 'select(.kind == "run" and .pipeline == "resolve-issue" and .payload.mode == "story")
       | {issue, outcome, pr, wall_s, gate: .payload.gate_verdict}' "$S"
# every review-loop record of one story run
jq -c --arg id resolve-issue-1791300100-1a2b \
  'select(.pipeline == "review-loop" and .parent_run_id == $id)
   | {run_id, outcome, rounds: .payload.rounds}' "$S"
```

`payload.fallbacks_fired` says which same-PR steps no-oped on that story
(`acceptance_tests`, `user_docs`, `c4_currency`) — whether the acceptance-test
and docs lifecycles actually reach your stories. Every key is in the
[story-mode table](#resolve-issue-story-mode); the
[join above](#join-nested-runs-through-parent_run_id) returns a story run and its
loops in one query.

## Estimate how long a review-loop step takes

Every review-loop record also stores how long each round's steps took:
`payload.step_wall_s_by_round` holds the panel, decide, risk and fix times in
seconds, and `payload.gate_by_round` holds each gate's `wall_s` and the `jobs`
share it ran with. A step that did not run, or was not timed, is `null`, never
`0`. `estimate-step.zsh` turns those into a prior for one step, read from the
current repo's file in `~/.claude/telemetry/`:

```console
$ development/skills/resolve-issue/scripts/estimate-step.zsh --step panel
{"step":"panel","scope":null,"jobs":null,"repo_type":null,"n":6,"median_s":700,"p80_s":900}
```

For the gate, name the scope and, to compare runs made with different CPU
shares, the job count to scale them to. Each recorded gate becomes
`wall_s × recorded jobs ÷ N`:

```console
$ development/skills/resolve-issue/scripts/estimate-step.zsh \
    --step gate --scope full --jobs 5 --repo-type claude-plugin
{"step":"gate","scope":"full","jobs":5,"repo_type":"claude-plugin","n":6,"median_s":2400,"p80_s":2400}
```

`median_s` and `p80_s` are the median and the 80th percentile, in whole seconds.
`--repo-type` keeps only records of that repo type, and `--sink FILE` reads
another file. With fewer than 5 samples, which includes every record written
before the times were recorded, it prints nothing, says
`estimate-step: <n> samples, fewer than 5 — withheld` on stderr and exits `1`.
It exits `2` when it is called wrongly and `3` when the sink cannot be read.

## Machine-readable output

```bash
zsh development/scripts/telemetry/rollup-telemetry.zsh --json
```

Emits a bare JSON array, one object per pipeline:

```json
[
  {
    "pipeline": "review-loop",
    "run_count": 12,
    "outcome_mix": {"success": 9, "parked": 0, "escalated": 2, "failed": 1},
    "mean_rounds": 3.4166666666666665,
    "mean_wall_s": 612.5,
    "escalation_rate": 0.16666666666666666
  }
]
```

There's no cross-pipeline totals entry — every entry describes one pipeline,
`unknown` included as an ordinary one.

## What each measure means

| Measure | Meaning |
| --- | --- |
| `run_count` | How many `kind: "run"` records this pipeline has. Enrichment records (a second, later fact appended about an already-recorded run) are never counted here. |
| `outcome_mix` | How runs ended, narrowed onto the 4-value cross-pipeline enum: `success`, `parked`, `escalated`, `failed`. |
| `mean_rounds` | Average review/refinement rounds **per record**, not per logical loop — over records that actually recorded a round count. An extended review-loop run (escalate → grant more rounds → resume) contributes both its escalation's round count and its later convergence's, so this is not any one loop's round count. Only `review-loop` and `refine-issue` carry `payload.rounds`, so every other pipeline shows it withheld. |
| `mean_wall_s` | Average wall-clock seconds **per record**, not per logical loop — the same reason as `mean_rounds`: this rollup does not group an extended loop's records back into one loop. What a second measures differs by pipeline: an epic run's span contains its children's, an acceptance record's is the CI job's duration, and an approve record's is the time from the Approver's first step to its posted review. |
| `escalation_rate` | `escalated` runs divided by total runs, for that pipeline. Pipelines whose outcome table never uses `escalated` — `refine-issue`, `story-preflight`, `acceptance` and `approve` — show `0` by construction, not as a measured result. |

**These figures count *every* run record, including a review-loop
suggestion-promotion pass.** That pass is a second, terminal run of its own, so
it lands as its own record. Only `ARCHITECTURE.md`'s convergence-**rate**
recipes exclude it (`select(.payload.promotion_phase != true)`), and this rollup
prints no rate of that kind; its mean-rounds and escalation-breakdown cuts
deliberately **keep** the pass, exactly as these figures do. So a discrepancy
against those cuts is not promotion filtering — look to their other selections
instead.

**A measure you can't honestly compute is withheld, never guessed.** If no
record in a group carries a rounds count, `mean_rounds` prints `-` in text and
comes back `null` (the key stays present) under `--json` — the same rule
applies to `mean_wall_s` and `escalation_rate`. This is deliberate: a `0` here
would look like a real, measured zero rather than "nothing to measure."

**The `resolve-issue` section mixes story and epic runs.** Both modes write
`pipeline: "resolve-issue"`, so its `run_count`, outcome mix and `mean_wall_s`
count an epic invocation beside the child story runs it contains, and the
rollup cannot split them. Split by `payload.mode` instead:

```bash
S=~/.claude/telemetry/timo-jakob-timos-claude-code-plugins.jsonl   # your repo's slug
jq -s -c '[.[] | select(.kind == "run" and .pipeline == "resolve-issue")]
  | group_by(.payload.mode)
  | map({mode: .[0].payload.mode, runs: length,
         outcome_mix: (group_by(.outcome) | map({(.[0].outcome): length}) | add)})' "$S"
```

## Older (pre-contract) records are read too

Two files predate the `telemetry/v1` contract — `review-loop.jsonl` and
`refine-issue.jsonl` — and are never migrated; they stay exactly where they
are. The rollup reads them through a built-in adapter: it recognizes which
pipeline a legacy record belongs to (by filename, or by the shape of its
fields when the filename doesn't say), and narrows its old status/outcome
vocabulary onto the same 4-value enum newer records use. You don't need to do
anything to benefit from this — point the rollup at a directory holding both
old and new files and it aggregates all of it.

## Share it across repos (opt-in)

By default nothing leaves your machine. If you *want* several repos' telemetry
in one place — for a separate reporting stack to read — point the **emitter** at
a shared directory:

```bash
zsh development/scripts/telemetry/emit-telemetry.zsh \
  --pipeline example --outcome success --wall-s 42 \
  --telemetry-dir ~/telemetry-share
```

> **This appends a real record.** The emitter has no dry-run: what it writes is
> indistinguishable from a genuine run to every consumer of that directory, and
> the sink is append-only. So the example uses `--pipeline example` — the
> identifier is open — rather than `review-loop`, which would inflate
> `run_count` and dilute `escalation_rate` in every rollup and dashboard over
> that directory. Try it against a scratch directory first.

It appends to `~/telemetry-share/<repo-slug>.jsonl` — one file per repo *slug*
(a many-to-one name, see below), so many repos can share the directory without
clobbering each other. The rollup reads
such a directory directly:

```bash
zsh development/scripts/telemetry/rollup-telemetry.zsh ~/telemetry-share/
```

Three things to know before you rely on it:

- **The slug is not an identity.** It is derived from `repo` and is
  many-to-one (`a/b-c` and `a-b/c` both become `a-b-c.jsonl`), so group by the
  `repo` *field*, never by filename.
- **Every pipeline but one forwards it for you.**
  `/development:resolve-issue 412 --telemetry-dir ~/telemetry-share` sends the
  story's record **and** every review-loop and size pre-flight record of that
  run to `~/telemetry-share/<repo-slug>.jsonl`; an epic target sends its own
  record and every child run's there too. `--telemetry-file PATH` works the same
  way and wins when both are given.
  `/development:maintenance` and `/development:bootstrap` take the same two
  flags for their run's record, and the acceptance and approver collectors take
  them for every record they append.
  `/development:refine-issue` does **not** forward it yet, so its
  records always go to the user-level default. An empty shared directory after a
  refine-issue run means *that* gap, not a broken emitter.
- **The shared directory is `telemetry/v1`-only.** Every line in it carries a
  `schema` key, which is what lets a consumer skip version sniffing entirely.
  The legacy pre-contract files described above stay where they are — **never copy them
  in**, even though the rollup itself reads old and new together quite happily.

What a cross-repo consumer may rely on is specified in the
[Grafana hand-off contract](../reference/telemetry-grafana-handoff.md).

## Bring older records into the user-level directory

Before #1972 every record landed in the checkout it was emitted from
(`<checkout>/.claude/telemetry/`), so a worktree's records were deleted with the
worktree. To keep what the remaining checkouts still hold, run the salvage once,
naming every checkout root of the repo — its worktrees are found for you, a
second clone is not:

```bash
zsh development/scripts/telemetry/collect-telemetry.zsh ~/repositories/widget ~/scratch/widget-clone
# copied 47, duplicate 0, skipped 25
```

It **copies** every `telemetry/v1` record into
`~/.claude/telemetry/<repo-slug>.jsonl` and never changes a source, so running it
again only reports duplicates. Pre-contract (v0) lines are skipped and stay
where they are; read them by naming the old directory, for example
`rollup-telemetry.zsh ~/repositories/widget/.claude/telemetry`.

## What's collected, and what isn't

- Telemetry is written to a **local** file,
  `~/.claude/telemetry/<repo-slug>.jsonl` — one file per repo, outside every
  checkout, so no git operation can commit it or delete it — and is **never
  sent anywhere** by default: there is no network transport in the emitter at
  all. Older records may still sit in a checkout's own
  `.claude/telemetry/telemetry.jsonl`, the default before #1972, and so may a
  sink you point `--telemetry-dir` at inside a repo. In a repo this family
  bootstrapped that path is **git-ignored**; if you adopted the plugins into an
  existing repo without bootstrap, add `.claude/telemetry/` to your
  `.gitignore` yourself — that exact entry, not all of `.claude/`, which would
  also untrack files meant to be committed (`.claude/approver-policy.md`). See
  [Pipeline telemetry](../explanation/pipeline-telemetry.md). Even the
  shared-directory path above moves nothing off-machine: it only redirects the
  append to a directory you choose, which a separate reporting stack may then
  read.
- `tokens` is deliberately **never estimated** — it stays `null` until the
  harness gives a real number, because a withheld figure beats a confidently
  wrong one.
- Records carry counts, outcomes, durations, issue/PR numbers, run ids, commit
  SHAs and short names — languages, tools, steps, interfaces, the bootstrapped
  `owner/name`, the API URL of an acceptance report — **not** your code, diffs,
  or the text of any review finding. The
  [payload tables](#payload-keys-by-pipeline) list every key.

[Pipeline telemetry](../explanation/pipeline-telemetry.md) explains why it is
collected at all, and why the stream deliberately undercounts rather than
guesses.

## What is not measured

No pipeline of the instrumentation epic was deferred, so there is no deferral
to substitute for. What the records do not hold:

| Not measured | Why | Substitute |
| --- | --- | --- |
| `tokens`, on every pipeline | the harness exposes no reliable number, and the field is never estimated | none — `wall_s` is the only cost measure |
| A PR's fate: merged, reverted, CI rounds to green | a run record is written before its PR settles; the downstream-outcome enrichment that will append these facts is not built yet | none yet |
| refine-issue records in a shared directory | `/development:refine-issue` does not forward `--telemetry-dir` or `--telemetry-file` | read its records in the user-level default file |
| A run that stopped before its first real step | a usage error, a closed issue or a maintenance run halted at its proceed/halt gate has no honest `outcome`, so it appends nothing | none |
| A run whose session died before its ending | the record is appended at the ending, which the run never reached | none |
| A review loop's resumable pauses | only terminal exits are recorded, so a pause is never counted as a run | the terminal record that follows it |
| An Approver run that posted no review — a conflict stop, a refusal, a token-mint failure, a dry run | the collector reads posted reviews, and those runs leave none | none |
| A posted review with no usable findings block | `wall_s` is required and never guessed, so the review gets no record | the collector's stdout count of reviews skipped as not instrumented |
| Acceptance legs older than 30 days, still running, or on a run with no PR | the report artifact expires after 30 days; a running job has no conclusion; a record needs its PR | collect regularly; a running job is picked up by a later collection |
| An acceptance leg whose report is missing, expired or unreadable | counts are withheld, never guessed | its `conclusion` is still recorded |
| A record of any pipeline before it was instrumented | records are never backfilled | the two pre-contract files, for review-loop and refine-issue only |

## See also

- [Pipeline telemetry](../explanation/pipeline-telemetry.md) — why this data is
  collected, what is deliberately left out, and why it stays on your machine.
- [The local review loop](../explanation/review-loop.md) — one of the
  pipelines that emit into the sink this page reads; the
  [inventory](#which-pipelines-are-instrumented) lists the others.
- `ARCHITECTURE.md`, "The telemetry/v1 contract", "Per-pipeline telemetry
  instrumentation (#1226)" and "Telemetry rollup (#1007)" — the normative
  schema, the instrumentation conventions and the rollup behaviour this page
  summarizes; each pipeline's own section is named under its payload table.
