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
| `tests/fixtures/kubernetes-repo/` | Self-contained end-to-end fixture (chart + **kustomize overlay** + Argo CD + policies + broken/) |

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

- Produces: plugin name `development-kubernetes`, version `0.1.0`. Every later task references this name.

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
  "description": "Infrastructure-as-code topic plugin (foundation slice, #1151) for Kubernetes manifests, Helm charts, Kustomize overlays and Argo CD resources. Composes ALONGSIDE a language plugin, and can itself be PRIMARY for a repo with no application language (a GitOps repo). Charter — mechanism only: render and validate manifests, and run the repo's own Kyverno policies from policies/kyverno/**/*.{yaml,yml}, skipping when no policy file matches. Defers Dockerfiles and image builds to language plugins (language-first). Ships no approver agent — a cluster definition is approved by a human. This slice ships the ownership boundary and the marketplace registration ONLY; the topic marker, gather script and dispatcher (#1152), the five agents and review skill (#1153), and the bootstrap CI pipeline (#1154) land in later children of #1150.",
  "version": "0.1.0",
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
  "description": "Infrastructure-as-code topic plugin (foundation slice, #1151) for Kubernetes manifests, Helm charts, Kustomize overlays and Argo CD resources. Composes ALONGSIDE a language plugin, and can itself be PRIMARY for a repo with no application language (a GitOps repo). Charter — mechanism only: render and validate manifests, and run the repo's own Kyverno policies from policies/kyverno/**/*.{yaml,yml}, skipping when no policy file matches. Defers Dockerfiles and image builds to language plugins (language-first). Ships no approver agent — a cluster definition is approved by a human. This slice ships the ownership boundary and the marketplace registration ONLY; the topic marker, gather script and dispatcher (#1152), the five agents and review skill (#1153), and the bootstrap CI pipeline (#1154) land in later children of #1150.",
  "version": "0.1.0",
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
**fail** the step, or the mechanism would be decorative.

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
`policy` and `policy_tests`: a repo with no `policies/kyverno/` has not failed to
configure a tool, it has declined to declare opinions — which is the whole point
of mechanism-here-policy-in-the-consumer — so surfacing it would re-emit the
adopt-Kyverno recommendation the charter forbids. Every other `false` entry
populates `missing_tooling` normally.

