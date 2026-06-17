# Java Approver — runtime behaviour

Operator-facing reference for the `java-approver` agent. What it does
in your repo when it runs, what it reads, what it posts, and when it
refuses to act. The implementation lives in
[`agents/java-approver.md`](../agents/java-approver.md); this file
is the human-readable specification of the same behaviour.

## When it runs

The agent is invoked by `.github/workflows/claude-approver.yml` (one of
the templates `/development:bootstrap --claude-approver true` renders).
The workflow fires on three GitHub events:

- `check_suite: completed` — primary. Once CI has finished on a PR head
  SHA, the workflow evaluates whether the gate state allows an Approver
  verdict.
- `issue_comment: created` — for `/approve` (manual re-trigger) and
  `/approve --dry-run` (non-binding evaluation that prints to the log
  without posting a review).
- `pull_request_review: submitted | dismissed` — re-evaluate after other
  reviewers act.

The workflow's gating steps (author allowlist, anti-rubber-stamp, PR
state, all-green checks, HEAD SHA freeze) decide *whether* to invoke
the agent. The agent itself is invoked **only when those gates pass**;
it is not a checker.

## Inputs

The workflow exports these env vars before invoking the agent:

| Variable | Source | Used for |
| --- | --- | --- |
| `GH_TOKEN` | Claude Approver App installation token | All `gh` mutations attribute to `claude-approver[bot]` |
| `ANTHROPIC_API_KEY` | Repo secret | Model invocation |
| `PR_NUMBER` | The PR number | Every `gh` call |
| `REPO` | `<owner>/<repo>` | Path qualification |
| `DRY_RUN` | `"true"` if `/approve --dry-run`, else empty | Print-vs-post toggle |

The agent's prompt itself is a short string:

```text
Review PR #<N> in <owner>/<repo>. Dry-run: <true|false>.
```

The PR's HEAD is already checked out into the working directory (with
full git history). The plugin family is available under
`.claude-plugins/development` and `.claude-plugins/development-java`.

## Procedure (what the agent does, step by step)

The detailed procedure lives in the agent prompt; this is the
operator's summary.

1. **Read the policy.** Loads `.claude/approver-policy.md`. If absent,
   refuses to run (see *Hard-fail conditions* below). The policy is
   the source of truth for type detection, baseline criteria, per-type
   must-haves, risk factors, and confidence calibration.

2. **Gather PR context.** `gh pr view` + `gh pr diff` + `gh pr view
   --json files` to capture title, body, author, head SHA, base ref,
   changed-file list, full diff, and labels.

3. **Detect PR type** per the policy: primary (conventional-commit
   prefix in title), fallback (diff heuristic over changed paths),
   tiebreaker (author hint). If genuinely ambiguous, emits a finding
   and caps confidence at LOW.

4. **Java API-stability gate (not configured).** The Python Approver
   reads a Griffe artifact (`griffe-findings.json`) from an
   `api-stability` workflow at this step. The Java analog — a
   binary/source API-compatibility gate built on japicmp or revapi —
   is **not built yet**. The agent therefore records a single
   informational finding ("Java API-stability gate not configured")
   and proceeds. No artifact is downloaded, and no API-break verdict
   is rendered for Java PRs until that gate ships.

5. **Cheap local checks** — defence-in-depth, not the primary
   verification. Gradle-based: `./gradlew spotlessCheck` for formatting
   on the changed sources, `./gradlew compileTestJava` to confirm the
   test sources still compile, and `./gradlew test --dry-run` to
   confirm tests still resolve into the task graph. LSP cross-reference
   lookups for any public symbol the diff touches.

6. **Linked issue (for `feat:` only).** Extracts `Closes #N` /
   `Fixes #N` from the body and reads the issue. Judges whether the
   implementation in the diff visibly addresses the user story. This
   is the one moment of model-driven intent matching.

7. **Test-quality detection.** Reads test bodies of added or modified
   test files (JUnit / Mockito). Flags:
   - `assertTrue(true)` / `assertEquals(1, 1)` or an empty `@Test`
     method body as the only content.
   - Assertions only on mock return values.
   - Tests that mock the very unit they're testing.
   - Names promising behaviour the assertions don't verify.
   - `@Disabled` without a reason, or a `// TODO: write test` left in.

8. **Per-type evaluation** against the policy's per-type must-haves +
   risk factors. Each finding cites the policy section by name so
   verdicts are traceable to specific clauses.

