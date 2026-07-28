# Read your pipeline telemetry

The review loop and `/development:refine-issue` — the two pipelines
instrumented so far, with more joining incrementally — each append one
`telemetry/v1` JSONL record per run **ending** to a local, git-ignored sink —
an extended review-loop run (escalate → grant more rounds → resume) appends
more than one such terminal record, so a "run" here means one ending, not one
whole loop. `rollup-telemetry.zsh` gives you a one-command
glance at how those pipelines are doing — no Grafana, no infrastructure.
(Cross-repo reporting via Grafana is a separate, opt-in path — see the
[Grafana hand-off contract](../reference/telemetry-grafana-handoff.md).)

## Run it

```bash
zsh development/scripts/telemetry/rollup-telemetry.zsh
```

With no argument it reads the local default sink
(`.claude/telemetry/telemetry.jsonl`, resolved relative to your **current
directory** — run it from the repo root) — if nothing has ever emitted, that's
silently an empty stream (`no records`), never an error.

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
| `mean_rounds` | Average review/refinement rounds **per record**, not per logical loop — over records that actually recorded a round count. An extended review-loop run (escalate → grant more rounds → resume) contributes both its escalation's round count and its later convergence's, so this is not any one loop's round count. |
| `mean_wall_s` | Average wall-clock seconds **per record**, not per logical loop — the same reason as `mean_rounds`: this rollup does not group an extended loop's records back into one loop. |
| `escalation_rate` | `escalated` runs divided by total runs, for that pipeline. |

**A measure you can't honestly compute is withheld, never guessed.** If no
record in a group carries a rounds count, `mean_rounds` prints `-` in text and
comes back `null` (the key stays present) under `--json` — the same rule
applies to `mean_wall_s` and `escalation_rate`. This is deliberate: a `0` here
would look like a real, measured zero rather than "nothing to measure."

## Older (pre-contract) records are read too

Two files predate the `telemetry/v1` contract — `review-loop.jsonl` and
`refine-issue.jsonl` — and are never migrated; they stay exactly where they
are. The rollup reads them through a built-in adapter: it recognizes which
pipeline a legacy record belongs to (by filename, or by the shape of its
fields when the filename doesn't say), and narrows its old status/outcome
vocabulary onto the same 4-value enum newer records use. You don't need to do
anything to benefit from this — point the rollup at a directory holding both
old and new files and it aggregates all of it.

## What's collected, and what isn't

- Telemetry is written to a **local, git-ignored** file
  (`.claude/telemetry/telemetry.jsonl`) and is **never sent anywhere** by
  default. Nothing leaves your machine unless *you* choose to point
  `emit-telemetry.zsh` at a shared directory for cross-repo reporting — a
  separate, opt-in path (the emitter's `--telemetry-dir`, epic #740 child (d),
  issue #1006).
- `tokens` is deliberately **never estimated** — it stays `null` until the
  harness gives a real number, because a withheld figure beats a confidently
  wrong one.

## See also

- [The local review loop](../explanation/review-loop.md) — one of the two
  pipelines that emit into the sink this page reads (the other is
  `/development:refine-issue`).
- `ARCHITECTURE.md`, "The telemetry/v1 contract" and "Telemetry rollup
  (#1007)" — the normative schema and rollup behaviour this page summarizes.
