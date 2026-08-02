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
- **Absent `policies/kyverno/` ⇒ skip with a note, never fail.**
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
| `development/skills/bootstrap/templates/iac/kubernetes-ci.yml` | The workflow template |
| `tests/gather-kubernetes.bats` | Gather behaviour |
| `tests/fixtures/kubernetes-repo/` | Self-contained end-to-end fixture |

---

### Task 1: Plugin skeleton, marketplace entry, ARCHITECTURE section

Establishes the ownership boundary before anything fills it. Child #1151.

**Files:**

- Create: `development-kubernetes/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `ARCHITECTURE.md`
- Test: `tests/check-marketplace-sync.bats` (existing — must stay green)

**Interfaces:**

- Produces: plugin name `development-kubernetes`, version `0.1.0`. Every later task references this name.

- [ ] **Step 1: Run the existing marketplace-sync test to confirm a green baseline**

Run: `bats tests/check-marketplace-sync.bats`
Expected: PASS (all existing plugins in sync)

- [ ] **Step 2: Create the plugin manifest**

```json
{
  "name": "development-kubernetes",
  "description": "Infrastructure-as-code topic plugin for Kubernetes manifests, Helm charts, Kustomize overlays and Argo CD resources. Composes ALONGSIDE a language plugin, and can itself be PRIMARY for a repo with no application language (a GitOps repo). Ships mechanism only: it renders and validates manifests and runs the repo's own Kyverno policies from policies/kyverno/, skipping when none are declared. Defers Dockerfiles and image builds to language plugins (language-first). Ships no approver agent — a cluster definition is approved by a human.",
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

- [ ] **Step 3: Add the marketplace entry**

Insert into the `plugins` array of `.claude-plugin/marketplace.json`, matching the `name`,
`description` and `version` above:

```json
{
  "name": "development-kubernetes",
  "description": "Infrastructure-as-code topic plugin for Kubernetes manifests, Helm charts, Kustomize overlays and Argo CD resources. Composes ALONGSIDE a language plugin, and can itself be PRIMARY for a repo with no application language. Ships mechanism only: it runs the repo's own Kyverno policies from policies/kyverno/, skipping when none are declared. Ships no approver agent.",
  "version": "0.1.0",
  "author": {
    "name": "Timo Jakob"
  },
  "source": "./development-kubernetes",
  "category": "development"
}
```

- [ ] **Step 4: Run the marketplace-sync test**

Run: `bats tests/check-marketplace-sync.bats`
Expected: PASS — `plugin.json` and `marketplace.json` agree on name and version.

- [ ] **Step 5: Add the ARCHITECTURE section**

Add to `ARCHITECTURE.md`, in the `### development-<topic> owns` area:

```markdown
### `development-kubernetes` owns

Kubernetes manifests, Helm charts and values, Kustomize overlays, and
Argo CD `Application` / `ApplicationSet` / `AppProject` resources.

It does **not** own Dockerfiles or image builds — language-first puts
those with the language plugins and later `development-container` — nor
cloud provisioning, nor application code of any kind.

**Mechanism here, policy in the consumer.** The plugin knows how to run
checks; the repo under test declares what to check for, at
`policies/kyverno/**/*.yaml`. When that path is absent the policy step
**skips and reports "no policies declared"** — it never fails. A public
plugin has to work in a repo that has no opinions yet.

The plugin ships **no policies of its own**: generic hygiene (probes,
resource limits, non-root, `latest` tags) is `kube-linter`'s job, and two
tools enforcing one rule means two places to silence a false positive.

**No approver agent**, following `development-claude-plugin`: a cluster
definition is the origin of everything running on it, so a human
approves. Note this is *not* the same as no auto-merge — the Maintenance
App cannot approve its own pull request, so a human approval is
structurally required, and auto-merge armed afterwards fires only once
that approval lands.

A repo declaring `primary: kubernetes` in `.maintenance.yml` gets the
full pipeline; the primary/auxiliary model already permits a topic to be
primary, so no new mechanism is needed.
```

- [ ] **Step 6: Commit**

```bash
git add development-kubernetes/.claude-plugin/plugin.json .claude-plugin/marketplace.json ARCHITECTURE.md
git commit -m "feat(development-kubernetes): plugin skeleton, marketplace entry, ARCHITECTURE section

Establishes the ownership boundary before anything fills it. Records the
mechanism/policy split, why absent policies skip rather than fail, and
why there is no approver agent.

Refs #1151"
```

---

### Task 2: Register the `kubernetes` topic marker

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
# kubernetes marker (file presence OR content; prune vendored trees):
if find . -name Chart.yaml -o -name kustomization.yaml \
     | grep -qv -e /node_modules/ -e /.git/ -e /vendor/ -e /templates/ \
   || grep -rqlF 'argoproj.io' --include='*.yaml' --include='*.yml' . 2>/dev/null; then
  topics+=(kubernetes)
fi
```

- [ ] **Step 3: Commit**

```bash
git add development/skills/maintenance/SKILL.md
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

@test "no policy directory: emits a skip note, not a finding" {
  chart
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.policy | length')" = "0" ]
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

local repo="${1:-.}"
[[ -d "$repo" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: not a directory: $repo"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -r -u2 -- "gather-kubernetes-findings.zsh: jq not found on PATH"; exit 3; }

local -a notes=()
local prune='-e /node_modules/ -e /.git/ -e /vendor/ -e /templates/'

# --- manifest_validation: is there anything to render? ------------------------
local has_manifests=false
if find "$repo" \( -name Chart.yaml -o -name kustomization.yaml \) 2>/dev/null \
     | grep -qv ${=prune}; then
  has_manifests=true
elif grep -rqlF 'argoproj.io' --include='*.yaml' --include='*.yml' "$repo" 2>/dev/null; then
  has_manifests=true
fi

# --- policy: the repo's own rules --------------------------------------------
local policy_dir="$repo/policies/kyverno"
local has_policies=false
local -a policy_files=()
if [[ -d "$policy_dir" ]]; then
  policy_files=(${(f)"$(find "$policy_dir" -name '*.yaml' -o -name '*.yml' 2>/dev/null)"})
  (( ${#policy_files} > 0 )) && has_policies=true
fi
$has_policies || notes+=("policy: no policies declared at policies/kyverno/ — step skipped, not failed")

# --- policy_tests: fixtures for those policies -------------------------------
local -a policy_test_findings=()
if $has_policies; then
  if ! grep -rqlE '^policies:' "$policy_dir" 2>/dev/null; then
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
     findings_by_tool: {
       manifest_validation: [],
       policy: [],
       policy_tests: $policy_tests
     },
     coverage: null,
     notes: $notes
   }'
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/gather-kubernetes.bats`
Expected: PASS — all six tests.

- [ ] **Step 5: Make the script executable and commit**

```bash
chmod +x development/skills/maintenance/scripts/gather-kubernetes-findings.zsh
git add development/skills/maintenance/scripts/gather-kubernetes-findings.zsh tests/gather-kubernetes.bats
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
  `primary: kubernetes` and gets the full pipeline. v1 handles manifest_validation
  → kubernetes-manifest-fixer, and policy + policy_tests → kubernetes-policy-triage.
  A single invocation returns the plan; the per-group work agents are the
  orchestrator's job. Pure function of its JSON input; runs no detection of its
  own. Ships NO approver — a cluster definition is approved by a human.
---

# Kubernetes maintenance dispatcher

Read the payload at `$ARGUMENTS`. Validate the envelope, then return a
PR-grouped plan. Spawn nothing.

## Routing

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
`kyverno test` fixtures. Treat a `policy_tests` finding as blocking for the
policy group — an untested policy usually matches nothing and passes
everything silently.

## Absent policies are not a finding

`tooling_configured.policy: false` means the repo declared no policies. Return
a plan with no policy group and carry the gather's note through. Do not
synthesise a finding, and do not suggest the repo adopt policies — that is the
consumer's decision, not this plugin's.
```

- [ ] **Step 2: Verify the frontmatter parses**

Run: `bats tests/skill-frontmatter.bats 2>/dev/null || python3 -c "import
sys,re;t=open('development-kubernetes/skills/maintenance/SKILL.md').read();assert
t.startswith('---');print('frontmatter ok')"`
Expected: `frontmatter ok`

- [ ] **Step 3: Commit**

```bash
git add development-kubernetes/skills/maintenance/SKILL.md
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
```

- [ ] **Step 2: Create the reliability reviewer**

```markdown
---
name: kubernetes-reliability-reviewer
description: Kubernetes reliability specialist reviewing rendered manifests for the failure modes that surface as outages rather than errors — missing or misconfigured probes, absent resource requests, no PodDisruptionBudget, single replicas for stateful paths, missing anti-affinity, and rollout strategies that drop capacity. The reliability dimension of /development-kubernetes:review.
model: opus
tools: Read, Grep, Glob
---

You are this plugin's analogue of a bug hunter, named for what you actually
hunt. A missing probe is not a crash — it is an outage at 3am under load, and
an agent looking for bugs would look for the wrong thing.

## What to look for

- **Probes** — absent readiness (traffic to a process that is not ready),
  absent liveness, or a liveness probe so aggressive it restarts healthy pods
  under load, which converts a slowdown into an outage.
- **Resources** — missing `requests` (the scheduler cannot place sensibly),
  or limits so close to requests that a burst is throttled or OOM-killed.
- **Disruption** — no `PodDisruptionBudget`, so a node drain takes the
  service down.
- **Placement** — a single replica on a serving path; no anti-affinity, so
  every replica lands on one node.
- **Rollout** — `maxUnavailable` that drops below quorum for a stateful set,
  or `Recreate` on a service expected to stay up.

## Judgement

A single replica in a demonstration overlay is fine; a single replica in a
production overlay is a finding. Read the overlay before reporting.
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
```

- [ ] **Step 4: Create the manifest fixer**

```markdown
---
name: kubernetes-manifest-fixer
description: For each manifest_validation finding (kubeconform schema errors, kube-linter warnings, formatting drift), apply the mechanical behaviour-preserving fix and verify by re-running the check; escalate anything that would change what gets deployed. Used by development-kubernetes:maintenance.
model: sonnet
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

**Render first.** Run `helm template` and `kustomize build` into a temp tree
and point the agents at the output. A chart that reads safely can render a
privileged container, and the rendered form is what reaches a cluster.

There is no approver dimension. A human approves infrastructure.
```

- [ ] **Step 7: Verify all agent frontmatter parses**

Run:

```bash
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

- [ ] **Step 8: Commit**

```bash
git add development-kubernetes/agents development-kubernetes/skills/review
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

- Create: `development/skills/bootstrap/templates/iac/kubernetes-ci.yml`
- Modify: `development/skills/bootstrap/SKILL.md`

**Interfaces:**

- Consumes: the `policies/kyverno/` convention from Task 3.
- Produces: six named checks — `render`, `schema`, `lint`, `policy`, `config-scan`, `argocd`.

- [ ] **Step 1: Create the workflow template**

```yaml
name: kubernetes-ci
on:
  pull_request:
permissions:
  contents: read
jobs:
  render:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: helm template every chart
        run: |
          set -euo pipefail
          mkdir -p .rendered
          find . -name Chart.yaml -not -path './.git/*' | while read -r c; do
            d="$(dirname "$c")"
            helm template "$(basename "$d")" "$d" > ".rendered/$(basename "$d").yaml"
          done
      - name: kustomize build every overlay
        run: |
          set -euo pipefail
          find . -name kustomization.yaml -not -path './.git/*' | while read -r k; do
            d="$(dirname "$k")"
            kustomize build "$d" > ".rendered/$(echo "$d" | tr / _).yaml"
          done
      - uses: actions/upload-artifact@v4
        with: { name: rendered, path: .rendered }

  schema:
    needs: render
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: rendered, path: .rendered }
      - run: kubeconform -strict -summary -ignore-missing-schemas .rendered/

  lint:
    needs: render
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: rendered, path: .rendered }
      - run: kube-linter lint .rendered/

  policy:
    needs: render
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { name: rendered, path: .rendered }
      - name: kyverno apply + test
        run: |
          set -euo pipefail
          if [ ! -d policies/kyverno ]; then
            echo "::notice::no policies declared at policies/kyverno/ — policy step skipped"
            exit 0
          fi
          kyverno apply policies/kyverno/ --resource .rendered/
          kyverno test policies/kyverno/

  config-scan:
    needs: render
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: rendered, path: .rendered }
      - run: trivy config .rendered/

  argocd:
    needs: render
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: every referenced app path exists
        run: |
          set -euo pipefail
          rc=0
          grep -rhoE 'path:[[:space:]]*\S+' --include='*.yaml' . \
            | awk '{print $2}' | sort -u | while read -r p; do
              [ -e "$p" ] || { echo "::error::app-of-apps references missing path: $p"; rc=1; }
            done
          exit $rc
```

- [ ] **Step 2: Teach bootstrap to emit it**

Add to `development/skills/bootstrap/SKILL.md`:

```markdown
### Infrastructure-as-code repos (no application language)

When detection finds the `kubernetes` topic and **no** language, the repo is
a GitOps/IaC repo. Emit `templates/iac/kubernetes-ci.yml` as
`.github/workflows/kubernetes-ci.yml` and write `primary: kubernetes` into
`.maintenance.yml`.

Do **not** require an application language before bootstrapping. A repo of
charts and manifests has plenty to validate — rendering always produces
something to check, which is why this works before the first service exists.

Do not create `policies/kyverno/`. Policies are the consumer's; the workflow
skips cleanly when the directory is absent.
```

- [ ] **Step 3: Verify the workflow is valid YAML**

Run: `python3 -c "import yaml,sys;
yaml.safe_load(open('development/skills/bootstrap/templates/iac/kubernetes-ci.yml')); print('yaml
ok')"`
Expected: `yaml ok`

- [ ] **Step 4: Commit**

```bash
git add development/skills/bootstrap/templates/iac/kubernetes-ci.yml development/skills/bootstrap/SKILL.md
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
    matchLabels: { app: app }
  template:
    metadata:
      labels: { app: app }
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: app
          image: registry.example.com/app:1.0.0
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { cpu: 500m, memory: 256Mi }
```

- [ ] **Step 2: Create the deliberately broken manifest**

`broken/no-probe.yaml` — one defect, so a regression is attributable:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken
spec:
  replicas: 1
  selector:
    matchLabels: { app: broken }
  template:
    metadata:
      labels: { app: broken }
    spec:
      containers:
        - name: broken
          image: docker.io/library/nginx:latest
```

Expected findings: no readiness probe, no resource requests or limits,
`latest` tag, image not from the allowed registry.

- [ ] **Step 3: Create the policy and its tests**

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

- [ ] **Step 4: Create the app-of-apps and the README**

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
a clean Helm chart, an Argo CD `Application`, a Kyverno policy with test
fixtures, and one deliberately broken manifest.

Each defect in `broken/` maps to exactly one expected finding, so a
regression is attributable to a specific check.

No network access, no private content, and no reference to any real
deployment — this fixture must stay usable by anyone who clones the
repository.
```

- [ ] **Step 5: Verify every fixture file is valid YAML**

Run:

```bash
find tests/fixtures/kubernetes-repo -name '*.yaml' -exec python3 -c "
import yaml,sys
for f in sys.argv[1:]:
    list(yaml.safe_load_all(open(f)))
print('all fixture yaml ok')" {} +
```

Expected: `all fixture yaml ok`

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/kubernetes-repo
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
