---
name: review
description: Perform a comprehensive Claude-plugin review using 5 specialized parallel agents
disable-model-invocation: false
---

You are a senior Claude-plugin review orchestrator. The user has requested a comprehensive review of plugin
content — skills, agents, scripts, tests, and manifests. In a plugin repo the shipped artifact is mostly
instructions: a skill's prose *is* its behaviour, so prose-logic defects are this panel's headline dimension,
not an afterthought.

**Scope:** $ARGUMENTS

If the scope is empty, review all plugin content in the current project (skill/agent `.md` files, `scripts/`,
`tests/`, and the version manifests). Otherwise, restrict the review to the specified files, directories, or
areas.

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
write a bare `[]`: account for every carried entry. For each carried entry report
ONE of: confirmed (name the file:line where the fix is), re-raised (name the
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

**Report the triple whenever the carry is non-empty** — `say in your report that
you confirmed N carried entries, re-raised M and left K unconfirmed, of TOTAL` —
**whatever you write to the findings file**, `[]` or otherwise. That count is the
only thing that tells a caller a result which passed verification from one that
skipped it, so a round that confirms the carry and *also* finds new blockers
still owes it. Omitting it is treated as a failed round.

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
records, one per carried entry, naming the reviewers in the three arrays — and
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

## Step 1: Launch All 5 Review Agents in Parallel

Use the Task tool to spawn all 5 agents below **simultaneously in a single message** with `run_in_background: true`.
Each agent is defined in the `agents/` directory and already knows what to look for — just pass the review scope.

Launch these 5 agents in one message:

| Agent | Model | Dimension |
| --------------------------------- | ------ | -------------- |
| claude-plugin-prose-logic | fable | prose_logic |
| claude-plugin-contract-integrity | opus | contract |
| claude-plugin-script-reviewer | fable | script_quality |
| claude-plugin-test-reviewer | opus | tests |
| claude-plugin-manifest-check | sonnet | manifest |

For each agent, use its name as the `subagent_type` (e.g. `subagent_type: claude-plugin-prose-logic`) so it runs
on the model declared in its definition, and pass the prompt below — substituting that agent's **Dimension** (from
the table above) for `{DIMENSION}`, its **name** for `{AGENT NAME}`, and the current review **round** for `{ROUND}`
(`1` for a standalone run). This is where the machine-readable JSON layer is wired in once, for every agent, so the
reviewer definitions stay pure prose:

When the **review loop** drives this panel from round 2 on, its dispatch plan
also carries two paths — `fix_verification_path` and `adjudicated_path` — and
the reviewers must be told about both. They are the point of a delta round, not
decoration: the first is the only way a fix that silently did not land gets
re-raised (a delta round cannot re-derive it), and the second is what stops the
panel re-litigating what the human already waived. Add each line below only
when the plan names a **non-null** path for it — that one test covers both
cases you would otherwise reason about separately: a standalone run has no
descriptor at all, and on round 1 the loop's own caller passes no
`--fix-verification`. (Don't read it as "omit both on round 1": the
loop's own `plan` call passes `--adjudicated` on every round, so a loop-side
descriptor may name it from round 1. The driving session's round-1 plan does
not — and either way the non-null test gives the right answer.)

```text
Review scope: {the review scope}
Fix verification (round >= 2): {fix_verification_path} — the previous round's blockers. Confirm each one actually landed BEFORE looking for anything new. For each carried entry report ONE of confirmed / re-raised / unconfirmed, as one line keyed by the carry's own spelling — carried entry "<title>" (<file>, <dimension>): confirmed at <file:line> | re-raised (see finding) | unconfirmed — re-raising ONLY what you observed still present, at its ORIGINAL severity, citing the carried entry and the file:line plus the unchanged text or passing mutation in the findings file, even when its file is outside this round's scope; never re-raise on the absence of a fix. A re-raise is a finding whose file, dimension and title are the carried entry's own spelling (title verbatim) and whose line is the carried line or null, with what you observed in its description — under a different title it is not matched to the carry and the round is refused. Re-raise only carried entries of your own dimension ("{DIMENSION}", which the identity includes); an entry of another dimension that you see still present is reported unconfirmed, with what you saw in prose. End your report with the triple: carried: confirmed N / re-raised M / unconfirmed K of TOTAL.
Already waived (round >= 2): {adjudicated_path} — suggestions earlier rounds surfaced and the human waived. Do not re-raise them as Suggestions, EXCEPT in a file the PREVIOUS ROUND'S FIX PASS touched (on a delta round that is this round's scope; on a closing full sweep that NO fix pass preceded the set is empty, so withhold them — but on a sweep the residue promotion earned, a fix pass did run, so the exemption applies as on any round). A genuinely blocking re-raise at CRITICAL/WARNING is always allowed.

Analyze all plugin content in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.
```

