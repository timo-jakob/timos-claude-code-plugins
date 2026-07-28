# The Grafana hand-off

Every **instrumented** pipeline in this family appends one line of JSON at each
terminal exit — an extended review loop ends more than once — on a best-effort
basis, since a telemetry failure drops the record and never the run. Two pipelines are
instrumented today, the review loop and issue refinement, with the rest owned by
epic 2 of the telemetry trilogy. That data has
three declared audiences: a human glancing at one repo, the plugin
self-improvement loop, and a **separate reporting repo** running Grafana across
many repos at once. This page is about the third — and specifically about why the
seam between the two repos is a committed artifact rather than a conversation.

The lookup material — the envelope, the glob, the join keys — lives on the
[hand-off contract reference page](../reference/telemetry-grafana-handoff.md).

## Why the Grafana stack lives in another repo

A dashboard stack is infrastructure: a compose file, a Loki instance, an
aggregation service, retention policy, credentials, a deployment. None of that is
a Claude Code plugin, and none of it belongs in a repo whose deliverable is
plugins that must stay **offline-safe** — a plugin that reached for a Grafana at
run time would fail on every machine that doesn't have one.

There is also an ownership argument. The reporting stack aggregates *many* repos;
this repo is one of its inputs. Putting the aggregator inside one of the things it
aggregates inverts the dependency, and the first repo to be onboarded would have
had to fork it.

So the boundary is drawn where it already exists in reality: this repo produces
data and describes it; the reporting repo consumes data and visualizes it.

## Why the envelope is closed

The contract splits every record into a **closed envelope** — 14 fixed top-level
keys — and an **open `payload`**. A pipeline may put anything it likes inside the
payload and nothing at all outside it. The validator rejects an unknown top-level
key.

That split is what makes cross-pipeline reporting possible at all. A dashboard
that groups on `outcome` works for the review loop, for issue refinement, and for
every pipeline instrumented later, *without being told they exist* — because
`outcome` means the same thing in all of them and there are only ever four
values. The moment a pipeline could add a top-level key, that guarantee would
become a per-pipeline question, and the consumer would need to know the producer.

The closed half is small on purpose. Everything genuinely pipeline-specific —
round counts, park types, objection tallies — is payload, where it can evolve
freely without a schema version bump and without any consumer caring.

This is also the answer to the obvious objection: closing the envelope sounds
rigid, but the rigidity is confined to the fourteen fields a dashboard actually
groups on. Nothing else is constrained.

## Why the hand-off is a committed artifact

The two existing telemetry streams — the review loop and issue refinement — were
built by copy-adaptation: the same sink convention, near-identical fields,
duplicated scaffolding, and no shared definition. They drifted. That is the whole
reason `telemetry/v1` exists.

A hand-off explained in conversation drifts in exactly the same way, one repo
boundary further out. So the contract is a page in this repo's docs, the key list
is printed by the **validator itself** rather than restated by hand, and the
starting dashboard is a committed JSON file the reporting repo imports.

The dashboard is the part that would rot fastest, so it is wired to the enforcer:
a sibling manifest records which envelope fields each panel queries, and CI
checks that manifest against the validator's own key list *and* against the
queries themselves. The check reads queries through a deliberately narrow
syntactic rule, and a **closure guard** keeps them inside it — mostly by
allowlist rather than by naming offenders, so a comparison the rule cannot read
(a regex, a line filter, a numeric or spaceless one), a parser stage that
auto-extracts every key (`| logfmt`, `| unpack`, a bare `| json`), LogQL's
shorthand parameter form, a renaming extraction, a grouping on a label nothing
extracted, and
field-reading stages like `unwrap` or `line_format` all fail
without the guard having to have anticipated them individually. Reaching for an
uncovered construct is built to red rather than pass — the honest failure mode: a
check that cannot see a construct should say so, not stay green and imply it
looked.

The pairing between an arm and its probe is itself mechanised: a harness deletes
each arm in turn and demands the probes notice. That is the difference between a
guard that is checked and one that is merely believed — and it earned its keep
immediately, proving one arm dead on the first run.

What it is not is a LogQL parser, and the reference page says so plainly. Every
escape found so far was closed deliberately, and the allowlist arms generalise
past the shapes anyone named — but a large query language will always admit one
more spelling. So the guarantee is "no known escape", not "no escape", and the
manifest stays something a human owns. Overstating that would reproduce, one
level down, exactly the unfalsifiable green tick this repo refuses to put on
dashboard rendering.

What CI here deliberately does **not** check is whether the dashboard *renders*.
This repo cannot run a Grafana stack, so that check would be unfalsifiable — a
green tick meaning nothing. Rendering is verified once, by the owner, on import.
Claiming more than that would be worse than claiming nothing.

## What this does not solve

The reporting repo still has to be built and operated, and nothing here forces it
to stay in step: a consumer that ignores the `kind == "run"` filter will
double-count enriched runs no matter how carefully this side is specified. The
contract narrows the failure to a documented, checkable rule — it does not
eliminate it.
