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
|---|---|---|
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
