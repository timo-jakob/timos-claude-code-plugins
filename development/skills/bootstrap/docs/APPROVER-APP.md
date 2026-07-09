# Claude Approver App — Design & Configuration

## Overview

The **Claude Approver App** is a GitHub App that posts code review verdicts (approval or requested
changes) to pull requests. The Approver App is **user-managed and invoked locally** via the
`/development-python:approve` skill, giving you control over when approval happens.

## Key Properties

- **Name pattern**: `claude-approver-<owner>` (owner-scoped to prevent collisions)
- **Type**: GitHub App (OAuth 2.0)
- **Invocation**: User runs `/development-python:approve <PR>` locally in Claude Code
- **Token lifetime**: 1 hour (GitHub default for installation tokens)
- **Registry**: Local at `~/.config/claude-plugins/apps.json` (same as Maintenance App)
- **Private key**: Stored in system Keychain (macOS) / Credential Manager (Windows) /
  pass/secret-tool (Linux)

## Permissions Required

The Approver App needs these GitHub permissions:

### Repository Permissions

Scope: repos this app is installed on

- `pull_requests: write` — post reviews (approval, requested changes, comments)
- `contents: write` — read PR diffs/files AND make the App's approvals count
  toward branch protection (push access = Contents permission, #418; the
  Approver never actually pushes)
- `checks: read` — read CI check run results (to inform approval decision)
- `security_events: read` — verify Code Scanning alert states under the App's
  own identity when reviewing security-fix PRs; without it those reads 403 and
  the agent falls back to the user's `gh` auth (#654)
- `commit_statuses: read` — read legacy commit statuses (Snyk, SonarCloud, etc.)

### Organization Permissions

When installing:

- None required (app is repo-scoped)

### User Permissions

- None (the app uses OAuth token, not user auth)

## Registration & Installation

### Step 1: Register the App (once per machine)

**Who**: User or admin (one-time setup)

```bash
development/skills/bootstrap/scripts/register-claude-apps.zsh
```

**What it does**:

- Creates GitHub App at `github.com/settings/apps/new` (user interactively creates it)
- Prompts for: app name, description, homepage URL, webhook URL (can be empty)
- Stores app ID + private key in `~/.config/claude-plugins/apps.json`
- Saves private key to system Keychain under `claude-plugins.claude-approver`

**Result**: App registered locally, ready to install on repos.

### Step 2: Install the App (once per repo)

**Who**: Repo admin
**When**: During `/development:bootstrap` setup

```bash
development/skills/bootstrap/scripts/install-claude-apps.zsh --approver-only
```

**What it does**:

- Adds Approver App to repo's installed apps
- Stores app metadata for later token minting

**Result**: App authorized on this repo, ready to post reviews.

## Comparison: Maintenance App vs Approver App

| Aspect | Maintenance App | Approver App |
| --- | --- | --- |
| **Purpose** | Opens PRs, pushes branches | Posts reviews/approvals |
| **Triggered by** | Orchestrator (local) | User skill (local) |
| **Permissions** | `contents: write`,  `pull_requests: write` | `pull_requests: write`,  `contents: read`, `checks: read` |
| **Invocation** | Internal to orchestrator | `/development-python:approve` (user) |
| **Posts as** | claude-maintenance-bot | claude-approver-bot |

Both are GitHub Apps registered locally — neither requires CI/GitHub Actions.

## Token Minting

Tokens are minted locally on demand using the `mint-approver-token.zsh` script:

```bash
mint-approver-token.zsh
```

- Reads app ID from `~/.config/claude-plugins/apps.json`
- Fetches private key from Keychain
- Calls GitHub API to get installation token (1 hour lifetime)
- Writes the token to a mode-600 temp file and prints the **path** (default);
  `--stdout` prints the raw token instead. The path-by-default design keeps the
  orchestrator from ever seeing the token value, so it can't be inlined into a
  subagent prompt or echoed into a transcript (#640)

**Used by**: `/development-python:approve` skill
**No platform account required**: Works with any AI coding assistant

## Why Separate Apps?

### Security

- Maintenance App: can write code (high risk)
- Approver App: can only read code + post reviews (lower risk)
- Fail-closed: if Approver token leaks, attacker can't push code

### Permissions Principle

- Each app gets minimum required permissions
- Easier to audit what each app can do
- User can selectively revoke Approver app without breaking maintenance

### Identity Clarity

- PR timeline shows `claude-maintenance-bot` for code changes
- PR timeline shows `claude-approver-bot` for approvals
- Clear attribution, audit trail

## Initial Setup

New repos bootstrapped with this version will have the Approver App configured for local
invocation only. No GitHub Actions workflow is generated — approval is always user-triggered
via the `/development-python:approve` skill.

## Security Considerations

### Token Handling

- Tokens are 1-hour lived (GitHub default)
- Private keys stored in system Keychain, not in code or config
- Tokens should not be logged or committed
- `mint-approver-token.zsh` writes the token to a mode-600 temp file and prints
  the **path** by default (the token value never touches stdout); the `--stdout`
  escape hatch prints the raw token only when a caller genuinely can't read a
  file path (#640)

### App Installation

- User controls which repos the app is installed on
- Can be revoked at any time (GitHub settings)
- No webhook required (approval is pull-based, not push)

### No Platform Lock-In

- App registration happens once per machine
- App can be used by any AI coding assistant (Claude, Copilot, etc.)
- User stays in control (invokes skill manually or via orchestrator they control)

## Implementation Checklist

- [x] #477: Complete this design document
- [x] #478: Implement `mint-approver-token.zsh`
- [x] #479: Remove workflow template from bootstrap
- [x] #480: Update bootstrap installation docs

## See Also

- `mint-approver-token.zsh` — token minting script
- `/development-python:approve` — approval skill (Phase 2)
- `.claude/approver-policy.md` — approval policy document
