# development-kubernetes — design

- **Date:** 2026-08-02
- **Status:** approved; in implementation — child 1 (#1151) landed, #1152-#1155 open
- **Drives:** the `development-kubernetes` epic
- **Motivating consumer:** a private platform-infrastructure repo (GitOps,
  Argo CD, Helm, no application language) that cannot currently be
  bootstrapped, and therefore cannot have required status checks.

## 1. Context and goals

The family has no home for infrastructure-as-code. A GitOps repo — Argo CD
manifests, Helm charts, Kustomize overlays, cluster provisioning — is
detected as nothing, gets no bootstrap, no CI, and no maintenance. In
practice that means branch protection can require a review but cannot
require that anything *builds*, because no check exists to require.

`ARCHITECTURE.md` already anticipates the answer by name:

> the `development-kubernetes` plugin defers to language plugins for the
> application's entrypoints and images, and owns only the manifest-side
> concerns — see `development-kubernetes` owns for the concern boundary,
> which deliberately leaves generic manifest hygiene to `kube-linter`
> rather than restating it here.

(The wording ARCHITECTURE.md carried when this design was written listed
"resource limits, probes, network policy, security contexts" as the plugin's
own concerns. #1151 corrected it: that generic hygiene is `kube-linter`'s, per
§3 below, and duplicating it would mean two places to silence one false
positive.)

Two properties of the motivating repo shape the design:

**It has no application language.** The primary/auxiliary model already
permits this — "the primary may itself be a topic, e.g. `claude-plugin`" —
so a repo declaring `primary: kubernetes` gets the full pipeline rather
than an auxiliary lint pass. No new mechanism is required.

**Its opinions are confidential.** The consuming repo's architectural
decisions (which service mesh, which database operator, a rule that no
managed cloud service may be adopted) live in a private repository. This
plugin is public. That constraint drives §3 and is not negotiable.

**Goal:** a repo with Helm charts and Argo CD manifests and no application
code can be bootstrapped into meaningful, requirable CI, and maintained by
the same orchestrator as everything else.

**Non-goal:** cloud provisioning. OpenTofu is a separate plugin (§6).

## 2. Ownership boundary

**Owns:** Kubernetes manifests, Helm charts and values, Kustomize
overlays, Argo CD `Application` / `ApplicationSet` / `AppProject`
resources.

**Does not own:** Dockerfiles and image builds — language-first, those
belong to the language plugins and later `development-container`; cloud
provisioning; application code of any kind.

**Ships no approver, deliberately.** Every language plugin has one.
`development-claude-plugin` does not, on the reasoning that "a plugin repo
is the origin of every other repo, so a human approves". A cluster
definition has the same property with a wider blast radius: a bad
manifest does not fail one service, it fails the platform hosting all of
them.

**No auto-approval is not no auto-merge**, and the distinction matters.
Maintenance PRs are authored by the Maintenance App, which cannot approve
its own work, so a human approval is structurally required. Auto-merge
armed afterwards fires only once that approval lands and CI is green.
Infrastructure keeps the family's convenience; only the judgement stays
human.

## 3. Mechanism here, policy in the consumer

The plugin ships **how to check**. The consuming repo ships **what to
check for**. This is what allows a public plugin to serve a repo whose
architectural decisions are confidential, and it is also what keeps the
plugin genuinely reusable by third parties.

**Discovery is by convention:** `policies/kyverno/**/*.{yaml,yml}` in the repo
under test. The **glob**, not the directory, is the contract: the skip
condition is **no matching files**, so an empty or `.json`-only policy
directory skips exactly like an absent one, and a repo that writes its
policies as `.yml` is enforced rather than silently ignored. When nothing
matches, the policy step **skips and reports "no policies declared"** — it
does not fail. When policies *are* declared, violations **do** fail. A public plugin has to work in a repo that
has no opinions yet; a hard failure would make it unusable by anyone but
its first consumer.

**The plugin ships no policies of its own.** Bundling a starter set — no
`latest` tags, resource limits required, run as non-root — is tempting and
wrong: `kube-linter` (§4) already enforces exactly those, and two tools
enforcing one rule means two places to silence a false positive and two
ways for them to disagree. The policy layer earns its place only where
`kube-linter` cannot reach:

- registry allow-lists
- required labels and annotations (tenancy, ownership, plane)
- cross-resource invariants — every namespace has a NetworkPolicy, every
  Deployment a PodDisruptionBudget
- forbidden APIs — turning a prose architectural commitment into a build
  failure

That last case is the most valuable. An architectural rule such as "no
managed cloud services" erodes one convenient exception at a time, and
prose cannot stop it. A policy can.

**Policies are code and get tests.** `kyverno test` runs fixture manifests
asserting pass and fail cases. An untested policy directory is a finding.
A policy nobody tested is usually a policy that matches nothing — it
passes everything, silently, and looks like it is working.

### Why Kyverno

YAML policies, no Rego, readable by one maintainer six months later, and
native Kubernetes semantics. The decisive property is reuse: **the same
policy files can later deploy in-cluster as admission control**, so CI and
runtime enforce one artifact instead of two rulesets that drift.

*Considered:* **Conftest/OPA Rego** — one engine spanning Kubernetes and
OpenTofu, so §6 would need nothing new; rejected because Rego's
readability tax falls hardest on a solo maintainer, and in-cluster reuse
would mean Gatekeeper. **`kube-linter` custom checks only** — rejected as
too weak to express registry allow-lists or cross-resource rules, with no
runtime story.

Accepted cost: Kubernetes-only, so §6 will need a second policy engine.

## 4. The check pipeline

One bootstrap-generated workflow, on pull requests, ordered so cheap
failures surface first:

| # | Step | Tool |
|---|---|---|
| 1 | **Render** charts and overlays into a temp tree | `helm template`, `kustomize build` |
| 2 | **Schema** validation against the target API version (core kinds; CRD-defined kinds are skipped in v1 — see below) | `kubeconform` |
| 3 | **Best practice** — probes, limits, privileged containers, `latest` | `kube-linter` |
| 4 | **Policy** — the repo's own rules, plus their tests | `kyverno apply`, `kyverno test` |
| 5 | **Config scan** — misconfiguration | `trivy config` |
| 6 | **Argo CD** — every app path the app-of-apps references exists (path integrity, not schema validity) | `yq` |

Everything downstream validates **rendered output, not templates**: a
chart that lints clean can render an invalid manifest, and the rendered
form is what reaches a cluster.

Step 1 is why this works on a repo with no application code — there is
always something to render, so the checks are meaningful before the first
service exists.

**v1 does not schema-validate CRD-defined resources.** `kubeconform` runs with
`-ignore-missing-schemas` and no CRD schema location, so `argoproj.io` kinds —
the resource class this plugin centres on — are skipped silently rather than
validated. Step 6 checks Argo CD app-path integrity, not schema validity, so the
gap is not covered elsewhere. Saying so plainly matters: a reader who believed
"CRDs included" would trust a validation that never ran. Wiring a CRD schema
catalog into the schema step is deliberate later work.

Each step becomes a required status check once green.

## 5. Maintenance

**Gather:** `development/skills/maintenance/scripts/gather-kubernetes-findings.zsh`,
discovered by the orchestrator's existing convention so nothing hardcodes
the new plugin. Detection marker is a Helm `Chart.yaml`, a
`kustomization.yaml`, or `argoproj.io` resources — deliberately *not* "any
YAML with `apiVersion`", which would match half the repos in existence. It
emits v2 JSON whose tool keys MAP onto §4's checks rather than repeating their
names: `manifest_validation` covers the render/schema/lint surface (§4 steps
1-3), and `policy` plus `policy_tests` cover step 4. Stating the mapping matters
because the dispatcher's routing table keys on those three names — a payload
keyed by the CI check names instead would produce groups the dispatcher does not
route — which its validation **halts** on with `human_action_required`, rather
than dropping. Either way the findings never reach an agent; the halt at least
says so out loud.

**v1 is presence-detection, not a second execution of §4's tools.** The gather
reports which tooling is *configured* (charts/overlays present, a policy set
declared, whether that policy set has `kyverno test` fixtures) and leaves
`manifest_validation` / `policy` findings empty; CI is where those tools
actually run. Stating it plainly matters, because the alternative reading —
that maintenance re-runs kubeconform/kube-linter/kyverno — would make an empty
findings list mean "this repo is clean" when it only means "nothing was run".
Executing the tools in the gather is a deliberate later step, not a gap this
slice silently carries.

**Dispatcher:** `development-kubernetes/skills/maintenance/SKILL.md` —
validates the payload, returns a PR-grouped plan, spawns nothing. A pure
function of its input, like every dispatcher in the family.

**Agents:**

| Agent | Dimension |
|---|---|
| `kubernetes-security-reviewer` | security contexts, RBAC breadth, secrets handling, privileged/hostPath, NetworkPolicy gaps |
| `kubernetes-reliability-reviewer` | probes, requests/limits, PDBs, replicas, anti-affinity, rollout strategy |
| `argocd-advisor` | app-of-apps structure, sync policy, `AppProject` restrictions, sync waves, drift |
| `kubernetes-manifest-fixer` | mechanical: formatting, schema corrections, autofixable lint |
| `kubernetes-policy-triage` | Kyverno failures and untested policies |

The reliability reviewer is this plugin's analogue of `<lang>-bug-hunter`,
named for what it actually hunts. A missing probe is not a crash; it is an
outage at 3am under load, and an agent told to look for bugs will look for
the wrong thing.

**The coverage-gate analogue is policy-test coverage.** Language plugins
gate on line coverage; topic plugins have no app test suite, which is why
`development-docs` has no coverage gate. An IaC repo does have something
meaningfully testable, and it fails in the way hardest to notice — a
policy directory without fixtures passes everything silently. So this
plugin gates on `kyverno test` where a language plugin gates on coverage.

## 6. Decomposition

Six children, the first five public and independently releasable, the
sixth private:

1. **Plugin skeleton** — `plugin.json`, marketplace entry in lockstep,
   `ARCHITECTURE.md` section recording the ownership boundary, the
   `policies/kyverno/` convention, and the no-approver rationale.
   Establishes the boundary before anything fills it.
2. **Gather script + dispatcher** — the maintenance path end to end.
3. **Agents** — the five above.
4. **Bootstrap IaC support** — the §4 workflow, emitted for a repo with no
   application language.
5. **Test fixtures** — a self-contained repo under `tests/fixtures/`: a
   Helm chart, a Kustomize overlay, an Argo CD `Application`, a Kyverno
   policy with tests, and deliberately broken manifests with known
   findings. The motivating consumer is private and empty, so it cannot
   serve as the reference project; coupling public tests to private
   content would be wrong regardless.
6. **Consumer adoption** *(private repo, not this repository)* —
   `.maintenance.yml` declaring `primary: kubernetes`, a
   `policies/kyverno/` directory encoding its architectural rules, then
   required status checks switched on.

Children 1–5 are releasable without any consumer. Child 6 is where the
opinions live and never enters this repository.

## 7. Adjacencies

**`development-opentofu` — the next slice.** Cloud provisioning is a
distinct toolchain and bundling it would double this spec. It should
follow the `development-javascript` precedent and cover both OpenTofu and
Terraform-compatible HCL, so it remains useful to consumers who have not
migrated. It will need its own policy engine, since Kyverno is
Kubernetes-only.

**In-cluster admission control.** The reuse that justified Kyverno.
Deliberately *not* assumed here: turning it on is a decision for the
consuming platform, with its own trade-offs, and it should not arrive as a
side effect of a CI tooling choice.

**Deferred agents.** A `helm-advisor` for chart hygiene and
`values.schema.json`, and a dedicated policy reviewer. `kube-linter` and
`kubernetes-policy-triage` cover enough of both that separate agents now
would be speculative.

## 8. Considered and rejected

**Bake the opinions into the plugin.** Simplest, most expressive, no
schema to design. Rejected: the plugin repository is public and the
consumer's architecture is confidential, and it would break the family's
stated genericity — third parties are meant to be able to use these
plugins without forking.

**A private companion plugin holding the opinions.** Richer than
data-driven policy: an agent could argue "this violates the
self-hosting decision because…". Rejected for now as a second plugin
repository with its own release cadence and marketplace wiring, none of it
shareable. Reconsider only if data-driven policy proves too blunt.

**Bootstrap support with no plugin.** Fastest route to required status
checks — workflows wiring up off-the-shelf linters, nothing else.
Rejected: no home for guardrails or reviewers, and the plugin would later
have to be retrofitted around workflows already generated.

**Ship generic starter policies.** Rejected as duplicating `kube-linter`;
see §3.
