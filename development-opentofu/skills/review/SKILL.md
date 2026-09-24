---
name: review
description: Perform a comprehensive OpenTofu/Terraform review using two specialized parallel agents — security and module structure. Gates on tofu validate first (a tree that does not validate fails the round; an unreachable provider registry degrades to a source-only review), reads the whole .tf tree, and reports only against changed files.
disable-model-invocation: false
---

# OpenTofu review

## Step 1 — the pre-dispatch gate

Before dispatching anyone, run the gate over the **source repository root** —
but only once Step 2's scope check has found an OpenTofu source in scope,
existing or deleted. A change with none is **not applicable** whatever state the
tree is in: a tree already broken on `main` must not fail a README-only story.
A standalone run, which has no changed-file list, always runs the gate.

    "<skill-base-dir>/scripts/tofu-review-gate.zsh" --repo <repo root>

It copies the tree into a scratch work dir (`tofu init` writes `.terraform/`
and a lock file wherever it runs, and a review must never move the tree it
reviews), then runs `tofu init -backend=false` and `tofu validate` in every
root module, and `tflint --recursive` when tflint is installed. It prints one
JSON document — `verdict`, `roots`, `validated`, `source_only`, `failures`,
`notes`, `tflint`, `work_dir` — and its exit code carries the verdict. **Three
outcomes, kept distinct:**

- **`tofu validate` FAILS → the round FAILS** (exit `10`, `verdict: "failed"`).
  Name the failing root module and the file its diagnostics point at, write the
  gate's document to the sibling `<findings-path>.failed.json`, and write
  **nothing** to the findings path — it is array-only by contract. A tree that
  does not validate is the one most worth reviewing, and reviewing it anyway
  would record a complete two-dimension review over a broken scope. The same
  holds for a `tofu init` that fails for a reason **other** than reaching the
  registry — a missing local module, an unknown provider: that is the tree's own
  defect, and the gate reports it as a failure with `step: "init"`.
- **`tofu init` cannot reach the provider registry → DEGRADE** (exit `0`,
  `verdict: "degraded"`). The offline or local run: the affected roots are
  listed in `source_only`, and the round proceeds as a **source-only review**
  and can succeed. Report the gate's `notes` to the caller and put them in the
  agents' prompt, so the review states what it could not check. `init` is the
  gate's only network-touching step — fine in CI, but failing the round on it
  would make every offline review round impossible. `tofu` not being installed
  at all degrades the same way, with its own note.
- **Both pass → the FULL review** (exit `0`, `verdict: "full"`).

**`tflint` absent degrades with a note, never fails a round** — the gate adds
the note and leaves the verdict alone, so a tree that validates still gets the
full review. So does a `tflint` that is installed but could not run. When it
did run, its output is at `tflint.output_file`: pass that path to the agents —
it is a tool run the gate actually made, so a finding quoting it reports an
observed verdict, not a modelled one.

**Exit `2` is your own malformed invocation** — fix the command and re-run.
**Exit `1` is an internal failure** (a tool the gate needs is missing, the copy
or the module search failed): report its stderr and report the round as
**failed** — never read an empty stdout as a clean gate.

`verdict: "empty"` means the repository has no non-pruned `*.tf` or
`*.tf.json` at all. When the changed-file list holds a **deleted** OpenTofu
source, that is the story tearing the last of it down: dispatch the deletions as
Step 2 describes, telling the agents no tree remains to validate. Otherwise
there is nothing to review, so report the round **not applicable** (below)
rather than dispatching two agents over nothing.

Remove the gate's `work_dir` whenever the round ends — failed, not applicable,
or after Step 4 — as long as the gate printed one; the tflint output the agents
read lives in it until then.

## Step 2 — scope, then dispatch

Dispatch two agents **in parallel**:

| Dimension | Agent |
|---|---|
| security | `opentofu-security-reviewer` |
| module | `opentofu-module-advisor` |

That is the whole panel. `opentofu-format-fixer` and `opentofu-policy-triage`
are **not** panel members: they are maintenance-routed, dispatched by
`/development-opentofu:maintenance` to fix `format`/`lint` and triage
`policy`/`policy_tests` findings, and they edit files — a review panel reports
and never edits. There is no approver dimension and no third agent: a human
approves infrastructure.

**Read the WHOLE tree, report against the changed files.** The agents read
the entire non-pruned `.tf` tree — every directory outside `.terraform/`,
`node_modules/`, `vendor/` and `.git/`, the same prune set as #1160's detection
recipe — **regardless of what `$ARGUMENTS` scopes**. Scope narrows what is
*reviewed*, never what is *read*: both reviewers make **absence** claims (no
lifecycle rule, no provider pin, no `terraform { encryption { … } }` block) and
must confirm them against the whole tree before reporting. The pin lives in an
unchanged `versions.tf` and the encryption block in an unchanged backend file
often enough that a scope-only read would file false blocking findings.

