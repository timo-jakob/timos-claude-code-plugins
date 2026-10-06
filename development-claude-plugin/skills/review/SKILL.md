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

## Step 1: Plan the round, then run its script and launch its agents in parallel

The panel has six dimensions: five reviewer agents and one script. **This table is the round's plan** — a
reviewer runs this round exactly when its **Runs** cell holds. Read `scope_mode` from the round's dispatch
descriptor (in hook mode, `$REVIEW_SCOPE_MODE`), and the split-carry map as the carry preamble above says; a
standalone run has no descriptor at all, which the **Runs** cells name as *no plan*.

| Reviewer | Kind | Model | Dimension | Runs |
| --------------------------------- | ------ | ------ | -------------- | ---- |
| claude-plugin-prose-logic | agent | fable | prose_logic | every round |
| claude-plugin-contract-integrity | agent | opus | contract | `scope_mode` is `"full"`, or no plan, or `contract` is not in `skippable_dimensions`, or the split-carry map holds `contract` |
| claude-plugin-script-reviewer | agent | fable | script_quality | every round |
| claude-plugin-test-reviewer | agent | opus | tests | every round |
| claude-plugin-manifest-check | agent | sonnet | manifest_bump | `scope_mode` is `"full"`, or no plan; on a `"delta"` round only when the split-carry map holds `manifest_bump` |
| check-manifests.zsh | script | — | manifest | every round |

