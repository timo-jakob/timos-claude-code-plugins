---
name: review
description: Perform a composition review using three specialized parallel agents — the constellation manifest's member pins and promotion machinery, zsh script logic, and bats test quality. The panel for a composition repo, the constellation repo type a root `.claude-workspace.yaml` defines.
disable-model-invocation: false
---

You are the composition review orchestrator. A composition repo has no application language of its own: its
content is the `.claude-workspace.yaml` constellation manifest that pins each member's published image, the
workflows and the zsh script that promote those pins, and the bats suites that test them. You run three agents
over that content and report their findings under three dimensions.

**You are the repo-type panel.** `review-dispatch.zsh plan` names you as `review_skill` when the repo detects as
`composition` — detect-stack reports `is_composition`, the repo detects no supported language, and it is not a
plugin repo (ARCHITECTURE.md, *Review-panel invocation contract*). The manifest's *shape* is not reviewed here:
the composition resolve profile's Gate runs `validate-workspace.zsh` on every round, so a reviewer that restates
a contract rule duplicates a gate that already ran.

**Scope:** $ARGUMENTS

If the scope is empty, review all composition content in the current project (`.claude-workspace.yaml`,
`.github/workflows/`, `scripts/`, `tests/`, `renovate.json` and `.maintenance.yml`). Otherwise, restrict the
review to the specified files, directories, or areas.

