# development-opentofu — design

- **Date:** 2026-08-02
- **Status:** approved design, not yet implemented
- **Drives:** the `development-opentofu` epic
- **Sibling:** `2026-08-02-kubernetes-iac-plugin-design.md`. This is slice 2 of the
  same IaC effort and mirrors it deliberately; only the differences are argued here.

## 1. Context and goals

`development-kubernetes` gives a GitOps repo a home, but it stops at the cluster
boundary. Cloud provisioning — the modules that create the cluster the manifests
are deployed onto — is still detected as nothing.

That gap matters more than the Kubernetes one. A bad manifest fails a workload; a
bad provisioning change destroys the state that everything else assumes.

**One plugin covers OpenTofu and Terraform-compatible HCL**, following the
`development-javascript` precedent where JavaScript and TypeScript ship together
rather than duplicating ~90% of their content. The tooling is shared, the file
extension is the same `.tf`, and a consumer who has not migrated should still find
the plugin useful. It is named for OpenTofu because that is the MPL-2.0 tool the
family recommends; BUSL-licensed Terraform is supported, not endorsed.

**Goal:** a repo of `.tf` modules can be bootstrapped into requirable CI and
maintained by the same orchestrator as everything else, with no cloud credentials
required for the checks that run on every pull request.

**Non-goal:** Kubernetes manifests. That is the sibling plugin, and a repo holding
both simply detects both topics.

## 2. Ownership boundary

**Owns:** `.tf` and `.tf.json` sources, module structure, provider and version
constraints, backend and state configuration, and `.tfvars` hygiene.

**Does not own:** anything the modules deploy *into* a cluster — that is
`development-kubernetes`; container images; application code.

> **Superseded in part by #1159 — authoritative text is `ARCHITECTURE.md`'s
> `development-opentofu owns` section.** Read as a *resource-kind* rule, the
> disclaimer above opens a gap neither plugin covers: a `kubernetes_manifest` or
> `helm_release` is deployed into a cluster but lives in a `.tf` file, which the
> sibling never reads — so a privileged pod declared in HCL would be deferred by
> this plugin and unreachable by the other. The boundary is the **file set**:
> cluster resources expressed in HCL stay here; only manifests, charts, overlays
> and Argo CD resources belong to the sibling. As with §4, §5, §6 and §8, the record
> is kept rather than rewritten.

**Ships no approver agent**, for the reason `development-claude-plugin` and
`development-kubernetes` already establish, with the sharpest form here: a
provisioning change can destroy state that no rollback recovers. A human approves.

As before, **no auto-approval is not no auto-merge.** The Maintenance App cannot
approve its own pull request, so a human approval is structurally required, and
auto-merge armed afterwards fires only once it lands.

## 3. Static now, plan-based seam built and disabled

Kubernetes lets a pipeline validate rendered output cheaply and safely.
Infrastructure provisioning does not.

**Static analysis** — `tofu validate`, `tflint`, `trivy config`, Conftest over HCL —
runs on any pull request with **no credentials and no state access**. It sees only
what is in the source.

**Plan-based analysis** — Conftest over `tofu show -json` — sees what will actually
happen: this change destroys the database, this recreates the cluster, this drops
encryption. Those are the findings an IaC gate exists for. Producing them requires
**provider credentials and state access in a workflow triggered by pull requests**,
which is a genuine security surface and not one to design casually.

**Decision: ship static checks, and ship the plan-based job disabled.** The workflow
contains the plan stage, guarded by a repository variable that defaults off, so
enabling it later is configuration rather than a redesign of the pipeline. Consumers
without cloud accounts — the common case at adoption time — get a working gate on
day one.

This is deliberately *not* a heuristic destroy-detector over HCL source. A guardrail
that is right most of the time trains people to trust it, and module composition
produces exactly the cases a source-level heuristic misses.

## 4. Mechanism here, policy in the consumer

Identical to the sibling plugin, with a different engine and path:
`policies/conftest/**/*.rego`. Absent, the policy step **skips and reports "no
policies declared"** — it never fails *for that reason*; declared policies whose
violations fire still fail the step, and so does a declared set Conftest cannot
evaluate.

**Conftest** is the engine. It parses HCL2 natively *and* plan JSON, so one binary
and one language cover both the static stage and the deferred plan stage. It is the
OPA project's own tool, so the Rego is portable if the consumer ever runs OPA
properly.

**The accepted cost is Rego's readability**, which is the exact trade the sibling
spec refused when it chose Kyverno's YAML for Kubernetes. It is accepted here
because the alternative is worse: Checkov would buy YAML-ish authoring at the price
of a large opinionated built-in library overlapping `tflint` and `trivy`, which is
the duplication the sibling pipeline was specifically designed to avoid.

