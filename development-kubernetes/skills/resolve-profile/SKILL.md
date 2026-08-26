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
  does — **and validate the repo's standalone manifests directly**, since they
  are part of the panel's tree without passing through either renderer, and a
  plain-YAML GitOps repo has nothing else.
- **Render the same SET this plugin's review panel renders — not "everything".**
  `development-kubernetes/skills/review/SKILL.md`'s render step skips a
  documented set (library charts, vendored subcharts, component kustomizations,
  and any root another root consumes); **read the set there rather than
  restating it here.** Those are not optional exclusions: several of them *fail
  by design* when rendered standalone, so a gate that enumerated every chart
  would red on a repo the plugin's own CI renders green — and the model would
  then either abandon a sound story or edit an unrelated chart to make it
  render, which this Gate forbids as smuggled content. A failure to render
  anything **outside** that skip set is a genuine red — **unless the renderer
  itself is absent**, which is the halt below and not a red at all. The two are
  the same observable event (a non-zero `helm template`), so **establish the
  applicable tool set and whether it is installed BEFORE interpreting any render
  failure**; reading `command not found` as §3's red sends a model to abandon a
  sound story, or to edit a chart until it renders, which the bullet above
  forbids as smuggled content.
- **An EMPTY set of gateable documents is not green — it is nothing to gate.**
  Green over zero documents is not a pass, it is a **no-op wearing a pass's
  clothes**: every applicable tool trivially succeeds, the green criterion below
  is satisfied *vacuously*, and a run that reported green there would
  consolidate, commit and open a PR backed by **zero validation evidence**. The
  panel refuses exactly that reading:
  `development-kubernetes/skills/review/SKILL.md` reports
  *nothing to render at all* — and equally
  *nothing in scope rendered* — as explicitly **not applicable**,
  and says such a result is absence of evidence rather than
  positive knowledge that the manifests are clean.

  **The population is the panel's TREE, not "what the render step produced".**
  That tree is rendered chart and overlay output **plus the standalone
  manifests copied in alongside it** — read the composition there, the same
  delegation the skip bullet above makes. A repo of plain YAML with no
  `Chart.yaml` and no `kustomization.yaml` renders nothing and still has a full
  tree of documents `kubeconform` and `kube-linter` validate directly; counting
  render output alone would condemn the commonest Argo CD layout there is. **The
  declared policy tree is in the population too** — `kyverno`'s input is a
  standalone manifest set like any other; what the bullet below says never
  enters the *render set* is a statement about the **render step**, not about
  what this Gate can gate.

  **Two preconditions first — both before either arm, and IN THIS ORDER,
  because an arm reached on a false premise ends a story that should ship and
  the two preconditions end differently.**

  1. **Ask whether the diff carries a deploy-relevant path at all** — a
     manifest, a chart, a kustomization, or a policy. **If it does not,
     neither arm applies:** a README, a workflow or a repo-root script was
     never owed render evidence. Gate what the tools do cover, say so in the
     report, and **proceed** — the panel will report its own not-applicable
     verdict at §3.5, which is where that case is decided. **This one is first
     because it settles the run:** a story that owed no render evidence is
     **not held up by a renderer it never needed**, so precondition 2 is not
     reached at all and its halt cannot fire on a docs-only diff.
  2. **Establish the applicable tool set and whether it is installed** —
     reached only when precondition 1 found something deployable in the diff.
     An absent renderer emits nothing, so a chart-only repo without `helm`
     looks exactly like an empty tree — and the halt below is *clearable*
     (install it and re-run) while these arms are not.
     Take that halt, never an arm.

  **Then the two arms. They share a verdict and differ in what the report must
  tell the human — and in WHERE THE OUTCOME IS DECIDED**, which is a terminal
  and not a report: arm 1 stops here, arm 2 hands off. In both, the applicable
  tools found nothing wrong, so
  **§3's own result stands** — this Gate is not claiming a red. What is missing
  is narrower and is what you report: **the gate produced no evidence about
  this story's change**, so it must not be offered as one. Never report the
  arms as plain green, and never report them as a red to fix.

  - **Repo-wide — the tree is empty.** Subtracting the skips leaves **no
    document at all**: no rendered output, no standalone manifest, no declared
    policy. A repo that is one `type: library` chart, or whose only
    kustomizations are `kind: Component` roots consumed from another repo. What
    counts is what *remained* after the skips, never how many charts or roots
    the repo had before them. Report and stop — the same halt-and-report the
    absent-tool bullet below defines, with **no commit and no PR** — and say
    that the condition is a property of the **repo**: no story of any kind will
    ever produce evidence here, which is why there is no choice to offer.
  - **Change-relative — the tree is non-empty, but nothing in it belongs to
    this change.** The precondition above has already excluded the diff that
    touched nothing deployable, so what reaches this arm is a **deploy-relevant
    change whose output the gate never saw**. It is the panel's *nothing in
    scope rendered*, and the outcome is **not this Gate's to decide**: carry it
    to §3.5 step 2's **NOT-APPLICABLE-on-a-full-round** arm and take the
    terminal named there (autonomous: stop; interactive: its three explicit
    options, one of which does open a PR — reachable because §3's own result
    stands). That list has one home; do not restate it, and do not pre-empt it
    with a stricter halt one step earlier.

  **`belongs to` is the panel's relation, not map-value equality — read it
  there rather than restating it here**, exactly as the skip set is read there.
  Two consequences worth naming because getting them wrong inverts the arm: a
  `values.yaml` or overlay-patch edit on a **live** chart **does** belong (the
  changed file shares the chart or root with the rendered document's source,
  and consumption is transitive), and a **deleted** path that *was* a manifest,
  a chart root or a kustomize root — or lived under one — is always in scope.
  Bare equality would fire the change-relative arm on the commonest change
  there is.

  **Take that second one from the panel's rule, not from its headline.** The
  panel bolds *A DELETED path is always in scope* and then closes the
  enumeration further down: a deleted path that was **none** of those and
  lived under none — a repo-root script, a workflow file, a README — is treated
  exactly like an existing path that belongs to no rendered document. Reading
  the headline alone makes this summary one-directionally **permissive**, and
  that is the direction with no backstop: at §3 the panel reports its own
  verdict and catches the misreading, but **at E4 no panel is dispatched at
  all**, so a deleted workflow read as in-scope declines the change-relative
  arm, surfaces no regression, and lets E5 close on zero validation evidence.

  **A diff whose only deploy-relevant paths are policies belongs by the same
  reading**: `kyverno test` over the declared fixtures **is** its evidence.

  **Neither arm is cleared by re-running**, unlike the absent-tool halt below
  (which clears when someone installs the tool). The repo-wide arm is a
  property of the repo and the change-relative arm of the diff, so say what the
  human can actually do — a repo that is one library chart, or only
  `kind: Component` roots, can never land *any* deploy-relevant story through
  this pipeline, and the options are to resolve it outside the pipeline or to
  bring the affected manifests into the gateable set (an unconsumed root). Do
  not leave a reader to re-run into the same stop.
