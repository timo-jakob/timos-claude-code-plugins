---
name: maintenance
description: >
  Maintenance orchestrator. Runs detection + per-tool findings gathering +
  coverage measurement, constructs the v2 JSON payload, dispatches to the
  matching language plugin and any topic plugins — discovered by gather-script
  convention, so the orchestrator hardcodes no language — and drives a
  sequential per-stage PR cycle (push → CI → merge → sync) until the plan is
  exhausted. The user-facing entry point for "go fix everything you safely
  can on this project."
disable-model-invocation: false
---

You are the maintenance orchestrator. The user invoked you with
`/development:maintenance` (optionally with flags). You drive an entire
maintenance cycle from detection to merged commits.

**User input:** $ARGUMENTS

## Phase 0 — parse flags

Supported flags in `$ARGUMENTS`:

- `--dry-run` — gather everything, construct the payload, **print the
  payload** instead of dispatching. For debugging / inspecting what
  would be sent.
- `--no-merge` — dispatch normally, but skip the auto-merge of worktree
  branches at the end. The user is left with the branches available
  for manual inspection + merge.
- `--tool=<name>` — scope dispatch to a single tool (testing aid).
  `<name>` must be one of: `ruff`, `semgrep`, `code_scanning`,
  `snyk_prs`, `sonarcloud`, `dependabot`, `renovate`, `container_scan`,
  `govulncheck`. The gather phase still runs
  for every tool (the payload stays complete), but the language plugin
  only spawns the agent(s) for the chosen tool. Other agents are
  skipped entirely — no work, no missing-tool recommendation.
  (`govulncheck` is Go-only — the Go vuln source of truth, #876 — just as
  `ruff` is Python-only.) Combinable with `--dry-run` and `--no-merge`.
- `--concern=<name>` — scope dispatch to a whole **concern** (a named
  group of tools); the coarse-grained sibling of `--tool`. `<name>` must
  be one of:
  - `security` → `snyk_prs`, `code_scanning`, `semgrep`, `container_scan`, `govulncheck`
  - `dependencies` → `dependabot`, `renovate`
  - `codequality` → `sonarcloud`, `ruff`

  It expands to that tool set and scopes dispatch exactly like `--tool`,
  just to several tools at once — the gather phase still runs for
  everything, only dispatch is narrowed. Combinable with `--dry-run` and
  `--no-merge`; **mutually exclusive with `--tool`** (pass one or the
  other). The three concerns partition all nine tools, so
  `--concern=security` + `--concern=dependencies` + `--concern=codequality`
  together cover the same set as an unscoped run.
