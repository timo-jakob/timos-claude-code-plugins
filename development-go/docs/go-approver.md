# Go Approver — runtime behaviour

Operator-facing reference for the `go-approver` agent. What it does in
your repo when it runs, what it reads, what it posts, and when it
refuses to act. The implementation lives in
[`agents/go-approver.md`](../agents/go-approver.md); this file is the
human-readable specification of the same behaviour.

## When it runs

The agent is invoked **locally, by the user**, via the
`/development-go:approve <PR>` skill (epic #476) — there is no GitHub
Actions trigger. You decide when a PR is ready for an Approver verdict;
typically after CI has gone green. The skill:

1. Verifies the Approver App is registered (apps.json + Keychain) and
   `gh` is authenticated.
2. Resolves the PR (explicit number, or the current branch's PR).
3. Mints a 1-hour Approver App installation token from the Keychain via
   `mint-approver-token.zsh` — which writes it to a mode-600 file and
   returns the **path**, never the token value (#640).
4. Spawns this agent with the resolved `DRY_RUN` (`false` unless you
   passed `--dry-run`, in which case the verdict is printed, not posted).
   When posted, the verdict attributes to `claude-approver-<owner>[bot]`.

The CI-era gate conditions didn't disappear — they moved: *CI green at
the head SHA* is re-checked by the agent itself (baseline criterion 1),
the *anti-rubber-stamp* rule (PR author ≠ approver identity) lives in
the agent's refusal patterns, and the *author allowlist* is retired —
the user pointing the skill at a PR **is** the trigger filter.

## Inputs

The approve skill provides these env vars (or the equivalent prompt
values) when spawning the agent:

| Variable | Source | Used for |
| --- | --- | --- |
| `GH_TOKEN` | Approver App installation token. Local: read it from the token **file path** given in the prompt (`export GH_TOKEN=$(cat <path>)`); CI: already in the env (#640) | All `gh` mutations attribute to `claude-approver-<owner>[bot]` |
| `PR_NUMBER` | The PR number | Every `gh` call |
| `REPO` | `<owner>/<repo>` | Path qualification |
| `DRY_RUN` | `"true"` for a non-binding local run, `"false"` to post | Print-vs-post toggle |

The agent's prompt itself is a short string:

```text
Review PR #<N> in <owner>/<repo>. Dry-run: <true|false>.
```

The agent runs in your local checkout of the repo, but that cwd is the
**shared session worktree** — the agent must never `git checkout` /
`git switch` / `gh pr checkout` in it (or any `.claude/worktrees/` dir),
which would leave the orchestrator detached (#643); it reviews from
`gh pr diff` / `gh api`, using a self-removing scratch worktree only if
it truly needs the PR tree.

## Procedure (what the agent does, step by step)

The detailed procedure lives in the agent prompt; this is the operator's
summary.

1. **Read the policy.** Loads `.claude/approver-policy.md`. If absent,
   refuses to run (see *Hard-fail conditions*). The policy is the source
   of truth for type detection, baseline criteria, per-type must-haves,
   risk factors, and confidence calibration.

2. **Gather PR context.** `gh pr view` + `gh pr diff` + `gh pr view
   --json files` to capture title, body, author, head SHA, base ref,
   changed-file list, full diff, labels, and mergeability. A
   `CONFLICTING` PR is a hard stop — no evaluation, no verdict: the
   conflict gets resolved first (by the writer bot, the vendor bot's own
   rebase, or the human author — never the read-only Approver), and the
   review runs afterwards on the resolved head.

3. **Detect PR type** per the policy: primary (conventional-commit
   prefix in title), fallback (diff heuristic over changed paths),
   tiebreaker (author hint). If genuinely ambiguous, emits a finding and
   caps confidence at LOW.

4. **Go API-stability gate (not configured).** The Python Approver reads
   a Griffe artifact from an `api-stability` workflow at this step. The
   Go analog — a package-API-compatibility gate built on
   `golang.org/x/exp/apidiff` or `gorelease` — is **not built yet**. The
   agent verifies exported-symbol stability directly via LSP
   find-references over the diff's changed public identifiers **first**,
   **then** records the informational finding reflecting what that pass
   actually did. If LSP is unavailable or errors, the finding says so
   honestly (judged from the diff only, not machine-verified), and a
   `refactor:` PR touching exported symbols is treated as a public break
   rather than assumed safe. Generated `*.pb.go` / `*.pb.gw.go` symbols
   are never treated as hand-authored API — the `.proto` is the source
   of truth.

5. **Cheap local checks** — defence-in-depth, not the primary
   verification, run **against the PR head** (in local invocation the
   whole-tree commands run inside a fresh scratch worktree at the PR head
   SHA, never the shared session worktree). Go tooling: `golangci-lint
   fmt --diff` on the changed `.go` files + `golangci-lint run` **per
   changed package** (`./<dir>/...`, since a file list spanning >1
   directory is rejected), then `go vet ./...`, `go build ./...`, and
   `go test -run '^$' ./...` to confirm the tests still compile without
   re-running the suite. A tool's own invocation error (bad args, tool
   absent, gopls unindexed) is noted-and-skipped, not a finding; only a
   genuine failure at the PR head becomes one, and even then it feeds
   calibration rather than auto-`REQUEST_CHANGES`. LSP cross-reference
   lookups for any public symbol the diff touches.

6. **Linked issue (for `feat:` only).** Extracts any GitHub closing
   keyword (`Closes`/`Fixes`/`Resolves #N` and case/tense variants) from
   the body and reads the issue. Judges whether the implementation in
   the diff visibly addresses the user story. This is the one moment of
   model-driven intent matching.

7. **Test-quality detection.** Reads test bodies of added or modified
   `_test.go` files. Flags empty bodies, computed-but-unasserted
   comparisons (`if got != want` with no `t.Errorf`/`t.Fatalf`),
   assertions only on a fake's own return, tests that stub the unit
   under test, table tests that never assert per case, names promising
   behaviour the assertions don't verify, and `t.Skip` / `// TODO:
   assert` filler.

8. **Per-type evaluation** against the policy's per-type must-haves +
   risk factors. Each finding cites the policy section by name.

9. **Baseline criteria** — the cross-type rules: CI green at head SHA
   (CANCELLED checks neutral, #190), no new tool findings, PR
   description has Type / Summary / Test plan (exact vendor-bot
   allowlist exception), no conflict markers, no bare TODO/FIXME without
   issue link, no new secrets, no unattested dep.

10. **Risk register — fed by the review dimensions (#449).** Walks the
    five lenses of the `/development-go:review` panel — bugs, security,
    performance, code quality, tests — one focused pass each over the
    diff, and emits at most the top 3 risks overall, each tagged with
    the `dimension` that produced it. Fable judgement; three is a cap,
    not a floor — an empty lens contributes nothing. Go-specific
    concerns include per-iteration loop-variable capture (judged by the
    module's `go` directive), nil-map writes, unchecked errors,
    goroutine leaks, `InsecureSkipVerify`, and data-race exposure.

11. **Confidence calibration** — start `HIGH`, apply policy adjustments.
    Verdict mapping:
    - `HIGH` + no critical baseline failure → `APPROVE`
    - `HIGH` + critical baseline failure → `REQUEST_CHANGES`
    - `MEDIUM` → `COMMENT` with reservations
    - `LOW` → `REQUEST_CHANGES`

12. **Render review body.** Markdown with verdict + summary + findings +
    top risks + calibration notes, AND a hidden HTML-comment JSON block
    at the bottom (see *Output* below).

13. **Post or dry-run.** Before the review is posted or printed (dry-run
    included), every finding contributing to a non-`APPROVE` verdict that
    rests on PR **metadata** (body, title, labels — as opposed to code
    findings) is re-verified against a fresh fetch of the live PR object;
    if the successful re-fetch contradicts the earlier read, live state
    governs — the finding is dropped or amended (re-running any earlier
    evaluation step the corrected metadata feeds, and everything
    downstream) and the verdict re-derived before anything is posted. A
    failed re-fetch is a tool failure, never a contradiction (#788).
    Then: if `DRY_RUN=true`, prints to stdout and exits. Otherwise
    `gh pr review --approve | --request-changes | --comment --body-file
    <tmpfile>`. The App token in `GH_TOKEN` attributes the review to
    `claude-approver-<owner>[bot]`.

## Hotfix special case

If the PR title starts with `hotfix:` or `hotfix(...):`, the agent posts
`REQUEST_CHANGES` immediately with a single finding:

> `hotfix:` requires human review. Hotfixes are emergencies and the
> Approver's confidence model is not calibrated for them. A human must
> make the merge call.

This happens **before** any of the procedure above. No risk register, no
calibration. The verdict is fixed.

## Maintenance-bot special case

PRs authored by `claude-maintenance[bot]` (which `/development:maintenance`
opens in Phase 4 of #89) start at `HIGH` confidence and can `APPROVE`
directly when CI is green and there are zero new tool findings. The
maintenance pipeline already ran tests + tool-specific verification on
the worktree before opening the PR, so the Approver's job on those is
mainly a sanity check. This shortens calibration only — unlike the
hotfix case it is **not** an early exit: every procedure step still runs
(mergeability, test-quality detection, live-state verification), and
"zero new tool findings" is a conclusion reached only after those steps,
not an assumption that skips them.

## API stability coupling

The Python Approver couples to
[`#174`](https://github.com/timo-jakob/timos-claude-code-plugins/issues/174)'s
`api-stability` workflow — it reads `griffe-findings.json` and applies
type-aware rules on top of the gate's binary bypass.

**No equivalent gate exists for Go yet.** An `apidiff`/`gorelease`-based
package-API-compatibility check is the planned analog, but it has not
been built. Until it ships, the Go Approver has no CI artifact to read at
step 4: it records the informational "Go API-stability gate not
configured" finding and verifies public-surface stability directly via
LSP find-references. The type-aware coupling described for Python — where
a `refactor:` PR the gate let through with `!` still earns a finding
because `refactor:` is non-negotiably no-break — is enforced here by that
LSP check, and gains a CI artifact once the Go gate lands.

| Layer | When breaking changes are allowed | What it checks |
| --- | --- | --- |
| Gate (CI) | Not configured for Go yet | n/a until apidiff/gorelease ships |
| Approver (this agent) | Depends on PR type — `feat!:` allows it, `refactor:` does not | Type-aware, via LSP find-references until the gate exists |

## Output: review body + hidden JSON

The review body is markdown structured as:

```markdown
## Verdict: <APPROVE | REQUEST_CHANGES | COMMENT (with reservations)>

**PR type detected:** <type>
**Confidence:** <HIGH | MEDIUM | LOW>

### Summary
...

### Findings
- <category>: <title> [<file:line>]
  <detail>

### Top risks
- <risk 1 — dimension>
- <risk 2 — dimension>

### Calibration
- Started HIGH.
- Dropped to MEDIUM because <reason>.

---

<!-- claude-approver:findings
{ "approver_version": "v1", "verdict": "...", "confidence": "...", "type_detected": "...", "findings": [ ... ] }
-->
```

The hidden HTML-comment JSON block at the bottom is **load-bearing** —
it is what `/development:maintenance` parses on the next maintenance run
to re-dispatch the right triage agents on `REQUEST_CHANGES` verdicts.
Don't strip it; don't reformat it; don't substitute prose for it.

### JSON schema

```json
{
  "approver_version": "v1",
  "verdict": "APPROVE | REQUEST_CHANGES | COMMENT",
  "confidence": "HIGH | MEDIUM | LOW",
  "type_detected": "feat | fix | refactor | chore_deps | chore_deps_major | chore_runtime | security | docs | test | ci | chore | revert | hotfix | ambiguous",
  "findings": [
    {
      "category": "test_quality | api_stability | coverage | baseline | type_ambiguity | feat_no_linked_issue | risk | type_policy | approver_permission",
      "dimension": "bugs | security | performance | code_quality | tests | null",
      "title": "Short headline",
      "detail": "Multi-line markdown explanation citing the policy clause that drove this finding.",
      "suggested_agent": "go-coverage-improver | go-sonar-triage | go-semgrep-triage | go-code-scanning-triage | null",
      "file": "internal/pkg/file.go",
      "line": 42
    }
  ]
}
```

Every JSON finding has a counterpart in the prose; the prose may not add
findings the JSON omits. The JSON is the contract; the prose is the
human view.

### `suggested_agent` mapping

Determines which triage agent `/development:maintenance` dispatches when
re-ingesting findings in Phase 4 of #89:

| Category | Suggested agent | Rationale |
| --- | --- | --- |
| `test_quality` | `go-coverage-improver` | Same skill writes meaningful tests as fixes bad ones |
| `coverage` | `go-coverage-improver` | Direct match |
| `baseline` (Sonar findings) | `go-sonar-triage` | Category matches scanner |
| `baseline` (semgrep findings) | `go-semgrep-triage` | Category matches scanner |
| `baseline` (CodeQL / Code Scanning alerts) | `go-code-scanning-triage` | Category matches scanner |
| `api_stability` | `null` | Gate not configured yet; informational only |
| `feat_no_linked_issue` | `null` | Author needs to link the issue |
| `type_ambiguity` | `null` | Author needs to rename the PR |
| `risk` | `null` | Judgement-only |
| `type_policy` (e.g. hotfix) | `null` | Human review required |
| `approver_permission` | `null` | Operator re-accepts the App grant |

## Hard-fail conditions (refuses to run)

The agent exits non-zero with a clear `stderr` message and **does NOT
post a review** when:

- `.claude/approver-policy.md` is missing.
- `gh` is not on `PATH`.
- `GH_TOKEN` is unset or empty AND `gh auth status` is non-zero.
- `PR_NUMBER` or `REPO` are unset.

These are operator errors, not PR problems. The operator needs to fix
their setup (registration, Keychain, `gh` auth), not the PR author.

## Refusal patterns (will NOT do)

- **Never approve a PR not actually evaluated.** If a tool the
  evaluation *depends on* (gh, jq, git) failed mid-run, the verdict is
  `REQUEST_CHANGES` with a finding describing the failure, never
  `APPROVE` with reduced confidence. A failed step-5 *cheap check* (a
  golangci-lint / `go` invocation error) is not this — CI already
  verified the tree, so it is noted-and-skipped.
- **Never post a duplicate review on the same head SHA.** If a previous
  Approver review with the same verdict on the current head SHA already
  exists, the agent exits 0 silently. (A fresh run *may* supersede a
  prior COMMENT/REQUEST_CHANGES when its blocking condition has since
  been addressed.)
- **Never modify the PR branch.** The agent is review-only. Even if it
  spots a one-line fix, its output is a finding, not a commit.
- **Never approve `hotfix:` PRs.** Always `REQUEST_CHANGES` with "human
  review required."

## Cost expectations

Fable, ~50–150 K tokens per PR depending on diff size and how many test
bodies the agent reads. The model is deliberately the high-judgement tier
because the questions (is this test meaningful? does the implementation
match the story? what could still go wrong?) are not mechanical. The
Approver runs only after every other gate is green, so the per-PR Fable
cost is bounded by the rate at which PRs reach the all-green state —
typically once per PR per push, not per push.

## Wiring status

Shipped in this slice (H of #868): the `go-approver` agent
([`agents/go-approver.md`](../agents/go-approver.md)) and the
`/development-go:approve` skill (user-triggered, posts the verdict as
`claude-approver-<owner>[bot]`; `--dry-run` prints instead). Epic #476
retired the CI workflow entirely; the skill is the invocation path on
every language.

**Not yet shipped — the bootstrap policy wiring.** The agent's Step 1
requires `.claude/approver-policy.md`, and it hard-fails without it. On
Python / Java / Swift that file is rendered by
`/development:bootstrap --claude-approver true`, but bootstrap does not
yet resolve `go` as an approver language (its `{{APPROVER_LANG}}` is
`python` / `java` / `swift`, and there is no
`templates/languages/go/approver-policy-overlay.md.tmpl`) — that lands
in the epic's **bootstrap slice**. Until then, on a Go repo you must
**hand-author `.claude/approver-policy.md`** before the first
`/development-go:approve` run: a sibling's rendered policy (a Java or
Swift repo's `.claude/approver-policy.md`) is a fine starting base —
adjust the type-detection and per-type sections for Go, since the agent
applies the policy verbatim (Steps 3 / 8 / 9 / 11). This mirrors the
Approver's own honest treatment of the missing API-stability gate:
absent machinery is named, not assumed.

## Related

- `/development:maintenance` reads the hidden JSON block from this agent's
  most recent review and re-dispatches the triage agents listed under
  `suggested_agent`. The JSON schema above is the contract.
- `/development-go:approve` is the invocation path (epic #476):
  user-triggered, token minted locally, verdict posted as the Approver
  App. Pass `--dry-run` for a non-binding evaluation that prints instead
  of posting.
- The operator-facing adoption guide, troubleshooting, and worked
  examples live in
  `development/skills/bootstrap/docs/APPROVER.md`.
