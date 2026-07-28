# Pipeline telemetry

Two of this family's pipelines — the local review loop and
`/development:refine-issue` — append one line of JSON when a run ends. This page
is about *why* that exists, what it deliberately does and does not contain, and
why it stays on your machine.

For the task itself — running the rollup and reading its measures — see
[Read your pipeline telemetry](../how-to/read-pipeline-telemetry.md).

## Why collect anything at all

These pipelines ask for autonomy: the review loop decides when a change has
converged, and refinement decides when a story is ready. Granting more autonomy
safely needs evidence, and the alternative to evidence is not neutrality — it is
somebody's recollection of how the last few runs felt.

The concrete case is the review loop's round budget, which defaulted to 3. The
recorded rounds-to-converge across six issues were 1, 3, 3, 3, 6 and 10 — a
median of 3 with a hard tail of two issues well past it. Because the cap is an
upper bound (the loop stops the moment blocking findings reach zero), raising it
is free for the easy majority and only changes the tail, so the default was
raised to **five rounds** on that evidence. That is the whole ambition of this
data: to answer *does this converge, how often does it escalate, and is the
budget right* with counts rather than impressions — note the honest shape of
that evidence, a tail rather than a majority.

## What a record is

One line per **run ending** — which is not the same as one line per run. An
extended review loop escalates, a human grants more rounds, it resumes and ends
again; each of those endings is its own record. That is why the rollup's
`mean_rounds` and `mean_wall_s` are per *record*, and why their spans overlap and
must never be summed into a "pipeline hours" figure.

Not every line is a run ending, though. A fact learned *after* a run finishes —
whether you acted on the suggestions it waived, say — is appended as a separate
`kind: "enrichment"` line joined to the original run by `run_id`, rather than
rewriting the line already written. So anything counting runs filters
`kind: "run"` first; the rollup already does.

Each record is a closed envelope of fourteen fields — identity, timing, outcome,
and, as the fourteenth, an open `payload` where a pipeline puts its own detail.
The envelope is
closed precisely so that a measure like `outcome` means the same thing across
every pipeline; the payload is open so a pipeline can evolve without a schema
change. `ARCHITECTURE.md`'s *telemetry/v1 contract* is the normative statement.

## What is deliberately not collected

- **No network egress.** The emitter writes JSONL to a path. There is no
  transport, no endpoint, no key — a shared directory (below) is still just a
  directory. Nothing is uploaded, and nothing can be, because nothing in the
  emitter speaks a network protocol.
- **No code, no diffs, no prose.** Records carry counts, outcomes, durations and
  issue/PR numbers. The finding *titles* a review round produced are not in
  them; neither is the content of any file the loop read or wrote.
- **`tokens` is never estimated.** The field exists and stays `null` until the
  harness reports a real number. A withheld figure beats a confidently wrong one,
  and a plausible-looking estimate would quietly become someone's cost model.

That last principle generalises: the stream is **lossy on purpose**. When a run
cannot honestly measure its own wall time, outcome or counts, the pipeline skips
the record rather than fabricate one — and emission is best-effort throughout, so
a telemetry failure drops the record and never the run. The consequence is worth
stating plainly: **the sink undercounts.** It is evidence, not an audit log, and
a missing record never means a run did not happen.

## Why it stays local

The sink is `.claude/telemetry/telemetry.jsonl`. In a repo this family
bootstrapped, that path is git-ignored — so it is never committed, never pushed,
and never reaches a PR. That is an ignore *entry*, not a property of the file:
if you adopted the plugins into an existing repo without bootstrap, add
`.claude/telemetry/` to your `.gitignore` yourself — that entry specifically,
since ignoring all of `.claude/` would also untrack files meant to be committed,
such as `.claude/approver-policy.md` — and check `git status` once before
trusting the guarantee. The default is local
because that is the only default that is obviously safe to run without asking:
nothing has to be trusted, configured, or opted out of.

Cross-repo reporting is therefore **opt-in and explicit**: point the emitter at a
shared directory with `--telemetry-dir` and it appends there instead — one file
per repo *slug*, a deliberately many-to-one name, so a consumer groups by the
`repo` field rather than by filename — for a separate reporting stack to read. What such a consumer may rely
on is written down in the
[Grafana hand-off contract](../reference/telemetry-grafana-handoff.md) — a
committed artifact rather than a conversation, for the same reason this page
exists.

## What this does not give you

It does not tell you *why* a run went the way it did. A record says a loop
escalated after five rounds; it does not say what the reviewers disagreed about —
that lives in the PR's review dossier and the issue thread. Telemetry is
deliberately the thin, countable layer: enough to see a trend and question a
default, not enough to reconstruct a run.
