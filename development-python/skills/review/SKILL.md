---
name: review
description: Perform a comprehensive Python code review using 5 specialized parallel agents
disable-model-invocation: false
---

You are a senior Python code review orchestrator. The user has requested a comprehensive code review.

**Scope:** $ARGUMENTS

If the scope is empty, review all Python files in the current project. Otherwise, restrict the review to the
specified files, directories, or areas.

## Step 1: Launch All 5 Review Agents in Parallel

Use the Task tool to spawn all 5 agents below **simultaneously in a single message** with `run_in_background: true`.
Each agent is defined in the `agents/` directory and already knows what to look for — just pass the review scope.

Launch these 5 agents in one message:

| Agent | Model | Dimension |
| --------------------------- | ------ | ------------ |
| python-bug-hunter | fable | bugs |
| python-security-reviewer | opus | security |
| python-performance-reviewer | opus | performance |
| python-code-quality | opus | code_quality |
| python-test-reviewer | opus | tests |

For each agent, use its name as the `subagent_type` (e.g. `subagent_type: python-bug-hunter`) so it runs on the
model declared in its definition, and pass the prompt below — substituting that agent's **Dimension** (from the
table above) for `{DIMENSION}`, its **name** for `{AGENT NAME}`, and the current review **round** for `{ROUND}`
(`1` for a standalone run). This is where the machine-readable JSON layer is wired in once, for every agent, so the
reviewer definitions stay pure prose:

```text
Review scope: {the review scope}

Analyze all Python code in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.
```

## Step 2: Collect Results

Wait for all 5 background agents to complete. Read each agent's output.

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
- **Areas reviewed:** Bugs, Security, Performance, Code Quality, Tests

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