- `--batch=N` — cap how much of the plan this run processes. After the
  language plugin's planner ranks the findings into groups (one PR / stage
  each), process only the **top N groups by priority**, deferring the rest
  to a later run. `N` must be a positive integer. This is the lever that
  keeps a multi-PR run tractable under `strict` branch protection, where
  every merged PR re-stales every other open one (see Phase 8's ordering
  note — bounding the batch is why #53 is cross-referenced there).

  **The unit is a planner group / PR / stage, not an individual finding.**
  The planner keeps a tool's findings together — it never subdivides a
  tool (see `development-python/agents/python-maintenance-planner.md` § 3)
  — so a group is the smallest reviewable unit, and "top N" is "the N
  highest-priority groups." **Stage 0 (the coverage pre-flight) is never
  counted** against the batch — it's a prerequisite, not a discretionary
  group. Combinable with `--tool` / `--concern` (those scope *which* tools
  are eligible; `--batch` then caps *how many* of the ranked groups run),
  `--no-merge`, and `--dry-run` — but under `--dry-run` the planner never
  runs (Phase 5 stops before dispatch), so `--batch` can only *annotate*
  what a live run would cap to, not select groups. Default when absent:
  process the entire plan, exactly as before.
- `--no-issues` — suppress the GitHub-issue trail (Phase 10). By
  **default** every real run leaves an issue trail for the changes it makes or
  proposes — per-tool scanner debt issues *and* tracking issues for PR-cycle
  outcomes (deferred vendor PRs, escalated stages, applied suppressions) — so no
  change vanishes into the run summary alone (#384). Pass `--no-issues` to skip
  that phase entirely (e.g. a quick scoped run where you don't want issue churn).
  Issue creation is also skipped under `--dry-run` (a dry run performs no
  outward actions). `--track-as-issues` is accepted as a **deprecated no-op**
  (issue tracking is now the default) — warn that it's no longer needed and
  proceed.
- `--resume` / `--fresh` — control the **resume entry** (below) when a
  checkpoint from an interrupted run exists: `--resume` continues from the
  last completed phase without asking; `--fresh` discards the checkpoint
  and starts over. Mutually exclusive (halt if both). Rejected together
  with `--dry-run` — a dry run neither writes nor consumes checkpoints.

Anything else: surface the input to the user as "unrecognized
arguments" and stop.

When `--tool=<name>` is set, validate `<name>` against the known set
above before proceeding. On a mismatch, halt with: "Unknown --tool
'`<name>`'; supported: ruff, semgrep, code_scanning, snyk_prs,
sonarcloud, dependabot, renovate, container_scan, govulncheck."

When `--concern=<name>` is set, validate `<name>` against `security`,
`dependencies`, `codequality`. On a mismatch, halt with: "Unknown
--concern '`<name>`'; supported: security, dependencies, codequality."
Expand it to its tool set (above) and carry that set forward as the
dispatch scope — Phase 4 writes it into `dispatch_filter.only_tools`
exactly as it does for `--tool`. If **both** `--tool` and `--concern`
are passed, halt with: "Pass --tool or --concern, not both."

When `--batch=N` is set, validate that `N` parses as an integer ≥ 1. On a
mismatch (non-numeric, zero, or negative), halt with: "Invalid --batch
'`<value>`'; expected a positive integer (e.g. --batch=5)." Carry `N`
forward as the **batch cap** applied in Phase 8's Stages 1..N. `--batch` is
orthogonal to `--tool` / `--concern` — it does not touch the payload or the
`dispatch_filter`; it only bounds how many of the planner's ranked groups
the PR cycle processes.

### Resume entry — pick up an interrupted run (#517)

A full run is long, and until #517 all orchestrator state lived only in the
conversation — an API/token interruption lost the run. Each phase below now
persists its result through the blessed store
(`"<skill-base-dir>/scripts/checkpoint.zsh"` — `save`/`load`/`status`/
`clear`/`dir`; state lives in the target repo's
`.git/claude-maintenance/`, outside the working tree and shared across
worktrees, so it survives the session). Before Phase 1, check for one:

```bash
"<skill-base-dir>/scripts/checkpoint.zsh" status   # exit 3 = none
```

- **No checkpoint (exit 3)** → proceed to Phase 1 normally.
- **Checkpoint exists** → judge staleness first: `age=` beyond ~24h, or
  `git rev-parse origin/<default>` no longer matching the `base_sha`
  recorded in `phase1-detect`, means the world moved — **recommend
  `--fresh`** but honour an explicit `--resume`. Then:
  - **`--resume`** (or the user picks resume) → skip every phase the
    checkpoint records: reload each phase's data with
    `checkpoint.zsh load --phase <name>` and re-read copied artifacts
    from `checkpoint.zsh dir` (never from `/tmp` — it didn't survive).
    Restore the **recorded flags**: a resumed run keeps its original
    scope; if this invocation passes a *different* `--tool`/`--concern`/
    `--batch`, halt — changing scope requires `--fresh`. Continue at the
    first phase not recorded; phases without a checkpoint of their own
    (2, 5, 7) are cheap derivations — re-run them from the restored
    state. Phase 8's per-stage resume additionally reconciles against
    GitHub reality (#536).
  - **`--fresh`** (or the user picks fresh) → `checkpoint.zsh clear`,
    then Phase 1 as normal.
  - **Neither flag** → ask the user: resume from `last=<phase>` or start
    fresh (name the checkpoint's age and phases).
- **`--dry-run`** never writes checkpoints and never offers resume — it
  performs no outward actions and must not leave state a later real run
  would resume into.

The checkpoint writes below are one-liners at each phase boundary and are
**best-effort**: if a save fails, warn and continue — the checkpoint is a
recovery aid, never a gate.

## Phase 1 — detect

Run the detection script and capture its JSON:

```bash
"<skill-base-dir>/../bootstrap/scripts/detect-stack.sh" > /tmp/detect.json \
  || { echo "detection aborted — forward its stderr, do not read detect.json"; exit 1; }
```

`<skill-base-dir>` is `development/skills/maintenance/`; the bootstrap
scripts live one directory up. Use the resolved absolute path.

**Check the exit status before parsing (#1177).** A non-zero exit means
detection could not complete and `/tmp/detect.json` is **empty** — the script
names the reason on stderr (today: a kubernetes marker search that could not
finish, which refuses to report `is_kubernetes: false` for a tree it could not
read). **Halt and forward that stderr verbatim.** Do **not** run the validations
below against an empty document: every key reads as absent, so `git_initialized`
is not `true` and the run would tell a user with a perfectly healthy repository
to `git init` — a confidently wrong instruction derived from a document that
was never written.

**Do not diagnose the cause beyond what the stderr says.** Every copy of the
marker runs `find … 2>/dev/null` and `grep … 2>/dev/null`, so the OS-level
message (*Permission denied* vs *No such file or directory*) is discarded, and
`find` exits `1` for both — a transient vanished file and a permanently
unreadable tree are **not distinguishable** from the evidence you have. Forward
the stderr verbatim, say that, and give the one decidable instruction: re-run
once; if the same statuses recur the cause is **most likely** permissions, so
have the user check them on the paths the search covers. Say "most likely" and
not "the tree is unreadable" — a tree being written throughout both runs (an
installer populating `node_modules`, a background `git gc`) reproduces the same
statuses. Never assert "transient, just re-run" either: on an unreadable tree
that is an unbounded retry loop dressed up as a diagnosis.

Validate from `detect.json` (only after a zero exit):

- `git_initialized == true` — if not, halt: "Maintenance needs a git
  repo (worktree-based agents require it). Initialize with `git init`
  and re-run."
- `languages` is non-empty — if not, **do not halt here.** Carry the empty set
  into Phase 2 and let its Proceed/halt gate decide, because that gate is the
  single halting authority and it halts only when **both** `supported` and
  `supported_topics` are empty. A language-less repo is not necessarily an
  unworkable one: `kubernetes` and `docs` are registered *language-agnostic*
  (Required language `none`), and a GitOps repo with no application language is
  precisely the case the kubernetes topic exists for — halting on it here would
  make that topic permanently undispatchable. **Phase 2 owns the message**; it is
  written there, beside the halt that emits it.

Extract for use in later phases: `repo` (path = cwd from script),
`default_branch`, `visibility`, `language_meta` (the nested
per-language block — e.g. `language_meta.python.version`,
`language_meta.java.version`, when applicable),
`languages` (the array — could be **empty**, one, or more; the empty case is
carried to Phase 2's gate rather than halted on here).

### Read the maintenance declaration (primary / auxiliary)

Read the optional repo-root `.maintenance.yml`. It declares the repo's
**primary** stack (its reason to exist) — set by `/development:bootstrap`, never
inferred. Read the `primary` scalar dependency-free (don't assume `yq`):

```bash
primary=$(grep -E '^[[:space:]]*primary:' .maintenance.yml 2>/dev/null | head -1 \
  | sed -E 's/^[[:space:]]*primary:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^["'\'']//; s/["'\'']$//')
```

This sets each dispatch's **mode** (carried in Phase 4's payload as
`dispatch_mode`):

- **`primary` present** → the matching language/topic dispatches in **full**
  mode (`dispatch_mode: "primary"`); every *other* detected language/topic
  dispatches in **auxiliary** mode (`dispatch_mode: "auxiliary"` —
  mechanical/lint-level only, no app-grade gates).
- **absent / empty** → backward-compatible: no primary/auxiliary distinction;
  **every** target dispatches as `primary` (full), exactly as before.

`primary` names a language (`python`) or a topic (`claude-plugin`). If it isn't
in the detected+supported set, treat all targets as `primary` and note the stale
declaration in the Phase 9 summary. See ARCHITECTURE.md § "Primary / auxiliary
model" for the rationale.

**Checkpoint `phase1-detect`** (skip under `--dry-run`): save the detection
result — everything later phases derive from — plus `base_sha` (the resume
entry's staleness reference) and this run's flags (a resume restores them):

```bash
print -r -- "{\"languages\":[…],\"topics\":[…],\"primary\":\"…\",\"default_branch\":\"…\",
  \"flags\":{…},\"base_sha\":\"$(git rev-parse origin/<default>)\"}" \
  | "<skill-base-dir>/scripts/checkpoint.zsh" save --phase phase1-detect --data -
```

## Phase 2 — discover which languages we can act on

Maintenance support is gated by **gather script presence**. For each
detected language, check whether the matching gather script exists:

```bash
test -x "<skill-base-dir>/scripts/gather-<lang>-findings.sh"
```

The naming convention is strict: `gather-<lang>-findings.sh` (e.g.,
`gather-python-findings.sh`). When a new language plugin lands in this
repo, its sibling gather script is what makes it discoverable here.

Partition `languages` into:

- **`supported`** — detected AND a matching gather script exists
- **`unsupported`** — detected BUT no gather script (i.e., no
  `development-<lang>` plugin built yet)

If `supported` is non-empty but `unsupported` is also non-empty,
proceed with the supported set; remember `unsupported` to include in
the final summary as an informational note ("Detected `<X>`, `<Y>` but
their plugins are not built yet — only `<Z>` findings were processed").

### Topics (cross-language concerns)

Topic plugins dispatch **alongside** languages — a repo can be Python *and* a
Claude plugin, and both get processed. They're gated by gather-script presence
just like languages, but triggered by a **topic marker** rather than a language
manifest. Known topics:

| Topic | Marker (present in repo) | Gather script |
| --- | --- | --- |
| `claude-plugin` | a `.claude-plugin/` dir holding `plugin.json` (an individual plugin) **or** `marketplace.json` (a marketplace of plugins, like this repo) | `gather-claude-plugin-findings.zsh` |
| `spring` | an `org.springframework.boot` Gradle plugin **or** a `spring-boot-starter-*` dependency in `build.gradle.kts` (composes alongside `java` — only meaningful when Java is also detected) | `gather-spring-findings.zsh` |
| `docs` | a `docs/architecture/` **directory** (the C4 architecture docs home — language-agnostic, so it composes with any language, or none) | `gather-docs-findings.zsh` |
| `react` | `react` in the **`dependencies`** (runtime, **not** `devDependencies`) of **any** `package.json`, monorepo-aware, under `detect_lang`'s prune set (`node_modules`, `.git`, `vendor`, `.build`, `dist`, `templates`). Requires `jq`; **requires language `javascript`** | `gather-react-findings.zsh` |
| `kubernetes` | a Helm `Chart.yaml`, a Kustomize manifest (`kustomization.yaml`, `kustomization.yml` or `Kustomization` — all three spellings kustomize accepts), **or** a file containing `argoproj.io` — language-agnostic, so it composes with any language, or none | `gather-kubernetes-findings.zsh` |

**Detecting a marker — use these exact recipes, don't improvise.** A
*file-presence* marker (the `claude-plugin` dir) is robust to test with
`test -e`. The **content** markers (`spring`, `react`, and the
`argoproj.io` half of `kubernetes`) must look *inside*
files — `spring` greps `build.gradle.kts`, `react` reads `package.json`
with `jq`. Kotlin DSL only (#343) — the family maintains
`build.gradle.kts`, so the marker greps only that; a Groovy/Maven repo is
detected as `java` (so the dispatcher halts it) but does **not** compose
Spring. Grep recursively with an `--include` filter over `.` — never pass a
possibly-absent file as a bare `grep` argument (a missing file makes grep
exit non-zero and can mask a genuine match):

```bash
# claude-plugin marker (file presence — robust):
test -f .claude-plugin/plugin.json || test -f .claude-plugin/marketplace.json

# spring marker (content; --include over '.' tolerates an absent build file):
grep -REl --include='build.gradle.kts' \
  'org\.springframework\.boot|spring-boot-starter-' . \
  2>/dev/null | grep -q .

# docs marker (directory presence — robust):
test -d docs/architecture

# react marker: `react` in the DEPENDENCIES of ANY package.json (monorepo-aware).
# THREE-WAY verdict — 0 = React, 1 = not React, 2 = COULD NOT EVALUATE. The third
# outcome is why the jq check is part of the recipe rather than advice beside it:
# with jq missing the pipeline would emit nothing and read as a confident "no".
# `( exit 2 )` yields status 2 without terminating a caller that sourced/eval'd this.
#
# The prune list mirrors detect-stack.sh's `detect_lang` exactly, so the marker and
# the `javascript` language detector agree about which tree they search. `-prune`
# (not `-not -path`) so pruned dirs are never DESCENDED into. `! -type d` so a
# DIRECTORY named package.json is never handed to jq, while a symlinked manifest —
# which `detect_lang` matches by name — still counts.
# Per-file `-exec … \;` — never `+`: one batched jq call ABORTS at the first
# unparseable package.json and skips every remaining file in that batch, so a
# single malformed manifest could mask a real match.
# The verdict is CAPTURED, not piped: `find … | grep -q .` inverts under
# `set -o pipefail`, because grep short-circuits on the first hit, the next jq child
# dies on SIGPIPE, and find then reports non-zero — turning a genuine match into
# "no React". Capturing the output and testing it is pipefail-safe.
# react-marker:begin
if ! command -v jq >/dev/null 2>&1; then
  printf 'react-marker: UNEVALUATED (jq not on PATH)\n' >&2
  ( exit 2 )
else
  react_hits="$(find . -mindepth 1 \
    -path '*/node_modules' -prune -o \
    -path '*/.git' -prune -o \
    -path '*/vendor' -prune -o \
    -path '*/.build' -prune -o \
    -path '*/dist' -prune -o \
    -path '*/templates' -prune -o \
    -name package.json ! -type d \
    -exec jq -er '.dependencies.react // empty' {} \; 2>/dev/null)" || true
  [ -n "$react_hits" ]
fi
# react-marker:end

# kubernetes marker (file presence OR content; prune vendored trees).
# A PREDICATE, like every recipe above — its EXIT STATUS is the verdict, and the
# partition step below does the registering. Never make a recipe register the
# topic itself: a side-effecting `if … fi` exits 0 whether or not the marker
# fired, so a caller reading `$?` uniformly across these recipes would detect
# the topic on every repo.
# Capture before filtering: `find | grep -q` loses the match to SIGPIPE under
# `set -o pipefail`, which every maintenance script sets.
# `! -type d` for the same reason the react recipe carries it: a DIRECTORY named
# `Kustomization` is not a manifest, while a symlinked one still counts.
#
# THREE exit statuses, not two (#1177): 0 = kubernetes, 1 = searched and found
# nothing, 2 = COULD NOT LOOK. The old single `|| true` spanned the whole
# `find | grep -v` chain, so a find that died mid-run and a repo with no charts
# were the same answer — "could not look" rendered as "looked and found
# nothing", a silent false negative. Each search's status is captured
# SEPARATELY now, and an unfinished search taints only the NEGATIVE verdict: a
# hit is a hit regardless of an unreadable sibling directory (which is why the
# argoproj-only-plus-locked-subtree repo still reports 0), while "no" is only
# ever reported when both halves genuinely completed.
# kubernetes-marker:begin
k8s_hits="$(find . \( -name Chart.yaml -o -name kustomization.yaml \
                       -o -name kustomization.yml -o -name Kustomization \) \
                 ! -type d 2>/dev/null)" && k8s_find_rc=0 || k8s_find_rc=$?
# the filter reads the captured string, never the filesystem, so it cannot fail
# for a reason the verdict should care about; `|| true` absorbs its no-match 1
k8s_hits="$(printf '%s\n' "$k8s_hits" \
  | grep -v -e /node_modules/ -e '/\.git/' -e /vendor/ -e /templates/ || true)"
k8s_argo_rc=1
if [ -z "$k8s_hits" ]; then
  grep -rqlF 'argoproj.io' \
    --include='*.yaml' --include='*.yml' \
    --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git \
    --exclude-dir=templates . 2>/dev/null && k8s_argo_rc=0 || k8s_argo_rc=$?
fi
if [ -n "$k8s_hits" ] || [ "$k8s_argo_rc" -eq 0 ]; then
  true
elif [ "$k8s_find_rc" -ne 0 ] || [ "$k8s_argo_rc" -ge 2 ]; then
  printf 'kubernetes marker: search did not complete (find %s, grep %s) — refusing to report "not kubernetes"\n' \
    "$k8s_find_rc" "$k8s_argo_rc" >&2
  ( exit 2 )
else
  false
fi
# kubernetes-marker:end
```

`( exit 2 )` rather than a bare `exit 2`: the recipe is a **predicate**, and an
`exit` in a snippet the orchestrator pastes into its own shell would kill that
shell instead of yielding a verdict. A subshell yields the status without the
side effect.

**The `kubernetes-marker:begin`/`:end` sentinels are load-bearing**, exactly as
react's are: `tests/kubernetes-topic-marker.bats` extracts the text between them
and executes it, so the suite tests *this* recipe rather than a copy of it, and a
second test derives the recipe's marker names and prune set from
`gather-kubernetes-findings.zsh` — and, since #1153, from
`development/skills/bootstrap/scripts/detect-stack.sh`'s `is-kubernetes-marker`
block, a FOURTH copy of this recipe — and requires all of them to agree. Keep
the whole recipe between them, and keep them a single unique pair.

**The `react-marker:begin`/`:end` sentinels are load-bearing**, not decoration:
`tests/react-topic-marker.bats` extracts exactly the text between them and executes
it, so the suite tests this recipe rather than a copy of it. Keep the whole recipe
between them, and keep them a single unique pair.

The `spring` topic is **only meaningful when `java` is also detected** —
require both before composing `development-spring`. The `docs` topic has no such
language gate: `docs/architecture/` is language-agnostic (every bootstrapped repo
can have one), so it composes with any detected language — or on its own. Its
marker is the **directory**, not `docs/architecture/c4-container.md`: tying the
whole topic to one tool's artifact would fail to dispatch a repo that has docs
concerns but no container diagram yet, and any second docs tool would have to
widen the marker retroactively. `tooling_configured.c4_drift` is deliberately the
**same** predicate — the presence of `docs/architecture/` — rather than a narrower
"is there a diagram?" gate: when the directory exists but `c4-container.md` is absent
or unparseable, the gather degrades to an empty finding list **plus a note**, never
to `configured: false` (#793).

The `react` topic (#956) is **only meaningful when `javascript` is also
detected** — require both before composing `development-react`, exactly as `spring`
requires `java` (#296 decision #1). That gate is **enforced in the partition step
below, not merely stated here** — see *Required language*, which also explains why it
must not rely on the marker's prune set staying in sync. Three deliberate narrowings
in its recipe:

- **Runtime dependencies only.** `react` in `devDependencies` alone means React
  *tooling* (a linter plugin, a component-test harness in a repo that ships no React
  app), not a React application — dispatching the framework topic there would review
  a codebase that has no components. So the recipe reads `.dependencies.react`, and
  **never** `.devDependencies.react` or `.peerDependencies.react` (the latter is the
  shape of every published React *component library*, which is a dependency of React
  apps rather than one itself).
- **Monorepo-aware.** A JS monorepo is as ordinary as a Gradle multi-project build,
  so the recipe searches **every** `package.json` rather than only the root one — a
  repo whose React app lives in `packages/web/` must match.
- **Pruned to `detect_lang`'s exact tree.** The recipe prunes `node_modules`, `.git`,
  `vendor`, `.build`, `dist` and `templates`, with `-mindepth 1`, because that is
  precisely what `detect-stack.sh`'s `detect_lang` prunes. Two independent reasons.
  First, `node_modules` must go: React is a transitive dependency of countless
  packages, so matching there would dispatch the topic for virtually any installed JS
  repo — the false positive most likely to make users distrust topic detection.
  Second, and less obvious, **any divergence from `detect_lang`'s set breaks the
  language gate**: a `package.json` under `templates/` or `dist/` would fire the
  marker while `javascript` was *not* detected, so the topic could compose onto a repo
  detection calls non-JS. That is not hypothetical here — #957 ships React bootstrap
  templates under a `templates/` tree, which would otherwise make this very plugin
  repo match the React marker. **If `detect_lang`'s prune list ever changes, change
  this recipe in the same PR.** `-mindepth 1` is copied verbatim so the two
  expressions stay diff-identical — but note it is a **no-op here**: `detect_lang`
  needs it because it searches an *absolute* `$cwd`, whose own basename can match
  `*/templates`, whereas this recipe starts at the literal `.`, which matches no
  prune pattern at any depth. Keep it for parity (and in case the recipe ever gains
  a start-path argument); do not cite it as protection this form actually needs.

**`jq` is a prerequisite of this marker, and its absence is not a verdict.** `react`
is the only topic marker that shells out to a tool which may be **missing**
(`claude-plugin`/`docs` use `test`, `spring` uses `grep`) — it is *not* the only
one that can fail to reach a verdict: `kubernetes` reaches the same
not-evaluated state from a search that could not complete, and signals it with
its own exit `2` rather than a preflight (#1177). Both land in the same
`unsupported_topics` bucket, by the three-way `$?` rule in the partition step
below. Because the recipe's
verdict is "did anything reach stdout", a missing `jq` produces no output and would
otherwise read as a confident **"this is not a React repo"** — silently skipping a
whole topic with nothing in the summary to say so. The `command -v jq` check is
therefore **the recipe's own first statement**, not advice beside it: when it
fails the recipe emits that reason on stderr and yields **2**, which the
partition step's three-way rule routes to **`unsupported_topics`** with the note
`jq not on PATH: the React marker could not be evaluated`. Do **not** record a
negative, and do not run the check a second time yourself — the Phase 9 summary
then reports a topic that was never evaluated rather than one evaluated as
absent. A **malformed**
`package.json` is a different case and *is* a deliberate non-match: `jq` fails on it,
the recipe emits nothing for that file, and the traversal continues to the others.

Use `-exec … \;` (**per file**) rather than `-exec … +` (one batched call). The
reason is *not* jq's exit status — nothing reads it; the **captured** stdout
(`[ -n "$react_hits" ]`) is the verdict, which is also why `-e` is belt-and-braces
rather than load-bearing. The real
reason is failure isolation: **a batched `jq` aborts at the first unparseable
`package.json` and skips every remaining file in that batch**, so one malformed
manifest sorted before the real one would turn a genuine React repo into a non-match.
Per-file execution contains that failure to the file that caused it.

Finally, `find` runs with its default `-P` (symlinks not followed), so a monorepo
whose app directory is a *symlink* is not traversed. This is a deliberate trade, not
an oversight: `-L` would follow the pnpm/yarn `node_modules` symlink farms the prune
list exists to avoid, and can loop.

The `kubernetes` topic (#1152) has **no** language gate — like `docs`, and unlike
`spring`/`react`. Charts and overlays are language-agnostic, so the topic composes
with any detected language, or with **none at all**: a GitOps repo declaring
`primary: kubernetes` is exactly the case it exists for, and requiring a language
would make that repo undispatchable. Two things about its marker are deliberate:

- **It is not "any YAML with `apiVersion`".** That would match half the repos in
  existence — every GitHub Actions workflow, every OpenAPI document. The marker is
  a Helm `Chart.yaml`, a Kustomize `kustomization.yaml` (all three spellings
  kustomize itself accepts — `kustomization.yaml`, `kustomization.yml`,
  `Kustomization`), or the literal string `argoproj.io`, which no non-Argo file
  carries by accident.
- **The find output is captured before it is filtered.** `find … | grep -q` looks
  equivalent but inverts under `set -o pipefail`: `grep -q` exits at its first
  match, `find` — still writing — dies of SIGPIPE, and the pipeline reports
  non-zero even though a chart *was* found. It fails only on repos whose `find`
  output outruns the pipe buffer, which is the worst possible failure mode.
  Capture, then test the variable.

All four copies — the marker, `gather-kubernetes-findings.zsh`, the manifests
lister below, and detect-stack.sh's `is-kubernetes-marker` block (#1153) — prune
`node_modules`, `.git`, `vendor` and `templates`; the last one matters here,
since this very repo ships chart *templates* under bootstrap's `templates/`
tree.

**`gather-docs-findings.zsh` landed in #793**, so `docs` is a **supported** topic
whenever its marker fires: #801 stood up the `development-docs` dispatcher and this
marker, and #793 added the gather plus the `c4_drift` tool. Never hard-code a topic's
supported/unsupported status from prose like this paragraph — the `test -x` partition
below is the single authority, and it is what decides on every run.

For each known topic whose marker **evaluated as present**, check for its gather
script:

```bash
test -x "<skill-base-dir>/scripts/gather-<topic>-findings.zsh"
```

**"Evaluated as present" is a three-way read of `$?`, not a two-way one.** A
marker recipe answers `0` = present and `1` = absent — but a recipe that could
not finish its search answers with **neither**, and reading its status as
"absent" is precisely the *could-not-look-rendered-as-nothing-found* failure.
**Two markers signal it today; the others cannot yet**, so read the `1` row
below as *provisional* for them:

| `$?` | Meaning | What the partition does |
| --- | --- | --- |
| `0` | marker present | continue below (gather script, required language) |
| `1` | marker absent | the topic is not this repo's — drop it, silently and correctly |
| anything else | **the marker was not evaluated** | `unsupported_topics`, with the recipe's own stderr as the note — **never** the absent bucket |

- **`kubernetes` exits `2`** when both halves of its search came up empty and at
  least one of them did not finish (#1177) — an unreadable subtree, a `find`
  killed mid-run, a `grep` that exited `2`. Note it as
  `kubernetes marker: search did not complete — the topic was not evaluated`,
  quoting the recipe's stderr, which names which half failed.

  **In practice Phase 1 usually catches this first, and that is by design.**
  `detect-stack.sh` runs a **parity-pinned** copy of this marker in Phase 1 —
  same filename set, prune set, `--exclude-dir`/`--include` tokens and the same
  three-way ladder, as `tests/kubernetes-topic-marker.bats` derives — and aborts
  the whole run on the same condition, because *its* answer is a boolean in a
  JSON document with no third state to say "unknown". (Parity is over those
  tokens and that ladder, **not** byte-equality: detect-stack's copy also carries
  `cd`/`exit 125` branches, which must never be pasted into the recipe above —
  `$cwd` does not exist there and a bare `exit` would kill the orchestrator's
  shell, which is what the `( exit 2 )` note exists to prevent.)

  So the ordinary outcome for an unreadable GitOps tree is the Phase 1 halt, with
  detect-stack's stderr forwarded. This row is not therefore dead: it covers the
  **residual** cases — a tree that becomes unreadable *between* the two searches,
  a run resumed from a post-detection checkpoint, or any future caller that
  reaches Phase 2 with a detection this phase did not perform. Two guards on one
  hazard, at different altitudes; never treat the topic-level one as redundant
  and delete it.
- **`react`'s** missing-`jq` case is the same shape reached a different way (its
  preflight below), and is noted the same way.

- **The other markers cannot signal it.** `claude-plugin`/`docs` use `test` on a
  path, which does not read a tree. `spring`'s recipe pipes
  `grep -REl … 2>/dev/null` into `grep -q .`, so the first grep's operational
  exit `2` becomes *no output* and the pipeline's status is the trailing grep's
  `1` — an unreadable subtree holding the only `build.gradle.kts` is
  indistinguishable from a non-match there. `react`'s find half has the same
  blind spot. It is the same defect #1177 removed from the kubernetes copies,
  still open in theirs (their own issue, not this one's).

  **Still take the `1` row for them.** This caveat documents a known blind spot
  for the next reader; it is **not** a partition rule, and it licenses no
  different action. A marker that cannot signal *not-evaluated* must never be
  recorded as not-evaluated — doing so would put `spring` in
  `unsupported_topics` on every Java repo that simply has no Spring, and Phase 9
  and the halt branch would print that permanent false "we could not tell"
  verbatim. Only a marker that actually exits non-0/1 takes the third row.

The rule is general because the failure is: a topic dropped from **both** buckets
never reaches Phase 9 at all, so a repo whose GitOps content could not be read
would be reported exactly like a repo that has none.

Partition into **`supported_topics`** (marker present AND gather script exists AND
any **required language** is in `supported`) and **`unsupported_topics`** (marker
present, but one of those failed — or the marker was not evaluable). Note topic
gather scripts are zsh (`.zsh`); the language ones are bash (`.sh`).

**Required language — the gate, enforced here.** A topic may require a language;
this is the single place that requirement is applied, so it can't be stated in the
marker prose and then quietly skipped:

| Topic | Required language |
| --- | --- |
| `claude-plugin` | none |
| `docs` | none |
| `kubernetes` | none |
| `spring` | `java` |
| `react` | `javascript` |

**Each `unsupported_topics` entry is `{topic, note}`** — the note says *which*
condition failed, because Phase 9 renders it verbatim and "we couldn't tell" must
never be reported as "nothing to do". The same shape applies to an `unsupported`
**language** entry. Three conditions are decided here in the partition; three more
producers write into the same bucket later (Phase 3's gather, Phase 4's manifest
listing, Phase 6's dispatch), so treat this table as open, not closed:

| Condition that failed | Note |
| --- | --- |
| no gather script | `no gather-<topic>-findings.zsh yet` |
| required language absent | `marker present but required language <lang> is not in the supported set (not detected, or no gather script)` |
| marker not evaluable | the marker's own reason — a preflight's (`jq not on PATH: the React marker could not be evaluated`) or a recipe's own stderr on a non-0/1 exit (`kubernetes marker: search did not complete — the topic was not evaluated`) |
| gather failed (Phase 3) | `gather failed: <error>` |
| manifest listing did not complete (Phase 4) | `manifest listing did not complete: <stderr>` |
| dispatch failed (Phase 6) | `dispatch failed: <error>` |

A topic in this bucket is never silently dropped and never dispatched. Note the
middle condition is `<lang>` **not in `supported`** — which is stricter than "not
detected", since `supported` also requires that language's gather script.

**Why the gate is enforced here rather than trusted to the marker.** With the recipe
pruning exactly `detect_lang`'s tree, a marker hit without its language is not
reachable *through that route* today. The gate exists because `supported` is stricter
than *detected*, and because any future drift between the two prune sets would make
it reachable — the gate must not depend on the two staying in sync.

### Proceed / halt

If **both** `supported` (languages) and `supported_topics` are empty, halt —
but **print every `unsupported` / `unsupported_topics` entry with its note
verbatim first**. Phase 9 never runs on this branch, so it is the only place
those notes can reach a human, and a bucket nothing renders is the silent drop
the partition step's "never silently dropped" rule forbids. Say explicitly when
an entry is a **not-evaluated marker** — *"the kubernetes marker search did not
complete; that is not a verdict that this repo has no charts"* — because the
reachable case is a GitOps-only repo with no detected language and an unreadable
subtree, which is precisely the repo the topic exists for: without this, it is
reported identically to a repo that genuinely has none. Then give what *was*
detected and point at the README's Plugins section.

**The wording is keyed on `unsupported_topics` alone**, because that is the
bucket the false-absence hazard lives in — a *language* in `unsupported` says
nothing about whether a topic marker fired:

- **`unsupported_topics` is empty** — no marker was present and none failed to be
  evaluated, so absence *is* the finding: *"No supported languages detected
  (swift / javascript / python / go / java) and no topic markers present. If
  your project uses one of these, ensure manifest files (pyproject.toml,
  package.json, build.gradle, etc.) are present."*
- **`unsupported_topics` is non-empty** — **never say "no topic markers
  present".** Something was present, or could not be evaluated, and the entries
  printed above say which: *"No supported languages detected, and the topics
  listed above were either detected but not processable, or could not be
  evaluated — see their notes."* Asserting absence here would contradict the
  not-evaluated note printed three lines earlier, on the very repo this halt
  exists to serve.

**Independently of that choice**, when `unsupported` (languages) is non-empty,
append *"…and the languages listed above have no plugin or gather script yet."*
The two buckets are separate facts; neither wording may swallow the other.

Otherwise proceed with whatever is supported, and carry any
`unsupported` languages / `unsupported_topics` into the Phase 9 summary as
informational notes ("Detected `<X>` but its plugin isn't built yet — not
processed").

## Phase 2.5 — Approver feedback ingestion (when Claude Apps registered)

Closes the loop between the **Claude Approver** (which posts
`REQUEST_CHANGES` reviews on PRs with a hidden JSON block of findings)
and the language-plugin triage agents that can fix those findings.

When the Approver posts `REQUEST_CHANGES` on a PR, the user re-runs
`/development:maintenance` to ingest the feedback. This phase finds the
flagged PRs, dispatches agents to fix what's auto-fixable, and pushes
the fixes back to the PR branches. CI re-runs on the new head (a plain
user-identity push's `synchronize` runs it; a bot **App-token** push's
does **not** — #605 — so the CI cycle re-triggers it deterministically,
see § *Re-trigger CI after a bot re-push* below). The Approver then
re-evaluates: in **`ci` mode** automatically on the next
`check_suite: completed` event; in **`local` mode** when the approve
skill is next driven (the approval gate does that per stage). The loop
closes without further user intervention.

**Skip silently** when `~/.config/claude-plugins/apps.json` doesn't
exist — the Approver isn't set up on this machine, there's nothing
to ingest. (The **approver-mode detection** just below still runs — it
is a pure read and records `none` in that case.)

### Approver mode — detect once per run (#642)

The Approver runs one of two ways, and the approval gate (Phase 8) must
know which so it doesn't wait on a workflow that isn't there. Detect the
mode **once**, near the start of the run — this is a pure read, so it
runs regardless of `--dry-run` or the skip above — and record it in the
checkpoint so every stage's gate reads the same value:

- **`ci`** — a CI-side Approver workflow exists in `.github/workflows/`
  (pre-#476 `claude-approver.yml`, or any workflow that posts the
  Approver verdict on `check_suite: completed`). The gate re-triggers it
  with a `/approve` comment.
- **`local`** — the Approver App is registered locally (`apps.json` has
  `claude_approver`) but there is **no** CI-side workflow — the
  decentralized default since epic #476 (deployed 2026-07-02). The gate
  drives the language plugin's `approve` skill directly; a `/approve`
  comment would only be noise posted under the user's identity, and
  waiting for a server-side verdict that never comes burns ~10 minutes
  per stage (#642).
- **`none`** — no `claude_approver` entry at all: the Approver isn't
  available here; the gate falls back to a human review / native
  auto-merge as it does today.

```bash
mode=none
if [[ -f ~/.config/claude-plugins/apps.json ]] \
   && jq -e '.claude_approver' ~/.config/claude-plugins/apps.json >/dev/null 2>&1; then
  # Registered locally → default to the decentralized model (#476): local.
  mode=local
  # Promote to ci ONLY on the pre-#476 CI-gate signature: a workflow that both
  # references the Approver AND is triggered by check_suite. Bias matters here:
  # a false 'local' is harmless (driving the approve skill works everywhere),
  # but a false 'ci' waits on a workflow that isn't there (#642) — so ci needs
  # the stronger, two-signal match, not a bare name mention (a leftover comment
  # or bot-login check must not flip the mode).
  while IFS= read -r wf; do
    if grep -q 'check_suite' "$wf"; then mode=ci; break; fi
  done < <(grep -rlsE 'claude-approver|approver-gate' .github/workflows 2>/dev/null)
fi
print -r -- "{\"approver_mode\": \"$mode\"}" \
  | "<skill-base-dir>/scripts/checkpoint.zsh" save --phase approver_mode --data -
```

Read it back in the approval gate with
`checkpoint.zsh load --phase approver_mode` (defaulting to `none` when
absent, e.g. a resumed run whose checkpoint predates this detection).

### `--dry-run` — detect only, never dispatch or push

`--dry-run` promises no remote side effects (Phase 0: "gather
everything … print the payload instead of dispatching"). The **Dispatch**
subsection below force-pushes fixes to PR branches and re-triggers CI —
exactly the kind of mutation dry-run forbids. So under `--dry-run`:

- **Run the read-only Detection + JSON parsing below** (those are pure
  `gh` reads — no mutation), then **stop before Dispatch**. Do **not**
  spawn agents, create worktrees, or push.
- Collect what you *would* have fixed into the Phase 9 dry-run report:
  the flagged PR numbers, and for each its findings grouped by
  `suggested_agent` (and the `suggested_agent: null` ones in the
  "needs human attention" bucket, same as a live run). See Phase 9's
  *"Approver backlog (dry-run)"* block.
- Then continue to Phase 3 as usual (gather still runs; the live-run
  reasons to proceed to Phase 3 hold under dry-run too).

The rest of this phase (Detection, JSON parsing, Dispatch, Identity,
Skip conditions) describes the **live** run.

### Detection

For each open PR in the current repo (`gh pr list --state open --json
number,headRefName,headRefOid,author`), fetch the most recent review
by the Approver bot:

```bash
gh pr view <pr> --json reviews --jq \
  '[.reviews[] | select(.author.login | test("^(app/)?claude-approver"))] | sort_by(.submittedAt) | last'
```

(Prefix match, two ways: gh's GraphQL-backed commands report App-bot
authors as `app/<slug>` while REST/webhooks use `<slug>[bot]` — the #221
mismatch — and the slug itself is owner-suffixed because App
slugs are globally unique, e.g. `claude-approver-timo-jakob[bot]`,
never the generic `claude-approver[bot]` — the #229 mismatch.)

Review bodies contain control characters and markdown: extract fields
with `gh --jq` only, exactly as above — never round-trip a body through
shell variable interpolation to re-parse it (that broke on the control
characters and cost a detection round, #524).

A PR is **Approver-flagged** when ALL hold:

- A review by the Approver bot (login prefix `claude-approver`) exists.
- Its `state` is `CHANGES_REQUESTED`.
- Its `commit_id` equals the PR's current `headRefOid` (no push since
  the review).
- Its `body` contains a `<!-- claude-approver:findings ... -->` HTML
  comment block.

### Conflicting standing bot PRs — inventory here, remediate in Phase 8 (#653)

The same open-PR pass also identifies **pipeline-authored PRs that have gone
`CONFLICTING`** — a prior maintenance PR whose base moved under it. Include
`author` and `mergeable` in the inventory (add `mergeable` to the
`gh pr list --json` fields, or read it per PR with
`gh pr view <pr> --json mergeable`):

- **`claude-maintenance` App author** (login prefix match, same `app/<slug>` /
  `<slug>[bot]` duality as above) **AND `mergeable: CONFLICTING`** → record the
  PR in the run state as a `conflicting_bot_prs` entry. These are **the
  pipeline's own PRs, and their conflicts are the pipeline's to resolve** —
  never the user's. Phase 8's *standing-PR remediation* step (§ *Conflicting
  bot-PR remediation*) rebases and re-verifies each one; do **not** act on
  them here (Phase 2.5 is detection + Approver-feedback only), and do **not**
  route them to the run summary as a manual to-do (that was the 2026-07-09
  ai-doc-organizer miss: bot PR #84, approved + armed but CONFLICTING, was
  deferred to "manual rebase" — the exact outcome this inventory exists to
  prevent).
- Conflicting **vendor** PRs are not collected here — the vendor-PR stage owns
  them with vendor-specific mechanisms (`@dependabot rebase`, the Renovate
  checkbox). Conflicting **human** PRs are never touched: report only.

Under `--dry-run`, this inventory is read-only like the rest of Phase 2.5:
list what *would* be remediated in the Phase 9 report, rebase nothing.

### JSON parsing

Extract the hidden block, parse the JSON. Schema documented in
[`development-python/docs/python-approver.md`](../../../development-python/docs/python-approver.md)
(the *JSON schema* section). Key fields:

- `verdict` — must be `"REQUEST_CHANGES"` for this phase to act.
- `findings[]` — each finding has `category`, `title`, `detail`,
  `suggested_agent`, `file`, `line`.

### Dispatch

Group findings by `suggested_agent`. Findings with `suggested_agent:
null` are unfixable by automation; record them in the Phase 9 summary's
*"Approver-flagged, needs human attention"* list with the finding's
`title` and `detail`.

For each agent group, spawn the agent with `isolation="worktree"`
**and the PR's head SHA as worktree base**:

```text
Agent(
  subagent_type="<finding.suggested_agent>",
  description="Fix Approver findings on PR #<n>",
  isolation="worktree",
  prompt="""
    repo_path: <repo.path>
    pr_number: <n>
    pr_branch: <pr.headRefName>
    findings: [ ... group of findings for this agent ... ]
    source: approver

    Address the findings above on the worktree branch (already based
    on the PR's HEAD). Run the project's test command before declaring
    success. Commit on the worktree branch — the orchestrator will push
    the commit to the PR branch.
  """
)
```

**Critical**: the worktree base is the PR's head SHA, not main. The
agent's fix layers on top of the PR; it doesn't replace it.

After the agent returns:

```bash
git -C "<worktree>" push --force-with-lease origin "<worktree_branch>:<pr.headRefName>"
git -C "<repo.path>" worktree remove "<worktree>" -f -f
```

The `--force-with-lease` protects against a parallel push race; the
agent's commit is the new head and we need to fast-forward the PR
branch to it.

### Identity

Phase 2.5 itself uses the user's `gh` auth. The PR was opened by
`claude-maintenance[bot]` in a prior maintenance run (when the
identity switch in Phase 8 fired), so the PR author is already the
bot; pushes don't change the PR author. Identity-switching matters
only at **PR creation time** — see Phase 8's *Identity for PR
creation* subsection.

### Skip conditions

- `suggested_agent` is `null` — record in the summary, skip the
  finding. Author judgement required.
- Named agent isn't installed in this plugin family (e.g., a Node
  agent on a Python-only project) — record in the summary, skip.
- Agent returns `human_action_required` — record the reason in the
  summary, skip.

### After this phase

Continue to Phase 3 (gather + plan + Phase 8 normal flow). The
Approver-driven fixes are pushed; the normal flow finds and addresses
any new issues from tools.

## Phase 3 — gather findings per supported language

### State pre-flight (per supported language)

Before invoking each language's gather script, run that language's
state-verification helper to make sure the gather will produce
trustworthy results. The helper's job is to surface stale or
inconsistent local state (a venv built against the wrong interpreter,
a deleted Bundler cache, a missing Go toolchain, etc.) and recover
where it can autonomously.

Naming convention mirrors the gather scripts: per detected language
`lang`, look for and invoke:

```bash
"<skill-base-dir>/scripts/verify-<lang>-state.sh" "$(pwd)"
```

If the script doesn't exist for a language, skip — that plugin
hasn't published a state-verification helper yet, and the gather
script's own internal notes path will handle whatever state issues
surface. Don't fail the run on a missing helper.

#### Verify-state script contract (all languages)

The script's exit code drives the orchestrator's next move. Don't
parse stdout/stderr to guess intent; trust the exit code.

| Exit code | Meaning | What you do |
| --- | --- | --- |
| `0`, no stdout | State is fine, no action needed | Proceed to the gather script |
| `0`, stdout is JSON `{"recovered": true, "action": ...}` | State was rebuilt successfully. `action` says which: **`"created"`** — there was no local env, so one was **bootstrapped from scratch** (e.g. Python had no `.venv`; #624); **`"recreated"`** — an existing env was on the wrong toolchain and was rebuilt. The JSON also carries what was installed (Python: `install_target`, e.g. `.[dev]`). | Proceed to the gather script. Include the JSON in the run summary so the user knows their local env changed — word it per `action` (a freshly **created** venv vs a **recreated** one). This is a **local-only** change (no remote mutation) and is therefore acceptable under `--dry-run` too — surface it in the dry-run summary's notes exactly the same way, so the user knows dry-run touched their local env. |
| `1`, message on stderr | User must intervene; cannot recover autonomously (typically: a tool isn't installed) | **Halt the run.** Forward the stderr message to the user verbatim. |
| `2`, stdout JSON `{"recreate_failed": true, ...}` (or other "tried, failed" shapes) | Recovery attempt failed mid-flight; user needs to choose | Invoke the **R.4 fallback** below: surface the JSON details via `AskUserQuestion` and act on the choice. |

Anything else (non-zero with no JSON, etc.) → halt and forward stderr.
Treat unknown failure modes as user-intervention paths rather than
silently continuing on broken state.

#### R.4 — fallback when the state script exits 2

The recovery attempt found a problem it couldn't auto-fix (typically:
a dep cascade exhausted before the venv would install). The state
script's JSON payload identifies the blockers; surface them via
`AskUserQuestion` with three options that work for any language's
state model:

```text
Question: "Local <lang> state can't be reconciled with main's declared
           configuration:
             - <blocker 1 from script JSON>
             - <blocker 2>
           Main is already at the new configuration. What now?"

Options:
  1. "Fall back to the previous configuration locally"
        — invoke the same verify-<lang>-state.sh with a
          --target-<something>=<old_value> flag so the script rebuilds
          state matching what main USED to look like. Specifics per
          language (Python: --target-py=<old_version>). Subsequent
          Phase 8 stages SKIP the pre-flight for the rest of this run
          (in-memory flag; resets next /development:maintenance call).
        — record in the summary: "Local <lang> state reverted to
          previous config; main is at the new config pending the
          blocker resolution."

  2. "Open a GitHub issue capturing the blockers, then halt"
        — orchestrator drafts an issue body from the script's JSON
          blockers, posts via `gh issue create`. Halt the run.

  3. "Halt — I'll handle it manually"
        — no further action. Run ends with the script's report in the
          summary.
```

This fallback shape is language-agnostic. The script JSON tells the
orchestrator what to put in the question; the option-1 fallback
command is `verify-<lang>-state.sh --target-...` with a flag the
language plugin defined.

### Run the gather script

For each `lang` in `supported`:

```bash
"<skill-base-dir>/scripts/gather-<lang>-findings.sh" "$(pwd)" > "/tmp/findings-<lang>.json"
```

Each script outputs a JSON with `tooling_configured`, `findings_by_tool`,
`coverage`, and `notes`. Collect them all. Python's gather additionally
emits `sonar_quality_gate` (#50) — the main branch's Quality Gate verdict
(`{status, conditions}`, or `null` when SonarCloud isn't configured or the
fetch failed). It is user-facing state for Phase 9's summary only and is
**never** copied into the dispatch payload.

If a script exits non-zero or produces malformed JSON, that's an
internal error — surface it to the user (with the script path + stderr)
and skip that language. Don't try to construct a payload from a broken
gather output.

**Skipping means removing it from `supported`, not just not-gathering it.**
`supported` is what Phase 4 iterates to build payloads, what Phase 6 iterates to
dispatch, and what Phase 9 prints verbatim as `Languages processed:`. Leave a
failed-gather language in that set and the run builds a payload from the broken
output, dispatches it, and reports the language as **processed** when it was never
gathered. So: drop it from `supported` and record it with the other unsupported
languages, noted `gather failed: <error>` (the same bookkeeping the failed-*dispatch*
branch in Phase 6 already does).

Pool all `notes` across all gather scripts; they describe why certain
tools couldn't produce live findings (e.g., snyk auth missing,
pytest-cov not installed). Surface them in the final summary.

### Run the topic gather scripts

Topics have no language toolchain state and no test suite, so they get **no
state pre-flight and no coverage**. For each `topic` in `supported_topics`:

```bash
"<skill-base-dir>/scripts/gather-<topic>-findings.zsh" "$(pwd)" > "/tmp/findings-<topic>.json"
```

Same output contract as the language gathers — `tooling_configured`,
`findings_by_tool`, `notes` — except `coverage` is always `null`. Collect them,
pool their `notes` with the rest, and treat a non-zero exit or malformed JSON
the same way (surface it, skip that topic) — including the bookkeeping: **remove the
topic from `supported_topics`** and record it in `unsupported_topics` noted
`gather failed: <error>`, for exactly the reason given above on the language path.
A topic that was never gathered must never appear under `Topics gathered:`.

### Project-level findings — template drift

After per-language gathers complete, run the template-drift detector
**once** (it's project-level, not per-language):

```bash
template_drift=$("<skill-base-dir>/scripts/detect-template-drift.zsh" "$(pwd)")
```

It emits a JSON array of findings (possibly empty), each with a
severity: `drifted`, `unknown_provenance`, `template_missing`, or
`malformed_marker` (detector mechanics + severity meanings in
`reference/gather.md` § Template-drift severities). A `drifted` finding
also carries `fixes` (the changelog entries newer than the rendered
file's marker — what a re-bootstrap would deliver, #400) and `blocking`
(true when one of those changes a required-check's behavior). In v1 these
are **detect-only** — they do not enter `findings_by_tool` or route to any
triage agent. Store `$template_drift` and surface it in Phase 9's
summary; the user decides between re-bootstrap, manual patch, or
accepting the drift. Phase 9 renders `blocking` drift first and names the
fixes, so "I updated the plugins but the repo behaves the same" (the fix
lives in the rendered file, not the plugin) is no longer a silent trap.

**Checkpoint `phase3-gather`** (skip under `--dry-run`): the gather
artifacts live in `/tmp` and won't survive to a new session — copy them
into the store first, then record what was gathered:

```bash
ckdir=$("<skill-base-dir>/scripts/checkpoint.zsh" dir)
cp /tmp/findings-*.json "$ckdir/"
print -r -- "{\"supported\":[…],\"supported_topics\":[…],
  \"artifacts\":[\"findings-<lang>.json\",…],\"template_drift\":$template_drift}" \
  | "<skill-base-dir>/scripts/checkpoint.zsh" save --phase phase3-gather --data -
```

On resume, re-read every findings file from `$ckdir`, not `/tmp`.

## Phase 4 — construct one payload per supported language

For each `lang` in `supported`, build the JSON payload per ARCHITECTURE.md
schema v2:

```json
{
  "schema_version": "2",
  "repo": {
    "path": "<cwd>",
    "default_branch": "<from detect-stack>",
    "visibility": "<from detect-stack, or 'unknown'>"
  },
  "language": "<lang>",
  "dispatch_mode": "<'primary' if <lang> == the declared primary (or no declaration); else 'auxiliary'>",
  "language_meta": {
    "version": "<lang-appropriate version from detect-stack, or a sensible default>",
    "manifests": [/* lang-appropriate manifest files that exist */]
  },
  "tooling_configured": <from findings-<lang>.json>,
  "findings_by_tool":   <from findings-<lang>.json>,
  "coverage":           <from findings-<lang>.json>,
  "policy": {
    "coverage_threshold": 90,
    "severity_gate": "high",
    "allow_nosemgrep_with_justification": true
  },
  "worktree": {
    "available": true,
    "base_branch": "<the user's current branch, NOT default_branch — that's where we'll merge back to>"
  }
}
```

When `--tool=<name>` **or** `--concern=<name>` was passed in Phase 0,
also add the optional `dispatch_filter` field to the payload (omit it
entirely otherwise):

```json
"dispatch_filter": { "only_tools": ["<tool>", "..."] }
```

`only_tools` is the scoped tool set: a single-element list for `--tool`,
or the concern's expanded tool set for `--concern` (e.g.
`["snyk_prs", "code_scanning", "semgrep", "container_scan", "govulncheck"]` for `--concern=security`).
The field shape is identical either way — the language plugin already
treats `only_tools` as a set, so no plugin change is needed to support
multi-tool scoping.

This is what the language plugin reads to know it should skip every
other agent. The gather output is unchanged — only dispatch is scoped.

The user's current branch from `git rev-parse --abbrev-ref HEAD`.

`language_meta.version` — language-appropriate, sourced from
detect-stack's nested `language_meta.<lang>` block:

- python → `language_meta.python.version` from detect-stack (default `3.12`)
- java → `language_meta.java.version` from detect-stack (default LTS `21`)
- javascript → detection + format_lint dispatch ship (#729); the
  `language_meta.javascript.version` population (Node version from
  package.json `engines.node`) is a later #683 slice, so it is not sourced yet
- go → `language_meta.go.version` from detect-stack (#870: the `go`
  directive normalized to major.minor; default `1.26`) — detection ships,
  the development-go dispatch side is epic #868 slice B
- etc.

`language_meta.manifests` — list whichever manifest files exist that
are conventional for that language (Python: pyproject.toml,
requirements.txt, setup.py, setup.cfg; Go: go.mod). Don't include
files that don't exist.

**Construction discipline.** Copy `tooling_configured`,
`findings_by_tool`, and `coverage` straight out of
`findings-<lang>.json`. Do not drop entries from `coverage.by_module`
because there are "many"; do not truncate
`findings_by_tool.dependabot[].body` because it contains 10 KB+ of
release notes; do not flatten or summarise any nested value. The full
**no-trim contract** is the rule in Phase 6 (the two real incidents
that motivated it are in `reference/gather.md`). Construction is where
the trimming most commonly enters; if the payload you build here
already has fields shortened, Phase 6's contract is broken before
dispatch even starts.

### Topic payloads

Build a payload per `topic` in `supported_topics` the same way, with these
differences:

- `language`: the **topic name** (e.g. `"claude-plugin"`) — it identifies the
  dispatch target. Most topic dispatchers don't branch on it, but the value is
  **contractual, not informational**: a topic dispatcher MAY validate it, and
  `development-kubernetes` does — it errors and stops when `.language` is not
  `"kubernetes"`, because the v2 payload has no `topic` key for it to check
  instead. So never null it, normalise it, or move the topic name to a new key
  without updating the topic dispatchers in the same change: every kubernetes
  dispatch would land in `unsupported_topics` as `dispatch failed`.
- `dispatch_mode`: `"primary"` if this topic == the declared `primary` (or no
  declaration); else `"auxiliary"` — same rule as language payloads (Phase 1).
- `language_meta`: `{ "version": null, "manifests": ["<the topic marker>"] }` —
  the marker path, whether a file (`claude-plugin`) or a directory
  (`docs` → `"docs/architecture"`). For a **content** marker — one that matches
  *inside* files rather than by path (`spring`, `react`, and the `argoproj.io`
  half of `kubernetes`) — `manifests` is the list of
  **every matching file path**, repo-relative, in `find` order: e.g.
  `["packages/web/package.json", "apps/admin/package.json"]`. Never invent a
  conventional root path for a content marker: a monorepo whose React app lives in
  `packages/web/` has no root `package.json` with `react` in it, so `["package.json"]`
  would name a file that does not carry the marker.

  **Get those paths from the marker's path-listing variant, not from the marker
  itself.** The `react` verdict recipe prints React *version strings* (and `spring`'s
  prints nothing but a status), so neither one's stdout is a path list. Run:

  ```bash
  # react → the matching package.json paths, repo-relative
  # react-manifests:begin
  find . -mindepth 1 \
    -path '*/node_modules' -prune -o \
    -path '*/.git' -prune -o \
    -path '*/vendor' -prune -o \
    -path '*/.build' -prune -o \
    -path '*/dist' -prune -o \
    -path '*/templates' -prune -o \
    -name package.json ! -type d \
    -exec sh -c '[ -n "$(jq -r ".dependencies.react // empty" "$1" 2>/dev/null)" ] && printf "%s\n" "${1#./}"' _ {} \; \
    2>/dev/null || true
  # react-manifests:end

  # spring → grep -REl already prints paths (sed strips find/grep's leading ./ so
  # both content markers emit the same repo-relative form the example above shows)
  grep -REl --include='build.gradle.kts' 'org\.springframework\.boot|spring-boot-starter-' . 2>/dev/null | sed 's|^\./||'

  # kubernetes → the HYBRID case (see below): the marker's own filtered path list,
  # falling back to the argoproj.io matches only when it is empty. The final
  # printf is GUARDED, so an empty result prints NOTHING — matching the two
  # recipes above, whose consumers read "one path per line" and would otherwise
  # turn a lone blank line into a `[""]` manifest naming no file.
  #
  # It carries the verdict recipe's three-status error contract too (#1177) —
  # but applies it STRICTLY, because a list is not a boolean. The verdict copies
  # can say "a hit stands whatever else failed": one hit settles a yes/no. Here
  # COMPLETENESS is the payload, so a partial walk is a wrong answer even when it
  # found plenty — the dispatch would name the files that happened to be walked
  # before the error and the agents would report clean on the rest. So the
  # incomplete-search test comes FIRST, ahead of the print: any search that did
  # not finish exits 2 and names it on stderr, empty result or not. Only a
  # complete search prints — a list when there is one, nothing when there is not.
  # (`gather-kubernetes-findings.zsh`'s policy listing already reasons this way:
  # "ANY non-zero find is fatal here".)
  #
  # Note the argoproj half captures grep's status BEFORE the `sed`, into its own
  # variable. A pipeline's status is its LAST command's, and `sed` always
  # succeeds — so capturing `grep … | sed` would read 0 for a grep that exited 2
  # in every shell without `pipefail`, which the Bash tool's shell is. That would
  # make the `-ge 2` half of the ladder below dead code and print an empty list
  # for a repo with one unreadable *.yaml: the exact defect this block removes.
  # The presence half's filter may stay piped — its status is discarded (`||
  # true`) because it reads the captured string, not the filesystem.
  # kubernetes-manifests:begin
  k8s_paths="$(find . \( -name Chart.yaml -o -name kustomization.yaml \
                         -o -name kustomization.yml -o -name Kustomization \) \
                   ! -type d 2>/dev/null)" && k8s_find_rc=0 || k8s_find_rc=$?
  k8s_paths="$(printf '%s\n' "$k8s_paths" \
                 | grep -v -e /node_modules/ -e '/\.git/' -e /vendor/ -e /templates/ \
                 | sed 's|^\./||')" || true
  k8s_argo_rc=1
  if [ -z "$k8s_paths" ]; then
    k8s_argo_raw="$(grep -rlF 'argoproj.io' \
      --include='*.yaml' --include='*.yml' \
      --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git \
      --exclude-dir=templates . 2>/dev/null)" && k8s_argo_rc=0 || k8s_argo_rc=$?
    [ -z "$k8s_argo_raw" ] || k8s_paths="$(printf '%s\n' "$k8s_argo_raw" | sed 's|^\./||')"
  fi
  if [ "$k8s_find_rc" -ne 0 ] || [ "$k8s_argo_rc" -ge 2 ]; then
    printf 'kubernetes manifests: search did not complete (find %s, grep %s) — refusing to report a possibly-truncated list\n' \
      "$k8s_find_rc" "$k8s_argo_rc" >&2
    ( exit 2 )
  elif [ -n "$k8s_paths" ]; then
    printf '%s\n' "$k8s_paths"
  fi
  # kubernetes-manifests:end
  ```

  **`kubernetes` is a HYBRID marker and needs its own clause**, because it is
  neither purely path-based nor purely content-based: it fires on a *file
  presence* set (`Chart.yaml`, the three `kustomization` spellings) **or** on
  `argoproj.io` *content*. Its `manifests` is the filtered path list the recipe
  above produces — many paths, not one — falling back to the `argoproj.io`
  matches when the presence half found nothing. Note the fallback drops `-q`:
  the verdict recipe's `grep -rqlF` deliberately prints nothing, so reusing it
  here would emit an empty list. And, per the rule above, never substitute a
  conventional root path such as `["kustomization.yaml"]` for an Argo-only
  repo — no such file exists there.

  **Read the lister's EXIT STATUS, not only its stdout (#1177).** Its contract is
  stricter than the verdict recipe's, because a list's *completeness* is the
  payload: `0` with output = the **complete** list; `0` with no output =
  genuinely nothing to list; **`2` = the search did not complete**, with the
  failing half named on stderr — and that includes a search that found plenty
  before it failed, since a truncated list read as whole is the same lie in a
  quieter form. On `2` there is no payload to build —
  move `kubernetes` to `unsupported_topics` with the note
  `manifest listing did not complete: <stderr>` (the same bookkeeping Phase 3
  uses for a failed gather) and dispatch nothing. Never let a status-2 run
  become `manifests: []`: the dispatch would name no files, the topic agents
  would review nothing, and the run would report clean — the empty list the
  recipe just refused to print, reintroduced by the step that consumes it.

  **The react lister above does NOT carry this contract yet**, and the honest
  reason is scope, not safety. Do not read its absence as proof the gap is
  closed there: react's verdict recipe discards `find`'s status and decides on
  captured stdout, so a walk that dies *after* producing one hit still answers
  `0`, and its lister then walks the same tree and prints a **truncated** list at
  status `0` — the same defect, unfixed. #1177's scope is the kubernetes marker's
  four parity-pinned copies; react's lister is its own change. Until then a react
  `manifests` list is **trusted, not verified**.

  **The `kubernetes-manifests:begin`/`:end` sentinels are load-bearing too**, like
  the verdict recipe's: `tests/kubernetes-topic-marker.bats` extracts this block by
  them, executes it, and holds its marker names and prune set to the *same* derived
  oracle as the verdict recipe, `gather-kubernetes-findings.zsh` and
  detect-stack.sh's `is-kubernetes-marker` block (#1153) — all four must
  stay identical. Keep them a single unique pair, keep the whole recipe between
  them, and keep the block at its current two-space indent inside this list item
  (the extractor de-indents by exactly that much).

  **The `react-manifests:begin`/`:end` sentinels are load-bearing too**, exactly as
  the verdict recipe's are: `tests/react-topic-marker.bats` extracts this block by
  them, executes it, and holds its prune set to the *same* derived oracle as the
  verdict recipe and `detect_lang` — all three must stay identical. Keep them a
  single unique pair, keep the whole recipe between them, and keep the block at its
  current two-space indent inside this list item (the extractor de-indents by
  exactly that much).

- `coverage`: `null` (the topic gather already emits `null`).
- `tooling_configured` / `findings_by_tool`: straight from `findings-<topic>.json`.
- `policy`, `worktree`: same as language payloads.
- `dispatch_filter`: **omit for topics.** `--tool` / `--concern` scope the
  *language* tool set (ruff, semgrep, …) and don't name topic tools, so a scoped
  run would hand a topic dispatcher a filter excluding all its tools. Rather than
  dispatch a guaranteed-empty plan, **skip topic dispatch entirely when `--tool`
  or `--concern` is set**, and note it in the Phase 9 summary ("topic checks
  skipped under --tool / --concern").

The same no-trim construction discipline applies.

**Checkpoint `phase4-payload`** (skip under `--dry-run`): copy each
constructed payload into the store and record the list, so a resumed run
dispatches the exact payloads this run built:

```bash
ckdir=$("<skill-base-dir>/scripts/checkpoint.zsh" dir)
cp /tmp/payload-*.json "$ckdir/"
print -r -- "{\"payloads\":[\"payload-<lang>.json\",…]}" \
  | "<skill-base-dir>/scripts/checkpoint.zsh" save --phase phase4-payload --data -
```

## Phase 5 — `--dry-run`?

If `--dry-run`: print each payload (pretty-formatted via `jq .`)
labeled by language **and topic**, print the pooled notes, list any
unsupported languages / topics, and stop. Nothing is dispatched or merged.
(Topic payloads are built and printed too, unless `--tool` / `--concern`
scoped the run — in which case note that topic checks were skipped.)

If `--batch=N` was also passed, the planner never runs under `--dry-run`
(planning happens inside the dispatcher in Phase 6, which dry-run skips), so
there is no ranked plan to cap here. Note in the dry-run output that a live
run would process **at most the top N planner groups** and defer the rest —
don't claim a specific group count, since the plan doesn't exist yet.

## Phase 6 — dispatch per supported language to plan

For each `lang` in `supported`, invoke the matching language plugin via
the Skill tool. **The payload is handed over via a temp file**, not
inline — see ARCHITECTURE.md § "JSON schema (v2)" for the contract.

```bash
# 1. Write the payload to a temp file. The helper sets 0600 perms
#    and prints the absolute path on stdout.
payload_file=$(print -r -- "$payload_json" \
  | "<skill-base-dir>/scripts/write-payload.zsh")
```

```text
# 2. Dispatch. args= is the path to the file just written.
Skill(
  skill="development-<lang>:maintenance",
  args="$payload_file"
)
```

```bash
# 3. After the Skill tool returns (success or failure), delete the
#    temp file. On hard crash the OS reaps it from $TMPDIR.
rm -f "$payload_file"
```

`<skill-base-dir>` is the maintenance skill's directory (the same
placeholder used for `mint-maintenance-token.zsh` elsewhere in this
file).

The file-based handover decouples payload size from any Skill-tool
inline limit. A maintenance run on a project with 200+ Dependabot PRs
(~6 MB payload) is the same code path as one with three patches.

### No-trim contract — known recurring bug

**Pass the payload as-is.** Do not trim, summarise, drop fields,
sample, flatten, or restructure any value before the `Skill(...)`
call — not `coverage.by_module` (every module, even 80+), not the full
`findings_by_tool.dependabot[].body` / `snyk_prs[].body` (even 10 KB of
release notes), not `code_scanning_alerts[]`, not any other field.
Downstream agents parse fields the orchestrator never reads, so
trimming silently changes routing.

**Self-check before each dispatch:** the JSON written to the temp file
must be character-for-character identical to the payload you built in
Phase 4. If you "tidied up," "shortened," "deduplicated," or
"summarised" anything, the contract is broken — reconstruct from
`findings-<lang>.json` and dispatch again.

This rule is incident-driven (the orchestrator trimmed payloads in
**two real runs**) and payload size is never a justification — v2's
file-handover makes the `args=` value an ~80-byte path regardless of
payload size, so the old "200 KB inline ceiling" escape valve is gone;
do not reintroduce it. See `reference/gather.md` § No-trim contract for
the two incidents and the per-field detail of what downstream reads.

The dispatcher's internal Phase A / Phase B sequencing — when it spawns
the coverage-improver, when it runs the planner, what payload validation
it performs — is owned by the language plugin. See
`development-python/skills/maintenance/SKILL.md` (intro) for the canonical
Phase A/B contract.

The orchestrator only needs to handle the three response shapes:

**Orchestrator's response handling for the first dispatch:**

- **Response has `improver_result` and no `plan`** → improver ran.
  Run Stage 0 of Phase 8 first (push the improver's branch, open a
  PR, monitor CI, merge, sync local main). Then **re-invoke the
  plugin with the same payload** to get the plan. The second
  invocation sees post-merge coverage and naturally lands on Phase B.
- **Response has `plan` and no `improver_result`** → improver wasn't
  needed. Skip Stage 0. Proceed straight to Phase 8's per-group PRs.
- **Response has `human_action_required`** → halt as before
  (Phase 7).

**The `Skill(...)` call is a step, not a turn boundary.** On return,
continue straight into Phase 7 and Phase 8 in the same assistant turn.
The dispatcher's plan response is Phase 8's **input** — and it is
checkpointed (`phase6-plan`, below, #517), so an interrupted Phase 8
resumes with the same plan instead of re-dispatching; persistence changes
nothing about turn flow.
The only events that end a turn before Phase 9 are (a) `human_action_required`,
(b) all Phase 8 stages complete + Phase 9 summary printed, or (c) the user
explicitly says "stop".

**The language plugin does NOT spawn the per-group work agents** in
either phase. Work agents are spawned per-group in Phase 8 below so that
each group's PR cycle (push → CI → merge → sync) completes before the
next group starts off the just-merged main. The one exception is the
coverage-improver itself, which the dispatcher spawns during Phase A.

Capture each response, keyed by language. Also read
`response.ci_fixer_agent` — the language plugin's CI-fix agent, spawned
by Phase 8's CI cycle when a PR's checks fail. It is present in **every**
response shape (including the Phase A `improver_result`-only response),
so it is available before any `plan` exists — Stage 0's CI cycle needs
it. Never substitute a hardcoded fixer name; use the one the dispatcher
returned.

**Checkpoint `phase6-plan`**: save the captured responses (the plan +
`ci_fixer_agent`, keyed by language/topic) via
`checkpoint.zsh save --phase phase6-plan --data -`. On resume, Phase 8
rebuilds its stage list from this instead of re-invoking the dispatcher —
a re-dispatch would re-run the coverage pre-flight and could double-spawn
improvers. (Per-stage Phase 8 progress records are #536.)

If a `Skill(...)` invocation fails (plugin not actually registered
despite the gather script existing — shouldn't happen but defend
anyway), treat that language as if it were `unsupported` for this run
and continue with the rest.

### Dispatch to topic plugins

After (or alongside) the language dispatches, dispatch each `topic` in
`supported_topics` **identically** — same file-handover, same no-trim contract,
same `Skill(...)`-is-a-step rule:

```text
Skill(
  skill="development-<topic>:maintenance",
  args="$payload_file"
)
```

Topic dispatchers share the response contract, with two simplifications:

- **Never an `improver_result`.** Topics have no coverage pre-flight, so a topic
  response is always a `plan` (possibly empty) + `missing_tooling`, or
  `human_action_required`. There is no Stage-0 improver dance for topics.
- **`ci_fixer_agent` may be `null`.** A topic plugin can decline to provide a
  CI-fixer in v1. Capture it as for languages, but if it is `null` — **or names an
  agent that cannot be spawned** (a topic may name a *language* plugin's fixer, e.g.
  `react` reuses `js-ci-fixer`, and that plugin may not be installed) — and a topic
  PR's CI fails in Phase 8, **escalate to the user** (carry it into the Phase 9
  summary as a `human_action_required`-style note) instead of spawning a fixer —
  never substitute a hardcoded one.

**A failed topic dispatch is not an empty plan.** If a topic's `Skill(...)`
invocation fails, or its response is not a JSON object carrying `plan`, move the
topic to `unsupported_topics` with the note `dispatch failed: <error>` and continue
with the remaining topics — never record it as an empty plan. The distinction
matters most for a topic whose *correct* result is an empty plan (a topic with no
tools registered yet): without this rule, a dispatch that never happened and a
dispatch that found nothing are reported identically.

A topic's `plan` groups join the **same Phase 8 queue** as language groups and
are processed by the same sequential per-stage PR cycle. **How to read an empty
topic `plan` depends first on `human_action_required`, then on
`tooling_configured`:**

- the response carries a non-empty **`human_action_required`** → the dispatcher
  *deliberately halted*, whatever `plan` and `tooling_configured` say. Carry its
  `{reason, recommendation}` entries into the Phase 9 summary (Phase 7's rule,
  which is not language-only) and **never render a clean verdict for that
  topic**. This is a real shape, not a hypothetical: `development-kubernetes`
  returns exactly it — empty `plan`, empty `missing_tooling` (both its policy
  keys are exempt from that list), and one `human_action_required` entry —
  whenever it cannot understand the payload: a `findings_by_tool` key its
  routing table has no row for, a `dispatch_mode` outside the two-value enum,
  or `manifest_validation: false` (presence detection, so `false` means the
  payload was not built by the orchestrator). Its **routable** groups return a
  real `plan` — the escalate-everything override retired with #1153.
- else `tooling_configured` **non-empty** → "this topic is clean — its tools ran
  and found nothing";
- else (**empty**) → "no tools are registered for this topic yet — nothing was
  inspected". Render it as such and cite the topic's `notes`, so a no-op is never
  reported as a clean bill of health.

A topic's `notes` can also contradict a clean reading directly — the kubernetes
gather always carries `manifest_validation: presence-detected only`, meaning its
tools have **not** run in the gather at all. Cite the notes whenever they say so,
even on the "clean" branch.

## Phase 7 — handle `human_action_required` early-outs

For any response that contains `human_action_required`, the dispatcher halted
deliberately. Pass the reasons + recommendations through to the user-facing
summary and **skip all remaining phases for that dispatch target**. Every other
target still proceeds.

**This is not language-only.** For a *language* plugin the halt means coverage
was below floor. A **topic** dispatcher halts for its own reasons — a finding
whose routing table has no entry, a payload field outside its documented enum,
or an agent a routing row names that has not shipped yet — and the same handling applies: the
reasons reach the summary, and Phase 9 renders the topic as **halted**, never as
clean.

## Phase 8 — per-stage PR cycle

> The steps below are the imperative procedure. The *why* behind the
> non-obvious ones — the identity switch, the isolation invariant, the
> per-tool override, `-f -f`, the post-merge state re-check, and more —
> lives in [`reference/pr-cycle.md`](reference/pr-cycle.md), cited inline
> as "see `reference/pr-cycle.md` § …". You don't need it to run the happy
> path; reach for it when a step's intent is unclear or an edge case fires.

Replaces the old "merge worktree branches locally" with a remote-first
flow: each stage (coverage improvement + each planner group) becomes
its own PR. PRs are processed **sequentially** — the next stage only
spawns its agent after the previous stage's PR has merged, so each
stage runs off the latest `main`.

**Stage 0 (improver) is special: it runs BEFORE the planner has even
been invoked.** When Phase 6's first dispatcher call returned an
`improver_result`-only response, you immediately do Stage 0 here.
Only after the improver's PR is merged + main is synced do you go
back and re-invoke the dispatcher for Phase B, which gives you the
plan. Then Stages 1..N proceed. This serialization is the whole
point — the planner must rank against actually-merged main, not a
worktree branch.

If `--no-merge` was passed, **skip this phase entirely** and list the
plan + any local worktree branches in the final summary for manual
handling.

### Per-stage checkpoint records + resume (#517)

Phase 8 is the long tail of the run, so its progress is checkpointed
**per stage**, not just at a phase boundary. Maintain a `phase8-stages`
record — one JSON object keyed by stage (`stage0`, then the planner
group ids in batch order) — and re-save the whole object via
`checkpoint.zsh save --phase phase8-stages --data -` at every
transition:

```json
{ "stage1": { "group": "<planner group id / tool>", "branch": "<worktree branch>",
              "pr": 214, "ci_fix_count": 1, "status": "pr_opened" } }
```

`status` moves `agent_spawned` → `pr_opened` → `merged` |
`awaiting_approval` | `escalated` | `deferred`. Update points: after
spawning the group's agent, after the PR opens (record branch + PR
number), after each CI-fixer invocation (increment `ci_fix_count`), and
at the stage's terminal state (the post-merge sync for `merged`; the
approval gate's outcomes for the rest).

**Resuming into Phase 8** (the resume entry already restored the plan
from `phase6-plan`): reconcile every recorded stage against **GitHub
reality** before acting — the checkpoint says what *was* true, GitHub
says what *is*:

- `status: merged` → skip the stage; already done.
- a `pr` is recorded → `gh pr view <pr> --json state`: **MERGED** → mark
  `merged`, sync local main, skip; **OPEN** → re-enter the CI cycle on
  it at the recorded `ci_fix_count` (the 3-per-PR fixer budget spans the
  interruption); **CLOSED** unmerged → treat as `escalated` and note it
  for Phase 9.
- `agent_spawned` with no `pr` → the interrupted session's worktree is
  gone; re-spawn the group's agent off the current merged tip — nothing
  outward happened, so this is safe.
- **Never** re-open an existing PR, re-dispatch a group whose PR merged,
  or spawn a second agent for a stage that has an open PR.

Stages not yet in the record run normally from the restored plan.

### Identity for PR creation (when Claude Apps registered)

When `~/.config/claude-plugins/apps.json` has a `claude_maintenance`
entry, mint an installation token before every `gh pr create` call in
this phase so the new PRs attribute to `claude-maintenance[bot]`:

```bash
# mint returns a mode-600 file PATH, not the token value (#640). Read it
# inline at each point of use so the secret never lands in a named variable
# that could be echoed into the session transcript that .tgz handoffs ship.
maint_token_file=$("<skill-base-dir>/scripts/mint-maintenance-token.zsh")
GH_TOKEN="$(cat "$maint_token_file")" gh pr create --base ... --head ... --title ... --body ...
```

This identity switch is what lets the Approver evaluate maintenance PRs
at all — its author allowlist is machine-only and its anti-rubber-stamp
gate requires a non-`claude-approver` author. See `reference/pr-cycle.md`
§ Why the identity switch matters for the Approver loop.

The installation token has a 1-hour lifetime. If a maintenance run
takes longer than an hour and you need another `gh pr create`, re-mint
by calling `mint-maintenance-token.zsh` again. `$maint_token_file` holds a
live token for the whole PR-creation phase; remove it once the phase is
done (`rm -f "$maint_token_file"`) so no mode-600 token file lingers in
`$TMPDIR` past its usefulness.

If `mint-maintenance-token.zsh` fails (App not installed on the repo,
key revoked, network down), surface the error to the user and **abort
PR creation for that stage**. Falling back to the user's PAT would
open a PR the Approver couldn't evaluate — worse than skipping. The
Phase 9 summary should clearly call out the skipped stage with the
reason.

If `~/.config/claude-plugins/apps.json` doesn't have a
`claude_maintenance` entry (Claude Apps not registered on this
machine), open PRs with the user's existing `gh` auth — the Approver
isn't installed on the repo either, so the identity mismatch is moot.

### PR body (every `gh pr create` in this phase)

The Approver judges these PRs, and its **Baseline criteria** require the body
to contain `## Type`, `## Summary`, and `## Test plan` sections (see
`.claude/approver-policy.md` / `development-python/agents/python-approver.md`).
A free-form body is a self-inflicted baseline miss that drops every maintenance
PR below an approve — the pipeline opening PRs its own Approver must dock. **So
every `--body` in this phase MUST be template-conforming**, never prose.

Build the body from the repo's `.github/PULL_REQUEST_TEMPLATE.md` when present
(populate its sections — don't leave the comment placeholders); otherwise emit
this minimum, which satisfies the Approver baseline:

```markdown
## Type

<conventional-commit type parsed from suggested_pr_title — e.g. `fix`, `chore(deps)`, `test`, `ci`>

## Summary

- <what changed + why, one bullet per agent action; from the agent's actions_taken>

## Linked issue

<`Closes #N` when the work resolves a tracked issue (e.g. the maintenance
tracking issue, a Dependabot/Snyk advisory); omit the line otherwise>

## Risk

<the agent's actions_requiring_review + known limitations — e.g. "apt pin is
CI-verified, not built locally"; an honest "could break X under Y" beats "none">

## Test plan

- [x] <what the agent ran — e.g. `pytest` green, `pre-commit run --all-files`>
- [ ] CI gates on this PR (coverage floor, scanners, image scan as applicable)
```

Populate from the work agent's structured response (`actions_taken`,
`actions_requiring_review`, the structured commit body) — never leave a
section empty or as its template comment. `## Type` is the conventional-commit
prefix of `suggested_pr_title`; `## Summary` mirrors the commit body; `## Test
plan` records what actually ran plus the CI gate. This applies to **both** the
per-group PRs (Stages 1..N) and the coverage-improver PR (Stage 0).

### Stage 0 — coverage improver (when present)

When Phase 6's first dispatcher call returned `improver_result` (no
plan yet), run Stage 0 now, **before re-invoking the dispatcher for
Phase B**. The improver's worktree branch + path are in the response;
both are returned by the Claude Code runtime because the improver
spawned with `isolation="worktree"`.

1. **Push the branch** to origin **from the improver's worktree, not
   `<repo.path>`** (#644). A pre-push hook runs wherever the push runs,
   and the project's `coverage-floor` pre-push hook needs the build
   artifacts (`coverage.xml` / JaCoCo XML) the agent produced **in its
   worktree**. `<repo.path>` has none, so pushing there fails the hook;
   the artifact-bearing worktree is push-ready (env + artifacts):

   ```bash
   git -C "<improver_worktree>" push -u origin "<improver_branch>"
   ```

   `<improver_worktree>` is the path returned in the improver's response,
   alongside `<improver_branch>`. This is the **pre-push-artifact
   contract**: worktree agents leave their coverage report in the
   worktree, and every stage pushes from the worktree that holds it —
   never from `<repo.path>`, which is why Stage 0 previously failed the
   diff-cover hook and burned tool calls bootstrapping a report by hand
   (#644, the sequel to #629).

2. **Open a PR** against the user's working branch (the same branch the
   improver was based on):

   ```bash
   gh pr create --base "<base_branch>" --head "<improver_branch>" \
     --title "test: <improver's summary>" \
     --body "$(<body per § PR body — Type: test; Summary: the modules + coverage deltas; Test plan: pytest green + CI coverage floor>)"
   ```

   Capture the PR number.
3. **Run the CI cycle below** against that PR, passing the improver's
   worktree path so the cycle's `worktree remove` step can clean it up.
4. After merge, sync local `main`:

   ```bash
   git -C "<repo.path>" switch "<base_branch>"
   git -C "<repo.path>" pull --ff-only origin "<base_branch>"
   ```

5. **Now re-invoke the dispatcher** with the same payload that drove
   the first dispatch — coverage is now at Required on main, so the
   second invocation lands on Phase B and returns the plan. Use the
   same three-step file-handover pattern as Phase 6:

   ```bash
   payload_file=$(print -r -- "$payload_json" \
     | "<skill-base-dir>/scripts/write-payload.zsh")
   ```

   ```text
   Skill(
     skill="development-<lang>:maintenance",
     args="$payload_file"
   )
   ```

   ```bash
   rm -f "$payload_file"
   ```

   The new response will have `plan` and no `improver_result` (that
   was the previous response's responsibility). Capture the plan and
   continue with Stages 1..N below.

   **If the improver's PR was escalated** (3 ci-fixer attempts failed
   or coverage somehow not at Required after merge), surface the
   escalation and halt the run for this language. Do NOT re-invoke
   the dispatcher; the project's coverage isn't where Stages 1..N
   need it to be.

### Stages 1..N — one PR per planner group, in priority order

**Batch cap — `--batch=N` (when set).** Before applying the ordering rule
below, decide which groups run this round. Sort the full `response.plan` by
`priority_score` (descending) and keep the **top N**; the remaining `M − N`
groups are **deferred** — not dispatched, no PR opened, no agent spawned.
Record each deferred group (tool, description, finding count, priority
score) for the Phase 9 *"Deferred this batch"* list. The cap counts
**planner groups only** — Stage 0 (the coverage pre-flight, already merged
above) is never counted against `N`. When `--batch` is absent the batch is
the whole plan, so this step is a no-op. Selection is by **priority**;
*execution order* among the selected groups is still set by the ordering
rule below (priority ranks what matters most; the rule sequences the chosen
work to minimise re-stale churn — the two are independent).

**Ordering rule — worktree stages first, vendor-PR (GitHub-PR) stages last
(#432).** The planner ranks groups by priority, but under `main`'s `strict`
("require branches up to date") + `dismiss_stale_reviews` branch protection a
multi-PR run is quadratic: every merged stage moves `main`, marking every other
open PR `BEHIND`; bringing one up to date is a new commit that **dismisses the
approval already earned** and re-runs CI. To minimise that churn, run all
`isolation: true` (worktree) stages — which open and merge their own fresh PRs —
and only **then** the `isolation: false` vendor-PR stages (Dependabot / Renovate
/ Snyk triage), which act on standing GitHub PRs that each first-party merge
would otherwise re-stale. Keep the planner's priority order among the worktree
stages; just sink the vendor-PR stage(s) to the end so they're processed once
`main` is stable. (A standing PR against a moving base is the worst case — it
re-stales on every intervening merge.)

**Re-staling is unavoidable under `strict`, but deterministic.** When a PR you
still need to merge has gone `BEHIND` from an intervening merge, drive it with
the blessed helper (#431), never a hand-rolled loop:

```bash
# ci mode: --retrigger re-earns the Approver's counting review via /approve
"<skill-base-dir>/scripts/merge-pr-cycle.zsh" --update --retrigger "<pr_number>"

# local mode (#642): no CI-side workflow to re-trigger — --update only, then
# drive the approve skill to re-earn the review (no /approve comment)
"<skill-base-dir>/scripts/merge-pr-cycle.zsh" --update "<pr_number>"
/development-<lang>:approve "<pr_number>"
```

`--update` brings it up to date (which, under `dismiss_stale_reviews`, drops the
prior approval); the helper waits for the fresh SHA's CI to **register** and
settle. In **`ci` mode** `--retrigger` then posts one `/approve` to re-earn the
Approver's counting review; in **`local` mode** you drop `--retrigger` and drive
the `approve` skill instead (same reason as the approval gate — no server-side
workflow to nudge, #642). Process such PRs **one at a time** — each merge
re-stales the rest, so a batch must be serial.

> The structural O(N) cost is inherent to `strict` + `dismiss_stale_reviews`.
> Bounding the batch (#53 `--batch=N`, #57 budget) keeps it tractable; a GitHub
> **merge queue** — or relaxing `strict` for the bot path while keeping required
> reviews — would remove the per-PR churn entirely. Both are branch-protection
> **policy decisions for the repo owner** (tracked in #432), not changed by the
> pipeline here.

**Conflicting bot-PR remediation — the pipeline resolves its own PRs'
conflicts (#653).** When Phase 2.5's inventory recorded `conflicting_bot_prs`
(open `claude-maintenance`-authored PRs at `mergeable: CONFLICTING` — a
`--update` can't fix those; only a rebase with conflict resolution can),
remediate them in the **standing-PR slot** — after the worktree stages, at the
head of the vendor-PR/standing-PR work, so the rebase lands on a stable
`main`. One PR at a time:

1. **Scratch worktree on the PR head** — never the session worktree (#643):

   ```bash
   scratch=$(mktemp -d)
   git -C "<repo.path>" fetch origin "<pr.headRefName>" -q
   git -C "<repo.path>" worktree add "$scratch/pr" "origin/<pr.headRefName>"
   git -C "$scratch/pr" rebase origin/<base_branch>
   # resolve each conflict hunk on its merits (read both sides; keep the
   # PR's intent applied onto the new base), then `git rebase --continue`
   ```

2. **Re-validate in the scratch worktree** — the project's **full suite**,
   leaving the coverage artifact per the pre-push-artifact contract (#644),
   so the pre-push hook passes and the rebased code is actually green. A red
   suite here means the conflict resolution is wrong or the PR no longer fits
   its base: stop, leave the PR untouched (do not push a red rebase), and
   record the stage as `escalated` with the failure.
3. **Force-push as the bot** (writer token via its mode-600 file path, #640):

   ```bash
   git -C "$scratch/pr" push --force-with-lease \
     "https://x-access-token:$(cat "$maint_token_file")@github.com/<owner/repo>.git" \
     "HEAD:<pr.headRefName>"
   git -C "<repo.path>" worktree remove "$scratch/pr" -f -f
   ```

   `--force-with-lease` is required (a rebase rewrites the branch) and safe
   (the lease aborts if someone else pushed meanwhile).
4. **Re-enter the normal CI cycle + approval gate** for the PR: under
   `dismiss_stale_reviews` the rebase dropped the prior approval, so the
   mode-aware gate (#642) re-earns it exactly as for any fresh head, and the
   merge confirms per the standing cascade.

Authorship guard — this step touches **only** `claude-maintenance`-authored
PRs. Conflicting **vendor** PRs use their vendor mechanisms in the vendor
stage; conflicting **human** PRs are reported, never rebased. And the run
summary never presents a bot PR's conflict as a manual to-do — after this
step it is either merged/armed or `escalated` with a concrete reason.

For each entry in the **selected batch** (the whole plan when `--batch` is
absent; the top-N groups when it is set), in priority order:

1. **Determine the effective base branch** — the user's current branch
   after all prior merges (initially `worktree.base_branch`; updated
   after each merge by the sync step).

2. **Spawn the group's agent.** Whether the agent runs in a worktree
   is governed by **`plan[i].isolation`** from the dispatcher's plan
   (boolean; treat absent as `true`). You decide isolation **from the
   contract, never by matching an agent name** — see ARCHITECTURE.md
   § "JSON schema (v2)".

   **`plan[i].isolation` is `true` (or absent) → pass
   `isolation="worktree"`.** This is load-bearing: omitting it for a
   file-editing group breaks the per-group-PR invariant (the agent
   edits the main workspace instead of a worktree branch). See
   `reference/pr-cycle.md` § Why isolation is load-bearing. Use this
   exact call shape:

   ```text
   Agent(
     subagent_type="<plan[i].agent>",
     description="<plan[i].description>",
     isolation="worktree",
     prompt="""
       repo_path: <repo.path>
       configured: true
       findings: <plan[i].findings, with their full finding objects>
       policy: <policy>
       worktree.base_branch: <effective base after prior merges>
       commit_subject: <plan[i].suggested_pr_title>

       End with the project's test command in the worktree; only
       return success if tests pass. Commit your changes on the
       worktree branch before returning — the orchestrator will push
       the branch as-is.
     """
   )
   ```

   **`plan[i].isolation` is `false` → spawn WITHOUT `isolation`.** The
   group's agent acts on GitHub PRs via `gh`, not on local files, so it
   needs no worktree (in `development-python` this is
   `python-dependabot-snyk-triage`; a second language plugin's
   vendor-PR agent carries the same `isolation: false` and is handled
   identically). It returns no worktree branch — steps 3–7 below that
   push/merge a worktree branch do not apply; follow the dispatcher
   SKILL's case list for what such an agent reports back.

   **Vendor-PR post-return cascade — the orchestrator owns all CI waiting
   (#645).** The vendor-PR agent **acts and returns in one pass**: it
   classifies, updates BEHIND branches, arms auto-merge on the safe green
   ones, and hands back its `actions_taken`. It never monitors CI or
   yields for resume (that improvised agent-side CI monitoring +
   `SendMessage` resume loop was the most fragile stretch of the
   2026-07-08 run). So **after it returns, you drive the waiting** — for
   each PR the agent reported `pr_pending_reverification` (a branch it
   just updated, whose fresh head's CI hasn't settled), run the serial
   cascade, **one PR at a time** (each merge re-stales the rest under
   `strict`):

   1. `await-pr-checks.zsh "<pr>"` — the registration grace (#641) rides
      the just-registered checks; a false "no checks" won't slip through.
   2. Approval gate (§ the Phase 8 approval-gate step) — mode-aware
      (#642); on green + approved, confirm the merge.
   3. Re-update whichever remaining PR the merge just re-staled, then
      repeat — the same re-stale ordering as § *Re-staling is unavoidable
      under `strict`*.

   The agent did the **initial** branch-update for the PRs it reported
   `pr_pending_reverification`; **you** own the **re-stale re-updates**
   from here (each merge knocks the rest BEHIND again). `pr_merged` /
   `pr_automerge_armed` entries need no cascade (already merged, or native
   auto-merge fires on green); only `pr_pending_reverification` does. This
   keeps every wait in the orchestrator's one blessed helper, never in the
   agent.

   **Pre-dispatch hook (when `plan[i].pre_dispatch_hook` is present).**
   Some groups need an environment check before their agent is spawned —
   e.g. a runtime-upgrade agent's cascade depends on the target
   interpreter being installed locally, and subagents can't prompt the
   user interactively, so the decision must happen here. The orchestrator
   has **no language knowledge**: it runs the hook the plan attached,
   dispatching on the hook's `type`, and passes the outcome to the agent
   via the field the hook names. When `pre_dispatch_hook` is absent, skip
   straight to step 3.

   The only hook `type` defined in v2 is **`runtime_availability`**:

   ```json
   "pre_dispatch_hook": {
     "type": "runtime_availability",
     "script": "development-python/scripts/pre-dispatch-runtime-upgrade.zsh",
     "target": "3.14",
     "prompt_field": "local_verification_mode",
     "modes": { "available": "auto", "unavailable": "skip" },
     "label": "Python 3.14 interpreter"
   }
   ```

   `script` is relative to `<plugin-base-dir>` and the planner has
   already extracted `target` (e.g. `3.14` from a
   `python:3.14-slim-bookworm` PR). Run its `detect` subcommand:

   ```bash
   "<plugin-base-dir>/<pre_dispatch_hook.script>" detect "<pre_dispatch_hook.target>"
   ```

   The script probes the standard install locations and prints a JSON
   result on stdout. Exit 0 = the runtime is available, exit 1 = missing.

   - **Available** (exit 0) → spawn the agent, adding
     `<prompt_field>: <modes.available>` to its prompt, and proceed
     normally.
   - **Missing** (exit 1) → **ask the user** via `AskUserQuestion`,
     naming `<label>` in the question, with exactly these three options:

     1. **"Install `<label>` now"** — orchestrator runs the script's
        `install <target>` subcommand, then re-runs `detect`. If
        re-detect still fails, surface the install error and re-ask the
        user (don't silently fall through to skip).
     2. **"I'll install it myself"** — pause, point the user at the
        plugin's installation guidance, then ask a follow-up
        `AskUserQuestion` "Ready to continue?" with options
        ["Yes, re-check", "Cancel — skip"]. On "Yes, re-check", re-run
        the `detect` subcommand; loop at most once, then fall through to
        skip.
     3. **"Skip"** — spawn the agent with
        `<prompt_field>: <modes.unavailable>`. The agent makes only the
        changes it can without local verification (for the runtime
        upgrade: the Dockerfile + `requires-python` edits only); CI does
        the real verification.

   The agent's prompt gains one extra field, named by the hook:

   ```text
   <pre_dispatch_hook.prompt_field>: <modes.available> | <modes.unavailable>
   ```

   If `pre_dispatch_hook.type` is unrecognized, skip the hook, spawn the
   agent without the extra field, and record it in the Phase 9 summary as
   a quality bug — the plan referenced a hook protocol this orchestrator
   version doesn't implement.

3. **Wait for the agent** → receive **both** the worktree branch and
   the worktree path. The Claude Code runtime returns both alongside
   the agent's response because you passed `isolation`. **Capture
   both** — the branch is what you push, the path is what you
   `git worktree remove` post-merge (step 6 in the CI cycle below).

   **If the agent returns no worktree branch but the main workspace is
   dirty, that's a contract violation** — surface it as a quality bug;
   do NOT bridge it by creating a `maint/...` branch from the dirty
   workspace. See `reference/pr-cycle.md` § Worktree-branch contract
   violations.
4. **Push** the worktree branch to origin, **open the PR** against the
   effective base branch (titled per the plan entry's
   `suggested_pr_title`, with a body per **§ PR body** above — template-
   conforming, never prose, so the Approver's baseline is satisfied), and
   capture the new PR number. Record the stage in `phase8-stages` —
   branch, PR number, `status: pr_opened` (§ Per-stage checkpoint
   records).

   **Missing-coverage-report fallback (#655).** Every worktree agent's
   contract says to leave its coverage report in the worktree (#644), so
   the pre-push hook normally passes first-attempt. If a push still
   fails on a missing report (an agent that slipped the contract),
   recover deterministically — regenerate it **in the artifact
   worktree** with the language's documented command (`pytest --cov
   --cov-report=xml` / `./gradlew test jacocoTestReport` / `swift test
   --enable-code-coverage`), retry the push **once**, and note the
   contract slip in the run summary (it's a plugin bug to file). Never
   improvise beyond that one retry.
5. **Close superseded vendor PRs.** Inspect the agent's response for
   any `actions_taken[].superseded_prs` entries (currently emitted by
   `python-major-upgrade`; any future agent that opens a replacement
   for a vendor PR uses the same field). For each PR number listed,
   close it with a "Superseded by" comment referencing the
   replacement:

   ```bash
   for superseded in <pr numbers from response>; do
     GH_TOKEN="$(cat "$maint_token_file")" gh pr close "$superseded" \
       --comment "Superseded by #<replacement_pr> — local major-upgrade with full audit + tests."
   done
   ```

   Use the `claude-maintenance` App token (from earlier in this phase)
   when available so the close attributes to `claude-maintenance[bot]`,
   matching who opened the replacement. Without the token, fall back
   to the user's `gh` auth.

   Close **before** the CI cycle starts (next step), not after merge,
   and reopen with `gh pr reopen <n>` if the replacement is later
   rejected. See `reference/pr-cycle.md` § Why close superseded vendor
   PRs before the CI cycle.
6. **Run the CI cycle** (same as Stage 0).
7. **After merge, sync local main**.
8. Continue to the next group.

### CI cycle (used by all stages)

After pushing and opening the PR:

1. **Monitor checks** until completion:

   ```bash
   gh pr checks "<pr_number>" --watch
   ```

   To poll in the background (or anywhere you'd otherwise hand-roll a wait
   loop), use the blessed poller instead of a bare `while [ … ]; do … done` —
   such a loop leaks its final test's nonzero status and reports a *successful*
   settled poll as a failure (#412):

   ```bash
   "<skill-base-dir>/scripts/await-pr-checks.zsh" "<pr_number>"
   ```

   It exits 0 the moment the checks settle — printing the green/red verdict for
   you to read — and reserves nonzero for real failures only (timeout → 3,
   gh/auth/network → 1). Never let a poll loop's trailing `[ … ]` test be the
   command result.

   **1b. Settled GREEN but a *required* check is CANCELLED → re-run it,
   deterministically (#656).** A cancelled check is neutral for the greenness
   verdict (#522 — the Approver-gate jobs cancel by design), but a cancelled
   **required context** can never satisfy branch protection: the verdict says
   GREEN while the merge silently stays BLOCKED (observed 2026-07-09: a
   `cancel-in-progress` concurrency race cancelled the required `sonarcloud`
   job mid-run while every sibling succeeded). So after settle, when the
   verdict is GREEN but the "other" bucket is non-zero, cross-check it against
   branch protection:

   ```bash
   required=$(gh api "repos/<owner/repo>/branches/<base_branch>/protection" \
     --jq '.required_status_checks.contexts[]' 2>/dev/null)
   cancelled=$(gh pr checks "<pr_number>" --json name,bucket \
     --jq '[.[] | select(.bucket == "cancel") | .name][]')
   # any name in BOTH lists → a cancelled required check
   ```

   For each cancelled **required** check: re-run just its job —
   `gh run rerun <run-id> --failed` (the run id via `gh run list
   --branch <headRefName> --json databaseId,name`), or the job-level rerun —
   then **re-enter step 1** and wait for the fresh settle. **Cap: 2 re-runs
   per PR** (mirroring the CI-fix cap); if the required check is still
   cancelled after that, record the stage `escalated` naming the check —
   don't loop forever on a repeating concurrency race. Cancelled
   **non-required** checks stay neutral exactly as today (#522) — no re-run.
2. **If all checks pass** (and no required check is cancelled, per 1b) →
   proceed to step 5 (approval gate) below.
3. **If any check fails**, distinguish **new** from **pre-existing**
   failures before spending tokens on the CI-fix agent
   (`<response.ci_fixer_agent>`, captured in Phase 6).

   A failure already red on `<base_branch>` isn't caused by this PR —
   classifying first avoids wasting fixer tokens on it (see
   `reference/pr-cycle.md` § New vs pre-existing failures).

   Run the classification:

   ```bash
   # 1. failing check names on this PR
   gh pr checks "<pr_number>" --json name,state \
     --jq '[.[] | select(.state == "FAILURE") | .name] | sort | unique' \
     > /tmp/pr_fail.json

   # 2. failing check-run names on <base_branch>'s latest commit
   #    (use the same names that gh pr checks reports — workflow + job name)
   gh api "repos/{owner}/{repo}/commits/<base_branch>/check-runs" \
     --jq '[.check_runs[] | select(.conclusion == "failure") | .name] | sort | unique' \
     > /tmp/base_fail.json

   # 3. new failures = PR failures − base failures
   comm -23 /tmp/pr_fail.json /tmp/base_fail.json > /tmp/new_fail.json
   # 4. pre-existing failures = PR failures ∩ base failures
   comm -12 /tmp/pr_fail.json /tmp/base_fail.json > /tmp/preexisting_fail.json
   ```

   (The intent is the set diff, not the exact incantation — see
   `reference/pr-cycle.md` § New vs pre-existing failures for the
   `gh`/`comm`/`jq` shell notes.)

   **Per-tool override (conservative).** Before treating any check as
   pre-existing, **promote any check matching THIS PR's own tool back
   into the "investigate" bucket** — the PR's tool is `plan[i].tool`
   (or `coverage` for the Stage 0 improver PR), matched against check
   names by case-insensitive substring. A same-tool failure is never
   trusted as "pre-existing". See `reference/pr-cycle.md` § Per-tool
   override for the reasoning and worked examples (sonar / snyk_prs /
   dependabot / Stage 0).

   After applying this override:

   - **All remaining (non-same-tool) failures pre-existing** AND **no
     same-tool failures** → log the pre-existing names ("pre-existing
     on `<base_branch>`: `<list>`"), treat them as a noop for merge
     gating, proceed to step 5 (approval gate). Record in the run
     summary so the user knows they're still red.
   - **At least one same-tool failure** OR **at least one new
     non-same-tool failure** → if `response.ci_fixer_agent` is `null`
     (a topic group whose plugin declined a CI-fixer in v1) **or the named
     agent cannot be spawned** (it isn't installed in this plugin family —
     a topic may name a *language* plugin's fixer, e.g. `react` reuses
     `js-ci-fixer`), **escalate this PR to the user** instead of fixing:
     leave it open, record it in the Phase 9 summary as needing manual
     attention, and move to the next stage without merging. **Never
     substitute a different fixer** — an installed fixer for another
     language would edit this PR with the wrong toolchain's idioms.
     Otherwise spawn `<response.ci_fixer_agent>`
     for that combined set. Pass two things in its prompt:

     - `failing_checks: <list>` — the names from the combined bucket
       above (truly-pre-existing failures are NOT in this list).
     - `pr_scope` — what this PR was responsible for, so the fixer
       can distinguish "this PR should have fixed X but didn't" from
       "X isn't this PR's responsibility, escalate." Shape:

       ```json
       {
         "tool":        "<plan[i].tool>",
         "description": "<plan[i].description>",
         "files":       <plan[i].files>,
         "findings":    <plan[i].findings, full objects with keys + messages>
       }
       ```

       For Stage 0 (coverage improver), use:

       ```json
       {
         "tool":             "coverage",
         "description":      "Raise coverage on under-covered modules",
         "files":            <modules the improver was supposed to bring above threshold>,
         "target_threshold": <the Required value, e.g. 80 or 90>
       }
       ```

     The fixer uses `pr_scope` to scope its work at the **tool
     level**: every failing finding from this PR's tool is in scope,
     other tools' checks are out of scope (escalated). Same-tool
     scope is exhaustive — `pr_scope.findings` is informational
     context for the fixer (what the work agent intended to address),
     not a filter for narrowing scope further. See the CI-fix agent's
     own doc for the full decision table (for `development-python`,
     `python-ci-fixer.md` step 3).

4. **Process the fixer's response.** The fixer returns JSON
   distinguishing three outcomes:

   - `resolved: true` with empty `out_of_scope_failures` → fixer made
     a commit; **re-trigger CI on the new head, then** re-monitor for the
     next check round. Don't assume the fixer's push re-ran CI: a fixer
     pushing under a bot **App installation token** fires a `synchronize`
     that GitHub does **not** turn into workflow runs (#605), so the new
     head can sit with zero checks and never settle. Run the blessed
     helper — it is identity-agnostic (a no-op nudge when the push already
     ran CI, a deterministic close+reopen re-trigger when it didn't):

     ```bash
     "<skill-base-dir>/scripts/retrigger-pr-ci.zsh" "<pr_number>"
     # emits `result: CI-RUNNING` (checks registered — no nudge) or
     # `result: NUDGED` (closed+reopened to re-trigger CI, auto-merge re-armed)
     ```

     Then re-monitor with `await-pr-checks.zsh` as before.
   - `resolved: true` with non-empty `out_of_scope_failures` → the
     failure was classified out of scope (a different tool's check
     failing, or a generic check pointing at files outside this PR's
     diff). **This PR is safe to merge** — skip further fixer
     invocations for that check, proceed to step 5 (approval gate).
     Record the out-of-scope failures so they appear in the run
     summary.
   - `resolved: false` → fixer couldn't resolve an in-scope failure;
     `escalation_recommendation` says why. Re-monitor only if a fix
     commit was made; otherwise count this attempt.

   **Repeat up to 3 fixer invocations on the remaining in-scope new
   failures**. After each fixer commit, re-monitor and re-classify
   (a new failure might resolve while a different pre-existing one
   persists — that's still a green light to merge per the previous
   bullet). If in-scope failures still persist after 3 attempts, **do
   not merge** — record the PR in `actions_requiring_review` for the
   final summary and **continue to the next stage**. Failure on one
   stage does not block later stages.
5. **Approval gate — never merge without an approving review (#224).**
   A maintenance merge requires an approving review from the Approver
   bot (`claude-approver-<owner>[bot]`) or a human on the PR's current
   state. You
   must **never** satisfy this yourself: posting
   `gh pr review --approve` with the user's gh identity is
   self-approval with admin credentials and is forbidden (see "What
   you will NOT do").

   **Branch on the approver mode** detected in Phase 2.5
   (`checkpoint.zsh load --phase approver_mode`; default `none`):

   - **`ci`** — a CI-side Approver workflow fires on
     `check_suite: completed`, so once CI is green its verdict typically
     lands within a few minutes. Use the `--retrigger` merge-cycle path
     below.
   - **`local`** (the default since epic #476) — there is **no** CI-side
     workflow, so **do not `--retrigger`**: a `/approve` comment would
     post under the user's identity and then wait out its window for a
     workflow that never runs (~10 min wasted per stage, #642). Instead,
     once checks settle green, **drive the language plugin's `approve`
     skill directly** and then confirm the merge — the local-mode path
     below.
   - **`none`** — no Approver available; fall through to the human /
     native-auto-merge handling (the `NONE` / `REVIEW_REQUIRED` branches
     below).

   When you drive the review yourself (the language plugin's `approve`
   skill spawning the local approver agent), mint the Approver token
   **just-in-time**: after `await-pr-checks.zsh` / `merge-pr-cycle.zsh`
   report settled, immediately before dispatching the review agent —
   never alongside PR creation. App installation tokens live 1 hour; a
   token minted before the CI wait can expire mid-wait, and the
   approver agent then hard-fails on the dead credential and needs a
   re-mint + resume round-trip (#524).

   **`ci` mode — use the blessed merge-cycle helper — do NOT hand-roll this
   loop (#431).** The tick-client-snapper run's improvised background loops
   re-triggered the Approver ~30s after `update-branch` (before the new SHA's
   checks had even registered, burning the one re-trigger), and mangled push
   refspecs forcing fresh SHAs. `merge-pr-cycle.zsh` does the subtle parts
   correctly: it waits for the head SHA's checks to *register* and settle
   (re-pinning if a rebase lands mid-wait), reads `reviewDecision`, and — with
   `--retrigger` — posts a single `/approve` comment to re-trigger the Approver
   (the gate honours it, #190), never an empty-commit push:

   ```bash
   "<skill-base-dir>/scripts/merge-pr-cycle.zsh" --retrigger "<pr_number>"
   # add --update first for a vendor PR that's BEHIND under strict branch protection
   ```

   **`local` mode — drive the approve skill, no `--retrigger` (#642).** There
   is no CI-side workflow to re-trigger, so run the same helper **without**
   `--retrigger` to wait for the head SHA's checks to register + settle, then
   drive the language plugin's `approve` skill to earn the verdict, then merge:

   ```bash
   # 1. wait for green — no /approve comment posted (mode is local)
   "<skill-base-dir>/scripts/merge-pr-cycle.zsh" "<pr_number>"
   #    add --update first for a vendor PR that's BEHIND under strict branch
   #    protection. Exit 4 (AWAITING-APPROVAL) here is expected — green but
   #    unapproved — and is the cue to drive the approve skill next; exit 6
   #    (NOT-GREEN) → back to step 3; exit 3 (TIMED-OUT) → record + move on.
   # 2. mint the Approver token just-in-time (a mode-600 file path, #640) and
   #    drive the approve skill — it spawns the local approver agent, which
   #    posts APPROVE as claude-approver-<owner>[bot], never your identity:
   /development-<lang>:approve "<pr_number>"
   # 3. re-read reviewDecision (below).
   ```

   Then, on the re-read `reviewDecision`:
   - **`APPROVED`** → step 6 (merge).
   - **`CHANGES_REQUESTED`** → the `CHANGES_REQUESTED` handling below.
   - **anything else** (still `REVIEW_REQUIRED`/`NONE`, or a
     COMMENT-with-reservations that isn't a binding `APPROVE`) → the
     approve skill did not clear the gate; **do not `--retrigger`** (there
     is no workflow to nudge). Arm native auto-merge, record the outcome
     as `awaiting_approval`, and move to the next stage — exactly the
     `local` sub-branch of the `REVIEW_REQUIRED` timeout case below. Do
     **not** fall through into the shared `--retrigger` poll.

   No `/approve` comment is ever posted in local mode — that was the ~10-min
   dead wait + user-identity noise this branch removes (#642).

   For the `ci`-mode helper, branch on its single `result:` line / exit code:
   `READY` (0) → step 6 (merge); `CHANGES-REQUESTED` (5) → the
   `CHANGES_REQUESTED` handling below — always a rejection of the **current
   head**: a stale request-changes pinned to a superseded commit comes back
   as `AWAITING-APPROVAL` (4) with a stale note instead, since that is
   re-review territory, not a terminal verdict (#523); `AWAITING-APPROVAL`
   (4) or `TIMED-OUT`
   (3) → arm native auto-merge and move on (the `REVIEW_REQUIRED` branch below);
   `NOT-GREEN` (6) → back to step 3. The manual poll below is exactly what it
   automates — drop to it only when you need the finer-grained in-run
   rejection-fix rounds.

   Poll the review decision (30s interval, 10-minute budget):

   ```bash
   gh pr view "<pr_number>" --json reviewDecision --jq '.reviewDecision // "NONE"'
   ```

   - **`APPROVED`** → proceed to step 6 (merge).
   - **`CHANGES_REQUESTED`** → fetch the latest `CHANGES_REQUESTED`
     review. If it is from the Approver (login matches
     `^(app/)?claude-approver` — App slugs are owner-suffixed, #229)
     and carries the
     `<!-- claude-approver:findings ... -->` block → **fix in-run**:
     run the Phase 2.5 re-ingest machinery scoped to this PR (parse
     the hidden JSON, group findings by `suggested_agent`, dispatch
     the agents against this stage's still-attached worktree, push).
     CI re-runs, the Approver re-evaluates, and you re-enter this
     gate. **Maximum 2 rejection-fix rounds per PR** (independent of
     the 3-CI-fix cap); after that, record in
     `actions_requiring_review` with the Approver's findings and move
     to the next stage. If the rejection is from a **human**, escalate
     immediately — that's their call, not yours to litigate.
   - **`NONE` on the first poll** → the repo has no review-requiring
     branch protection, so `reviewDecision` will never flip. Check for
     an explicit approval instead:
     `gh pr view "<pr_number>" --json latestReviews --jq '[.latestReviews[] | select(.state == "APPROVED")] | length'`.
     Non-zero → proceed to step 6. Zero → do **NOT** arm auto-merge
     (with no review requirement it would merge instantly, bypassing
     approval); leave the PR open, record as awaiting approval, and
     continue to the next stage.
   - **`REVIEW_REQUIRED` still at timeout** (Approver slow, gates
     exit-78'd, or Approver not installed on this repo) → **arm
     GitHub's native auto-merge**: remove the worktree first (same
     ordering rule as step 6), then

     ```bash
     gh pr merge "<pr_number>" --auto --squash --delete-branch
     ```

     After arming, **poll for the verdict — but branch on the approver
     mode (#642), never `--retrigger` outside `ci` mode:**

     - **`ci`** — a server-side workflow can still post the verdict, so
       re-trigger it and poll:

       ```bash
       "<skill-base-dir>/scripts/merge-pr-cycle.zsh" \
         --retrigger --timeout 600 "<pr_number>"
       result_code=$?
       ```

     - **`local`** — you already drove the `approve` skill above and it
       did not yield a binding `APPROVE`; there is no workflow to nudge.
       Poll **without** `--retrigger` for a late-landing verdict, then
       stop — no `/approve` comment:

       ```bash
       "<skill-base-dir>/scripts/merge-pr-cycle.zsh" --timeout 600 "<pr_number>"
       result_code=$?
       ```

     - **`none`** — no Approver exists; do **not** poll for a verdict
       that can never come (that was the ~10-min dead wait, #642). The
       native auto-merge is armed and will fire if a human approves;
       record the outcome as `awaiting_approval` and move on
       (`result_code=4`).

     Then map `result_code` (skip this mapping in `none` mode, which set
     it to 4 directly):

     - Exit 0 (READY): Approver approved, PR merged (or will merge
       immediately). Record outcome as `merged`.
     - Exit 4 (AWAITING-APPROVAL): CI green but no approval within the
       wait window. Record outcome as `awaiting_approval` (not `automerge_armed`,
       which was misleading — the PR is armed but won't merge without
       explicit approval, which may not arrive for hours/days). This is
       also the verdict when the only rejection is a **stale**
       request-changes pinned to a superseded head — the `result:` line
       names the old commit (#523); a fresh review supersedes it.
     - Exit 5 (CHANGES-REQUESTED): Approver or reviewer objected **at the
       current head** (stale rejections are exit 4, above). Record
       in `actions_requiring_review` with the rejecting review reason.
     - Exit 3 (TIMED-OUT): Checks didn't settle. Record in
       `actions_requiring_review` as "timed out waiting for CI".
     - Exit 6 (NOT-GREEN): Required checks failed. Record in
       `actions_requiring_review` with failing checks.

     If arming fails (repo setting "Allow auto-merge" is off), leave
     the PR open and record it in `actions_requiring_review` as awaiting
     approval (do not invoke merge-pr-cycle in this case).

   A stage that ends `automerge_armed` or awaiting-approval did
   **not** merge: skip steps 6–8 for it, and the next stage builds
   against `<base_branch>` without this stage's changes — the same
   sequencing consequence as an escalated stage, and acceptable for
   the same reason (stages are independent tool groups).

6. **Remove the local worktree first, then merge the PR.** Order
   matters: `gh pr merge --delete-branch` tries to delete the local
   branch ref, which fails with *"cannot delete branch X used by
   worktree at Y"* if the worktree is still attached. The merge + the
   remote-branch delete still happen, but the local ref is left
   behind and the next stage's `cleanup` won't find a clean slate.

   ```bash
   # Free the local branch from its worktree first.
   # <worktree_path> is what the Agent runtime returned alongside the
   # branch name in step 3 — capture both, use both here.
   #
   # IMPORTANT: -f -f (double force), not single -f — agent worktrees
   # are locked by the runtime and the lock survives process exit, so
   # single -f fails with "cannot remove a locked working tree". See
   # reference/pr-cycle.md § Why `-f -f` (double force) on worktree removal.
   git -C "<repo.path>" worktree remove "<worktree_path>" -f -f

   # Now gh can cleanly delete the merged branch from both ends.
   gh pr merge "<pr_number>" --squash --delete-branch

   # Belt-and-suspenders: prune any administrative refs left over from
   # earlier runs where the remove failed silently.
   git -C "<repo.path>" worktree prune
   ```

   If `<worktree_path>` is empty (legacy path where isolation didn't
   apply — shouldn't happen after #64), skip the `worktree remove`
   step and just call `gh pr merge`; the local-branch delete will
   then succeed because there's no worktree holding the ref.

7. **Sync local main** so the next stage starts from the updated tree:

   ```bash
   git -C "<repo.path>" switch "<base_branch>"
   git -C "<repo.path>" pull --ff-only origin "<base_branch>"
   ```

   Then record the stage as `merged` in `phase8-stages`
   (§ Per-stage checkpoint records).

8. **Re-run the state pre-flight from Phase 3.** A merge — especially
   of a runtime-version-bumping PR — can leave local state (venv,
   toolchain cache, etc.) inconsistent with the new `main`, so later
   stages would verify against stale state. See `reference/pr-cycle.md`
   § Why re-run the state pre-flight after each merge.

   Invoke the same per-language helper from Phase 3:

   ```bash
   "<skill-base-dir>/scripts/verify-<lang>-state.sh" "$(pwd)"
   ```

   Handle the exit code per Phase 3's script-contract table. The R.4
   fallback applies here too — the script's exit-2 JSON drives the
   `AskUserQuestion` shape.

   **In-memory skip flag.** If R.4's option 1 ("fall back to previous
   configuration locally") was chosen earlier in this run, set a
   run-scoped flag and SKIP this step on every subsequent stage. The
   user has explicitly accepted the mismatch; re-asking on every stage
   would be noisy. The flag is in-memory only; the next
   `/development:maintenance` invocation re-evaluates from scratch.

### Agents commit before returning

The agent's final procedure step runs
`git add -A && git commit -m "<commit_subject>"` on its worktree branch
(only when it made changes). The orchestrator then pushes that
already-committed branch — no ad-hoc "commit pending changes" logic in
this phase. **If a worktree branch comes back uncommitted, that's a
legacy-agent quality bug** — surface it in the summary; do not silently
bridge it.

This pairs with the isolation contract in step 2: the agent only ever
commits to its own worktree branch, and the orchestrator only ever
pushes a branch the runtime created. Together those two invariants
keep `main`'s working tree clean throughout the entire run.

If `--no-merge` was passed: skip this phase. List the branches in the
final summary so the user can merge manually.

## Phase 9 — present the summary

### Before rendering — cross-link known issues

Before emitting any advisory / TODO / "investigate this" line in the
run notes, check whether the project already has an open issue
tracking it. List the repo's open issues:

```bash
gh issue list --state open --limit 50 --json number,title,labels
```

For each advisory you're about to emit, scan the titles for an
obvious topical match (keywords from the advisory's subject — tool
name, bug type, version pin, etc.). If you find one, append
`(see #<n>)` to the advisory line so the user isn't pointed at
investigation work that's already filed.

Be conservative — only cross-link when the topical match is
unambiguous. A wrong `(see #N)` is worse than no link. If you're
unsure, omit the link. (Worked examples in `reference/report.md`
§ Cross-linking known issues.)

The same applies for the **plugin repo's** issues
(`timo-jakob/timos-claude-code-plugins`) when the advisory is about
the maintenance pipeline itself (e.g., a recurring scrape failure,
a known agent quirk) — use `gh issue list --repo <plugin-repo>`.

### Snyk channel naming

When the Render template's pre-existing-failures section names a Snyk
channel, disambiguate the **three** independent Snyk channels — the Snyk
GitHub App PR checks (`security/snyk (<org>)` etc.), the workflow `image`
job (`snyk container test`), and any legacy in-workflow `snyk-code` /
`snyk-open-source` jobs. Phrase a `security/snyk (<org>)` **ERROR** state
as an infrastructure/quota condition, not a finding on the diff (never
call it a "legacy job to remove" — check the workflow first). The `image`
job channel now also feeds the `container_scan` finding source (harvested
from its `snyk-container-scan` artifact, #299): a red `image` check and the
`container_scan` findings describe the **same** base-image CVEs — attribute
them to one channel, don't double-count. And surface
any `Snyk findings via REST API (no quota consumed): …` gather note
verbatim in the "Notes from the gather step" section. Full channel table,
the exact ERROR phrasing, and the no-quota-note rule live in
`reference/report.md` § Snyk channel naming — guidance for you, not
output.

### Render

Render a user-facing summary. Each language's results are reported in
its own block so it's clear which plugin produced what.

```text
=== Maintenance summary ===

Project:       <repo path>
Branch:        <user's current branch>
Languages processed: <comma-separated list from supported>
Topics gathered:     <comma-separated list from supported_topics, or "none">
                     <per-topic dispatch/processing status is in the blocks below>
Approver mode:       <ci | local | none — from the Phase 2.5 detection (#642);
                      in local mode the approval gate drove the approve skill
                      directly, posting no /approve comment>
<If any approver verdict this run carried an `approver_permission` finding (#654):>
⚠ Approver App permission gap: security_events:read missing on this
  installation — Code Scanning reads fell back to your gh auth. One-time fix:
  re-accept the App installation after the permission update
  (install-claude-apps.zsh --verify shows the exact steps).
  This is surfaced HERE and in the verdict — never written to session memory;
  plugin-fixable constellations ship in the plugin (#654).
<If --tool=<name> was set:>
⚠ Scoped to single tool: <name>
  Other tools were gathered but not dispatched. Re-run without --tool
  to process them.
<If --concern=<name> was set:>
⚠ Scoped to concern: <name> (tools: <comma-separated expanded set>)
  Tools outside this concern were gathered but not dispatched. Re-run
  without --concern (or with the other concerns) to process them.
<If --batch=N was set AND the plan had more than N groups:>
⚠ Batch-limited: processed the top <N> of <M> planned groups (by priority).
  The remaining <M−N> are deferred (listed below) — re-run
  /development:maintenance to process the next batch.

<If unsupported is non-empty:>
⚠ Languages detected but not yet supported:
  - <lang>: <the note recorded when it entered this bucket>
    (e.g. "no development-<lang> plugin built yet — see README's Plugins
     section for current per-language status", "gather failed: <error>",
     "dispatch failed: <error>")

<If unsupported_topics is non-empty:>
⚠ Topics detected or NOT EVALUATED, and not processed:
  - <topic>: <the note recorded when it entered this bucket>
    (e.g. "no gather-<topic>-findings.zsh yet", "marker present but required
     language <lang> is not in the supported set", "jq not on PATH: the React
     marker could not be evaluated", "kubernetes marker: search did not
     complete — the topic was not evaluated", "gather failed: <error>",
     "manifest listing did not complete: <stderr>", "dispatch failed: <error>")
    The heading says "or NOT EVALUATED" deliberately: an entry whose marker
    exited non-0/1 was never detected, and a bare "detected" heading would
    assert the very fact the marker refused to assert.

<If topic dispatch was skipped because --tool/--concern scoped the run:>
ℹ Topic checks skipped under --tool / --concern (those flags scope the
  language tool set). Re-run without scoping to process topic findings.

<If --dry-run AND Phase 2.5 ran its read-only detection (apps.json
present). Report the Approver backlog that a live run WOULD have
pushed fixes for — detected, never dispatched:>
🔎 Approver backlog (dry-run — detected, not dispatched):
  <If any flagged PRs were found:>
  - PR #<pr>: <N> finding(s) a live run would dispatch:
      → <agent>: <count> finding(s) (<comma-separated finding titles>)
      ...
  ...
  <For findings with suggested_agent: null, the same "needs human
  attention" list a live run produces, but flagged as not acted on:>
  - PR #<pr>: <N> finding(s) need human attention (suggested_agent: null):
      - <title> — <detail>
  ...
  <If apps.json present but no PRs were Approver-flagged:>
  No Approver-flagged PRs — nothing a live run would push.

<For each topic in supported_topics, a block. Topics are NOT languages — the
 per-language block below never renders them, so without this block a topic's
 verdict, its missing_tooling and its escalations would have nowhere to go:>
--- <topic> ---
<Verdict — worded from the topic payload's `tooling_configured`, per Phase 6.
 The cases are ordered and EXHAUSTIVE; never infer "clean" from an absent plan:>
  <If the topic was never DISPATCHED — no plan exists (topic dispatch skipped
   under --tool/--concern, or --dry-run):>
  Gathered but not dispatched — no verdict for this run.
  <Else if the RESPONSE carried a non-empty human_action_required — the
   dispatcher deliberately halted. This case comes BEFORE the two below: the
   halt shape is an empty plan with an empty missing_tooling, which would
   otherwise fall through to "Clean" and report an escalation as a clean bill of
   health. `development-kubernetes` returns exactly this shape for a payload it
   cannot understand — an unrouted `findings_by_tool` key, a `dispatch_mode`
   outside its enum, or `manifest_validation: false`:>
  Halted — <N> group(s) need a human decision.
    <one line per entry: <reason> → <recommendation>>
  <Else if tooling_configured is EMPTY (no tools registered for this topic yet):>
  No tools registered for this topic yet — nothing was inspected.
    <cite the topic's gather `notes` here>
  <Else if the plan was empty AND missing_tooling is empty:>
  Clean — the topic's tools ran and found nothing.
    <cite any gather `note` that CONTRADICTS that reading — e.g. kubernetes'
     "presence-detected only", which means the tools did not run in the gather>
  <Else if groups were planned:>
  <N> group(s) planned, <M> processed.
  <Otherwise: state the observed state plainly.>

  <`--no-merge` is a SUFFIX on the verdict above, never a replacement for it —
   the topic WAS dispatched, so its verdict is known and must still be stated.
   BOTH lines below are inside this condition; omit the whole section whenever
   Phase 8 ran, since processed and escalated groups are reported by the 🚀 and
   ! sections instead — rendering both would claim the same groups were merged
   AND not processed:>
  <If Phase 8 was skipped (--no-merge) and groups were planned:>
    — Phase 8 skipped (--no-merge); no PRs were opened for this topic.
  📋 Planned groups (not processed) — every group in the plan:
    - <group_id>: <description> → <agent>

<If the topic response carried missing_tooling:>
? Missing tooling (<N>):
  - <tool>: <summary> — <how_to_add>

<If any topic group opened a PR:>
🚀 PRs opened & merged:
  - PR #<pr>: <title> — <merged|open>

<If any topic stage ended escalated (a null or unspawnable ci_fixer_agent, or
 3 failed CI-fix attempts) OR is awaiting approval — these are distinct terminal
 states in the phase8-stages enum, not one:>
! Needs your attention:
  - PR #<pr>: <reason>
    <If the stage failed CI:> Last failing checks: <names>
    Suggested action: <what the user should do>
--- end <topic> ---

<For each language in supported, a block:>
--- <lang> ---

<If findings-<lang>.json has a non-null .sonar_quality_gate (#50),
render the verdict line FIRST — it's the broadest system-health
signal. Map .status to the display word: OK→PASS, ERROR→FAIL,
WARN→WARN, NONE→"not computed". When FAIL or WARN, list each
condition whose .status != "OK" as a bullet.

**Scope the label honestly (#433).** SonarCloud's default `Sonar way`
gate measures **new code only** (its conditions are `new_*` metrics), so
a PASS means "no new-code regressions" — NOT "the codebase is clean".
Title the line `new code` and append the caveat, so a PASS is never read
as overall Sonar health (the run that motivated #433 flipped the gate to
PASS while the legacy/overall issue backlog was essentially untouched —
"Reported numbers must be reliable or withheld"). The overall/legacy
backlog is reflected by the category inventory below — the issues static
analysis surfaced this run — not by this gate.>

Quality Gate — new code (<default branch>): PASS|FAIL|WARN|not computed
  - <metricKey>: actual <actualValue>, threshold <comparator> <errorThreshold>
  ...
  (New-code gate only — it does NOT measure the overall/legacy issue
  backlog; the category inventory below shows what static analysis
  surfaced this run.)

<If .sonar_quality_gate is null or absent, omit the line entirely —
the pooled notes already explain why the fetch didn't happen.>

<Render the cross-tool category inventory next (#51) — system-health
at-a-glance before the per-tool detail. Invoke:>

  "<skill-base-dir>/scripts/categorize-findings.zsh" "/tmp/findings-<lang>.json"

<and paste its stdout verbatim. The script omits the block entirely
when all category totals are zero (clean run), so an empty result is
expected and means "skip this section." Counts reflect findings as of
run start; the 🚀 PRs section below shows what was tackled.>

<If response.plan is non-empty (planner ran):>
📋 Plan (M groups, N findings):
  1. [<tool>] <description>
     <findings-count> finding(s) across <files-count> file(s) — priority <score>
     → <agent>
  2. ...

🚀 PRs opened & merged (M):
  - #<pr> [stage 0: coverage] <title> — <merged|escalated after 3 CI fixes>
  - #<pr> [group 1: <tool>] <title> — <merged|escalated after 3 CI fixes>
  - ...

<If --batch=N deferred any planner groups (M > N):>
⏸ Deferred this batch — not processed (M−N):
  - [<tool>] <description> — <finding-count> finding(s), priority <score>
  - ...
  Re-run /development:maintenance (optionally with --batch) to process the
  next batch. These groups remain tracked as scanner-debt issues (Phase 10).

<If any vendor PR/stage ended awaiting_approval (armed but not approved within polling window) or requires review (#224, #458):>
⏳ Awaiting approval — not merged (N):
  - PR #<pr> ("<title>") — CI green, approval pending. PR is armed
    for auto-merge but did not approve within the ~10-min polling window.
    Will merge once approved (may take hours/days if approval is delayed).
  - ...

<If any vendor PR/stage merged during the approval-poll window:>
✅ Vendor PRs merged (N):
  - PR #<pr> ("<title>") — approved and merged during the run
  - ...

<If Phase 2.5 inventoried conflicting_bot_prs (#653):>
🔧 Conflicting bot PRs remediated (N):
  - PR #<pr> ("<title>") — rebased onto <base_branch> in a scratch worktree,
    suite green, force-pushed, <merged | auto-merge re-armed awaiting approval>
  <For an escalated one:>
  - PR #<pr> ("<title>") — rebase attempted but <suite red on the rebased
    head | lease conflict>; left untouched, recorded escalated: <reason>
  (Never render a bot PR's conflict as a manual-rebase to-do — the pipeline
  owns its own PRs' conflicts.)

? Missing tooling (N):
  - <tool>: <summary>
    <how to add>
  ...

! Stages requiring your review (N):
  - PR #<pr> ("<title>") — escalated after 3 CI-fix attempts failed.
    Last failing checks: <list>
    Suggested action: <from ci-fixer's escalation_recommendation>
  ...

<If any stage observed pre-existing failures on <base_branch>:>
ℹ Pre-existing CI failures observed on <base_branch> (not maintenance's
  scope — flagging so you know they're still red):
  - <check_name>: failing on <base_branch> and on PR #<pr> — merged anyway
    <if you can identify the channel, name it explicitly per the
    Snyk channel naming subsection above; otherwise just report
    the check name>
  - ...

<If human_action_required is non-empty for this language:>
🛑 Halted — human action required:
  - <reason>
    recommendation: <recommendation>

--- end <lang> ---

<If $template_drift array is non-empty:>
🧬 Template drift (rendered config files vs current bootstrap templates):
  <Render findings with `blocking == true` FIRST, each prefixed ⚠ — a
   blocking drift means this repo still has the OLD behavior of a required
   CI check (e.g. the pre-#386 blanket image scan that blocks app PRs).>
  <For each finding, one bullet:>
  - <file> — <severity>: <message>
    <if severity == "drifted">
        marker: v<marker_version> → current: v<current_version>
        <if .fixes is non-empty — name what a re-bootstrap delivers:>
        re-bootstrap would apply:
          - #<issue>: <summary>   <append " (BLOCKING required-check change)" when that entry's blocking==true>
        <end if>
        action: re-run /development:bootstrap to re-render, or
                patch by hand against the upstream template.
    <if severity == "unknown_provenance">
        action: re-run /development:bootstrap to add a marker so drift
                detection works on future runs.

<If pooled notes are non-empty:>
Notes from the gather step:
  - <note 1>
  - <note 2>

<If --no-merge:>
Worktree branches available for manual review (no PRs opened):
  - <branch>: <summary>
  - ...
```

Keep the tone factual. If everything was clean, say so: "No issues
found by the configured tools; project is in good shape."

**"Clean" is a claim about tools that RAN.** Exclude from it any topic whose
`tooling_configured` was empty — nothing inspected it, so it cannot be reported as
clean (Phase 6). When every supported target is in that state, say so plainly
instead: "No tools are registered for the detected topic(s) yet — nothing was
inspected." Reporting a no-op as a clean bill of health is the one summary error
that actively misleads.

## Phase 10 — track changes and findings as GitHub issues

**Runs by default.** Skip this phase entirely when `--no-issues` was
passed, or under `--dry-run` (a dry run performs no outward actions).
The goal (#384): every change the run made or proposed leaves a
traceable GitHub issue, so nothing lives only in the run summary.
**Group similar findings into one issue; split out anything that needs
its own human action.**

### 10a — scanner debt issues (per tool)

For each language's `findings-<lang>.json`, invoke the tracker:

```bash
"<skill-base-dir>/scripts/track-debt-issues.zsh" \
  --findings "/tmp/findings-<lang>.json" \
  --repo "<repo-path>" \
  --run-ref "<today's date> — <N> PR(s) opened this run"
```

The script handles the GitHub side end-to-end: ensures the labels
exist (`maintenance`, `tool:<name>`), finds existing tracking issues
by label combo, stamps the `--run-ref` into the body, and acts based
on the current finding count:

| Finding count | Existing issue? | Action |
| --- | --- | --- |
| > 0 | yes | Edit body (title + checklist refresh) |
| > 0 | no | Create new issue |
| 0 | yes | Close with "All `<tool>` findings resolved" comment |
| 0 | no | No-op |

One tracking issue per scanner tool (`ruff`, `semgrep`,
`code_scanning_alerts`, `sonarcloud`, `container_scan`). Within each issue's
body, findings are grouped by the tool's natural sub-category: `tool` for
code scanning (CodeQL / Scorecard), `type` for SonarCloud
(BUG / VULNERABILITY / CODE_SMELL / SECURITY_HOTSPOT), severity for
semgrep and `container_scan` (Snyk base-image CVEs), none for ruff (flat).

Body is capped at the top 50 findings (per-group cap is
`50 / num_groups` so one giant group can't eat the cap). The
remainder is summarized with a `+ N more — see source tool` footer.

PR-based tools (`dependabot`, `snyk_prs`, `renovate`, and the Go-only
`govulncheck`) are **not mirrored finding-for-finding** here — an open
vendor PR is already a first-class PR, and a `govulncheck` finding surfaces
as a `go-major-upgrade` PR tracked by the per-group PR cycle, not as
persistent scanner debt; duplicating either as a checklist item creates two
states to keep in sync. But when one is **deferred** to human review rather
than merged, that *outcome* does get a follow-up issue in 10b below (the
gap #384 closes).

### 10b — PR-cycle outcome issues (deferrals, escalations, suppressions)

The scanner tracker only mirrors *open findings*. The things the run did
or deferred during the **Phase 8** PR cycle — which otherwise live only in
the Phase 9 summary — also need a trail. For each outcome accumulated this
run, open (or update) a tracking issue, **one per PR**, idempotent on the
PR number:

- **Deferred vendor PRs** — a Dependabot / Renovate / Snyk PR the dispatch
  routed to `actions_requiring_review` (a breaking major upgrade, a Docker
  base-image policy deferral, etc.). The vendor PR stays the source of
  truth; the issue is a *follow-up pointer* so the human action isn't lost.
- **Escalated stages** — a maintenance PR abandoned after 3 failed CI-fix
  attempts, or rejected by the Approver / a human.
- **Applied suppressions** — findings an agent suppressed as false positives
  inside a merged PR (e.g. SonarCloud S-rules marked WONTFIX). The issue
  records *what* was suppressed and the *rationale*, so it stays auditable.

Ensure the follow-up label exists once, then for each outcome search for an
existing open issue before acting:

```bash
gh label create "maintenance:pr-followup" --color fbca04 \
  --description "Maintenance run outcome needing human follow-up" 2>/dev/null || true

gh issue list --label maintenance --state open \
  --search "PR #<n> in:title" --json number,title
```

For a **new** outcome (no existing open issue), create one:

```bash
gh issue create \
  --label maintenance --label "maintenance:pr-followup" \
  --title "[maintenance] follow-up: PR #<n> — <short reason>" \
  --body "<body>"
```

If an open issue **already exists**, `gh issue edit <m>` refreshes its body.
If the underlying PR has since **merged/closed and needs no further action**,
`gh issue close <m>` with a one-line comment.

The body must carry: a link to the PR (`#<n>`), the **reason** it was
deferred / escalated / suppressed (verbatim from the agent's
`actions_requiring_review` / `escalation_recommendation`), the suggested
human action, and the run reference (today's date).

**Grouping rule.** One issue per PR is the default — each PR's follow-up is
its own human action. Only fold multiple items into one issue when they are
the *same* finding repeated (e.g. the identical SonarCloud rule suppressed
across several files of one PR → one issue listing them). When in doubt,
split.

**Honor the run's scope (#53 / #57).** Don't issue-spam: file only for
outcomes this run actually produced. A `--tool` / `--concern`-scoped run
files issues only for the tools in scope. A `--batch`-capped run files
PR-cycle follow-ups (10b) only for the groups it actually processed —
groups **deferred** by the batch cap weren't acted on, so they get no 10b
follow-up; they stay visible through the 10a scanner-debt issues, which
track the full finding backlog regardless of how many groups this run
processed.

### Report

Print the tracker's stdout (one line per tool — `created` / `updated` /
`closed` / `no-op`) **and** a one-line-per-PR-follow-up summary into the run
summary, so the user sees exactly what changed on the issues side.

### Run complete — clear the checkpoint (#517)

The run is finished; remove its checkpoint:

```bash
"<skill-base-dir>/scripts/checkpoint.zsh" clear
```

A completed run leaves no checkpoint behind — resume is only ever
offered for *interrupted* runs. When Phase 10 is skipped
(`--no-issues`), clear at the end of Phase 9 instead. (`--dry-run`
never wrote one.)

## What you will NOT do

- **Detection or tool invocation directly** — those are the gather
  script's job; you orchestrate them, you don't reimplement them.
- **Push to main directly, force-push, or `--no-verify`** — every
  change reaches `main` through a PR with passing CI. The CI fixer
  may push additional commits to an open PR's branch (that's the
  flow), but never to a protected base.
- **Approve any PR with the user's gh identity** — never run
  `gh pr review --approve` (or post any review) as the operator.
  Approval comes from the Approver bot or a human; your job
  ends at the approval gate (#224). Satisfying branch protection
  with the user's own admin credentials is self-approval and
  defeats the review model.
- **Run more than 3 CI-fix iterations per PR** — after 3, escalate
  via the summary and move on to the next stage. The user reviews
  the failing PR manually.
- **Process multiple stages in parallel** — stages are sequential so
  each runs against the previous merge's result. Within a stage, the
  spawned agent works in its own worktree.
- **Modify the dispatched language plugin's response** — pass the
  plan through verbatim. The dispatcher is the source of truth for
  what gets spawned per group; you just orchestrate the stages.