**The review scope** is the changed **OpenTofu sources** — `*.tf`, `*.tf.json`,
`*.tfvars`, `*.tfvars.json` and `.terraform.lock.hcl` outside the pruned trees.
A changed path that no longer exists and was one of those is **in scope**, as a
**deletion**: a deleted resource or output changes what gets provisioned, and
its effects land on unchanged files (a caller still reading a removed output),
which the whole-tree read is what lets the reviewers see. List deleted paths in
`{CHANGED FILES}`, marked as deletions.

**Then check the scope is worth reviewing, before dispatching anyone.** When a
changed-file list exists and **no** changed path — existing or deleted — is an
OpenTofu source, the change produced nothing this panel can see (a README, a
workflow, a policy file). Do not dispatch: two agents would each read nothing
in scope, each correctly emit `[]`, and Step 4 would write a clean aggregate for
a change no agent reviewed. Report the round **not applicable** to the caller,
with the detail in `<findings-path>.failed.json` and **nothing** written to the
findings path — except on a loop-driven **delta** round, where the
NOT-APPLICABLE half writes `[]` instead; see *On a loop-driven DELTA round*
below. The FAILED half is unchanged on every round.

**A standalone run has no changed-file list**, and the not-applicable check is
then vacuous — read literally it would report every standalone run as not
applicable. In that mode the scope is every non-pruned OpenTofu source in the
repository, only `verdict: "empty"` makes the round not applicable, and a
non-empty tree always dispatches.

