---
name: open-pr
description: >
  Open a pull request for the current branch authored by the Claude-Plugin-Writer
  identity (the Claude Maintenance GitHub App) instead of by you, so YOU can
  approve it (GitHub blocks self-approval) and it auto-merges on approval + green
  CI. Use this to finish work in a Claude-plugin repo (#260): mint the writer
  token, push as the bot, open the PR as the bot, and arm squash auto-merge with
  branch deletion. Falls back to a normal user-authored PR (which you'd
  admin-merge) when the writer App isn't installed.
disable-model-invocation: false
---

You are opening a PR **as the Claude-Plugin-Writer** — the Claude Maintenance
GitHub App, reused as the writer for a plugin repo. The point: a plugin repo is
the origin of every other repo, so a **human** approves (no AI Approver). GitHub
won't let someone approve a PR they authored, so Claude's PRs must be authored by
the bot, not by you — then you approve and it auto-merges.

**User input:** $ARGUMENTS — optional PR title; otherwise generate one from the
commits (use `/development:commit` conventions).

## Step 1 — preconditions

```bash
test -n "$(git log @{u}.. 2>/dev/null || git log --oneline -1)" || { echo "no commits to PR"; exit 1; }
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "$BRANCH" != "main" ]] || { echo "on the default branch — make a feature branch first (/development:git-branch-naming)"; exit 1; }
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
```

This skill is for repos where the **writer App is installed** — typically a
`claude-plugin`-primary repo (check `.maintenance.yml` says `primary:
claude-plugin`). It works on any repo with the Maintenance App installed.

## Step 2 — mint the writer token

The mint script writes the token to a mode-600 temp file and prints the
**path**, not the token value (#640) — so capture the path and read the
token inline (`$(cat "$TOKEN_FILE")`) only at the point of each push / `gh`
call below. Never assign the token to a variable you might `echo`, and never
`cat` it to stdout.

```bash
TOKEN_FILE=$("<skill-base-dir>/../maintenance/scripts/mint-maintenance-token.zsh" 2>/tmp/mint.err)
```

- **Success** → `$TOKEN_FILE` is the path to a mode-600 file holding a 1-hour
  installation token for `claude-maintenance-<login>[bot]`. Continue Step 3;
  remove the file at the end of Step 4.
- **Failure** (App not registered / not installed on this repo) → **fall back**:
  tell the user the writer App isn't set up here (so the PR will be authored by
  *them* and they'll need to merge it themselves — admin-merge, since they can't
  approve their own PR), point them at the install path
  (`install-claude-apps.zsh --writer-only` once it ships, or the browser App-install),
  then open the PR the normal way: `gh pr create ...` (as the user) and **stop**
  (don't arm auto-merge — there's no approver-able author). Report which path ran.

## Step 3 — push as the bot, open the PR as the bot

**Before pushing — the coverage-report precondition (#602).** If the target repo
ships the `coverage-floor` **pre-push** hook (bootstrapped Python/Java/Swift
repos do), that hook runs `diff-cover` against a coverage report. Do **not**
eagerly run the whole test suite to produce that report "just so the push
succeeds" — for a diff with **no covered-language lines** (a docs/config/workflow
change) the hook skips and no report is needed, so a test run is pure waste
(running 167 tests for a vacuous `coverage.xml` was the observed symptom of
issue 602). Ask the guard first, and only build the report when it says one is
actually required:

```bash
"<skill-base-dir>/../bootstrap/scripts/ensure-coverage-precondition.zsh" --lang <python|java|swift>
#   exit 0 → no report needed (or already on disk) — push straight away, no tests
#   exit 1 → covered-language lines ARE in the diff — generate the report
#            (pytest --cov / gradlew jacocoTestReport / swift llvm-cov), then push
```

(An older, pre-#379 target repo whose hook still has `always_run: true` is
repaired in place by `reconcile-precommit-hooks.zsh` — see the bootstrap flow —
so the guard's skip actually takes effect there too.)

The PR **author** is whoever creates it, and the **last pusher** should also be
the bot (so a "review from someone other than the last pusher" rule never blocks
*your* approval). Use the token for both:

```bash
git push "https://x-access-token:$(cat "$TOKEN_FILE")@github.com/${REPO}.git" "HEAD:${BRANCH}" --force-with-lease

GH_TOKEN="$(cat "$TOKEN_FILE")" gh pr create \
  --base main --head "$BRANCH" \
  --title "<title>" --body "<body — include 'Closes #N' when it fixes an issue>"
```

Capture the PR number/URL. The PR author is now `claude-maintenance-<login>[bot]`.

**Push rejected with `without 'workflows' permission`? Stale installation grant
(#750).** The Maintenance App is granted `workflows: write` (so a changeset
touching `.github/workflows/*` is fine on the bot path), but a permission
increase only takes effect on an installation once the user **re-accepts** it —
an installation still on the pre-#750 grant rejects any workflow-touching push
**wholesale**:

```text
! [remote rejected] HEAD -> <branch> (refusing to allow a GitHub App to create or
  update workflow `.github/workflows/api-stability.yml` without `workflows` permission)
```

When the bot push fails with exactly that error: tell the user this
installation hasn't accepted the `workflows: write` grant yet — point them at
`install-claude-apps.zsh --verify` (it prints the re-accept instructions) —
then **fall back to the user-authored path for this run**: `rm -f "$TOKEN_FILE"`,
push + `gh pr create` as the user, **stop** (no auto-merge; they admin-merge),
and report which path ran and why. Don't retry the bot push — the rejection is
deterministic until the grant is re-accepted.

**Re-pushing to an already-open PR? Re-trigger CI (#605).** The `gh pr create`
above fires `pull_request: opened`, which **does** run CI — so the normal
open-a-fresh-PR path needs nothing extra. But when this same bot **App
installation token** re-pushes to a PR that is **already open** (a resume, or a
follow-up fix push), the resulting `pull_request: synchronize` event creates
**no** workflow runs — the new head sits with zero checks and armed auto-merge
never fires. After any such re-push, re-trigger CI deterministically with the
blessed helper (a close+reopen nudge that fires `reopened`, re-arming auto-merge
that closing disarmed). You pushed as the App, so pass `--grace 0` to nudge
immediately — no point watching for checks that a bot `synchronize` never
produces:

```bash
GH_TOKEN="$(cat "$TOKEN_FILE")" "<skill-base-dir>/../maintenance/scripts/retrigger-pr-ci.zsh" --grace 0 "<pr-number>"
#   result: NUDGED → closed+reopened to re-trigger CI on the new head
```

(This assumes the repo's `on: pull_request` workflows include the `reopened`
activity type — they do when `types:` is unset, GitHub's default. A workflow
pinned to `types: [opened, synchronize]` would not re-run on the nudge.)

**Review dossier (#563).** When the caller ran the local review loop (#562) and
it exited `CONVERGED`, append the **Review dossier** to the PR body, after the
Test plan — it is the durable audit record for why auto-merge happened. Build it
from the loop's status JSON:

```bash
"<skill-base-dir>/../resolve-issue/scripts/build-dossier.zsh" --status <status.json>
```

It emits the human-readable dossier section **and** a hidden
`<!-- review-dossier: {…} -->` JSON block the Approver re-ingests into its risk
register. When no loop ran (`--no-review` / zero rounds) it prints nothing, so
the PR body is exactly as it is today — no dossier, no behavior change.

> Optional cleaner attribution: if you want the *commits* (not just the PR)
> attributed to the bot, amend/rebase with
> `git -c user.name='claude-maintenance[bot]' -c user.email='<app-id>+claude-maintenance[bot]@users.noreply.github.com'`
> before pushing. The PR author alone is enough for you to approve, so this is
> optional.

## Step 4 — arm auto-merge (squash + delete branch)

```bash
GH_TOKEN="$(cat "$TOKEN_FILE")" gh pr merge "<pr-number>" --auto --squash --delete-branch

# Done with the token — remove the mode-600 file minted in Step 2.
rm -f "$TOKEN_FILE"
```

GitHub merges by itself once **your** approving review lands and CI is green
(squash, head branch deleted — the repo settings bootstrap configured). Nothing
else to run; you don't need to babysit it.

## Step 5 — report

Tell the user: the PR URL, that it's **authored by the bot and awaiting their
approval**, and that auto-merge (squash) is armed. They review + approve; it
merges itself. No admin-merge needed.

## Guardrails

- **Never** open the PR with your own `gh` auth when the writer token minted —
  that defeats the whole point (you'd author it and couldn't approve it).
- The token is short-lived (1 h) and minted on demand — don't print it, log it,
  or store it.
- Squash + delete-branch only, matching the family's merge convention.