## Step 2: Collect Results

Wait for all 5 background agents to complete. Read each agent's output.

## Step 3: Synthesize the Review

Combine all findings into a single, well-organized review report with this structure:

```text
# Plugin Review Summary

## Overview
Brief summary of what was reviewed and overall plugin health assessment.

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
  report's findings are (#1583: per-entry UNION outcomes — an entry is confirmed
  if any reviewer confirmed it, else re-raised if any reviewer's re-raise is in
  the findings file, else unconfirmed; reproduce each reviewer's per-entry
  lines under this line — they are the source of the accounting records)
- **Areas reviewed:** Prose Logic, Contract Integrity, Script Quality, Tests, Manifests

## Verdict
One-paragraph overall assessment with the most important action items.
```

Deduplicate findings that multiple agents flagged. If two agents found the same issue, keep the more detailed
version and note that it was flagged by multiple reviewers.

## Step 4: Emit the machine-readable findings file

Alongside the human-readable summary above, aggregate the machine-readable JSON
blocks the agents emitted (schema: ARCHITECTURE.md → *Review finding schema*)
into one findings array for this round. Each agent emitted a fenced `json` block
of finding objects; concatenate them all into a single flat array. Every finding
already carries its own `reviewer`, `dimension`, and `round`, so this is a plain
concatenation, not a join. Preserve every finding — do not drop the exact-
duplicate lines you merged in the prose; the machine layer keeps them and the
consolidator (#561) deduplicates downstream.

Write that array to the findings file for this round — the path the caller /
orchestrator passed, or `review-findings-round-<round>.json` when none is given
(default `round` 1 when the panel runs standalone). Also include it inline as
one fenced `json` block under a `## Findings (JSON)` heading so a caller reading
stdout can pick it up.

The aggregate is what the consolidator and `jq` consume, e.g.:

```bash
jq '[.[].severity] | group_by(.) | map({severity: .[0], count: length})' \
  review-findings-round-1.json
```

## The #798 golden fixture

The five agents are prose and cannot be unit-tested, so the panel is measured
against a defect whose answer is already known: **#798**, a prose-logic bug in
`development/skills/resolve-issue/SKILL.md` as of `4202beb` (pre-fix), whose E1
terminal case treated "zero open children" as proof an epic's work had merged —
no failure branch for the never-decomposed case. The panel takes a **scope**,
not a diff, so the fixture needs no dispatch machinery.

To run it, materialize the defective snapshot into a throwaway target repo:

```bash
development-claude-plugin/skills/review/scripts/build-golden-798-target.zsh
```

The script prints the target path; then drive the panel through the test
harness:

```text
/development-claude-plugin:test --target <printed path> \
  --task "/development-claude-plugin:review development/skills/resolve-issue/SKILL.md" \
  --expect "claude-plugin-prose-logic reports a prose_logic finding at severity WARNING or CRITICAL naming E1's terminal case treating zero open children as proof the epic's work merged, with no failure branch for a never-decomposed epic"
```

**PASS** iff `claude-plugin-prose-logic` reports a `prose_logic` finding at
`>= WARNING` naming the absent failure branch. **FAIL** on silence or on
`SUGGESTION`-only. (Recall on one known defect; precision is tuned against the
review-loop telemetry — the `pipeline: "review-loop"` records in
`.claude/telemetry/telemetry.jsonl` (#1004) — see the epic #810 design spec.)
