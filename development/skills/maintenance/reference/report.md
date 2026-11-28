# Phase 9 (summary) — rationale & reference detail

Lookup tables and worked examples behind Phase 9's summary rendering in the
maintenance orchestrator (`development/skills/maintenance/SKILL.md`). The render
template and the cross-link / Snyk-naming *rules* stay in SKILL.md; this file
holds the detail they cite.

## Cross-linking known issues

Examples of the kind of topical match worth a `(see #<n>)` link on an advisory:

- An advisory about a ruff py314 bug → matches an issue titled "Re-enable ruff
  format once upstream py314 except-tuple bug is fixed" → emit `(see #38)`.
- An advisory about a Snyk container CVE → matches an issue titled "Suppress
  Debian base-image CVEs in .snyk" → emit `(see #N)`.

Be conservative — only cross-link when the topical match is unambiguous. A wrong
`(see #N)` is worse than no link.

## Snyk channel naming

Snyk surfaces findings through *three* independent channels, and run-note prose
has historically confused them. Disambiguate before naming a channel in the
Render template's pre-existing-failures section:

| Check / job name shape | Channel | Notes |
| --- | --- | --- |
| `security/snyk (<org>)`, `code/snyk (<org>)`, `open-source/snyk (<org>)` | Snyk **GitHub App** (integration PR checks, posted from app.snyk.io) | Primary SAST + OSS signal for projects with the App installed. |
| `image` job in the workflow (running `snyk container test`) | CI workflow job | Scans the freshly-built container image, which the GitHub App cannot see. |
| `snyk-code`, `snyk-open-source` jobs in the workflow (running `snyk code test` / `snyk test --all-projects`) | CI workflow jobs | When present, they duplicate the GitHub App's SAST + OSS signal AND burn private-test quota. If they appear in a failure list, suggest replacing them with the GitHub App. |

When a `security/snyk (<org>)` check fails with state `ERROR` (not `FAILURE`),
it is almost always an **infrastructure** condition (most commonly the org's
monthly private-test quota is exhausted), not a finding on the PR's diff.
Phrase it that way:

> security/snyk (`<org>`): ERROR state from the Snyk GitHub App's integration
> check — typically quota exhaustion on the org's monthly private-test budget.
> Top up the plan or wait for the monthly reset.

Do **not** describe such a failing check as a "legacy CI job to remove" — the
GitHub App's PR check is the canonical signal, not legacy. Check the actual
workflow file before suggesting removals.

If the maintenance gather's per-language Snyk script emitted a summary into
`notes[]` of the form `Snyk findings via REST API (no quota consumed): X code,
Y OSS. Projects scanned: ...`, include that note verbatim in the "Notes from
the gather step" section of the Render output — it tells the user the
maintenance pipeline did NOT burn quota this run, which is load-bearing
diagnostic when the GitHub App's check is erroring.

## The scheduled run's record and the Maintenance log (#3215)

Under `--scheduled` every ending leaves a `maintenance-run/v1` record and one
comment on the repo's standing *Maintenance log* issue: the normal ending, a
cut-off run, and a stop at or before Phase 2's gate, which emits no telemetry
record. Under `--dry-run` neither script runs: a dry run performs no outward
actions.
The summary below is written before *Run complete — clear the checkpoint*,
since it reads the checkpoint; the two script calls are the run's last act —
after Phase 10's report, after the Phase 9 emit when Phase 10 is skipped, or
where an earlier stop stops. ARCHITECTURE.md,
*Maintenance run record (`maintenance-run/v1`)*, is the record's contract; the
two scripts' headers state their exit codes.

**The outcome.** Take the first that holds:

| The run … | `--outcome` |
| --- | --- |
| ended at the resume entry because a younger checkpoint says a run may still be going (`reference/scheduled.md` § 1) | `skipped-running` |
| stopped in Phase 0 or 1, or at Phase 2's gate | `could-not-start` |
| deferred any group, stage or bug by `cutoff` | `cut-off` |
| ended any other way | `completed` |

`outside-window` is never a session's: the wave that starts the run writes it,
with the same script, for a repo it did not start before the cutoff. Pass the
stop's reason as `--reason` whenever the run did not end normally.

**The summary.** Write `<scratch>/run-summary.json` with the Write tool from
facts noted where each was decided — `phase8-stages`, Phase 7's halts, Phase
3's `unsupported` notes, the budget's `deferred` list and the `Bugs` block
(`reference/bugs.md` § 5) — never reconstructed from the rendered summary. It
holds `started_at` (the start stamp's time, `jq -r '.ts | todate'
<scratch>/maintenance-run.json`), `concerns` and `bugs`; each item is
`{number, title, url, note}`:

- per concern (`security`, `dependencies`, `bugs`, `codequality`, `topic`):
  `merged` — PRs merged this run; `opened` — PRs this run opened that are still
  open and not waiting for a human; `waiting` — open PRs and `advisory` stages
  (`number` null, the entries in `note`) waiting for a human's approval or
  decision; `parked` — anything else that ended needing a human, the reason in
  `note`: escalated or held stages and bugs, bug fixes that left no open or
  merged PR, failed analyses, and a target Phase 7 halted or a language Phase 3
  skipped (a topic's under `topic`, a language's under `codequality`);
  `deferred` — groups and bugs not started, `note` naming the `deferred_by` or
  the reason;
- `bugs`: `fixed` — a bug belongs here only when its fix was confirmed by its
  PR merging this run, never when the fix was merely attempted: an open fix PR
  goes under the `bugs` concern's `opened` or `waiting`, a
  `spec-does-not-reproduce` stop under `not_reproducing`, and every other
  ending of a fix run under the concern's `parked`, the ending in `note`;
  `analysed` — bugs analysed this run, the verdict in `note`;
  `awaiting_confirmation` — bugs whose spec waits for a code owner's
  `confirmed` label; `not_a_bug`, `not_eligible` and `not_reproducing` (a fix
  stopped with `spec-does-not-reproduce`) — bugs in that state, the reason in
  `note`.

A stop at or before Phase 2's gate writes no summary, passes no `--from`, and
takes a fresh `mktemp -d` as `<scratch>`. `<owner/name>` is what follows `github.com/` or
`github.com:` in `git remote get-url origin`, `.git` dropped, so it needs no
network. With no git repo, no `origin`, or an origin not on github.com, never
guess one: run neither script, and report that the run record could not be
written.

```bash
export MAINTENANCE_RUN_DIR="${MAINTENANCE_RUN_DIR:-<scratch>}"
"<skill-base-dir>/scripts/write-run-record.zsh" --repo <owner/name> --outcome <outcome> \
  [--reason "<why>"] [--from <scratch>/run-summary.json]     # prints <record>
"<skill-base-dir>/scripts/post-maintenance-log.zsh" <record>
```

The scheduler exports `MAINTENANCE_RUN_DIR`; a `--scheduled` run typed by hand
keeps its record in `<scratch>`. A `write-run-record.zsh` exit 1 on the summary:
report its stderr and write again without `--from`, the reason saying the
summary was refused, so a record exists. Its exit 2 is your own malformed call:
fix it and re-run once. A `post-maintenance-log.zsh` exit 1 leaves the record
valid with `log_comment_url: null`: report its stderr, and retry nothing — the
next run's comment is the next attempt. Neither script ever closes the log
issue. Once both have run, relay the record's path and the comment's URL, or
the failure, as the run's final output.
