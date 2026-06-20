# Claude Approver — Adoption Guide

This is the operator-facing guide to running the Claude Approver on your
own repos. It assumes you've read the design summary in
[`../../../README.md`](../../../README.md) — that section explains *why*
the Approver exists; this one explains *how to use it*.

If you just want quick links to the underlying specs, skip to
[Reference docs](#reference-docs) at the end.

---

## Table of contents

1. [What the Approver actually does](#what-the-approver-actually-does)
2. [How it decides](#how-it-decides)
3. [One-time setup (per machine)](#one-time-setup-per-machine)
4. [Per-repo setup](#per-repo-setup)
5. [The daily flow](#the-daily-flow)
6. [The PR description schema](#the-pr-description-schema)
7. [PR types — quick reference](#pr-types--quick-reference)
8. [The policy file](#the-policy-file)
9. [Local dry-run with `/development-python:approve`](#local-dry-run-with-development-pythonapprove)
10. [REQUEST_CHANGES → maintenance loop](#request_changes--maintenance-loop)
11. [The author allowlist](#the-author-allowlist)
12. [Hotfix override](#hotfix-override)
13. [Multi-language status](#multi-language-status)
14. [Customisation](#customisation)
15. [Cost and rate limits](#cost-and-rate-limits)
16. [Troubleshooting](#troubleshooting)
17. [Worked examples](#worked-examples)
18. [Reference docs](#reference-docs)

---

## What the Approver actually does

After every other CI gate has gone green on a PR — tests, linters,
SonarCloud / Snyk / CodeQL, the coverage floor, the API-stability check
— the Claude Approver workflow fires and asks two questions a checker
can't:

- **Risk:** given everything is green, what could still go wrong?
- **Confidence:** how sure am I that this PR does what it claims, with
  the quality the project expects?

It then posts one of three verdicts to the PR:

- `APPROVE` — confidence is HIGH and the risk register has no
  load-bearing entries. The Approver's review satisfies branch
  protection's one-approval requirement, so the PR becomes mergeable
  without a human review (assuming you've left the Approver in the
  approval set).
- `REQUEST_CHANGES` — at least one criterion failed OR confidence is
  below HIGH. The review body includes a human-readable summary AND a
  hidden JSON block that `/development:maintenance` parses on the next
  run to re-dispatch the right triage agents.
- `COMMENT` with reservations — the Approver would approve "if X is
  verified by a human." Defers to a human for the binary call without
  blocking the PR.

The Approver is **not another CI check.** It runs after every other
gate. It is the synthesis layer.

## How it decides

For every triggered PR the Approver runs a 13-step procedure (full
detail in [`../../../development-python/docs/python-approver.md`](../../../development-python/docs/python-approver.md)).
The short version:

1. **Read the policy** (`.claude/approver-policy.md`). Refuse to run if
   absent.
2. **Detect PR type** from the conventional-commit prefix (`feat:`,
   `fix:`, `refactor:`, etc.). Title is primary; diff heuristic is
   fallback; author hint is tiebreaker.
3. **Read the API-stability artifact** (from the [griffe-based gate](../../../development-python/docs/api-stability.md))
   when present.
4. **Run cheap local checks** — `ruff` on changed files, `pytest
   --collect-only`, LSP cross-reference lookups when a public symbol
   is touched.
5. **For `feat:` PRs**, fetch the linked issue and judge whether the
   implementation matches the story.
6. **Detect test-quality patterns** — `assert True`-style filler,
   assertions only on mock return values, tests that mock the unit
   under test, name-promises-behaviour-the-assertions-don't-verify.
7. **Apply per-type criteria** from the policy.
8. **Apply baseline criteria** that every type must pass — CI green,
   no new tool findings, PR description has the right sections, no
   conflict markers, no bare TODOs, no new secrets.
9. **Build a risk register** — the top three things that could still
   go wrong even with everything green.
10. **Calibrate confidence.** Start `HIGH`. Each unmet criterion drops
    a level. Each risk-factor match drops half a level. PRs with > 30
    changed files or > 1000 net added lines cap at `MEDIUM`. Ambiguous
    type caps at `LOW`. `claude-maintenance[bot]` PRs with green CI
    and zero new findings start at `HIGH` and can `APPROVE` directly.
11. **Render the verdict.** `HIGH` + clean baseline → `APPROVE`. `LOW`
    → `REQUEST_CHANGES`. `MEDIUM` → `COMMENT`-with-reservations.

The full per-type criteria, calibration rules, and finding schema are
in the bootstrap-generated `.claude/approver-policy.md` of any
Approver-enabled repo, and the template the bootstrap renders from is
[`../templates/languages/python/approver-policy.md.tmpl`](../templates/languages/python/approver-policy.md.tmpl).

## One-time setup (per machine)

The Approver runs as two distinct GitHub Apps:

- **Claude Approver** — posts the reviews.
- **Claude Maintenance** — opens the PRs that `/development:maintenance`
  auto-generates. Distinct identity so the Approver's anti-rubber-stamp
  gate (PR author ≠ Approver's bot) fires correctly even on
  maintenance-authored PRs.

Both Apps are registered **once per machine** under your GitHub
account; subsequent repo bootstraps just install the already-registered
Apps onto the new repo.

To register them, run:

```sh
~/.claude/plugins/cache/timos-claude-code-plugins/development/<version>/skills/bootstrap/scripts/register-claude-apps.zsh
```

The script:

1. Opens your browser to GitHub's App-manifest flow, twice (once per
   App).
2. You click **Create GitHub App** on each.
3. The script catches the redirect callback on `127.0.0.1:18923`,
   exchanges the temporary code for App credentials, and stashes the
   App IDs in `~/.config/claude-plugins/apps.json` (mode `0600`) and
   the private keys in macOS Keychain (service
   `claude-plugins.claude-approver` and `claude-plugins.claude-maintenance`,
   account `private-key`).

The full design — permissions, fallback flow, key rotation — is in
[`CLAUDE-APPS.md`](./CLAUDE-APPS.md). Re-running the script is a no-op
if both Apps are already registered.

**Pre-requisites:**

- macOS (the registration scripts use Keychain).
- `gh` CLI authenticated against the GitHub account you want to own
  the Apps.
- `python3` on `PATH` (the script uses Python's `http.server` to catch
  the redirect).

**Recovery from a failed registration** — if the browser flow completes
but the script fails to persist the credentials (a real bug we hit in
Phase 6 validation, since fixed in #201), you'll have an orphan App on
GitHub with no local record. Recover by:

1. Visiting `https://github.com/settings/apps/<app-slug>`.
2. Generating a private key (downloads a `.pem`).
3. Importing it manually:

   ```sh
   register-claude-apps.zsh --import claude-approver \
     --app-id <ID> --pem <path-to-pem>
   ```

## Per-repo setup

In each repo where you want the Approver:

```sh
cd /path/to/repo
/development:bootstrap --review --signed-commits --claude-approver true
```

The `--claude-approver true` flag tells bootstrap to:

1. Render `.github/workflows/claude-approver.yml` (the workflow that
   actually runs the Approver agent).
2. Render `.claude/approver-policy.md` (the per-PR-type criteria the
   agent reads).
3. Merge `## Type` and `## Risk` sections into
   `.github/PULL_REQUEST_TEMPLATE.md` if those sections aren't already
   present.
4. Install the **Claude Approver** and **Claude Maintenance** GitHub
   Apps onto this specific repo (opens the install URLs in your
   browser — you select "Only select repositories" and pick the
   current repo).
5. Store per-repo secrets and variables via `gh`:
   - **Secrets** (in both Actions and Dependabot scopes):
     - `ANTHROPIC_API_KEY` — captured during install (or read from env).
     - `CLAUDE_APPROVER_PRIVATE_KEY` — the Approver App's PEM.
     - `CLAUDE_MAINTENANCE_PRIVATE_KEY` — the Maintenance App's PEM.
   - **Variables**:
     - `CLAUDE_APPROVER_APP_ID`
     - `CLAUDE_MAINTENANCE_APP_ID`
     - `CLAUDE_APPROVER_AUTHOR_ALLOWLIST` — defaults to the
       machine-only list `["dependabot[bot]", "github-actions[bot]",
       "claude-maintenance[bot]"]`. Add your own login here to have
       the Approver evaluate your PRs (see [the allowlist
       section](#the-author-allowlist)).

If a Python project is detected (any `pyproject.toml` with a
`[project]` table), bootstrap **also** renders the API-stability gate
(`.github/workflows/api-stability.yml` + `.github/scripts/check-api-stability.py`)
which produces the `griffe-findings.json` artifact the Approver reads.
See [`../../../development-python/docs/api-stability.md`](../../../development-python/docs/api-stability.md).

Re-running bootstrap is idempotent — existing files go through the
`bootstrap-idempotency-reviewer` agent, which classifies each as
*skip* / *merge* / *overwrite* per its own contract.

## The daily flow

Once the Approver is set up, the typical PR lifecycle is:

1. **You (or a bot) open a PR.** The Approver workflow fires on
   `pull_request: opened` and every required check fires too.
2. **The `approver-gate` job short-circuits early** for PRs the
   Approver shouldn't evaluate (each skip ends the gate job *green*
   with a `::notice::` explaining why — GitHub records non-zero exits
   as failures, so skips must not exit non-zero; see #232):
   - Comment trigger (`/approve`) with the comment author not in
     `OWNER/MEMBER/COLLABORATOR` → skipped at the job-level `if:`.
   - PR author matches `claude-approver*[bot]` → anti-rubber-stamp
     gate skips.
   - PR author not on `CLAUDE_APPROVER_AUTHOR_ALLOWLIST` → skips.
   - PR is draft, not OPEN, or has a moving head SHA → skips.
3. **The all-green check gate waits in-job** — polling the head SHA's
   check runs every 30s (30-minute deadline) until every other check
   has completed, then requires `success | skipped | neutral` on all
   of them. This is what makes the Approver effectively run **last**:
   GitHub Actions has no cross-workflow ordering, so the gate
   sequences itself (#232). If a check is red, the gate skips out
   green (no point asking Claude when CI already said no — the
   failing check tells the story). A new push cancels the waiting
   run via the concurrency group and starts a fresh one.
   **Advisory legacy commit statuses are excluded** from the green
   computation (#387): Snyk's `code/snyk` and `security/snyk` post via
   the legacy commit-status API but are never required branch-protection
   contexts, and on the free tier they can go ERROR for quota reasons
   ("Code test limit reached") unrelated to the PR. The gate evaluates
   the non-advisory statuses individually rather than trusting the
   aggregate state, so an advisory quota failure can't silently skip the
   Approver. Required legacy statuses (e.g. `sonarcloud`) still gate.
4. **When everything's green**, the gate emits `proceed=true` and the
   `approve` job (chained via `needs:`) mints a 1-hour Approver App
   installation token, checks out the PR HEAD, pulls in the plugin
   family at the pinned SHA, installs Claude Code CLI, and invokes
   `python-approver` (opus model). When the gate declines, the
   `approve` job shows as *skipped*, never red.
5. **The agent posts the review** as `claude-approver[bot]` via `gh pr
   review --approve | --request-changes | --comment`. Branch
   protection sees a fresh review from a non-author identity and
   updates the *Required reviews* count.

For machine-authored PRs (Dependabot, the maintenance pipeline), the
human is fully out of the loop unless the Approver requests changes.
For human-authored PRs, the Approver supplements a human reviewer
rather than replacing them — unless you widen the allowlist (see
below).

## The PR description schema

The bootstrap-generated `.github/PULL_REQUEST_TEMPLATE.md` has the
sections the Approver expects:

```markdown
## Type
<!-- One of: feat | fix | refactor | chore(deps) | chore(deps-major) |
     chore(runtime) | security | docs | test | ci | build | chore |
     revert | hotfix. Add `!` for breaking. -->

## Summary
<!-- 1-3 bullets. -->

## Linked issue
<!-- Closes #123. Required for feat:. -->

## Risk
<!-- What could go wrong? -->

## Test plan
<!-- How was this verified? -->

## Notes for reviewer
```

Each section serves the Approver concretely:

| Section | What the Approver does with it |
| --- | --- |
| `## Type` | Drives type detection (primary signal). Wrong / missing type caps confidence at `LOW`. |
| `## Summary` | Read by the model as part of intent matching. |
| `## Linked issue` | For `feat:`, the linked issue body is the user-story the implementation is judged against. Missing on `feat:` is a finding. |
| `## Risk` | Seeded into the agent's risk register. A specific honest risk ("this could break X under Y") is more useful than "no known risks". |
| `## Test plan` | Cross-checked against the actual added/modified tests. |

PRs without these sections still get evaluated, but the baseline
criterion *"PR description has `## Type`, `## Summary`, and `## Test
plan` sections"* fails, which drops confidence one level per missing
section.

## PR types — quick reference

| Prefix | Type | Most common failure mode |
| --- | --- | --- |
| `feat:` | New feature | Tests look like coverage-farming (assertions only on mocks); implementation doesn't match the linked issue's story |
| `fix:` | Bug fix | No regression test; fix narrows error handling without addressing root cause |
| `refactor:` | Behaviour-preserving | Public API actually changed (caught by api-stability gate); coverage dropped |
| `chore(deps):` | Patch/minor bump | Release-notes link missing; bumped package has known breaking-change history |
| `chore(deps-major):` | Major bump | Migration sections not visibly addressed; consumers in this repo not updated |
| `chore(runtime):` | Python/Docker base bump | Cascade-upgrade body doesn't match diff |
| `security:` | CVE fix | No test demonstrating unsafe input no longer succeeds |
| `docs:` | Docs only | Claims don't cross-check against current code |
| `test:` | Tests only | Assertions only on mock return values; tests mock the unit they test |
| `ci:` / `build:` | Workflows | Required gate weakened; new workflow uses overly broad permissions |
| `chore:` | Cleanup | Removed code is referenced dynamically (`getattr`, plugin entry point) |
| `revert:` | Clean revert | Dependents since the original commit not considered |
| `hotfix:` | Emergency | Always `REQUEST_CHANGES` with "human review required" — by design (see below) |

Per-type must-haves and risk factors live in the policy template at
[`../templates/languages/python/approver-policy.md.tmpl`](../templates/languages/python/approver-policy.md.tmpl).
The rendered copy is at `.claude/approver-policy.md` in each
bootstrapped repo.

## The policy file

`.claude/approver-policy.md` is **the source of truth** for what your
Approver considers approvable. The agent reads it on every run.

### Editing the policy

Policy changes go through normal code review:

1. Branch, edit `.claude/approver-policy.md`, push, open a PR.
2. The Approver evaluates the policy-change PR using the **previous**
   version of the policy (the one currently on `main`). This is
   intentional — you can't grease through a permissive new policy by
   evaluating the policy-change PR against itself.
3. After merge, the new policy applies to PRs opened on top of
   the merged main.

### What you'll most often want to customise

- **Per-type criteria.** Tighten or loosen the must-haves for any of
  the 13 types. E.g., add "all new public functions have docstrings"
  to the `feat:` must-haves.
- **Confidence calibration.** Adjust the file-count or line-count
  caps. The default is 30 files / 1000 lines → cap at MEDIUM.
- **Baseline criteria.** Add or remove from the seven cross-type
  rules.

### What you should generally NOT change

- The **JSON schema** at the end of the policy. That's the contract
  `/development:maintenance` reads when ingesting `REQUEST_CHANGES`
  findings; changing it without updating the maintenance side
  silently breaks the closed loop.
- The **hotfix override**. Hotfixes are emergencies; the confidence
  model isn't calibrated for them. Keep `REQUEST_CHANGES` with "human
  review required" as the verdict.

## Local dry-run with `/development-python:approve`

Sometimes you want to know what verdict the Approver *would* render
before pushing. Run the agent locally:

```sh
# Reviews the PR for the current branch
/development-python:approve

# Reviews a specific PR
/development-python:approve 42
```

The skill spawns the same `python-approver` agent the CI workflow
uses, with `DRY_RUN=true` in the prompt. The agent's verdict (markdown -
hidden JSON block) prints to stdout. **Nothing is posted to
GitHub.**

Useful for:

- Predicting CI's verdict before pushing.
- Sanity-checking someone else's PR.
- Previewing a `.claude/approver-policy.md` change against open PRs
  before merging the policy update.

The dry-run consumes your `ANTHROPIC_API_KEY` from the environment
(or prompts), not the repo's secret. Same per-PR cost as the CI run
(~50–150 K opus tokens — see [Cost](#cost-and-rate-limits)).

Full spec in
[`../../../development-python/skills/approve/SKILL.md`](../../../development-python/skills/approve/SKILL.md).

## REQUEST_CHANGES → maintenance loop

When the Approver posts `REQUEST_CHANGES`, the review body has two
halves:

1. **Human-readable markdown** with the verdict, findings, risk
   register, and calibration trace.
2. **A hidden HTML-comment JSON block** at the bottom:

   ```html
   <!-- claude-approver:findings
   {
     "approver_version": "v1",
     "verdict": "REQUEST_CHANGES",
     "confidence": "LOW",
     "type_detected": "feat",
     "findings": [
       {
         "category": "test_quality",
         "title": "...",
         "detail": "...",
         "suggested_agent": "python-coverage-improver",
         "file": "tests/test_search.py",
         "line": 18
       }
     ]
   }
   -->
   ```

To close the loop, re-run maintenance:

```sh
/development:maintenance
```

The orchestrator's Phase 2.5 (*Approver feedback ingestion*) lists
open PRs in the repo, finds those with a `REQUEST_CHANGES` review by
`claude-approver[bot]` on the current head SHA, parses the JSON
block, groups findings by `suggested_agent`, spawns each named agent
against the PR's branch in a worktree, and pushes the fixes back to
the PR branch.

CI re-runs on the push, the Approver re-fires on the next
`check_suite: completed`, and the loop continues until the verdict
flips to `APPROVE` — or human attention is needed for a finding with
`suggested_agent: null` (e.g. `risk`, `api_stability`,
`feat_no_linked_issue`).

This is the **v1** loop — the human is in the loop only on the
re-trigger (you running `/development:maintenance` after each
`REQUEST_CHANGES`). The v2 loop closes that gap entirely via a
`pull_request_review`-triggered workflow on the repo side. v2 is not
shipped; v1's JSON-block bridge is the load-bearing primitive that
makes v2 mechanical to add later.

## The author allowlist

`CLAUDE_APPROVER_AUTHOR_ALLOWLIST` is a per-repo GitHub Actions
variable that controls **which PR authors the Approver evaluates**.

### Default — machine-only

```json
["dependabot[bot]", "github-actions[bot]", "claude-maintenance[bot]"]
```

PRs from anyone else (including you) are skipped at Gate 3 — the
gate job ends green without invoking the agent and the `approve` job
shows as skipped. The Approver is then
effectively just a robot for machine-authored PRs, and humans still
get a normal human review process.

### Widening to your login

```sh
gh variable set CLAUDE_APPROVER_AUTHOR_ALLOWLIST \
  --body '["dependabot[bot]","github-actions[bot]","claude-maintenance[bot]","timo-jakob"]'
```

Now the Approver evaluates your PRs too. The Approver's review still
satisfies branch protection's one-approval requirement (assuming
you've left the *Required reviews from someone other than the
last pusher* set), so you get auto-approved PRs that you author —
provided the Approver's verdict is `APPROVE`.

### Widening to everyone

```sh
gh variable set CLAUDE_APPROVER_AUTHOR_ALLOWLIST --body '["*"]'
```

Every PR gets evaluated. **Use this with care** — there's no rate-limit
defence at the workflow level; a busy repo with many human
contributors can pile up opus invocations quickly. The default
machine-only allowlist is the right choice for repos where automated
PRs are the volume and human PRs are the exception.

### Security considerations

- The Approver's review only satisfies branch protection if the
  Approver App's identity is in the *Allowed actors* for required
  reviews. By default it is (it's the only identity that can post a
  review with `pull_requests: write` from the App's token).
- The anti-rubber-stamp gate (Gate 2) checks `PR author ≠
  claude-approver[bot]`. This protects against a corrupted maintenance
  pipeline opening a PR under the Approver's identity and
  self-approving it.
- The `/approve` comment trigger (manual re-fire) is gated on
  `author_association ∈ {OWNER, MEMBER, COLLABORATOR}` (#192). A
  random external commenter can't make the workflow run.

## Hotfix override

Any PR titled `hotfix:` or `hotfix(scope):` always gets
`REQUEST_CHANGES` with "human review required" — before any other
evaluation runs. This is by design:

- Hotfixes are emergencies. The Approver's confidence model is
  calibrated for normal PRs, not for "the production is down, ship
  something fast."
- A human attestation in the audit trail is more valuable than a
  bot's verdict when the stakes are real.
- The Approver still produces a finding list, so the human reviewer
  benefits from the analysis even though the verdict is fixed.

To suppress this for a specific repo, edit `.claude/approver-policy.md`
and remove the *hotfix*-specific override section. Generally
discouraged — if you find yourself frequently shipping `hotfix:` PRs,
that's a process signal, not a policy problem.

## Multi-language status

**Today: Python only.**

The Approver framework (App identities, workflow, policy template
structure, dispatch contract, JSON block schema) is
language-agnostic. The **agent that does the evaluation** is
Python-specific (`python-approver` in the `development-python`
plugin).

For other languages (`development-javascript`, `development-go`,
`development-swift`, etc.), the pattern is:

1. Ship the language plugin's `<lang>-approver` agent
   (`development-<lang>/agents/<lang>-approver.md`).
2. Ship a language-specific policy template
   (`templates/languages/<lang>/approver-policy.md.tmpl`) bootstrap
   renders for that language.
3. Bootstrap's `--claude-approver true` detects which language
   plugins have an Approver agent and renders the right policy +
   wires the workflow to invoke the right agent.

Until any non-Python plugin ships its Approver agent, bootstrap
**warns-and-skips** on non-Python projects when `--claude-approver
true` is set. The warning explains which language's Approver is
missing and points at the issue for that language plugin's roadmap.

## Customisation

The most useful per-project customisation surfaces:

- **Author allowlist** — see above. The most common widening.
- **Policy criteria** — edit `.claude/approver-policy.md`. Add
  per-type must-haves, adjust calibration thresholds, change the
  baseline rules. Changes go through code review.
- **Workflow event triggers** — if you want the Approver to *not*
  fire on every push (e.g., only on `ready_for_review` to save token
  budget on early-WIP PRs), edit the `on:` block of
  `.github/workflows/claude-approver.yml`. The Gate 1 trigger-resolver
  handles missing triggers gracefully (skips out green).
- **Per-repo cost limits** — currently not enforced by the workflow.
  See [Cost](#cost-and-rate-limits) for how to estimate and bound.

What you generally **should not** customise without thinking carefully:

- The Approver's identity (don't rename the App). The
  `anti-rubber-stamp` gate keys off the literal string
  `claude-approver[bot]`.
- The JSON block schema in the policy. Maintenance reads it; changes
  must be coordinated.
- The `--force-with-lease` push semantics in the maintenance phase
  2.5 — they're there for a reason (parallel push race).

## Cost and rate limits

**Per-PR cost — opus, ~50–150 K tokens.** Driven mostly by:

- Diff size (the agent reads the full diff).
- Number of added/modified test files (Step 7's test-quality
  detection reads each test body).
- For `feat:`, the linked issue body.

At Anthropic's current Opus 4.7 pricing (~$15/M input, $75/M output),
that's roughly **$0.30–$2.00 per evaluated PR.** Skipped PRs (gate
declines before agent invocation) cost ~$0 in tokens — just the
workflow runner-minutes, including the gate's wait-for-CI loop.

**Estimating for your repo:** count machine-authored PRs per month
(Dependabot is usually the dominant source). Multiply by $1 as a
reasonable average. Most repos land in the $5–$30/month range.
Repos with many large refactors or feature PRs evaluated by the
Approver may run higher.

**When to fall back to human review** — if your machine-authored PR
volume gets large enough that token spend becomes meaningful (say,
>$100/month), consider tightening the author allowlist to drop
`github-actions[bot]` (which often opens many small PRs), or adjusting
the workflow trigger to fire only on `ready_for_review` instead of
`opened`.

**Rate limits:**

- Anthropic API: standard tier limits apply per the
  `ANTHROPIC_API_KEY` you provided. A burst of many simultaneous
  Approver runs (e.g., 20 Dependabot PRs opened in one batch) can
  hit per-minute token limits and stall some evaluations until the
  window resets. The workflow's `concurrency:` block prevents same-PR
  races but not cross-PR contention.
- GitHub Apps: token-mint is per-App-installation; the Approver App
  caps at 5000 requests/hour per installation, which is well above
  what a single repo's workflow needs.

## Troubleshooting

### `DataError: Invalid keyData` at "Mint Approver App token"

The private key in the repo secret is in **PKCS#1** format (`BEGIN RSA
PRIVATE KEY`). GitHub generates App keys that way, and
`actions/create-github-app-token@v1` accepted it — but v3+ of that
action (WebCrypto-based) only reads **PKCS#8** (`BEGIN PRIVATE KEY`)
and fails with exactly this error. The key is not broken; it's the
wrong container format.

Run the doctor (#234):

```sh
development/skills/bootstrap/scripts/install-claude-apps.zsh --verify --fix
```

It validates the Keychain key cryptographically against the App
(JWT → `GET /app` must return the registered App ID — this also
catches truncated keys and keys from the wrong App), re-sets the repo
secret normalized to PKCS#8, and offers to re-run the failed workflow
run. Only if the local key itself is missing or invalid does it walk
you through generating a fresh one in the App settings UI (the one
step GitHub has no API for).

### "Gate 1: comment not from a collaborator" — workflow exits early

The `/approve` comment trigger requires the comment author to have
`OWNER`, `MEMBER`, or `COLLABORATOR` association on the repo. External
contributors' comments don't fire the workflow (by design — see #192/#190).

If a legitimate maintainer hits this, check their account is added as
a repo collaborator with write access.

### "fatal: not a git repository" at gate 2

This was a real bug in 1.7.10 and earlier — `gh pr view` was called
before `actions/checkout`. Fixed in 1.7.11 (#204) by adding `-R
"$REPO"` to every pre-checkout `gh` call. **Re-run bootstrap** to
regenerate the workflow with the fix.

### The Approver never runs on PR open

Possible causes:

- **Cached CI runs.** If every required check resolved from cache
  without a fresh run, no `check_suite: completed` event fires. The
  `pull_request` backstop trigger (#198, 1.7.10+) handles this —
  again, re-run bootstrap to pick up the fix.
- **Author not on allowlist.** Default allowlist is machine-only.
  Add your login (see [The author allowlist](#the-author-allowlist)).
- **App not installed on this repo.** Visit
  `https://github.com/settings/installations` and confirm both apps
  are installed with access to the repo.

### Approver posts "operator error — refusing to evaluate"

The agent's preflight failed. Stderr in the workflow run will name
which condition:

- **`.claude/approver-policy.md` missing** → re-run bootstrap to
  render the policy.
- **`gh` can't authenticate** → the installation token mint failed;
  check the App credentials and that the App is still installed on
  this repo.
- **`PR_NUMBER` / `REPO` unset** → workflow template was modified;
  re-render from bootstrap.

The agent **deliberately doesn't post a verdict in these cases** —
they're operator errors, not PR problems.

### "Code exchange failed" during `register-claude-apps.zsh`

This was a real bug in 1.7.10 and earlier (#195) — `print --`
corrupted the PEM in the conversion response. Fixed in 1.7.10.
**Update the plugin family** to 1.7.10+ first. If you already
created an orphan App on GitHub before the fix, recover via
`--import` (see [One-time setup](#one-time-setup-per-machine)).

### `griffe check` failures in the api-stability workflow

Two cases:

- **"`--format json` is invalid"** — fixed in 1.7.11 (#204) by
  switching to `-f oneline`. Re-run bootstrap.
- **Genuine breaking change with no version bump** — this is the gate
  doing its job. Either bump the major version in
  `pyproject.toml [project].version`, add `!` to the conventional-commit
  type in the title, or revert the breaking change. See
  [`../../../development-python/docs/api-stability.md`](../../../development-python/docs/api-stability.md).

### The Approver approves but branch protection still requires a human

Check branch protection's *Require review from someone other than the
last pusher* and *Restrict who can dismiss reviews* settings — those
may be excluding the App. The Approver App's pull-request review is
treated as a regular review by GitHub.

If you've configured branch protection to require a specific number
of approvals from your team, the Approver's approval counts toward
that number. If you want the Approver to satisfy the entire approval
requirement, set *Require approvals* to `1` and ensure the Approver
App isn't excluded.

## Worked examples

These are illustrative renderings of what the Approver's review body
looks like in practice. Real verdicts from your repo will appear in
the same shape.

### Example A — `chore(deps):` Dependabot patch bump

```markdown
## Verdict: APPROVE

**PR type detected:** chore_deps
**Confidence:** HIGH

### Summary

Dependabot patch bump for `requests` from 2.31.0 to 2.31.1. Release
notes mention only a bug fix in `requests.adapters`. CI passed
including the existing requests integration tests. No new findings
from Sonar, Snyk, or CodeQL.

### Findings

(none)

### Top risks

- 2.31.1 patches a TLS-related bug; if the project relied on the
  specific (broken) behaviour, traffic to one upstream might fail.
  Mitigation: the existing integration tests would catch this and
  they pass.

### Calibration

- Started HIGH (default).
- No baseline failures.
- No per-type must-haves unmet.
- No risk-factor matches.
- Final: HIGH → APPROVE.

<!-- claude-approver:findings
{ "approver_version": "v1", "verdict": "APPROVE", "confidence": "HIGH",
  "type_detected": "chore_deps", "findings": [] }
-->
```

### Example B — `feat:` PR with coverage-farming tests

```markdown
## Verdict: REQUEST_CHANGES

**PR type detected:** feat
**Confidence:** LOW

### Summary

Implements user-story #142 (search by tag). Implementation looks
right and visibly addresses the user story. However: the three added
tests in `tests/test_search.py` assert only on mock return values and
don't exercise the actual search code path.

### Findings

- **test_quality** (`tests/test_search.py:18`): `test_search_by_tag`
  asserts on the mock's return value; the real `search()` function
  isn't called. Per the policy's `feat:` must-have *"new code paths
  have meaningful tests — assertions bind to behaviour, not to mock
  return values"*.
- **test_quality** (`tests/test_search.py:32`): `test_empty_query`
  has `assert True` after the call — coverage farming.
- **test_quality** (`tests/test_search.py:51`): `test_no_results`
  mocks the search function itself, so the test verifies the mock,
  not the unit under test.

### Top risks

- Coverage-farming tests give false confidence in the next
  refactoring window — the search code path appears tested but
  isn't.
- The actual search behaviour against a real corpus is untested.
- Issue #142's user story says "results sorted by tag relevance";
  no test asserts ordering.

### Calibration

- Started HIGH.
- Dropped to MEDIUM for one unmet `feat:` must-have (meaningful
  tests).
- Dropped to LOW for one risk-factor match (`tests look like
  coverage-farming`).
- Final: LOW → REQUEST_CHANGES.

### Suggested next action

Re-run `/development:maintenance` to ingest these findings.
`python-coverage-improver` will rewrite the test bodies to assert
on behaviour rather than mock return values.

<!-- claude-approver:findings
{ "approver_version": "v1", "verdict": "REQUEST_CHANGES",
  "confidence": "LOW", "type_detected": "feat", "findings": [
    { "category": "test_quality", "title": "...",
      "suggested_agent": "python-coverage-improver",
      "file": "tests/test_search.py", "line": 18 }, ... ] }
-->
```

### Example C — `refactor:` PR with an API change the gate let through

```markdown
## Verdict: REQUEST_CHANGES

**PR type detected:** refactor
**Confidence:** LOW

### Summary

Refactor splits `parser.py` into `parser/` package with submodules
for tokenisation, AST construction, and validation. The diff is
mechanically clean — no test changes, no behaviour-affecting
re-ordering. **However:** `griffe-findings.json` shows
`parser.parse_string` was renamed to `parser.tokenise.parse_string`,
which is a breaking change to the public API.

### Findings

- **api_stability** (`parser/__init__.py:1`): Public function
  `parser.parse_string` was removed from the package's top-level
  namespace. The api-stability gate let this through because the PR
  title declares `refactor!:` and `pyproject.toml [project].version`
  was bumped major. **But the policy's `refactor:` must-have is
  non-negotiable: refactors don't change public API, full stop.**
  Either:
  - Restore the top-level re-export (`from .tokenise import
    parse_string` in `parser/__init__.py`), keeping this as a true
    refactor, OR
  - Change the PR type to `feat!:` (or split the refactor and the
    rename into two PRs).

### Top risks

- Downstream consumers of `parser.parse_string` will break silently
  on update unless their tests cover the import.
- A `refactor!:` declaration sets a precedent for the next refactor
  to do the same — better to enforce the "refactors are boring" rule.

### Calibration

- Started HIGH.
- Dropped to MEDIUM for one unmet `refactor:` must-have (no public
  API change).
- Dropped to LOW for the explicit "refactors are non-negotiably
  no-break" override in the policy.
- Final: LOW → REQUEST_CHANGES.
```

These examples are hypothetical; real verdicts will reference your
project's actual code and issues. Once we have a few real
Approver-verdict PRs landed via the `ai-doc-organizer` test bed,
they'll be added here.

## Reference docs

| Document | What it covers |
| --- | --- |
| [README *Claude Approver* section](../../../README.md#claude-approver) | Design summary + ship-status table |
| [`CLAUDE-APPS.md`](./CLAUDE-APPS.md) | The two App identities, permissions, manifest flow, manual fallback, key rotation |
| [`../../../development-python/docs/python-approver.md`](../../../development-python/docs/python-approver.md) | Agent runtime spec — what env it gets, the 13-step procedure, the JSON schema, hard-fail conditions, refusal patterns |
| [`../../../development-python/docs/api-stability.md`](../../../development-python/docs/api-stability.md) | Griffe-based API-stability gate — the artifact the Approver reads in step 4 |
| [`../../../development-python/skills/approve/SKILL.md`](../../../development-python/skills/approve/SKILL.md) | Local dry-run skill — how `/development-python:approve` invokes the agent |
| [Bootstrap `SKILL.md` Step 3e](../SKILL.md) | What gets rendered into the target repo at bootstrap time |
| [Bootstrap `SKILL.md` Step 4.5 *Claude Apps install*](../SKILL.md) | What `install-claude-apps.zsh` does at bootstrap time |
| [Maintenance `SKILL.md` Phase 2.5](../../maintenance/SKILL.md) | Approver feedback ingestion — the closed loop |