9. **Baseline criteria** — the seven cross-type rules: CI green, no
   new tool findings, PR description has Type / Summary / Test plan,
   no conflict markers in the diff, no bare TODO / FIXME without
   issue link, no new secrets, no unattested dep.

10. **Risk register** — top-3 things that could still go wrong even
    with everything green. Opus judgement, three is a cap not a floor.

11. **Confidence calibration** — start `HIGH`, apply policy
    adjustments. Verdict mapping:
    - `HIGH` + no critical baseline failure → `APPROVE`
    - `HIGH` + critical baseline failure → `REQUEST_CHANGES`
    - `MEDIUM` → `COMMENT` with reservations
    - `LOW` → `REQUEST_CHANGES`

12. **Render review body.** Markdown with verdict + summary +
    findings + top risks + calibration notes, AND a hidden HTML-comment
    JSON block at the bottom (see *Output* below).

13. **Post or dry-run.** If `DRY_RUN=true`, prints to stdout and
    exits. Otherwise `gh pr review --approve | --request-changes |
    --comment --body-file <tmpfile>`. The App token in `GH_TOKEN`
    attributes the review to `claude-approver[bot]`.

## Hotfix special case

If the PR title starts with `hotfix:` or `hotfix(...):`, the agent
posts `REQUEST_CHANGES` immediately with a single finding:

> `hotfix:` requires human review. Hotfixes are emergencies and the
> Approver's confidence model is not calibrated for them. A human must
> make the merge call.

This happens **before** any of the procedure above. No risk register,
no calibration. The verdict is fixed.

## Maintenance-bot special case

