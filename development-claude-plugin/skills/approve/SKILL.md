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
PR_NUMBER=<the PR number resolved above>; [ -n "$PR_NUMBER" ] || exit 1
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
[ -n "$REPO" ] || { echo "::error::Could not resolve the repository — posting nothing."; exit 1; }
printf 'PR_NUMBER=%s\nREPO=%s\n' "$PR_NUMBER" "$REPO"
AUTHOR=$(gh pr view "$PR_NUMBER" --json author -q .author.login) && [ -n "$AUTHOR" ] ||
  { echo "::error::Could not read PR #$PR_NUMBER's author — posting nothing." >&2; exit 1; }
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
PR_NUMBER=<the PR_NUMBER Step 1 printed>; [ -n "$PR_NUMBER" ] || exit 1
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

The bar's result holds only for the head and body it judged, so the block
records both: `HEAD_SHA`, read first, before the body and paths, and
`BODY_SHA256`, the SHA-256 of the exact body file the bar reads. The agent
re-checks both against the live PR just before it posts (its Step 12). The
block prints them with `SCRATCH` and `BAR_RC`; later steps take these values
verbatim from that output, never from a fresh `gh` read.

```bash
PR_NUMBER=<the PR_NUMBER Step 1 printed>; REPO=<the REPO Step 1 printed>
[ -n "$PR_NUMBER" ] && [ -n "$REPO" ] || exit 1
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/plugin-approver.XXXXXX")
{ HEAD_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid -q .headRefOid) && [ -n "$HEAD_SHA" ] &&
  sed 's/{{APPROVER_LANG}}/claude-plugin/g' \
    development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl > "$SCRATCH/policy.md" &&
  cat "<skill-base-dir>/approver-policy-overlay.md.tmpl" >> "$SCRATCH/policy.md" &&
  gh pr view "$PR_NUMBER" --json body -q .body > "$SCRATCH/body" &&
  BODY_SHA256=$(shasum -a 256 < "$SCRATCH/body" | cut -d' ' -f1) && [ -n "$BODY_SHA256" ] &&
  gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" \
    --jq '.[] | .filename, (.previous_filename // empty)' > "$SCRATCH/paths"
} || { echo "::error::Policy render or PR fetch failed — posting nothing."; rm -rf "$SCRATCH"; exit 1; }
BAR_RC=0
"<skill-base-dir>/scripts/never-approve-bar.zsh" --body "$SCRATCH/body" --paths "$SCRATCH/paths" \
  > "$SCRATCH/bar" || BAR_RC=$?
printf 'SCRATCH=%s\nHEAD_SHA=%s\nBODY_SHA256=%s\nBAR_RC=%s\n' "$SCRATCH" "$HEAD_SHA" "$BODY_SHA256" "$BAR_RC"
```

- `BAR_RC` 0 → clear (`$SCRATCH/bar` is empty); 3 → hit (one `hit=` line per
  hit). Either way, continue: the agent applies the result.
- Any other exit: stop. Post nothing, mint nothing, remove `$SCRATCH`, and relay
  the bar's stderr. Exit 1 is a dossier block that is not valid JSON, or an
  empty paths list — the bar fails closed rather than call it clear; exit 2 is
  a malformed invocation.

A failed `sed`, `gh pr view` or `gh api` above is the same stop, and the block
exits 1 on it: a bar run over an empty or partial paths file would read as clear.
So is an empty `HEAD_SHA` or `BODY_SHA256`: a review with nothing to pin it to
is never posted.

## Step 4 — Mint the Approver token, just in time

The mint script writes the token to a mode-600 file and prints the **path** —
never the value (#640). Capture the path; never `cat` or `echo` the token.

```bash
SCRATCH=<the SCRATCH path Step 3 printed>
[ -n "$SCRATCH" ] || exit 1
TOKEN_FILE=$(development/skills/maintenance/scripts/mint-approver-token.zsh)
[ -s "$TOKEN_FILE" ] || { echo "::error::Failed to mint Approver token."; rm -rf "$SCRATCH"; exit 1; }
echo "TOKEN_FILE=$TOKEN_FILE"
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
    HEAD_SHA=<$HEAD_SHA>
    BODY_SHA256=<$BODY_SHA256>
    Read your token from the path below and export it before any `gh` mutation — do not print it:
      export GH_TOKEN=$(cat <TOKEN_FILE path>)
    Your cwd is this session's shared worktree — do NOT run git checkout / git switch /
    gh pr checkout in it or any .claude/worktrees/ dir (#643); use a fresh scratch
    worktree you remove before returning.
    Post the verdict through `gh api repos/<owner>/<repo>/pulls/<n>/reviews` with
    commit_id=<HEAD_SHA>, and only after your Step 12 has re-checked the live head
    and body against HEAD_SHA and BODY_SHA256.
  """
)
```

Substitute the values Steps 1, 3 and 4 printed. Afterwards — whether the agent succeeded or not:

```bash
TOKEN_FILE=<the TOKEN_FILE path Step 4 printed>; SCRATCH=<the SCRATCH path Step 3 printed>
[ -n "$TOKEN_FILE" ] && [ -n "$SCRATCH" ] || exit 1
rm -rf "$TOKEN_FILE" "$SCRATCH"
```

## Step 6 — Report

Print the posted verdict, the review URL and the agent's full output
(human-readable verdict, findings and the hidden JSON block). When the bar hit,
say "Needs a human" and list every `hit=` line. If the agent posted nothing (a
head or body change, a failed re-read, unsettled CI or a conflicting PR), say
that no review was posted, give the reason, and say to re-run
`/development-claude-plugin:approve` — never report its derived verdict as posted.

## Security & token handling

- **Opt-in per session, never recorded.** `CLAUDE_PLUGIN_APPROVER=1` lives only
  in the environment; unset it and the repo is human-only again. The repo's
  recorded `approval: human` is unchanged.
- **Token is minted fresh**, 1-hour lifetime, as a mode-600 **file path**, and
  removed after the run.
- **Review is posted as `claude-approver-<owner>[bot]`**, a read-only identity
  distinct from the Maintenance App that authored the PR.
- **The never-approve bar is a script, not a judgment**: residue, workflow
  changes and approval/identity machinery always reach a human. Its result
  holds only for the head SHA and body it judged: a push or a body edit before
  the post means no review is posted, and the review that is posted is pinned
  to that head with `commit_id`.
