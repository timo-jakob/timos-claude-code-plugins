---
name: review
description: Perform a comprehensive Go code review using 5 specialized parallel agents
disable-model-invocation: false
---

You are a senior Go code review orchestrator. The user has requested a comprehensive code review.

**Scope:** $ARGUMENTS

If the scope is empty, review all Go files in the current project. Otherwise, restrict the review to the specified
files, directories, or areas.

Exclude generated sources from the review scope — `*.pb.go` and `*.pb.gw.go` are emitted by `buf generate` from the
authoritative `.proto` files, so findings against them are unactionable: the fix belongs in the proto or the codegen
config. Say so if the scope named them explicitly.

## Step 1: Launch All 5 Review Agents in Parallel

Use the Task tool to spawn all 5 agents below **simultaneously in a single message** with `run_in_background: true`.
Each agent is defined in the `agents/` directory and already knows what to look for — just pass the review scope.

Launch these 5 agents in one message:

| Agent | Model | Dimension |
| ------------------------ | ------ | ------------ |
| go-bug-hunter | fable | bugs |
| go-security-reviewer | fable | security |
| go-performance-reviewer | opus | performance |
| go-code-quality | opus | code_quality |
| go-test-reviewer | opus | tests |

For each agent, use its name as the `subagent_type` (e.g. `subagent_type: go-bug-hunter`) so it runs on the model
declared in its definition, and pass the prompt below — substituting that agent's **Dimension** (from the table
above) for `{DIMENSION}`, its **name** for `{AGENT NAME}`, and the current review **round** for `{ROUND}` (`1` for a
standalone run). This is where the machine-readable JSON layer is wired in once, for every agent, so the reviewer
definitions stay pure prose:

```text
Review scope: {the review scope}

Analyze all Go code in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.
```

**Tell the agents the module's Go version.** Read the `go` directive from the root `go.mod` and include it in the
scope line (e.g. `Review scope: ./internal/... (module go 1.24)`). Several Go review judgements turn on it — most
sharply the per-iteration loop-variable semantics that changed in Go 1.22 (where the same `go func()` capture is a
bug below and correct at or above) and the Go 1.23 timer-collection change that turns a `time.After`-in-loop leak
into a mere allocation nit. Without the version an agent must guess, and a confidently-wrong concurrency finding is
worse than none.

Resolve it explicitly rather than assuming one root module:

- **No root `go.mod`** (a `go.work` workspace, or the scope points inside a submodule) — use the `go` directive of
  the module that actually **contains each scoped path**.
- **The scope spans modules with different directives** — pass a per-module **mapping**, e.g.
  `(module ./svc-a go 1.21; module ./svc-b go 1.24)`, and tell the agents to judge each file by its own module's
  directive. Do **not** collapse them to a single version. Collapsing to the *lowest* looks conservative and is
  the opposite: these gates fire in the false-positive direction, so applying 1.21 semantics to a 1.24 module
  makes the bug-hunter flag a correct loop-variable capture as a CRITICAL race. Collapsing to the *highest*
  suppresses real findings in the older module. Neither is safe; the mapping is.
- **Undeterminable** — say `(go version unknown)` in the scope line. The agents are instructed to state the
  semantics they assumed; that is the honest outcome, and far better than silently defaulting to "latest".

## Step 2: Collect Results

Wait for all 5 background agents to complete. Read each agent's output.

**An agent that fails is not an agent that found nothing.** If one errors, times out, or returns prose with no
fenced `json` block, re-launch that one agent once. If it fails again:

1. Name the missing dimension in the Overview and in Metrics, and
2. **Do not write the findings file at all.** Report the round as **failed** to the caller, naming the dimension
   that did not run.

Step 4's aggregate is only written when all five dimensions completed. This is deliberately blunt because the
machine channel cannot express partial: the #558 finding schema is a flat array of finding objects with no
round-status field, so a four-dimension array written to `findings_path` is byte-indistinguishable from a clean
five-dimension review, and the consolidator would waive the missing dimension's blockers. Writing nothing is not a
safe fallback either — a caller that maps an absent file to `[]` reads that as clean too — which is exactly why the
failure has to be surfaced **to the caller**, not merely recorded in prose. (The schema gap is family-wide, not
Go-specific; it is tracked separately.)

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
version and note that it was flagged by multiple reviewers. Expect genuine overlap on goroutine lifetime: the
bug-hunter frames an unstoppable goroutine as a leak, the performance reviewer frames it as unbounded growth. That
is one issue seen through two lenses — merge it, keeping both framings' detail.

## Step 4: Emit the machine-readable findings file

Alongside the human-readable summary above, aggregate the machine-readable JSON
blocks the agents emitted (schema: ARCHITECTURE.md → *Review finding schema*)
into one findings array for this round — **only when all five dimensions
completed** (Step 2 owns the incomplete case, and it does not reach here). Each
agent emitted a fenced `json` block of finding objects; concatenate them all
into a single flat array. Every finding
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
