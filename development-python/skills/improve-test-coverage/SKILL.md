---
name: improve-test-coverage
description: >
  Raise test coverage on a Python project toward a target threshold by spawning
  `python-coverage-improver` agents in parallel worktrees. Brings legacy projects
  or under-covered modules up to desired coverage as deliberate investment outside
  the maintenance pipeline.
---

You are the standalone coverage improver coordinator. Your job is to **bring
project coverage up to a target**, not just fill gaps in a change. This skill
runs when a user wants to invest in test quality across a whole project or
codebase section.

## User invocation

```text
/development-python:improve-test-coverage [--target 80|90] [--scope MODULE_PATH]
```

- `--target`: Target coverage threshold (default: 80). Choose 80 for quick wins
  on refactorability, 90 for high-quality test suites.
- `--scope`: Optional path prefix (e.g., `src/myapp/`) to limit work to a
  subsection. Default: entire project.

## Execution

### Step 1 — Gather coverage and identify gaps

1. Run `pytest --cov=. --cov-report=json .coverage` to get current coverage.
2. Parse the JSON report to find all modules below the target threshold.
3. Filter to the `--scope` if provided.

**Gate:** If no modules are below target, return "All modules meet target ✓"
and exit.

### Step 2 — Batch modules into worktrees

Group under-covered modules into logical batches:

- **For small projects** (≤ 10 modules under target): one batch, one worktree.
- **For medium projects** (11–30 modules): split by top-level package (e.g.,
  `src/foo/`, `src/bar/`).
- **For large projects** (>30 modules): split by top-level package, and if any
  package has >15 modules, split that package further (e.g., `src/foo/core/`,
  `src/foo/service/`).

For each batch, build a `modules_to_improve` list. Each entry:

```json
{
  "path": "<module_path>",
  "current": <current_pct>,
  "target": <target_threshold>
}
```

Preserve the current → target gap for agent context.

### Step 3 — Spawn improver agents in parallel worktrees

For each batch, spawn `python-coverage-improver` in a fresh worktree:

```python
Agent(
  subagent_type="python-coverage-improver",
  description=f"Raise coverage on {len(modules_to_improve)} modules in batch N",
  isolation="worktree",
  prompt=f"""
    repo_path: {repo_path}
    test_root: tests/
    target: {target_threshold}
    modules_to_improve: {json.dumps(modules_to_improve)}
    worktree.base_branch: main

    Write behavior tests to bring each module from its current coverage up to
    the target. Do NOT modify production code.
    Run pytest in the worktree to verify new tests pass and coverage improves.
    Commit your changes on the worktree branch before returning.
  """
)
```

Spawn these **in parallel** — don't wait for batch N before starting batch N+1.

### Step 4 — Collect results and return branches

When all agents finish, collect:

- `worktree_branch`: branch name
- `modules_improved`: array of `{ "path", "before", "after" }` per module
- `summary`: one-line summary per batch

Return:

```json
{
  "batches": [
    {
      "batch_id": 1,
      "agent_output": "...",
      "worktree_branch": "<branch>",
      "worktree_path": "<path>",
      "modules_improved": [
        { "path": "src/foo/bar.py", "before": 65, "after": 82 }
      ],
      "summary": "Raised 3 modules from 60–70% to 80%+"
    },
    ...
  ],
  "total_modules_improved": <count>,
  "coverage_before": <overall_pct>,
  "coverage_after": <overall_pct_if_re_measured>
}
```

The user then reviews and merges each branch.

## Design notes

- **Parallel worktrees:** Each batch runs independently, so N modules under
  target can be improved ~N times faster than serial (bounded by concurrent
  agent slots).
- **No merging:** This skill returns branches; it does not merge them. The user
  decides merge order and handles any conflicts (unlikely given orthogonal
  modules).
- **Best-effort:** If an agent can't improve a module (e.g., can't infer intent
  from existing tests), it returns that module in `unable_to_fix`. The user can
  tackle those manually or accept lower coverage on those specific modules.
- **Re-measure:** After merging all branches, the user can re-run this skill
  to see the new overall coverage. Iterate toward the target.

## Assumptions

- `pytest` is installed and the project's test suite passes with current venv.
- `.venv/` is the project's virtual environment (or equivalent is set up).
- Tests are in `tests/` or auto-discovered by pytest.
- Coverage report is JSON-compatible (standard pytest-cov output).

## What this is NOT

- **Not a lint/format tool** — it only adds tests, never rewrites production code.
- **Not a mutation-testing framework** — no grammar-based test generation, only
  behavior-driven tests.
- **Not the maintenance improver** — that's surgical (fills gaps in planned
  changes). This is strategic (deliberate test investment).
