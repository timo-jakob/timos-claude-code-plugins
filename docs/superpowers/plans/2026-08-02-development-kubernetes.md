# development-kubernetes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give infrastructure-as-code a home in the plugin family, so a repo of Argo CD manifests
and Helm charts with no application language can be bootstrapped into requirable CI and maintained
by the same orchestrator as everything else.

**Architecture:** A `development-kubernetes` topic plugin that can also be *primary*. It ships
**mechanism** — how to render, validate and policy-check manifests — while the repo under test ships
**policy** at `policies/kyverno/`. Absent policies skip rather than fail, so the plugin works in a
repo with no opinions. Maintenance mirrors the family: a gather script in `development`, a
dispatcher and agents in the new plugin. No approver agent.

**Tech Stack:** zsh + jq (gather scripts), bats (tests), Kyverno CLI, kubeconform, kube-linter,
helm, kustomize, trivy, GitHub Actions.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-02-kubernetes-iac-plugin-design.md`. Epic #1150; children #1151–#1155.
- **This repository is public. The motivating consumer is private.** No spec, skill, agent
  description, doc, test fixture or commit message may name that consumer, its repos, its
  architecture or its ADRs. Write "the motivating consumer" or "a private platform-infrastructure
  repo".
- **The plugin ships no Kyverno policies of its own.** Generic hygiene (probes, limits, non-root,
  `latest` tags) belongs to `kube-linter`. Duplicating it means two places to silence one false
  positive.
- **No file matching `policies/kyverno/**/*.{yaml,yml}` ⇒ skip with a note, never fail.**
  The glob is the contract, not the directory's existence; when policies ARE declared,
  violations fail.
- **No approver agent.** Do not add one, and do not add auto-approval anywhere.
- `plugin.json` and `.claude-plugin/marketplace.json` versions move in **lockstep**.
- Gather scripts are `zsh` with `emulate -L zsh; set -euo pipefail`, take an optional repo path
  (default `.`), and print JSON on stdout, exit 0 on a well-formed run.
- Naming: no abbreviations — `development-kubernetes`, never `development-k8s`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `development-kubernetes/.claude-plugin/plugin.json` | Plugin manifest |
| `.claude-plugin/marketplace.json` | Marketplace entry, lockstep version |
| `ARCHITECTURE.md` | Ownership boundary, policy convention, no-approver rationale |
| `development/skills/maintenance/SKILL.md` | Topic marker row for `kubernetes` |
| `development/skills/maintenance/scripts/gather-kubernetes-findings.zsh` | Findings gatherer |
| `development-kubernetes/skills/maintenance/SKILL.md` | Dispatcher — payload in, plan out |
| `development-kubernetes/skills/review/SKILL.md` | Review-panel wiring |
| `development-kubernetes/agents/*.md` | Five agents |
| `development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl` | The workflow template |
| `tests/kubernetes-plugin-skeleton.bats` | Skeleton + registry invariants (the #1151 gate) |
| `tests/gather-kubernetes.bats` | Gather behaviour |
| `tests/kubernetes-topic-marker.bats` | Extracts + EXECUTES the SKILL.md marker and manifests recipes; derives marker/prune parity against the gather |
| `tests/kubernetes-dispatcher.bats` | The dispatcher's prose contract, clause by clause |
| `tests/fixtures/kubernetes-repo/` | Self-contained fixture, clean variant (chart + **kustomize overlay** + Argo CD + policies) — expected fully green |
| `tests/fixtures/kubernetes-repo-broken/` | Sibling variant holding every deliberate defect, one removed guarantee per file |
| `tests/fixtures/kubernetes-repo-untested-policy/` | Sibling variant: a policy set with no `kyverno-test.yaml` |

---

### Task 1: Plugin skeleton, marketplace entry, ARCHITECTURE section

Establishes the ownership boundary before anything fills it. Child #1151.

> **LANDED (#1151).** The blocks below are **re-synced from the shipped files**,
> not a source the shipped files are generated from — and
> `tests/kubernetes-plugin-skeleton.bats` *derives* that comparison, asserting the
> live `ARCHITECTURE.md` section and the live `plugin.json` description/version
> back against THIS FILE. So any later task that edits those artifacts must
> re-sync these blocks and stage this plan file in the same PR, or the suite
> reds. Never resolve that red by reverting the shipped artifacts to match the
> plan; the shipped files are authoritative.
>
> This task shipped, and the review loop on that PR changed
> several things this plan originally specified — the policy contract became a
> **glob** rather than a directory, both descriptions gained a foundation-slice
> caveat, and the `primary: kubernetes` paragraph gained a stale-declaration
> caveat. The blocks below are the **shipped** text, reproduced so later tasks
> read the real contract. Do not regenerate these files from an older draft.

**Files:**

- Created: `development-kubernetes/.claude-plugin/plugin.json`
- Modified: `.claude-plugin/marketplace.json`, `ARCHITECTURE.md`
- Also modified (registries the review loop surfaced): `README.md`,
  `docs/reference/plugins.md`, `docs/explanation/motivation.md`,
  `docs/architecture/c4-container.md`, `scripts/generate-docs-reference.py`,
  `.github/workflows/script-tests.yml`
- Also modified: `tests/dogfood-c4.bats` — the declared-container assertion
  became marketplace-DERIVED (a hardcoded floor rots the moment a plugin is
  added), plus two derived count-word tests over `c4-container.md`'s prose
- Test: **`tests/kubernetes-plugin-skeleton.bats`** (new — the real gate)

**Interfaces:**

- Produces: plugin name `development-kubernetes` — the identity every later
  task references. Version `0.3.0` as of #1153 (Task 5) — this line moves with
  the manifest blocks below. Every later task references this name.

- [x] **Step 1: Establish a green baseline**

Run: `zsh development/skills/resolve-issue/scripts/run-gate.zsh --tests-dir tests`

Note `tests/check-marketplace-sync.bats` is **not** a sufficient gate on its own:
it is fixture-only (it copies `tests/fixtures/clean` into a tmpdir and runs the
script against that), so it passes byte-identically with this whole change
reverted. `tests/kubernetes-plugin-skeleton.bats` asserts against the real repo
root and is what actually gates this task.

- [x] **Step 2: Create the plugin manifest**

```json
{
  "name": "development-kubernetes",
  "description": "Infrastructure-as-code topic plugin for Kubernetes manifests, Helm charts, Kustomize overlays and Argo CD resources. Composes ALONGSIDE a language plugin, and can itself be PRIMARY for a repo with no application language (a GitOps repo). Charter — mechanism only: render and validate manifests, and run the repo's own Kyverno policies from policies/kyverno/**/*.{yaml,yml}, skipping when no policy file matches. Defers Dockerfiles and image builds to language plugins (language-first). Ships no approver agent — a cluster definition is approved by a human. This slice adds the five agents and the review panel (#1153): the security, reliability and Argo CD review dimensions behind /development-kubernetes:review, plus the manifest fixer and policy triage agents the maintenance dispatcher now routes every finding group to. Its CI pipeline ships as a `development` bootstrap template — six requirable checks over rendered manifests (#1154).",
  "version": "0.3.1",
  "author": {
    "name": "Timo Jakob"
  },
  "license": "MIT",
  "keywords": [
    "kubernetes",
    "helm",
    "kustomize",
    "argocd",
    "kyverno",
    "infrastructure-as-code",
    "topic-plugin"
  ]
}
```

- [x] **Step 3: Add the marketplace entry**

Insert into the `plugins` array of `.claude-plugin/marketplace.json`. The
description is **byte-identical** to `plugin.json`'s — not abridged: the two
drifted apart once already, so `tests/kubernetes-plugin-skeleton.bats` pins
exact equality. Edit one, edit both.

```json
{
  "name": "development-kubernetes",
  "description": "Infrastructure-as-code topic plugin for Kubernetes manifests, Helm charts, Kustomize overlays and Argo CD resources. Composes ALONGSIDE a language plugin, and can itself be PRIMARY for a repo with no application language (a GitOps repo). Charter — mechanism only: render and validate manifests, and run the repo's own Kyverno policies from policies/kyverno/**/*.{yaml,yml}, skipping when no policy file matches. Defers Dockerfiles and image builds to language plugins (language-first). Ships no approver agent — a cluster definition is approved by a human. This slice adds the five agents and the review panel (#1153): the security, reliability and Argo CD review dimensions behind /development-kubernetes:review, plus the manifest fixer and policy triage agents the maintenance dispatcher now routes every finding group to. Its CI pipeline ships as a `development` bootstrap template — six requirable checks over rendered manifests (#1154).",
  "version": "0.3.1",
  "author": {
    "name": "Timo Jakob"
  },
  "source": "./development-kubernetes",
  "category": "development"
}
```

- [x] **Step 4: Run the real gate**

Run: `bats tests/kubernetes-plugin-skeleton.bats`

- [x] **Step 5: Add the ARCHITECTURE section**

Added to `ARCHITECTURE.md`, in the `### development-<topic> owns` area:

```markdown
### `development-kubernetes` owns

Kubernetes manifests, Helm charts and values, Kustomize overlays, and
Argo CD `Application` / `ApplicationSet` / `AppProject` resources.

It does **not** own Dockerfiles or image builds — language-first puts
those with the language plugins and later `development-container` — nor
cloud provisioning, nor application code of any kind.

**Mechanism here, policy in the consumer.** The plugin knows how to run
checks; the repo under test declares what to check for, at
`policies/kyverno/**/*.{yaml,yml}`. That glob — **not** the mere
existence of the `policies/kyverno/` directory — is the contract: the
skip condition is **no matching files**, so an empty (or `.json`-only)
policy directory skips exactly like an absent one, and a repo that
writes its policies as `.yml` is enforced rather than silently ignored.

When nothing matches, the policy step **skips and reports "no policies
declared"**. *That absence* is never an error — a public plugin has to
work in a repo that has no opinions yet. The guarantee scopes to the
absence and nothing else: when policies **are** declared, violations
**fail** the step, or the mechanism would be decorative. So does a declared set
the pinned Kyverno CLI **cannot evaluate** — policies written only in kinds it
does not know (Kyverno 1.14's `ValidatingPolicy` and friends) fail rather than
skipping, because that absence of a *matching file* is the one and only skip
condition; anything else would be a green check over unenforced policies.

The plugin ships **no policies of its own**: generic hygiene (probes,
resource limits, non-root, `latest` tags) is `kube-linter`'s job, and two
tools enforcing one rule means two places to silence a false positive.

**No approver agent**, following `development-claude-plugin`: a cluster
definition is the origin of everything running on it, so a human
approves. Note this is *not* the same as no auto-merge — the Maintenance
App cannot approve its own pull request, so a human approval is
structurally required, and auto-merge armed afterwards fires only once
that approval lands.

**One deliberate exception to the `missing_tooling` rule.** The family default
builds `missing_tooling` from `tooling_configured` entries that are `false`, and
dispatches the tool's agent to say "here's how to add it". This plugin exempts
`policy` and `policy_tests`: a repo with no file matching
`policies/kyverno/**/*.{yaml,yml}` has not failed to
configure a tool, it has declined to declare opinions — which is the whole point
of mechanism-here-policy-in-the-consumer — so surfacing it would re-emit the
adopt-Kyverno recommendation the charter forbids. Every other **known** `false` entry
populates `missing_tooling` normally; an **unknown** key arriving `false` is the
`tooling_configured` face of routing drift and is escalated via
`human_action_required` instead, never listed as missing tooling. Plus one
narrower point the dispatcher records in full: `manifest_validation` is **presence detection**, not
configuration, so it cannot be `false` on a payload that reached the dispatcher
at all (the gather and the topic marker share one recipe). Should one ever
arrive, that is a payload-contract break the dispatcher **escalates** via
`human_action_required`, never a `missing_tooling` entry recommending
kubeconform to a repo that has no manifests.

A repo declaring `primary: kubernetes` in `.maintenance.yml` **selects this
plugin for maintenance dispatch**; the primary/auxiliary model already permits a
topic to be primary, so no new mechanism is needed. The *bootstrap* half is
narrower, and the two must not be conflated: bootstrap renders the six-check
workflow and calls `branch-protection.sh --iac-only true` for the kubernetes
marker with an **empty resolved language set**. There a recorded `primary:` can
**veto** the path (any other value takes the repo off it) but never **grant**
it, so a declaration alone does not entitle a repo to the pipeline. The mixed
repo — the marker plus a stray tooling language — is deferred to #1193.

**#1152 landed the first half**: the
topic marker and `gather-kubernetes-findings.zsh` exist, so `kubernetes` now
enters the detected+supported set and such a declaration **selects this
plugin** rather than being treated as stale. **#1153 landed the second half**:
the five agents ship, so the dispatcher now **routes** each finding group to a
`subagent_type` that exists rather than escalating it to a human.
**#1154 landed the gates themselves**: the check pipeline ships, so a routed
group is now backed by a CI check that enforces the manifests on a PR rather
than by a plan alone.

"Full pipeline" here means the **six checks** bootstrap's
`templates/iac/.github/workflows/kubernetes-ci.yml.tmpl` **emits** (#1154) — render → schema →
lint → policy → config-scan → argocd. Note where they live: the workflow
is a *bootstrap* template owned by the generic `development` plugin, not
something this plugin's skills run, which is the same boundary that keeps
detection in `development`. A manifests repo has no test suite, so the language-app
gates — the coverage floor above all — do not apply to it, and bootstrap does not
render them. Branch protection still runs: `branch-protection.sh --iac-only true`
**requires those six contexts instead of** the language-app set (which no
workflow on such a repo would ever report), leaving the protection rule and the
repo merge settings auto-merge depends on unchanged.
```

- [x] **Step 6: Commit**

