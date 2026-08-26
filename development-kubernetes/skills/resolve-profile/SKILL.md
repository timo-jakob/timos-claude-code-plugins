---
name: resolve-profile
description: >
  Loaded by /development:resolve-issue — not for direct use. The kubernetes repo
  type's driver rules for the resolve-issue conductor: which validation tools
  gate a manifest change, what §4's version bump means here, and which review
  panel applies. The conductor detects the repo type at §1b and loads the
  matching `development-<repo_type>:resolve-profile` by name; a type with no
  profile keeps the conductor's generic behaviour.
disable-model-invocation: false
---

You are the **kubernetes resolve profile**. `/development:resolve-issue` loaded
you at its §1b step because this repo detected as `kubernetes` — a GitOps or
manifest repo with no application language of its own. You do not drive the run
— the conductor does. You supply the rules that are true of **this repo type and
no other**, so a Go or claude-plugin run never reads them, and so every
kubernetes-side edit lands here rather than in the shared conductor.

Every heading below is part of the profile contract (ARCHITECTURE.md, *Resolve
profile contract*). A heading with nothing to say says **none** — it is never
dropped, because the contract's readers key on the roster, not on presence.

## Gate

These are the §3 rules for this repo type. The conductor's generic bullet says
*the whole suite, never a subset*; what follows is how that is spelled here.

- **There is no test suite — there are validation tools.** A manifest repo has
  nothing to compile and nothing to unit-test, so the gate is: **render** first
  (a chart or overlay is gated on what it produces, never on its template), then
  `kubeconform` for schema validity, `kube-linter` for the presence checks, and
  `kyverno test` for the declared policy fixtures. Render with `helm template`
  where a `Chart.yaml` governs and `kustomize build` where a `kustomization.yaml`
  does.
- **Render the same SET this plugin's review panel renders — not "everything".**
  `development-kubernetes/skills/review/SKILL.md`'s render step skips a
  documented set (library charts, vendored subcharts, component kustomizations,
  and any root another root consumes); **read the set there rather than
  restating it here.** Those are not optional exclusions: several of them *fail
  by design* when rendered standalone, so a gate that enumerated every chart
  would red on a repo the plugin's own CI renders green — and the model would
  then either abandon a sound story or edit an unrelated chart to make it
  render, which this Gate forbids as smuggled content. A failure to render
  anything **outside** that skip set is a genuine red.
- **`kyverno test` applies only where the repo declares policies.** Green is
  every **applicable** tool passing on the rendered output. A repo that declares
  no policies (nothing under its Kyverno policy tree) has no policy arm, and
  that is a **deliberate state, not a gap** — this plugin's own maintenance
  skill says an absent policy set is never a finding and must not be turned into
  a suggestion to adopt one. Never author policy fixtures here to give that arm
  something to run: authoring them is `kubernetes-policy-triage`'s work, and
  doing it in a fix pass smuggles unrelated content into the story's diff.
- **The anchor for the TOOL SET is `development-kubernetes/skills/maintenance/SKILL.md`,
  not a `*-ci-fixer.md`** — and that difference is deliberate, not an oversight.
  This plugin ships **no** ci-fixer agent, because a manifest repo has no CI
  build to repair; the three tools are named in the maintenance skill instead,
  with `kubernetes-manifest-fixer` and `kubernetes-policy-triage` applying them.
  Do not "correct" this anchor to match the other four profiles. The
  **render-first** half above is *not* that file's rule — it is
  `development-kubernetes/skills/review/SKILL.md`'s, which reviews rendered
  output rather than templates for the same reason this gate validates it.
- **A tool the gate needs that is not installed is not a pass, and it is not
  §3's red either.** That is **any** of `helm`, `kustomize`, `kubeconform`,
  `kube-linter` and `kyverno` — the renderers as much as the validators, since
  the gate's first step needs them and they are as likely to be absent. §3 knows
  two outcomes, so say which one this is: an **absent tool is not green** — do
  not consolidate, do not commit, and do not open a PR on it. It is also not a
  red to fix, because there is nothing wrong with the change; **report the
  absent tool(s) by name and stop** (interactive: tell the user, who may install
  it out of band and have you re-run, or abandon the story). That is a
  halt-and-report, distinct from §3's abandon-the-PR arm. Do **not** install a
  toolchain to get past it: this run does not mutate the machine it runs on.
- **Attribute a finding before you treat it as this story's red.** The gate
  validates rendered output across the repo, so it will surface findings in
  manifests the story never touched. One the **change itself** introduced is an
  in-scope red like any other. One that reproduces on `origin/main` is
  **pre-existing** — report it and **stop** per §3's abandon-and-report; do not
  fix unrelated manifests inside this story's diff, which is the same scope
  creep the policy-fixture rule above forbids.
- **`--gate-attest`: not applicable.** No attestable single-run runner of the
  `run-gate.zsh` shape (#981) ships for this type, so there is no `tree`
  identity to carry into the next round's `--resume`, and the loop re-runs the
  gate each round. Pass no `--gate-attest`: the flag is fail-closed on a
  mismatch, but a value that never came from a green gate is not a mismatch —
  it is a false attestation, and the loop would skip a re-run it never earned.
- **Epic verification (§E4) uses this same render-then-validate gate** — the
  conductor dereferences this heading at both §3 and E4, and E4's bullet list
  names no arm for this type.

## Version bump

This is §4's procedure for this repo type. The conductor keeps the `### 4.`
heading as the anchor its reference files cross-reference; the rule lives here.

**none** — a cluster-definition repo ships no installable plugin content, so
§4's subject does not exist here and the step is a no-op. This heading
supersedes the conductor's generic floor rather than narrowing it: that floor
governs the no-profile case, where the conductor cannot know what kind of repo
it is in. A Helm chart's own `version`/`appVersion` is a property of the change
being made, decided in the manifests themselves — never a manifest edit this
step performs on the side.

Note that this heading is about a **target** repo of type `kubernetes`. The
`development-kubernetes` **plugin** in this family is a different thing, and its
own shipped-slice version rule lives with the claude-plugin profile that governs
edits to it.

## Panel

**`/development-kubernetes:review`** — that skill is the panel, and its agents
under `development-kubernetes/agents/` carry their own severity bars. It is the
same value `review-dispatch.zsh plan` emits as `review_skill` (the script builds
it as `development-${repo_type}:review`), which is what §3.5 actually
dispatches; this heading **records** that, it does not override it.

This profile deliberately states **no** dimension list and **no** bar. Each of
those rules already has exactly one home, with the agent that applies it;
restating them here would mint the second statement that drifts (#1432). Read
them where they live.

## Fix-pass rules

**none** — no kubernetes-specific fix-pass rule has been established. #1502's
read-out is the evidence that would produce one; until it arrives, a rule here
would encode a guess as contract. This position has no dereference site today
either (#1506 decides which of the last three acquire one), so a rule written
here would be one no step is contracted to consult.

## Documentation expectations

**none** *beyond* the conductor's generic §2 same-PR user-docs step (#767),
which applies to every repo type and is not restated here. No
kubernetes-specific documentation duty has been established; #1502's read-out is
where one would come from.

## Residue

**none** — the residue procedure (#1435) in
`development/skills/resolve-issue/reference/residue.md` is repo-type-agnostic:
issue filing, labels and the dossier, with nothing kubernetes-specific in it. If
a type-specific rule ever exists, #1502's read-out is where it would come from.