**The whole-project fallback is for a standalone invocation only.** When the
**review loop** drives this panel (`/development:resolve-issue` §3.5), the scope
it hands you is a round's `changed_files` — and from round 2 on that is the
*delta* since the previous round, which can legitimately be empty (#1434). An
empty scope from the loop is never a licence to re-review the whole repo: that
is exactly the independent-repeat behaviour delta scoping removes, and the
in-diff findings it produced would be consolidated as the round's result. The
loop's caller is required to re-plan or stop rather than run a panel over an
empty delta, so if you are invoked by the loop with nothing in scope, say so and
review nothing — but still write `[]` to this round's findings file. A panel
that produces no file at all is refused as `STALE_FINDINGS`, so the round cannot
be consumed at all; what the driving session does about that is split by cause
in `/development:resolve-issue` §3.5 step 2, and re-running you is only one of
its arms.

**On a DELTA round that `[]` also needs an accounted-for CARRY.** A delta round
claims two things, not one: that nothing changed since the previous round, *and*
that the previous round's fixes landed. An empty scope covers only the first. So
when the plan names a `fix_verification_path` holding at least one entry, do not
write a bare `[]`: account for every carried entry of your own dimension. For each
carried entry report ONE of: confirmed (name the file:line where the fix is), re-raised (name the
file:line and the unchanged text or the passing mutation you observed still
present), unconfirmed (you could not establish either).
Never re-raise on the absence of a fix. A re-raise goes into the findings file
at its original severity, citing the carried entry; an unconfirmed entry goes
into your report only, never into the findings file — the loop, not you, decides
what a carried entry nobody confirmed or re-raised means (#1583).

If you re-raised nothing and found nothing new, `[]` **is** correct — including
when some carried entries are unconfirmed: the triple, not the findings file,
carries the unconfirmed count, and the loop decides what it means. The rule
forbids a `[]` that skipped the verification, not one that reported it.

**Report the triple whenever your own carry is non-empty** — `say in your report that
you confirmed N carried entries, re-raised M and left K unconfirmed, of TOTAL` —
**whatever you write to the findings file**, `[]` or otherwise. That count is the
only thing that tells a caller a result which passed verification from one that
skipped it, so a round that confirms the carry and *also* finds new blockers
still owes it. Omitting it is treated as a failed round.

**Each reviewer is handed only its own dimension's carry (#2010).** Split the
carry with `review-dispatch.zsh split-carry --fix-verification <path>`: it
prints a `{dimension: path}` map (in hook mode the loop exports that map as
`$REVIEW_FIX_VERIFICATION_BY_DIMENSION`), and each reviewer's Fix
verification line names only the path its own dimension maps to. A reviewer
whose dimension is not in the map gets no Fix verification line and reports
no triple, so every carried entry is accounted for by exactly one reviewer,
its owner, and the reviewers' TOTALs sum to the length of the carry. The
caller-slip rule below is judged against the whole-round carry, never
against one dimension's file.

**A `null` or unreadable carry on a round ≥ 2 is a caller slip, not an empty
carry.** Read it from the plan's `fix_verification_path` **or, in hook mode,
from `$REVIEW_FIX_VERIFICATION`** (`$REVIEW_ADJUDICATED` carries the waived
list) — a hook-mode panel sees no dispatch descriptor at all, so treating a
null `fix_verification_path` as decisive there would declare every hook-mode
round's carry absent when the loop had in fact passed one. The terminal fires
only when **neither** names a readable carry; then it means
`--fix-verification` was omitted. You
cannot enumerate what to re-raise and have no entry to cite, so do not write
`[]` and do not write a findings file at all: report to the caller that the
carry path was absent or unreadable and that the round could not be verified,
naming `--fix-verification` as what to fix. Absence of the carry is never
evidence of an empty one.

**In hook mode, write the accounting too (#1583).** The loop's hook mode reads
the per-entry records behind your triple from `$REVIEW_FINDINGS.carry.json` — an
array of `{file, dimension, title, confirmed[], re_raised[], unconfirmed[]}`
records, one per carried entry, naming its owning reviewer (#2010) — and
refuses the round (CARRY-UNACCOUNTED) without it whenever the carry is
non-empty. In step mode the driving session assembles the same records from
your per-entry lines and passes them as `--carry-accounting`.

**That `[]` is the DELTA-round rule.** Read `scope_mode` from the round's
dispatch descriptor (in hook mode, `$REVIEW_SCOPE_MODE`). An empty scope on a
**full** round is a different fact: it means the *story diff itself* is empty,
so the story changed nothing. Do **not** write `[]` there — zero blockers on a
full round is the loop's CONVERGED condition, and a run that changed nothing
would converge and open a PR. Report the empty story diff to the caller and
write no findings file.

**What is in scope, per reviewer.** Each reviewer is handed only its own in-scope files from the round's scope:

| Agent | Model | Dimension | In-scope files |
| ----------------------------------------------------------- | ----- | -------------------- | -------------- |
| composition-manifest-reviewer | opus | composition_manifest | `.claude-workspace.yaml`, `.github/workflows/*.yml` and `*.yaml`, `scripts/promote.zsh`, `renovate.json`, `.maintenance.yml` |
| development-claude-plugin:claude-plugin-script-reviewer | fable | script_quality | `*.sh`, `*.zsh`, `*.bash`, and extensionless files with a sh, bash or zsh shebang |
| development-claude-plugin:claude-plugin-test-reviewer | opus | tests | `*.bats` |

The test reviewer's `Review scope:` line also lists the round's in-scope script files as coverage context, so it
can judge whether a changed script has bats coverage, and it is dispatched whenever the round has an in-scope
script or `*.bats` file. `scripts/promote.zsh` is in two reviewers' lists on purpose: what it does to pins and
environments is the manifest reviewer's, and its shell logic is the script reviewer's.

**The script and test reviewers are reused, not owned.** They ship in `development-claude-plugin`, whose
fallback panel already runs them over the shell and bats files of any repo, so this panel launches them by
their qualified names and adds no second copy of either. Their prompts' `Analyze all composition content in
scope` line is what tells them the files are a composition repo's, not a plugin's. When that plugin is not
installed, the two agents cannot be launched: Step 2's failed-dimension rule applies to each.

**Rendered output is not in scope.** `deploy/<env>/importmap.json`, which `render-importmap.zsh` writes from the
manifest, is generated: nobody edits it by hand, so a finding against it cannot be acted on. Its source, the
manifest, is reviewed instead. Say so if the scope named it explicitly.

**A non-empty scope with no in-scope file is NOT APPLICABLE, not clean.** When the loop hands you files but none
of them is in any reviewer's list (a docs-only story, a change confined to `deploy/` or `e2e/` READMEs), on a
**full** round whose carry holds none of this panel's dimensions, report the round **not applicable** to the
caller, naming the out-of-scope files, and write **nothing** to the findings path. A `[]` there would be the
loop's CONVERGED condition over a change no agent read. On a **delta** round, apply the delta-round rules above
unchanged. **On either kind of round, a carry holding an entry of one of this panel's dimensions means you
launch that dimension's agent**, so the entry is accounted for even though no file in scope is its kind.

## Step 1: Launch the review agents in parallel

Use the Task tool to spawn **every agent whose in-scope list is non-empty this round (the test reviewer's
counts the script files it is given as context), or whose dimension the split-carry map holds, simultaneously in
a single message** with `run_in_background: true`. Use each agent's
name from the table above as its `subagent_type` (`subagent_type: composition-manifest-reviewer`, and the
qualified names for the two reused agents), so it runs on the model declared in its definition, and pass the
prompt below — substituting its **Dimension** for `{DIMENSION}`, its **name** for `{AGENT NAME}`, its own
in-scope files for `{the review scope}`, and the current review **round** for `{ROUND}` (`1` for a standalone
run). This is where the machine-readable JSON layer is wired in once, for every agent, so the reviewer
definitions stay pure prose.

When the **review loop** drives this panel from round 2 on, its dispatch plan
also carries two paths — `fix_verification_path` and `adjudicated_path` — and
the reviewers must be told about both. The first is the only way a fix that
silently did not land gets re-raised (a delta round cannot re-derive it), and the
second is what stops the panel re-litigating what the human already waived. Add
each line below only when the plan names a **non-null** path for it — a
standalone run has no descriptor at all, and on round 1 the loop's own caller
passes no `--fix-verification`.
The Fix verification line carries the path the split-carry map (above) gives the
reviewer's **own** dimension, never `fix_verification_path` itself, and is
added only when the map holds that dimension (#2010).
The `Fix-pass hunks (delta round):` line is added only when the plan's
`scope_mode` is `"delta"`, never because `delta_hunks` is non-null, exactly as
`/development-claude-plugin:review` states it (#2011): the reused test reviewer's
delta-round rule reads it.

```text
Review scope: {the review scope}
Fix verification (round >= 2): {own_fix_verification_path} — the previous round's blockers. Confirm each one actually landed BEFORE looking for anything new. For each carried entry report ONE of confirmed / re-raised / unconfirmed, as one line keyed by the carry's own spelling — carried entry "<title>" (<file>, <dimension>): confirmed at <file:line> | re-raised (see finding) | unconfirmed — re-raising ONLY what you observed still present, at its ORIGINAL severity, citing the carried entry and the file:line plus the unchanged text or passing mutation in the findings file, even when its file is outside this round's scope; never re-raise on the absence of a fix. A re-raise is a finding whose file, dimension and title are the carried entry's own spelling (title verbatim) and whose line is the carried line or null, with what you observed in its description — under a different title it is not matched to the carry and the round is refused. Every entry in that file is of your own dimension ("{DIMENSION}", which the identity includes) and is yours alone to account for: no other reviewer is shown it. End your report with the triple: carried: confirmed N / re-raised M / unconfirmed K of TOTAL, where TOTAL is the number of entries in that file.
Already waived (round >= 2): {adjudicated_path} — suggestions earlier rounds surfaced and the human waived. Do not re-raise them as Suggestions, EXCEPT in a file the PREVIOUS ROUND'S FIX PASS touched (on a delta round that is this round's scope; on a closing full sweep that NO fix pass preceded the set is empty, so withhold them — but on a sweep the residue promotion earned, a fix pass did run, so the exemption applies as on any round). A genuinely blocking re-raise at CRITICAL/WARNING is always allowed.
Fix-pass hunks (delta round): {delta_hunks} — the previous fix pass's new-side line ranges, each {file, kind, start, end}: kind "added" is a pure addition, "changed" rewrote or removed lines that existed at the prior tree. Apply them as your agent definition's delta-round rule says; a definition that states no such rule ignores this line.

Analyze all composition content in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.
```

## Step 2: Collect Results

Wait for every agent you launched to complete, then read each one's output.

**An agent that fails is not an agent that found nothing.** If one errors, times out, cannot be launched, or
returns prose with no fenced `json` block, re-launch it once. If it fails again:

1. Name the missing dimension in the Overview and in Metrics, and
2. **Do not write the findings file at all.** Report the round as **failed** to the caller, naming the
   dimension that did not run.

A round that consolidated two dimensions' findings as if the third had reported clean would converge over a
change one reviewer never read. This gate applies only to an agent that was launched: a dimension with no
in-scope file and no carried entry is not run and produces nothing, which is not a failure.

## Step 3: Synthesize the Review

Combine all findings into a single review report with this structure:

```text
# Composition Review Summary

## Overview
Brief summary of what was reviewed and the health of the change to the constellation.

## Critical Issues
{All CRITICAL findings from all agents, grouped logically}

## Warnings
{All WARNING findings from all agents, grouped logically}

## Suggestions
{All SUGGESTION findings from all agents, grouped logically}

## Metrics
- **Total findings:** X (Y critical, Z warnings, W suggestions)
- **Carried entries:** confirmed N / re-raised M / unconfirmed K of TOTAL — required
  on any round whose `fix_verification_path` holds entries, whatever this
  report's findings are (#1583, #2010: each entry's outcome is its owning
  reviewer's — confirmed, else re-raised when that re-raise is in the findings
  file, else unconfirmed; reproduce each reviewer's per-entry
  lines under this line — they are the source of the accounting records)
- **Areas reviewed:** Constellation manifest, Script Quality and Tests, when the round ran them — on a failed
  round, **Areas not reviewed:** the dimension that did not run

## Verdict
One-paragraph overall assessment with the most important action items.
```

Deduplicate findings that two agents flagged. If two agents found the same issue, keep the more detailed version
and note that it was flagged by both.

## Step 4: Emit the machine-readable findings file

Alongside the human-readable summary above, aggregate the machine-readable JSON blocks the agents emitted
(schema: ARCHITECTURE.md → *Review finding schema*) into one findings array for this round — **only when every
launched agent completed** (Step 2 owns the failed case, and it does not reach here). Every finding already
carries its own `reviewer`, `dimension` and `round`, so this is a plain concatenation, not a join. Preserve every
finding: do not drop the duplicates you merged in the prose; the consolidator (#561) deduplicates downstream.

Write that array to the findings file for this round — the path the caller / orchestrator passed, or
`review-findings-round-<round>.json` when none is given (default `round` 1 when the panel runs standalone). Also
include it inline as one fenced `json` block under a `## Findings (JSON)` heading so a caller reading stdout can
pick it up.
