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
3. Mergeability gate — a conflicting PR gets resolved first (by the
   right identity, never the Approver) and re-checked; review happens
   after, on the resolved head.
4. Mint Approver token locally via `mint-approver-token.zsh` (it writes the
   token to a mode-600 file and returns the **path**).
5. Spawn `go-approver` agent, passing the token **file path** in the prompt.
6. Agent reads the token from the path and posts the verdict as
   `claude-approver-bot`.

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
- **`--dry-run`** (in any position) → set `DRY_RUN=true` for a
  non-binding evaluation that **prints** the verdict instead of posting
  it; strip the flag before resolving the PR number. Absent → `DRY_RUN=false`.
- **Empty** (after stripping flags) → run `gh pr view --json number` to
  find the current branch's PR. If none, halt with a clear message.

Capture repo:

```bash
REPO=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
```

## Step 3 — Mergeability gate (conflicts get resolved BEFORE review)

A conflicting PR must never be reviewed or approved: auto-merge can't
fire on it, and the conflict resolution pushes a new head SHA that
invalidates the verdict anyway. Resolve first, review after — on the
resolved head.

```bash
MERGEABLE=$(gh pr view "$PR_NUMBER" --json mergeable -q .mergeable)
```

- `MERGEABLE` → continue to Step 4.
- `UNKNOWN` → GitHub is still computing mergeability; re-check after a
  few seconds (a handful of retries) before deciding.
- `CONFLICTING` → resolve according to who authored the PR, then
  re-enter this skill from Step 1:
  - `dependabot[bot]` → comment `@dependabot rebase` on the PR. Never
    hand-edit a Dependabot branch — Dependabot force-pushes over
    manual commits.
  - `renovate[bot]` → tick the rebase checkbox in the PR body: fetch
    it with `gh pr view --json body`, flip
    `- [ ] <!-- rebase-check -->` to `- [x]`, write it back with
    `gh pr edit --body`. Renovate rebases on its next run.
  - `claude-maintenance[bot]` (pipeline/writer PRs) → check out the
    head branch in a scratch worktree, rebase onto the base branch,
    resolve the conflicts, run the local build/tests, and push with a
    freshly minted writer token (`mint-maintenance-token.zsh`) using
    `--force-with-lease`, so the bot stays author and last pusher.
  - A human author → don't touch their branch; report the conflict to
    the user and offer the rebase steps instead.

The Approver App itself can never do the resolving — it has read-only
code access by design (reviewer and author must stay separate
identities). After the resolution push, wait for CI on the **new**
head SHA to go green, then proceed.

## Step 4 — Mint Approver token (to a file path)

The mint script writes the token to a mode-600 temp file and prints the
**path** — never the token value. Capture the path; do **not** `cat` or
`echo` the token yourself (that is exactly the leak this design prevents —
see #640).

```bash
TOKEN_FILE=$(development/skills/maintenance/scripts/mint-approver-token.zsh)
if [ -z "$TOKEN_FILE" ] || [ ! -s "$TOKEN_FILE" ]; then
  echo "::error::Failed to mint Approver token."
  echo "Check: Approver App registered + installed on this repo + Keychain accessible"
  exit 1
fi
```

## Step 5 — Invoke the go-approver agent

Spawn the agent with the token **file path** in the prompt (the Agent tool
has no env-var channel, so the token must not be inlined — the agent reads
it from the path itself):

```text
Agent(
  subagent_type="go-approver",
  description="Review and post PR #<n>",
  prompt="""
    Review PR #<n> in <owner>/<repo>. Dry-run: <DRY_RUN>.

    PR_NUMBER=<n>
    REPO=<owner>/<repo>
    DRY_RUN=<DRY_RUN>

    Your GitHub token has Approver App permissions. Read it from the file
    path below and export it before any `gh` mutation — do not print it:
      export GH_TOKEN=$(cat <TOKEN_FILE path>)
    Your cwd is this session's shared worktree — do NOT run git checkout /
    git switch / gh pr checkout in it or any .claude/worktrees/ dir (#643).
    Review from `gh pr diff` / `gh api`; if you truly need the PR tree, use
    a fresh scratch worktree you remove before returning.
    When DRY_RUN=false, post the verdict to GitHub using
    `gh pr review <n> --approve|--request-changes`; when DRY_RUN=true,
    print the rendered verdict to stdout and post nothing.
  """
)
```

Substitute the actual `$TOKEN_FILE` path into `<TOKEN_FILE path>` and the
resolved `DRY_RUN` value (from Step 2) into `<DRY_RUN>`. The agent runs
the same synthesis procedure as CI and posts the verdict as
`claude-approver-bot` when `DRY_RUN=false`.

After the agent returns, remove the token file:

```bash
rm -f "$TOKEN_FILE"
```

## Step 6 — Report

When posting succeeds, confirm the review is visible:

```text
✓ Review posted to GitHub as claude-approver-bot
  https://github.com/<owner>/<repo>/pull/<n>#pullrequestreview-xyz
```

Print the agent's full output (human-readable verdict + findings + hidden
JSON block) for the user to inspect.

## Security & token handling

- **Token is minted fresh**, 1-hour lifetime (GitHub default).
- **Token is never logged or committed.** The mint script returns a
  mode-600 **file path**, not the token value, so the orchestrator never
  sees the secret and can't leak it into a prompt or transcript (#640). The
  agent reads it from the path; the file is removed after the run.
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

One Fable invocation of `go-approver` (~50–150 K tokens depending on
diff size). Same cost as CI, paid per local invocation.