A repo declaring `primary: kubernetes` in `.maintenance.yml` is entitled to
the full pipeline; the primary/auxiliary model already permits a topic to be
primary, so no new mechanism is needed. It arrives in two steps, and
conflating them over-promises the first: until `kubernetes` is in the
detected+supported set the orchestrator **treats the declaration as stale**
and dispatches every target as primary — that ends when the topic marker
and gather script land (#1152). The **gates themselves** arrive later still,
with the agents (#1153) and the check pipeline (#1154).

"Full pipeline" here means the **six checks** bootstrap's
`templates/iac/.github/workflows/kubernetes-ci.yml.tmpl` **will emit** (#1154) — render → schema →
lint → policy → config-scan → argocd. Note where they will live: the workflow
is a *bootstrap* template owned by the generic `development` plugin, not
something this plugin's skills run, which is the same boundary that keeps
detection in `development`. A manifests repo has no test suite, so the language-app
gates — the coverage floor above all — do not apply to it.
```

- [x] **Step 6: Commit**

Landed as `feat(development-kubernetes): plugin skeleton, marketplace entry, ARCHITECTURE section` (Closes #1151).

---

### Task 2: Register the `kubernetes` topic marker

> **Tasks 2-4 are child #1152 and land as ONE PR**; the boxed doc-flips in Tasks
> 3 and 4 are commits within it. Read as per-task PRs they would briefly leave
> the two registries disagreeing — the topic-row caveat retired while the
> dispatcher does not yet exist.

The orchestrator must detect the topic before any gather runs. Child #1152.

**Files:**

- Modify: `development/skills/maintenance/SKILL.md` (topic marker table, ~line 247)

**Interfaces:**

- Produces: topic name `kubernetes`, gather script name `gather-kubernetes-findings.zsh`. Task 3
  creates that script at exactly that path.
- [ ] **Step 1: Add the marker row**

Add to the "Known topics" table:

```markdown
| `kubernetes` | a Helm `Chart.yaml`, a `kustomization.yaml`, **or** a file containing `argoproj.io` — language-agnostic, so it composes with any language, or none | `gather-kubernetes-findings.zsh` |
```

- [ ] **Step 2: Add the detection recipe**

Add alongside the existing marker recipes. The marker is deliberately *not* "any YAML with
`apiVersion`", which would match half the repos in existence:

```bash
# kubernetes marker (file presence OR content; prune vendored trees).
# Capture before filtering: `find | grep -q` loses the match to SIGPIPE under
# `set -o pipefail`, which every maintenance script sets.
k8s_hits="$(find . \( -name Chart.yaml -o -name kustomization.yaml \
                       -o -name kustomization.yml -o -name Kustomization \) 2>/dev/null \
              | grep -v -e /node_modules/ -e '/\.git/' -e /vendor/ -e /templates/ || true)"
if [[ -n "$k8s_hits" ]] \
   || grep -rqlF 'argoproj.io' --include='*.yaml' --include='*.yml' \
        --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git . 2>/dev/null; then
  topics+=(kubernetes)
fi
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
> nothing will flag it. Stage both files.

- [ ] **Step 3: Commit**

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
- [ ] **Step 1: Write the failing tests**

Create `tests/gather-kubernetes.bats`:

```bash
#!/usr/bin/env bats
#
# Behavioral tests for gather-kubernetes-findings.zsh (epic #1150, child #1152).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-kubernetes-findings.zsh"
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W"
  (cd "$W" && git init -q)
}
chart() { mkdir -p "$W/charts/app"; printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"; }
policy() { mkdir -p "$W/policies/kyverno"; printf 'apiVersion: kyverno.io/v1\nkind: ClusterPolicy\nmetadata:\n  name: p\n' > "$W/policies/kyverno/p.yaml"; }
policy_test() { mkdir -p "$W/policies/kyverno"; printf 'name: p-test\npolicies:\n  - p.yaml\n' > "$W/policies/kyverno/kyverno-test.yaml"; }
gather() { zsh "$GATHER" "$W"; }

@test "a Helm chart alone: manifest_validation configured, policy NOT configured" {
  chart
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "true" ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "false" ]
}

@test "no policy directory: emits a skip note, and NO policy keys at all" {
  chart
  run gather
  [ "$status" -eq 0 ]
  # per the v2 contract an unconfigured tool is ABSENT from findings_by_tool —
  # asserted with has(), since `jq '.missing | length'` is also 0 and would pass
  # for an empty array, making "not configured" and "clean" indistinguishable
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy")')" = "false" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("policy_tests")')" = "false" ]
  echo "$output" | jq -r '.notes[]' | grep -q "no policies declared"
}

@test "policies without test fixtures: exactly one policy_tests finding" {
  chart; policy
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.policy')" = "true" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.policy_tests | length')" = "1" ]
}

@test "policies with test fixtures: no policy_tests finding" {
  chart; policy; policy_test
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.policy_tests | length')" = "0" ]
}

@test "coverage is null — a topic has no application test suite" {
  chart
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.coverage')" = "null" ]
}

@test "a repo with no kubernetes markers still emits a well-formed payload" {
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.manifest_validation')" = "false" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/gather-kubernetes.bats`
Expected: FAIL — the gather script does not exist.

- [ ] **Step 3: Write the gather script**

Create `development/skills/maintenance/scripts/gather-kubernetes-findings.zsh`:

```zsh
#!/usr/bin/env zsh
# gather-kubernetes-findings.zsh — the kubernetes topic's finding gatherer
# (epic #1150, child #1152). Emits the v2 gather payload the
# `development-kubernetes` dispatcher consumes.
#
# Tools:
#   manifest_validation — rendered-output checks (kubeconform, kube-linter).
#   policy              — the repo's OWN Kyverno policies at policies/kyverno/.
#                         Absent ⇒ tooling_configured.policy=false + a note.
#                         NEVER a finding: a public plugin must work in a repo
#                         with no opinions yet.
#   policy_tests        — this topic's coverage-gate analogue. A policy
#                         directory with no `kyverno test` fixtures passes
#                         everything silently, which is the failure mode
#                         hardest to notice.
#
# `coverage` is always null — a topic has no application test suite.
#
# Usage: gather-kubernetes-findings.zsh [<repo_path>]   (default: current dir)
# Output: JSON on stdout (always exit 0 on a well-formed run).

emulate -L zsh
set -euo pipefail

repo="${1:-.}"
[[ -d "$repo" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: not a directory: $repo"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -r -u2 -- "gather-kubernetes-findings.zsh: jq not found on PATH"; exit 3; }

typeset -a notes=()
# run find from INSIDE the repo so these substrings only ever test the
# repo-relative portion: an absolute $repo under ~/templates/ would otherwise
# filter every hit and report a chart-full repo as manifest-free. Dots escaped.
typeset prune='-e /node_modules/ -e /\.git/ -e /vendor/ -e /templates/'

# --- manifest_validation: is there anything to render? ------------------------
has_manifests=false
# Capture BEFORE filtering. `grep -q` exits at its first match; find, still
# writing, then dies of SIGPIPE (141), and under `set -o pipefail` the whole
# condition goes FALSE even though a chart WAS found — nondeterministically, on
# any repo whose find output outruns the pipe buffer.
# `cd` so the emitted paths are repo-RELATIVE: with an absolute "$repo" the
# prune substrings would also test the checkout's own prefix, and a repo living
# under ~/templates/ or a workspace named vendor would filter every hit and be
# reported manifest-free. All three marker filenames, per kustomize.
manifest_hits="$(cd "$repo" && find . \
                   \( -name Chart.yaml -o -name kustomization.yaml \
                      -o -name kustomization.yml -o -name Kustomization \) 2>/dev/null \
                   | grep -v ${=prune} || true)"
if [[ -n "$manifest_hits" ]]; then
  has_manifests=true
elif grep -rqlF 'argoproj.io' --include='*.yaml' --include='*.yml' \
       --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git "$repo" 2>/dev/null; then
  has_manifests=true
fi

# --- policy: the repo's own rules --------------------------------------------
typeset policy_dir="$repo/policies/kyverno"
typeset has_policies=false
typeset -a policy_files=()
if [[ -d "$policy_dir" ]]; then
  policy_files=(${(f)"$(find "$policy_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null)"})
  (( ${#policy_files} > 0 )) && has_policies=true
fi
$has_policies || notes+=("policy: no policies declared at policies/kyverno/ — step skipped, not failed")

# --- policy_tests: fixtures for those policies -------------------------------
typeset -a policy_test_findings=()
if $has_policies; then
  if ! find "$policy_dir" -type f \( -name 'kyverno-test.yaml' -o -name 'kyverno-test.yml' \) -print -quit 2>/dev/null | grep -q . 2>/dev/null; then
    policy_test_findings=('{"tool":"policy_tests","severity":"medium","file":"policies/kyverno/","message":"Policy directory has no kyverno test fixtures. An untested policy usually matches nothing and passes everything silently."}')
  fi
fi

# --- emit ---------------------------------------------------------------------
jq -n \
  --argjson manifests "$has_manifests" \
  --argjson policies "$has_policies" \
  --argjson policy_tests "[${(j:,:)policy_test_findings}]" \
  --argjson notes "$(printf '%s\n' ${notes:-} | jq -R . | jq -s 'map(select(length>0))')" \
  '{
     tooling_configured: {
       manifest_validation: $manifests,
       policy: $policies,
       policy_tests: $policies
     },
     # The v2 contract in ARCHITECTURE.md: findings_by_tool carries keys ONLY for
     # configured tools. Emitting an empty array for an unconfigured tool would
     # make "not configured" indistinguishable from "configured and clean", and
     # an orchestrator validating the envelope against the family contract would
     # reject the payload.
     findings_by_tool: (
       (if $manifests then { manifest_validation: [] } else {} end)
       + (if $policies then { policy: [], policy_tests: $policy_tests } else {} end)
     ),
     coverage: null,
     # ALWAYS carry the presence-detection note. The orchestrator reads an empty
     # topic plan with a NON-empty tooling_configured as "this topic is clean —
     # its tools ran and found nothing", which for this gather would be a lie:
     # nothing ran. The note is the only thing that reaches the Phase 9 summary
     # and can contradict that rendering.
     notes: ($notes + ["manifest_validation: presence-detected only — kubeconform/kube-linter/kyverno run in the CI pipeline (#1154), not in this gather"])
   }'
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/gather-kubernetes.bats`
Expected: PASS — all six tests.

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
> nothing will flag it. Stage both files.

- [ ] **Step 5: Make the script executable and commit**

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
- [ ] **Step 1: Write the dispatcher skill**

```markdown
---
name: maintenance
description: >
  Kubernetes/IaC maintenance dispatcher. Receives a v2 maintenance payload (a
  file path in $ARGUMENTS) that /development:maintenance built from the
  kubernetes topic gather (gather-kubernetes-findings.zsh), validates it, and
  returns a plan routing each finding group to an agent. A TOPIC plugin that can
  also be PRIMARY: a GitOps repo with no application language declares
  `primary: kubernetes` and gets the full pipeline. v1 REGISTERS the routing table
  (manifest_validation → kubernetes-manifest-fixer; policy + policy_tests →
  kubernetes-policy-triage) but ships NO agents, so every group returns as a
  human_action_required entry naming #1153, where those agents land.
  A single invocation returns the plan; the per-group work agents are the
  orchestrator's job. Pure function of its JSON input; runs no detection of its
  own. Ships NO approver — a cluster definition is approved by a human.
---

# Kubernetes maintenance dispatcher

Read the payload at `$ARGUMENTS`. Spawn nothing.

## Validation

Each check terminates — a dispatcher that routes whatever happens to parse is
worse than one that stops:

- `$ARGUMENTS` empty → print the invocation help and **stop**.
- the file is missing, or does not parse as JSON → **error and stop**.
- `.schema_version != "2"` → **error and stop**, naming the version found.
- `.language != "kubernetes"` → **error and stop**. (For a topic dispatch the
  orchestrator carries the TOPIC name in `language`; there is no `topic` key in
  the v2 payload, so a `.topic == "kubernetes"` guard would stop on every valid
  dispatch.)
- a key appears in `findings_by_tool` that the routing table below has no entry
  for → **halt** with `human_action_required`, rather than dropping it silently.

## Dispatch mode

`dispatch_mode` is `"primary"` | `"auxiliary"`; **absent is treated as
`"primary"`**, as every sibling dispatcher states. This topic composes ALONGSIDE a
language plugin, so **auxiliary is the common case** — any language repo that
also holds charts. The disposition of all three routed keys, so nothing falls
through to a guess:

- `manifest_validation` → routed as usual. Mechanical, always in scope.
- `policy` → routed as usual. A violation of a policy the repo *declared* is a
  real defect whatever the repo's primary language is; suppressing it would lose
  the finding with no trace.
- `policy_tests` → **omitted entirely** in auxiliary mode. This is the
  app-grade coverage analogue, and it is the only one that is. Planning ordering-blocking
fixture-writing on a repo whose primary is Java or Go is exactly the category
error the primary/auxiliary split exists to prevent.

## Response

Return the family's v2 envelope — every field, every time; the orchestrator's
per-group CI cycle branches on `ci_fixer_agent` and its summary renders
`missing_tooling`:

    {
      "schema_version": "2",
      "ci_fixer_agent": null,
      "plan": [],
      "missing_tooling": []
    }

"Every field, every time" scopes to the **non-halt** path. The halt branch in
*Validation* adds a fifth top-level field — but **keeps `plan` and
`missing_tooling`**. The orchestrator moves a topic whose response "is not a
JSON object carrying `plan`" to `unsupported_topics` with a
`dispatch failed` note, which would swallow the very escalation the halt exists
to deliver:

    {
      "schema_version": "2",
      "ci_fixer_agent": null,
      "plan": [],
      "missing_tooling": [],
      "human_action_required": [
        { "reason": "...", "recommendation": "..." }
      ]
    }

**`missing_tooling` — the positive rule.** The family default builds it from
`tooling_configured` entries that are `false`. This dispatcher takes ONE
deliberate exception: `policy` and `policy_tests`. A repo with no
`policies/kyverno/` has not failed to configure a tool — it has declined to
declare opinions, which is the charter's whole point, and listing it would
re-emit the adopt-Kyverno recommendation as a "here's how to add it". Every
other `false` entry (today: `manifest_validation`) populates `missing_tooling`
normally. This exception is **already recorded** in `ARCHITECTURE.md`'s
`### development-kubernetes owns` section — it shipped with #1151. Verify the
two still agree; do **not** add a second statement of it.

`ci_fixer_agent` is `null`: this topic ships no CI fixer, so on a red PR the
orchestrator **escalates to the user** in its summary. It does **not**
substitute another plugin's fixer — reusing one requires naming it, which is
exactly what `null` does not do (`development-docs` states the same rule;
`development-react` names `js-ci-fixer` because it genuinely reuses it). The gather's "no policies declared" skip
note surfaces **nowhere** in the response — it is a deliberate skip, not missing
tooling, so putting it in `missing_tooling` would turn it into exactly the
adopt-Kyverno recommendation the charter forbids.

## Routing

**Until #1153 lands, this table routes nothing.** The agents below are created
by #1153; #1152 ships the dispatcher alone. A `policy_tests` finding is
reachable the moment the gather exists, so routing it now would have the
orchestrator spawn a `subagent_type` with no definition and the group would
fail. Until the agent files exist, return every group as a
`human_action_required` entry naming #1153. Borrow the **mechanism** the
language dispatchers use — escalate via `human_action_required` rather than
`development-react`'s empty-plan-plus-`missing_tooling` summary, because an
unroutable group must **halt**, and because this dispatcher forbids
`missing_tooling` for the policy skip. Borrow only the mechanism: `development-java`'s
and `development-go`'s halt objects both omit `plan` (and Java's additionally
omits `ci_fixer_agent`), which the *Response* section above forbids here — keep
both fields, per that section. Delete this paragraph in #1153.

| Finding tool | Agent |
|---|---|
| `manifest_validation` | `kubernetes-manifest-fixer` |
| `policy` | `kubernetes-policy-triage` |
| `policy_tests` | `kubernetes-policy-triage` |

Group `policy` and `policy_tests` into **one** PR: they touch the same
directory, and splitting them would produce two PRs racing on the same files.

## No coverage gate, one analogue

A topic has no application test suite, so there is no line-coverage
pre-flight. The analogue is `policy_tests`: a policy directory with no
`kyverno test` fixtures. Treat a `policy_tests` finding as **ordering-blocking**
for the group — the group is still dispatched (`kubernetes-policy-triage` is what
WRITES the missing fixtures), but the plan must order fixture-writing before any
policy-driven manifest fix in it. Never drop the group: that would permanently
preserve the untested-policy state the gate exists to eliminate. This rule is
**primary-mode only** — in auxiliary mode the `policy_tests` group is omitted
before it is ever formed (see *Dispatch mode*).

## Absent policies are not a finding

`tooling_configured.policy: false` means the repo declared no policies. Return
a plan with no policy group. The gather's "no policies declared" note stays in
the gather payload and is reproduced **nowhere** in the response — not in
`missing_tooling`, not in the plan (see *Response* above; `missing_tooling`
would turn a deliberate skip into an adopt-Kyverno recommendation). Do not
synthesise a finding, and do not suggest the repo adopt policies — that is the
consumer's decision, not this plugin's.
```

- [ ] **Step 2: Verify the frontmatter parses**

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

- [ ] **Step 3: Commit**

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

- [ ] **Step 1: Create the security reviewer**

```markdown
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

## What NOT to report

Generic hygiene `kube-linter` already covers — missing probes, absent
resource limits, `latest` tags. Reporting them duplicates the pipeline and
trains the reader to skim your findings.

## Reporting Format

Report each finding in this shape — the review skill's injected prompt extracts
the severity tag from it, so the tag must be present and spelled exactly:

### [CRITICAL|WARNING|SUGGESTION] <one-line title>

**File:** <path>:<line>
**Description:** what is wrong, and what it costs when it happens.
**Suggested fix:** the concrete remediation.

**Severity guide** — bounded so the review loop converges rather than drowning
in nitpicks:

- **CRITICAL** — the rendered manifest takes the platform or a serving path
  down, or grants cluster-wide privilege.
- **WARNING** — a real defect with a bounded blast radius: one workload
  degraded, one namespace exposed, one app unsyncable.
- **SUGGESTION** — hygiene and clarity. Never blocks a round.

```

- [ ] **Step 2: Create the reliability reviewer**

```markdown
---
name: kubernetes-reliability-reviewer
description: Kubernetes reliability specialist reviewing rendered manifests for the failure modes that surface as outages rather than errors — MISCONFIGURED probes (an aggressive liveness probe that restart-loops a slow-starting pod), requests/limits that throttle or OOM-kill, no PodDisruptionBudget, single replicas for stateful paths, missing anti-affinity, and rollout strategies that drop capacity. Bare presence/absence checks (a probe missing entirely, no limits set, a latest tag) belong to kube-linter and are deliberately NOT reported here. The reliability dimension of /development-kubernetes:review.
model: opus
tools: Read, Grep, Glob
---

You are this plugin's analogue of a bug hunter, named for what you actually
hunt. A missing probe is not a crash — it is an outage at 3am under load, and
an agent looking for bugs would look for the wrong thing.

## What to look for

> **What NOT to report**, same carve-out as the security reviewer: the bare
> presence/absence checks `kube-linter` already performs — a missing probe, a
> missing `requests`/`limits`, a `latest` tag. Report the JUDGEMENT cases below,
> where a probe or a limit exists but is wrong. Two tools enforcing one rule
> means two places to silence one false positive.

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
- **Placement** — in scope for the same reason (no `kube-linter` default check):
  a single replica on a serving path; no anti-affinity, so
  every replica lands on one node.
- **Rollout** — `maxUnavailable` that drops below quorum for a stateful set,
  or `Recreate` on a service expected to stay up.

## Judgement

A single replica in a demonstration overlay is fine; a single replica in a
production overlay is a finding. Read the overlay before reporting.

## Reporting Format

Report each finding in this shape — the review skill's injected prompt extracts
the severity tag from it, so the tag must be present and spelled exactly:

### [CRITICAL|WARNING|SUGGESTION] <one-line title>

**File:** <path>:<line>
**Description:** what is wrong, and what it costs when it happens.
**Suggested fix:** the concrete remediation.

**Severity guide** — bounded so the review loop converges rather than drowning
in nitpicks:

- **CRITICAL** — the rendered manifest takes the platform or a serving path
  down, or grants cluster-wide privilege.
- **WARNING** — a real defect with a bounded blast radius: one workload
  degraded, one namespace exposed, one app unsyncable.
- **SUGGESTION** — hygiene and clarity. Never blocks a round.

```

- [ ] **Step 3: Create the Argo CD advisor**

```markdown
---
name: argocd-advisor
description: Argo CD specialist reviewing Application, ApplicationSet and AppProject resources — app-of-apps structure, sync policy (automated, prune, selfHeal), AppProject restrictions on sources and destinations, sync waves and ordering, and drift between what an app declares and what exists. The argocd dimension of /development-kubernetes:review.
model: opus
tools: Read, Grep, Glob
---

You review Argo CD resources — the layer that decides what actually reaches a
cluster, and therefore where a mistake has the widest blast radius.

## What to look for

- **App-of-apps integrity** — a parent referencing a child path that does not
  exist. This fails silently at sync time, not at review time.
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

### [CRITICAL|WARNING|SUGGESTION] <one-line title>

**File:** <path>:<line>
**Description:** what is wrong, and what it costs when it happens.
**Suggested fix:** the concrete remediation.

**Severity guide** — bounded so the review loop converges rather than drowning
in nitpicks:

- **CRITICAL** — the rendered manifest takes the platform or a serving path
  down, or grants cluster-wide privilege.
- **WARNING** — a real defect with a bounded blast radius: one workload
  degraded, one namespace exposed, one app unsyncable.
- **SUGGESTION** — hygiene and clarity. Never blocks a round.

```

- [ ] **Step 4: Create the manifest fixer**

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

## Verify

Re-run the failing check after each fix. A fix that silences a checker without
being verified is indistinguishable from suppressing it.
```

- [ ] **Step 5: Create the policy triage agent**

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

## 3. The policy has no tests

A `policy_tests` finding. Write `kyverno test` fixtures asserting both a
passing and a failing case. This is not busywork: an untested policy usually
matches nothing, so it passes everything and looks like it is working.

## Never

Do not add policies. This plugin ships none, and generic hygiene belongs to
`kube-linter`.
```

- [ ] **Step 6: Create the review skill**

```markdown
---
name: review
description: Perform a comprehensive Kubernetes/IaC review using three specialized parallel agents — security, reliability, and Argo CD. Reviews rendered manifests, not templates.
---

# Kubernetes review

Dispatch three agents in parallel over the changed manifests:

| Dimension | Agent |
|---|---|
| security | `kubernetes-security-reviewer` |
| reliability | `kubernetes-reliability-reviewer` |
| argocd | `argocd-advisor` |

**Render first.** Run `helm template` and `kustomize build` into a temp tree,
then **copy standalone manifests in alongside them** — same exclusions as the CI
render job (chart-owned trees, kustomize inputs). Without that copy the scope is
chart and overlay output only, so a repo whose Argo CD resources are plain YAML
— the common GitOps layout, and this plugin's own fixture — points
`argocd-advisor` at a tree containing no `Application` document. It emits `[]`
deterministically and the round records a clean review of resources no agent
read. A repo with no charts at all would review an empty tree and report clean.

Point the agents at that tree. A chart that reads safely can render a privileged
container, and the rendered form is what reaches a cluster.

**Skip what the CI render job skips** before rendering — `type: library`
charts, vendored subcharts (a `charts/` parent that is itself a chart),
`kind: Component` kustomizations, **and any kustomization root another root's
`resources:` consumes** — build only unconsumed roots, exactly as the CI job's
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

**Scope.** `$ARGUMENTS` names the review scope; with no argument, review every
file the render step produced. Note the mapping: reviewers read *rendered*
output, but "changed" is a property of the *source* — one edited `values.yaml`
can change many rendered documents, so scope by the rendered files a changed
source produces, never by source paths alone.

For each agent, use its name as the `subagent_type` and pass the prompt below,
substituting **all four** placeholders: `{SCOPE}` (the scope above),
`{DIMENSION}` and `{AGENT NAME}` from the table, and `{ROUND}` (the review
round; `1` for a standalone run). Leaving `{AGENT NAME}` unbound corrupts the
`reviewer` field the consolidator keys on. This is where the machine-readable JSON layer is
wired in once, for every agent, so the reviewer definitions stay pure prose:

    Review scope: {SCOPE}

    Analyze the rendered manifests in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

    Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.

Without this block the panel's findings cannot be consumed by
`consolidate-findings.zsh` or the resolve-issue review loop — ARCHITECTURE.md
makes injecting it the *review skill's* job precisely so no reviewer definition
has to carry the boilerplate.

There is no approver dimension. A human approves infrastructure.

## Step 2 — collect

Wait for all three agents. **An agent that fails is not an agent that found
nothing.** If one errors, or returns no fenced `json` block, re-launch it once;
if it fails again, report the round as **failed** and name the dimension.

**Do not write the findings path.** It is array-only by contract, and all three
consumers enforce that (`resolve-story-loop.zsh`, `consolidate-findings.zsh`,
`review-dispatch.zsh` each exit 1 on a non-array), so a `{"round_failed": …}`
object there would surface as "malformed input file" and bury the very
dimension the signal names. This is the rule `development-go`'s panel states,
and this panel follows it. Write the durable detail to a **sibling** path —
`<findings-path>.failed.json` — where nothing parses it as findings. A missing
dimension silently waived is a blocker shipped, so the failure must be reported
to the caller, not inferred from an absent file.

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
modes that surface as outages. Because this topic composes alongside a language
plugin, one review round can emit both, and two near-homonyms in one dossier
invite a reader to treat them as duplicates. State the split explicitly when
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

- [ ] **Step 7: Verify all agent frontmatter parses**

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
> 5. **delete the "Until #1153 lands, this table routes nothing" paragraph** from
>    `development-kubernetes/skills/maintenance/SKILL.md` (that paragraph says
>    so itself) and flip its frontmatter description back to the present-tense
>    routing sentence — otherwise post-#1153 runs keep halting every group with
>    a `human_action_required` naming a closed issue;
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
> `docs/reference/`, `ARCHITECTURE.md`, `README.md`,
> `docs/explanation/motivation.md`,
> `docs/superpowers/plans/2026-08-02-development-kubernetes.md` (re-sync Task 1's
> blocks), `development-kubernetes/skills/maintenance/SKILL.md`,
> `development/skills/resolve-issue/scripts/review-dispatch.zsh`,
> `development/skills/bootstrap/scripts/detect-stack.sh` (item 4's topic key),
> and both manifests.

- [ ] **Step 8: Commit**

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

**Interfaces:**

- Consumes: the `policies/kyverno/` convention from Task 3.
- Produces: six named checks — `render`, `schema`, `lint`, `policy`, `config-scan`, `argocd`.

- [ ] **Step 1: Create the workflow template**

Every `uses:` is pinned to a full commit SHA with a `# <tag>` comment, per
MAINTAINING.md Step 2: the semgrep gate bootstrap itself installs **blocks
mutable tags in downstream repos**, so a template floating on `@v4` would ship
consumers a workflow their own quality gate flags. The path matters too — a
`.tmpl` under a `.github/workflows/` segment is the only shape both Renovate
managers see, so these pins stay refreshable. The SHAs below are the ones this
repo already pins elsewhere; re-resolve them if a newer digest has landed.

```yaml
name: kubernetes-ci
on:
  pull_request:
permissions:
  contents: read
env:
  # one non-hidden work directory. A DOT-prefixed path (`.rendered`) is fatal
  # here: actions/upload-artifact@v4 excludes hidden files and folders by
  # default (>= v4.4), so a hidden tree uploads NOTHING and every downstream
  # job dies at download — or, worse, uploads partially and the checks go green
  # having validated nothing.
  RENDER_DIR: rendered-out
jobs:
  render:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6
      - name: helm template every top-level chart
        run: |
          set -euo pipefail
          mkdir -p "$RENDER_DIR"
          find . -name Chart.yaml -not -path './.git/*' | while read -r c; do
            d="$(dirname "$c")"
            # Skip a VENDORED subchart — one whose charts/ parent is itself a
            # chart. A blanket `-not -path '*/charts/*'` would also skip a
            # TOP-LEVEL charts/ collection, which is the most common GitOps
            # layout: helm would render nothing and every check would pass green
            # with the charts entirely unvalidated.
            owner="${d%/charts/*}"
            if [ "$owner" != "$d" ] && [ -f "$owner/Chart.yaml" ]; then
              continue
            fi
            # a library chart is a render-time INPUT to other charts, not
            # renderable output — `helm template` refuses it outright ("library
            # charts are not installable"), so a repo with a shared charts/common
            # would red the render job, and every other job needs: render
            grep -q '^type:[[:space:]]*library' "$c" && continue
            rel="${d#./}"; rel="${rel:-root}"
            # release name AND filename derive from the full path: basename alone
            # makes `helm template . .` (invalid release name) for a root chart,
            # and silently overwrites when two charts share a leaf directory name.
            # `_` is escaped to `__` first so services/a_b and services/a/b cannot
            # collapse onto the same filename.
            slug="$(printf '%s' "$rel" | sed 's/_/__/g' | tr / _)"
            name="$(printf '%s' "$rel" | tr 'A-Z' 'a-z' | tr '/_' '--' \
                      | tr -cd 'a-z0-9-' | cut -c1-53)"
            # strip ALL leading/trailing dashes — a `--` run survives a single
            # ${name#-}, and a leading or trailing dash is an invalid release name
            name="$(printf '%s' "$name" | sed 's/^-*//; s/-*$//')"
            # a chart declaring dependencies: fails to render without them
            # tolerate the status (dependency-free charts), but let stderr reach
            # the log: otherwise the later `helm template` failure is undiagnosable
            helm dependency build "$d" >/dev/null || true
            helm template "${name:-root}" "$d" > "$RENDER_DIR/helm_$slug.yaml"
          done
      - name: kustomize build every overlay
        run: |
          set -euo pipefail
          # all THREE marker filenames kustomize accepts — finding only
          # kustomization.yaml leaves the others silently unrendered, and a
          # kustomization.yml would then be scooped up as a "standalone manifest"
          # and fed to kubeconform as if it were output rather than input
          : > "$RUNNER_TEMP/kustomize-roots.txt"
          : > "$RUNNER_TEMP/kustomize-buildable.txt"
          find . \( -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) \
            -not -path './.git/*' | while read -r k; do
              d="$(dirname "$k")"
              # RECORD FIRST, then decide whether to build. A Component is
              # correctly not built standalone (kustomize rejects it), but its
              # directory still holds kustomize INPUTS — partial patches — so it
              # must be excluded from the plain-manifest sweep below or those
              # fragments get validated unrendered.
              printf '%s\n' "$d" >> "$RUNNER_TEMP/kustomize-roots.txt"
              grep -q '^kind:[[:space:]]*Component' "$k" && continue
              printf '%s\n' "$d" >> "$RUNNER_TEMP/kustomize-buildable.txt"
            done
          # SECOND pass: build only roots that no OTHER root consumes. A base is
          # `kind: Kustomization` too, so building every root would render the
          # base standalone — and a base is deliberately partial (the overlay
          # supplies image, resources, securityContext), so its output would red
          # kube-linter on manifests that are kustomize INPUTS. That is the same
          # "rendered output, not templates" violation the plain-manifest sweep
          # excludes bases for; the roots file keeps them excluded there, and
          # this pass keeps them from being built here.
          while read -r d; do
            consumed=""
            while read -r other; do
              [ "$other" = "$d" ] && continue
              # does another root reference this one? compare resolved paths, so
              # ../../base from an overlay matches the base's own entry
              # strip the leading dash AND any surrounding quotes: `- "../../base"`
              # is ordinary YAML house style (yamllint's quoted-strings: required
              # mandates it), and an unstripped quote makes the cd fail, so the
              # base would be treated as unconsumed and built standalone — the
              # exact failure this pass exists to prevent
              for ref in $(grep -hE '^[[:space:]]*-[[:space:]]' \
                             "$other"/kustomization.y*ml "$other"/Kustomization 2>/dev/null \
                             | sed -e 's/^[[:space:]]*-[[:space:]]*//' \
                                   -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"); do
                case "$ref" in /*|http*|'') continue ;; esac
                if [ "$(cd "$other" && cd "$ref" 2>/dev/null && pwd)" = "$(cd "$d" && pwd)" ]; then
                  consumed=1; break
                fi
              done
              [ -n "$consumed" ] && break
            done < "$RUNNER_TEMP/kustomize-buildable.txt"
            [ -n "$consumed" ] && continue
            rel="${d#./}"; rel="${rel:-root}"
            slug="$(printf '%s' "$rel" | sed 's/_/__/g' | tr / _)"
            kustomize build "$d" > "$RENDER_DIR/kustomize_$slug.yaml"
          done < "$RUNNER_TEMP/kustomize-buildable.txt"
      # A repo may legitimately hold Argo CD manifests and NO chart/overlay —
      # the topic marker fires on an argoproj.io reference alone. Without this
      # the render job would upload nothing and every downstream job would die
      # at download-artifact, so bootstrap would ship CI red on every PR.
      #
      # Chart-owned trees are EXCLUDED: templates/*.yaml are Go templates, not
      # YAML, and Chart.yaml/values.yaml are chart metadata. Copying them would
      # feed raw templates to kubeconform/kube-linter and red every real chart
      # repo — the opposite of "validate rendered output, not templates".
      - name: copy standalone manifests so there is always something to validate
        run: |
          set -euo pipefail
          # `|| true`: find propagates a non-zero status from an -exec ... {} +
          # batch, and grep -l exits 1 when nothing in the batch matches — which
          # is the legitimate "no standalone manifests" case, not an error
          { find . \( -name '*.yaml' -o -name '*.yml' \) \
              -not -path './.git/*' -not -path "./$RENDER_DIR/*" \
              -not -path '*/templates/*' -not -name 'Chart.yaml' -not -name 'values.yaml' \
              -not -name 'kustomization.yaml' -not -name 'kustomization.yml' -not -name 'Kustomization' \
              -exec grep -lE '^kind:' {} + 2>/dev/null || true; } \
            | while read -r m; do
                # skip kustomize INPUTS: a base or patch fragment is deliberately
                # partial (the overlay supplies image, resources, securityContext),
                # so validating it unrendered reds a valid repo — the opposite of
                # this step's own "rendered output, not templates" charter
                skip=""
                while read -r root; do
                  case "$m" in "$root"/*) skip=1; break ;; esac
                done < "$RUNNER_TEMP/kustomize-roots.txt"
                [ -n "$skip" ] && continue
                cp "$m" "$RENDER_DIR/plain_$(printf '%s' "${m#./}" | sed 's/_/__/g' | tr / _)"
              done
          # never upload an empty artifact — downstream jobs must have an input.
          # NON-hidden, or upload-artifact drops it and we are back to the
          # if-no-files-found: error failure this guard exists to prevent. And a
          # VALID object, not a comment: `kube-linter lint` errors with "no valid
          # objects found" on a tree containing none, so a comment-only sentinel
          # would red the lint check in exactly the corner it exists to keep green.
          if [ -z "$(ls -A "$RENDER_DIR")" ]; then
            # printf, not an indented heredoc: inside a YAML block scalar the
            # terminator would carry the block's indentation and never match
            printf '%s\n' \
              'apiVersion: v1' \
              'kind: ConfigMap' \
              'metadata:' \
              '  name: render-sentinel' \
              'data:' \
              '  note: "nothing to render - placeholder so downstream checks have a valid input"' \
              > "$RENDER_DIR/EMPTY.yaml"
          fi
      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: rendered
          path: ${{ env.RENDER_DIR }}
          if-no-files-found: error

  schema:
    needs: render
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8
        with:
          name: rendered
          path: ${{ env.RENDER_DIR }}
      # ubuntu-latest ships helm and kustomize but NONE of kubeconform,
      # kube-linter, kyverno or yq — without an install step the job exits 127
      # and the check can never go green, so it can never become required
      - name: install kubeconform
        run: |
          set -euo pipefail
          url="https://github.com/yannh/kubeconform/releases/download"
          curl -sSfL "$url/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
            | tar -xz -C /usr/local/bin kubeconform
        env:
          KUBECONFORM_VERSION: 0.6.7
      - run: kubeconform -strict -summary -ignore-missing-schemas "$RENDER_DIR/"

  lint:
    needs: render
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8
        with:
          name: rendered
          path: ${{ env.RENDER_DIR }}
      - name: install kube-linter
        run: |
          set -euo pipefail
          url="https://github.com/stackrox/kube-linter/releases/download"
          curl -sSfL "$url/v${KUBE_LINTER_VERSION}/kube-linter-linux.tar.gz" \
            | tar -xz -C /usr/local/bin kube-linter
        env:
          KUBE_LINTER_VERSION: 0.7.2
      - run: kube-linter lint "$RENDER_DIR/"

  policy:
    needs: render
    runs-on: ubuntu-latest
    timeout-minutes: 10
    # JOB-level, not step-level: the apply/test step names the version too, and a
    # step-level env would leave it unset there — fatal under `set -u`
    env:
      KYVERNO_VERSION: 1.13.4
    steps:
      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6
      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8
        with:
          name: rendered
          path: ${{ env.RENDER_DIR }}
      - name: install kyverno CLI
        run: |
          set -euo pipefail
          url="https://github.com/kyverno/kyverno/releases/download/v${KYVERNO_VERSION}"
          curl -sSfL "$url/kyverno-cli_v${KYVERNO_VERSION}_linux_x86_64.tar.gz" \
            | tar -xz -C /usr/local/bin kyverno
      - name: kyverno apply + test
        run: |
          set -euo pipefail
          # gate on a MATCHING FILE, not on the directory: an empty or
          # .json-only policies/kyverno/ must skip exactly like an absent one,
          # and a .yml-only repo must be ENFORCED, not silently ignored.
          # `-print -quit` rather than `| head -n1`: head closes the pipe, find
          # dies of SIGPIPE, and pipefail then fails the assignment.
          # `|| true` is load-bearing: when policies/kyverno does not exist at
          # all — the DEFAULT state this whole design centres on — find exits 1,
          # the assignment inherits that status, and errexit would kill the step
          # before the skip branch below could run. The never-fail guarantee has
          # to survive its own most common case.
          policies="$(find policies/kyverno -type f \( -name '*.yaml' -o -name '*.yml' \) \
                        -print -quit 2>/dev/null || true)"
          if [ -z "$policies" ]; then
            echo "::notice::no policies declared at policies/kyverno/**/*.{yaml,yml} — policy step skipped"
            exit 0
          fi
          # kyverno test fixtures live in the SAME directory by convention, and
          # `kyverno apply` errors when handed a non-policy document — so select
          # the policy documents explicitly rather than passing the directory
          mkdir -p "$RUNNER_TEMP/policies"
          # `|| true` for the same reason as the render step: grep -l exits 1
          # when no file in the batch matches and find propagates it
          { find policies/kyverno -type f \( -name '*.yaml' -o -name '*.yml' \) \
              -exec grep -lE '^kind:[[:space:]]*(Cluster)?Policy[[:space:]]*$' {} + 2>/dev/null || true; } \
            | while read -r pol; do
                cp "$pol" "$RUNNER_TEMP/policies/$(printf '%s' "$pol" | sed 's/_/__/g' | tr / _)"
              done
          if [ -z "$(ls -A "$RUNNER_TEMP/policies")" ]; then
            # YAML present but no policy documents (e.g. only fixtures survive a
            # deletion). `kyverno apply` on an empty directory errors, so report
            # and skip rather than red.
            # WARNING, not notice: YAML is present but nothing matched the kinds
            # the pinned CLI can evaluate. Kyverno 1.14 added ValidatingPolicy /
            # ImageValidatingPolicy / CleanupPolicy, which 1.13.4 cannot run — a
            # repo using only those would otherwise get a green check with its
            # declared policies entirely unenforced.
            echo "::warning::policies/kyverno holds YAML but no Policy/ClusterPolicy" \
                 "document the pinned kyverno CLI can evaluate — policy step skipped"
            exit 0
          fi
          kyverno apply "$RUNNER_TEMP/policies/" --resource "$RENDER_DIR/"
          # A policy set with no fixtures is a MEDIUM MAINTENANCE FINDING
          # (policy_tests -> kubernetes-policy-triage), not a build failure — the
          # six-check design names no policy-tests check. Running `kyverno test`
          # unconditionally would exit non-zero here and make that a hard red.
          # EXACTLY the names `kyverno test <dir>` discovers — a broader glob
          # (kyverno-test-registry.yaml) would pass this gate while the CLI finds
          # nothing and errors, and the gather would simultaneously report
          # fixtures present so no policy_tests finding is ever filed
          if find policies/kyverno -type f \( -name 'kyverno-test.yaml' -o -name 'kyverno-test.yml' \) \
               -print -quit 2>/dev/null | grep -q .; then
            kyverno test policies/kyverno/
          else
            echo "::warning::policies declared but no kyverno test fixtures — maintenance reports this as policy_tests"
          fi

  config-scan:
    needs: render
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8
        with:
          name: rendered
          path: ${{ env.RENDER_DIR }}
      - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          scan-type: config
          scan-ref: ${{ env.RENDER_DIR }}/
          exit-code: '1'
          # threshold, or the check reds on a fresh repo's FIRST PR: trivy's
          # default k8s checks fire LOW/MEDIUM on essentially every Deployment
          # (seccompProfile, drop-capabilities, readOnlyRootFilesystem) — the
          # plan's own "clean" fixture chart included. Start requirable, tighten
          # deliberately; a repo that wants the lower bands owns a .trivyignore
          # exactly as it owns policies/kyverno/.
          severity: HIGH,CRITICAL

  argocd:
    needs: render
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6
      # the rendered tree too: a very common app-of-apps authors its Application
      # documents AS a Helm chart (argo-apps/templates/*.yaml). Those are Go
      # templates in the source tree — correctly pruned below — so scanning only
      # the checkout would extract zero paths and exit 0, a green check that
      # verified nothing on exactly the repos with the most paths to verify.
      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8
        with:
          name: rendered
          path: ${{ env.RENDER_DIR }}
      - name: install yq
        run: |
          set -euo pipefail
          curl -sSfLo /usr/local/bin/yq \
            "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64"
          chmod +x /usr/local/bin/yq
        env:
          YQ_VERSION: 4.44.3
      - name: every app path this repo owns exists
        run: |
          set -euo pipefail
          # Read .spec.source.path from Argo CD Application/ApplicationSet docs
          # ONLY. A bare `grep 'path:'` matches every path: key in the repo — a
          # readinessProbe's `path: /healthz` included.
          #
          # Per-file yq, not one batched invocation: yq ABORTS on the first
          # unparseable document, and Helm templates/*.yaml are Go templates, so
          # a single batch would silently truncate the path list and the check
          # would pass having extracted nothing. Templates are pruned as well.
          # A parse failure is reported per file via ::warning below; yq's own
          # stderr is deliberately suppressed there to keep the log readable
          # (the PROBE, by contrast, lets it through — that is the one place a
          # diagnostic is worth the noise, because it fails the whole step).
          paths_file="$RUNNER_TEMP/argocd-paths.txt"
          : > "$paths_file"

          # ONE definition of the expression, shared by the probe and the loop —
          # a probe that tested a different string would prove nothing.
          #
          # Evaluated with JQ over `yq -o=json`, not by yq directly: this is jq
          # dialect. mikefarah yq implements neither `ascii_downcase` (its
          # operator is `downcase`), nor `endswith`, and its `sub` takes
          # comma-separated arguments — so handing this to `yq -N -r` would fail
          # to parse for EVERY file. ubuntu-latest ships jq, and multi-document
          # YAML converts to a JSON stream jq consumes natively. Note jq's env
          # accessor is `env.VAR` — `strenv()` is itself one of the yq-isms this
          # comment warns about, and would fail to compile here.
          JQ_EXPR='
            select(type == "object")
            | select(.apiVersion == "argoproj.io/v1alpha1")
            | select(.kind == "Application" or .kind == "ApplicationSet")
            | [ .spec.source, .spec.template.spec.source,
                (.spec.sources // [])[], (.spec.template.spec.sources // [])[] ]
            | .[]
            | select(. != null)
            | select(
                ((.repoURL // "") | sub("\\.git$"; "") | sub("/$"; "") | ascii_downcase) as $u
                | (env.REPO_SLUG | ascii_downcase) as $s
                | ($u | endswith("/" + $s)) or ($u | endswith(":" + $s)))
            | (.path // empty)'
          # BOTH source shapes above: Argo CD >= 2.6 multi-source Applications
          # carry .spec.sources, and reading only the singular form extracts zero
          # paths from them, so the check would pass vacuously on exactly the
          # repos it should scrutinise. The repoURL filter is anchored on the
          # PATH BOUNDARY with literal operators: test() would treat a "." in the
          # repo name as match-any, and contains() would match the sibling repo
          # `acme/k8s-apps` for slug `acme/k8s`, whose paths are correctly absent
          # locally. Case folded, since GitHub slugs are case-insensitive.

          # Probe the EXPRESSION against a known-good document first. yq exits
          # non-zero both for "this file will not parse" and "this expression
          # will not compile", and the per-file `|| echo` below cannot tell them
          # apart — so a expression the pinned yq rejects would warn on every
          # file, extract nothing, and exit 0: a required check permanently green
          # while validating nothing. Fail loudly here instead.
          printf '%s\n' \
            'apiVersion: argoproj.io/v1alpha1' \
            'kind: Application' \
            'spec:' \
            '  source:' \
            "    repoURL: https://github.com/$REPO_SLUG.git" \
            '    path: .' > "$RUNNER_TEMP/probe.yaml"
          if [ "$(yq -o=json '.' "$RUNNER_TEMP/probe.yaml" | jq -r "$JQ_EXPR")" != "." ]; then
            echo "::error::the Argo CD path expression does not compile or match — refusing to report a vacuous pass"
            exit 1
          fi
          while read -r f; do
            yq -o=json '.' "$f" 2>/dev/null | jq -r "$JQ_EXPR" >> "$paths_file" \
              || echo "::warning::could not parse $f as YAML — skipped"
          done < <(find . "$RENDER_DIR" \( -name '*.yaml' -o -name '*.yml' \) \
                     -not -path './.git/*' -not -path '*/templates/*' 2>/dev/null | sort -u)

          # report inline rather than accumulating into a word-split string: a
          # path containing a space or a glob character would otherwise be
          # re-split or expanded in the reporting loop
          fail=0
          while read -r p; do
            [ -n "$p" ] || continue
            # an ApplicationSet generator templates its path ('{{path}}'), which
            # cannot exist on disk and is not statically verifiable
            case "$p" in *'{{'*) echo "::notice::templated path not statically checkable: $p"; continue ;; esac
            [ -e "$p" ] || { echo "::error::app-of-apps references missing path: $p"; fail=1; }
          done < <(sort -u "$paths_file")
          exit "$fail"
        env:
          REPO_SLUG: ${{ github.repository }}
```

- [ ] **Step 2: Teach bootstrap to emit it**

Add to `development/skills/bootstrap/SKILL.md`:

```markdown
### Infrastructure-as-code repos (no application language)

When detection finds the `kubernetes` topic and **no** language, the repo is
a GitOps/IaC repo. Emit `templates/iac/.github/workflows/kubernetes-ci.yml.tmpl` as
`.github/workflows/kubernetes-ci.yml` and write `primary: kubernetes` into
`.maintenance.yml`.

Do **not** require an application language before bootstrapping. A repo of
charts and manifests has plenty to validate — rendering always produces
something to check, which is why this works before the first service exists.

When a language **is** also detected, bootstrap that language normally and do
not emit this template or write `primary: kubernetes` — a mixed repo is a later
slice, and the language's own CI already gates its build. This slice covers the
no-language case only.

Do not create `policies/kyverno/`. Policies are the consumer's; the workflow
skips cleanly when no `policies/kyverno/**/*.{yaml,yml}` file matches — the
glob is the contract, not the directory's existence.
```

- [ ] **Step 3: Verify the workflow is valid YAML**

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
> paragraph to the present tense here, and **bump both manifests in lockstep**
> (minor) with the slice-status sentence updated. Also bump
> `docs/reference/plugins.md`'s `**What's built (vX):**` label and rewrite its
> narrative — it still says "the ownership boundary and the marketplace
> registration, and nothing else", which the CI pipeline falsifies. `git add`
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
> **Bump the `development` plugin.** This task modifies content under
> `development/`, and every PR that does must bump `development/.claude-plugin/plugin.json`
> **and** its `.claude-plugin/marketplace.json` entry in lockstep (minor) —
> Claude Code caches plugins by version, so an omitted bump means installs never
> see the change and the fix silently appears inert. `marketplace-sync.yml`
> catches only *disagreement* between the two files, never an omitted bump, so
> nothing will flag it. Stage both files.

- [ ] **Step 4: Commit**

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

**Files:**

- Create: `tests/fixtures/kubernetes-repo/kustomize/base/kustomization.yaml`
- Create: `tests/fixtures/kubernetes-repo/kustomize/base/deployment.yaml` (the
  resource the base's `resources:` names)
- Create: `tests/fixtures/kubernetes-repo/kustomize/overlays/prod/kustomization.yaml` —
  the spec requires a Kustomize overlay, and without one the kustomize half of
  the machinery (the marker's `kustomization.yaml` branch, the gather's sweep,
  and Task 6's kustomize-roots recording / Component exclusion / input
  sweep-exclusion) is never exercised by the one end-to-end fixture
- Create: `tests/fixtures/kubernetes-repo/charts/app/Chart.yaml`
- Create: `tests/fixtures/kubernetes-repo/charts/app/templates/deployment.yaml`
- Create: `tests/fixtures/kubernetes-repo/argocd/app-of-apps.yaml`
- Create: `tests/fixtures/kubernetes-repo/policies/kyverno/require-registry.yaml`
- Create: `tests/fixtures/kubernetes-repo/policies/kyverno/kyverno-test.yaml`
- Create: `tests/fixtures/kubernetes-repo/broken/no-probe.yaml`
- Create: `tests/fixtures/kubernetes-repo/README.md`

**Interfaces:**

- Consumes: nothing. Deliberately self-contained — no network, no private content, no reference to any real deployment.

- [ ] **Step 1: Create the clean chart**

`charts/app/Chart.yaml`:

```yaml
apiVersion: v2
name: app
version: 0.1.0
```

`charts/app/templates/deployment.yaml`:

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
      securityContext:
        runAsNonRoot: true
      containers:
        - name: app
          image: registry.example.com/app:1.0.0
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
```

- [ ] **Step 2: Create the Kustomize base and prod overlay**

Without these the kustomize half of the machinery — the topic marker's
`kustomization.yaml` branch, the gather's marker sweep, and Task 6's
kustomize-roots recording, `kind: Component` exclusion and kustomize-input
sweep-exclusion — is never exercised by the one end-to-end fixture. The base
carries a real resource so the input-exclusion is genuinely tested: that
Deployment must NOT reach the validators unrendered.

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
the overlay genuinely **completes** the base, so the rendered output is clean
and every finding stays attributable to a file under `broken/`:

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
  - target:
      kind: Deployment
      name: worker
    patch: |
      - op: add
        path: /spec/template/spec/securityContext
        value:
          runAsNonRoot: true
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
      - op: add
        path: /spec/template/spec/containers/0/readinessProbe
        value:
          httpGet:
            path: /healthz
            port: 8080
```

Verify: `kustomize build tests/fixtures/kubernetes-repo/kustomize/overlays/prod`
exits 0 and renders a 3-replica Deployment in namespace `prod` whose image is
`registry.example.com/worker:1.0.0` (tagged, and on the registry the Kyverno
policy allows) with resources, a readiness probe and `runAsNonRoot` — i.e. the
rendered output is clean even though the base is not.

- [ ] **Step 3: Create the deliberately broken manifest**

`broken/no-probe.yaml` — one defect PER FINDING, so a regression is
attributable (this file carries four, each mapping to exactly one finding):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken
spec:
  replicas: 1
  selector:
    matchLabels:
      app: broken
  template:
    metadata:
      labels:
        app: broken
    spec:
      containers:
        - name: broken
          image: docker.io/library/nginx:latest
```

Expected findings: no readiness probe, no resource requests or limits,
`latest` tag, image not from the allowed registry.

- [ ] **Step 4: Create the policy and its tests**

`policies/kyverno/require-registry.yaml`:

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

`policies/kyverno/kyverno-test.yaml`:

```yaml
name: require-registry-test
policies:
  - require-registry.yaml
resources:
  - ../../broken/no-probe.yaml
  - ../../charts/app/templates/deployment.yaml
results:
  - policy: require-registry
    rule: images-from-allowed-registry
    resource: broken
    result: fail
  - policy: require-registry
    rule: images-from-allowed-registry
    resource: app
    result: pass
```

- [ ] **Step 5: Create the app-of-apps and the README**

`argocd/app-of-apps.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
spec:
  project: default
  source:
    repoURL: https://example.com/fixture.git
    targetRevision: v1.0.0
    path: charts/app
  destination:
    server: https://kubernetes.default.svc
    namespace: fixture
```

`README.md`:

```markdown
# kubernetes-repo fixture

A self-contained repository shape for exercising `development-kubernetes`:
a clean Helm chart, a Kustomize base + prod overlay, an Argo CD `Application`, a Kyverno policy with test
fixtures, and one deliberately broken manifest.

Each defect in `broken/` maps to exactly one expected finding, so a
regression is attributable to a specific check.

No network access, no private content, and no reference to any real
deployment — this fixture must stay usable by anyone who clones the
repository.
```

- [ ] **Step 6: Verify the fixture passes the repo's YAML gate**

Run `yamllint --strict tests/fixtures/kubernetes-repo` — it subsumes the parse
check and is what CI enforces. `tests/fixtures/` is excluded from the
whitespace and markdownlint hooks, **not** from yamllint.

Run:

```bash
find tests/fixtures/kubernetes-repo -name '*.yaml' -exec python3 -c "
import yaml,sys
for f in sys.argv[1:]:
    list(yaml.safe_load_all(open(f)))
print('all fixture yaml ok')" {} +
```

Expected: `all fixture yaml ok`

- [ ] **Step 7: Commit**

```bash
git add tests/fixtures/kubernetes-repo
# Task 7 has NO box: stage the fixture tree and nothing else. In particular do
# NOT bump any plugin version — fixtures under tests/ are not plugin content.
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