*Considered and rejected:* **kyverno-json**, which would have unified the policy
language across both plugins — it is **no longer maintained**, its successor is the
Kyverno CLI's CEL-based `ValidatingPolicy`, and that applies to JSON payloads, which
is the plan stage this design defers. The unification was attractive and does not
survive contact with the facts.

**The plugin ships no policies of its own.** Generic rules belong to `tflint` and
`trivy`; the policy layer is for what they cannot express — required module
structure, mandated backend configuration, provider version floors, naming and
tagging conventions, forbidden resource types.

**One exception, and it is a first-class check rather than a policy: state
encryption.** OpenTofu supports encrypting state natively, and state holds provider
credentials, generated passwords and connection strings in plaintext otherwise. A
rule that lives only in a consumer's policy set is a rule the consumer can forget to
write. The plugin therefore checks that an `encryption` block is configured and
reports its absence as a finding. This is the one opinion the plugin holds, and it
is held because the failure is silent, severe, and identical for every consumer.

> **Superseded in part by #1159 — read `ARCHITECTURE.md`'s
> `development-opentofu owns` section as authoritative for this check.** The
> paragraph above states the mechanism as the OpenTofu-native `encryption`
> block, which BUSL Terraform rejects — so taken literally it would make the
> check fire permanently and unfixably on every Terraform-dialect repo, the
> dialect §1 declares supported. The decision that survives is the
> **requirement** — state encrypted at rest, in whichever form the repo's own
> tool provides — not the artifact satisfying it. And the requirement itself
> binds only where the repo **owns** state: a reusable-module library is
> exempt, a root on the implicit local backend is not. §5's Tool cell for this
> row originally read "plugin check" and has been **corrected in place** — a
> consumer's rendered workflow cannot call this plugin's scripts, so the check
> is inline; that is the one deviation in this document from the
> keep-the-record convention, made because a Tool cell has no room to carry a
> banner. The rest of this section
> stands. As with §2, §5, §6 and §8, the record is kept rather than rewritten, per
> this repo's treatment of design documents as evidence of what was decided
> when.

## 5. The check pipeline

Bootstrap-generated, on pull requests, cheap failures first:

| # | Step | Tool | Credentials |
| --- | --- | --- | --- |
| 1 | **Format** | `tofu fmt -check -recursive` | none |
| 2 | **Validate** — syntax, references, types | `tofu validate` | none |
| 3 | **Lint** — provider-aware best practice, deprecations | `tflint` | none |
| 4 | **Misconfiguration scan** | `trivy config` | none |
| 5 | **State encryption configured** | inline in the rendered workflow (see ARCHITECTURE) | none |
| 6 | **Policy** — the consumer's own Rego, plus `conftest verify` for its tests | `conftest` | none |
| 7 | **Plan policy** — *disabled by default* | `tofu plan` + `conftest` | **cloud + state** |

Steps 1–6 are the requirable set at adoption. Step 7 becomes requirable only once a
consumer enables it.

`tofu validate` requires `tofu init`, which reaches the provider registry. That is a
network dependency but not a credential one; the workflow uses `-backend=false` so
no state is touched.

**Policies are code and get tests.** `conftest verify` runs Rego unit tests. An
untested policy directory is a finding — the same reasoning as the sibling plugin: an
untested policy usually matches nothing, so it passes everything and looks like it
is working.

> **Superseded in part by #1159 — authoritative text is `ARCHITECTURE.md`'s
> `development-opentofu owns` section.** "A finding" here sits inside a section
> that otherwise speaks only in CI terms, so it reads as *the `policy` job
> fails*. It is the opposite: `conftest verify` over a test-less directory exits
> green, so the rendered pipeline is **silent** on that state; the verify leg
> fails only on a *failing* `conftest verify` run (violations and the
> cannot-evaluate states fail the step as before — this bounds the verify leg,
> not the job). The declared-but-untested defect travels **solely** under the
> maintenance gather's `policy` key — one defect, one carrier. Building the CI
> half from this paragraph would turn a consumer's pipeline permanently red on a
> state the charter routes to `opentofu-policy-triage`. As with §2, §4, §6 and §8,
> the record is kept rather than rewritten.

## 6. Maintenance

**Gather:** `development/skills/maintenance/scripts/gather-opentofu-findings.zsh`,
discovered by the orchestrator's existing convention. Detection marker is the
presence of `*.tf` files, pruning vendored trees and `.terraform/`.

