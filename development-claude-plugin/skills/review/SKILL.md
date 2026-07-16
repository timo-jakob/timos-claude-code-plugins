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

```text
Review scope: {the review scope}

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
review-loop telemetry, `.claude/telemetry/review-loop.jsonl` — see the epic #810
design spec.)
