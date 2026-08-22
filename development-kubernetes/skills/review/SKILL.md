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
render job the #1154 template ships (chart-owned trees, kustomize inputs).
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
describe one relation — build only unconsumed roots, the same rule the CI job's
second pass applies. **Same rule, wider net there**: the CI pass reads every
list entry in a consumer's kustomization rather than these three keys, so a base
referenced only from `patches:` counts as consumed in CI and not here. Do not
restate the two as identical. The first three FAIL by design when rendered standalone, so
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
`<findings-path>.failed.json` and **nothing** written to the findings path —
except on a loop-driven **delta** round, where the NOT-APPLICABLE half writes
`[]` instead; see *On a loop-driven DELTA round* below. The FAILED half is
unchanged on every round.

**The second shape applies only when a changed-file list exists.** On a
standalone run there is none, so "no document maps back to any changed file" is
vacuously true — read literally it would report *every* standalone run as not
applicable and dispatch nobody, a review command that never reviews. In that
mode only the empty-tree shape gates: a non-empty tree always dispatches.

**The no-argument fallback is for a standalone invocation only.** When the
**review loop** drives this panel (`/development:resolve-issue` §3.5), the scope
it hands you is a round's `changed_files` — and from round 2 on that is the
*delta* since the previous round, which can legitimately be empty (#1434). An
empty scope from the loop is never a licence to review the whole temp tree: that
is exactly the independent-repeat behaviour delta scoping removes, and the
in-diff findings it produced would be consolidated as the round's result. The
loop's caller is required to re-plan or stop rather than run a panel over an
empty delta, so if you are invoked by the loop with nothing in scope, say so and
review nothing — but still write `[]` to this round's findings file **when the
round is a delta round** — an instance of the delta rule below, carry
precondition included, not a competing one. An empty scope on a **full** round
means the *story diff itself* is empty and is decided by the FULL paragraph
below instead.

**On a loop-driven DELTA round that carries NOTHING, every NOT-APPLICABLE shape
writes `[]`** — not just the empty scope. Scoping the carve-out to the empty
delta alone leaves the commonest delta shape uncovered: a round whose delta is
*non-empty* but maps back to no rendered document, because the previous round's
fix pass edited only a README, a workflow, or a doc page. Nothing that deploys
moved **since the previous round**, so all three not-applicable shapes (an empty
scope, nothing to render at all, nothing in scope rendered) write `[]` to the
findings path and put the detail in `<findings-path>.failed.json`. A panel that
writes no file at all is refused as `STALE_FINDINGS`, so the round cannot be
consumed at all — and one of the driving session's recovery arms is to re-run
this same panel over this same scope, which reproduces the same verdict. And `[]`
costs nothing there: the loop cannot converge on a delta round, so at worst it
promotes the closing sweep.

**"Carries nothing" is a precondition, not a detail — check it before you write
`[]`.** The plan's `fix_verification_path` names the previous round's blockers,
and a delta round claims two things, not one: that nothing deploy-relevant moved
since the previous round, *and* that the previous round's fixes landed. The
carve-out covers only the first. So when the plan names a `fix_verification_path`
holding **at least one** entry, this round is never a bare `[]` — the gate fires
before dispatch, so writing one would retire those blockers without a single
agent confirming them, and the loop would then record `verify-<R+1>.json` as
`[]`, dropping the carry chain for good and narrating the carried blockers as
fixed. Instead, either **dispatch the agents anyway** with the carry (the tree
renders; they can confirm the carried fixes against the source files named in
each entry, which is what the carry duty already asks of them), or write a
findings array that **re-raises every carried blocker you could not confirm, at
its original severity, citing the carried entry**. `[]` is correct when the carry is
`[]`, and also when you dispatched with the carry and the agents positively
confirmed every carried entry landed while finding nothing new. The rule forbids
a `[]` that skipped the verification, not one that passed it.

**Report the count whenever the carry is non-empty** — `say in your report that
you confirmed N carried entries` — **whatever you write to the findings file**,
`[]` or otherwise. A round that confirms the carry and *also* finds new blockers
still owes it; omitting it is treated as a failed round.

**A `null` or unreadable carry on a round ≥ 2 is a caller slip, not an empty
carry.** Read it from the plan's `fix_verification_path` **or, in hook mode,
from `$REVIEW_FIX_VERIFICATION`** (`$REVIEW_ADJUDICATED` carries the waived
list) — a hook-mode panel sees no dispatch descriptor at all, so treating a
null `fix_verification_path` as decisive there would declare every hook-mode
round's carry absent when the loop had in fact passed one. The terminal fires
only when **neither** names a readable carry; then it means
`--fix-verification` was omitted, an easy and silent slip. You cannot enumerate what to re-raise and have no entry to
cite, so do not write `[]` and do not write a findings file at all: report to
the caller that the carry path was absent or unreadable and that the round could
not be verified, naming `--fix-verification` as what to fix (the detail goes in
`<findings-path>.failed.json`, as for any failed round). Absence of the carry is never
evidence of an empty one.

**On a loop-driven FULL round the terminal stands as written — for all THREE
not-applicable shapes, the empty scope included.** Read the round's `scope_mode`
from the dispatch descriptor rather than inferring it — `"delta"` selects the
paragraph above, `"full"` this one; in hook mode the same value arrives as
`$REVIEW_SCOPE_MODE`. A full round whose scope is empty means the story diff
itself is empty, which is not a clean review of anything. (`"full"` is round 1, a `--final` re-plan, and
the promoted closing sweep, but that enumeration is the gloss, not the test.) Write **nothing** to the
findings path, name the cause in `<findings-path>.failed.json`, and report
not-applicable to the caller. `[]` on a full round is not a clean delta: zero
blockers on `scope_mode: "full"` is exactly the loop's CONVERGED condition, so a
story whose diff touches only an excluded chart's `values.yaml` would converge
and open a PR with **no manifest reviewed at all** — verbatim the outcome this
gate exists to block. The unbounded-loop worry does not apply here either:
`/development:resolve-issue` §3.5 step 2 carries a **not-applicable-on-a-full-round**
recovery arm of its own, separate from the FAILED one — it says the verdict is
not fixable, forbids re-running the panel, and names the forward path (report;
autonomous, stop; interactive, three explicit options). That list has one home;
read it there rather than from this restatement.

Note also what shapes 2 and 3 actually establish. An empty scope (shape 1) is
positive knowledge that nothing changed; "nothing to render" and "nothing in
scope rendered" only mean the change produced nothing **this panel can see** —
absence of evidence. That is a fair basis for "no manifest moved since last
round" and not for "the story's manifests are clean".

**A FAILED round keeps the terminal on every round, delta or full**: an empty
temp tree *after render errors*, or a dimension that failed twice, means the
round did not review what it was supposed to. Write **nothing** to the findings
path, name the cause in `<findings-path>.failed.json`, and report the round as
failed. `[]` there would be a fabricated clean round over a dimension nobody
ran, and the loop would consolidate it as the round's real result.

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

When the **review loop** drives this panel from round 2 on, its dispatch plan
also carries two paths — `fix_verification_path` and `adjudicated_path` — and
the reviewers must be told about both. They are the point of a delta round, not
decoration: the first is the only way a fix that silently did not land gets
re-raised (a delta round cannot re-derive it), and the second is what stops the
panel re-litigating what the human already waived. Bind the two extra
placeholders below, filling each line only when the plan names a **non-null**
path for it — that one test covers both cases you would otherwise reason about
separately: a standalone run has no descriptor at all, and on round 1 the loop's
own caller passes no `--fix-verification`. (Don't read it as "omit both on round 1": the
loop's own `plan` call passes `--adjudicated` on every round, so a loop-side
descriptor may name it from round 1. The driving session's round-1 plan does
not — and either way the non-null test gives the right answer.)

For each agent, use its name as the `subagent_type` and pass the prompt below,
substituting **all seven** placeholders, plus one line per **non-null** carry
path the plan names (up to nine on a loop-driven round ≥ 2):
`{SCOPE}` (the scope above),
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
    Fix verification (round >= 2): {FIX VERIFICATION} — the previous round's blockers. Confirm each one actually landed BEFORE looking for anything new, and re-raise any you cannot confirm at its ORIGINAL severity, citing the carried entry — even when its file is outside this round's scope. Say in your report how many of them you confirmed landed, whatever else you find.
    Already waived (round >= 2): {ADJUDICATED} — suggestions earlier rounds surfaced and the human waived. Do not re-raise them as Suggestions, EXCEPT in a file the PREVIOUS ROUND'S FIX PASS touched (on a delta round that is this round's scope; on a closing full sweep that NO fix pass preceded the set is empty, so withhold them — but on a sweep the residue promotion earned, a fix pass did run, so the exemption applies as on any round). A genuinely blocking re-raise at CRITICAL/WARNING is always allowed.

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