> **Superseded in part by #1159 — authoritative text is `ARCHITECTURE.md`'s
> `development-opentofu owns` section.** The marker sentence above reads as a
> settled decision. It is not: the charter's ownership statement covers
> `.tf.json` as well, so a module tree written entirely as HCL-JSON would be
> owned yet undetected by a `*.tf`-only glob. #1160 must therefore **either
> widen the glob to match the ownership statement or record why the JSON syntax
> is out of scope** — nothing downstream may assume the narrower reading here
> was deliberate. As with §2, §4, §5 and §8, the record is kept rather than
> rewritten.

**Dispatcher:** `development-opentofu/skills/maintenance/SKILL.md` — validates the
payload, returns a PR-grouped plan, spawns nothing.

**Agents:**

| Agent | Dimension |
| --- | --- |
| `opentofu-security-reviewer` | over-permissive IAM, public exposure, unencrypted storage, secrets in variables or outputs, state backend exposure |
| `opentofu-module-advisor` | module boundaries and output contracts, provider and version pinning, variable validation and typing, backend configuration |
| `opentofu-format-fixer` | mechanical: `tofu fmt`, autofixable `tflint` rules |
| `opentofu-policy-triage` | Conftest failures and untested policies |

Four rather than the sibling's five: there is no Argo CD analogue, and the
reliability dimension folds into the module advisor because in provisioning the
failure modes are structural — a missing lifecycle rule, an unpinned provider — not
runtime.

**The coverage-gate analogue is policy-test coverage**, exactly as in the sibling
plugin: `conftest verify` fixtures where a language plugin has line coverage.

**Version pinning deserves naming.** An unpinned provider means the same source
produces different infrastructure on different days, which is the IaC equivalent of
an irreproducible build. The module advisor treats it as a finding, not a style note.

## 7. Decomposition

Five children, all public:

1. **Plugin skeleton** — `plugin.json`, marketplace entry in lockstep,
   `ARCHITECTURE.md` section recording the ownership boundary, the
   `policies/conftest/` convention, the no-approver rationale, and the OpenTofu /
   Terraform-compatible scope.
2. **Gather script + dispatcher** — including the topic marker registration.
3. **Agents** — the four above.
4. **Bootstrap IaC support** — the §5 pipeline, with step 7 present and disabled.
5. **Test fixtures** — a self-contained module tree: a clean module, a module with
   an unpinned provider and no state encryption, a Rego policy with `conftest verify`
   tests, and one module whose defects map one-to-one to expected findings.

Consumer adoption is tracked in the consuming repo, as with the sibling plugin. It
never enters this repository.

## 8. Adjacencies

**Enabling the plan stage** is a consumer decision with real prerequisites: a cloud
identity for CI with least-privilege read access, state access, and a policy on
pull requests from outside the repository. The seam exists so that decision is
configuration, not redesign.

**`development-container`** remains the home for image concerns, unchanged.

**A repo holding both `.tf` and Kubernetes manifests** detects both topics and runs
both pipelines. No coordination is needed — the plugins own disjoint file sets, and
that disjointness is what makes composition free.

> **Superseded in part by #1159 — authoritative text is `ARCHITECTURE.md`'s
> job-id collision paragraph.** The sentence above holds for the *maintenance*
> pipelines, which do compose freely. It does **not** hold for the
> bootstrap-rendered **CI** workflows: the two share three job ids (`lint`,
> `config-scan`, `policy`) and a required status context is matched by name, so
> at most one IaC workflow is rendered per repo and the dual-marker case must
> halt until the slice that renders both disambiguates them. As with §2, §4, §5 and
> §6, the record is kept rather than rewritten.

## 9. Considered and rejected

**Plan-based from the start.** Full value immediately. Rejected: it requires
designing credential handling, state access and pull-request trigger safety before
any consumer has cloud accounts, and it would gate adoption on infrastructure that
does not exist.

**Static only, plan stage out of scope.** Smallest and safest. Rejected: it can
never answer "will this destroy something", which is the question an IaC gate exists
for, and adding it later would mean reopening the pipeline design rather than
flipping a variable.

**A source-level destroy-detection heuristic.** Cheaper than a real plan and catches
the loudest cases. Rejected: heuristics over HCL miss what module composition
produces, and a guardrail that is right most of the time is worse than none, because
people stop checking.

**A separate `development-terraform` plugin.** Rejected on the
`development-javascript` precedent: shared tooling, shared file extension, ~90%
shared content.

**Checkov as the policy engine.** YAML-ish custom policies, closer to Kyverno's
ergonomics. Rejected: its large built-in library overlaps `tflint` and `trivy`, and
duplicated enforcement means two places to silence one false positive — the specific
outcome the sibling pipeline was designed to avoid.
