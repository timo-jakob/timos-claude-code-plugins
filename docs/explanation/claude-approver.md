# The Claude Approver — design summary

> **Operator-facing adoption guide:**
> [`development/skills/bootstrap/docs/APPROVER.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/APPROVER.md).
> Start there if you want to use the Approver on your own project. This page
> is the design summary that explains *why* the Approver works the way it does.
> To adopt it, see [How-to: adopt the Approver](../how-to/adopt-the-approver.md).
>
> **Read this page as history up to #476.** Phases 0–6 below describe the
> original **CI-driven** Approver. Since epic #476 the Approver is
> **user-invoked locally** via `/development-<lang>:approve`: bootstrap renders
> **no workflow** (`claude-approver.yml.tmpl` was removed in #479), there is no
> automatic re-trigger, the author allowlist is retired (pointing the skill at a
> PR *is* the trigger filter), and App credentials live in the local Keychain
> rather than in repo secrets/variables. Every mention of a workflow, a trigger,
> an allowlist or a repo variable below belongs to that retired design; the
> *reasoning* it records is why the Approver still works the way it does.
>
> **Status — Phases 0–5 + #174 shipped; Phase 6 (live validation) in
> progress.** The two GitHub App identities can be registered
> (`Phase 0`, #179), bootstrap installs them on a repo with the secrets +
> variables they need (`Phase 1`, #180), the policy +
> PR description template render at bootstrap time (`Phase 2`, #181),
> the `python-approver` fable agent the workflow invokes is in
> [`development-python/agents/python-approver.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-python/agents/python-approver.md)
> with the operator-facing runtime spec at
> [`development-python/docs/python-approver.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-python/docs/python-approver.md)
> (`Phase 3`, #183), `/development:maintenance` re-ingests the
> Approver's hidden-JSON findings on the next run (`Phase 4`, #185),
> and `/development-python:approve` runs the same agent locally
> (`Phase 5`, #186) — it posts the verdict; the print-only path is
> spawning the agent with `DRY_RUN=true`, and the `--dry-run` flag is
> Go-only. The
> [`api-stability`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-python/docs/api-stability.md)
> gate (`griffe` + version-bump bypass, from
> [#174](https://github.com/timo-jakob/timos-claude-code-plugins/issues/174))
> couples in via the artifact the agent reads. **Remaining:** Phase 6 is
> live validation against the `ai-doc-organizer` test bed; the first
> bot PR after merge will exercise the workflow end-to-end. All tracked
> under
> [#89](https://github.com/timo-jakob/timos-claude-code-plugins/issues/89)
> and the meta-tracker
> [#176](https://github.com/timo-jakob/timos-claude-code-plugins/issues/176).

## Idea

`/development:bootstrap` installs a Zero Tolerance toolchain — CI runs ruff,
mypy, semgrep, Sonar, Snyk, CodeQL, and a `coverage-floor` step that fails
the build below 90% new-code coverage; branch protection on `main` requires
every check green plus one approving review before merge. The Approver is
the **final synthesis layer** that decides whether that approving review
can come from Claude rather than (or in addition to) a human.

It is *not* another CI check. It runs **after** every other gate has passed
and asks two judgment questions a checker can't:

- **Risk** — given everything is green, what could still go wrong?
- **Confidence** — how sure am I that this PR actually does what it claims,
  with the quality the project expects?

Verdict is one of:

- `APPROVE` — confidence HIGH and risk register has no load-bearing entries.
- `REQUEST_CHANGES` — at least one criterion failed OR confidence below HIGH.
  Findings are emitted both as human-readable markdown *and* a hidden
  machine-readable JSON block so the maintenance pipeline can re-ingest them.
- `COMMENT` with reservations — bot would approve "if X is verified by a
  human"; defers to a human for the binary call.

## How it runs (gating)

> **Pre-#476 history.** The gating below describes the retired CI-driven
> Approver. Since epic #476 the Approver is **user-invoked locally** and
> bootstrap renders **no workflow** (`claude-approver.yml.tmpl` was removed in
> #479), so the workflow triggers, the neutral-exit behaviour and the `/approve`
> PR-comment path are no longer live. The gates themselves still describe what
> the agent checks.

The Approver only spends a token once every other signal is clean:

- All required GitHub Actions status checks = SUCCESS
- No new findings from SonarCloud/SonarQube, Snyk Code, Snyk OSS, CodeQL
- All review threads resolved
- All checkboxes in the PR body checked
- PR not in draft; no pending review requests
- HEAD SHA matches the SHA that produced the green checks (no race)

If any gate failed the workflow exited neutral and waited for the next event,
and an `/approve` PR comment re-triggered it. Both belong to the retired
CI path above — today you invoke `/development-<lang>:approve` yourself.

## Identity (two distinct GitHub Apps)

- **Claude Approver** — its `pull_request_review` calls satisfy branch
  protection's one-approval requirement. Permissions:
  `pull_requests: write`, `contents: read`.
- **Claude Maintenance** — separate App used by `/development:maintenance`
  to open PRs. Distinct identity so the anti-rubber-stamp gate
  ("PR author ≠ approver identity") fires correctly even when maintenance
  PRs are evaluated by the Approver.

One-time per-org setup registers both Apps; per-repo bootstrap installs
them and stores `*_APP_ID` repo variables + `*_PRIVATE_KEY` repo secrets.
See [`CLAUDE-APPS.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/CLAUDE-APPS.md)
and [`APPROVER-APP.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/APPROVER-APP.md).

## Author allowlist (machine-only by default)

The Approver only evaluates PRs from authors on a configurable allowlist.
Default: `dependabot[bot]`, `github-actions[bot]`, `claude-maintenance[bot]`.
Override per-repo via the `CLAUDE_APPROVER_AUTHOR_ALLOWLIST` repo variable
(set to `["*"]` to opt into reviewing human-authored PRs).

It is the approving half of `python-dependabot-snyk-triage`'s merge flow
for safe patch + minor Dependabot PRs — triage never approves, so its
merges (immediate or via armed auto-merge) wait on the Approver's or a
human's review; when triage defers a PR or CI is red, **you** run
`/development-<lang>:approve` on it once everything turns green —
nothing picks it up on its own.

## PR type taxonomy

Detection: conventional-commit prefix in PR title (primary), diff heuristic
(fallback), author hint (tiebreaker). Ambiguity is itself a finding.

| Prefix | Type | Headline risk |
| --- | --- | --- |
| `feat:` | New feature | Implementation matches the story; tests are meaningful, not coverage farming |
| `fix:` | Bug fix | Regression test exists; root cause addressed, not the symptom |
| `refactor:` | Behavior preserved | No public-API change; coverage holds; diff is atomic |
| `chore(deps):` | Patch/minor dep bump | Changelog scanned; supplements `python-dependabot-snyk-triage` |
| `chore(deps-major):` | Major dep bump | Migration notes verifiably addressed |
| `chore(runtime):` | Python / Docker base-image bump | Structured commit body from `python-runtime-upgrade` matches the diff |
| `security:` | CVE / finding fix | Test demonstrates the unsafe input no longer succeeds |
| `docs:` | Documentation only | Claims cross-checked against the code described |
| `test:` | Tests only | Assertions are meaningful, not line-touching |
| `ci:` / `build:` | Workflows / config | No required gate weakened |
| `chore:` | Cleanup / maintenance | Dead-code removal verified including dynamic references |
| `revert:` | Clean revert | Dependents since the original commit checked |
| `hotfix:` | Emergency | Always REQUEST_CHANGES with "human review required" |

Full criteria per type live in the in-repo policy file.

## Policy file (in target repo)

Bootstrap generates `.claude/approver-policy.md` from the language-matched
template. The policy is the source of truth for "ready to approve" —
versioning it in-repo means changes to the criteria themselves go through
code review. A policy-change PR is evaluated by the *previous* policy; the
new policy applies to PRs opened after it merges.

Policy file content:

- Type detection rules (primary / fallback / tiebreaker)
- Baseline criteria (apply to every type)
- Per-type must-have criteria
- Per-type risk factors to weigh
- Confidence calibration rules

## PR description template

Bootstrap also generates `.github/pull_request_template.md` mirroring the
structure the Approver expects:

```markdown
## Type
<!-- feat | fix | refactor | chore(deps) | chore(deps-major) |
     chore(runtime) | security | docs | test | ci | chore | revert | hotfix -->

## Linked issue
<!-- #123 or Closes #123 — GitHub issue body is read by the Approver for `feat:` -->

## Risk
<!-- What could go wrong? Edge cases not exercised? Anything load-bearing untested? -->

## Test plan
<!-- How was this verified beyond `pytest`? -->

## Checklist
- [ ] ...
```

## REQUEST_CHANGES feedback loop

The Approver's findings include a hidden machine-readable JSON block —
**this is shipped** (Phase 3); the schema lives in
[`development-python/docs/python-approver.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-python/docs/python-approver.md).
**v1** *(Phase 4, shipped — #185)*: the user re-runs
`/development:maintenance`, which reads the JSON block from the most recent
Approver review, dispatches the relevant triage agents (ruff, semgrep, snyk,
sonar, etc.) and pushes fixes; you then re-run
`/development-<lang>:approve <PR>` once CI is green again — there is **no
automatic re-trigger**. (A **v2** that closed the loop in CI via a
`pull_request_review`-triggered workflow was designed but never shipped; #476
retired the workflow path entirely.) v1's JSON bridge is the load-bearing
primitive.

## Languages

Python, Java, and Swift ship `<lang>-approver` agents (fable) + policy
templates today (`python-approver`, `java-approver`, `swift-approver`); the
bootstrap wires the per-language approver via `{{APPROVER_LANG}}`, which
resolves **only** to those three. **Go** ships `go-approver` and
`/development-go:approve` too, but `{{APPROVER_LANG}}` does not resolve for it,
so bootstrap skips the **whole** Approver path on a Go repo — App install
included. Using it there means installing the Apps and authoring
`.claude/approver-policy.md` by hand (see the
[how-to](../how-to/adopt-the-approver.md)). Future plugins
(`development-node`, etc.) follow the same pattern.
Bootstrap with `--claude-approver true` on any language `{{APPROVER_LANG}}`
cannot resolve — currently anything but Python, Java and Swift — warns and
skips.