- **`kyverno test` applies only where the repo declares policies.** Green is
  every **applicable** tool passing over **the panel's tree** — the rendered
  output *and* the standalone manifests validated directly — with the anti-no-op
  arm above in force, so zero applicable tools over an **empty tree** is never
  a way to satisfy it **when the diff carried a deploy-relevant path**. That
  qualifier is the **deploy-relevant-path precondition's**, not a loophole (the
  name, not the number — from outside the precondition list a reorder rots a
  numeral and leaves the pointer aimed at the halt, which is why every
  cross-reference here names the test; the numerals *inside* the list are the
  list's own and stay): a docs-only diff was never owed
  render evidence, so there is no vacuum to refuse and §3's own result stands —
  without it this clause and that precondition license opposite actions on one
  run, and a README fix in a library-chart-only repo is abandoned by whichever a
  model reads second. Say *tree*, not *rendered output*: on a plain-YAML repo
  there is no rendered output at all, and a criterion whose subject is empty is
  satisfied by a `kubeconform` failure nobody read. A repo that declares
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
  §3's red either.** ***Needs* is the operative word, and it is scoped by the
  repo's own markers — a tool this repo never selects is not a missing tool.**
  Within the applicable set the rule covers `helm`, `kustomize`, `kubeconform`,
  `kube-linter` and `kyverno` alike — the renderers as much as the validators,
  since the gate's first step needs them and they are as likely to be absent.
  Outside it there is nothing to halt over: applicability is decided by the same
  markers the bullets above already use, **read against the render set that
  SURVIVES the skips, never against the repo's raw file list** — `helm` where a
  **non-skipped** `Chart.yaml` remains to render, `kustomize` where a
  non-skipped, unconsumed `kustomization.yaml` does, and `kubeconform` +
  `kube-linter` wherever anything remains in the tree to validate. **`kyverno`
  is the one exception to that rule**, and it is an exception rather than a
  counter-example: its input is the declared **policy tree**, which never enters
  the render set at all, so it is selected by the repo declaring policies.

  **A chart or root inside the skip set never selects its
  renderer**, so a repo whose only `Chart.yaml` is a `type: library` chart needs
  no `helm` even though the file exists. So a kustomize-only repo with no `helm`
  on the machine, and a policy-free repo with no `kyverno`, are both gated
  normally; halting on either
  would abandon a story this gate could have taken green, which is the same
  false stop the `kyverno`-has-no-arm bullet above already refuses. §3 knows
  two outcomes, so say which one this is: an **absent tool is not green** — do
  not consolidate, do not commit, and do not open a PR on it. **This halt is
  reached only once the diff carried a deploy-relevant path**, the reciprocal of
  the deploy-relevant-path precondition above: a docs-, workflow- or
  script-only change was never owed render evidence, so an absent tool **in the
  applicable set** does not halt it. This bullet states the carve-out too,
  because a reader can enter here without passing through that precondition. It is also not a
  red to fix, because there is nothing wrong with the change; **report the
  absent tool(s) by name and stop** (interactive: tell the user, who may install
  it out of band and have you re-run, or abandon the story). That is a
  halt-and-report, distinct from §3's abandon-the-PR arm. Do **not** install a
  toolchain to get past it: this run does not mutate the machine it runs on.

  **At E4 that terminal is spelled differently, because none of §3's
  prohibitions has a referent there.** The conductor dereferences this heading
  at E4 too, where there is nothing to consolidate, no commit and no PR — so
  "do not open a PR" is vacuous and a model reading only the §3 wording finds no
  regression, takes E4's *otherwise* branch and lets E5 close the epic on an
  absent tool. It does not: **halt E4, report the absent tool(s) by name, and do
  NOT close the epic** — the shape E4 already uses for `detect`'s exit 1 and
  exit 3.