PRs authored by `claude-maintenance[bot]` (which `/development:maintenance`
opens in Phase 4 of #89) start at `HIGH` confidence and can `APPROVE`
directly when CI is green and there are zero new tool findings. The
maintenance pipeline already ran tests + tool-specific verification on
the worktree before opening the PR, so the Approver's job on those is
mainly a sanity check.

## API stability coupling

The Python Approver couples to
[`#174`](https://github.com/timo-jakob/timos-claude-code-plugins/issues/174)'s
`api-stability` workflow — it reads `griffe-findings.json` from that
workflow's artifact and applies type-aware rules on top of the gate's
binary bypass.

**No equivalent gate exists for Java yet.** A japicmp/revapi-based
binary/source API-compatibility check is the planned analog, but it has
not been built. Until it ships, the Java Approver has no CI artifact to
read at step 4: it records the informational "Java API-stability gate
not configured" finding and moves on. The type-aware coupling described
for Python — where a `refactor:` PR the gate let through with `!` still
earns a finding because `refactor:` is non-negotiably no-break — only
becomes active once the Java gate lands.

| Layer | When breaking changes are allowed | What it checks |
| --- | --- | --- |
| Gate (CI) | Not configured for Java yet | n/a until japicmp/revapi ships |
| Approver (this agent) | Depends on PR type — `feat!:` allows it, `refactor:` does not | Type-aware, but records "gate not configured" until the gate exists |

When the Java gate ships, this table gains the same deterministic-CI /
type-aware-Approver split the Python doc describes. Both layers are
meant to exist on purpose.

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
- <risk 1>
- <risk 2>
- <risk 3>

### Calibration
- Started HIGH.
- Dropped to MEDIUM because <reason>.
- ...

---

<!-- claude-approver:findings
{
  "approver_version": "v1",
  "verdict": "...",
  "confidence": "...",
  "type_detected": "...",
  "findings": [ ... ]
}
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
      "category": "test_quality | api_stability | coverage | baseline | type_ambiguity | feat_no_linked_issue | risk | type_policy",
      "title": "Short headline",
      "detail": "Multi-line markdown explanation citing the policy clause that drove this finding.",
      "suggested_agent": "java-coverage-improver | java-semgrep-triage | java-sonar-triage | java-code-scanning-triage | null",
      "file": "path/to/File.java",
      "line": 42
    }
  ]
}
```

Every JSON finding has a counterpart in the prose; the prose may not
add findings the JSON omits. The JSON is the contract; the prose is
the human view.

### `suggested_agent` mapping

Determines which triage agent `/development:maintenance` dispatches
when re-ingesting findings in Phase 4 of #89:

| Category | Suggested agent | Rationale |
| --- | --- | --- |
| `test_quality` | `java-coverage-improver` | Same skill writes meaningful tests as fixes bad ones |
| `coverage` | `java-coverage-improver` | Direct match |
| `baseline` (Sonar findings) | `java-sonar-triage` | Category matches scanner |
| `baseline` (semgrep findings) | `java-semgrep-triage` | Category matches scanner |
| `baseline` (CodeQL / Code Scanning alerts) | `java-code-scanning-triage` | Category matches scanner |
| `api_stability` | `null` | Gate not configured yet; informational only |
| `feat_no_linked_issue` | `null` | Author needs to link the issue |
| `type_ambiguity` | `null` | Author needs to rename the PR |
| `risk` | `null` | Judgement-only |
| `type_policy` (e.g. hotfix) | `null` | Human review required |

## Hard-fail conditions (refuses to run)

The agent exits non-zero with a clear `stderr` message and **does NOT
post a review** when:

- `.claude/approver-policy.md` is missing.
- `gh` is not on `PATH`.
- `GH_TOKEN` is unset or empty.
- `PR_NUMBER` or `REPO` are unset.

These are operator errors, not PR problems. Surfacing them as review
verdicts would be wrong — the maintainer needs to fix the workflow,
not the PR author.

## Refusal patterns (will NOT do)

- **Never approve a PR not actually evaluated.** If a tool failed
  mid-run (gh, jq, git, gradle), the verdict is `REQUEST_CHANGES` with
  a finding describing the failure, never `APPROVE` with reduced
  confidence.
- **Never post a duplicate review on the same head SHA.** If a previous
  Approver review on the current head SHA already exists, the agent
  exits 0 silently — the gate workflow re-fires per event; we don't
  need redundant reviews.
- **Never modify the PR branch.** The agent is review-only. Even if it
  spots a one-line fix, its output is a finding, not a commit. Pushes
  to PR branches come from `/development:maintenance` (in Phase 4 of
  #89), not from here.
- **Never approve `hotfix:` PRs.** Always `REQUEST_CHANGES` with "human
  review required."

## Cost expectations

Opus, ~50–150 K tokens per PR depending on diff size and how many
test bodies the agent reads. The model is deliberately the
high-judgement tier because the questions (is this test meaningful?
does the implementation match the story? what could still go wrong?)
are not mechanical. The Approver runs only after every other gate is
green, so the per-PR Opus cost is bounded by the rate at which PRs
reach the all-green state — typically once per PR per push, not per
push.

## CI wiring status (read this)

The CI workflow (`.github/workflows/claude-approver.yml`) currently
hardcodes `--agent python-approver`. Making it **select the per-language
approver** (so Java repos invoke `java-approver`) and shipping a Java
`approver-policy.md` template are **bootstrap concerns** — they land in
the Java bootstrap slice (Slice C), tracked separately under
[#307](https://github.com/timo-jakob/timos-claude-code-plugins/issues/307).

What exists **now**: the `java-approver` agent
([`agents/java-approver.md`](../agents/java-approver.md)) and the local
invocation skill `/development-java:approve`, which runs this agent
against an open PR from your workstation and prints the verdict to
stdout instead of posting a review. Pass a PR number explicitly
(`/development-java:approve 123`) or omit it to use the PR for your
current branch.

What follows **later** (the bootstrap slice): the workflow's
per-language agent selection, and the Java `approver-policy.md` template
rendered by `/development:bootstrap`. Until then, full CI wiring for
Java repos is not in place; the `/development-java:approve` skill is the
supported way to run the Java Approver.

## Forward-pointers

- **#307 (Java bootstrap, Slice C)**: per-language agent selection in
  `claude-approver.yml` + a Java `approver-policy.md` template. The
  java-approver agent and `/development-java:approve` skill are ready;
  this slice wires them into CI for Java repos.
- **Phase 4 of #89**: `/development:maintenance` reads the hidden JSON
  block from this agent's most recent review and re-dispatches the
  triage agents listed under `suggested_agent`. The JSON schema above
  is the contract.
- **Phase 5 of #89**: the local `/development-java:approve` slash
  command (shipped) that runs this agent against an open PR from the
  developer's workstation without posting a review. Useful for
  predicting what CI's Approver will say before pushing.
- **#88**: comprehensive user-facing adoption guide, including
  troubleshooting and worked examples.
