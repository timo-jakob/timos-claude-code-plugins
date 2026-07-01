---
name: approve
description: >
  Review and post approval/rejection to an open PR using the Claude Approver
  identity. Mints token locally, posts as claude-approver-bot. Same agent as
  CI. Pass a PR number or use current branch's PR.
disable-model-invocation: false
---

You are running the **Claude Approver** locally and **posting the verdict to GitHub**
as `claude-approver-bot`. The Approver App token is minted fresh from your local
Keychain; no platform account or GitHub Actions required.

**User input:** `$ARGUMENTS` (PR number, optional; defaults to current branch's PR)

## What this skill does

1. Verify Approver App is registered and installed on this repo.
2. Resolve which PR to review (explicit argument or current branch).
3. Mint Approver token locally via `mint-approver-token.zsh`.
4. Spawn `java-approver` agent with the minted token.
5. Agent posts verdict to GitHub as `claude-approver-bot`.

## Step 1 — Preflight

Verify prerequisites:

```bash
# Check Approver App is registered locally
test -f ~/.config/claude-plugins/apps.json || {
  echo "::error::Approver App not registered."
  echo "Run: development/skills/bootstrap/scripts/register-claude-apps.zsh"
  exit 1
}

# Check gh CLI
command -v gh >/dev/null 2>&1 || {
  echo "::error::gh CLI not on PATH. Install: brew install gh"
  exit 1
}

# Check gh authentication
gh auth status >/dev/null 2>&1 || {
  echo "::error::gh not authenticated. Run: gh auth login"
  exit 1
}
```

## Step 2 — Resolve the PR

Parse `$ARGUMENTS`:

- **Positive integer** (`123`, `--pr 123`) → use as PR number.
- **Empty** → run `gh pr view --json number` to find current branch's PR.
  If none, halt with clear message.

Capture repo:

```bash
REPO=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
```

## Step 3 — Mint Approver token

```bash
TOKEN=$(development/skills/maintenance/scripts/mint-approver-token.zsh)
if [ -z "$TOKEN" ]; then
  echo "::error::Failed to mint Approver token."
  echo "Check: Approver App registered + installed on this repo + Keychain accessible"
  exit 1
fi
```

## Step 4 — Invoke the java-approver agent

Spawn the agent with the minted token in the environment:

```text
Agent(
  subagent_type="java-approver",
  description="Review and post PR #<n>",
  prompt="""
    Review PR #<n> in <owner>/<repo>. Dry-run: false.

    GitHub token (GH_TOKEN) is provided with Approver App permissions.
    Post the verdict to GitHub using `gh pr review <n> --approve|--request-changes`.
  """
)
```

Pass these env vars to the agent:

- `GH_TOKEN=<minted token>`
- `PR_NUMBER=<n>`
- `REPO=<owner>/<repo>`
- `DRY_RUN=false`

The agent runs the same synthesis procedure as CI and posts the verdict
as `claude-approver-bot` when `DRY_RUN=false`.

## Step 5 — Report

When posting succeeds, confirm the review is visible:

```text
✓ Review posted to GitHub as claude-approver-bot
  https://github.com/<owner>/<repo>/pull/<n>#pullrequestreview-xyz
```

Print the agent's full output (human-readable verdict + findings + hidden
JSON block) for the user to inspect.

## Security & token handling

- **Token is minted fresh**, 1-hour lifetime (GitHub default).
- **Token is never logged or committed.**
- **Private key stays in system Keychain**, not in code or secrets.
- **Review is posted as `claude-approver-bot`**, not the user's identity.
- **Approver App has read-only code access** (can't push or modify code).
- **User controls when approval happens** — skill is user-triggered, not
  automated.

## When to use

- **When you're ready to approve/reject a PR** with AI synthesis (instead
  of waiting for CI to run).
- **For your own PRs** (Approver can't self-approve, but the verdict is
  useful for quality signal).
- **On team PRs** when you want a second opinion before human review.

## Cost

One Opus invocation of `java-approver` (~50–150 K tokens depending on
diff size). Same cost as CI, paid per local invocation.
