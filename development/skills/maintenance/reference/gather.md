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
|---|---|
| `drifted` | Marker present, template hash has moved upstream — re-bootstrap or patch to pick up fixes. |
| `unknown_provenance` | File lacks a marker (rendered before #213 shipped, or hand-created). Can't verify drift. |
| `template_missing` | Marker references a template path that no longer exists upstream (renamed/deleted). |
| `malformed_marker` | Marker present but unparseable — corrupted by hand-edit. |

In v1 these findings are **detect-only**: they do not enter `findings_by_tool`
and are not routed to any per-tool triage agent. The orchestrator surfaces them
in Phase 9's summary and lets the user decide between re-bootstrap, manual
patch, or accepting the drift.
