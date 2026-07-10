# Persona consumption — validation evidence (#669)

Epic [#664](https://github.com/timo-jakob/timos-claude-code-plugins/issues/664)
wires personas into their two consumption sites: the `story-readiness` gate's
**advisory** persona-reference check, and `refine-issue`'s realistic test-data
generation. This document is the reproducible evidence that the wired mechanics
work end-to-end, using the **shipped** primitives (the same
`story-spec-prose-hash.zsh` the gate recomputes with).

> **Scope of this evidence.** This validates the *mechanics* the epic ships — the
> provenance/staleness hash, the advisory logic, and the `data_traits` → payload
> path — deterministically. The remaining acceptance step, a **human-approved
> `docs/personas.md` produced by an interactive `/development:define-personas`
> session on `ai-doc-organizer`** and a real refined issue there, is a
> human-in-the-loop adoption action (the interactive skills require a human to
> answer and approve). The skills are validated *capable* of it here; running it
> for real on the test bed is the maintainer's step.

## 1. A `personas/v1` registry as `/development:define-personas` emits it

The registry prose (one persona, `dana-dispatcher`, `kind: end-user`) is hashed
by the shipped primitive to stamp `provenance.prose_sha256`:

```text
$ story-spec-prose-hash.zsh --file personas-prose.md
034646a3c65a10fd43fc60c6098a612a8bed1012f93086e3602185ef00b7f8a4
```

## 2. Advisory validation (`story-readiness`, #668) — never a hard fail

A `story-spec/v1` block's `personas` array is validated against that registry.
The verdict is **unaffected** in every case; only `advisories[]` changes.

| Case | `personas` | Result |
| --- | --- | --- |
| **valid reference** | `["dana-dispatcher"]` | `advisories: []` — **clean pass** (id present, hash matches) |
| **unknown id** | `["ghost-user"]` | `advisories: [{kind: persona-unknown, …names 'ghost-user'…}]` |
| **stale registry** | `["dana-dispatcher"]` | prose edited after stamping → recomputed hash `09989c6d…` ≠ stored `034646a3…` → `advisories: [{kind: persona-registry-stale, …}]` |

Staleness is detected because the recomputed hash diverges the instant the
human-authoritative prose is edited — the whole pull-based staleness mechanism,
with no background job.

## 3. `data_traits` → realistic outside-in payload (`refine-issue`)

`dana-dispatcher`'s `data_traits` (`job_ref` like `JOB-2291`; `site_name` with
accents like `Müller & Sons`) drive the drafted test-case payload:

```text
curl -X POST /jobs -d '{"job_ref":"JOB-2291","site_name":"Müller & Sons"}'
```

— realistic values, not `foo`/`bar`. That is the payoff the persona registry
exists for.

## Reproduce

The trace above is deterministic; re-run the shipped hash primitive over any
sentinel-delimited persona prose region and the same recipe the gate uses
(`LF → strip per-line trailing whitespace → drop leading/trailing blank lines →
one trailing LF → SHA-256`) reproduces the hashes byte-for-byte. See
`tests/story-spec-prose-hash.bats` for the golden vectors.
