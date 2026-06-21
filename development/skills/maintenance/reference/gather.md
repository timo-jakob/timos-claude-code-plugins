# Phases 3–4 / 6 (gather + payload handover) — rationale & reference detail

Incident history and reference tables behind the gather, payload-construction,
and dispatch-handover steps of the maintenance orchestrator
(`development/skills/maintenance/SKILL.md`, Phases 3, 4, and 6). The imperative
procedure — the rules, commands, and lookup tables the orchestrator executes —
stays in SKILL.md; this file holds the *why* it cites.

## No-trim contract

The inline rule in Phase 6 ("pass the payload as-is") is incident-driven. This
is the evidence behind it and the per-field detail of what downstream code
reads.

Payload trimming by the orchestrator has been observed in **two real
maintenance runs**, despite the dispatch section already saying "pass the
payload as-is." The two incidents:

- **2026-06-05** — scoped `--tool=dependabot` run. The orchestrator dropped
  entries from `coverage.by_module` because it judged the payload "had lots of
  entries." The dispatcher's safety net halted with `human_action_required`
  citing missing coverage data; the orchestrator caught itself mid-narration
  and re-dispatched with the full payload.
- **2026-06-06** — full run. The orchestrator truncated
  `findings_by_tool.dependabot[].body` because it judged "10 KB+ release notes
  per PR pushed the payload to ~70 KB." The triage agent's `gh` refetch
  silently compensated — that is **lucky, not correct**. Pre-spawn routing
  decisions that depend on body content would have routed wrong.

The fields trimmed in the wild — and that downstream code reads — include:

- `coverage.by_module` — every module, every row. Eighty-plus modules is
  normal; do not sample because there are "many."
- `findings_by_tool.dependabot[].body` — the full body, even when it's 10 KB of
  release notes. The triage agent reads it for grouped-PR member lists,
  release-notes breaking-change flags, and Dependabot compatibility scores.
- `findings_by_tool.snyk_prs[].body` — same rule, same reasons.
- `findings_by_tool.code_scanning_alerts[]` — every alert, every field;
  `python-major-upgrade` and the runtime-upgrade agent consume fields the
  orchestrator does not see used in the immediate dispatch.

And every other schema field. Trimming silently changes routing because
downstream agents parse fields the orchestrator never read.

**On payload size.** Both observed incidents (~70 KB and smaller) were well
below any actual Skill-tool limit — the trimming was a behavioural error, not
a capacity workaround. With v2's file-based handover, payload size no longer
enters the Skill-tool's input budget at all — the `args=` value is a ~80-byte
path, regardless of whether the payload behind it is 5 KB or 5 MB. The previous
"200 KB inline ceiling" + `human_action_required` escape valve is gone; do not
reintroduce it. If a payload routinely grows multi-MB, file a quality bug
against the gather script — it should not produce that much. But payload size
is never a justification for trimming.

## Template-drift severities

The template-drift detector (`detect-template-drift.zsh`) reads each tracked
rendered file's `# claude-bootstrap: rendered from … sha256:<H>` marker (#213)
and compares the recorded sha256 against the current template's sha256. It
emits a JSON array of findings (possibly empty), each carrying one severity:

| Severity | What it means |
| --- | --- |
| `drifted` | Marker present, template hash has moved upstream — re-bootstrap or patch to pick up fixes. |
| `unknown_provenance` | File lacks a marker (rendered before #213 shipped, or hand-created). Can't verify drift. |
| `template_missing` | Marker references a template path that no longer exists upstream (renamed/deleted). |
| `malformed_marker` | Marker present but unparseable — corrupted by hand-edit. |

A `drifted` finding additionally carries (#400):

- `fixes` — the entries from `reference/template-changelog.json` for this
  template whose `version` is newer than the rendered file's marker version,
  i.e. **what a re-bootstrap would deliver** (`{version, issue, blocking, summary}`).
  Empty when the changelog has no newer entry (the message then falls back to the
  generic "pick up upstream fixes").
- `blocking` — `true` when any of those `fixes` changes a **required-check's**
  behavior (e.g. #386's path-conditional image scan). Phase 9 renders blocking
  drift first, so a fix that lives in the rendered file rather than the plugin
  isn't a silent "I updated the plugins but nothing changed" trap.

To surface a new template change here, add an entry to
`reference/template-changelog.json` keyed by the template path (omit cosmetic
changes).

In v1 these findings are **detect-only**: they do not enter `findings_by_tool`
and are not routed to any per-tool triage agent. The orchestrator surfaces them
in Phase 9's summary and lets the user decide between re-bootstrap, manual
patch, or accepting the drift.

## Coverage measurement reliability

A coverage number drives the dispatcher's safety floor (Floor/Required gating)
and whether `python-coverage-improver` is spawned. A wrong number is therefore
not a cosmetic bug — it produces wrong autonomous decisions. So the gather step
treats coverage as a *measurement with a provenance*, not a bare figure.

**Incident — 2026-06-14.** A `--dry-run` against an isolated `git clone` of the
test-bed project reported **46.89%** where the real project was at **98.01%**.
Root cause: the clone had no `.venv` (it's gitignored, so `git clone` never
copies it), so `gather-python-findings.sh` silently fell back to the **system**
interpreter, ran the suite without the project's dependencies, tests errored,
and a partial `coverage.json` was emitted — with no signal it was untrustworthy.
Two latent defects, both fixed:

- The "how coverage was gathered" note fired *only* for a venv, so a system-
  interpreter run looked identical to a real one.
- `pytest --cov … || true` discarded pytest's exit code, so a run whose tests
  errored still produced a reported number. Environment-independent — it bites
  even with the correct venv if the suite has a collection error.

**The contract now.** `gather-python-findings.sh` emits a structured verdict
alongside the figure:

```json
"coverage": {
  "overall":   85,            // null when not reliably measured
  "by_module": { ... },       // {} when not reliably measured
  "measurement": {
    "source":      ".venv",   // ".venv" | "venv" | "env" | "system" | "none"
    "pytest_exit": 0,         // captured, not discarded; null if pytest didn't run
    "reliable":    true,      // false ⇒ overall/by_module are withheld
    "reason":      "measured with .venv/bin/pytest (exit 0)."
  }
}
```

Reliability rule: **reliable only when a project venv ran AND pytest exited 0 or
1** (lines still execute when a test merely fails). System-interpreter runs
(`source == "system"`) and abnormal exits (`>= 2`: interrupted / internal error
/ no tests collected) are **not** reliable — the figure is withheld (`overall:
null`, `by_module: {}`) and `reason` explains why. The dispatcher's coverage
pre-flight Step 1 halts with `human_action_required` on `reliable == false` (or
null/empty), echoing `reason`. Never present an unverified number as
authoritative — no figure beats a confident wrong one.
