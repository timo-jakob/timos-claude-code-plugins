# Plugin Approver — ENV-gated override for claude-plugin repos

Date: 2026-10-05 · Status: design approved in chat, spec under review

## Goal

Let a refined epic run end-to-end on a claude-plugin repo. Today
`/development:resolve-issue` stops after every sequential child's PR because a
claude-plugin repo is human-only: a human must approve and merge before the next
child can branch off fresh `main`. With an explicit, per-session opt-in, the
Claude Approver approves those PRs instead, so armed auto-merge fires and the
epic advances in the same invocation — the cadence Approver repos already have.

## Non-goals

- Changing the default. A claude-plugin repo stays human-only; the recorded
  `approval:` key, `resolve-approval.zsh`, and its refusal of a recorded
  `approver` on a plugin repo are untouched.
- Bootstrap's Step 4f approve → merge drive, `/development:sync-prs`, and any
  CI-side Approver workflow.
- Bypassing branch protection: approval is always a real review posted by the
  Approver App identity; nothing admin-merges.

## Constraints

- **Opt-in lives in the environment only**: `CLAUDE_PLUGIN_APPROVER=1`. Only
  the exact value `1` enables it; unset, empty, `0`, `true` or anything else is
  off. Nothing is written to the repo.
- **No Approver App is a supported configuration, not an error.** An
  organisation that forbids AI approvals simply does not register or does not
  install the Approver App. Every flow in scope must then take the human path
  **without an error message, a warning, or a non-zero exit** — whether or not
  `CLAUDE_PLUGIN_APPROVER` is set.
- The Approver's author allowlist stays machine-only: it only reviews PRs
  authored by the Maintenance App (writer) identity.

## Design

### 1. The decision helper — `plugin-approver-override.zsh`

A single script answers "may the Approver approve PRs on this repo in this
session?", so no flow reads the ENV variable itself. Location:
`development/scripts/approval/plugin-approver-override.zsh` (shared by
resolve-issue and maintenance).

Checks, in order — the first that fails decides:

| # | Check | Result when it fails |
|---|-------|----------------------|
| 1 | `CLAUDE_PLUGIN_APPROVER` is exactly `1` | `off`, reason `env-unset` |
| 2 | repo is claude-plugin (`.claude-plugin/plugin.json` or `marketplace.json`) | `off`, reason `not-plugin-repo` |
| 3 | Approver registered for the repo's owner (`claude-apps-owner.zsh status claude-approver` exit 0) | `off`, reason `approver-not-registered` |
| 4 | Approver App installed on this repo (`mint-approver-token.zsh --check-installed` exit 0) | `off`, reason `approver-not-installed` |

All four are ON → `on`. Output on stdout, one `key=value` per line:
`override=on|off`, `reason=<slug>` (when off). **Exit 0 for every on/off
answer**, including the two "no Approver App" reasons — absence is a decision,
not a failure. Nothing is printed to stderr for those reasons.

The helper exits non-zero (1) **only for a broken setup that someone did
intend**: the Approver is registered but its key is missing
(`approver: key missing`), the registry is unreadable, or the installation
lookup failed for a reason other than "Not Found" (network, rejected key). It
then relays the existing `fix:` line. Callers treat exit 1 as `off` plus one
surfaced diagnostic — the human path still runs.

The PR-author check (Maintenance bot) is not part of the helper — it belongs to
the approve skill's preflight, because the helper answers per repo/session and
the author is per PR.

### 2. Quiet installation probe — `mint-approver-token.zsh --check-installed`

Today a missing installation exits 2 with an error message, the same exit code
as a network failure or a rejected key. Add a `--check-installed` flag that
signs the JWT and looks up `/repos/<owner>/<repo>/installation`, mints **no**
token, and exits:

- `0` — installed;
- `3` — GitHub returned `Not Found` (not installed) — **silent**, no stderr;
- `2` — any other failure, with today's diagnostics.

Without the flag the script behaves exactly as today (callers such as
`/development:open-pr` key their fallback on the existing message).

### 3. The plugin approver — in `development-claude-plugin`

