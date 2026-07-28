# Grafana hand-off contract

The cross-repo **reporting repo** — a separate, owner-created repo running a
Grafana stack over many repos' pipeline telemetry — ingests the JSONL this repo's
pipelines emit. This page is the written contract between the two: what lands on
disk, in what shape, and what a consumer may rely on.

It exists because the alternative is tribal knowledge. Handing the shape over in
conversation is exactly the drift that
[epic #740](https://github.com/timo-jakob/timos-claude-code-plugins/issues/740)
was filed to stop, one repo boundary further out.

For the rationale — why the stack lives elsewhere, why the envelope is closed —
see [the explanation page](../explanation/telemetry-grafana-handoff.md). For the
authoritative schema definition, see the `telemetry/v1` section of
[`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md).

## What this repo provides / does not provide

**Provides:**

- The emitter and the contract validator, under
  [`development/scripts/telemetry/`](https://github.com/timo-jakob/timos-claude-code-plugins/tree/main/development/scripts/telemetry).
- The append-only JSONL itself, in the shape this page documents.
- One committed **reference dashboard**,
  [`grafana/reference-dashboard.json`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/scripts/telemetry/grafana/reference-dashboard.json),
  as the reporting repo's starting point.

**Does not provide** — every one of these is the **reporting repo's** concern:

- The **Grafana stack**: the compose file (or any other deployment), Grafana
  itself, and its configuration.
- **Datasource provisioning** — standing up Loki, and pointing Grafana at it.
- The **aggregation service** that scrapes the shared directory into Loki —
  including the `timestamp` stage described below. Note it does *not* assemble
  that directory: the repos' emitters append to it directly.
- **Deployment**, hosting, retention, and access control.

**Dashboard rendering is owner-verified once on import and is deliberately not a
CI gate here.** This repo cannot execute a Grafana stack, so an automated "it
renders" check would be unfalsifiable; what CI *does* enforce is the structural
contract below — the dashboard parses, its datasource indirection is intact, and
every field its queries reference is a real envelope key.

## Where

A pipeline emits through
[`emit-telemetry.zsh`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/scripts/telemetry/emit-telemetry.zsh),
which owns the sink. Sink precedence, highest first:

1. `--telemetry-file PATH` — an explicit file.
2. `--telemetry-dir DIR` — the **shared** cross-repo mode: appends to
   `DIR/<repo-slug>.jsonl`. This is the mode the reporting repo consumes.
3. The local default — `<repo-dir>/.claude/telemetry/telemetry.jsonl`, which is
   git-ignored and never leaves the machine.

The slug is derived from the record's resolved `repo`: `/` becomes `-`, any
character outside `[A-Za-z0-9._-]` becomes `-`, a leading `.` or `-` becomes `_`,
and the result is lowercased. The mapping is **many-to-one** (`a/b-c` and `a-b/c`
both slug to `a-b-c.jsonl`), so the filename partitions the directory but is not
an identity: **group by the `repo` field, never by filename.** Because GitHub
identities are case-insensitive but case-preserving, compare `repo` values
case-insensitively too.

The mode is filesystem-only — JSONL on a path, never a network transport.

**No pipeline forwards `--telemetry-dir` yet.** It is the *emitter's* capability,
reached today only by invoking `emit-telemetry.zsh` with the flag directly; the
review-loop and refine-issue callers still pass at most `--telemetry-file`, so
their records land in each repo's local default sink — or in an explicit
`--telemetry-file` when one was given — never in the shared directory. Wiring a sink flag through
every pipeline entry point is per-pipeline instrumentation and belongs to the
trilogy's **epic 2**. Read an empty shared directory as *that* gap, not as a
broken emitter or a broken aggregation service.

| Flag | Script | Meaning for the hand-off |
| --- | --- | --- |
| `--telemetry-dir` | `emit-telemetry.zsh` | Writes into the shared directory the reporting repo globs. |
| `--telemetry-file` | `emit-telemetry.zsh` | Overrides the directory; a record lands here instead. |
| `--repo-dir` | `emit-telemetry.zsh` | Identity source (which repo a record claims); it locates the local default sink, never the shared directory. |
| `--require-records` | `validate-telemetry.zsh` | Turns an empty stream into a failure — "did the pipeline emit?" |
| `--print-envelope-keys` | `validate-telemetry.zsh` | Prints the authoritative envelope key list as a JSON array. |

## The glob

`DIR/*.jsonl` — one file per repo slug, **append-only**, one JSON object per
line. Files are never rewritten and records are never edited in place; a
correction is a new record, joined on `run_id`.

A consumer reads the directory as a glob and treats each line independently. A
partially-written trailing line is possible in principle on a concurrent read and
should be skipped, not treated as corruption of the file.

## The envelope

Every record carries **exactly** these 14 top-level keys — no more, no fewer. The
envelope is **closed**; `payload` is **open**.

The authoritative list is what the contract enforcer prints:

```console
$ zsh development/scripts/telemetry/validate-telemetry.zsh --print-envelope-keys
["schema","kind","run_id","parent_run_id","ts","repo","repo_type","pipeline","issue","pr","outcome","wall_s","tokens","payload"]
```

The table below is the human statement of that same list. **It is not
authoritative for a test** — a test reads `--print-envelope-keys`, so a key can
never be added to the enforcer and missed here without CI noticing.

| Key | Type | Nullability |
| --- | --- | --- |
| `schema` | string, const `"telemetry/v1"` | required |
| `kind` | string, `"run"` or `"enrichment"` | required |
| `run_id` | string, non-empty — the join key | required |
| `parent_run_id` | string — links a nested run to its parent | nullable |
| `ts` | integer, unix seconds, non-negative | required |
| `repo` | string, non-empty, `owner/name` (basename fallback) | required |
| `repo_type` | string, e.g. `python`, `claude-plugin` | nullable |
| `pipeline` | string, non-empty; open identifier `[A-Za-z0-9._-]+` (emitter-enforced — the validator checks non-empty only) | required |
| `issue` | integer, non-negative | nullable |
| `pr` | integer, non-negative | nullable |
| `outcome` | string, `"success"`, `"parked"`, `"escalated"` or `"failed"` | required |
| `wall_s` | integer, non-negative | required on `kind: "run"`; **`null`** on enrichments |
| `tokens` | integer, non-negative — never estimated | nullable |
| `payload` | object, open — pipeline-specific detail | required |

Three rules a consumer must encode rather than infer:

- **`pipeline` is an open identifier, not an enum.** A new pipeline appears in
  the data with no schema change and no dashboard change. Never hard-code the set.
- **`outcome` on an enrichment describes the enrichment event**, not the run it
  enriches. Every run-level aggregation must therefore filter `kind == "run"` —
  see the join below.
- **A `kind: "run"` record is one terminal *exit*, not one pipeline
  invocation.** An extended review loop — escalate, human grants more rounds,
  resume — emits one record per escalation, plus a final one if the loop later
  ends differently, and their `wall_s`
  spans **overlap**. So `wall_s` may be **counted but never summed** into a
  "pipeline hours" figure, and a run-volume panel is really an ending-volume
  panel. See ARCHITECTURE.md's *Review-loop telemetry* section for the exact
  emission rule.

## The join

`run_id` is the join key, and it joins two ways:

- **Nested runs** — `parent_run_id` on a child record equals `run_id` on its
  parent (a review-loop run inside a resolve-issue run). Follow it to attribute a
  child's cost to the parent pipeline.
- **Run × enrichment** — an enrichment record carries the **`run_id` of the run
  it enriches**, never a fresh one, and names its kind in `payload.event`. It is
  event-sourced: a fact learned later is appended, never patched into the
  original line. Unlike every envelope rule on this page, `payload.event` is a
  **producer convention, not a validated invariant** — `payload` is open by
  design, so an enrichment lacking `event` validates clean and reaches the
  directory. Treat an eventless enrichment as malformed input to skip, not an
  impossible state.

**A consumer computing run outcomes MUST filter `kind == "run"`.** Counting both
kinds double-counts every enriched run *and* blends two meanings into the single
field dashboards group on. This is the one contract rule most likely to be
missed, which is why all four reference panels carry the filter already.

Enrichment panels arrive with epic 3 of the telemetry trilogy. The join shape is
documented now so that adding one needs no re-cutting of the existing panels.

## Legacy

**The shared directory is `telemetry/v1`-only.** Every record written into it
carries a `schema` key, so a consumer needs no missing-`schema` tolerance and no
version sniffing — and correspondingly, no reference panel references `schema` at
all.

Pre-contract records (the per-pipeline files `review-loop.jsonl` and
`refine-issue.jsonl`, which carry no `schema` key) stay in their per-repo
locations. They are read locally by the rollup's v0→v1 adapter — see
[Read your pipeline telemetry](../how-to/read-pipeline-telemetry.md). **No file
migration is performed**, and no legacy record is ever promoted into the shared
directory.

## Versioning

- A **breaking envelope change** — a key added, removed, retyped, or an enum
  value changed — bumps the schema to `telemetry/v2`. `validate-telemetry.zsh`
  then rejects a v2 record outright rather than passing on the fields the two
  versions share. Note this is a *producer-side* guarantee: the consumer path
  below (aggregation service → Loki → LogQL) never runs the validator, so nothing
  fails loudly on the reporting side by itself — see the migration step.
- **`payload` evolves freely** per pipeline and is non-breaking by definition.
  One named exception: `payload.rounds` is a shared reporting key, so renaming or
  nesting it withholds that pipeline's mean-rounds measure.
- Until a v2 exists, **the shared directory holds exactly one schema version**,
  so the reference panels deliberately carry no `schema` filter — a filter for a
  condition that cannot occur is noise that reads as caution. The day a v2 stream
  first lands in the same directory, the reporting repo adds the filter at that
  point, as a deliberate migration step rather than a standing assumption.

## The reference dashboard

[`development/scripts/telemetry/grafana/reference-dashboard.json`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/scripts/telemetry/grafana/reference-dashboard.json)
is a committed Grafana dashboard export — a starting point, not a product.

- **Datasource: `loki`. Query dialect: LogQL.** The shared directory is scraped
  into Loki by the reporting repo's aggregation service; the panels query it in
  LogQL.
- **No environment-specific uid is committed.** The export declares an
  `__inputs` entry named `DS_TELEMETRY` (`type: "datasource"`,
  `pluginId: "loki"`), and every panel's datasource is
  `{"type": "loki", "uid": "${DS_TELEMETRY}"}`. The reporting repo binds its own
  datasource on import.
- The stream selector in each query (`{job="claude-telemetry"}`) is the label the
  reporting repo's scrape config applies. Adjust it to match that config.

### The four panels

Each filters `kind = "run"`:

- **Runs over time** — run volume (strictly, *ending* volume — see the third
  consumer rule above), bucketed over the dashboard's time range.
- **Outcome mix** — how runs ended, grouped on `outcome`.
- **Escalation rate** — escalated runs over all runs, *filtered* on `outcome`.
  Unlike `Outcome mix` and `Per-pipeline breakdown` it does not `sum by (…)` at
  all: `outcome` narrows the numerator, it is not a grouping dimension. Adding
  `by (outcome)` to both halves does **not** blank the panel — it pegs it: the
  numerator's single `{outcome="escalated"}` series matches the denominator's
  identically-labelled series, divides to a constant 1, and every other outcome
  series is dropped. A percentunit stat stuck at 100% is the same silently-wrong
  shape as an inverted ratio, which is why the suite asserts these queries carry
  **no grouping clause at all** — no `by (…)` and no `without (…)`, in either the
  prefix (`sum by (…) (…)`) or the postfix (`sum(…) by (…)`) position. LogQL
  accepts both and both produce the identical peg, so a negative check for one
  literal spelling would miss the other.
- **Per-pipeline breakdown** — run volume, grouped on `pipeline`.

### The one other thing the scrape config decides: the time axis

`Runs over time` uses `count_over_time`, which buckets by each log entry's **Loki
timestamp** — whatever the ingestion assigned — and *not* by the `ts` field
inside the record. The query extracts `ts` so it is available as a label, but no
LogQL construct can make it the x-axis.

So the reporting repo's scrape config **must promote the record's `ts` onto the
entry timestamp** (in Promtail or Alloy, a `timestamp` stage sourcing the `ts`
field, unix-seconds format). Without that stage the panel is a chart of *ingest*
time: correct for a live tail, and badly wrong the first time the directory is
backfilled or re-scraped, where every historical run piles onto the moment it was
read. This is the one dependency beyond the stream selector, and it is invisible
in the query — hence stating it here rather than leaving it to be discovered.

### The anti-drift cross-check

A committed dashboard rots the moment the envelope moves under it, so the two are
wired together in CI.

[`reference-dashboard.fields.json`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/scripts/telemetry/grafana/reference-dashboard.fields.json)
is a sibling manifest mapping each panel title to the envelope fields its query
references. A **field reference** inside a query is, exactly:

1. a JSON-extraction label assignment of the form `| json <name>="<name>"`, or
2. the left-hand side of a label-filter comparison (`<name> = "…"` or
   `<name> != "…"`) appearing after a `| json` stage.

Nothing else counts — which is why the test never has to parse LogQL.
`tests/telemetry-grafana-dashboard.bats` then asserts three ways, over **every**
target of every panel:

1. every manifest field appears in the `--print-envelope-keys` array;
2. every manifest field for a panel appears literally in that panel's queries;
3. every rule-matched field reference in a panel's queries appears in that
   panel's manifest entry.

**What (3) does and does not guarantee.** On its own it catches an un-manifested
field written in either of the two shapes above, and is blind to a reference
written any *other* way: a regex filter (`| pipeline =~ "…"`), a line filter
(`!~ "…"`), a numeric or unquoted comparison (`| wall_s > 0`), a grouping label
(`sum by (repo)`), a bare `| json` stage (which makes Loki extract *every* key,
so that grouping becomes a reference to `repo` with nothing to match on),
LogQL's shorthand parameter form (`| json kind, outcome`), a renaming extraction
(`| json p="pipeline"`), another auto-extracting parser (`| logfmt`,
`| unpack`), or `unwrap` / `label_format` / `line_format`.

Rather than leave that as a silent hole, a **closure guard** keeps the committed
queries inside the rule's reach. Several of its parts are **allowlists**, so they
fail closed on constructs nobody has thought of rather than only on the ones
someone remembered to name:

- **a query must carry at least one `| json` stage**, spelled with a following
  space — a stage-less query, or one spelled `|json`, is rejected outright.
- **every JSON-stage body must reduce to nothing** once identity `name="name"`
  pairs, commas and whitespace are removed, and must contain at least one such
  pair. That rejects a bare `| json`, the shorthand `| json kind, outcome`, a
  renaming `| json p="pipeline"`, and a backquoted parameter — in one rule
  rather than four.
- **every remaining pipeline stage must begin with a label filter the rule
  matched.** `logfmt`, `unpack`, `unwrap`, `line_format`, `pattern`, `regexp` and
  any future stage are all rejected without being named.
- **no comparison operator survives outside those stages** — no `=~`, `!~`, `>`,
  `<`, no spaceless `field="value"`, and no metric-level threshold after the
  aggregation. `~` is in that set for a reason worth keeping: a negated-regex
  *line* filter (`!~ "…"`) contains none of `=`, `<`, `>`, and can sit where the
  stage rule cannot reach it.
- **every label list must name fields the rule can see** — `by (…)`,
  `without (…)`, `on (…)`, `ignoring (…)`, `group_left/right (…)`. Each label
  must be extracted by an identity pair, or be the `job` stream label. These live
  in the aggregation and metric layers, which no stage rule covers.
- **the stream selector may match only on `job`.** `{…}` is stripped before the
  other arms, so a matcher on a promoted envelope label
  (`{job="…", outcome="escalated"}`) would otherwise be an unguarded read.
- **no `label_replace` / `label_join`**, which name a label in a plain function
  argument — no operator, no stage, no label list, and so nothing structural to
  allowlist them by.

So an editor who reaches for one of those forms gets a **red** test telling them
the rule no longer covers the query — not a green one implying it still does. It
lives in one `guard_expr` predicate that the query tests and the probes both
*call*, and **every guard arm is pinned by at least one probe** — enforced by
construction, not by review: a harness neutralises each arm in turn and requires
the probe suite to fail, so an arm added without a probe reddens immediately.
That pairing had gone false twice before the harness existed, and building it
turned up a ninth arm that was simply dead.

**What the guard is, honestly.** It is a *checked approximation* of LogQL, not a
parser. Each of the shapes above was found by review and closed deliberately, and
the allowlist arms generalise beyond the ones named — but LogQL is a large
language, and a genuinely novel construct that reads a field could still slip
through. So the guard makes (3) **strong**, not **total**: treat a green suite as
"no known escape", and the manifest as something a human still owns when a query
changes. Claiming more than that would be the same unfalsifiable green this page
refuses for dashboard rendering.
