---
name: review
description: Perform a comprehensive JavaScript/TypeScript code review using 6 specialized parallel agents
disable-model-invocation: false
---

You are a senior JavaScript/TypeScript code review orchestrator. The user has requested a comprehensive code review.

**Scope:** $ARGUMENTS

If the scope is empty, review all JavaScript and TypeScript files in the current project. Otherwise, restrict the
review to the specified files, directories, or areas.

**The whole-project fallback is for a standalone invocation only.** When the
**review loop** drives this panel (`/development:resolve-issue` §3.5), the scope
it hands you is a round's `changed_files` — and from round 2 on that is the
*delta* since the previous round, which can legitimately be empty (#1434). An
empty scope from the loop is never a licence to re-review the whole project:
that is exactly the independent-repeat behaviour delta scoping removes, and the
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

**What is in scope.** JavaScript and TypeScript sources: `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`, `.cts` and
`.tsx`, plus the `package.json` and `tsconfig*.json` the diff touches. Build output and installed or generated code
(`node_modules/`, `dist/`, `build/`, `coverage/`, and a client generated from an OpenAPI or proto contract) are not:
nobody edits them by hand, so a finding against them is unactionable — the fix belongs in the source or the
generator's input. Say so if the scope named them explicitly.

**A non-empty scope with no in-scope file is NOT APPLICABLE, not clean.** When the loop hands you files but none
of them is JavaScript or TypeScript (a docs-only story, a workflow-only fix pass, plugin prose in a plugin repo that
also ships a Node hook), the story changed something this panel cannot review. On a **full** round, report the
round **not applicable** to the caller, naming the out-of-scope files, and write **nothing** to the findings path:
a `[]` there is the loop's CONVERGED condition over a change no agent read. On a **delta** round, apply the
delta-round rules above unchanged — without launching agents, `[]` only when the carry is empty; with a non-empty
carry, launch the agents so every carried entry is accounted for, and write their aggregate as Step 4 says.

**Tell the agents the runtime.** Put two facts in the scope line, each on its own: the Node version — the root
`package.json`'s `engines.node`, or `node version unknown` when it declares none — and `TypeScript` only when a
`tsconfig.json` is present (e.g. `Review scope: src/** (node >=22, TypeScript)`). Several judgements turn on them —
whether a global `fetch` exists, whether an unhandled rejection ends the process by default — and an agent that
has to guess should say so rather than silently assume the latest runtime. Code that runs only in the browser has
no Node version; say so for those paths.

## Step 1: Launch All 6 Review Agents in Parallel

Use the Task tool to spawn all 6 agents below **simultaneously in a single message** with `run_in_background: true`.
Each agent is defined in the `agents/` directory and already knows what to look for — just pass the review scope.

Launch these 6 agents in one message:

| Agent | Model | Dimension |
| ----------------------- | ------ | ------------ |
| js-bug-hunter | fable | bugs |
| js-security-reviewer | fable | security |
| js-performance-reviewer | opus | performance |
| js-code-quality | opus | code_quality |
| js-test-reviewer | opus | tests |
| js-resilience-reviewer | opus | resilience |

For each agent, use its name as the `subagent_type` (e.g. `subagent_type: js-bug-hunter`) so it runs on the
model declared in its definition, and pass the prompt below — substituting that agent's **Dimension** (from the
table above) for `{DIMENSION}`, its **name** for `{AGENT NAME}`, and the current review **round** for `{ROUND}`
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

Analyze all JavaScript and TypeScript code in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.
```

## Step 2: Collect Results

Wait for all 6 background agents to complete. Read each agent's output.

**An agent that fails is not an agent that found nothing.** If one errors, times out, or returns prose with no
fenced `json` block, re-launch that one agent once. If it fails again:

1. Name the missing dimension in the Overview and in Metrics, and
2. **Do not write the findings file at all.** Report the round as **failed** to the caller, naming the dimension
   that did not run.

Step 4's aggregate is only written when all six dimensions completed. This gate applies only once the agents
were launched: an empty-delta round that carries nothing launches none and still writes `[]`. The #558
finding schema is a flat array with no round-status field, so a five-dimension array written to
`findings_path` is byte-indistinguishable from a clean six-dimension review, and the consolidator would waive the
missing dimension's blockers.

## Step 3: Synthesize the Review

Combine all findings into a single, well-organized review report with this structure:

```text
# Code Review Summary

## Overview
Brief summary of what was reviewed and overall code health assessment.

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
- **Areas reviewed:** Bugs, Security, Performance, Code Quality, Tests, Resilience — on a failed round, only the
  dimensions that completed, plus **Areas not reviewed:** the one that did not

## Verdict
One-paragraph overall assessment with the most important action items.
```

Deduplicate findings that multiple agents flagged. If two agents found the same issue, keep the more detailed
version and note that it was flagged by multiple reviewers.

## Step 4: Emit the machine-readable findings file

Alongside the human-readable summary above, aggregate the machine-readable JSON
blocks the agents emitted (schema: ARCHITECTURE.md → *Review finding schema*)
into one findings array for this round — **only when all six dimensions
completed** (Step 2 owns the incomplete case, and it does not reach here). Each agent emitted a fenced `json` block
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