**`agents/claude-plugin-approver.md`** — same contract and model tier as
`python-approver`: reads the policy, the PR, its diff, and the PR body's hidden
`review-dossier` block (the five claude-plugin review dimensions), builds a risk
register, calibrates confidence, and posts `APPROVE` / `REQUEST_CHANGES` /
`COMMENT` via `gh pr review` with the Approver token (read from the mode-600
file path, #640).

**Plugin-specific never-approve bar.** The agent never posts `APPROVE` — it
posts `COMMENT` naming the reason, so a human decides — when the PR:

- carries tracked residue (the dossier's `open > 0`);
- touches `.github/workflows/*`;
- touches the approval or identity machinery: any `*approver*` agent, skill or
  policy template, `mint-approver-token.zsh`, `resolve-approval.zsh`,
  `claude-apps-owner.zsh`, `install-claude-apps.zsh`,
  `register-claude-apps.zsh`, or `plugin-approver-override.zsh`.

This keeps the concern behind the human-only position (a plugin repo is the
origin of every other repo) applied to the changes where it bites hardest.

**`skills/approve/SKILL.md`** — mirrors `development-python:approve`: preflight,
resolve PR, mergeability gate, just-in-time mint, spawn
`claude-plugin-approver`. Its preflight runs the override helper first and
**refuses unless `override=on`**, printing the reason in one informational line
(not an error) and exiting 0, so a human-only run that reaches it is a clean
no-op. It also refuses a PR whose author is not the Maintenance bot.

**Policy.** Core policy (`approver-policy-core.md.tmpl`) plus a new
`development-claude-plugin/skills/approve/approver-policy-overlay.md.tmpl`,
shipped with the approve skill rather than under bootstrap's
`templates/languages/` (a plugin repo is not a language, and bootstrap never
renders a policy for it). The skill renders core + overlay at review time into
its scratch — bootstrap renders no `.claude/approver-policy.md` for a
human-only repo, and this design does not change that.

### 4. resolve-issue

After `open-pr` (Single-issue §6 and every epic child), run the helper:

- **`override=on`** → wait for green with `merge-pr-cycle.zsh <pr>` (exit 4
  AWAITING-APPROVAL is the expected cue), run
  `/development-claude-plugin:approve <pr>`, re-read `reviewDecision`.
  `APPROVED` → `await-pr-checks.zsh <pr>` until merged, then fetch and branch
  the next child **in the same invocation**, exactly the Approver-repo cadence.
  Any other verdict → today's human-only stop (report the PR; resume on
  re-run), naming the Approver's verdict.
- **`override=off`** → today's human-only behaviour, byte-for-byte. When the
  reason is `env-unset` or `not-plugin-repo`, say nothing extra. When the ENV
  was set but the reason is `approver-not-registered` or
  `approver-not-installed`, the final report carries one informational line —
  `AI approval: off (Approver App not installed) — a human approves.` — not a
  warning.

Prose touched: SKILL.md (frontmatter description, §6 Outcomes, Epic flow
"Waiting for each merge"), `reference/interactive.md`, `reference/sequential.md`.

### 5. maintenance

Phase 2.5 "Approver mode — detect once per run": on a claude-plugin-primary
repo, the mode is `none` unless the helper says `override=on`, in which case it
is `local`. The existing `local` branch of Phase 8's approval gate then drives
`/development-claude-plugin:approve` — no new loop. `override=off` for a "no
Approver App" reason is silent, matching today's silent skip on
`approver: not registered`.

### 6. Docs

One added sentence each, stating the ENV exception and that an absent Approver
App is the supported way to forbid AI approvals:

- `ARCHITECTURE.md` — the approval-model paragraph (#1684).
- `development/skills/bootstrap/docs/APPROVER.md` — a short "Plugin repos:
  opt-in per session" section, plus "Forbidding AI approvals: don't register or
  don't install the Approver App".
- `development/skills/open-pr/SKILL.md` — the "a human approves (no AI
  Approver)" sentence gains the ENV exception.

## Testing (bats)

- **Helper truth table**: ENV unset / `0` / `true` / `1`; non-plugin repo;
  approver not registered; registered but not installed (stubbed probe exit 3);
  all on. Assert stdout, **exit 0**, and **empty stderr** for both "no Approver
  App" cases — with and without the ENV set.
- **Helper broken setup**: key missing, probe exit 2 → exit 1 with the `fix:`
  line relayed.
- **`--check-installed`**: stubbed `curl` returning an installation, `Not
  Found`, an empty body, and a rejection → exits 0 / 3 (silent) / 2 / 2; and no
  token-mint request is made.
- **Plugin approver skeleton**: agent + skill frontmatter (name, description,
  tools, model) and plugin layout.
- **Needles**: the never-approve bar's three conditions in the agent; the
  skill's preflight refusal on `override=off`; resolve-issue and maintenance
  prose name the helper rather than the raw ENV variable.
- Full bats suite under `LC_ALL=C` before the PR.

## Versioning

Minor bump of `development` and `development-claude-plugin` (new capability),
in `plugin.json` and `marketplace.json`, re-bumped right before committing.

## Prerequisite (operator)

To use the override on this repo, the Approver App must be installed on
`timo-jakob/timos-claude-code-plugins` (`install-claude-apps.zsh`). It is
registered for the owner today; installation on this repo is unverified. Not
installing it is the supported way to keep this repo human-only.
