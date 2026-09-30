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

## Step 1b — rebase onto main if main is ahead

A branch cut from an older `main` opens a PR that may already conflict, or that
CI validates against a stale base. Before pushing, run the rebase engine from
inside the repository. It fetches `origin main` and, when main has commits the
branch lacks, rebases onto `origin/main` with the repo type's merge driver wired
in for that one rebase, so a mechanical manifest conflict is resolved by rule
(#1822):

```bash
# The lease, taken BEFORE the rebase: the remote branch as this branch last saw
# it. Empty → the branch must not exist yet. A remote tip this branch does not
# contain means commits landed there that a push would overwrite: stop.
LEASE=$(git ls-remote origin "refs/heads/${BRANCH}" | cut -f1)
[[ -z "$LEASE" ]] || git merge-base --is-ancestor "$LEASE" HEAD \
  || { echo "origin/${BRANCH} has commits this branch lacks — stop, open no PR"; exit 1; }
VERDICT=$("<skill-base-dir>/../../scripts/merge/rebase-onto-main.zsh")
#   exit 0 → clean or resolved     exit 1 → conflict (the rebase was aborted)
#   exit 2 → your own bad call (it takes no arguments)
#   exit 3 → runtime failure (fetch, detect, a dirty tree): stop, report stderr
#            (a stderr naming "rebased onto <sha>" means the rebase DID happen)
```

Stdout is one JSON object; branch on its `verdict`:

- **`clean`** → continue with Step 2. With no `base`, main was not ahead and
  nothing ran. With a `base`, the branch was rebased onto that `origin/main` sha
  and nothing needed resolving.
- **`resolved`** → the rebase succeeded, and the merge driver resolved the
  fields listed in `resolved`, one record per field:
  `{path, plugin, field, main, pr, result}`. Continue with Step 2, and list each
  resolved field (path, plugin, field, main → PR → result) in the **PR body**
  and in the final report.
- **`conflict`** → the engine has run `git rebase --abort`, so the branch is
  exactly as it was. **Stop — open no PR** and report the conflicting paths in
  `files`. A conflict the driver did not resolve needs a human's or the caller's
  judgment; never resolve it by picking a side automatically.

**A rebase can leave nothing to PR.** On `clean` with a `base`, and on
`resolved`, re-check Step 1's precondition against the new base: when
`git rev-list --count "<base>..HEAD"` is `0`, every commit was already on main
(squash-merged or cherry-picked work) — **stop, push nothing, open no PR**, and
report that.

**The final report carries the rebase, on every path this skill ends on** —
Step 5, and the user-authored fallbacks in Steps 2 and 3 alike: that the branch
was rebased and onto which sha, each resolved field, and, if the caller
validated the branch (a test gate, a review loop) before this step, that the
result was against the old base and CI on the PR is now the check against the
new one. Only textual conflicts are resolved; a textually clean rebase that
breaks something semantically is CI's to catch. A repo whose type cannot be
determined, or whose type has no `merge-driver-<repo_type>.zsh` beside the
engine, gets a plain rebase, where any conflict stops.

**Every push after this step replaces the remote branch under the `LEASE`
recorded above** — the bot push in Step 3 and both user-authored fallbacks — so
it succeeds only while the remote still holds what this branch was rebased from.
A rebased branch that was pushed before is no fast-forward of it, so a plain
`git push` is rejected; never `git pull` to get past that (it merges the
pre-rebase commits back in), never push with a bare `--force`, and never re-read
the lease at push time (it would always match, which is a bare `--force`). Name
the lease explicitly: a bare `--force-with-lease` checks a remote-tracking ref,
which a push to a URL never has, so it is refused as `stale info` whenever the
branch already exists.

```bash
# <remote>: Step 3's token URL for the bot, `origin` on a user-authored fallback
git push "<remote>" "HEAD:${BRANCH}" --force-with-lease="${BRANCH}:${LEASE}"
```

## Step 2 — mint the writer token

The mint script writes the token to a mode-600 temp file and prints the
**path**, not the token value (#640) — so capture the path and read the
token inline (`$(cat "$TOKEN_FILE")`) only at the point of each push / `gh`
call below. Never assign the token to a variable you might `echo`, and never
`cat` it to stdout.

```bash
TOKEN_FILE=$("<skill-base-dir>/../maintenance/scripts/mint-maintenance-token.zsh" 2>/tmp/mint.err)
```

The script mints the writer App of **this repository's owner** (#1683): inside
an organisation repo, the organisation's App; inside a personal repo, your
personal one — on the same machine, with no flag.

- **Success** → `$TOKEN_FILE` is the path to a mode-600 file holding a 1-hour
  installation token for `claude-maintenance-<owner>[bot]`. Continue Step 3;
  remove the file at the end of Step 4.
- **Failure** → first ask the shared probe why, because two kinds of failure
  need opposite handling:

  ```bash
  "<skill-base-dir>/../bootstrap/scripts/claude-apps-owner.zsh" status claude-maintenance
  ```

  - **A fixable registry state — do NOT open a PR.** `maintenance: key missing`
    (run the `fix:` line), exit 1 (`apps.json` still schema 1 — run
    `register-claude-apps.zsh --list` — or the Keychain is locked: unlock it)
    or exit 4 (no GitHub owner resolvable). Relay the probe's and
    `/tmp/mint.err`'s message and **stop**: the fix is one command, after which
    re-running this skill opens the bot PR, whereas a user-authored PR would
    need an admin merge for nothing.
  - **A GitHub-side failure — do NOT open a PR either.** Exit 0 (the writer
    is registered and its key readable) and the mint said anything other than
    `App is not installed on <repo>` — `Could not reach GitHub …` (a network
    outage), `GitHub rejected the … installation lookup` (a key GitHub no
    longer accepts) or `Failed to mint installation token`. The mint prints
    `App is not installed` **only** for GitHub's own 404, so the two never
    overlap. Relay `/tmp/mint.err` and stop; re-run this skill once GitHub
    is reachable, or run `install-claude-apps.zsh --verify --fix` for a
    rejected key.
  - **The writer is genuinely absent here** — `maintenance: not registered`
    (exit 3), or exit 0 **and** `/tmp/mint.err` says `App is not installed on
    <repo>` → this is the **"writer App not installed"** branch —
    **fall back**: tell the user the writer App isn't set up here (so the PR
    will be authored by *them* and they'll need to merge it themselves —
    admin-merge, since they can't approve their own PR), and relay
    `/tmp/mint.err` verbatim: for an unregistered owner it names the exact
    register command
    (`register-claude-apps.zsh [--org <slug>] --apps claude-maintenance`) —
    or, for a personal repo owned by another account,
    that only that account can register its Apps — and for a
    registered-but-not-installed App the install path is
    `install-claude-apps.zsh --writer-only`. Then open the PR the normal way:
    push to `origin` under Step 1b's lease, `gh pr create ...` (as the user)
    and **stop** (don't arm auto-merge — there's no approver-able author).
    Report which path ran, plus Step 1b's rebase note. **Never** mint
    another owner's App instead: a personal App cannot author PRs on an
    organisation's repo, and the script refuses to fall through by design.

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
git push "https://x-access-token:$(cat "$TOKEN_FILE")@github.com/${REPO}.git" "HEAD:${BRANCH}" \
  --force-with-lease="${BRANCH}:${LEASE}"

GH_TOKEN="$(cat "$TOKEN_FILE")" gh pr create \
  --base main --head "$BRANCH" \
  --title "<title>" --body "<body — include 'Closes #N' when it fixes an issue>"
```

Capture the PR number/URL. The PR author is now `claude-maintenance-<owner>[bot]`.

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
push to `origin` under Step 1b's lease + `gh pr create` as the user, **stop**
(no auto-merge; they admin-merge), and report which path ran and why, plus Step
1b's rebase note. Don't retry the bot push — the rejection is
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
it reached a **PR-opening terminal** — `CONVERGED` (exit 0) **or**
`CONVERGED_WITH_RESIDUE` (exit 14, #1435); those two, and no escalation — append
the **Review dossier** to the PR body, after the
Test plan — it is the durable audit record for why auto-merge happened. A residue
PR is exactly the one that must not lose it: its dossier carries the terminal and
the per-dimension `open` counts, which is how the Approver learns those blockers
were deliberately left open and filed as follow-ups rather than missed. Build it
from the loop's status JSON, appending **exactly ONE** dossier — so decide the
flags *before* you run anything: pass the promotion pair when the caller kept a
promotion-phase status JSON (the condition is spelled out below), and the plain
`--status` form otherwise.

The once-only rule is about **appended output**, not processes: never append two
dossier outputs (two hidden blocks) to one body. So if you ran the wrong form and
its output has **not** been appended anywhere, discard it and run the single
correct invocation; if it **has** been appended, stop and report to the caller
rather than appending or hand-editing a second block.

Plain form — **no kept promotion-phase status JSON**. Note a discard does *not*
put you here: resolve-issue step 7 mandates a re-invoke after a discarded
phantom, and it is the re-invoked sub-loop's **kept** status, never the discarded
file, that the condition tests — so a discard-then-re-invoke run takes the pair
form. The plain form applies only when the run ended with no kept promotion
status at all (the no-op case is described just below):

```bash
"<skill-base-dir>/../resolve-issue/scripts/build-dossier.zsh" --status <status.json>
```

It emits the human-readable dossier section **and** a hidden
`<!-- review-dossier: {…} -->` JSON block the Approver re-ingests into its risk
register. When no loop ran — a `SKIPPED` / `--no-review` status, or a status
with zero rounds — it prints nothing, so the PR body is exactly as it is
today — no dossier, no behavior change.

When the caller kept a **promotion-phase status JSON** — one this run wrote and
did **not** discard (a sub-loop can be invoked and its round-1 status discarded
as a phantom, and a reused scratch dir can hold an earlier story's leftover),
including a run where it raised nothing — that
same single invocation merges both phases into the one section and one block
(#1064); the Approver parses exactly one, so never **append** its output twice:

```bash
"<skill-base-dir>/../resolve-issue/scripts/build-dossier.zsh" --status <status.json> \
  --promotion-status <promotion-status.json> --promoted <promoted.json>
```

The two promotion flags are an **atomic pair** — one without the other is a
usage error (exit 2), never a silent fall back to a blocking-phase-only dossier.
The condition is the *artifact*, not the phrase "the phase ran": resolve-issue's
promotion step 8 owns it, and its *If NONE matched* terminal never invokes the
sub-loop (plain `--status`) while its not-reproducible terminal does (pass the
pair, and the dossier honestly reports `promoted: 0`).

**Check the exit status before appending.** build-dossier prints nothing on
stdout when it fails (2 = usage / broken pair, 1 = bad input), which is
indistinguishable from the legitimate no-loop no-op — so an unchecked append
opens a dossier-less PR and reads the silence as sanctioned. On non-zero, fix
the input stderr names and re-run rather than opening the PR; and when the loop
is known to have run a round — on **either** PR-opening terminal, `CONVERGED` or
`CONVERGED_WITH_RESIDUE` — treat empty output at exit 0 as the same error. The
second is named explicitly because this section now distinguishes the two by
name, and "converged" read as exit 0 alone would let a residue PR ship
dossier-less on the very silence this rule exists to catch. If
the input cannot be restored, **stop and report to the caller instead of opening
the PR** — never reconstruct the status JSON by hand to satisfy the command.

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
merges itself. No admin-merge needed. Include Step 1b's rebase note — the new
base sha, each `resolved` field and the old-base caveat — when Step 1b rebased.

## Guardrails

- **Never** open the PR with your own `gh` auth when the writer token minted —
  that defeats the whole point (you'd author it and couldn't approve it).
- The token is short-lived (1 h) and minted on demand — don't print it, log it,
  or store it.
- Squash + delete-branch only, matching the family's merge convention.