Landed as `feat(development-kubernetes): plugin skeleton, marketplace entry, ARCHITECTURE section` (Closes #1151).

---

### Task 2: Register the `kubernetes` topic marker

> **LANDED (#1152).** Tasks 2-4 shipped as ONE PR. The blocks below are
> **re-synced from the shipped files**, not a source those files are generated
> from — exactly as Task 1's banner says of its own. The review loop on that PR
> changed several things this plan originally specified: the marker recipe became
> a **pure predicate** carrying `kubernetes-marker:begin`/`:end` sentinels (a
> side-effecting `topics=...` form exits 0 on every repo, so a caller reading
> `$?` uniformly across the recipes would detect this topic everywhere) and gained
> `! -type d`; the gather's finding object gained `id`/`type`/`fix`/`files` and
> severity `high`; and the dispatcher gained an unknown-key halt exception,
> presence-detection semantics for `manifest_validation`, and a maintainer-note
> framing for its ARCHITECTURE cross-reference. **Do not regenerate the shipped
> files from an older draft**; when they change, re-sync these blocks in the
> same PR.
>
> Three suites gate them: `tests/gather-kubernetes.bats` (the payload contract),
> `tests/kubernetes-topic-marker.bats` (extracts and EXECUTES the SKILL.md
> recipe, and derives marker/prune parity against the gather), and
> `tests/kubernetes-dispatcher.bats` (the dispatcher's prose contract).

The orchestrator must detect the topic before any gather runs. Child #1152.

**Files:**

- Modify: `development/skills/maintenance/SKILL.md` — five sites, not one:
  the topics table row, the marker recipe (Step 2), the **Required-language**
  row (`| kubernetes | none |`), the Phase 4 **hybrid `language_meta.manifests`**
  clause with its own `kubernetes-manifests:begin`/`:end` recipe, and the
  Phase 6 / 7 / 9 **`human_action_required` topic cases** — without which a
  dispatcher that halts every group is summarised as "Clean" (see Task 4)

**Interfaces:**

- Produces: topic name `kubernetes`, gather script name `gather-kubernetes-findings.zsh`. Task 3
  creates that script at exactly that path.
- [x] **Step 1: Add the marker row**

Add to the "Known topics" table:

```markdown
| `kubernetes` | a Helm `Chart.yaml`, a Kustomize manifest (`kustomization.yaml`, `kustomization.yml` or `Kustomization` — all three spellings kustomize accepts), **or** a file containing `argoproj.io` — language-agnostic, so it composes with any language, or none | `gather-kubernetes-findings.zsh` |
```

- [x] **Step 2: Add the detection recipe**

Add alongside the existing marker recipes. The marker is deliberately *not* "any YAML with
`apiVersion`", which would match half the repos in existence:

```bash
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
# kubernetes-marker:begin
k8s_hits="$(find . \( -name Chart.yaml -o -name kustomization.yaml \
                       -o -name kustomization.yml -o -name Kustomization \) \
                 ! -type d 2>/dev/null \
              | grep -v -e /node_modules/ -e '/\.git/' -e /vendor/ -e /templates/ || true)"
[ -n "$k8s_hits" ] || grep -rqlF 'argoproj.io' \
  --include='*.yaml' --include='*.yml' \
  --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git \
  --exclude-dir=templates . 2>/dev/null
# kubernetes-marker:end
```

> **Also register the Required-language row.** `development/skills/maintenance/SKILL.md`
> carries a SECOND per-topic registry beside the marker table — the
> Required-language table — and its own prose says it is "the single place that
> requirement is applied, so it can't be stated in the marker prose and then
> quietly skipped". Add `| \`kubernetes\` | none |` there; stating
> language-agnosticism only in the marker prose leaves the topic undefined at
> the point the partition actually decides it.
>
> **Bump the `development` plugin.** This task modifies content under
> `development/`, and every PR that does must bump `development/.claude-plugin/plugin.json`
> **and** its `.claude-plugin/marketplace.json` entry in lockstep (minor) —
> Claude Code caches plugins by version, so an omitted bump means installs never
> see the change and the fix silently appears inert. `marketplace-sync.yml`
> catches only *disagreement* between the two files, never an omitted bump, so
> nothing will flag it. Stage all THREE manifest files —
> `development/.claude-plugin/plugin.json`,
> `development-kubernetes/.claude-plugin/plugin.json` and the single root
> `.claude-plugin/marketplace.json`, which carries both entries. (The only
> other marketplace.json in the repo is the `tests/fixtures/clean/` one,
> which must NOT be bumped.)

- [x] **Step 3: Commit**

```bash
git add development/skills/maintenance/SKILL.md
# plus every file the box above requires — re-read it before committing;
# `git status` must be clean afterwards
git commit -m "feat(development): register the kubernetes topic marker

Chart.yaml, kustomization.yaml or an argoproj.io reference. Deliberately
not 'any YAML with apiVersion', which would match half the repos in
existence.

Refs #1152"
```

---

### Task 3: The gather script

Child #1152. TDD — the test defines the contract.

**Files:**

- Create: `development/skills/maintenance/scripts/gather-kubernetes-findings.zsh`
- Test: `tests/gather-kubernetes.bats`

**Interfaces:**

- Consumes: topic name from Task 2.
- Produces: v2 gather payload with `tooling_configured` keys `manifest_validation`, `policy`, and
  `policy_tests`; `findings_by_tool` keyed the same; `coverage` always `null` (a topic has no app
  test suite); `notes` array. Task 4's dispatcher consumes exactly these keys.
- [x] **Step 1: Write the failing tests**

Create `tests/gather-kubernetes.bats`. **The shipped suite is 48 tests and is
authoritative** — read it rather than a draft reproduced here. It pins the
payload contract the dispatcher consumes: `has()` (never `length`) for
unconfigured keys, the `tooling_configured` key set, the finding-object shape,
all three Kustomize spellings, every prune entry, the `argoproj.io`
include/exclude branches, the repo-relative-path guarantee, and exits 2 and 3.

Two sibling suites land with it: `tests/kubernetes-topic-marker.bats` and
`tests/kubernetes-dispatcher.bats`.

```bash
bats tests/gather-kubernetes.bats  # the suite itself is the contract
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `bats tests/gather-kubernetes.bats`
Expected: FAIL — the gather script does not exist.

- [x] **Step 3: Write the gather script**

Create `development/skills/maintenance/scripts/gather-kubernetes-findings.zsh`:

```zsh
#!/usr/bin/env zsh
# gather-kubernetes-findings.zsh — the kubernetes topic's finding gatherer
# (epic #1150, child #1152). Emits the v2 gather payload the
# `development-kubernetes` dispatcher consumes:
# `tooling_configured` / `findings_by_tool` / `coverage` / `notes`.
#
# Tools:
#   manifest_validation — rendered-output checks (kubeconform, kube-linter).
#                         PRESENCE-DETECTED here; the tools themselves run in
#                         the CI pipeline (#1154), never in this gather.
#   policy              — the repo's OWN Kyverno policies, matched by the GLOB
#                         policies/kyverno/**/*.{yaml,yml} rather than by the
#                         directory's existence, so an empty (or .json-only)
#                         directory skips exactly like an absent one and a repo
#                         writing .yml policies is enforced rather than silently
#                         ignored (the ARCHITECTURE.md contract).
#                         No match ⇒ tooling_configured.policy=false + a note.
#                         NEVER a finding: a public plugin must work in a repo
#                         with no opinions yet.
#   policy_tests        — this topic's coverage-gate analogue. A declared policy
#                         set with no `kyverno test` fixtures passes everything
#                         silently, which is the failure mode hardest to notice.
#
# `coverage` is always null — a topic has no application test suite.
#
# Usage: gather-kubernetes-findings.zsh [<repo_path>]   (default: current dir)
# Output: JSON on stdout (always exit 0 on a well-formed run).

emulate -L zsh
set -euo pipefail

local repo="${1:-.}"
[[ -d "$repo" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: not a directory: $repo"; exit 2; }
# and TRAVERSABLE. Every search below is wrapped in `|| true` / `2>/dev/null`, so
# a directory that exists but cannot be entered would yield an all-false payload
# with exit 0 — "could not look" rendered as "looked and found nothing", the one
# outcome this script's comments repeatedly refuse to produce.
[[ -r "$repo" && -x "$repo" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: not a readable directory: $repo"; exit 2; }
# normalise a relative path to an explicit ./ prefix: a repo path beginning with
# `-` clears the `[[ -d ]]` gate (test operators parse no options) but is then
# read as an OPTION by `cd` and as a PRIMARY by `find` — and every such failure is
# absorbed by the `|| true` below, yielding a confident all-false payload instead
# of an error. Absolute paths are already unambiguous.
[[ "$repo" == /* ]] || repo="./$repo"
command -v jq >/dev/null 2>&1 || { print -r -u2 -- "gather-kubernetes-findings.zsh: jq not found on PATH"; exit 3; }

local -a notes=()

# --- manifest_validation: is there anything to render? ------------------------
# The marker is deliberately NOT "any YAML with apiVersion", which would match a
# workflow file or an OpenAPI document in half the repos in existence. It is a
# Helm Chart.yaml, a Kustomize manifest (all three spellings kustomize accepts),
# or the literal `argoproj.io`, which nothing else carries by accident.
local has_manifests="false"

# Capture BEFORE filtering. `find … | grep -q` looks equivalent but inverts under
# `set -o pipefail`: grep -q exits at its first match, find — still writing — dies
# of SIGPIPE, and the whole condition goes FALSE even though a chart WAS found.
# It misfires only once find's output outruns the pipe buffer, which is the worst
# possible failure mode. `grep -v` reads its input to EOF, so the filter itself is
# safe; the capture keeps it that way if the filter is ever changed.
#
# `cd` into the repo so the emitted paths are repo-RELATIVE: with an absolute
# "$repo" the prune substrings would also test the checkout's own prefix, and a
# repo living under ~/templates/ (or a workspace directory named vendor) would
# filter every hit and be reported manifest-free.
local manifest_hits
#
# `! -type d` for the same reason the react marker carries it: a DIRECTORY named
# `Kustomization` is not a manifest, while a symlinked one still counts. Kept
# identical to the SKILL.md marker recipe — tests/kubernetes-topic-marker.bats
# derives the comparison, so the two cannot drift into detecting different repos.
# gather-kubernetes-marker:begin
manifest_hits="$(cd -- "$repo" && find . \
                   \( -name Chart.yaml -o -name kustomization.yaml \
                      -o -name kustomization.yml -o -name Kustomization \) \
                   ! -type d 2>/dev/null \
                   | grep -v -e /node_modules/ -e '/\.git/' -e /vendor/ -e /templates/ || true)"
if [[ -n "$manifest_hits" ]]; then
  has_manifests="true"
elif ( cd -- "$repo" && grep -rqlF 'argoproj.io' \
         --include='*.yaml' --include='*.yml' \
         --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git \
         --exclude-dir=templates . 2>/dev/null ); then
  # `cd` first, and grep the literal `.` — for the SAME reason the find branch
  # does it, but a sharper failure: GNU grep documents --exclude-dir as skipping
  # any COMMAND-LINE directory whose name matches, so passing "$repo" would skip
  # a repo literally named `templates`/`vendor`/`node_modules` in its ENTIRETY
  # and report it manifest-free with exit 0. `.` can never match a pattern.
  has_manifests="true"
fi
# gather-kubernetes-marker:end

# --- policy: the repo's own rules, matched as a GLOB --------------------------
# `-L` (not `-H`) on both finds below. `-H` follows only the COMMAND-LINE
# symlink, so a symlinked policies/kyverno is searched but a symlinked policy
# FILE inside a real one is type `l` and `-type f` drops it — reporting a
# symlink-shared policy set as undeclared, and a symlinked kyverno-test.yaml as
# missing coverage (a false untested-policies accusation). `-L` resolves both:
# a symlink-to-file becomes type `f`, a directory named `p.yaml` stays type `d`
# so the -type f guard still holds, and a dangling symlink is still excluded.
# Note the asymmetry with the manifest half, which is deliberate and NOT parity:
# the manifest finds stay at the default `-P`, so they count a symlinked manifest
# FILE but do not descend a symlinked chart DIRECTORY. That is the boundary the
# FOUR manifest copies share (SKILL.md's marker recipe, SKILL.md's manifests
# lister, the manifest find ABOVE in this file, and detect-stack.sh's
# `is-kubernetes-marker` block, #1153 — not the two policy finds
# below, which are the `-L` ones this block declares), and the parity oracles in
# tests/kubernetes-topic-marker.bats hold
# them identical — so do not "fix" the policy side down to match, and do not
# raise the manifest side to `-L` without changing all four copies together.
local policy_dir="$repo/policies/kyverno"
local has_policies="false"
local policy_hits=""
if [[ -d "$policy_dir" ]]; then
  # the same rule as the repo gate, one level deeper: an unreadable policy
  # directory would fail into `2>/dev/null || true` and emit "no policies
  # declared" for a repo that declared several — the silent skip the glob
  # contract exists to prevent
  [[ -r "$policy_dir" && -x "$policy_dir" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: policies/kyverno exists but is not readable"; exit 2; }
  policy_hits="$(find -L "$policy_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null || true)"
  [[ -n "$policy_hits" ]] && has_policies="true"
fi
if [[ "$has_policies" != "true" ]]; then
  notes+=("policy: no policies declared at policies/kyverno/**/*.{yaml,yml} — step skipped, not failed")
fi

# --- policy_tests: fixtures for those policies -------------------------------
# Recursive and both extensions: fixtures are commonly grouped per policy in a
# subdirectory, and .yml is as valid as .yaml — missing either would report a
# tested policy set as untested, which is a false accusation rather than a
# missed one, and trains users to ignore this finding.
local policy_tests_findings="[]"
if [[ "$has_policies" == "true" ]]; then
  local test_hits
  test_hits="$(find -L "$policy_dir" -type f \
                 \( -name 'kyverno-test.yaml' -o -name 'kyverno-test.yml' \) 2>/dev/null || true)"
  if [[ -z "$test_hits" ]]; then
    policy_tests_findings="$(jq -n '[{
      id: "policy_tests:untested-policies",
      tool: "policy_tests",
      type: "untested_policies",
      severity: "high",
      message: "policies/kyverno/ declares policies but has no kyverno test fixtures. An untested policy usually matches nothing, so it passes everything silently.",
      fix: "Add a kyverno-test.yaml beside the policies, declaring at least one resource each policy must PASS and one it must FAIL, and run `kyverno test policies/kyverno`.",
      files: ["policies/kyverno/"]
    }]')"
  fi
fi

# --- emit ---------------------------------------------------------------------
# ALWAYS carry the presence-detection note. The orchestrator reads an empty topic
# plan with a NON-empty tooling_configured as "this topic is clean — its tools ran
# and found nothing", which for this gather would be a lie: nothing ran. The note
# is the only thing that reaches the Phase 9 summary and can contradict that
# rendering.
notes+=("manifest_validation: presence-detected only — kubeconform/kube-linter/kyverno run in the CI pipeline (#1154), not in this gather")

local notes_json
notes_json="$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.')"

jq -n \
  --argjson manifests "$has_manifests" \
  --argjson policies "$has_policies" \
  --argjson policy_tests "$policy_tests_findings" \
  --argjson notes "$notes_json" '
{
  tooling_configured: {
    manifest_validation: $manifests,
    policy: $policies,
    policy_tests: $policies
  },
  # The v2 contract in ARCHITECTURE.md: findings_by_tool carries keys ONLY for
  # configured tools. Emitting an empty array for an unconfigured tool would make
  # "not configured" indistinguishable from "configured and clean" — which for the
  # policy skip is exactly the confusion the charter must never create.
  findings_by_tool: (
    (if $manifests then { manifest_validation: [] } else {} end)
    + (if $policies then { policy: [], policy_tests: $policy_tests } else {} end)
  ),
  coverage: null,
  notes: $notes
}
'
```

- [x] **Step 4: Run the tests to verify they pass**

Run: `bats tests/gather-kubernetes.bats`
Expected: PASS — the whole suite (48 tests as shipped).

> **Before committing, flip the #1151 skeleton gate (the gather half).**
> `tests/kubernetes-plugin-skeleton.bats` asserts
> `[ ! -f development/skills/maintenance/scripts/gather-kubernetes-findings.zsh ]`
> — the FACT behind ARCHITECTURE's claim that `primary: kubernetes` is treated
> as stale "until `kubernetes` is in the detected+supported set". Creating the
> gather makes that claim false, so this task must, in the same PR:
>
> 1. delete that assertion (and its `@test`, if nothing else remains in it);
> 2. retire the stale-declaration caveat — FOUR pinned needle sites, all of
>    which red together, and each should be FLIPPED to its post-landing form
>    (caveat gone, positive capability still pinned) rather than deleted:
>    the `treats the declaration as stale` needle, the two `plugins.md` caveat
>    needles, and the topic-row `dispatch lands with #1152` needle. In prose:
>    `ARCHITECTURE.md`'s `### development-kubernetes owns` paragraph and
>    `docs/reference/plugins.md`'s "Until #1152 lands there is no `kubernetes`
>    topic marker" sentence — and drop the `(dispatch lands with #1152)` caveat
>    from the ARCHITECTURE Topic-table row, which the same suite pins;
> 3. run the whole suite:
>    `zsh development/skills/resolve-issue/scripts/run-gate.zsh --tests-dir tests`.
>
> `git add` must therefore also stage `tests/kubernetes-plugin-skeleton.bats`,
> `ARCHITECTURE.md`, `docs/reference/plugins.md` and
> `docs/superpowers/plans/2026-08-02-development-kubernetes.md` (re-sync Task 1's
> blocks — the skeleton suite derives them against the live artifacts).
>
> **Bump the `development` plugin.** This task modifies content under
> `development/`, and every PR that does must bump `development/.claude-plugin/plugin.json`
> **and** its `.claude-plugin/marketplace.json` entry in lockstep (minor) —
> Claude Code caches plugins by version, so an omitted bump means installs never
> see the change and the fix silently appears inert. `marketplace-sync.yml`
> catches only *disagreement* between the two files, never an omitted bump, so
> nothing will flag it. Stage all THREE manifest files —
> `development/.claude-plugin/plugin.json`,
> `development-kubernetes/.claude-plugin/plugin.json` and the single root
> `.claude-plugin/marketplace.json`, which carries both entries. (The only
> other marketplace.json in the repo is the `tests/fixtures/clean/` one,
> which must NOT be bumped.)

- [x] **Step 5: Make the script executable and commit**

```bash
chmod +x development/skills/maintenance/scripts/gather-kubernetes-findings.zsh
git add development/skills/maintenance/scripts/gather-kubernetes-findings.zsh tests/gather-kubernetes.bats
# plus every file the box above requires — re-read it before committing;
# `git status` must be clean afterwards
git commit -m "feat(development-kubernetes): gather-kubernetes-findings.zsh

Emits the v2 gather payload. Absent policies produce tooling_configured
false plus a skip note, never a finding — a public plugin must work in a
repo with no opinions yet.

policy_tests is this topic's coverage-gate analogue: a policy directory
without fixtures passes everything silently, which is the failure mode
hardest to notice.

Refs #1152"
```

---

### Task 4: The maintenance dispatcher

Child #1152. A pure function of its input — validates the payload, returns a PR-grouped plan, spawns nothing.

**Files:**

- Create: `development-kubernetes/skills/maintenance/SKILL.md`

**Interfaces:**

- Consumes: the exact `tooling_configured` / `findings_by_tool` keys from Task 3.
- Produces: routing — `manifest_validation` → `kubernetes-manifest-fixer`; `policy` and
  `policy_tests` → `kubernetes-policy-triage`. Task 5 creates both agents under those exact names.
- [x] **Step 1: Write the dispatcher skill**

````markdown
---
name: maintenance
description: >
  Kubernetes/IaC maintenance dispatcher. Receives a v2 maintenance payload (a
  file path in $ARGUMENTS) that /development:maintenance built from the
  kubernetes topic gather (gather-kubernetes-findings.zsh), validates it, and
  returns a plan routing each finding group to an agent. A TOPIC plugin that can
  also be PRIMARY: a GitOps repo with no application language declares
  `primary: kubernetes` and gets the full pipeline. It ROUTES each finding group
  by the live routing table (manifest_validation → kubernetes-manifest-fixer;
  policy + policy_tests → kubernetes-policy-triage, grouped into one PR).
  A single invocation returns the plan; the per-group work agents are the
  orchestrator's job. Pure function of its JSON input; runs no detection of its
  own. Ships NO approver — a cluster definition is approved by a human.
disable-model-invocation: false
---

# Kubernetes maintenance dispatcher

Read the payload at `$ARGUMENTS`. Spawn nothing.

You are the **kubernetes-topic maintenance dispatcher**. You receive a v2
maintenance payload that `/development:maintenance` built from the kubernetes
topic gather, and you return a **plan**: an ordered list of finding groups, each
routed to the agent that fixes that category. You do **not** run detection, the
gather, or the validation **tools** (kubeconform / kube-linter / `kyverno test`,
which run in CI — #1154) yourself, and you do **not** spawn the work agents —
Phase 8 of the orchestrator does, one PR per group. *Payload* validation is a
different thing and it **is** yours: see *Validation* immediately below.

Like the other topic plugins (`development-docs`, `development-claude-plugin`),
you have **no language coverage gate and no Phase A/B dance** — a topic has no
application test suite of its own. This dispatcher is a single invocation
returning one `plan`. Its one analogue is `policy_tests` (see *No coverage gate,
one analogue*).

## Validation

Each check terminates — a dispatcher that routes whatever happens to parse is
worse than one that stops:

- `$ARGUMENTS` empty → print one line explaining this is a dispatch target for
  `/development:maintenance`, not a standalone command, and **stop**.
- the file is missing, or does not parse as JSON → **error and stop**.
- `.schema_version != "2"` → **error and stop**, naming the version found.
- `.language != "kubernetes"` → **error and stop**. (For a topic dispatch the
  orchestrator carries the TOPIC name in `language`; there is no `topic` key in
  the v2 payload, so a `.topic == "kubernetes"` guard would stop on every valid
  dispatch.)
- a key appears in `findings_by_tool` that the routing table below has no entry
  for → **halt** with `human_action_required`, rather than dropping it silently.

```bash
command -v jq >/dev/null 2>&1 || { echo "jq not found on PATH — cannot validate the payload"; exit 1; }
[ -n "$ARGUMENTS" ] || { echo "development-kubernetes:maintenance is a dispatch target for /development:maintenance, not a standalone command"; exit 1; }
test -f "$ARGUMENTS" || { echo "no payload file at: $ARGUMENTS"; exit 1; }
jq -e . "$ARGUMENTS" >/dev/null 2>&1 || { echo "payload is not valid JSON: $ARGUMENTS"; exit 1; }
jq -e '.schema_version == "2"' "$ARGUMENTS" >/dev/null \
  || { echo "unexpected payload schema (want 2, found: $(jq -r '.schema_version // "absent"' "$ARGUMENTS"))"; exit 1; }
jq -e '.language == "kubernetes"' "$ARGUMENTS" >/dev/null \
  || { echo "payload is not a kubernetes dispatch (language: $(jq -r '.language // "absent"' "$ARGUMENTS"))"; exit 1; }
```

**Stop on any failure in the block above** — every check except the unknown-key
bullet (the bullets and the guards are not 1:1; the JSON bullet is two guards).
Never fall through to *Response* and return the empty-plan envelope for a payload
you could not validate: the empty plan is for a *valid* v2 payload that carries no
kubernetes findings, **not** for a broken or wrong-version one, and masking a
payload-contract break (a future v3 orchestrator, say) as "nothing to do" would be
a silent failure.

**The unknown-key bullet is the one exception, and it is not a fall-through.**
That payload *did* validate — it is well-formed v2 for this topic; only its
routing is unknown. So it does not error out: it **returns** the halt envelope
defined in *Response* (the four fields plus `human_action_required`), which is
the only way the escalation reaches a human. Erroring instead would make the
orchestrator record `dispatch failed` in `unsupported_topics` and swallow it.

## Dispatch mode

`dispatch_mode` is `"primary"` | `"auxiliary"`; **absent is treated as
`"primary"`**, per `ARCHITECTURE.md` § *Primary / auxiliary model* (the language
dispatchers restate it; the sibling topic dispatchers only accept the field).
Any **other** value is a payload-contract break, and it is handled exactly like
the `manifest_validation: false` case in *Response*: **route nothing** and return
the halt envelope with **one** `human_action_required` entry naming the value
found — that single entry is the trace for the whole payload, so do not
additionally enumerate the groups. Do **not** "treat it as primary and carry on":
any non-empty `human_action_required` *is* the halt branch, and Phase 7 skips
every remaining phase for the target, so a plan built alongside the note would be
discarded and the routed work would silently never run. The orchestrator only
ever emits the two values, so a third means the payload was not built by it.
This topic composes ALONGSIDE a language plugin, so auxiliary is the expected
case for a repo that **declares a language primary** — note that a repo which
declares no primary at all dispatches every target as `"primary"`, so auxiliary
is not simply the default. Here is the disposition of all three routed keys, so
nothing falls through to a guess:

- `manifest_validation` → routed as usual. Mechanical, always in scope.
- `policy` → routed as usual. A violation of a policy the repo *declared* is a
  real defect whatever the repo's primary language is; suppressing it would lose
  the finding with no trace.
- `policy_tests` → **omitted entirely** in auxiliary mode. This is the app-grade
  coverage analogue, and it is the only one that is. Planning ordering-blocking
  fixture-writing on a repo whose primary is Java or Go is exactly the category
  error the primary/auxiliary split exists to prevent.

## Routing

**One name, two things — read the qualified paths.** This topic's `policy`
*tool* is `tooling_configured.policy` / `findings_by_tool.policy`. The payload
also carries a **top-level `policy` object** (`{coverage_threshold,
severity_gate, …}`) — the family's maintenance policy, present and truthy on
every payload, and **never** read by this dispatcher. Resolving a bare "policy"
to that object would read a repo with no Kyverno files as having policies
configured, inverting the charter's central skip.

**This table is live** — every row routes, and its entries also define the
known-key universe *Validation*'s unknown-key check tests against. Both agents
ship with this plugin (`development-kubernetes/agents/`), so a routed group
names a `subagent_type` that exists.

| Finding tool | Agent |
|---|---|
| `manifest_validation` | `kubernetes-manifest-fixer` |
| `policy` | `kubernetes-policy-triage` |
| `policy_tests` | `kubernetes-policy-triage` |

**A group exists only for a ROUTED `findings_by_tool` key whose array is
NON-EMPTY.** A routed key present with an **empty** array means "configured, and
it found nothing" —
it forms no group, no plan entry, and no `human_action_required`
entry either. This is not a corner case: `manifest_validation: []` is on *every*
payload this dispatcher receives, because that tool is presence-detected and its
checks run in CI, and `policy: []`/`policy_tests: []` is the shape of a clean
policy set. Treating each routed *key* as a group would escalate the ordinary
clean dispatch — the most common payload there is — to a human as "Halted".

**"Routed" is the load-bearing word, and *Validation* wins over this rule for
anything else.** An **unknown** key — one this table has no row for — halts on
its mere *presence*, empty array or not; it is not a group and this paragraph
does not exempt it. The two rules answer different questions: this one asks "is
there work here?", *Validation*'s asks "do I still understand this payload?".
A future gather adding a presence-detected tool would ship exactly that shape —
an unknown key with an empty array — and silently dropping it is the routing
drift the halt exists to surface.

Group `policy` and `policy_tests` into **one** PR: they touch the same
directory, and splitting them would produce two PRs racing on the same files.

Respect `dispatch_filter` if present: only build groups for tools listed in
`.dispatch_filter.only_tools`. In practice the orchestrator **omits
`dispatch_filter` for topics** and skips topic dispatch entirely under
`--tool`/`--concern`, so this handling is **defensive**: if a filter naming no
kubernetes tool ever did arrive, an empty plan is the correct result.

## No coverage gate, one analogue

A topic has no application test suite, so there is no line-coverage pre-flight.
The analogue is `policy_tests`: a declared policy set with no `kyverno test`
fixtures. Treat a `policy_tests` finding as **ordering-blocking** for the group —
the group is dispatched to `kubernetes-policy-triage` (that
agent is what WRITES the missing fixtures) and the plan must order
fixture-writing before any policy-driven manifest fix in it. Never drop the
group: that would permanently preserve the untested-policy state the gate exists
to eliminate.

The ordering rule is also **primary-mode only** — in auxiliary mode the
`policy_tests` group is omitted before it is ever formed (see *Dispatch mode*).

## Absent policies are not a finding

`tooling_configured.policy: false` means the repo declared no policies — the
gather's glob `policies/kyverno/**/*.{yaml,yml}` matched nothing. Return a plan
with no policy group. The gather's "no policies declared" note stays in the
gather payload and is reproduced **nowhere** in the response — not in
`missing_tooling`, not in the plan (see *Response*; `missing_tooling` would turn
a deliberate skip into an adopt-Kyverno recommendation). Do not synthesise a
finding, and do not suggest the repo adopt policies — that is the consumer's
decision, not this plugin's.

## Response

Return the family's v2 envelope **inline** (NOT via a file) — every field, every
time; the orchestrator's per-group CI cycle branches on `ci_fixer_agent` and its
summary renders `missing_tooling`:

```json
{
  "schema_version": "2",
  "ci_fixer_agent": null,
  "plan": [],
  "missing_tooling": []
}
```

"Every field, every time" scopes to the **non-halt** path. The halt branch in
*Validation* adds a fifth top-level field — but **keeps `plan` and
`missing_tooling`**. The orchestrator moves a topic whose response "is not a
JSON object carrying `plan`" to `unsupported_topics` with a `dispatch failed`
note, which would swallow the very escalation the halt exists to deliver:

```json
{
  "schema_version": "2",
  "ci_fixer_agent": null,
  "plan": [],
  "missing_tooling": [],
  "human_action_required": [
    { "reason": "...", "recommendation": "..." }
  ]
}
```

**`missing_tooling` — the positive rule.** The family default builds it from
`tooling_configured` entries that are `false`. This dispatcher takes ONE
deliberate exception: `policy` and `policy_tests`. A repo with no matching
policy file has not failed to configure a tool — it has declined to declare
opinions, which is the charter's whole point, and listing it would re-emit the
adopt-Kyverno recommendation as a "here's how to add it".

Every other **known** `false` entry — one the routing table has a row for —
populates `missing_tooling` normally. An **unknown** key arriving `false` does
not: that is the `tooling_configured` face of the very routing drift *Validation*
halts on, and it reaches you *instead of* that halt, because the gather emits
`findings_by_tool` keys only for **configured** tools. So the same future tool
splits by repo — present, and the unknown key halts; absent, and only
`tooling_configured.<new_tool>: false` arrives. Treat both as the same event:
note it in `human_action_required`, **never** in `missing_tooling`. Recommending
that a repo adopt a tool this dispatcher cannot route is the same category error
the policy exemption prevents.

Of the known keys there is today exactly one besides the two exempted ones,
`manifest_validation`, and **it cannot be `false` on a
payload that reached you**. It is *presence detection*, not configuration: the
gather sets it from the same `find`/`grep` recipe the orchestrator's topic marker
uses, so a repo with no manifests never fires the marker and never dispatches
here. If one ever does arrive `false` — the two recipes having drifted, or a
hand-built payload — **note it in `human_action_required` and route nothing**:
"no manifests found" is not "kubeconform is unconfigured", and emitting the
family's adopt-a-tool recommendation for it would be the same category error the
policy exemption exists to prevent. That one halt entry is the trace for the
**whole** payload — do not additionally enumerate the other groups, because the
payload itself is what is suspect.

*Maintainers of this file:* this exemption is also recorded in the plugin
repo's `ARCHITECTURE.md`, under `### development-kubernetes owns` (shipped
with #1151) — keep the two in agreement, and never add a third statement of it.
This is an editing note, **not** a dispatch step: at dispatch time you are in the
consumer's repo, where that file is absent or belongs to someone else, so never
read it, and never let its absence affect the response.

`ci_fixer_agent` is `null`: this topic ships no CI fixer, so on a red PR the
orchestrator **escalates to the user** in its summary. It does **not** substitute
another plugin's fixer — reusing one requires naming it, which is exactly what
`null` does not do (`development-docs` states the same rule;
`development-react` names `js-ci-fixer` because it genuinely reuses it).

## What you never do

- Don't edit any file or spawn any agent — you only plan.
- Don't run the gather or re-derive findings — trust the payload (the
  orchestrator already gathered).
- Don't trim or restructure the payload's findings when echoing them into a
  group's `findings` list — echo the finding objects through **in full**, ids
  included (Phase 8 builds the work agent's prompt from them).
- Don't approve anything. This plugin ships **no approver agent** — a cluster
  definition is the origin of everything running on it, so a human approves.
````

- [x] **Step 2: Verify the frontmatter parses**

Run — one physical line; a wrapped inline code span would put literal newlines
inside the `-c` string and raise `SyntaxError` before the check runs:

```bash
python3 -c "t=open('development-kubernetes/skills/maintenance/SKILL.md').read(); assert t.startswith('---'), 'no frontmatter'; print('frontmatter ok')"
```

Expected: `frontmatter ok`

> **Before committing, flip the #1151 skeleton gate (the skills half).**
> Adding `development-kubernetes/skills/` falsifies these pinned assertions —
> note the first is an ENTRY-SET equality, not a pair of `[ ! -d ]` negatives
> (that shape was rejected deliberately: it would let a later `hooks/` or
> `commands/` tree land unnoticed), so update the expected set rather than
> replacing the invariant:
>
> - `[ "$entries" = ".claude-plugin " ]` → `".claude-plugin skills "`
> - the absence of `## development-kubernetes` in `docs/reference/commands.md`
> - `contains "$c4" 'dispatches (planned, #1152)'` — the Container diagram's
>   label, pinned precisely so this PR must retire it
>
> In the same PR:
>
> 1. update the entry set as above and add a positive
>    `[ -f "$PLUGIN_DIR/skills/maintenance/SKILL.md" ]`; flip the commands.md
>    assertion to `contains`; retire **both** time-bounded labels in
>    `docs/architecture/c4-container.md` — `dispatches (planned, #1152)` →
>    `dispatches`, and `may be primary (skeleton, #1151)` → `may be primary`
>    (CLAUDE.md requires the diagram to stay true in the same PR) — and **flip**
>    both needles to the post-landing strings rather than deleting them, so the
>    page stays pinned;
> 2. run `python3 scripts/generate-docs-reference.py` and commit the regenerated
>    `docs/reference/commands.md` — `development-kubernetes` is already in that
>    script's `PLUGINS`, so the first SKILL.md makes the committed page stale and
>    `.github/workflows/reference-drift.yml --check` reds;
> 3. **bump `plugin.json` + `marketplace.json` in lockstep** (minor — this adds a
>    feature) and rewrite the trailing "This slice ships … ONLY" sentence of the
>    (identical) descriptions to name what has now landed. The suite pins the
>    "foundation slice" clause and the exact equality of the two strings, so
>    REPLACE that clause and relax its needle in the same PR — do not preserve a
>    "foundation slice" label on a version that ships a dispatcher;
> 4. update `docs/reference/plugins.md`: its "**Skills:** none yet — the
>    dispatcher lands with #1152" line becomes false, and the Maintenance-skill
>    row's topic-plugin enumeration must gain `development-kubernetes`. Nothing
>    mechanical catches either — reference-drift only regenerates
>    `commands.md`/`agents.md` — so the overview would contradict the generated
>    page in the same commit. Bump its `**What's built (v0.1):**` label to the
>    new version and relax the matching needle in the skeleton suite.
>
> 5. update the two remaining slice-status registries. `README.md`'s "ownership
>    boundary only in v0.1" cell **is pinned** —
>    `tests/kubernetes-plugin-skeleton.bats` asserts
>    `contains "$row" 'ownership boundary only in v0.1'` — so rewrite the cell
>    AND relax that needle in the same PR. Only
>    `docs/explanation/motivation.md`'s "its gather, dispatcher, agents and CI
>    pipeline are the remaining children" sentence is genuinely uncovered;
> 6. **last**, run the whole suite —
>    `zsh development/skills/resolve-issue/scripts/run-gate.zsh --tests-dir tests`.
>    It must be last: items 4 and 5 change prose the suite pins, so running it
>    earlier validates a tree you then edit.
>
> `git add` must therefore also stage `tests/kubernetes-plugin-skeleton.bats`,
> `docs/reference/commands.md`, `docs/reference/plugins.md`,
> `docs/architecture/c4-container.md`, `README.md`,
> `docs/explanation/motivation.md`,
> `docs/superpowers/plans/2026-08-02-development-kubernetes.md` (Task 1's blocks
> are derived against the live artifacts — re-sync them),
> `development-kubernetes/.claude-plugin/plugin.json`
> and `.claude-plugin/marketplace.json`.

- [x] **Step 3: Commit**

```bash
git add development-kubernetes/skills/maintenance/SKILL.md
# plus every file the box above requires — re-read it before committing;
# `git status` must be clean afterwards
git commit -m "feat(development-kubernetes): maintenance dispatcher

Pure function of its payload. Groups policy and policy_tests into one PR
— same directory, and splitting them would race two PRs on the same
files. Absent policies yield no group and no finding.

Refs #1152"
```

---

### Task 5: The five agents and the review skill

Child #1153.

> **LANDED (#1153).** The blocks below are **re-synced from the shipped files**,
> not a source those files are generated from — exactly as Tasks 1 and 2 say of
> their own. The review loop on that PR changed several things this plan
> originally specified, so regenerating an agent from an older draft would
> reintroduce defects the loop found: the reporting format moved into a fenced
> `text` block (bare `<placeholder>` angle brackets are inline HTML, which
> markdownlint rejects); every reviewer gained a **report against the CHANGED
> SOURCE FILE** rule, because `scope-findings` keeps only findings whose `file`
> matches the story's diff, so a rendered temp path — or an unchanged template
> when the edit was to `values.yaml` — is silently discarded; the render step
> gained a provenance contract (`--output-dir`, per-root kustomize output,
> `render-map.json`) without which reviewers cannot obey that rule; the two
> absence-checking reviewers gained a **consult the whole tree** rule; both
> maintenance agents gained an `## Escalations` channel and an `## Unverified`
> branch for a missing checker; `argocd-advisor` gained the repo-identity
> procedure; the review skill's scope default became "the temp tree" (the draft's
> "every file the render step produced" excludes the copied-in standalone
> manifests, which is the failure the render paragraph exists to prevent), its
> Step 2 gained a third retry condition, and its frontmatter carries
> `disable-model-invocation: false`. **When the shipped files change, re-sync
> these blocks in the same PR.** The *Before committing* box further down is a
> record of work already executed, not an outstanding instruction.

**Files:**

- Create: `development-kubernetes/agents/kubernetes-security-reviewer.md`
- Create: `development-kubernetes/agents/kubernetes-reliability-reviewer.md`
- Create: `development-kubernetes/agents/argocd-advisor.md`
- Create: `development-kubernetes/agents/kubernetes-manifest-fixer.md`
- Create: `development-kubernetes/agents/kubernetes-policy-triage.md`
- Create: `development-kubernetes/skills/review/SKILL.md`

**Interfaces:**

- Consumes: agent names referenced by Task 4's routing table.
- Produces: review dimensions `security`, `reliability`, `argocd`.

- [x] **Step 1: Create the security reviewer**

````markdown
---
name: kubernetes-security-reviewer
description: Kubernetes security specialist reviewing rendered manifests for over-broad RBAC, missing or permissive security contexts, privileged and hostPath containers, secrets handled as plain env vars, and namespaces without NetworkPolicy. The security dimension of /development-kubernetes:review.
model: opus
tools: Read, Grep, Glob
---

You review **rendered** Kubernetes manifests for security defects. Rendered,
not templated: a chart that reads safely can render a privileged container.

## What to look for

- **RBAC breadth** — `ClusterRole` where a namespaced `Role` suffices;
  wildcard verbs or resources; `escalate`, `bind`, `impersonate`.
- **Security context** — missing `runAsNonRoot`, writable root filesystem,
  `allowPrivilegeEscalation: true`, added capabilities, `privileged: true`.
- **Host access** — `hostPath` volumes, `hostNetwork`, `hostPID`, `hostIPC`.
- **Secrets** — secret material in `env` rather than mounted or referenced;
  secrets committed in plain manifests.
- **NetworkPolicy** — a namespace with workloads and no policy defaults to
  allow-all, which is the opposite of what its author usually assumes.

## Absence findings: consult the whole tree, not just your scope

The NetworkPolicy check is an **absence** claim, and your scope is usually a
subset — the rendered documents a *changed* source produced. A NetworkPolicy
rendered from an unchanged source is outside that subset but very much present
in the cluster. So before reporting a namespace as unprotected, search the
**entire** rendered tree for a policy selecting it; your tools are unrestricted
and the scope bounds what you *review*, not what you may *consult*. Absence of
evidence inside a scope is not evidence of absence, and a false WARNING here
blocks the round on a namespace that was never exposed.

## What NOT to report

**Exactly three things: missing probes, absent resource limits, and `latest`
image tags.** That is the whole list — it is a closed enumeration, not an
example of a broader "whatever `kube-linter` covers" rule. Reporting those three
duplicates the pipeline and trains the reader to skim your findings.

**Do not widen it by reasoning about `kube-linter`'s check set.** Its defaults
overlap several items in *What to look for* — `run-as-non-root`,
`privileged-container`, `privilege-escalation-container`, the `host-*` checks,
`env-var-secret`. Those stay **in scope for you anyway**: a lint warning and a
blocking security finding are different instruments, and a reviewer that
suppressed them as "the linter's job" would silently waive this dimension's core
checks — the worst outcome available here. Where you overlap the linter on a
security control, report it.

## Reporting Format

Report each finding in this shape — the review skill's injected prompt extracts
the severity tag from it, so the tag must be present and spelled exactly:

```text
### [CRITICAL|WARNING|SUGGESTION] One-line title

**File:** path/to/source.yaml:lineNumber
**Description:** What is wrong, and what it costs when it happens.
**Suggested fix:** The concrete remediation.
```

**Report against the CHANGED SOURCE FILE.** You read *rendered* manifests, but
the `file` you report must be a repo-relative path **that appears in your
scope's changed-file list**. Resolve the rendered document back through the
rendered-to-source map your prompt names, then report the *changed* file whose
edit produced the text you are flagging: the `values.yaml` when the field was
substituted, the overlay patch when it was patched, the template only when the
template itself changed. Use `line: null` when the rendered line has no line in
that source file. Never report the rendered temp-tree path, and **never a
directory** — the review loop keeps only findings whose `file` exactly matches a
changed path, so either one is silently discarded and your finding is lost.
Name the temp path in prose as context if it helps; never as `file`.

**Unless your prompt's changed-file list reads `none — standalone run`.** Then
there is no diff and no downstream filter to satisfy, and the list constraint
does not apply: resolve via the render map and report the concrete repo-relative
source **file** the flagged text came from — the patch, `kustomization.yaml`,
`values.yaml`, template or standalone manifest — and **never the chart or
overlay root** the map may name for a kustomize output, since a directory is
still forbidden here. Never withhold a finding for want of a list — reading the
rule as absolute in that mode loses every finding you have, by the opposite
route. And if you cannot tie a finding to a source file at all, report it
against the closest file you can identify with `line: null`, saying the
attribution is approximate: reporting nothing is worse than reporting it
approximately.

**In LOOP mode the same danger has a different shape.** When a changed-file list
*is* given and the flagged text lives in a file the story did not touch — a
deleted child path breaking an unchanged app-of-apps parent, a removed
NetworkPolicy exposing an unchanged namespace — you *can* name a source file, so
the rule above never fires and you would report the unchanged path. The filter
discards it, and the round records clean over a real blocker. Report such a
finding against the **closest CHANGED file in scope** with `line: null`, and say
in the prose which unchanged file the text is actually in.

**Severity guide** — bounded so the review loop converges rather than drowning
in nitpicks:

- **CRITICAL** — the rendered manifest takes the platform or a serving path
  down, or grants cluster-wide privilege.
- **WARNING** — a real defect with a bounded blast radius: one workload
  degraded, one namespace exposed, one app unsyncable.
- **SUGGESTION** — hygiene and clarity. Never blocks a round.
````

- [x] **Step 2: Create the reliability reviewer**

````markdown
---
name: kubernetes-reliability-reviewer
description: Kubernetes reliability specialist reviewing rendered manifests for the failure modes that surface as outages rather than errors — MISCONFIGURED probes (an aggressive liveness probe that restart-loops a slow-starting pod), requests/limits that throttle or OOM-kill, no PodDisruptionBudget, single replicas for stateful paths, anti-affinity that EXISTS but does not work (wrong topologyKey, preferred where required is needed), and rollout strategies that drop capacity. Bare presence/absence checks (a probe missing entirely, no limits set, a latest tag, no anti-affinity at all) belong to kube-linter and are deliberately NOT reported here. The reliability dimension of /development-kubernetes:review.
model: opus
tools: Read, Grep, Glob
---

You are this plugin's analogue of a bug hunter, named for what you actually
hunt. A missing probe is not a crash — it is an outage at 3am under load, and
an agent looking for bugs would look for the wrong thing.

## What to look for

> **What NOT to report**, same closed enumeration as the security reviewer, plus
> one of your own: a missing probe, a missing `requests`/`limits`, a `latest`
> tag — and bare *absence* of anti-affinity, which `kube-linter`'s default
> `no-anti-affinity` check already gates. Report the JUDGEMENT cases below,
> where a probe, a limit or an anti-affinity rule **exists but is wrong**. Two
> tools enforcing one rule means two places to silence one false positive.
>
> That list is closed. Do not extend it by reasoning about what else
> `kube-linter` might cover — every other item below is yours, overlap or not.

- **Probes** — a probe that EXISTS but is wrong: a readiness probe whose
  condition passes before the process can actually serve, so traffic reaches a
  pod that is not ready; or a liveness probe so aggressive it restarts healthy
  pods under load, converting a slowdown into an outage. A probe that is
  *missing entirely* is `kube-linter`'s, not yours.
- **Resources** — `requests` set so far below real usage that the scheduler
  packs the node and everything on it degrades, or `limits` so close to
  `requests` that a normal burst is throttled or OOM-killed. Resources absent
  altogether are `kube-linter`'s.
- **Disruption** — no `PodDisruptionBudget`, so a node drain takes the service
  down. In scope here despite being an absence check: `kube-linter`'s default
  set does not gate on PDB presence, so this is not a duplicate.
- **Placement** — a single replica on a serving path, and **anti-affinity that
  exists but does not work**: the wrong `topologyKey` (so "spread" spreads
  across nothing), or `preferred` rather than `required` on a path that cannot
  survive co-location. Bare *absence* of anti-affinity is **not** yours —
  `kube-linter`'s default set does include `no-anti-affinity`, so reporting it
  is exactly the duplicate the carve-out above forbids. The single-replica case
  stays yours: it is a judgement about the path, not a presence check.
- **Rollout** — `maxUnavailable` that drops below quorum for a stateful set,
  or `Recreate` on a service expected to stay up.

## Absence findings: consult the whole tree, not just your scope

Disruption and Placement are **absence** claims, and your scope is usually a
subset — the rendered documents a *changed* source produced. A
`PodDisruptionBudget` (or an anti-affinity rule) rendered from an unchanged
source is outside that subset but very much present in the cluster. So before
reporting one missing, search the **entire** rendered tree for it; your tools
are unrestricted and the scope bounds what you *review*, not what you may
*consult*. Absence of evidence inside a scope is not evidence of absence, and a
false WARNING here blocks the round on a service that already survives a drain.

## Judgement

A single replica in a demonstration overlay is fine; a single replica in a
production overlay is a finding. Read the overlay before reporting.

## Reporting Format

Report each finding in this shape — the review skill's injected prompt extracts
the severity tag from it, so the tag must be present and spelled exactly:

```text
### [CRITICAL|WARNING|SUGGESTION] One-line title

**File:** path/to/source.yaml:lineNumber
**Description:** What is wrong, and what it costs when it happens.
**Suggested fix:** The concrete remediation.
```

**Report against the CHANGED SOURCE FILE.** You read *rendered* manifests, but
the `file` you report must be a repo-relative path **that appears in your
scope's changed-file list**. Resolve the rendered document back through the
rendered-to-source map your prompt names, then report the *changed* file whose
edit produced the text you are flagging: the `values.yaml` when the field was
substituted, the overlay patch when it was patched, the template only when the
template itself changed. Use `line: null` when the rendered line has no line in
that source file. Never report the rendered temp-tree path, and **never a
directory** — the review loop keeps only findings whose `file` exactly matches a
changed path, so either one is silently discarded and your finding is lost.
Name the temp path in prose as context if it helps; never as `file`.

**Unless your prompt's changed-file list reads `none — standalone run`.** Then
there is no diff and no downstream filter to satisfy, and the list constraint
does not apply: resolve via the render map and report the concrete repo-relative
source **file** the flagged text came from — the patch, `kustomization.yaml`,
`values.yaml`, template or standalone manifest — and **never the chart or
overlay root** the map may name for a kustomize output, since a directory is
still forbidden here. Never withhold a finding for want of a list — reading the
rule as absolute in that mode loses every finding you have, by the opposite
route. And if you cannot tie a finding to a source file at all, report it
against the closest file you can identify with `line: null`, saying the
attribution is approximate: reporting nothing is worse than reporting it
approximately.

**In LOOP mode the same danger has a different shape.** When a changed-file list
*is* given and the flagged text lives in a file the story did not touch — a
deleted child path breaking an unchanged app-of-apps parent, a removed
NetworkPolicy exposing an unchanged namespace — you *can* name a source file, so
the rule above never fires and you would report the unchanged path. The filter
discards it, and the round records clean over a real blocker. Report such a
finding against the **closest CHANGED file in scope** with `line: null`, and say
in the prose which unchanged file the text is actually in.

**Severity guide** — bounded so the review loop converges rather than drowning
in nitpicks:

- **CRITICAL** — the rendered manifest takes the platform or a serving path
  down, or grants cluster-wide privilege.
- **WARNING** — a real defect with a bounded blast radius: one workload
  degraded, one namespace exposed, one app unsyncable.
- **SUGGESTION** — hygiene and clarity. Never blocks a round.
````

- [x] **Step 3: Create the Argo CD advisor**

````markdown
---
name: argocd-advisor
description: Argo CD specialist reviewing Application, ApplicationSet and AppProject resources — app-of-apps structure, sync policy (automated, prune, selfHeal), AppProject restrictions on sources and destinations, sync waves and ordering, and declared paths or revisions that cannot resolve in the repository under review. The argocd dimension of /development-kubernetes:review.
model: opus
tools: Read, Grep, Glob
---

You review Argo CD resources — the layer that decides what actually reaches a
cluster, and therefore where a mistake has the widest blast radius.

## What to look for

- **App-of-apps integrity** — a parent referencing a child path that does not
  exist. This fails silently at sync time, not at review time. **Resolve
  `spec.source.path` against the SOURCE repository root, never the rendered
  tree** — the render tree holds output documents, not the repo's directory
  layout, so resolving there reports every healthy parent as broken.

  Your prompt names that root (and its remote URL, when the repo has one); it is
  how you tell this repository's own `Application`s from another repo's. If the
  prompt gave you no remote URL, read `<repo root>/.git/config` — you have
  `Read`, and its `[remote "origin"] url` is the comparison you need. Match
  loosely: `repoURL` and the git remote routinely differ in scheme, a `.git`
  suffix, or a trailing slash while naming the same repository.

  Then, per `Application`:
  - **`repoURL` is this repository** → resolve `spec.source.path` under the
    source root and report a genuine miss.
  - **`repoURL` is demonstrably some other repository** → skip the existence
    check for that app and say so; you cannot see that repo's tree.
  - **you could not establish this repository's identity at all** → report the
    check as *skipped, reason: repo identity unknown*, for every app. Do **not**
    silently pick a branch: guessing "some other repo" waives the check on this
    repo's own apps — its primary target — and guessing the other way reports
    every healthy parent as broken.
- **Sync policy** — `automated` without `prune` leaves orphans forever;
  `prune` without care deletes resources a human created deliberately;
  `selfHeal` fights manual intervention during an incident, which is exactly
  when someone is intervening manually.
- **AppProject restrictions** — a project permitting `*` source repos or any
  destination namespace is an unbounded deployment surface.
- **Sync waves** — ordering that lets a workload start before the CRD, secret
  or namespace it needs exists.
- **Revision pinning** — `targetRevision: HEAD` makes deployments
  irreproducible; what deployed on Tuesday cannot be recovered on Friday.

## Reporting Format

Report each finding in this shape — the review skill's injected prompt extracts
the severity tag from it, so the tag must be present and spelled exactly:

```text
### [CRITICAL|WARNING|SUGGESTION] One-line title

**File:** path/to/source.yaml:lineNumber
**Description:** What is wrong, and what it costs when it happens.
**Suggested fix:** The concrete remediation.
```

**Report against the CHANGED SOURCE FILE.** You read *rendered* manifests, but
the `file` you report must be a repo-relative path **that appears in your
scope's changed-file list**. Resolve the rendered document back through the
rendered-to-source map your prompt names, then report the *changed* file whose
edit produced the text you are flagging: the `values.yaml` when the field was
substituted, the overlay patch when it was patched, the template only when the
template itself changed. Use `line: null` when the rendered line has no line in
that source file. Never report the rendered temp-tree path, and **never a
directory** — the review loop keeps only findings whose `file` exactly matches a
changed path, so either one is silently discarded and your finding is lost.
Name the temp path in prose as context if it helps; never as `file`.

**Unless your prompt's changed-file list reads `none — standalone run`.** Then
there is no diff and no downstream filter to satisfy, and the list constraint
does not apply: resolve via the render map and report the concrete repo-relative
source **file** the flagged text came from — the patch, `kustomization.yaml`,
`values.yaml`, template or standalone manifest — and **never the chart or
overlay root** the map may name for a kustomize output, since a directory is
still forbidden here. Never withhold a finding for want of a list — reading the
rule as absolute in that mode loses every finding you have, by the opposite
route. And if you cannot tie a finding to a source file at all, report it
against the closest file you can identify with `line: null`, saying the
attribution is approximate: reporting nothing is worse than reporting it
approximately.

**In LOOP mode the same danger has a different shape.** When a changed-file list
*is* given and the flagged text lives in a file the story did not touch — a
deleted child path breaking an unchanged app-of-apps parent, a removed
NetworkPolicy exposing an unchanged namespace — you *can* name a source file, so
the rule above never fires and you would report the unchanged path. The filter
discards it, and the round records clean over a real blocker. Report such a
finding against the **closest CHANGED file in scope** with `line: null`, and say
in the prose which unchanged file the text is actually in.

**Severity guide** — bounded so the review loop converges rather than drowning
in nitpicks:

- **CRITICAL** — the rendered manifest takes the platform or a serving path
  down, or grants cluster-wide privilege.
- **WARNING** — a real defect with a bounded blast radius: one workload
  degraded, one namespace exposed, one app unsyncable.
- **SUGGESTION** — hygiene and clarity. Never blocks a round.
````

- [x] **Step 4: Create the manifest fixer**

```markdown
---
name: kubernetes-manifest-fixer
description: For each manifest_validation finding (kubeconform schema errors, kube-linter warnings, formatting drift), apply the mechanical behaviour-preserving fix and verify by re-running the check; escalate anything that would change what gets deployed. Used by development-kubernetes:maintenance.
model: opus
tools: Read, Edit, Bash, Grep
---

You fix mechanical manifest defects. The line you must not cross: a fix that
changes **what gets deployed** is not mechanical, whatever the linter says.

## Fix

Schema violations with one correct form (a misspelled field, a wrong
apiVersion for the target cluster), formatting and indentation drift, missing
required metadata with an unambiguous value.

## Escalate

Anything altering image tags, replica counts, resource values, RBAC subjects,
or namespace targets. A linter suggesting a *smaller* resource limit is
suggesting a production change, not a lint fix.

**Where an escalation goes.** You are a work agent, not the dispatcher, so
`human_action_required` is not yours to emit. Put every escalation under a
`## Escalations` heading in your final report, one entry per finding, naming the
finding and why it is not mechanical — the orchestrator relays that section to
the human. Never leave an escalated finding as an aside in running prose: an
escalation nothing is contracted to read is a finding you dropped.

## Verify

Re-run the failing check after each fix. A fix that silences a checker without
being verified is indistinguishable from suppressing it.

**If the checker is not installed, say so.** `kubeconform` and `kube-linter`
run in the target repo's CI (#1154); the machine you run on may not have them.
That is not a licence to skip verification silently — report the fix under a
`## Unverified` heading naming the missing tool, so the PR reviewer knows the
fix was reasoned rather than demonstrated. Never install a toolchain to get
around this, and never claim a fix was verified when it was not.

**If the re-run still fails, the fix did not work.** One failed re-verify is
the end of the road for that finding: **revert your edit** and report the
finding under `## Escalations`, naming the check that stayed red and what you
tried. Do not iterate on it — a second and third attempt is how a mechanical
fixer wanders into a redesign — and above all do not leave the edit in place
while reporting the finding as fixed, which closes the group's PR over a check
that is still failing.
```

- [x] **Step 5: Create the policy triage agent**

```markdown
---
name: kubernetes-policy-triage
description: For each policy or policy_tests finding, determine whether a Kyverno policy failure is a real violation in the manifests, a policy that is wrong, or a policy with no test fixtures; fix manifests when the policy is right, and escalate policy changes since a policy encodes an architectural decision the consumer owns. Used by development-kubernetes:maintenance.
model: opus
tools: Read, Edit, Bash, Grep
---

You triage Kyverno policy results. Three outcomes, and telling them apart is
the value you provide.

## 1. The manifest is wrong

The policy is right and a manifest violates it. Fix the manifest.

## 2. The policy is wrong

The policy is over-broad, matches nothing, or encodes a rule the repo has
outgrown. **Escalate — do not edit the policy.** A policy encodes an
architectural decision the consuming repo owns; changing it silently
relaxes an architectural commitment on their behalf.

**Where an escalation goes.** You are a work agent, not the dispatcher, so
`human_action_required` is not yours to emit. Put every escalation under a
`## Escalations` heading in your final report, one entry per policy, naming the
policy file and the decision the human has to make — the orchestrator relays
that section. Never leave it as an aside in running prose: an escalation
nothing is contracted to read is a finding you dropped, and the group's PR must
not close over it silently.

## 3. The policy has no tests

A `policy_tests` finding. Write `kyverno test` fixtures asserting both a
passing and a failing case. This is not busywork: an untested policy usually
matches nothing, so it passes everything and looks like it is working.

**Expect that sentence to come true, and hand off when it does.** The most
likely outcome of writing the failing-case fixture is discovering the policy
does not catch the violation — which *is* case 2, a dead policy, and it
escalates. **Never** adjust the fixture's expected result to `pass` to make the
suite green: that enshrines a match-nothing policy as tested-and-correct, the
exact illusion this case exists to dispel.

## Verify

**Re-run the check that PRODUCED the finding** — they are different commands
and only one of them reads what you changed:

- a **manifest** fix (case 1) is verified by `kyverno apply` of the declared
  policies against the fixed manifests. That is what produced the `policy`
  finding, and it is the only command that evaluates your edit;
- a **fixture** you wrote or changed (case 3) is verified by `kyverno test`,
  which evaluates the resources `kyverno-test.yaml` declares.

Do not substitute one for the other. `kyverno test` after a manifest fix
re-evaluates the *fixtures*, not the manifest — it comes back green without
having read your edit, so you would report the fix verified when nothing checked
it, and the revert-on-failure rule below could never fire because the re-run
cannot fail on a manifest it never looked at. An unrun fixture proves nothing,
and a manifest fix you did not re-check is indistinguishable from a claim.

**If `kyverno` is not installed, say so.** Like `kubeconform` and `kube-linter`,
it runs in the target repo's CI (#1154) and may be absent where you run. Report
the work under an `## Unverified` heading naming the missing tool — never
silently skip verification, never install a toolchain to get around it, and
never claim verification that did not happen.

**If the re-run still fails, the fix did not work** — the same rule
`kubernetes-manifest-fixer` follows, for the same reason. One failed re-verify
ends that finding: **revert whatever you edited for it — manifest *or*
fixture** — and report it under
`## Escalations`, naming the policy that stayed red and what you tried. The
fixture half matters: you write fixtures too, and Verify re-runs after each one,
so a branch that only mentions manifests would leave a failing `kyverno test`
fixture in the tree while escalating. Do not
iterate toward a redesign, and never leave the failing edit in place while
reporting the finding fixed — that closes the group's PR over a red check.

## Never

Do not add policies. This plugin ships none, and generic hygiene belongs to
`kube-linter`.
```

- [x] **Step 6: Create the review skill**

```markdown
---
name: review
description: Perform a comprehensive Kubernetes/IaC review using three specialized parallel agents — security, reliability, and Argo CD. Reviews rendered manifests, not templates.
disable-model-invocation: false
---

# Kubernetes review

## Step 1 — render and dispatch

Dispatch three agents in parallel over the changed manifests:

| Dimension | Agent |
|---|---|
| security | `kubernetes-security-reviewer` |
| reliability | `kubernetes-reliability-reviewer` |
| argocd | `argocd-advisor` |

**Render first, and render the WHOLE repo** — every chart, every unconsumed
kustomization root, every standalone manifest — **regardless of what
`$ARGUMENTS` scopes**. Scope narrows what is *reviewed*, never what is
*rendered*: both reviewers make **absence** claims (a namespace with no
NetworkPolicy, a workload with no PodDisruptionBudget) and are told to confirm
them against the entire rendered tree before reporting. Render only the scoped
chart and that tree is a subset, so a policy or PDB rendered from an unchanged
source is invisible and the reviewer files a false blocking finding against a
resource that was never exposed.

Run `helm template` and `kustomize build` into a temp tree,
then **copy standalone manifests in alongside them** — same exclusions as the CI
render job the #1154 template will ship (chart-owned trees, kustomize inputs).
Without that copy the scope is
chart and overlay output only, so a repo whose Argo CD resources are plain YAML
— the common GitOps layout, and the shape this plugin's own fixture will take
(#1155) — points
`argocd-advisor` at a tree containing no `Application` document. It emits `[]`
deterministically and the round records a clean review of resources no agent
read. A repo with no charts at all would review an empty tree and report clean.

**Render so that provenance survives**, or the reporting rule below cannot be
obeyed: reviewers run in their own contexts with `Read`/`Grep`/`Glob` and no
`Bash`, so whatever the render step does not record, they cannot recover.
`kustomize build` in particular emits one undifferentiated stream carrying no
source annotation at all. So:

- `helm template --output-dir <tmp>/charts/<chart>` — it preserves the
  per-template file structure and the `# Source:` comments;
- write each kustomize root's output to a path **named for that root**
  (`<tmp>/kustomize/<overlay-path>.yaml`), never a single merged file;
- copy standalone manifests **under their repo-relative paths**
  (`<tmp>/standalone/<repo/relative/path>.yaml`), not flattened into one
  directory;
- write `<tmp>/render-map.json` — `{"<rendered path>": "<source repo path>"}` —
  and name that file in the agents' prompt as the mapping to consult.

Point the agents at that tree. A chart that reads safely can render a privileged
container, and the rendered form is what reaches a cluster.

**Skip what the CI render job skips** before rendering — `type: library`
charts, vendored subcharts (a `charts/` parent that is itself a chart),
`kind: Component` kustomizations, **and any kustomization root another root
consumes** via `resources:` / `components:` / `bases:` — the same three keys the
in-scope gate below tests, so both statements of "consumes" in this file
describe one relation — build only unconsumed roots, exactly as the CI job's
second pass does. The first three FAIL by design when rendered standalone, so
enumerating them would fail the round on a repo the plugin's own CI renders
green. The fourth is subtler and matters more: a consumed base renders
*successfully* but **partially**, so it evades the failure rule entirely and
quietly seeds the review tree with documents that never deploy in that form —
the security reviewer would then flag a missing `runAsNonRoot` on a base whose
overlay supplies it. Then: **if any REMAINING render command fails, the round FAILS** — name the chart or overlay and
report the round as failed to the caller and write the detail to the sibling
`<findings-path>.failed.json`, exactly as Step 2 does — **never** to the
findings path itself, which is array-only. Reviewing the partially rendered
tree would report a
complete three-dimension review over a silently truncated scope, and the chart
that failed to render is the one most worth reviewing.

**Then check the tree is worth reviewing, before dispatching anyone.** Two
shapes must not become a clean round:

- the temp tree is **empty** — nothing rendered and nothing copied;
- **no rendered document belongs to a changed source** — the change produced
  nothing this panel can see, which is what a values edit on an excluded library
  chart looks like.

  "Belongs to" is **membership plus consumption**, not map-value equality. A
  rendered document is in scope when its `render-map.json` source — *or any file
  in the same chart or kustomize root as that source, or in any root that root
  transitively consumes* via `resources:` / `components:` / `bases:` — is in the
  changed-file list.

  **A DELETED path is always in scope.** A changed path that no longer exists
  cannot render anything, share a root with anything, or be consumed by
  anything, so every membership test above fails it — and the round would report
  *not applicable* on a diff that deleted a manifest, a chart or a whole
  kustomize root. That is a change which unambiguously alters what deploys, and
  it is precisely the class this panel's own attribution rules legislate for (a
  deleted child path dangling an app-of-apps parent, a removed NetworkPolicy
  exposing a namespace). So: if any changed path no longer exists in the repo
  and was a manifest, a chart root, or a kustomize root — or lived under one —
  **dispatch**.

  **Any such deletion in the diff makes the WHOLE temp tree the scope.** The
  condition is the deletion itself, **not** whether it is what triggered
  dispatch: whenever *any* changed path is a deletion no surviving rendered
  document belongs to — even on a mixed diff where an ordinary edit
  independently triggers dispatch and would bind a perfectly good scope of its
  own — set `{SCOPE}` to the whole temp tree and list the deleted paths in
  `{CHANGED FILES}`, marked as deletions.

  Conditioning on "what triggered dispatch" instead would lose the deletion on
  the commonest shape that carries one: edit chart A *and* delete a standalone
  `Application` — any move-or-remove refactor. Dispatch is triggered by the
  edit, ordinary scope binds to chart A's output, and the deleted manifest's
  effects on *unchanged* documents fall outside every reviewer's scope, so the
  round records clean over the dangling parent. The whole-tree scope is what
  lets the reviewers' absence checks and `argocd-advisor`'s path resolution meet
  those unchanged documents — the exposed namespace, the dangling parent — which
  is the entire point of dispatching on a deletion. (A deleted unit also renders
  nothing, so on a deletion-only diff the ordinary rule would bind `{SCOPE}` to
  nothing and three agents would read nothing and correctly emit `[]` — the same
  clean-round-over-nothing this gate exists to block, arriving one step later.)

  A deleted path that was **not** any of those, and lived under none — a
  repo-root script, a workflow file, a README — is treated exactly like an
  existing path that belongs to no rendered document. Stating that explicitly
  closes the enumeration: without it a deleted non-deploy path satisfies neither
  the dispatch condition nor the reservation below, and a model resolving toward
  "deletions dispatch" would run the panel over a scope containing nothing,
  collect three correct `[]`s, and write a clean aggregate for a change no agent
  reviewed. So: reserve *not applicable* for the case where **no** changed path —
  existing or deleted — belongs to, or was, any rendered unit.

  Both extensions are load-bearing. Equality alone would be wrong on the
  commonest change there is: the map points a rendered document at its
  *template*, so a story editing only `values.yaml` or an overlay patch would
  map back to nothing. And same-root alone would be wrong on the shape this very
  step creates — it builds only *unconsumed* roots, so a change confined to a
  consumed base (`base/deployment.yaml`, consumed by `overlays/prod/`) renders
  into the overlay's output under the *overlay's* root, a different root from
  the changed files. Without the consumption step this gate would refuse to
  dispatch on a change that genuinely alters what deploys.

Either way the three agents would each read nothing, each correctly emit `[]`,
and Step 3 would write a clean aggregate for a change no agent ever reviewed.
So do not dispatch: report the round as **failed** (an empty tree after render
errors) or explicitly **not applicable** (nothing to render at all, or nothing
in scope rendered) to the caller, with the detail in
`<findings-path>.failed.json` and **nothing** written to the findings path.

**The second shape applies only when a changed-file list exists.** On a
standalone run there is none, so "no document maps back to any changed file" is
vacuously true — read literally it would report *every* standalone run as not
applicable and dispatch nobody, a review command that never reviews. In that
mode only the empty-tree shape gates: a non-empty tree always dispatches.

**Scope.** `$ARGUMENTS` names the review scope; with no argument, review every
file **in the temp tree** — rendered output *and* the standalone manifests
copied in alongside it. Say "the temp tree", never "what the render step
produced": the standalone manifests were *copied*, not produced, and a model
reading the narrower phrase points `argocd-advisor` at chart output containing
no `Application` — the exact failure the paragraph above exists to prevent.
Note the mapping: reviewers read *rendered*
output, but "changed" is a property of the *source* — one edited `values.yaml`
can change many rendered documents, so scope by the rendered files a changed
source produces, never by source paths alone. **The deletion branch above
overrides this**: a deletion produces no rendered files, so it scopes to the
whole temp tree instead — and so does any *other* change sharing a diff with
such a deletion.

**Report against the CHANGED SOURCE FILE — the findings are otherwise thrown
away.** The `file` field of every finding object must be a **repo-relative
path to a file that is in the review scope's changed-file list**. Not the
rendered temp-tree path, and not just any source path: specifically the changed
source whose edit produced the rendered text you are reporting on.

- a field substituted from `values.yaml` → `file` is the **`values.yaml`**, not
  the template that consumed it;
- a field added or patched by an overlay → the **overlay patch** or its
  `kustomization.yaml`;
- a template's own line → the **template file** — but only when that template is
  itself in the changed-file list;
- a standalone manifest → its own repo path.

Use `line: null` whenever the rendered line has no line in that source file.

**Never report a directory as `file`** — not a chart directory, not an overlay
root. The filter below matches file paths, so a directory matches nothing and
the finding is discarded unconditionally.

This is not a formatting preference. The resolve-issue loop filters the panel's
aggregate through `review-dispatch.zsh scope-findings`, which keeps only
findings whose `file` **exactly matches an entry in the story's diff**. So both
of the obvious near-misses lose the finding outright: a temp-tree path
(`/tmp/.../helm_app.yaml`) never matches, and neither does an *unchanged*
template file when the actual edit was to `values.yaml` — which is precisely
the case the *Scope* note above calls out as typical. Either way the filtered
array is `[]`, and the loop converges recording a clean round over a blocker it
was told about.

If you genuinely cannot tie a finding to a changed source file, report it
against the **closest changed file that is in scope**, with `line: null`, and
say in the prose that the attribution is approximate. Reporting it against an
out-of-scope path is equivalent to not reporting it at all.

**A standalone run has no changed-file list, and the rule relaxes accordingly.**
Everything above assumes the loop invoked this panel over a story's diff. Run
directly (`/development-kubernetes:review` with no orchestrator), there is no
diff, no changed-file list and **no `scope-findings` filter to satisfy** — so
`file` is the repo-relative **source FILE** the flagged text came from: resolve
via the render map, then name the concrete file — the patch,
`kustomization.yaml`, `values.yaml`, template or standalone manifest — never a
temp path, and never the chart or overlay **root** the map itself may name for a
kustomize output. Say so explicitly when you pass
`{CHANGED FILES}` as `none — standalone run`; a reviewer that reads the
changed-file rule as absolute in that mode withholds every finding it has, which
is the same silent loss by the opposite route.

For each agent, use its name as the `subagent_type` and pass the prompt below,
substituting **all seven** placeholders: `{SCOPE}` (the scope above),
`{DIMENSION}` and `{AGENT NAME}` from the table, `{ROUND}` (the review
round; `1` for a standalone run), `{RENDER MAP}` (the path to the
`render-map.json` the render step wrote), `{REPO}` (the **source repository
root**, plus its remote URL when one exists — `argocd-advisor` needs it to tell
this repo's own `Application`s from another repo's, and it has no `Bash` to ask
`git` itself), and `{CHANGED FILES}` (the story's changed **source** paths, or
the literal `none — standalone run`).

`{CHANGED FILES}` is not optional decoration: the reporting rule below requires
each finding's `file` to be a member of that list, and a reviewer has no `Bash`
and no git access to derive it. Leave it unbound and the rule is unfollowable,
so the reviewer guesses — typically the unchanged template rather than the
edited `values.yaml` — and the loop's filter discards the finding. Leaving
`{AGENT NAME}` unbound corrupts the
`reviewer` field the consolidator keys on. This is where the machine-readable JSON layer is
wired in once, for every agent, so the reviewer definitions stay pure prose:

    Review scope: {SCOPE}
    Source repository root: {REPO}
    Rendered-to-source map: {RENDER MAP}
    Changed source files in scope: {CHANGED FILES}

    Analyze the rendered manifests in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

    Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.

    `file` MUST be one of the changed source files listed above — resolve the rendered document back to its source via the rendered-to-source map, then report the CHANGED file whose edit produced the text you are flagging (the values.yaml or overlay patch when the field was substituted or patched; the template only when the template itself is in that list). Never the rendered temp-tree path, and never a directory: a downstream filter keeps only findings whose file exactly matches a changed path, so anything else is silently discarded and your finding is lost. Use line: null when the rendered line has no line in that source file. When a changed-file list IS given and no changed file produced the flagged text — the text lives in a file this story did not touch, which is exactly how a deleted child path breaks an unchanged app-of-apps parent — do NOT report the unchanged file: the filter discards it on an exact match against the diff, and your finding is lost. Report it against the closest CHANGED file in scope with line: null, and say in the prose that the attribution is approximate and which unchanged file the text is actually in. When the changed-file list is `none — standalone run`, that filter does not exist: resolve via the render map and report the concrete repo-relative source FILE the flagged text came from (patch, kustomization.yaml, values.yaml, template or standalone manifest) — never the chart or overlay root the map may name — and never withhold a finding for want of a list. Either way, if you cannot tie a finding to any file at all, report it against the closest file in scope with line: null and say the attribution is approximate; reporting nothing is worse than reporting it approximately.

Without this block the panel's findings cannot be consumed by
`consolidate-findings.zsh` or the resolve-issue review loop — ARCHITECTURE.md
makes injecting it the *review skill's* job precisely so no reviewer definition
has to carry the boilerplate.

There is no approver dimension. A human approves infrastructure.

## Step 2 — collect

Wait for all three agents. **An agent that fails is not an agent that found
nothing.** If one errors, returns no fenced `json` block, **or returns a block
that does not parse as a JSON array**, re-launch it once;
if it fails again, report the round as **failed** and name the dimension. The
third condition is not redundant: a block holding invalid JSON, or a single
finding *object* rather than an array, satisfies neither of the first two, so
without it the retry never fires and Step 3 concatenates the malformed content —
which every consumer then rejects as "malformed input file", burying the
dimension the signal was supposed to name.

**Do not write the findings path.** It is array-only by contract — but do not
rely on the consumers to catch a violation, because only one of them does.
`resolve-story-loop.zsh` genuinely rejects a non-array and exits 1. The other
two **accept it silently**: `review-dispatch.zsh scope-findings` iterates a
`{"round_failed": …}` object's values, matches nothing and prints `[]` at exit
0, and `consolidate-findings.zsh` has no array guard on `--findings` at all —
it coerces the object into a single bogus `SUGGESTION` and exits 0. So writing
a status object there does not surface as a loud parse error; it produces a
clean or near-clean round over a dimension that failed. That is worse than the
rejection, and it is the reason for the rule. Write the durable detail to a
**sibling** path — `<findings-path>.failed.json` — where nothing parses it as
findings. A missing dimension silently waived is a blocker shipped, so the
failure must be reported to the caller, not inferred from an absent file.

## Step 3 — aggregate

When all three dimensions complete, concatenate their JSON arrays into one array
and write it to the findings path the caller passed (default
`review-findings-round-<round>.json`), then reproduce it inline under a
`## Findings (JSON)` heading. This is the file `consolidate-findings.zsh` and
the resolve-issue loop read; without it a caller that maps an absent file to
`[]` records a clean review that never happened.
```

**Register the two new dimensions — and say how `reliability` differs from
`resilience`.** The family already ships a `resilience` dimension
(`*-resilience-reviewer`, #966) for every service language, meaning the failure
modes that surface as outages. The two are near-homonyms sitting side by side in
one dimension enum, and a reader meeting both invites treating them as
duplicates. (A single review *round* never emits both: `plan` resolves exactly
one `repo_type`, and `kubernetes` is a no-language fallback any **supported**
language beats. It is the *maintenance* dispatch that composes alongside a
language plugin.) State the split explicitly when
registering: `resilience` reviews **application code**'s outbound-dependency
behaviour (breakers, timeouts, fallbacks); `reliability` reviews the **rendered
manifest**'s availability posture (probes, PDBs, replicas, rollout strategy).
They never look at the same artifact. `reliability` and `argocd` extend the
review-dimension enum. ARCHITECTURE.md documents every extension explicitly
(Swift's `swift6_compliance`, the four `development-claude-plugin` dimensions),
so add a kubernetes row to its *Dimension enum* paragraph in this same task —
and note that, like every non-core dimension, they inherit the known
`build-dossier.zsh` `$core` gap (#1148): a **clean** run of a non-core dimension
emits no key at all, which is indistinguishable from "never ran".

- [x] **Step 7: Verify all agent frontmatter parses**

Run:

```bash
set -e   # without this the loop's status is only the LAST file's, so a
         # malformed FIRST agent sails through the step that exists to catch it
for f in development-kubernetes/agents/*.md; do
  python3 -c "
import sys,re
t=open('$f').read()
assert t.startswith('---'), '$f: no frontmatter'
fm=t.split('---')[1]
for k in ('name:','description:','model:','tools:'):
    assert k in fm, '$f: missing '+k
print('$f ok')"
done
```

Expected: five `ok` lines.

> **Before committing, flip the #1151 skeleton gate (the agents half).**
> Adding `development-kubernetes/agents/` falsifies the entry-set equality again
> (`".claude-plugin skills "` → `".claude-plugin agents skills "`) and the
> absence of a `## development-kubernetes` section in `docs/reference/agents.md`.
> In the same PR:
>
> 1. update the entry set and flip the agents.md assertion to `contains`;
> 2. run `python3 scripts/generate-docs-reference.py` and commit the regenerated
>    `docs/reference/agents.md` (and `commands.md`, for the review skill);
> 3. **Bump the `development` plugin too.** The NEXT item modifies content under
>    `development/`, so this PR must also bump `development/.claude-plugin/plugin.json`
>    and its `.claude-plugin/marketplace.json` entry in lockstep (minor) — the
>    same rule Tasks 2, 3 and 6 carry. Without it the `repo_type` registration
>    never reaches an installed copy and the panel stays unreachable, with
>    nothing mechanical to flag it. Stage that manifest as well; "both manifests"
>    below means the kubernetes plugin.json and the root marketplace.json, so
>    this is a THIRD file.
> 4. **register `kubernetes` as a `repo_type` in
>    `development/skills/resolve-issue/scripts/review-dispatch.zsh`** (and in its
>    header-comment enum plus ARCHITECTURE.md's *Review-panel invocation
>    contract*). **Not by appending to the `for l in swift python java go` loop**
>    — that set is intersected with `detect-stack.sh`'s `.languages`, which can
>    never contain `kubernetes`, so appending there is inert and the repo still
>    exits 3. Resolve it the way `claude-plugin` is: a **marker-driven fallback**
>    branch taken only when no supported language matched. That needs a
>    detection signal, and there is exactly ONE right place for it: a
>    `kubernetes` topic key in `detect-stack.sh`, fed by the same
>    Chart.yaml / kustomization.yaml / `argoproj.io` recipe Task 2 registers.
>    **Do not probe the marker inside `review-dispatch.zsh` instead** — Task 6
>    mandates that same key, so an in-script probe would leave the repo with two
>    implementations of one marker recipe that can silently diverge, against
>    ARCHITECTURE's rule that detection is always `detect-stack.sh`'s. Document
>    the key in that script's header output block and stage `detect-stack.sh`;
>    Task 6 depends on it. Without this the new panel is unreachable from the
>    very loop its Step 3 claims to feed;
> 5. **delete the "Until #1153 lands, this table dispatches nothing" paragraph**
>    from `development-kubernetes/skills/maintenance/SKILL.md` (that paragraph
>    says so itself), flip its frontmatter description's
>    "v0.2 REGISTERS … NO agents" sentence back to the present-tense routing
>    sentence, and delete the *No coverage gate, one analogue* qualifier — which
>    means **exactly** its "**Until #1153, this section describes the
>    destination, not today's behaviour.**" paragraph, plus the
>    "**once #1153 ships `kubernetes-policy-triage`**" hedge in the sentence
>    above it. **Keep** that section's `ordering-blocking` rule and its
>    "Never drop the group" sentence — `tests/kubernetes-dispatcher.bats` still
>    requires both — otherwise
>    post-#1153 runs keep halting every group with a `human_action_required`
>    naming a closed issue, and the coverage section keeps deferring to a
>    paragraph that no longer exists;
> 5b. **retire `tests/kubernetes-dispatcher.bats`'s self-expiring pins in the
>    same PR** — the suite is deliberately built to red here. **Nine** assertions
>    fail the moment this task lands — count them against the list below, not
>    against the four enclosing `@test` blocks: `'Until #1153 lands, this table dispatches
>    nothing'`, `'Delete this paragraph in #1153'`, the
>    `'rewrite the "v0.2 REGISTERS ... NO agents" sentence'` needle,
>    `contains "$FRONTMATTER" 'ships NO agents'`,
>    `contains "$FRONTMATTER" 'v0.2 REGISTERS the routing table'` (item 5
>    rewrites exactly that sentence), `'return every group as a
>    \`human_action_required\` entry'` (that string lives only in the paragraph
>    item 5 deletes, and the needle is scoped to the whole *Routing* section),
>    `'once #1153 ships \`kubernetes-policy-triage\`'`,
>    `'*Routing* wins until its paragraph is deleted'`, and the final
>    `[ ! -d "$REPO_ROOT/development-kubernetes/agents" ]`. **Flip** each to its
>    post-landing form (assert the routing table is live and the agents exist)
>    rather than deleting them, so the contract stays pinned in its new
>    direction. The skeleton suite's `[ ! -d "$PLUGIN_DIR/agents" ]` (item 1's
>    entry-set assertion) flips with them;
> 6. register the new `reliability` and `argocd` dimensions in ARCHITECTURE.md's
>    *Dimension enum* paragraph, per Step 6;
> 7. **bump `plugin.json` + `marketplace.json` in lockstep** (minor) and update
>    the slice-status sentence of the identical descriptions;
> 8. update `docs/reference/plugins.md`: bump its `**What's built (vX):**` label
>    and rewrite the narrative to name what has landed, and add the
>    `**Agents:**` table plus the `review` row to its Skills table — every
>    agent-shipping plugin section in that file carries one, and nothing
>    mechanical catches its absence (reference-drift regenerates only
>    `commands.md`/`agents.md`);
> 9. update the two slice-status registries now that the agents and review skill
>    have landed: `README.md`'s slice cell (**pinned** by
>    `tests/kubernetes-plugin-skeleton.bats` — relax the needle in the same PR,
>    whatever wording #1152 left it at) and `docs/explanation/motivation.md`'s
>    remaining-children sentence (genuinely uncovered);
> 10. **last**, run the whole suite.
>
> `git add` must therefore also stage `tests/kubernetes-plugin-skeleton.bats`,
> `tests/kubernetes-dispatcher.bats` (item 5b), `docs/reference/`,
> `ARCHITECTURE.md`, `README.md`,
> `docs/explanation/motivation.md`,
> `docs/superpowers/plans/2026-08-02-development-kubernetes.md` (re-sync Task 1's
> blocks), `development-kubernetes/skills/maintenance/SKILL.md`,
> `development/skills/resolve-issue/scripts/review-dispatch.zsh`,
> `development/skills/bootstrap/scripts/detect-stack.sh` (item 4's topic key),
> and both manifests.

- [x] **Step 8: Commit**

```bash
git add development-kubernetes/agents development-kubernetes/skills/review
# plus every file the box above requires — re-read it before committing;
# `git status` must be clean afterwards
git commit -m "feat(development-kubernetes): five agents and the review skill

The reliability reviewer is this plugin's analogue of a bug hunter, named
for what it hunts — a missing probe is an outage at 3am, not a crash.

The policy triage agent escalates rather than edits a wrong policy: a
policy encodes an architectural decision the consuming repo owns.

No approver agent.

Refs #1153"
```

---

### Task 6: Bootstrap IaC support — the check pipeline

Child #1154. The child that produces requirable status checks.

**Files:**

- Consumes: the `kubernetes` topic key in
  `development/skills/bootstrap/scripts/detect-stack.sh` — **added by Task 5
  (#1153), which lands first.** Do NOT add a second detection block: a duplicate
  is precisely the two-implementations-of-one-recipe divergence Task 5 forbids.
  Verify the key is present and documented in the script's header output block,
  and only add it here if you are executing this task standalone. It matters
  because bootstrap's ONLY detector is that script and topics otherwise live in
  `development/skills/maintenance/SKILL.md`, which bootstrap never reads — so
  without the key the branch below can never fire and a GitOps repo bootstraps
  silently with no workflow and no `primary: kubernetes`, an omission neither
  the yamllint step nor the bats suite can see.
- Modify: `development/skills/bootstrap/SKILL.md` — also extend the
  `{{PRIMARY}}` resolution table, whose branches today are (0) `claude-plugin`
  marker, (1) exactly one language, (2) several languages → ask. There is **no
  zero-language branch**, so the placeholder would not resolve to `kubernetes`
  even once the section below lands; the two sites must state one rule.
- Create: `development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl`
- Modify: `development/skills/bootstrap/SKILL.md`
- Create: `tests/bootstrap-iac-pipeline.bats` — **amended into this list as it
  shipped.** Step 3 below only *parses* the template, which cannot see the
  properties the story is actually about: that every check consumes the rendered
  artifact, that the policy step stays green on an absent, empty or `.json`-only
  `policies/kyverno/` but enforces a declared one, and that the render job
  survives the canonical base + two-overlays layout. Every `run:` step is
  extracted by name and executed against real directory shapes with recording
  stubs; structure alone cannot distinguish a passing check from a vacuous one.
- Modify: `development/skills/bootstrap/scripts/branch-protection.sh` —
  **amended in.** The task as planned left branch protection to a manual Step 5
  item, which review showed drops far more than the contexts: the script is also
  the only site that PATCHes `allow_auto_merge` / `delete_branch_on_merge`, so
  skipping it puts every IaC bootstrap into Step 4e's *arming failed* branch and
  leaves the default branch unprotected. `--iac-only true` instead swaps the
  language-app contexts for the six kubernetes-ci jobs and changes nothing else.
- Modify: `.github/workflows/script-tests.yml`, `tests/Dockerfile` — `yamllint`
  and `yq` become declared test dependencies (the new suite calls both
  unguarded), and the path-filter comment records its second dependant.
- Modify: `MAINTAINING.md` — the template downloads four CLIs by release URL
  (`KUBECONFORM_VERSION`, `KUBE_LINTER_VERSION`, `KYVERNO_VERSION`,
  `YQ_VERSION`). That pin class matches none of Step 1's recipes and no Renovate
  manager, so it gets its own inventory line.

**Interfaces:**

- Consumes: the `policies/kyverno/` convention from Task 3.
- Produces: six named checks — `render`, `schema`, `lint`, `policy`, `config-scan`, `argocd`.

- [x] **Step 1: Create the workflow template**

> **LANDED — read the file, not this section.** The workflow shipped as
> `development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl`,
> and the local review loop changed it in ways that matter, so the draft that
> used to be reproduced here has been removed rather than left to be
> regenerated from. What the review corrected, each with a behavioural test in
> `tests/bootstrap-iac-pipeline.bats`:
>
> - **errexit**: the kustomize passes' `[ … ] && break` / `&& continue`
>   AND-lists became if-statements. A `while` loop exits with its last body
>   command's status, so the AND-list form killed the render job under `set -e`
>   on the canonical base + two-overlays layout — and every downstream check
>   `needs: render`.
> - **quoted scalars**: the `type: library`, `kind: Component` and
>   `kind: (Cluster)Policy` probes tolerate optional quotes and a trailing
>   comment. `kind: "ClusterPolicy"` is ordinary house style, and an
>   unquoted-only match dropped every policy file of such a repo.
> - **the unevaluable-policy branch FAILS** (`::error::` + exit 1) rather than
>   warning and skipping: the charter has exactly one skip condition — no file
>   matching the glob — so a declared set the pinned CLI cannot run is a failure
>   to report, never a green check over unenforced policies.
> - **the sentinel** gates on object presence (`grep -rqE '^kind:'`), not on
>   `ls -A`: a chart whose manifests are all value-gated off renders an
>   object-free file that would suppress the sentinel while `kube-linter` still
>   errors with "no valid objects found".
> - **`lint` and `config-scan` check out the repo**, so the `.trivyignore` /
>   `.kube-linter.yaml` tuning this template tells consumers they may own is
>   actually visible to the tools.
> - **the consumed-scan reads `kustomize-roots.txt`**, so a base consumed only
>   through a Component is not built standalone.
> - smaller: a root chart's slug normalises to `root`; the argocd sweep has one
>   `find` start point; the repoURL normalisation strips the trailing slash
>   before `.git`.
>
> Every `uses:` is pinned to a full commit SHA with a `# <tag>` comment, per
> MAINTAINING.md Step 2 — the semgrep gate bootstrap installs **blocks mutable
> tags in downstream repos**, so a template floating on `@v4` would ship
> consumers a workflow their own quality gate flags. The path matters too: a
> `.tmpl` under a `.github/workflows/` segment mirrors every other workflow
> template's layout and keeps the pins where Renovate's `.tmpl` manager sees
> them.

- [x] **Step 2: Teach bootstrap to emit it**

> **LANDED — read `development/skills/bootstrap/SKILL.md` §3l.** The draft
> reproduced here keyed the path on *detection* output and said only "emit the
> template, write `primary: kubernetes`". Review established four rules it did
> not have, all of which the shipped section carries:
>
> - it keys on the **resolved** language set (after Q4), not on detection — a
>   language the user names for a repo the detector missed makes it a language
>   repo, and `{{PRIMARY}}` branch (2) states the same rule;
> - it enumerates **exactly what is and is not emitted** (a table), because
>   §3b/§3c select by visibility with no language condition and would otherwise
>   render a `quality-*.yml` whose `sonarcloud` job needs a job the stripped
>   `LINUX_TESTS` block never produced — a workflow GitHub refuses to run;
> - **branch protection still runs**, via `branch-protection.sh --iac-only
>   true`. The first draft skipped the script, which silently dropped the
>   `allow_auto_merge` / `delete_branch_on_merge` PATCH that Step 4e's arming
>   depends on and left the default branch unprotected;
> - **Step 4.5 skips the per-path automation** on this path, because
>   `automate-*.sh` re-invokes `branch-protection.sh` *without* the flag and its
>   PUT would replace the rule with contexts nothing reports.
>
> Step 3.6 also gained a provenance row for the rendered workflow, and
> `detect-stack.sh` holds the not-emitted set out of `missing_artifacts` so a
> State-D re-bootstrap cannot render it blind.

- [x] **Step 3: Verify the workflow is valid YAML**

Run — one physical line, for the same reason:

```bash
yamllint --strict development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl && echo 'yamllint ok'
```

`yamllint --strict`, not `yaml.safe_load`: the repo lints every `*.yml` through a
pre-commit hook that CI runs as a required check, and `safe_load` passes happily
on the `line-length` and `braces` violations that hook rejects. Parsing is not
the gate.

Expected: `yamllint ok`

> **In the same PR as the template.** `ARCHITECTURE.md` currently says the six
> checks are what bootstrap's `templates/iac/.github/workflows/kubernetes-ci.yml.tmpl` **will emit
> (#1154)** and "where they will live" — deliberately future-tense, because the
> file does not exist yet. Landing it makes that tense wrong, so flip the
> paragraph to the present tense here. **`development-kubernetes` moves by a
> PATCH** (0.3.0 → 0.3.1) — corrected again from the earlier "do NOT bump"
> instruction, which assumed nothing installable in that plugin changes here.
> The pipeline itself is all `development/` content (the template, the SKILL
> rules, `branch-protection.sh`), so the MINOR does not move; but this task also
> edits `development-kubernetes/skills/review/SKILL.md`'s cross-reference to the
> template, and MAINTAINING.md's rule admits no exception for content under
> `<plugin>/` — Claude Code caches by version, so an unbumped edit ships inert.
> Its `**What's built (vX):**` label therefore stays put; rewrite the narrative
> around it instead, so the page attributes the pipeline to the `development`
> bootstrap skill where it actually lives — whatever wording the earlier children
> left it at (#1152 rewrote it to name the dispatcher, marker and gather; #1153
> rewrites it again), it will not mention the CI pipeline this task ships.
> `git add`
> must stage `ARCHITECTURE.md`, `docs/reference/plugins.md`, `README.md`,
> `docs/explanation/motivation.md`, **`tests/kubernetes-plugin-skeleton.bats`**,
> `docs/superpowers/plans/2026-08-02-development-kubernetes.md` (re-sync Task 1's
> blocks) and both manifests alongside the template.
>
> The suite is not optional here: it pins the `**What's built (vX):**` label in
> `plugins.md` and the README row's slice-status claim — **whatever wording the
> earlier children left them at** (#1152 and #1153 each relax and re-pin these),
> so read the current needles before editing and relax BOTH. No
> *generated-docs drift* check covers those two registries; the bats suite does.
>
> **Then run the whole suite** —
> `zsh development/skills/resolve-issue/scripts/run-gate.zsh --tests-dir tests`.
> Step 3's YAML parse checks the template only; this task also rewords the
> ARCHITECTURE six-checks paragraph and the `**What's built (vX):**` label, both
> of which the skeleton suite pins, so a tense flip that breaks a needle would
> otherwise ship red and surface only in CI.
>
> **Bump `development` (minor) and `development-kubernetes` (patch).** This task
> modifies content under both, and every PR that does must bump that plugin's
> `<plugin>/.claude-plugin/plugin.json`
> **and** its `.claude-plugin/marketplace.json` entry in lockstep —
> Claude Code caches plugins by version, so an omitted bump means installs never
> see the change and the fix silently appears inert. `marketplace-sync.yml`
> catches only *disagreement* between the two files, never an omitted bump, so
> nothing will flag it. Stage all THREE manifest files —
> `development/.claude-plugin/plugin.json`,
> `development-kubernetes/.claude-plugin/plugin.json` and the single root
> `.claude-plugin/marketplace.json`, which carries both entries. (The only
> other marketplace.json in the repo is the `tests/fixtures/clean/` one,
> which must NOT be bumped.)

- [x] **Step 4: Commit**

```bash
git add development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl development/skills/bootstrap/SKILL.md
# plus every file the box above requires — re-read it before committing;
# `git status` must be clean afterwards
git commit -m "feat(development): bootstrap IaC support — the check pipeline

Six jobs, each a separately requirable check. Everything downstream
validates RENDERED output, not templates: a chart that lints clean can
render an invalid manifest, and the rendered form is what reaches a
cluster.

Rendering is why this works on a repo with no application code — there is
always something to validate.

The policy job exits 0 with a notice when policies/kyverno/ is absent.

Refs #1154"
```

---

### Task 7: Self-contained test fixtures

Child #1155.

**THREE sibling whole-repo variants**, not one. Each is a repository shape in its
own right, so a tool (or the pipeline) is pointed at exactly one variant at a
time — the same way it would meet a real repo. A single variant holding both
clean and broken manifests is impossible: each of the pipeline's `lint`, `policy` and
`argocd` jobs fails the whole job when any finding is present, so a repo
containing the broken subset could never simultaneously demonstrate the green
case.

This task's acceptance is **tool-level** — the fixture is proven by running
`helm`, `kustomize`, `kube-linter` and `kyverno` directly against the tree. The
pipeline-level claim (that `kubernetes-ci.yml` greens on the clean variant and
reds on the broken one) belongs to **#1199**, the real-tool harness, which owns
the bats file and the `tests/Dockerfile` / `script-tests.yml` tool installs that
executing the workflow requires.

**Files:**

Variant 1 — `tests/fixtures/kubernetes-repo/` (clean, expected fully green):

- Create: `tests/fixtures/kubernetes-repo/charts/app/Chart.yaml`
- Create: `tests/fixtures/kubernetes-repo/charts/app/templates/deployment.yaml`
- Create: `tests/fixtures/kubernetes-repo/charts/app/templates/configmap.yaml` (the one
  genuinely TEMPLATED manifest, so an absent or empty helm render is observable)
- Create: `tests/fixtures/kubernetes-repo/charts/app/values.yaml`
- Create: `tests/fixtures/kubernetes-repo/kustomize/base/kustomization.yaml`
- Create: `tests/fixtures/kubernetes-repo/kustomize/base/deployment.yaml` (the
  resource the base's `resources:` names)
- Create: `tests/fixtures/kubernetes-repo/kustomize/overlays/prod/kustomization.yaml` —
  the spec requires a Kustomize overlay, and without one the kustomize half of
  the machinery (the marker's `kustomization.yaml` branch, the gather's sweep,
  and Task 6's kustomize-roots recording / Component exclusion / input
  sweep-exclusion) is never exercised
- Create: `tests/fixtures/kubernetes-repo/argocd/app-of-apps.yaml`
- Create: `tests/fixtures/kubernetes-repo/argocd/foreign-app.yaml` (a NEGATIVE
  control: a foreign-slug Application whose absent path must stay unchecked, so a
  filter widened to `contains` reds the clean variant)
- Create: `tests/fixtures/kubernetes-repo/policies/kyverno/require-registry.yaml`
- Create: `tests/fixtures/kubernetes-repo/policies/kyverno/kyverno-test.yaml` (PASS-ONLY)
- Create: `tests/fixtures/kubernetes-repo/.kube-linter.yaml`
- Create: `tests/fixtures/kubernetes-repo/README.md`

Variant 2 — `tests/fixtures/kubernetes-repo-broken/` (every deliberate defect):

- Create: `tests/fixtures/kubernetes-repo-broken/broken/no-probe.yaml`
- Create: `tests/fixtures/kubernetes-repo-broken/broken/no-limits.yaml`
- Create: `tests/fixtures/kubernetes-repo-broken/broken/latest-tag.yaml`
- Create: `tests/fixtures/kubernetes-repo-broken/broken/bad-registry.yaml`
- Create: `tests/fixtures/kubernetes-repo-broken/broken/argocd/dangling-app.yaml`
- Create: `tests/fixtures/kubernetes-repo-broken/broken/argocd/dangling-multisource.yaml`
  (the same defect via `.spec.sources[]`, so the multi-source leg is load-bearing)
- Create: `tests/fixtures/kubernetes-repo-broken/policies/kyverno/require-registry.yaml`
- Create: `tests/fixtures/kubernetes-repo-broken/policies/kyverno/kyverno-test.yaml` (expected-FAIL)
- Create: `tests/fixtures/kubernetes-repo-broken/.kube-linter.yaml`
- Create: `tests/fixtures/kubernetes-repo-broken/README.md`

Variant 3 — `tests/fixtures/kubernetes-repo-untested-policy/` (policy, no tests):

- Create: `tests/fixtures/kubernetes-repo-untested-policy/policies/kyverno/require-registry.yaml`
- Create: `tests/fixtures/kubernetes-repo-untested-policy/charts/app/Chart.yaml` — NOT
  decoration: the topic marker fires on Chart.yaml / kustomization* / an `argoproj.io`
  reference, none of which a bare `policies/kyverno/` carries, so without it the variant
  is undetectable as a Kubernetes repo and unreachable by the machinery it exercises
- Create: `tests/fixtures/kubernetes-repo-untested-policy/charts/app/templates/deployment.yaml` —
  a real workload, so `kyverno apply` evaluates something and `lint` has a valid object
  rather than three jobs passing vacuously
- Create: `tests/fixtures/kubernetes-repo-untested-policy/charts/app/templates/configmap.yaml`
- Create: `tests/fixtures/kubernetes-repo-untested-policy/charts/app/values.yaml` — with the
  configmap above, the same observable-render construction as the clean variant, so an
  absent or empty helm render is red here too
- Create: `tests/fixtures/kubernetes-repo-untested-policy/.kube-linter.yaml` — identical to
  its siblings', so all three variants are linted under ONE check set
- Create: `tests/fixtures/kubernetes-repo-untested-policy/README.md`

**Interfaces:**

- Consumes: nothing. Deliberately self-contained — no network, no private content, no reference to any real deployment.

- [x] **Step 1: Create the clean chart**

`charts/app/Chart.yaml`:

```yaml
apiVersion: v2
name: app
version: 0.1.0
```

`charts/app/templates/deployment.yaml` — clean **by construction** against
kube-linter's default set plus the one non-default check `.kube-linter.yaml`
enables, never clean by exclusion. Note `ports:`, which the default
`readiness-port` check requires once a probe names a port; the `capabilities.drop`
that `drop-net-raw-capability` requires; the `readOnlyRootFilesystem` that
`no-read-only-root-fs` requires; and the pod anti-affinity that `no-anti-affinity`
requires at `replicas: 2`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: app
              topologyKey: kubernetes.io/hostname
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: app
          image: registry.example.com/app:1.0.0
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
```

`.kube-linter.yaml` — the default set plus exactly one non-default check, and
**no exclusions**. Without it `broken/no-probe.yaml` would map to no check at all,
since neither `no-readiness-probe` nor `no-liveness-probe` is a default:

```yaml
checks:
  include:
    - no-readiness-probe
```

The identical file is copied into BOTH sibling variants, so all three are linted
under one check set.

- [x] **Step 2: Create the Kustomize base and prod overlay**

Without these the kustomize half of the machinery — the topic marker's
`kustomization.yaml` branch, the gather's marker sweep, and Task 6's
kustomize-roots recording and kustomize-input sweep-exclusion — is never
exercised. Two neighbouring branches stay UNCOVERED by this tree and are
deliberately left to #1199: `kind: Component` exclusion (no Component directory
is shipped) and the alternate marker spellings `kustomization.yml` /
`Kustomization`. The base carries a real resource so the
input-exclusion is genuinely tested: that Deployment must NOT reach the
validators unrendered.

`tests/fixtures/kubernetes-repo/kustomize/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
```

`tests/fixtures/kubernetes-repo/kustomize/base/deployment.yaml` — genuinely
partial: **no image tag**, no resources, no probe, no securityContext. That is
the point. A base like this is invalid on its own (kube-linter would fire
`latest-tag`, `unset-cpu-requirements` and `run-as-non-root` on it), so if
Task 6's plain-manifest sweep ever stopped excluding kustomize inputs, the
fixture's *clean* half would red — which is exactly the regression the
exclusion exists to prevent, made observable:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: worker
  template:
    metadata:
      labels:
        app: worker
    spec:
      containers:
        - name: worker
          image: registry.example.com/worker
```

`tests/fixtures/kubernetes-repo/kustomize/overlays/prod/kustomization.yaml` —
the overlay genuinely **completes** the base, so the rendered output is clean.
It bumps to 3 replicas and therefore **must supply a pod anti-affinity**: at
`count: 3` the default `no-anti-affinity` check genuinely applies, so an overlay
that raised the replica count without one would red the clean variant. A
strategic-merge patch keeps the completion readable:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - ../../base
replicas:
  - name: worker
    count: 3
images:
  - name: registry.example.com/worker
    newTag: "1.0.0"
patches:
  - patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: worker
      spec:
        template:
          spec:
            affinity:
              podAntiAffinity:
                requiredDuringSchedulingIgnoredDuringExecution:
                  - labelSelector:
                      matchLabels:
                        app: worker
                    topologyKey: kubernetes.io/hostname
            securityContext:
              runAsNonRoot: true
              runAsUser: 1000
            containers:
              - name: worker
                ports:
                  - containerPort: 8080
                readinessProbe:
                  httpGet:
                    path: /healthz
                    port: 8080
                resources:
                  requests:
                    cpu: 100m
                    memory: 128Mi
                  limits:
                    cpu: 500m
                    memory: 256Mi
                securityContext:
                  readOnlyRootFilesystem: true
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop:
                      - ALL
```

Verify: `kustomize build tests/fixtures/kubernetes-repo/kustomize/overlays/prod`
exits 0 and renders a 3-replica Deployment in namespace `prod` whose image is
`registry.example.com/worker:1.0.0` (tagged, and on the registry the Kyverno
policy allows) with resources, a readiness probe, `runAsNonRoot`,
`readOnlyRootFilesystem`, dropped capabilities and an anti-affinity — i.e. the
rendered output is clean even though the base is not.

- [x] **Step 3: Create the deliberately broken manifests (variant 2)**

**One defect per FILE**, not four in one manifest: each file is the clean chart's
deployment with exactly **one guarantee removed** and everything else retained,
so no default check fires incidentally and a regression reads as
"`no-limits.yaml` stopped firing `unset-cpu-requirements`" rather than "the
fixture went red".

| file | removed guarantee | owning job | check id(s) |
| --- | --- | --- | --- |
| `broken/no-probe.yaml` | readiness probe | `lint` | `no-readiness-probe` |
| `broken/no-limits.yaml` | resource requests/limits | `lint` | `unset-cpu-requirements`, `unset-memory-requirements` |
| `broken/latest-tag.yaml` | pinned image tag | `lint` | `latest-tag` |
| `broken/bad-registry.yaml` | allowed registry | `policy` | kyverno `require-registry` / `autogen-images-from-allowed-registry` |
| `broken/argocd/dangling-app.yaml` | app path exists | `argocd` | `app-of-apps references missing path: charts/does-not-exist` |
| `broken/argocd/dangling-multisource.yaml` | app path exists, via `.spec.sources[]` | `argocd` | `app-of-apps references missing path: charts/also-missing` |

`no-limits.yaml` stays **one file carrying two check ids** — one removed
guarantee, two ways kube-linter names it — and is deliberately not split.

Two separations keep every row one-to-one: `latest-tag.yaml` stays on the
**allowed** registry (`registry.example.com/app:latest`), so only `latest-tag`
fires and the Kyverno rule keeps passing; and `bad-registry.yaml` is **pinned**
(`other-registry.example.com/nginx:1.27.0`), so `latest-tag` does not also fire
and the only finding is the policy one. The off-registry host is an
`example.com` placeholder rather than a real registry, because the fixture's
self-containedness rule admits no hostname outside `example.com` and
`kubernetes.default.svc`.

The broken variant's `README.md` carries that table plus, in prose: which jobs
own nothing (`render`, `schema` and `config-scan` are green even here —
`config-scan` is thresholded at `HIGH,CRITICAL`, which none of these defects
reaches, so a red there is a regression); that `kyverno test` is never reached
under the pipeline in this variant; the temp-dir-copy caveat; and the
`REPO_SLUG` contract.

- [x] **Step 4: Create the policy and its two test fixtures**

`policies/kyverno/require-registry.yaml` — identical in all three variants:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-registry
spec:
  validationFailureAction: Enforce
  rules:
    - name: images-from-allowed-registry
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "images must come from registry.example.com"
        pattern:
          spec:
            containers:
              - image: "registry.example.com/*"
```

The single fixture is **split across the two variants** — a variant whose whole
point is that nothing fails must not park an expected-fail resource in it.

The rule named in `results:` is the **autogen** one: the policy matches
`kinds: [Pod]`, and Kyverno generates a Deployment/DaemonSet/StatefulSet variant
of the rule automatically, so a fixture naming the bare rule name matches nothing.

Clean variant — `tests/fixtures/kubernetes-repo/policies/kyverno/kyverno-test.yaml`,
**pass-only**, whose resource is a plain-YAML chart template that the render
sweep's `-not -path '*/templates/*'` already excludes (a test input, never a
validated manifest):

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-registry-test
policies:
  - require-registry.yaml
resources:
  - ../../charts/app/templates/deployment.yaml
results:
  - policy: require-registry
    rule: autogen-images-from-allowed-registry
    resources:
      - app
    kind: Deployment
    result: pass
```

Broken variant — `tests/fixtures/kubernetes-repo-broken/policies/kyverno/kyverno-test.yaml`,
the **expected-fail** half:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-registry-test
policies:
  - require-registry.yaml
resources:
  - ../../broken/bad-registry.yaml
results:
  - policy: require-registry
    rule: autogen-images-from-allowed-registry
    resources:
      - bad-registry
    kind: Deployment
    result: fail
```

Note the ordering consequence: the pipeline's policy step runs `kyverno apply`
**before** `kyverno test`, and under `set -euo pipefail` the non-zero exit of
`kyverno apply` over `bad-registry.yaml` ends the step. The expected-fail fixture
is therefore verified by running `kyverno test` **directly** against the broken
variant, not through the pipeline.

Variant 3 — `tests/fixtures/kubernetes-repo-untested-policy/` holds the same
policy and **no** `kyverno-test.yaml`, so the untested-policy path (a
`policy_tests` maintenance finding, and the pipeline's
`policies declared but no kyverno test fixtures` warning) is exercised.

- [x] **Step 5: Create the app-of-apps and the READMEs**

Each Argo-CD-bearing variant declares **at least one** repoURL naming **its own
directory**, because the `argocd` job filters Application paths by a repoURL
ending in the runner's `github.repository`. The clean variant deliberately also
ships one that does NOT — `argocd/foreign-app.yaml`, slug
`fixture-org/kubernetes-repo-extra`, path `charts/does-not-exist` — as a NEGATIVE
control: its slug has the variant's own slug as a strict prefix, so a filter
regressed from a path-boundary `endswith` to a `contains` match would select it,
find the absent path and red the clean variant.

`tests/fixtures/kubernetes-repo/argocd/app-of-apps.yaml` — `path` resolves:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
spec:
  project: default
  source:
    repoURL: https://example.com/fixture-org/kubernetes-repo.git
    targetRevision: v1.0.0
    path: charts/app
  destination:
    server: https://kubernetes.default.svc
    namespace: fixture
```

`tests/fixtures/kubernetes-repo-broken/broken/argocd/dangling-app.yaml` — same
shape, with `repoURL: https://example.com/fixture-org/kubernetes-repo-broken.git`
and `path: charts/does-not-exist`.

**The fixture contract.** Any harness exercising the `argocd` job against an
Argo-CD-bearing variant must present the slug `fixture-org/<variant-dir>` to it.
Note *how*: the workflow pins `REPO_SLUG: ${{ github.repository }}` at step
level, and a step-level `env:` beats an exported shell variable — so exporting
`REPO_SLUG` around an unmodified workflow run does nothing. The contract is met
by a harness that **executes the job's `run:` block** with `REPO_SLUG` set, or by
overriding `github.repository`. Without it the repoURL filter selects nothing and
the job passes **vacuously** with the dangling path unchecked. Variant 3 ships no Application, so it pins no
particular slug — but `REPO_SLUG` must still be set to some **non-empty** value
there, and the two failure modes differ. **Unset**, the job dies on an unbound
variable: the compile probe dereferences `$REPO_SLUG` under `set -euo pipefail`
before any Application is read. **Empty** is worse — the probe URL collapses to a
bare host with a trailing slash, the filter's `endswith("/" + $s)` guard
degenerates to `endswith("/")` which is TRUE, so the probe *passes* and the job
greens having selected nothing: a vacuous pass the probe does not catch. Closing
that blind spot in the workflow belongs to #1199, not to this fixture. Naming that contract in each README and in an acceptance
criterion is this task's whole obligation; wiring a harness that sets it belongs
to #1199.

Each variant's `README.md` states its expectation (fully green / red with every
finding attributable to one file / green with the untested-policy warning), names
its required `REPO_SLUG` where it has one, and carries the **run against a copy, never the working
tree** caveat: the policy job dereferences `policies/kyverno` in place
(`rm -rf` then `mv`), so pointing a local pipeline run at a fixture directory
would rewrite it.

- [x] **Step 6: Verify the fixture with the real toolchain and the YAML gate**

Run the pinned toolchain the pipeline itself installs — kube-linter 0.7.2,
kyverno 1.13.4, kubeconform 0.6.7 — directly against the tree:

Invoke `kube-linter` **without `--config`**, exactly as the pipeline invokes it:
it auto-discovers `./.kube-linter.yaml` from the working directory, and that
discovery is what makes the non-default `no-readiness-probe` check apply at all.
Verifying with an explicit `--config` would stay green in precisely the case
where the pipeline's own form silently drops the check.

Each variant's own `README.md` carries the **authoritative** recipe, with the
full assertions; the block below is a summary — run the READMEs' recipes before
recording the fixture verified. Three properties they have that a narrower recipe
would miss, and which differ per variant:

- variants 1 and 2 rebuild the pipeline's **whole** `RENDER_DIR` (the render job
  also sweeps the standalone Argo CD and `policies/kyverno` manifests, so
  validating only the renders leaves those unchecked);
- variants 1 and 3 assert kyverno's **`pass:` counter**, because `kyverno apply`
  exits 0 both when the rule passed and when it matched nothing; variant 2's
  expected result is instead a counted **`fail: 1`**, which also distinguishes a
  real violation from a tool error;
- variant 2's commands are **expected to fail**, so each is wrapped in an `if`
  that fails when the command *succeeds* — a plain `set -e` block would abort on
  its first row and prove nothing about the rest — and each asserts its **check
  id**, not merely a non-zero exit.

Pinned toolchain: **kube-linter 0.7.2, kyverno 1.13.4, kubeconform 0.6.7,
yq 4.44.3** plus `jq`. `config-scan` is deliberately absent — it runs a
third-party `trivy-action` this step cannot execute, and whether to exercise it
is #1199's call.

```bash
set -euo pipefail   # so a failing subshell aborts the block rather than being discarded

# 1. clean variant — expected fully green
( cd tests/fixtures/kubernetes-repo
  set -euo pipefail
  rm -rf /tmp/rendered && mkdir -p /tmp/rendered
  helm template app charts/app            > /tmp/rendered/helm_charts_app.yaml
  kustomize build kustomize/overlays/prod > /tmp/rendered/kustomize_prod.yaml
  grep -q 'rendered-by-helm' /tmp/rendered/helm_charts_app.yaml || exit 1
  for m in argocd/*.yaml policies/kyverno/*.yaml; do
    cp "$m" "/tmp/rendered/plain_$(printf '%s' "$m" | tr / _)"
  done
  kube-linter lint /tmp/rendered/                                      # zero findings
  kubeconform -strict -summary -ignore-missing-schemas /tmp/rendered/  # 0 invalid
  kyverno test policies/kyverno/
  kyverno apply policies/kyverno/require-registry.yaml \
    --resource /tmp/rendered/ | tee /tmp/apply.txt                    # pass: 2, fail: 0
  grep -qE 'pass: [1-9]' /tmp/apply.txt || exit 1 )                   # not a zero-match green

# 2. broken variant — one attributable finding per file
( cd tests/fixtures/kubernetes-repo-broken
  set -euo pipefail
  # the THREE lint-owned rows. bad-registry's defect is the policy's to catch
  # (kube-linter reports nothing on it BY DESIGN), and the two broken/argocd/*.yaml
  # rows are checked by the yq+jq block below instead.
  # Each MUST fail — kube-linter exits non-zero on a finding. Use `if`, NOT a
  # bare `!`: a `!`-negated command is EXEMPT from errexit (#829), so `! cmd`
  # would silently pass even when the fixture stopped firing its check — an inert
  # assertion against exactly the regression it targets.
  if kube-linter lint broken/no-probe.yaml;   then echo 'FAIL: no-probe'; exit 1; fi
  if kube-linter lint broken/no-limits.yaml;  then echo 'FAIL: no-limits'; exit 1; fi
  if kube-linter lint broken/latest-tag.yaml; then echo 'FAIL: latest-tag'; exit 1; fi
  kube-linter lint broken/bad-registry.yaml   # exits 0: its defect is the policy's to catch
  kyverno test policies/kyverno/              # passes: the failure is EXPECTED
  if kyverno apply policies/kyverno/require-registry.yaml \
       --resource broken/bad-registry.yaml; then
    echo 'FAIL: the policy did not reject bad-registry.yaml'; exit 1
  fi )   # the README additionally asserts the check ids, `found 4 lint errors` and `fail: 1`

# 3. untested-policy variant — green, plus the untested-policy warning
( cd tests/fixtures/kubernetes-repo-untested-policy
  set -euo pipefail
  rm -rf /tmp/untested-rendered && mkdir -p /tmp/untested-rendered
  helm template app charts/app > /tmp/untested-rendered/helm_charts_app.yaml
  grep -q 'rendered-by-helm' /tmp/untested-rendered/helm_charts_app.yaml || exit 1
  kube-linter lint /tmp/untested-rendered/
  # tee to a FILE, never `| grep -q`: grep exits at the first match, the still
  # writing producer takes SIGPIPE, and pipefail turns a MATCH into a failure
  kyverno apply policies/kyverno/require-registry.yaml \
    --resource /tmp/untested-rendered/ | tee /tmp/untested-apply.txt   # pass: 1, fail: 0
  grep -qE 'pass: [1-9]' /tmp/untested-apply.txt || exit 1
  test ! -e policies/kyverno/kyverno-test.yaml )   # its ABSENCE is the fixture

# 4. the argocd filter — the one job using yq+jq rather than the tools above.
#    Each README's "Checking the argocd filter" section carries the JQ_EXPR.
#    clean  + REPO_SLUG=fixture-org/kubernetes-repo        -> exactly charts/app
#    broken + REPO_SLUG=fixture-org/kubernetes-repo-broken -> charts/does-not-exist
#                                                             AND charts/also-missing
```

Never lint a variant's tree directly: that reaches
`kustomize/base/deployment.yaml`, a deliberately partial kustomize *input* that
fires several checks by design. Validate rendered output, not inputs.

Then `yamllint --strict tests/fixtures/kubernetes-repo*` — it subsumes the parse
check and is what CI enforces. `tests/fixtures/` is excluded from the whitespace
and markdownlint hooks, **not** from yamllint.

- [x] **Step 7: Commit**

```bash
git add tests/fixtures/kubernetes-repo tests/fixtures/kubernetes-repo-broken \
        tests/fixtures/kubernetes-repo-untested-policy \
        docs/superpowers/plans/2026-08-02-development-kubernetes.md
# Task 7 has NO box: stage the fixture tree (plus this plan amendment) and
# nothing else. In particular do NOT bump any plugin version — fixtures under
# tests/ are not plugin content — and add no bats file, no tests/Dockerfile tool
# installs and no script-tests.yml wiring: executing the pipeline against these
# fixtures is #1199.
# `git status` must be clean afterwards
git commit -m "test(development-kubernetes): self-contained fixture repo

The motivating consumer is private and empty, so it cannot serve as a
reference project — and coupling this repository's public tests to
private content would be wrong regardless.

Each deliberate defect maps to exactly one expected finding, so a
regression is attributable.

Refs #1155"
```

---

## Self-Review

**Spec coverage.** §2 ownership boundary → Task 1. §3 mechanism/policy split, skip-not-fail, no
bundled policies, policy tests → Tasks 3, 4, 6. §4 pipeline → Task 6. §5 gather, dispatcher, agents,
coverage analogue → Tasks 2–5. §6 decomposition → task-to-child mapping throughout. The sixth child,
consumer adoption, is deliberately absent from this plan: it lives in a private repo and is tracked
there.

**Placeholder scan.** No TBD/TODO. Every code step carries the actual content.

**Type consistency.** `tooling_configured` keys `manifest_validation` / `policy` / `policy_tests`
are defined in Task 3 and consumed unchanged in Task 4. Agent names in Task 4's routing table match
the filenames in Task 5. The `policies/kyverno/` path is identical in Tasks 3, 4, 6 and 7.