**The no-argument fallback is for a standalone invocation only.** When the
**review loop** drives this panel (`/development:resolve-issue` §3.5), the
scope it hands you is a round's `changed_files` — and from round 2 on that is
the *delta* since the previous round, which can legitimately be empty (#1434).
An empty scope from the loop is never a licence to review the whole tree: that
is exactly the independent-repeat behaviour delta scoping removes. If you are
invoked by the loop with nothing in scope, say so and review nothing — but
still write `[]` to this round's findings file **when the round is a delta
round** — an instance of the delta rule below, carry precondition included. An
empty scope on a **full** round means the *story diff itself* is empty and is
decided by the FULL paragraph below instead.

**On a loop-driven DELTA round that carries NOTHING, every NOT-APPLICABLE shape
writes `[]`** — an empty scope, and a non-empty scope holding no OpenTofu
source (the previous round's fix pass edited only a README). Nothing that
provisions moved **since the previous round**, so write `[]` to the findings
path and put the detail in `<findings-path>.failed.json`. A panel that writes
no file at all is refused as `STALE_FINDINGS`, and re-running this same panel
over this same scope reproduces the same verdict. `[]` costs nothing there: the
loop cannot converge on a delta round, so at worst it promotes the closing
sweep.

**"Carries nothing" is a precondition, not a detail — check it before you write
`[]`.** The plan's `fix_verification_path` names the previous round's blockers,
and a delta round claims two things: that nothing that provisions moved since
the previous round, *and* that the previous round's fixes landed. The carve-out
covers only the first. So when the plan names a `fix_verification_path` holding
**at least one** entry, this round is never a bare `[]` — **dispatch the agents
anyway** with the carry, so they can confirm the carried fixes against the files
named in each entry. There is no second path: without an agent observation
nothing can be confirmed or re-raised, so every entry would be unconfirmed and
the loop would refuse the round. For each carried entry the agents report ONE
of: confirmed (the file:line where the fix is), re-raised (the file:line and the
unchanged text observed still present, as a finding), unconfirmed (you could not establish either).
Never re-raise on the absence of a fix. An unconfirmed entry
goes into the report only, never into the findings file; the loop, not you,
decides what a carried entry nobody confirmed or re-raised means (#1583).

**Report the triple whenever the carry is non-empty** — say in your report that
you confirmed N carried entries, re-raised M and left K unconfirmed, of TOTAL —
**whatever you write to the findings file**, `[]` or otherwise. Omitting it is
treated as a failed round.

**A `null` or unreadable carry on a round ≥ 2 is a caller slip, not an empty
carry.** Read it from the plan's `fix_verification_path` **or, in hook mode,
from `$REVIEW_FIX_VERIFICATION`** (`$REVIEW_ADJUDICATED` carries the waived
list). Only when **neither** names a readable carry: do not write `[]` and do not
write a findings file at all — report that the carry path was absent or
unreadable and that the round could not be verified, naming
`--fix-verification` as what to fix, with the detail in
`<findings-path>.failed.json`. Absence of the carry is never evidence of an
empty one.

**In hook mode, write the accounting too (#1583).** The loop's hook mode reads
the per-entry records behind the triple from `$REVIEW_FINDINGS.carry.json` — an
array of `{file, dimension, title, confirmed[], re_raised[], unconfirmed[]}`
records, one per carried entry, naming the reviewers in the three arrays — and
refuses the round (CARRY-UNACCOUNTED) without it whenever the carry is
non-empty. In step mode the driving session assembles the same records from the
agents' per-entry lines and passes them as `--carry-accounting`.

**On a loop-driven FULL round the not-applicable terminal stands as written —
the empty scope included.** Read the round's `scope_mode` from the dispatch
descriptor rather than inferring it — `"delta"` selects the paragraph above,
`"full"` this one; in hook mode the same value arrives as `$REVIEW_SCOPE_MODE`.
Write **nothing** to the findings path, name the cause in
`<findings-path>.failed.json`, and report not-applicable. `[]` on a full round
is not a clean delta: zero blockers on `scope_mode: "full"` is exactly the
loop's CONVERGED condition, so a story whose diff touches no OpenTofu source
would converge with **no module reviewed at all**. `/development:resolve-issue`
§3.5 step 2 carries the not-applicable-on-a-full-round recovery arm; read it
there rather than from a restatement here.

**A FAILED round keeps the terminal on every round, delta or full**: a gate
that failed, or a dimension that failed twice (Step 3), means the round did not
review what it was supposed to. Write **nothing** to the findings path, name
the cause in `<findings-path>.failed.json`, and report the round as failed.
`[]` there would be a fabricated clean round over a dimension nobody ran.

**Report against the CHANGED SOURCE FILE — the findings are otherwise thrown
away.** The `file` field of every finding must be a **repo-relative path to a
file in the changed-file list** — never a directory, and never a path in the
gate's scratch copy. The resolve-issue loop filters the panel's aggregate
through `review-dispatch.zsh scope-findings`, which keeps only findings whose
`file` **exactly matches an entry in the story's diff**. When the flagged text
lives in a file the story did not touch, the finding goes against the
**closest changed file in scope** with `line: null`, saying in the prose that
the attribution is approximate and which unchanged file the text is in.

**A standalone run relaxes that rule.** Run directly
(`/development-opentofu:review` with no orchestrator) there is no diff, no
changed-file list and **no `scope-findings` filter to satisfy** — so `file` is
the concrete repo-relative file the flagged text is in. Say so explicitly by
passing `{CHANGED FILES}` as `none — standalone run`; a reviewer that read the
changed-file rule as absolute in that mode would withhold every finding it has.

When the **review loop** drives this panel from round 2 on, its dispatch plan
also carries `fix_verification_path` and `adjudicated_path`. Bind the two carry
lines below, filling each only when the plan names a **non-null** path for it —
that one test covers a standalone run (no descriptor at all) and round 1 alike.

For each agent, use its name as the `subagent_type` and pass the prompt below,
substituting **all seven** placeholders, plus one line per **non-null** carry
path: `{SCOPE}` (the scope above), `{DIMENSION}` and `{AGENT NAME}` from the
table, `{ROUND}` (the review round; `1` for a standalone run), `{REPO}` (the
**source repository root**), `{CHANGED FILES}` (the changed OpenTofu sources,
deletions marked, or the literal `none — standalone run`), and `{GATE}` (the
gate's verdict, its `validated` and `source_only` roots, every entry of its
`notes`, and the tflint output path when tflint ran — or `not run: carry
verification only, no root validated` on a delta round dispatched only for its
carry, where no OpenTofu source is in scope and so Step 1 ran no gate). `{CHANGED FILES}` is not
decoration: the reviewers hold no `Bash` and cannot derive it, and leaving
`{AGENT NAME}` unbound corrupts the `reviewer` field the consolidator keys on.
This is where the machine-readable JSON layer is wired in once, for both agents,
so the reviewer definitions stay pure prose:

    Review scope: {SCOPE}
    Source repository root: {REPO} — read the WHOLE non-pruned .tf tree under it (everything outside .terraform/, node_modules/, vendor/ and .git/) before reporting any absence; the scope bounds what you report on, never what you read.
    Changed source files in scope: {CHANGED FILES}
    Pre-dispatch gate: {GATE} — a "degraded" verdict means the roots listed as source-only were NOT validated: say so wherever a finding depends on it, and never claim tofu validate passed for them.
    Fix verification (round >= 2): {FIX VERIFICATION} — the previous round's blockers. Confirm each one actually landed BEFORE looking for anything new. For each carried entry report ONE of confirmed / re-raised / unconfirmed, as one line keyed by the carry's own spelling — carried entry "<title>" (<file>, <dimension>): confirmed at <file:line> | re-raised (see finding) | unconfirmed — re-raising ONLY what you observed still present, at its ORIGINAL severity, citing the carried entry and the file:line plus the unchanged text in the findings file, even when its file is outside this round's scope; never re-raise on the absence of a fix. A re-raise is a finding whose file, dimension and title are the carried entry's own spelling (title verbatim) and whose line is the carried line or null, with what you observed in its description — under a different title it is not matched to the carry and the round is refused. Re-raise only carried entries of your own dimension ("{DIMENSION}", which the identity includes); an entry of another dimension that you see still present is reported unconfirmed, with what you saw in prose. End your report with the triple: carried: confirmed N / re-raised M / unconfirmed K of TOTAL.
    Already waived (round >= 2): {ADJUDICATED} — suggestions earlier rounds surfaced and the human waived. Do not re-raise them as Suggestions, EXCEPT in a file the PREVIOUS ROUND'S FIX PASS touched (on a delta round that is this round's scope; on a closing full sweep that NO fix pass preceded the set is empty, so withhold them — but on a sweep the residue promotion earned, a fix pass did run, so the exemption applies as on any round). A genuinely blocking re-raise at CRITICAL/WARNING is always allowed.

    Analyze the OpenTofu sources in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

    Your evidence rule's "the tree you were told to read" is, for a `decides:` command, the source repository root above ({REPO}). The command must be READ-ONLY there: `tofu fmt -check`, `tflint --chdir=<dir>` and `conftest test` qualify; `tofu init`, `tofu validate` and `tofu plan` do NOT — init writes .terraform/ and a lock file into the tree — so a claim that needs them is reported as a suspicion in prose with no decides: line.

    Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.

    `file` MUST be one of the changed source files listed above — never a directory, and never a path under the gate's scratch copy: a downstream filter keeps only findings whose file exactly matches a changed path, so anything else is silently discarded and your finding is lost. When a changed-file list IS given and the flagged text lives in a file this story did not touch, do NOT report the unchanged file: report it against the closest CHANGED file in scope with line: null, and say in the prose that the attribution is approximate and which unchanged file the text is actually in. When the changed-file list is `none — standalone run`, that filter does not exist: report the concrete repo-relative file the flagged text is in, and never withhold a finding for want of a list. Either way, if you cannot tie a finding to any file at all, report it against the closest file in scope with line: null and say the attribution is approximate; reporting nothing is worse than reporting it approximately. A re-raise of a CARRIED entry is the one exception to all of the above: it keeps the carried entry's own file, dimension and title verbatim even when that file is not in the changed-file list (#1583).

Without this block the panel's findings cannot be consumed by
`consolidate-findings.zsh` or the resolve-issue review loop — ARCHITECTURE.md
makes injecting it the *review skill's* job precisely so no reviewer definition
has to carry the boilerplate.

## Step 3 — collect

Wait for both agents. **An agent that fails is not an agent that found
nothing.** If one errors, returns no fenced `json` block, **or returns a block
that is not a JSON array** (invalid JSON, or a single finding *object*),
re-launch it once; if it fails again, report the round as **failed** and name
the dimension.

**Do not write the findings path on a failed round.** It is array-only by
contract, and only one of its consumers rejects a non-array loudly:
`review-dispatch.zsh scope-findings` iterates a status object's values and
prints `[]`, and `consolidate-findings.zsh` coerces it into one bogus
`SUGGESTION` — so a status object there produces a clean or near-clean round
over a dimension that failed. Write the durable detail to the **sibling**
`<findings-path>.failed.json`, where nothing parses it as findings, and report
the failure to the caller — a missing dimension silently waived is a blocker
shipped.

## Step 4 — aggregate

When both dimensions complete, concatenate their two JSON arrays into one array
and write it to the findings path the caller passed (default
`review-findings-round-<round>.json`), then reproduce it inline under a
`## Findings (JSON)` heading. This is the file `consolidate-findings.zsh` and the
resolve-issue loop read. On a **degraded** round, also report the gate's notes
beside it, so the caller sees which roots were reviewed from source only.

On a round whose carry is non-empty (#1583), report the triple — `carried:
confirmed N / re-raised M / unconfirmed K of TOTAL` — as **per-entry union
outcomes** over the two agents (an entry is confirmed if either agent confirmed
it, else re-raised if either agent's re-raise is in the findings array, else
unconfirmed; TOTAL is the number of carried entries, never a sum across
agents), and **reproduce each agent's per-entry lines verbatim** beneath it —
they are the source of the accounting records the driving session assembles.
