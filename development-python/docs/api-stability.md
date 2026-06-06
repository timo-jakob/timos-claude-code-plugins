# API stability bootstrap artifacts (Python)

Specification for the API-stability files that `/development:bootstrap`
renders into a Python project. The generic bootstrap orchestrator
dispatches here — it knows *that* something needs rendering for Python,
but the *what* and *how* live in this language plugin per the
language-first principle in `ARCHITECTURE.md`.

This file is read by the bootstrap skill (Step 3f) and by the
`bootstrap-validator` agent (Step 3.5). Keep it the canonical reference
for the Python API-stability surface; do not duplicate any of this content
back into the generic bootstrap SKILL.

## When to render

Render the artifacts below when BOTH of these hold:

- `python` is in the detected languages list.
- `pyproject.toml` exists at the repo root AND contains a `[project]`
  table with a `name` field.

This is **independent of `--claude-approver`** — every Python project
that publishes a package benefits from the API-stability gate, whether
or not the Approver is also enabled.

## Files to render

Sources live in the bootstrap plugin's template tree (the bootstrap
plugin owns the templates directory regardless of language); this spec
just names them.

| Template (in this plugin family) | Target path in repo | Placeholders |
|---|---|---|
| `development/skills/bootstrap/templates/common/.github/workflows/api-stability.yml.tmpl` | `.github/workflows/api-stability.yml` | `{{DEFAULT_BRANCH}}`, `{{PYTHON_VERSION}}` |
| `development/skills/bootstrap/templates/languages/python/check-api-stability.py` | `.github/scripts/check-api-stability.py` | (none) |

Both files follow the bootstrap's standard idempotency rules. The script
is updated out-of-band by the plugin family on Griffe-API changes;
treat the generated copy as the user's to customise after first render.

## What the workflow does

Runs `griffe check` between the PR's merge-base and HEAD on the package
named in `pyproject.toml [project].name`, then gates with a
**version-bump bypass**:

> Breaking changes are allowed when EITHER `pyproject.toml
> [project].version`'s **major component bumps** OR the PR title declares
> the break with `!` after the conventional-commit type (`feat!:`,
> `fix(api)!:`, `refactor!:`, etc.).

The workflow uploads `griffe-findings.json` as an artifact with `if:
always()` so consumers (notably the Claude Approver) can read it even
when the gate failed — that's the whole point of having two layers.

A Job Summary is rendered so the verdict is visible in the GitHub UI
without clicking into the artifact.

## Branch protection stance

`branch-protection.sh` does **not** add `api-stability` as a required
status check by default. The gate starts in **advisory mode** — visible
in the GitHub UI but not blocking merges. Once the user has lived with
it for a release or two and trusts it, they promote it to required via
GitHub Settings → Branches UI (or by re-running `branch-protection.sh`
with the `api-stability` context added explicitly).

This is the advisory-→-strict rollout phasing from
[#174](https://github.com/timo-jakob/timos-claude-code-plugins/issues/174).

## Coupling with the Claude Approver

When the Claude Approver is also enabled (`--claude-approver true` ran
at bootstrap time), the Approver reads `griffe-findings.json` from
this workflow's artifact and applies per-PR-type criteria from
`.claude/approver-policy.md` on top of the gate's binary verdict.

A typical case: a `refactor:` PR that the gate let through with a `!`
declaration still triggers `REQUEST_CHANGES` from the Approver, because
the per-type rule for `refactor:` is "no public API change, full stop."

**The gate's bypass and the Approver's per-type criteria are
deliberately not the same thing** — that distinction is the whole
reason for having both layers.

## Validator checks (called from generic Step 3.5)

When the artifacts above were rendered, the `bootstrap-validator`
agent verifies:

- `.github/workflows/api-stability.yml` parses as valid YAML.
- `.github/scripts/check-api-stability.py` exists, is executable
  (mode `0755` or similar), and its first line is the
  `#!/usr/bin/env python3` shebang.
- `.github/workflows/api-stability.yml` retains no `{{DEFAULT_BRANCH}}`
  or `{{PYTHON_VERSION}}` placeholders (substitution ran).

## Out of scope (this plugin)

The other contract surfaces from #174 — REST / OpenAPI, gRPC / Protobuf,
GraphQL, AsyncAPI / event schemas, CLI snapshots, env-var schemas,
config-file schemas, webhook payloads, queue / topic message formats,
MCP tool signatures, exposed DB views — are not in scope for this
Python-specific spec. They will land under their own language plugins
(e.g. CLI snapshots and library exports are language-bound) or under
topic plugins (e.g. `development-container` for OCI-related contracts)
as #174 progresses.
