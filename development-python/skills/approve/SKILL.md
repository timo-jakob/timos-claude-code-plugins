---
name: approve
description: Run the Claude Approver locally against an open PR — same agent, same `.claude/approver-policy.md`, but the verdict prints to stdout instead of being posted as a review. Useful for predicting what CI's Approver will say before pushing, or for a quick sanity check on someone else's PR. Pass a PR number explicitly (`/development-python:approve 123`) or omit it to use the PR associated with your current branch.
disable-model-invocation: false
---

You are running a **local dry-run of the Claude Approver**. The user
wants to see what verdict the `python-approver` agent would render
for a given PR, without anything being posted to GitHub.

**User input:** $ARGUMENTS

## What this skill does

1. Verify the repo has the Approver installed (`.claude/approver-policy.md`
   exists) and the user is authenticated to GitHub.
2. Resolve which PR to review — explicit argument or the PR for the
   current branch.
3. Spawn the same `python-approver` agent the CI workflow uses, with
   `DRY_RUN=true` in the prompt.
4. Display the agent's output to the user.

## Step 1 — Preflight

Check both prerequisites; halt with a clear pointer if either fails.

```bash
test -f .claude/approver-policy.md || {
  echo "::error::No .claude/approver-policy.md in this repo."
  echo "Run /development:bootstrap --claude-approver true to install the Approver."
  exit 1
}

command -v gh >/dev/null 2>&1 || {
  echo "::error::gh CLI not on PATH. Install via: brew install gh"
  exit 1
}

gh auth status >/dev/null 2>&1 || {
  echo "::error::gh CLI not authenticated. Run: gh auth login"
  exit 1
}
```

## Step 2 — Resolve the PR

Parse `$ARGUMENTS`:

- **A positive integer** (`123`, `--pr 123`, `--pr=123`) → use as
  `PR_NUMBER`.
- **Empty** → try `gh pr view --json number --jq .number` to find a
  PR for the current branch. If none, halt:

  ```text
  No PR provided and no open PR is associated with the current
  branch. Either push the branch and open a PR first, or pass an
  explicit PR number: /development-python:approve 123
  ```

Capture the repo as `owner/name`:

```bash
REPO=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
```

## Step 3 — Invoke the python-approver agent

Spawn the agent with the same prompt shape the CI workflow uses, but
with `DRY_RUN=true`. The agent reads `.claude/approver-policy.md`,
gathers PR context via `gh`, runs the same 13-step procedure as in CI,
and returns the rendered review body (markdown + hidden JSON block)
**without posting it**.

```text
Agent(
  subagent_type="python-approver",
  description="Local dry-run review of PR #<n>",
  prompt="""
    Review PR #<n> in <owner>/<repo>. Dry-run: true.

    This is a LOCAL invocation via /development-python:approve.
    Env vars GH_TOKEN, PR_NUMBER, REPO, DRY_RUN are not set; use these
    values from the prompt and rely on the user's existing `gh auth`
    for all GitHub API calls. Do NOT post a review — return the
    rendered review body as your final text.
  """
)
```

The agent's full behaviour is documented in
[`development-python/docs/python-approver.md`](../../docs/python-approver.md)
and the prompt itself lives at
[`development-python/agents/python-approver.md`](../../agents/python-approver.md).
This skill changes nothing about what the agent does — only how it's
invoked and what it does with its output.

## Step 4 — Display

Print the agent's return value to the user verbatim. Include both
halves: the human-readable verdict + findings + risks, AND the hidden
`<!-- claude-approver:findings -->` JSON block (helpful if the user
wants to see what `/development:maintenance`'s re-ingest would
receive).

Add a brief banner at the top so it's obvious this was a dry-run:

```text
=================================================================
LOCAL DRY-RUN — no review was posted to GitHub.
PR: <owner>/<repo>#<n>
=================================================================
```

## What this skill does NOT do

- **Does not post a review.** The agent's step 13 sees `DRY_RUN=true`
  and skips the `gh pr review` call.
- **Does not modify the PR.** No pushes, no comments, no labels.
- **Does not consume App tokens.** Uses the user's `gh auth` —
  `GH_TOKEN` is not set and not needed.
- **Does not download CI artifacts beyond the agent's own logic.** The
  agent's step 4 (fetch `griffe-findings.json` from the api-stability
  workflow's artifact) runs as it would in CI. If the artifact isn't
  available for the current head SHA, the agent records an
  informational finding and proceeds — the verdict is rendered without
  Griffe data.

## Cost

One opus invocation of `python-approver`, ~50–150 K tokens depending
on diff size and how many test bodies the agent reads. Same cost
profile as the CI Approver, paid per local-dry-run invocation.

## When to use this

- **Before pushing**, to predict CI's verdict and fix any findings
  while the iteration loop is local + fast.
- **On someone else's PR**, for a quick sanity check before reviewing
  manually.
- **When the policy file changes**, to test the new criteria against
  open PRs before merging the policy update (a policy-change PR is
  evaluated by the previous policy in CI; the new policy applies
  going forward — `/development-python:approve` lets you preview).