**A dimension the table does not plan for this round is not run and produces nothing** — no findings, no
triple — and that is not a dimension that failed to run. Two cells vary. The `manifest_bump` row: round 1 and
every closing sweep plan with `scope_mode: "full"`, so the agent judges bump size on both, and a delta round
brings it back only to account for its own carried entries (`reference/review-loop/carry.md` in the resolve-issue
skill, *Carry-driven dispatch (#2008)*). The `contract` row (#2009): it runs on every full round, and on a
`"delta"` round unless the plan's `skippable_dimensions` holds `contract` — the plan puts it there when a pure
selector finds that the round's fix pass touched no contract surface. Read `skippable_dimensions` from the
dispatch descriptor (in hook mode, `$REVIEW_SKIPPABLE_DIMENSIONS`, a JSON array string); a standalone run has
neither, which is the *no plan* case. A carried `contract` entry still brings it back, by the same
*Carry-driven dispatch (#2008)* rule.

**Run the script first, with Bash.** It is this skill's
`scripts/check-manifests.zsh`, in the same plugin cache directory as this `SKILL.md`:

```bash
<this skill's base dir>/scripts/check-manifests.zsh --repo <the plan's worktree_root, or . standalone> \
  --base <the plan's base, or origin/main standalone> --round {ROUND}
```

In hook mode (no descriptor, but not the table's *no plan*), the two values are `$REVIEW_REPO` and `$REVIEW_BASE`.

On a carried round whose split-carry map holds `manifest`, add `--fix-verification <the path the map gives
manifest> --carry-out <a file beside it>`. Its stdout is the `manifest` dimension's JSON block — a findings
array already in the Review finding schema, at its real severity, with no `proposed-severity:` line — and the
`--carry-out` file holds its per-entry carry lines and its triple, which stand for the `manifest` owner's
report exactly as a reviewer's lines do. It never reports an entry `unconfirmed`. An exit 2 is a malformed
invocation (or a carried entry this script does not own): fix the call and re-run once. Any other non-zero
exit, or a second exit 2, means the `manifest` dimension did not run.

Then use the Task tool to spawn **every agent the table plans for this round simultaneously in a single
message** with `run_in_background: true`. Each agent is defined in the `agents/` directory and already knows
what to look for — just pass the review scope.

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
On round 1 the plan may carry a third path, `self_check_path` (#2014) — the
writer's pre-review self-check items and the waivers on those left untested, so
a reviewer can see which gaps were consciously accepted. Add the `Self-check
waivers (round 1):` line only when the plan names a **non-null**
`self_check_path`, the same test: a standalone run and every round from 2 on
carry none.
The Fix verification line carries the path the split-carry map (above) gives the
reviewer's **own** dimension, never `fix_verification_path` itself, and is
added only when the map holds that dimension (#2010).

**The `Fix-pass hunks (delta round):` line takes a different test: add it only
when the plan's `scope_mode` is `"delta"` (#2011).** Never key it on
`delta_hunks` being non-null — the closing sweep and a residue-promoted sweep
plan with `--prior-tree` too, so their descriptor carries a hunk list while
their `scope_mode` is `"full"`, and a full round reviews at today's bar. Round
1, every full round and a standalone run therefore carry no such line, and the
test reviewer's delta-round rule (its mutation bar) does not apply to them.
Nor does a hook-mode round, even when `$REVIEW_SCOPE_MODE` is `delta`: it sees
no descriptor, so it has no `delta_hunks` to substitute — leave the line out
and never compute ranges yourself. Substitute the plan's `delta_hunks` array as compact JSON.

**The `Version increments:` line goes to `claude-plugin-manifest-check` alone.** That agent holds no git, and
both manifests in the tree already carry the new version, so it cannot see the version it is sizing against.
For each plugin whose `plugin.json` version differs from the base's, read the base version with
`git show <base>:<plugin>/.claude-plugin/plugin.json` in the script's `--repo` and `--base`, and list
`<plugin>: <base version> -> <new version>`, comma-separated; write `none` when no plugin's version moved.

```text
Review scope: {the review scope}
Fix verification (round >= 2): {own_fix_verification_path} — the previous round's blockers. Confirm each one actually landed BEFORE looking for anything new. For each carried entry report ONE of confirmed / re-raised / unconfirmed, as one line keyed by the carry's own spelling — carried entry "<title>" (<file>, <dimension>): confirmed at <file:line> | re-raised (see finding) | unconfirmed — re-raising ONLY what you observed still present, at its ORIGINAL severity, citing the carried entry and the file:line plus the unchanged text or passing mutation in the findings file, even when its file is outside this round's scope; never re-raise on the absence of a fix. A re-raise is a finding whose file, dimension and title are the carried entry's own spelling (title verbatim) and whose line is the carried line or null, with what you observed in its description — under a different title it is not matched to the carry and the round is refused. Every entry in that file is of your own dimension ("{DIMENSION}", which the identity includes) and is yours alone to account for: no other reviewer is shown it. End your report with the triple: carried: confirmed N / re-raised M / unconfirmed K of TOTAL, where TOTAL is the number of entries in that file.
Already waived (round >= 2): {adjudicated_path} — suggestions earlier rounds surfaced and the human waived. Do not re-raise them as Suggestions, EXCEPT in a file the PREVIOUS ROUND'S FIX PASS touched (on a delta round that is this round's scope; on a closing full sweep that NO fix pass preceded the set is empty, so withhold them — but on a sweep the residue promotion earned, a fix pass did run, so the exemption applies as on any round). A genuinely blocking re-raise at CRITICAL/WARNING is always allowed.
Self-check waivers (round 1): {self_check_path} — the writer's pre-review self-check: JSON items {file, kind, line, text} for script surface no bats case tests and rule sentences no bats needle pins, each still listed one carrying the writer's "waiver" reason. A waived item is a gap the writer chose to accept; judge it at your own bar, and do not raise it only because it is listed.
Fix-pass hunks (delta round): {delta_hunks} — the previous fix pass's new-side line ranges, each {file, kind, start, end}: kind "added" is a pure addition, "changed" rewrote or removed lines that existed at the prior tree. Apply them as your agent definition's delta-round rule says; a definition that states no such rule ignores this line.
Version increments (claude-plugin-manifest-check only): {increments} — each bumped plugin's version at the base and in this tree, as <plugin>: <base version> -> <new version>.

Analyze all plugin content in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.
```

## Step 2: Collect Results

Wait for every agent you launched to complete. Read each agent's output, and the script's stdout and
`--carry-out` file.

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
  report's findings are (#1583, #2010: each entry's outcome is its owning
  reviewer's — confirmed, else re-raised when that re-raise is in the findings
  file, else unconfirmed; reproduce each reviewer's per-entry
  lines under this line — they are the source of the accounting records)
- **Areas reviewed:** Prose Logic, Script Quality, Tests, Manifests, and Contract Integrity and Bump Size
  when the round planned them

## Verdict
One-paragraph overall assessment with the most important action items.
```

Deduplicate findings that multiple agents flagged. If two agents found the same issue, keep the more detailed
version and note that it was flagged by multiple reviewers.

## Step 4: Emit the machine-readable findings file

Alongside the human-readable summary above, aggregate the machine-readable JSON
blocks the agents emitted (schema: ARCHITECTURE.md → *Review finding schema*)
into one findings array for this round. Each agent emitted a fenced `json` block
of finding objects, and the script printed its array on stdout; concatenate them
all into a single flat array. Every finding
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

The five agents are prose and cannot be unit-tested — the `manifest` script is,
by `tests/check-manifests.bats` — so the agents' half of the panel is measured
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
