---
name: approve
description: >
  Review a claude-plugin PR and post the verdict as the Claude Approver —
  ONLY when CLAUDE_PLUGIN_APPROVER=1 opts this session in (a plugin repo is
  otherwise human-only). Without a registered + installed Approver App it is a
  clean no-op: a human approves. Changes to workflows, to the approval
  machinery, or with review residue always go to a human. Pass a PR number or
  use the current branch's PR.
disable-model-invocation: false
---

You are running the **Claude Approver for a claude-plugin repo** and posting
its verdict as `claude-approver-<owner>[bot]`. A claude-plugin repo is
human-only by default; this skill only acts when the operator opted this
session in, and even then a hard bar keeps the riskiest changes with a human.

**User input:** `$ARGUMENTS` (PR number, optional; defaults to the current branch's PR)

Run every step from the repository root. The scripts named by a repo-relative
path (`development/…`) are this repository's own; `<skill-base-dir>` is this
skill's directory.

## Step 0 — Is AI approval on for this session?

```bash
OVR=$(development/scripts/approval/plugin-approver-override.zsh) || true
if ! grep -qx 'override=on' <<<"$OVR"; then
  REASON=$(sed -n 's/^reason=//p' <<<"$OVR")
  REASON=${REASON:-override-helper-unavailable}
  echo "AI approval: off (${REASON}) — a human approves."
  exit 0
fi
```

That line is informational, not an error: report it and stop, exit 0.
`env-unset`, `approver-not-registered` and `approver-not-installed` are the
ordinary off states — the last two are the supported way to forbid AI
approvals. If the helper printed a diagnostic on stderr (a broken setup such
as `approver-key-missing`), relay it once; the human path still applies.
Anything but an exact `override=on` line — including a helper that could not
run — is off.

## Step 1 — Resolve the PR and check its author

`$ARGUMENTS` a positive integer → that PR. Empty → `gh pr view --json number -q
.number`; with none, stop with a clear message. Anything else is a usage error:
print `usage: /development-claude-plugin:approve [<pr-number>]` and stop.

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
[ -n "$REPO" ] || { echo "::error::Could not resolve the repository — posting nothing."; exit 1; }
AUTHOR=$(gh pr view "$PR_NUMBER" --json author -q .author.login)
grep -qE '^(app/)?claude-maintenance' <<<"$AUTHOR" || {
  echo "AI approval: off (PR authored by ${AUTHOR}, not the Maintenance App) — a human approves."
  exit 0
}
```

The Approver reviews only Maintenance-App PRs. A human's PR is reviewed by a
human — the same informational stop as Step 0, never an error.

## Step 2 — Mergeability gate

A conflicting PR is never reviewed: auto-merge can't fire on it, and resolving
the conflict pushes a new head that invalidates any verdict.

```bash
MERGEABLE=$(gh pr view "$PR_NUMBER" --json mergeable -q .mergeable)
```

- `MERGEABLE` → continue.
- `UNKNOWN` → GitHub is still computing it; re-check after a few seconds (a
  handful of retries) before deciding. Still `UNKNOWN` → stop and report.
- `CONFLICTING` → run `/development:sync-prs` with no argument: it re-syncs
  every conflicting Maintenance-App PR, this one included. Then re-check
  `mergeable` with the same handful of retries: `MERGEABLE` → re-enter this
  skill from Step 1 (the agent's Step 8 waits for CI). Anything else, or a
  `needs-manual-rebase` label, stays with a human: stop and report. The
  Approver never resolves conflicts — its App has read-only code access by
  design.

## Step 3 — Policy and never-approve bar

Render the policy — the core with its only placeholder, `{{APPROVER_LANG}}`,
set to `claude-plugin`, followed by this skill's overlay — and run the bar over
the PR body and every changed path. A renamed file contributes its old path as
well as its new one, so moving a file out of the approval machinery still hits.

```bash
SCRATCH=$(mktemp -d -t plugin-approver.XXXXXX)
{ sed 's/{{APPROVER_LANG}}/claude-plugin/g' \
    development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl > "$SCRATCH/policy.md" &&
  cat "<skill-base-dir>/approver-policy-overlay.md.tmpl" >> "$SCRATCH/policy.md" &&
  gh pr view "$PR_NUMBER" --json body -q .body > "$SCRATCH/body" &&
  gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" \
    --jq '.[] | .filename, (.previous_filename // empty)' > "$SCRATCH/paths"
} || { echo "::error::Policy render or PR fetch failed — posting nothing."; rm -rf "$SCRATCH"; exit 1; }
BAR_RC=0
"<skill-base-dir>/scripts/never-approve-bar.zsh" --body "$SCRATCH/body" --paths "$SCRATCH/paths" \
  > "$SCRATCH/bar" || BAR_RC=$?
```

- `BAR_RC` 0 → clear (`$SCRATCH/bar` is empty); 3 → hit (one `hit=` line per
  hit). Either way, continue: the agent applies the result.
- Any other exit: stop. Post nothing, mint nothing, remove `$SCRATCH`, and relay
  the bar's stderr. Exit 1 is a dossier block that is not valid JSON, or an
  empty paths list — the bar fails closed rather than call it clear; exit 2 is
  a malformed invocation.

A failed `sed`, `gh pr view` or `gh api` above is the same stop, and the block
exits 1 on it: a bar run over an empty or partial paths file would read as clear.

## Step 4 — Mint the Approver token, just in time

The mint script writes the token to a mode-600 file and prints the **path** —
never the value (#640). Capture the path; never `cat` or `echo` the token.

```bash
TOKEN_FILE=$(development/skills/maintenance/scripts/mint-approver-token.zsh)
[ -s "$TOKEN_FILE" ] || { echo "::error::Failed to mint Approver token."; rm -rf "$SCRATCH"; exit 1; }
```

## Step 5 — Spawn the agent, then clean up

Spawn the agent with the token **file path** in the prompt (the Agent tool has
no env-var channel, and the token value is never inlined):

```text
Agent(
  subagent_type="development-claude-plugin:claude-plugin-approver",
  description="Review and post PR #<n>",
  prompt="""
    Review PR #<n> in <owner>/<repo>. Dry-run: false.
    PR_NUMBER=<n>
    REPO=<owner>/<repo>
    DRY_RUN=false
    POLICY_FILE=<$SCRATCH/policy.md>
    BAR_FILE=<$SCRATCH/bar>
    Read your token from the path below and export it before any `gh` mutation — do not print it:
      export GH_TOKEN=$(cat <TOKEN_FILE path>)
    Your cwd is this session's shared worktree — do NOT run git checkout / git switch /
    gh pr checkout in it or any .claude/worktrees/ dir (#643); use a fresh scratch
    worktree you remove before returning.
    Post the verdict with `gh pr review <n> --approve|--request-changes|--comment`.
  """
)
```

Substitute the actual paths. Afterwards — whether the agent succeeded or not:

```bash
rm -rf "$TOKEN_FILE" "$SCRATCH"
```

## Step 6 — Report

Print the posted verdict, the review URL and the agent's full output
(human-readable verdict, findings and the hidden JSON block). When the bar hit,
say "Needs a human" and list every `hit=` line.

## Security & token handling

- **Opt-in per session, never recorded.** `CLAUDE_PLUGIN_APPROVER=1` lives only
  in the environment; unset it and the repo is human-only again. The repo's
  recorded `approval: human` is unchanged.
- **Token is minted fresh**, 1-hour lifetime, as a mode-600 **file path**, and
  removed after the run.
- **Review is posted as `claude-approver-<owner>[bot]`**, a read-only identity
  distinct from the Maintenance App that authored the PR.
- **The never-approve bar is a script, not a judgment**: residue, workflow
  changes and approval/identity machinery always reach a human.