- **Attribute a finding before you treat it as this story's red.** The gate
  validates the panel's tree across the repo, so it will surface findings in
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
- **Epic verification (§E4) uses this same render-then-validate gate, and needs
  nothing beyond it** — the conductor dereferences this heading at both §3 and
  E4. **The reason is positive, not an inference from E4's silence.** E4's
  **Java / Python app** bullet asks for an end-to-end exercise on top of the
  suite because such a repo ships a runnable artifact whose children can
  integrate badly; a GitOps repo ships **no runnable artifact at all** — no
  binary, no service, nothing to start — so there is nothing that exercise could
  be run against. The only way to exercise these manifests for real is to put
  them on a cluster, and **the family's GitOps position forecloses doing that
  from here**: ARCHITECTURE.md's *Deployment — GitOps promotion and immutable
  references* (#1189) makes the infrastructure repo the only path to a cluster,
  and that path is a **reviewed pull request plus an Argo CD sync** — never an
  ad-hoc apply from a resolve run, which would put an unreviewed state in the
  cluster and answer "why is this running?" with a CI transcript instead of
  `git log`. It is the same rule as the absent-tool bullet's *this run does not
  mutate the machine it runs on*, one layer out. So the rendered-and-validated
  output *is* this type's epic evidence rather than half of it. **Do not reach
  for #1206 here** — that gate reads an *application* repo's workflow text, and
  `detect-stack` deliberately withholds it from the IaC path (an IaC repo is the
  one place a cluster write belongs), so it forbids nothing about this repo and
  citing it would invite a model to check, find it inapplicable, and conclude the
  exercise is owed after all. Do **not** read the absent E4 arm as the licence
  either: the `go` and `swift` profiles call that same absence "an absence,
  **not a licence**" and they are right — what licenses this verdict is the
  repo's shape, which those types do not share.

  **Two things about this heading at E4, and both are needed or it misfires on
  every kubernetes epic.** First, **every diff-shaped test in this heading asks
  about *this change***, a phrase with no referent at E4, which runs after all
  children
  merge and has no story branch and no story diff. At E4 the
  changed-path set is the **union of the epic's children's merged diffs**; read
  **every one of them** against that, never against a working tree that is
  identical to `main`. There are four today — the deploy-relevant-path
  precondition, the change-relative arm, the absent-tool bullet's
  *reached only once the diff carried a deploy-relevant path*, and the
  **finding-attribution** bullet — and the count is
  written as "every", not as a closed list, because a fifth added later would
  otherwise inherit no basis at all, which is exactly how the third acquired
  none.

  **The fourth needs one thing more than a re-based changed-path set, because
  its comparison inverts rather than emptying.** It attributes by asking whether
  a finding reproduces on `origin/main` — and by E4 `origin/main` *carries every
  child's diff*, so a regression a child introduced reproduces there **by
  construction** and reads as pre-existing. Re-basing alone does not reach that:
  the other three ask about the changed-path SET, which the union supplies,
  while this one asks about a BASELINE, and the union is not one. So at E4
  attribution is decided against the epic's **pre-epic baseline** and
  **never against `origin/main`, which by E4 already carries every child's
  diff**. Spell that baseline as the commit on `main` immediately **before the
  epic's first child merged** (`git rev-parse <first-child-merge>^`) —
  **not as a merge-base against that child's branch**, which this family's
  squash merge deleted, leaving `git merge-base` no second argument and a model
  no baseline
  but the one this sentence bans. Were attribution read against
  `origin/main` instead, a `kube-linter` red on a `securityContext` a child
  dropped would be written off as nobody's, E4 would surface no regression,
  and E5 would close the epic on the very regression it introduced.

  **That does not discard the union — it stops being the test and becomes an
  input.** The union survives as the **changed-file list** that `belongs to`
  reads in attribution case 2 below, which is the shape that relation is
  defined over. Dropping it along with the path test would leave `belongs to`
  nothing to be relative to, and case 2 no readable condition at all.

  **Attribution has three outcomes here, not two**, because `main` moves under a
  long epic — and they are decided **in the order written**, stated rather than
  implied because a three-outcome list whose order a reader must infer is the
  defect this heading is repairing. **Read the baseline first, and consult
  `belongs to` only for a finding the baseline did not already place.** They
  are **attribution cases**, never "arms": this heading numbers two **empty-set
  arms** above — repo-wide and change-relative — and every later *unqualified*
  mention of an arm means those two. (The qualified ones above — §3.5's
  NOT-APPLICABLE arm, the policy arm, §3's abandon-the-PR arm — name themselves.)

  **Derive `<first-child-merge>` before anything else, because every case reads
  it.** Take each child's merge commit (`gh pr view <child-pr> --json
  mergeCommit`), order them by **commit date**, and use the **earliest** — first
  by merge time, never the lowest issue number, which on an out-of-order epic
  yields a baseline that already carries other children's diffs.

  **Every child must yield a merge commit.** If any child's `mergeCommit` is
  null, or its PR cannot be identified, the earliest of the *rest* is not a
  pre-epic baseline — it may already carry the unresolved child's diff, so every
  regression that child introduced would read as pre-existing. That is an
  unresolvable baseline: take the halt below, naming the child that did not
  resolve, and never derive the baseline from the children that did.

  **One gate run yields many findings, and they sort into different cases.**
  Sort every one of them, and keep the two halves apart. **Every finding's own
  filing action is performed whatever the others reached** — case 2's issue
  against the epic, and an independent issue per case-3 finding. **Only the
  run's OUTCOME takes the strictest terminal:** a single case-2 or
  unattributable finding halts E4 and leaves the epic open, however many others
  sort to case 1 or 3, and the E4 report lists all three groups. Collapsing the
  two would drop case 3's filing on every mixed run — the unfiled report that
  case 3 exists to refuse.

  Decide *present on the baseline* with §3's own verb: **re-run this
  render-then-validate gate at the pre-epic baseline commit**, in a scratch
  worktree rather than by checking that commit out in the epic's tree. A
  finding that **reproduces** there is present on the baseline; one that does
  not is absent from it. Nothing here turns on whether a *file* existed.

  **The baseline run is a REPRODUCTION PROBE, not a verdict**: its
  preconditions, its two empty-set arms and their E4 terminals do **not** fire
  there — only reproduction is read off it. A baseline whose gateable tree is
  empty after the skips — the ordinary shape when the epic's children added the
  repo's **first** chart, overlay or manifest set — produced **no findings**, so
  every finding of the E4 run is absent from it. That is neither a fired arm nor
  an unresolvable baseline; read either way, a fully delivered epic is halted
  and left permanently open. Only a baseline run that cannot be **run to
  completion** is unresolvable, per the closed condition below.

  **Two findings are the same finding when the same tool reports the same check
  against the same rendered object** — kind, namespace and name — **produced
  from the same SOURCE ROOT**, which you resolve through `render-map.json`
  rather than read off the rendered path. Never match on the rendered path
  itself: a child renaming a template, a chart directory or an overlay changes
  it without changing the finding, so where the union shows a root was renamed,
  the old and new names are the same root. Matched by path, a pre-existing
  finding looks absent from the baseline the moment a child renames anything,
  and then sorts to case 2: an epic halted and blamed for a lint failure it
  inherited. **The source root is what keeps two roots apart**, too — a repo
  rendering the same kind, namespace and name from `clusters/a/` and
  `clusters/b/` has two distinct findings, and identity blind to the root would
  read a child's new one on the second as the first's pre-existing twin.

  1. **Present on the pre-epic baseline** — genuinely pre-existing: report it and let E5 close,
     **whether or not a child touched what it fires on**. That
     trailing clause is the whole reason the baseline is read first: a child
     editing one line of a Deployment does not thereby adopt every finding that
     Deployment already carried.
  2. **Absent from the baseline, and it `belongs to` a source a child changed** —
     the epic's **own** regression:
     **halt E4, file an issue for it, and do NOT close the epic**, the same shape
     as the absent-tool halt's E4 terminal above and the arms' below.
  3. **Absent from the baseline, and belonging to nothing the epic changed** — it
     arrived on `main` from work outside this epic while the epic ran.
     **File it as an INDEPENDENT issue, name that issue in the E4 report, and let E5 close** —
     never as the epic's own and never with the epic's residue
     labelling. *Report it* has no other destination at E4: there is no PR and
     no §3.5, so an unfiled report ends the run with a real regression on
     `main` and no owner. Closing here is what keeps a delivered epic from
     sitting permanently open on a stranger's regression, the done-but-open
     miss this heading refuses below.

  **Cases 1 and 3 NARROW the conductor's E4 rule, and say so here because the
  conductor states it unqualified.** Its *file it — the epic stays open until
  that regression is handled* governs the epic's **own** combined effect, which
  is case 2. A finding the baseline places **outside** the epic is **reported
  (case 1) or filed as an independent issue (case 3)**, and the epic closes;
  holding it open would strand delivered work on a regression no child caused,
  which nothing in the flow ever clears.

  **They narrow E5's *only after E4 is green* the same way**, since a case-1 or
  case-3 run reaches E5 with a finding reported and the gate not green on any
  plain reading. **E4 is green FOR CLOSURE PURPOSES when every finding it
  surfaced sorts to case 1 or case 3 and each case-3 finding has been filed.**
  Only a case-2 finding, an unattributable one, or a fired arm makes it
  not-green. Without that, a model consulting E5's precondition declines to
  close and produces the done-but-open epic both documents call the flow's most
  common miss.

  **`belongs to` in attribution case 2 is the panel's relation — read it there
  rather than restating it here**, exactly as the change-relative arm above
  delegates it, and with that relation's transitive reading intact: narrowing
  it to a shared chart or root here would be the second copy this Gate
  refuses, and would drop the consumed-base case the panel calls load-bearing.
  Read the **relation** there, and not the panel's neighbouring
  *deletion-widens-the-whole-tree* clause: that one binds `{SCOPE}` for a
  dispatch, never belonging for a finding, and imported here it would put every
  finding on any epic where a child deleted a manifest into case 2.

  What is E4-specific is a **resolution step, not a belonging test**, and it is
  **not universal**. A finding from `helm template` / `kustomize build` output,
  or from the copied standalone tree, names a path in the **render tree** rather
  than the repo: resolve it through `render-map.json` to its source before
  applying the relation. **Run the E4 render in the panel's own render-step
  layout so that map exists** — at E4 no panel is dispatched, so nothing else
  writes it. A `kyverno test` finding is the exception that proves the scope:
  the declared policy tree never enters the render set, so such a finding
  **already names its repo path** and the relation applies to it directly.
  **A finding the baseline placed as ABSENT that resolves neither way is
  unattributable: it takes the halt below, and NEVER case 3** — whose closing
  terminal would otherwise absorb every finding the map failed to explain. (A
  finding case 1 already placed is closed there; this never reaches back for
  it.) The one belonging question the panel
  does not answer is the
  **cross-object red** — `dangling-service`, `dangling-ingress`,
  `non-existent-service-account` — which belongs to a child that changed
  **either endpoint**: the object it dangles from, *or* the referring object's
  own file, where a child may have authored the reference itself. Only where a
  child changed **neither** endpoint does such a red fall to case 3.

  **Two distinct things take this halt: a baseline that cannot be resolved, and
  a finding that resolves neither through the map nor by naming its own repo
  path.** Both are unattributable, and neither takes the report — **but only
  where there is a finding to attribute at all.** A **green** E4 gate has none,
  **so an unresolvable baseline is no halt there and that epic closes**; keying this
  on the baseline alone would strand a fully delivered epic that produced no
  finding. Where there IS one:
  **halt E4, report the unattributable finding and whichever of the two fired
  — why the baseline could not be resolved, or why its path resolved to no
  source — and do NOT close the epic**; do not file an issue against a finding
  you could not attribute. Only the halt is recoverable: a human resolves the
  baseline and re-runs, while an epic closed on its own regression is reopened
  by nothing this flow does.

  **Unresolvable is a closed condition, not a list of two.** No first child
  merge is identifiable; the history was rewritten under it; **or the gate
  cannot be run to completion at that commit** — a renderer error, chart
  dependencies that no longer resolve, a policy set `kyverno` rejects at that
  revision. **Any state in which reproduction at the baseline cannot be DECIDED
  is an unresolvable baseline**, and
  **a baseline run that errors out is NEVER read as producing no findings**:
  read that way, every pre-existing finding looks
  absent from the baseline, and one firing on a path a child touched takes case
  2 — halting a delivered epic and filing an issue that blames it for a finding
  it did not introduce.

  **Like the absent-tool halt, this one is reached only once the union carried
  a deploy-relevant path** — the reciprocal of the precondition above, stated
  here because a reader can enter at this paragraph without passing through
  it. On an epic whose children touched nothing this gate validates there is
  nothing to attribute at all, so an unresolvable baseline is no halt there
  either: that epic closes by the precondition's own rule below.

  Getting either of those first two diff-shaped tests wrong fails in a
  different direction, which is why both are named: the change-relative arm
  read against an identical tree fires every time and halts
  every epic (noisy but safe), while the **deploy-relevant-path precondition
  read against it concludes nothing deployable changed and says *proceed*** —
  on an epic whose children may have rewritten every manifest in the repo, so
  E4 surfaces no regression and E5 closes on zero validation evidence. That is
  the permissive failure this heading exists to refuse. Second, **neither ARM's
  terminal has a referent at E4** — the repo-wide arm's is §3-shaped and the
  change-relative arm's is a hand-off to §3.5, while at E4 there is nothing to
  consolidate, no commit, no PR, and **no §3.5 at all**: the conductor says
  outright that the Epic flow never reaches it. So at E4 **either arm** means
  one thing:
  **halt E4, report which arm fired, and do NOT close the epic** —
  the same shape as the absent-tool halt's own E4 terminal above, and as
  `detect`'s exit 1 and exit 3. **For the ARMS specifically**, reading their §3
  wording literally leaves no prohibition with a referent, so a model would
  surface no regression, take E4's *otherwise* branch and let E5 close on zero
  validation evidence — the vacuous green this whole heading exists to refuse,
  arriving one step later, which is why their E4 terminal is spelled out here.

  **The deploy-relevant-path precondition is deliberately NOT swept into that
  halt.** Once it is read against the union (above) it fires only on an epic
  whose children genuinely touched nothing this gate can validate — a docs-,
  workflow- or script-only epic. Nothing was owed, so there is no missing
  evidence to halt over: report that no child touched anything this gate
  validates, and **let E5 close the epic**. Halting there would strand a fully
  delivered epic permanently open with no remedy — no re-run, no repo change
  and no §3.5 ever clears it — which is the done-but-open epic the conductor
  calls this flow's most common miss, and the same false stop this Gate refuses
  at §3.

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
