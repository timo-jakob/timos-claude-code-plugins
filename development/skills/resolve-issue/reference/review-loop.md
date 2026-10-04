# Review loop — the round protocol

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

It carries §3.5's round protocol, including the loop's invocation
template.

Every `<!-- moved: … -->` block below is byte-identical to the text it was
carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit, and is what keeps this file honest.

**Two regions are outside that proof**, and both are NEW prose the gate does not
check. The text between `<!-- /moved: round-protocol-head -->` and
`<!-- moved: round-protocol-tail -->` is #1582's reviewer-path rule — the gate
proves only that no *original* line migrated into it, by asserting the two
anchors stay adjacent in the pinned commit. And **everything after
`<!-- /moved: round-protocol-tail -->`** is unproven too: the #1571 correction, the #1485 empty-story-diff note,
the #1805 fix-pass rule pointer, *Topic panels* (#1072), *The decided pass* (#1584), *The risk pass*
(#1921), *Carry accounting* (#1583), *Selected gates for delta rounds* (#1973),
*Round subagents* (#1935) and the #1226 `loop_args` note all live there,
because a byte-frozen span cannot be edited and those rules had to correct or
extend what it says. Edit either region knowing the byte check does not cover
it.

## The round protocol

<!-- moved: round-protocol-head -->
**The round boundary is concurrent — one minted tree, two readers (#1497).**
The full-suite gate and the reviewer panel are both **readers** of the working
tree, so the boundary starts them together instead of making the panel queue
behind the gate. Nothing about the gate changes: the whole suite still runs on
every round that applied a fix, a red gate still blocks consolidation, and a
round is still consolidated only against a tree a green gate proved. What
changes is that the panel no longer waits for it — worth roughly
`min(gate, panel)` per round, about ten minutes a round across the #1435
session's fifteen rounds.

The ordering, and it is the whole of it:

1. **Mint the tree identity once**, before either activity starts. This one
   value is what both attestations will name:

   ```bash
   T=$("<skill-base-dir>/scripts/git-tree-id.zsh" .) || T=
   [ -n "$T" ] || { echo "could not mint a tree identity — report and stop" >&2; exit 1; }
   ```

   `git-tree-id.zsh` prints **nothing** and exits non-zero when it cannot
   compute an identity, and its contract is that callers **fail closed** — hence
   the `exit 1` rather than a bare `echo`, whose zero status would let the
   boundary carry straight on. An unmintable `T` is a **report-and-stop**, never
   a restart: it is neither a red gate nor a moved tree, and carrying the empty
   value forward would silently disarm `--gate-attest` while aborting the loop
   on `--findings-tree`.

2. **Start the gate out of band**, so that it runs without blocking the panel —
   the same `<full gate>` command §3 runs. **This step says what the launch must
   guarantee, and deliberately not how to write one**: four properties, and the
   shape to reproduce is the `--detach` block of
   `development-claude-plugin:test`'s `run-headless.zsh` — **a shape reference,
   never a runner you hand the gate to.** That script only ever launches
   `claude -p`, which the gate must never be: passing `<full gate>` as its
   `--prompt` would make the round's verdict a headless model run's exit status
   rather than the suite's, and §3.5's own first hard rule forbids exactly that.
   Reproduce the shape; do not invent a third one, and do not re-derive a recipe
   here.

   - it **survives the turn that started it**. A harness background command may
     stand in, but only where it is documented to outlive the turn *and*
     re-invoke the session when it exits — **verify that; never assume it**:
     `development-claude-plugin:test` records the opposite for Claude Code's
     Bash `run_in_background` (#811: killed the instant the turn ends,
     SIGTERM-ing the child mid-run);
   - it **signals completion only once the verdict is complete**, and the
     signal is cleared before the launch. A payload that doubles as the signal
     can be read half-written — the redirection creates the file before
     anything is in it — and a signal that survives a boundary restart is last
     round's answer to this round's question; both land on step 5 as a verdict
     no gate gave. Either separate the two, or rename a fully-written payload
     into place. The signal means *finished*, **never** *green*;
   - it **records the verdict where step 5 can read it**: the gate's **exit
     status** on every stack, plus `run-gate.zsh`'s JSON summary where
     `<full gate>` **is** `run-gate.zsh` — the only stack that emits one, which
     is why step 5's `tree` arms are scoped the way they are;
   - it is **killable — by a handle that stops the SUITE, not merely whatever
     launched it.** Record that handle beside the signal. A pid naming a
     supervisor whose child keeps running does not satisfy this, and it is the
     easy mistake: the reference shape prints its *wrapper's* pid, so a
     reproduction has to make the recorded handle reach the process actually
     running the suite. Step 3 has nothing else to work with, because deriving
     anything from the handle is banned there.

   Two of these the reference shape does **not** demonstrate, and reproducing it
   naively reproduces the gaps: its marker doubles as the exit-status file, so
   take from it the detach and the pre-launch clear, not the marker's dual role;
   and its printed pid is the wrapper's, per the property above.

   Everything it writes goes **outside the repo**, as the work-dir and findings
   files already do: a byte landing under the worktree between step 1's mint and
   the gate's own hashing is step 7's drift, every round.

   The wait itself begins after step 3, not here.
   **How to wait** (this section) governs the wait — it is not restated here.
3. **Plan and dispatch the panel** (the *Each round* panel step below) against
   that same tree, while the gate is still running. **If that step refuses or
   aborts the round** — an unreadable carry, a non-zero `plan`, a FAILED panel,
   an empty `"full"` scope — **stop the gate using the handle step 2 recorded**,
   rather than waiting on it: a second gate started over a live one
   oversubscribes the host, and a byte the abandoned suite writes lands after
   the next mint. **Never derive something to kill from that handle** — on a
   plain background detach the handle's process group is the driving session's
   own, and killing it takes down the run. On a round where step 2 was skipped
   there is no handle and nothing to stop. Do not reuse the gate's result. Then
   take **that arm's own recovery**, which this step never overrides: several
   are report-and-stop, and stopping is the whole recovery. Only where the
   recovery **resumes** the round — a re-planned `plan`, a re-run panel after a
   fixed FAILED cause, a return from §2 — resume at step 1 here, since the tree
   may have moved meanwhile. **Unless step 2 was skipped and the recovery did
   not move the tree**: there the round is still a no-fix round, so re-dispatch
   against the same held `T` and mint nothing — a fresh mint would forfeit the
   held `--gate-attest`, which is the self-attestation the invariant forbids.
4. **Observe the gate's completion before consolidating** — wait for step 2's
   signal, **with a generous bound** (a full suite runs minutes, not hours),
   then read the verdict it recorded. What is banned is a poll that runs **while
   the panel could have been running**: that spends the overlap this boundary
   exists to buy. A gate whose signal **never arrives**, or whose recorded
   verdict cannot be read, is neither green nor red: stop it with step 3's
   handle, do **not** consolidate, and **report and stop** — never read a
   missing verdict as step 5's empty-`tree` arm. Never consolidate a gate that
   has not returned.
5. **Green** → consolidate (the *Each round* loop-invocation step below),
   passing `--findings-tree "$T"`. Whether `--gate-attest "$T"` rides along is
   decided by what the gate **reported**, in four arms:
   - a **plugin repo** whose `<full gate>` **is** `run-gate.zsh` and reported a
     `tree` — the only stack that reports one — additionally requires that
     `tree` to equal `T`, and passes `--gate-attest "$T"`;
   - a plugin repo whose `<full gate>` is **compound** — `run-gate.zsh` plus
     anything else as one command — consolidates on green with
     `--findings-tree "$T"` and **omits `--gate-attest` entirely**, whatever
     `tree` the embedded `run-gate.zsh` reported: the four rules' first rule
     governs, and a match would skip the whole compound including the parts
     that run never executed;
   - a plugin repo whose reported `tree` is **empty** is `run-gate.zsh`'s
     documented degradation, not drift (it blanks the field when it cannot
     compute one). Consolidate on green, pass `--findings-tree "$T"`, **omit**
     `--gate-attest` so the loop runs its own gate — #981's fail-closed
     direction, unchanged — and relay its stderr note where it printed one;
   - **every other stack emits no `tree` at all**, so green alone is the
     condition and `--gate-attest` is **omitted entirely**, per the four rules
     below.
6. **Red** → the round is **not** consolidated and **neither** attest is passed.
   Fix the red (§3's rule is unchanged: green is the precondition, and you
   abandon and report if you cannot get there), which moves the tree, and
   **restart this boundary from its step 1**: this round's panel findings
   describe the superseded tree and are **discarded**. That discard is the one
   cost of the overlap, and it is agent tokens rather than wall-clock — the red
   had to be fixed either way, and the next round's panel reads the fixed tree.
7. **Green on a REPORTED tree that is not `T`** — reachable on a plugin repo
   only, and only when a `tree` was actually reported (an empty one is step 5's
   documented-degradation arm, not this). Also **not** consolidated and no attest passed, but
   there is no red to fix: something moved the tree between the mint and the
   gate's own hashing. `git-tree-id.zsh` resolves `.` to whichever repo contains
   the gate's cwd, so the usual causes are a gate started in a **different**
   worktree or outside the repo entirely, a `--work-dir` or
   `findings-round-R.json` written **inside** the repo, a gate that writes
   (below), or a killed gate still flushing. Fix the cause and restart this
   boundary **once**; a second drifted green is **reported, and you stop** —
   never a third restart, which would spend the round budget on discarded panels
   with nothing to fix.

**Two kinds of round take a different boundary, and both are stated here rather
than qualified into each step.**

- **No fix pass ran since the last boundary** — the zero-blocker closing-sweep
  promotion (the *Each round* `AWAITING_FIX` step below) and the
  **findings-file** recovery re-invokes (missing/empty, byte-identical, alias).
  The tree has not moved: mint nothing and **skip steps 2 and 4** — there is no
  gate to start and none to wait for. **Step 3 still applies on the
  closing-sweep promotion**: its full-diff panel is the whole point of that
  promotion, and skipping it would consolidate a full round with no findings
  file — which the loop refuses, or which tempts a session into authoring `[]`
  and converging on a sweep nobody reviewed. Only the findings-file recovery
  re-invokes skip it too — but only those whose aggregate really is intact (an
  alias, a wrong path re-passed, a byte-identical file that exists). A
  missing/empty refusal caused by a panel that **never ran** takes step 3 like
  any other round, per that recovery's own arm. Then consolidate as at step 5,
  passing `--findings-tree "$T"` **and**, on a plugin repo whose `<full gate>`
  **is** `run-gate.zsh`, the held `--gate-attest "$T"` — the previous round's
  green gate proved that exact `T`, which is the re-run #981's attest-skip
  exists to remove. **Nothing is held unless that boundary actually passed one**:
  a compound `<full gate>` omitted it (step 5's compound arm), and so did an
  **empty reported `tree`** (step 5's documented-degradation arm) — in both
  cases this round omits it too, since the four rules license `T` only once a
  gate reported green on that same `T`, which a blanked field never did.
  Step 5's reported-tree arms do not apply at all, because no gate ran this
  round. **The CADENCE refusal is not one of these**: it
  fires *because* the tree moved, so it re-mints `--findings-tree` and holds
  `--gate-attest`, per the invariant below.
- **The `<full gate>` SUITE writes into the tree** — a suite that regenerates a
  fixture, or a compound `--test-cmd` with a fixing step inside it. Fixing
  `pre-commit` hooks are **not** this case: §3 runs them before the mint, and
  they are never part of `<full gate>`. A write *after* the mint moves the
  tree out from under `T`, so run the gate **first** and mint `T` once it has
  **settled** — on every stack, plugin repos included. Do **not** take
  `run-gate.zsh`'s reported `tree` there: it is captured *before* the suite
  runs, on the documented assumption that the suite is read-only, so on a
  writing gate it names a pre-write tree the panel never sees, and every round
  would be refused by the cadence guard. Dispatch the panel against the
  post-settle mint. The serial boundary — correct, and merely slower. `T` is
  still fixed before the panel reads anything, so the invariant holds; step 5's
  equality check no longer **gates** consolidation and step 7 does not fire. On
  a **compound**
  `<full gate>` `--gate-attest` is **omitted entirely** — the four rules' first
  rule governs, and a tree match would let the loop skip the whole compound
  including the parts the attested run never executed. It rides along only where
  `<full gate>` **is** `run-gate.zsh` and its reported `tree` happens to equal
  that post-settle mint — omitted otherwise, #981's fail-closed direction.

**At a round boundary the attestation pair is the invariant.** `--gate-attest`
and `--findings-tree` name the **same minted tree, minted before both** the gate
and the panel start. A value re-minted after either has run matches the working
tree trivially and certifies nothing — the self-attestation #981 and #1435 §10
each forbid. This needs no new flag and no new script: it is an ordering over
the two flags that already exist. **Outside a boundary the two legitimately
differ.** The cadence-refusal recovery re-mints only `--findings-tree`; there
you re-pass the **held** `--gate-attest` (it mismatches, so the loop re-runs the
gate, which is correct) or omit it — never pass the fresh mint as
`--gate-attest`, which would skip a gate that never ran on the post-fix tree.
That is the one recovery the *no fix pass ran* case above excludes.

**How to wait — end the turn (#1513).** Once the boundary has dispatched — the
gate started out of band, the panel's agents spawned — there is nothing left for
this turn to do, so **end it**. Every reviewer's result arrives as a harness
notification that re-invokes you, and the harness queues them, so the boundary
resumes when the last one lands. **The gate is not one of these**: step 2 puts
it out of band, so its completion is the file case below, collected by the one
bounded call where the boundary says to observe it. A turn that has
dispatched and has nothing else to do **ends**: it does not run `date`, `sleep`,
`echo`, `git status` or any other heartbeat to hold itself open, and it does not
schedule short wake-ups to poll work the harness already tracks. That
busy-poll is not hypothetical — on the #1497 session it took **366 of 1 159
assistant turns and 235M of 658M input tokens**, a third of each, spent
learning nothing, and the run then hit the weekly limit mid-round. The one
sanctioned in-turn wait is for a signal the harness does **not** deliver — the
gate's own marker, or another file a process writes — and it is **one bounded
blocking call**: `Monitor`, with a timeout generous enough for the wait the
step that ordered it describes. One call, never one probe per turn. **A call that returns without its signal is not a retry**:
judge by re-testing the condition, never by the call's exit status, and take the
boundary's own signal-never-arrived arm instead of blocking again.

Each round:
<!-- /moved: round-protocol-head -->

**Build each reviewer's scope block from the plan's `scope_abs[]`, never from
`changed_files` alone (#1582).** This governs step 1 below, whose frozen text
says only "scoped to the plan's `changed_files`" — that names the right SET,
and this names the tree those names resolve against. The set is unchanged: apply
the **same `--work-dir` subtraction** step 1 states, to the absolute list, by
dropping every `scope_abs[]` entry whose repo-relative twin sits under the
loop's `--work-dir`; and judge emptiness on that filtered set, exactly as step 1
does.

`changed_files` is repo-relative, and a reviewer that resolves a repo-relative
path against its own cwd reads the ORIGINAL checkout whenever the run is in a
worktree — which is how a repo-root `.claude-plugin/marketplace.json` read from
`main` produced a CRITICAL false positive on the #1558 session.

**First confirm the descriptor describes the tree the STORY was implemented in**
— which is not necessarily your cwd. `plan` reports the roots of the `--repo` it
was handed and cannot know whether that was the right one, so a plan run against
the original checkout reports `original_root: null` and a `worktree_root` naming
`main`, and the sentence below would then tell every reviewer, with full
authority, to read the wrong tree. Compare `worktree_root` against **the
worktree this story's branch is checked out in** — `git worktree list` names it.
(Identified by what it *is*, not by who made it: §1 creates the **branch**, and
the conductor's single-issue flow creates no worktree at all; an epic child's is
created by E3.) Take the arm that applies — the first folds in the case a naive
cwd test gets backwards:

- **`worktree_root` IS the implementation worktree** → proceed, **even when that
  differs from your own cwd**. An epic child runs in its own worktree while the
  invoking session's cwd stays at the original checkout, so a cwd comparison
  reads as a mismatch on a perfectly correct descriptor — and "fixing" it by
  re-planning against your cwd's toplevel points every reviewer at the original
  checkout, which is precisely the #1558 failure this rail exists to prevent.
  Never re-plan against your cwd;
- **`worktree_root` is NOT the implementation worktree** → re-plan against the
  implementation worktree. Re-run the **same** `plan` invocation with only
  `--repo` changed — every other flag unchanged (`--round`, `--prior-tree`,
  `--fix-verification`, `--adjudicated`, and `--final` where it applied). A bare
  `plan --repo <worktree>` defaults `--round` to 1, so `scope_mode` comes back
  `"full"` at exit 0 with no error anywhere — the round ≥ 2 guard cannot fire on
  a round of 1 — and the panel reviews the whole story diff on an iteration
  round, the independent repeat step 1 forbids; the dropped
  `--fix-verification` additionally makes every panel refuse the round. Then
  **re-confirm `worktree_root` and `round` on the new descriptor** before
  building the scope block.

Then build the scope block, giving **both spellings of every file** — the
repo-relative name the finding must carry, and the absolute path to read:

```text
Review scope (the scope block) — read the absolute path; report each finding's
`file` under the repo-relative name beside it:
  development/skills/resolve-issue/scripts/review-dispatch.zsh
    -> /abs/path/to/<worktree>/development/skills/resolve-issue/scripts/review-dispatch.zsh
```

Both, not either: a block of `scope_abs[]` alone leaves the prompt with no
repo-relative spelling for the reporting rule below to name, and a block of
`changed_files` alone is the cwd-resolution hazard this whole section exists to
close. One entry breaks that symmetry, and it is the one the example below
shows with a single spelling: a `[DELETED by this story]` entry is the one
exception to "Both, not either" — the absolute spelling names a path nobody can
open, so give the repo-relative name and the excerpt.

Then open every reviewer prompt with these two sentences **verbatim**:

> Read every file you are given under `<worktree_root>`; this run's tree is that
> directory, not `<original_root>`. Report every finding's `file` using the
> repo-relative name shown for it in the scope block — never the absolute path
> you read.

substituting the descriptor's two values. When `original_root` is `null` — the
descriptor names no second checkout to warn about, either because you planned
against a main checkout or because the main worktree is **bare** — emit the
first sentence's **first clause only**, keeping the reporting sentence:

> Read every file you are given under `<worktree_root>`. Report every finding's
> `file` using the repo-relative name shown for it in the scope block — never
> the absolute path you read.

Never render the literal `null` into the sentence. The sentence names **which
tree** paths resolve against; it never widens the round's scope — the scope
block is the whole of what a reviewer reads **for new findings**.

**The carried entries are the one exception, and they need the same treatment.**
From round 2 on each reviewer's first job is to confirm the previous round's
blockers landed, and step 1 requires every carried entry to be accounted for —
confirmed, re-raised, unconfirmed — **even when its file is outside this
round's delta** — so on a delta round that file is, by construction, not in the
scope block. Left there, the two rules collide: a reviewer honouring the
sentence above declines to open it and reports unconfirmed a blocker that was in
fact fixed (every round, so the loop refuses every round as CARRY-UNACCOUNTED
and the run never advances), and a reviewer that opens it anyway has only the
carry's repo-relative spelling and resolves it against its own cwd — the #1558
mechanism, arrived at through the one door this section left open. So give the
prompt a second, clearly-labelled section with the **same both-spellings
treatment**, covering every file named in `<work-dir>/verify-<R>.json`:

```text
Carried entries to verify (the carried section) — read the absolute path;
report under the repo-relative name beside it:
  development/skills/resolve-issue/scripts/review-dispatch.zsh
    -> /abs/path/to/<worktree>/development/skills/resolve-issue/scripts/review-dispatch.zsh
```

**A carried entry whose file no longer exists keeps its place here.** The header
above says to read the absolute path, and the deletion arm below says not to
raise a finding about the missing path — a file in both lists would otherwise
carry those two instructions at once. **Both apply, each scoped to its own
section**: the scope block's covers reviewing the deletion as new work, the
carried section's covers accounting for the blocker, and the two blockquotes
below say so verbatim. It keeps its place because dropping it would silently
retire a blocker nobody confirmed.

**Test the antecedent; do not infer it from which round did the deleting.** The
carried section is built by prefixing every name in `<work-dir>/verify-<R>.json`
with the worktree root, which is a string operation and checks nothing — so
**for every entry, test whether its file exists under `<worktree_root>`, and
take this arm whenever it does not**, whatever round removed it. Keying on *the
previous* fix pass would miss an entry deleted in round R-1 and still unconfirmed
at R+1, which is the same silent retirement by a longer route.

So mark it **`[DELETED by this story]`**, exactly as the scope block does, and
give it the **same excerpt**:

```text
Carried entries to verify (the carried section) — read the absolute path;
report under the repo-relative name beside it:
  development/skills/resolve-issue/scripts/old-helper.zsh   [DELETED by this story]
```

The marking **replaces** "read the absolute path" for that entry — there is no
path to read — and the reviewer **confirms the carried blocker landed from the
excerpt** instead, rooted at the descriptor's tree like every other:

```bash
git -C "<worktree_root>" diff "<base>" -- "<path>"
```

**Say so IN THE PROMPT — the scope block's blockquote is the wrong instruction
here.** That blockquote tells the reviewer to "neither raise a finding about the
missing path nor fail the round on it", i.e. not to question the entry; applied
to a *carried* entry it produces a reviewer that says nothing about a blocker it
was asked to confirm, so the round comes back with fewer confirmations than
carries and no re-raise to reconcile them — the blocker is stalled or retired for
good, which is the harm this arm exists to prevent. Telling only yourself is not
enough, exactly as with the reporting rule. Give the carried section its own
sentence, and scope the scope block's blockquote to the scope block:

> An entry marked `[DELETED by this story]` in the **carried** section has no
> path to open. Where it carries a **diff excerpt**, confirm from the excerpt
> that the carried blocker landed; **re-raise it at its original severity only
> if the excerpt shows the defect still present**, and report it
> **unconfirmed** if the excerpt settles neither. Where it carries the note
> **`exists in neither tree`** instead,
> the file the finding was about is in no tree the round can read: **count the
> entry as confirmed, say so in your count, and do not re-raise it** — spell
> its per-entry line `confirmed (exists in neither tree)`, since there is no
> file:line to name. The scope
> block's *neither raise a finding nor fail the round* rule covers reviewing the
> deletion as new work; it never licenses leaving a carried entry unaccounted
> for.

The two forms are why the blockquote keys on **which of them the entry carries**
rather than on the marking alone. An entry with no excerpt and no note would
leave the reviewer unable to confirm and without evidence to re-raise, so it
reports the entry unconfirmed — every round, on a file that can never come back
— and the loop refuses every round as CARRY-UNACCOUNTED over a blocker the fix
pass legitimately disposed of. Emit one or the other, never neither.

**An empty excerpt is not always a stop.** This rule is stated **once**, here,
and governs **both** sections — the scope block's own sentence says "report it
and stop" without it, and that is the abbreviation, not the whole rule. Apply it
wherever an excerpt comes back empty:

1. **Establish the probe can answer at all** — `git -C "<worktree_root>"
   rev-parse --verify "<base>^{commit}"`, and `git -C "<worktree_root>" rev-parse
   --show-toplevel` must print `<worktree_root>`. Either failing means the
   descriptor's tree or base is wrong, so **no** per-entry verdict below is
   meaningful: report it and stop. This is the only root check the rule needs —
   judge by it, never by how many entries came back one way.
2. **Then, per entry**, ask whether the path exists at `<base>`
   (`git -C "<worktree_root>" cat-file -e "<base>:<path>"`):
   - **absent at `<base>` too** — the file is in **neither** tree, the ordinary
     shape of one **this story created** and a later fix pass deleted (*A fix
     pass subtracts* prefers that disposal). There was never a net change against
     `<base>`, so there is no diff to show: emit the **`exists in neither tree`**
     note in place of the excerpt and **do not stop**. In the **scope block**,
     where the entry is being reviewed as new work rather than confirmed, show
     the deletion instead with a `<prior_tree>`-rooted excerpt — `git -C
     "<worktree_root>" diff "<prior_tree>" -- "<path>"` — which does render it;
   - **present at `<base>`**, excerpt still empty — **that** is the stop. Its
     causes are the scope block's own: the command read the wrong tree, or the
     entry was never a story deletion. Report it and stop.

**Both sections reach case 2's first arm, for different reasons.** The carried
entries come from `verify-<R>.json`, which lists a file whatever became of it.
The scope block's come from `changed_files` — and on a **delta** round that is
`diff-tree <prior_tree> <cur>`, which lists a file that existed at `prior_tree`
and is gone now, i.e. exactly the created-then-deleted shape. Only on a **full**
round is it `diff --name-only <base>`, which cannot list one. An earlier cut of
this rule asserted the scope block was immune; it is immune on full rounds only,
and asserting otherwise would have aborted a healthy delta round.

**A finding's `.file` stays repo-relative** — the same spelling `changed_files`
uses, never an entry from `scope_abs[]`. `scope-findings` filters on that
spelling and silently DISCARDS a finding whose `.file` is absolute, so getting
this wrong costs the whole finding, not just its readability — and a round whose
every finding is discarded reads as zero-blocker, which on a full round is the
`CONVERGED` condition. That is why the reporting rule is **in the prompt** and
not merely stated here: the reviewer writes the value, so the reviewer is who
must be told.

**An entry that does not exist is a file the story DELETED** — `changed_files`
comes from `git diff --name-only`, which lists deletions, so a scope block
provably contains unreadable paths on any story that removes a file. The
reviewer is the party that opens them, so — as with the reporting rule — telling
only yourself is not enough: **mark those entries in the scope block**, and say
what to do with them:

```text
  development/skills/resolve-issue/scripts/old-helper.zsh   [DELETED by this story]
```

> An entry marked `[DELETED by this story]` **in the scope block** is expected:
> review the deletion in the diff excerpt below, and neither raise a finding
> about the missing path nor fail the round on it.

The scoping is load-bearing: the same marking appears in the **carried** section,
where this instruction would be exactly wrong — there the reviewer must still
account for the blocker, from the excerpt, as one of confirmed, re-raised, unconfirmed
(re-raising only what the excerpt shows still present).
That section states its own rule; this one governs the scope block alone.

Hand the deletion's content with it, since the reviewer cannot read a file that
is gone — and **root the command at the tree the descriptor names**, never at
your cwd, for the reason the confirm step above gives:

```bash
git -C "<worktree_root>" diff "<base>" -- "<path>"
```

**An EMPTY excerpt is a stop, not a deletion** — *once the empty-excerpt rule
above has been applied*, which is where the exceptions live. On a **full** round
the deletion is in the diff, so an empty result means the command read the wrong
tree — the cwd hazard again — or the entry was never a story deletion at all. On
a **delta** round it can also mean the file was created and removed inside this
story, which is not a stop; that case is the rule's, not this sentence's.
Do **not** dispatch it marked `[DELETED by this story]`: **in the scope block**
that marking tells the reviewer not to question it, so an empty excerpt beside it
means nobody reviews that file and the round records a clean result over it. (In
the carried section the same marking means the opposite — account for it from the
excerpt — which is why the shared empty-excerpt rule above resolves the two
sections differently.) Re-confirm
`worktree_root` per the step above; if the root is right and the excerpt is
still empty, report it and stop.

Without the marking, a reviewer reports the round FAILED or raises a finding
about a missing file, and step 2's FAILED recovery then re-runs a panel that
fails the same way.

<!-- moved: round-protocol-tail -->
1. **Review panel, in-session.** Get the dispatch plan (`review-dispatch.zsh
   plan`, §#560) and spawn the reviewers of the skill it names in
   `review_skill` via the **Agent tool** (one agent per dimension, visible to
   the user), scoped to the plan's `changed_files` — minus anything under the
   loop's `--work-dir`, which is loop state, never story code. Aggregate their
   findings into one #558-schema JSON array file — the round's findings file.

   **How to wait** (this section) governs the wait — it is not restated here.

   **From round 2 on, `plan` needs flags — and it refuses a round ≥ 2 that
   names neither `--prior-tree` nor `--final` (#1434).** The two carry flags are
   optional to the parser, but they are not alike. `--adjudicated` is genuinely
   optional and a `null` path is benign. Omitting `--fix-verification` on a
   round ≥ 2 is **not**: the descriptor reports a `null` path and every panel
   then refuses the round outright — writing no findings file and naming the
   flag — so the omission costs a full panel run before the round can be
   re-planned.
   Your panel must be scoped the way the loop will consolidate
   the round, so run the loop's own invocation as your baseline — then apply the
   `--final` rule below. The loop reaches the same two `--final` rounds itself
   (for a verification-only round, via its own re-plan), so your plan and its
   plan agree; the rule is what you need in order to scope your panel *before*
   the loop's invocation exists:

   ```bash
   # round 1 — no flags beyond the round; there is nothing yet to iterate on
   "<skill-base-dir>/scripts/review-dispatch.zsh" plan \
     --repo <repo> --base <base> --round 1
   # round R >= 2
   "<skill-base-dir>/scripts/review-dispatch.zsh" plan \
     --repo <repo> --base <base> --round <R> \
     --prior-tree "$(cat <work-dir>/tree-$((R-1)).txt)" \
     [--final] \
     --fix-verification <work-dir>/verify-<R>.json \
     --adjudicated <work-dir>/adjudicated.json
   ```

   The work-dir files above are written **by the loop**. Three are **normally**
   on disk
   before every round ≥ 2: `tree-<N>.txt` (the working-tree identity round N's
   reviewers saw), `verify-<N>.json` (round N-1's blockers, written at the end
   of round N-1) and `adjudicated.json`. The fourth, `.closing-sweep`, is
   absent until a zero-blocker delta round promotes a sweep — and then
   **persists for the rest of the run**, since a sweep that finds blockers does
   not end it. So read its **content**, never its mere existence: it means
   "this round is the closing sweep" only when it holds **this** round's number.
   A marker naming an earlier round means the sweep already happened and this
   round is ordinary. Neither its absence nor a stale number is a broken
   work-dir. A missing or blank
   `tree-<R-1>.txt` IS an error: it means the loop never ran round R-1, so
   report it and stop.

   **Read the carry before you plan ANY round ≥ 2**, not only when the delta
   turns out to be empty. `jq length` on `<work-dir>/verify-<R>.json`: if it is
   **absent**, **zero-byte**, or does not print a non-negative integer, it is an
   **unreadable carry** — report it and stop. Both causes are orthogonal to
   whether the delta is empty (a `--resume` into an older work-dir predating
   that write; a run killed in the write's truncate-then-fill window), so on a
   NON-empty delta round the empty-delta branch below never runs and nothing
   else would catch it. Planning the round anyway names a `--fix-verification`
   path you could not read: the panel gets a carry it cannot enumerate, re-raises
   nothing, and the loop then writes `verify-<R+1>.json` from this round's
   blockers alone — the carry chain gone for good. **Never plan a round with a
   carry path you have not successfully read.**
   **Never synthesize a prior tree** — computing one from the current tree
   yields an empty delta and a panel that reviews nothing.

   **A non-zero `plan` exit is never a scope.** The call is as fallible as the
   file read above — you hand-build it, including `$(cat <work-dir>/tree-<R-1>.txt)`
   — and it has three documented failures:

   - **exit 2** is your own malformed invocation (an empty value, a dangling
     flag, a `--round` that is not a non-negative integer of at most 18
     digits). Fix the command and re-run it, the same rule §0a applies to its
     own script;
   - **exit 1** is an internal failure (an unresolvable `--base` or
     `--prior-tree`, a failed `jq` or stack probe). Report its stderr and stop;
   - **exit 3** prints a **typed error object** on stdout (`unsupported_repo_type`,
     or an ambiguous repo type) and names no panel. It is the same condition the
     loop reports as `ESCALATE_AMBIGUOUS` — report it and stop.

   Exit 3 is the trap worth naming twice: its stdout *parses as JSON*, so a
   descriptor read that only checks "did I get JSON?" sails past it with
   `review_skill` and `changed_files` null. In none of the three cases may you
   derive `changed_files` yourself or pick a panel by inspection — a
   `git diff <base>` substitute is a **full** scope on a delta round, the
   independent repeat this whole section exists to remove.

   **Pass `--final` in exactly two cases, and never otherwise:**

   - **this round is the closing full sweep** — `<work-dir>/.closing-sweep`
     holds this round's number (the loop writes it, and the zero-blocker
     `AWAITING_FIX` in step 3 is the same signal). The loop passes `--final` on
     its own `plan` call for that round whether or not you do; if you don't,
     your panel is scoped to a delta that is **empty** (the sweep applies no
     fix), so it reviews nothing while the loop records a full-sweep round with
     zero blockers and converges — the safety net silently becoming a no-op;
   - **this round is a verification-only round** — the plan came back
     `scope_mode: "delta"` with `scope_empty: true` while blockers are carried
     (below). Re-plan it with `--final` so the carried blockers are actually
     checked against the whole story diff.

   **`changed_files` is the round's scope, and what it MEANS varies by round.**
   `scope_mode` says which — read the field rather than inferring it:

   - **`"full"`** — the whole story diff against `--base`. That is round 1, the
     closing full sweep, and a verification-only round you re-planned with
     `--final`.
   - **`"delta"`** — every intermediate round: exactly what the previous
     round's fix pass changed. Review that, and **do not** re-read the rest of
     the story diff: a round that re-reviews everything is an independent
     repeat, not an iteration, which is what let round 9 of the #687 run
     produce 49 blocking findings and zero Criticals.

   **A `"full"` plan with `scope_empty: true` is not a round to review either,
   and it is a different problem.** The scope of a full round *is* the story
   diff, so an empty one means the implementation produced nothing. Do not spawn
   a panel, and do not write `[]` — go back to **§2 (Implement)** and write the
   code, then take this round's boundary again — *The round boundary is
   concurrent* (§3.5) — which mints `T`, starts the gate and re-dispatches this
   round's panel together; do not gate to green first. Or, if the story
   genuinely needs no code change, say so and stop. The loop will refuse
   such a round rather than converge it (`STALE_FINDINGS`, naming the full
   round), so there is nothing to recover by re-running the panel: this is the
   verdict all six panels emit as *the story diff itself is empty*, and its
   recovery arm is in step 2.

   **A `"delta"` plan with `scope_empty: true` is not a round to review.**
   Nothing changed since the previous round, so there is nothing for a panel to
   look at. Judge that emptiness on the set you will actually hand the panel —
   `changed_files` **after** the `--work-dir` subtraction above — not on
   `scope_empty` alone. The two agree whenever the work-dir is outside the repo
   or git-ignored, which this section already requires, and the loop itself
   judges on the filtered set; keying on the raw flag would send you to spawn a
   panel over nothing on the one wiring that section forbids. Two cases, split by **how many blockers `<work-dir>/verify-<R>.json`
   carries** — `jq length` on it, not whether the file exists or is non-empty:
   the loop writes that file at the end of every round, storing `[]` when the
   round had no blockers, so for any work-dir this loop version created it is
   normally present and non-empty — and you have already read it, because the
   precondition above required that before this round was planned at all. An
   **absent or zero-byte** carry, or a `jq length` that is not a non-negative
   integer, is **not** "carries none": it is the unreadable carry that stopped
   you there (the loop treats absent and zero-byte identically, `! -s`), and it
   never reads as 0 — the loop's own round-start fallback only rebuilds
   it after your panel has already run.

   - **carries blockers** — a verification-only round. **Re-plan with
     `--final`** and review the whole story diff, so the carried blockers are
     actually checked. (In step mode the loop keeps this a delta round either
     way — it cannot converge, and a clean result promotes the closing sweep.
     What `--final` changes is what your panel *reads*: without it the panel
     sees an empty scope and the carried blockers go unverified for another
     round.)
   - **carries none (`[]`)** — **check `<work-dir>/.closing-sweep` first.** If
     it holds this round's number, this is the promoted closing full sweep and
     the empty delta is expected: re-plan with `--final` and run the full-diff
     panel (above). Stopping here would abandon the run one round short of
     convergence, and skip the very sweep this story exists to add.

     If the marker does **not** name this round, do not read that as "nothing
     to review" either. An empty carry means the previous round found **zero
     blockers**, and such a round is either full — which would have CONVERGED
     and ended the run — or a delta round, for which the loop *writes* the
     marker. So in a healthy run the marker naming this round is the only
     reachable state: its absence means it was lost after that round was
     recorded, or the `--resume` adoption clamp ignored it (a resume passing a
     smaller `--max-rounds` than the run that wrote it, or an unreadable
     marker — the loop says so on stderr). **Recover, don't stop**: restore
     `<work-dir>/.closing-sweep` holding this round's number, or re-invoke with
     the `--max-rounds` the marker was written under, and re-plan the round with
     `--final`. Stop only when you cannot establish that the previous round was
     a zero-blocker delta round. The loop's own refusal message names the same
     recovery — never invent a code change just to move the tree.

   Two carries ride in the plan from round 2 on, and the reviewers must be
   **told about both** — they are the point of the delta, not decoration:

   - **`fix_verification_path`** — the previous round's blockers. Each
     reviewer's first job is to confirm those fixes actually landed, before
     looking for anything new. **Say what to do when one did not:** a fix that
     did not land, or that the reviewer cannot confirm landed, must be
     **re-raised at its original severity**, citing the carried entry, *even
     when its file is outside this round's delta* — a delta round cannot
     re-derive it, so silence here converges the run with the blocker unfixed.
     **And tell each reviewer to report how many carried entries it confirmed
     landed** — on any round whose carry is non-empty, whatever it writes to the
     findings file, `[]` or otherwise. Step 2 refuses a round that does not
     account for every carried entry, so asking for the count belongs to the
     dispatch, not to the recovery.

     **You get one count per reviewer, and the round's count is their UNION.**
     A carried entry is confirmed when **at least one** reviewer says so; the
     round's count is `|union| of M`. A reviewer silent about the carry
     contributes zero confirmations — it does **not** fail the round on its own,
     since the entry may be outside its dimension. What fails the round is a
     carried entry that no reviewer confirmed **and** no reviewer re-raised.
   - **`adjudicated_path`** — suggestions earlier rounds already surfaced and
     the human already waived. **Do not re-raise them as Suggestions — except
     in a file the PREVIOUS ROUND'S FIX PASS touched**, where new code has just
     been written and a same-titled observation may be genuinely new. Key it on
     the fix pass, not on the round's scope: on a **delta** round the two are
     the same set, and on a **closing full sweep that NO fix pass
     preceded** (the zero-blocker promotion) the fix-touched set is empty — so
     there, withhold every waived suggestion. On a sweep the RESIDUE promotion
     earned, a fix pass did run, so the exemption applies as on any round.
     That exemption is an *instruction*, not a footnote: in
     step mode the panel reads `adjudicated.json` as the previous round left it,
     before the loop drops the entries whose file the fix pass touched, so a
     reviewer that withholds one there kills a finding nothing downstream can
     restore. And if one is genuinely *blocking* on this round's code, raise it
     at `CRITICAL`/`WARNING` and say what changed — a re-raise above Suggestion
     level is never suppressed, and withholding it would converge the run with a
     Critical nobody reported.
2. **One loop invocation.**

   ```bash
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <work-dir> --status-file <status.json> --issue <N> \
     --findings-file <findings-round-R.json> \
     --test-cmd '<full gate>' [--resume] [--gate-attest <T>] \
     [--findings-tree <T>]
   ```

   **`--findings-tree` on EVERY step-mode invocation — round 1 included.** It is
   the identity your panel READ, and it is what arms the cadence guard (step 3
   states the invariant and the failure it prevents). Omitting it is not an
   error — the guard is fail-quiet — which is exactly why it has to be in the
   template: a run that leaves it out has the rail silently off while looking
   identical to one that does not.

   **Round 1 is the round that needs it most, not least.** A fresh round is a
   FULL round, where zero blockers *is* the `CONVERGED` condition — so a session
   that runs the panel, edits, then invokes would exit 0 and open the PR on a
   review of a tree that no longer exists. There is no `--resume` there to hang
   the habit on, which is precisely why it is stated here:

   ```bash
   T=<the round boundary's single guarded mint, §3.5 step 1>
   # …start the gate, run round 1's panel, write findings-round-1.json…
   resolve-story-loop.zsh … --findings-file <…> --findings-tree "$T" \
     --gate-attest "$T"   # plugin repos only — omit on any other stack
   ```

   `T` is the round boundary's single mint (above), not a second one, and it
   is minted through that step's fail-closed guard rather than bare. Re-pass
   the SAME value unchanged when recovering from a
   **findings-file** refusal (missing/empty, byte-identical, alias): nothing
   moved the tree there, so the held identity still matches. **On the CADENCE
   refusal it depends which recovery you take**, because the tree is what moved:
   if you **re-run the panel**, the held value can never clear it — mint a FRESH
   identity before that panel runs. If instead you **discard the fix** that moved
   the tree, the tree is back to what the panel read, so re-pass the SAME held
   value and mint nothing (minting there would be the self-attestation banned
   below). See that arm in the list below.

   **Never mint it just before the `--resume`.** An identity computed after the
   panel — or after a fix pass — matches the working tree trivially and turns the
   guard into a self-attestation that certifies nothing, defeating it on the one
   ordering it exists to catch. Mint it *before* the gate and the panel start,
   and hold it. This is the same trap `--gate-attest` names for the gate, and the
   reason both flags carry one `T`.

   `<full gate>` is the same whole-suite command as Step 3. On a **plugin repo**
   that is the blessed single-run parallel gate — `--test-cmd 'zsh
   <skill-base-dir>/scripts/run-gate.zsh --tests-dir tests'` (#980) — never a
   bare `bats` invocation that a later step would re-run to count.

   `--resume` from round 2 on. On a `--resume` invocation the loop runs
   `--test-cmd` — the **full** suite (unit **and** integration), never a
   subset (#604) — FIRST, deterministically gating the previous round's
   in-session fix: red exits `ERROR` (1), the same "red after a fix aborts"
   rule as ever — **unless** a matching `--gate-attest` (below) proves that run
   redundant, in which case the loop skips it (and only it).

   **`--gate-attest` — one full-gate run per round, not two (#981).** On a
   `--resume` the session has *just* run the full gate green in Step 3 (right
   after applying the previous round's fix). Passing the `tree` identity from
   that green `run-gate.zsh` (Step 3, above) as `--gate-attest <T>` lets the
   loop **skip** its own `--test-cmd` run **when — and only when — that identity
   still exactly matches the working tree**, killing the byte-identical
   duplicate that dominated the #976 session (~24 min). It is strictly
   **fail-closed**: a mismatch (the tree changed since the attestation), an
   empty/absent value, or an uncomputable current identity all run `--test-cmd`
   exactly as before — the gate itself never weakens, this removes only a
   provably-redundant re-run.

   Four rules keep it honest — break any and the loop either re-runs the gate
   (safe) or, worse, skips a gate it should not (a false green):

   - **Only when `--test-cmd` *is* the attested `run-gate.zsh`.** The `tree`
     field exists only on **plugin repos** (it is `run-gate.zsh` stdout). On a
     `pytest` / `gradle` / other stack there is **no** attestation to pass —
     **omit `--gate-attest` entirely** and let the loop run the gate. Never
     synthesize an identity yourself (e.g. calling `git-tree-id.zsh` right
     before `--resume`): a resume-time identity trivially matches the loop's
     resume-time computation, turning the check into a vacuous self-attestation
     that skips a gate that never ran. The attestation must come from the actual
     green gate, or not at all. The round boundary's `T` is not synthesis: it is
     minted *before* the gate starts and is passed only once that gate has
     reported **green on that same `T`**, so it carries the gate's own verdict
     rather than a resume-time recomputation. Likewise pass it only when `--test-cmd` runs the
     **same** `run-gate.zsh` you gated with — a broader/compound `--test-cmd`
     would be skipped whole on a tree match, including parts the attested run
     never executed.
   - **Capture the attestation from the *green* gate, and don't edit after.**
     The panel is read-only, so a tree that only the review agents have touched
     (i.e. read) is unchanged and still matches — but **you** must not touch the
     tree between the green Step-3 gate and the `--resume`. If you did edit anything (or you
     can't be sure), re-run the gate to get a fresh `tree` **or** omit
     `--gate-attest` — never pass the stale one. (Passing it is not *unsafe* —
     the loop just re-runs on the mismatch — but it wastes the round's point.)
   - **Keep `--work-dir` and every `findings-round-R.json` OUTSIDE the repo**
     (or on a git-ignored path). The identity hashes tracked **and** untracked,
     non-ignored files, so a findings file or work-dir written *inside* the repo
     changes the tree every round and defeats every match. Put them under a
     scratch dir outside the worktree, exactly as the C4 step (§3) writes
     `detect.json` outside the repo.
   - **The one blind spot: git-ignored files.** The identity honors
     `.gitignore`, so a change confined to an *ignored* test-relevant file is
     the single edit class a match cannot catch. In these repos ignored paths
     are build artifacts the suite never reads, so this is theoretical — but if
     you knowingly change an ignored file the tests read, re-run the gate.

   **Write each round's findings to its own path** (`findings-round-R.json` —
   hence the `R`), and pass that round's path. On a `--resume` round the loop
   refuses several shapes of "this round was never really reviewed" as
   **`STALE_FINDINGS` (exit 2, #974, #1434, #1435)** — a *recoverable* usage
   error, not a verdict. Named rather than counted, because this list has grown
   twice and both times a tally elsewhere went stale: some are about the findings
   **file** you passed, one about the tree the round is **scoped against**, one
   about the tree your **panel read**, and one about a **full** round whose panel
   produced no findings file. The empty-delta, full-round and cadence shapes are
   not `--resume`-only — they fire in hook mode too:

   - the file is **missing or empty** — a panel that found nothing still writes
     `[]`, so silence is never read as a clean round (that would converge the
     loop on an unreviewed round and green-light the PR);
   - its content is **byte-identical to the round just consumed** — a stale
     path re-passed, or the new round's file never written. Consumed, it would
     read as a blocker surviving two rounds and trip a phantom
     `ESCALATE_NO_CONVERGENCE`. **One exception (#1434):** the promoted closing
     full sweep is exempt when the round before it **looked at something and
     found nothing** — all three facts (a recorded sweep, that round's findings
     being `[]`, and its scope having been non-empty), because `[]` twice
     running is the expected shape there and refusing it would make convergence
     unreachable. You never have to work around this arm: a round whose panel
     saw *nothing* records no digest at all, so it cannot refuse its successor
     either. **Never hand-edit findings to make the bytes differ** — see the
     recovery rules below;
   - `--findings-file` **IS** the round's own dispatch `findings_path` — you
     aimed at the internal sink the loop truncates. It is refused up front, so
     your panel output was never destroyed; it is simply at the wrong path;
   - the round's **delta is empty and nothing is carried** to verify (#1434) —
     nothing has changed since a round that **left no blockers to verify** (its
     `verify-<R>.json` is `[]`; that round may still have logged Suggestions). This one is
     **not** a re-run-the-panel case: a re-invocation recomputes the same empty
     delta and refuses again. **Recover per the empty-delta arm below** —
     restore the closing-sweep marker the previous round earned, or re-invoke
     under the `--max-rounds` it was written under (step 1 sets out why the
     marker is the reachable state). Stop only when you cannot establish that
     the previous round was a zero-blocker delta round, and never invent a code
     change just to move the tree.
     (An empty delta *with* a carry is **not** refused — it is a
     verification-only round; see step 1 for how to scope it.)
   - the **`--findings-tree` you attested disagrees with the working tree** on a
     reviewable file (#1435) — the panel read one tree and you are consolidating
     against another, so these findings describe a tree that no longer exists.
     This is the cadence invariant of step 3 being enforced rather than trusted,
     and it is **not** a re-pass case: what moved is the tree, not the file.
     **Recover by re-running this round's panel against the current tree** and
     passing its aggregate with a freshly minted `--findings-tree`, or by
     discarding the fix that moved the tree and re-consolidating what the panel
     actually read. The stderr names both identities and the files that moved.

   **Recover by cause, then re-invoke** — the round is not lost. One arm below
   (the missing-confirmation-count one) is a **pre-invocation** check rather than a
   recovery: the loop cannot refuse that shape for you, so it is on you to spot
   it before you pass the file:

   - if round R's panel **did** run and its aggregate exists at its own path,
     **and the refusal named the findings FILE rather than the tree**, just
     re-invoke with the correct `--findings-file` (don't re-run the panel). The
     qualifier is load-bearing: that antecedent is true on a **cadence** refusal
     too — the panel ran, the aggregate is right where it should be — and taking
     this arm there re-passes a file the loop has just told you describes the
     wrong tree;
   - on the **CADENCE** refusal (`--findings-tree` disagreed with the working
     tree) → re-run round R's panel against the **current** tree, minting a fresh
     `--findings-tree` **before** that panel runs, and pass its aggregate. Or
     discard the fix that moved the tree and re-consolidate what the panel
     actually read. **Never clear it by dropping `--findings-tree`** — the guard
     is fail-quiet, so that consolidates the very round it just refused, which is
     the fix-then-resume outcome the guard exists to prevent;
   - if round R's panel reported the round **FAILED** — a dimension that did
     not run, a render step that failed, or (on a round ≥ 2) a
     `fix_verification_path` that was **null or unreadable** — it deliberately
     wrote no findings file and named the cause. That last shape splits: a **null**
     carry is *your own* omitted `--fix-verification` — re-plan the round with
     the carry path (step 1's precondition) and re-run the panel; an
     **unreadable** one means the path was passed but the panel could not read
     it (a relative path resolved against a different cwd, a file outside the
     agent's reach), which step 1's read-before-plan precondition should already
     have caught — fix the path so the agent can read it, then re-run. Either
     way, re-running the panel *unchanged* reproduces the same report. Do **not** write `[]` and do **not** re-invoke:
     fix what it named and re-run the panel, or, if it cannot be fixed, report
     it in the conversation and stop. Writing `[]` here records a clean round
     over a dimension nobody reviewed, and on a delta round that also promotes
     the closing sweep — so the run can reach CONVERGED and open a PR on an
     unreviewed dimension, the exact outcome the panels' write-nothing rule
     exists to prevent.

     **The panel's report to you is the primary signal**, not a file on disk.
     Only the `kubernetes` panel additionally leaves durable detail in
     `<findings-path>.failed.json`; the other five report a failed round to
     their caller and nothing else. So a missing sidecar is **not** evidence
     the panel ran cleanly. (On a loop-driven **delta** round that carries
     nothing, the `kubernetes` panel reports **not applicable** by writing `[]`
     itself plus that sidecar — the opposite case, with nothing to recover.
     With a non-empty carry it either dispatches with the carry or re-raises what
     it could not confirm. A **full** round's not-applicable verdict has its own
     arm below.);
   - **any** panel, on a round carrying a non-empty `verify-<R>.json`, that
     does not account for **every** carried entry took the wrong branch —
     whatever it wrote to the findings file. Two shapes: it states **no count
     at all**, or it states `N of M` with `N < M` and does **not** re-raise, at
     its original severity, each of the `M − N` it could not confirm. A `[]` is
     the starkest case, but two *new* findings with nothing said about the carry
     retire the carried blockers just as unconfirmed — and so does a partial
     count with no re-raises to reconcile it. The count and the findings file
     must add up: every carried entry is either confirmed in the report or
     re-raised in the file. All six carry the same rule ("say in your report
     that you confirmed N carried entries"), so this is not a kubernetes-only
     shape — a confirmed-clean `[]` is legitimate and says so. Treat an
     unconfirmed one exactly like a FAILED round: do **not** pass it to
     `--findings-file`. Re-run the round's panel, telling it explicitly to
     confirm each carried entry and to report how many it confirmed; if the
     re-run again reports no confirmation count, report it in the conversation
     and stop. Consuming it retires carried blockers no reviewer
     confirmed: the entries this round did not re-raise never reach
     `verify-<R+1>.json`, so the carry chain is gone for good — and when the
     report was a `[]`, the round additionally promotes the closing sweep, so
     the run can reach CONVERGED with the previous round's blockers unfixed;
   - if round R's panel reported the round **NOT APPLICABLE on a full round** —
     the `kubernetes` panel's verdict when a story's diff touches nothing it can
     review (a workflow, a docs page, an excluded chart's `values.yaml`), and
     the other five panels' *the story diff itself is empty* — it is neither a
     failure nor something you can fix, and **re-running it is deterministic**:
     it will report the same thing. Do **not** write `[]` (zero blockers on a
     full round is the CONVERGED condition, so that would open a PR on a story
     nothing reviewed), and do **not** loop on the panel. Report to the user
     what the panel said. Then:

     - **autonomous** — stop, and say so. An unattended run does not get to
       waive its own review. Do **not** commit and do **not** open a PR;
     - **interactive** — put it to the human as three options, and take none of
       them without an explicit choice: (1) the deliberate `--no-review` fast
       path (below), which records status `SKIPPED` and does open a PR; (2) a
       **non-panel review** — you read the story diff yourself and report what
       you find in the conversation; it produces **no** findings file and does
       not resume the loop, so the run ends with the review recorded as waived
       in the PR body; (3) stop, with no commit and no PR.

     An **empty story diff** is the one shape not to offer any of these for:
     nothing was implemented, so there is nothing to review or to ship — see
     step 1's `"full"` plan branch and go back to **§2 (Implement)**;
   - if it **never** ran, and you can establish that positively (no panel was
     dispatched this round, or it was interrupted before any dimension
     completed), run round R's panel (step 1) and write **its** aggregate —
     which is `[]` only when that panel really found nothing — then re-invoke.

   **You never author a review round's findings file yourself.** In every arm
   above the `[]` that reaches `--findings-file` is a panel's own output; there
   is no state in which the right move is to write `[]` on a panel's behalf. If
   you cannot positively establish that this round's panel ran to completion
   over **every** dimension, the absent aggregate is ambiguous — re-run the
   panel, or stop. Filling it in yourself converges the round on a review nobody
   performed. The loop enforces the same rule from its side: on a **full** round
   a missing or empty `--findings-file` is refused as `STALE_FINDINGS` rather
   than read as `[]`, because zero blockers there is the CONVERGED condition.

   **The one carve-out is the promotion sub-loop's seeded round 1** (below),
   and it is not an exception to the rule above: that file is never a `[]`
   substituted for a panel, and it adds nothing a panel did not already report
   — it is the blocking phase's own panel aggregate plus items projected from
   that phase's own changelist, so a human's promoted pick is reproducible. It
   is a *seed* for a round that then runs its panel normally, not a stand-in
   for one.
   - on the **alias** refusal, re-invoke with `--findings-file` pointing at this
     round's own path (`findings-round-R.json`). Do **not** re-run the panel —
     its output is intact, and re-running it into the same sink repeats the
     mistake;
   - on the **empty-delta** refusal, no re-run of the **panel** can clear it,
     and there is nothing to fix either: this arm fires only when the carry is
     `[]`, and the refusal message says so itself. Restore `<work-dir>/.closing-sweep` holding this round's number, or
     re-invoke under the `--max-rounds` the marker was written under (step 1
     sets out why the marker is the reachable state). **Never invent a code
     change just to move the tree.** Stop only when you cannot establish that
     the previous round was a zero-blocker delta round.

   **Re-pass the same `--gate-attest` on the recovery re-invoke** (plugin repos).
   The refusal happens *after* the resume-start gate has already run (or validly
   attest-skipped) on this exact tree, and neither the refusal nor the read-only
   panel touches the tree — so the held attestation still matches. Omit it and
   the recovery needlessly re-runs the full suite, the very duplicate #981
   removes; drop it only if you edited the tree since the green gate.

   Never re-pass the previous round's file, and **never hand-edit findings to
   make the bytes differ** — that fakes a round. The **byte-identical** refusal
   can only fire *again* if you feed it byte-identical findings *again*; two
   genuinely independent panel runs **that each found something** never
   serialise to identical bytes (evidence text, ordering, and reviewer set all
   vary), so a repeat means the file still wasn't this round's real panel
   output — recover it (above), don't work around it. Two rounds that both
   found **nothing** do serialise identically, of course, and that case is
   governed by the waiver above rather than by this rule. A blocker the reviewers keep re-finding is a real problem to
   **fix in-session**, not a reason to defeat the guard. That reasoning is
   specific to that arm. The **empty-delta** refusal depends on the tree, the
   **cadence** refusal on the tree the panel READ, and the **alias** refusal on
   the invocation, so re-passing different bytes does nothing for any of the
   three — take their own recoveries above. (The cadence one is the only refusal
   whose inputs are all well-formed: the panel ran, the file is right, and it is
   the ORDERING that was wrong.)

   Exit 2 **writes** its own status JSON (`status: "STALE_FINDINGS"`) to
   stdout and `--status-file`, so the previous round's verdict is never left
   there to be misread; it is not terminal, so it appends no telemetry record
   and no `**Final:**` line — but it *does* append a `**Refused (round N):**`
   line to `<work-dir>/progress.md`, so a user tailing it sees why the round
   they expected did not happen. `STALE_FINDINGS` is never an escalation: don't
   run `build-escalation.zsh` on it, don't post a comment from it, don't enter
   the interactive extension on it — only recover-and-re-invoke.

   The byte-identical half of the guard needs a sha256 tool (`shasum` /
   `sha256sum`); without one that detection degrades silently, so a re-passed
   stale file trips a **phantom** `ESCALATE_NO_CONVERGENCE` instead of this
   refusal. Guard against that at the point it would mislead: on any
   `ESCALATE_NO_CONVERGENCE`, before trusting it, confirm the `--findings-file`
   you passed was round R's own freshly-aggregated path. If it was **stale**,
   the escalation is phantom — ignore it (don't post or extend on it) and
   recover as the `STALE_FINDINGS` case (re-invoke `--resume` with round R's
   real findings, running the panel first if it never ran). The missing/empty
   half of the guard (and the alias guard — `--findings-file` must never be the
   dispatch `findings_path`) needs no digest tool and always applies.
3. **On `AWAITING_FIX` (exit 20)** — the round is over and the run continues.

   **The cadence, and it is an invariant, not a preference: a round's findings
   reach the loop BEFORE that round's fix pass runs, always.** Panel first,
   `--resume` second, fix third — never fix-then-resume. The loop cannot see a
   fix pass it did not invoke, so a round consolidated after one snapshots a
   post-fix tree and attributes that round's blockers to it: the fix-touched
   set, every `class` derived from it, and the residue decision that reads both
   are then computed from a tree the reviewers never saw. The arithmetic stays
   internally consistent while every input is false, which is exactly how a
   residue run files follow-up issues for findings already fixed in the same PR.
   Attest it rather than remembering it — mint the identity your panel read and
   pass it back:

   ```bash
   T=<the round boundary's single guarded mint, §3.5 step 1>
   # …start the gate, run the panel, write findings-round-N.json…
   resolve-story-loop.zsh … --resume --findings-file <…> --findings-tree "$T" \
     --gate-attest "$T"   # plugin repos only — omit on any other stack
   ```

   The loop refuses the round (`STALE_FINDINGS`, exit 2) when that identity
   disagrees with the working tree, naming both and the files that moved. It is
   a **refusal, not a repair** — the loop cannot know which of the two trees the
   reviewers read, so it will not guess. `--findings-tree` is separate from
   `--gate-attest` on purpose: that one answers *may I skip the duplicate test
   run*, a claim about the suite, not about which tree was reviewed. They carry
   the same `T` because the round boundary minted one tree for both; what stays
   separate is what each one claims, so neither may ever stand in for the other.

   **Then check `final_changelist.summary.blocking` (#1434): a ZERO there is
   not a fix turn.** It is a delta round that found nothing, so the loop wrote
   `<work-dir>/.closing-sweep` and promoted the **next** round to a closing full
   sweep over the whole story diff. Say so, **apply no fix at all** (there is
   nothing to fix, and an invented one would change the tree the sweep is about
   to read), then run the next round's panel **with `--final` on your own `plan`
   call** (step 1) so it is scoped `"full"`, and `--resume`. The `--final` is
   not optional: no fix ran, so a plan without it returns an **empty** delta and
   your panel would review nothing while the loop — which passes `--final`
   itself — records a full-sweep round with zero blockers and converges, turning
   the safety net into a no-op. **Re-pass the same `--gate-attest`** on that
   resume (plugin repos): no fix ran, so the attestation you are holding still
   matches and the sweep need not re-run the whole suite. Only that closing
   sweep can declare `CONVERGED`; treating this exit as a normal fix turn would
   either stall the run or, worse, invent changes nothing reviewed. If the promoted sweep sits past `--max-rounds`,
   that is deliberate: the loop grants the closing full sweep
   exactly one round beyond the ceiling, once, so the safety net is not skipped
   precisely when the run has been longest.
   The status JSON carries `closing_sweep_granted: true`,
   `max_rounds` still reports what you passed, and the `--resume` is accepted —
   do **not** "fix" it by raising `--max-rounds` yourself.

   **A second promotion trigger reaches this same exit (#1435 §9), and it is NOT
   a zero-blocker round.** When a **delta** round's residue conditions hold, the
   loop promotes the closing sweep rather than declaring `CONVERGED_WITH_RESIDUE`
   on a slice — same `.closing-sweep` marker, same one-round grant. Tell the two
   apart by `final_changelist.summary.blocking` **and the marker's CONTENT**:

   - **zero blocking** → the #1434 case above; apply no fix.
   - **non-zero blocking, and `<work-dir>/.closing-sweep` holds THIS round's
     number + 1** → the residue promotion. Fix the blockers as on any ordinary
     round, then run the next panel with `--final` and `--resume`.
   - **non-zero blocking, and the marker is absent, UNREADABLE, or holds
     anything other than this round's number + 1** → an ordinary fix turn. Fix,
     take the next round's boundary — *The round boundary is concurrent*
     (§3.5) — and plan that round **without** `--final`. (An
     unreadable or out-of-range marker is a reachable state — a partial write, a
     kill mid-promotion — and the loop *ignores* it, saying so on stderr, and
     plans that round as a delta. So the ordinary fix turn is exactly what
     matches the loop's own behaviour; the arm is written to catch it rather than
     leave you with no arm at all.)

   **Read the content, never the mere existence** — the same rule step 1 states.
   The marker persists for the rest of the run (a sweep that finds blockers does
   not end it), so "the closing sweep ran, found blockers, exited AWAITING_FIX"
   has non-zero blocking *and* a marker, and is an ordinary fix turn. Keying on
   existence sends you back through `--final` on a round the loop is planning as
   a delta: the panel re-reviews the whole diff (the independent repeat step 1
   forbids) while you wait for an exit 14 that round cannot produce.

   The progress line corroborates it (*residue conditions hold, but on a DELTA
   round*), but corroboration is not the test. Only the sweep may exit 14, and it
   declares it against the whole story diff — which is what makes the dossier's
   claim true rather than merely well-formed.

   Otherwise blockers remain and budget is left:
   **narrate the round in the conversation** (round number; the
   Critical/Warning/Suggestion counts — plus, on a promotion sub-loop round, the
   `promoted` count and each `- promoted suggestion:` line; blockers found, new
   vs carried;
   fixed-since-prior and the cumulative blocking trend from round 2 on; the
   dimensions they came from; what you fix next — the same block the loop
   just appended to progress.md, which carries these where applicable, plus an
   `- adjudicated re-raises dropped: N` line when the consolidator suppressed a
   re-raise of an already-waived suggestion, #1434, and a `- by class:` row —
   new_defect / incomplete_propagation / under_assertion, #1435 — whenever the
   round's blockers are class-stamped, which is what says whether the round found
   fresh problems or re-read the last fix pass's own edits).

   **That row is this round's fix-pass trigger (#1496).** Sum the last two
   rounds' `- by class:` cells — the **literal** last two, the same window
   `build-escalation.zsh` renders, never reaching back past one to find a
   stamped pair; summed, never compared per round, since a single round's split
   is noise. When the totals give
   `incomplete_propagation + under_assertion >= new_defect`, the loop is mostly
   re-reading its own last edits, and **rule 2's collapse is MANDATORY for this
   round's fix pass**: every restatement the round names at **more than two**
   sites is collapsed to one normative site plus pointers, rather than patched
   site by site. Rule 2's own threshold still decides which restatements those
   are — a fact at two sites or fewer is corrected in place, because collapsing
   it would rewrite prose no finding named.

   **If either of those two rounds is absent, the histogram is absent** — round
   1, an unstamped round, or a pre-#1435 work-dir — and then **only rule 2's
   collapse relaxes to advisory**: a restatement at more than two sites may be
   corrected in place instead. **Rules 1, 3 and 4, and the ban on adding
   surface, bind every fix pass** whatever the histogram says — rule 3 in
   particular is absolute, so a stale count is never fixed by updating the
   numeral, on any round. A round is absent only when it **had**
   blockers and none of them carries a `class` stamp: a **zero-blocker** round
   counts as `0/0/0` and is present, even though `progress.md` omits its row
   (`build-escalation.zsh` renders it as zeros in the summary table, where a
   `–` cell — an en dash, as that script emits — is the stamp-less sentinel).
   **Otherwise the histogram is present.**

   Three
   false-trip shapes to narrate, and progress.md names each one so you never
   have to infer which you have. A **verified false trip auto-continue**
   (#983) renders as `false trip auto-continued (#983)`: a carried match whose
   title is fully disjoint from its prior is identity-cleared as a genuinely
   different finding, so the loop kept going (no escalation, no human grant) —
   narrate it here (the blocker is fresh, not stuck) and fix it as a normal new
   blocker. A **possible-false-trip auto-continue** (#1498) renders as
   `possible false trip auto-continued (#1498)`: the round met every condition
   the rung requires (ARCHITECTURE.md, *Review-loop state machine*), so the loop
   took the round it already had rather than escalating. #983's "the blocker is fresh, not stuck" does **not** hold here
   — ambiguous means the loop cannot tell a reworded survivor from a new
   neighbour — so **treat it on its own merits, and where the previous round's
   fix for the matched prior was incomplete, finish that rather than patch
   around it.** That is what the round buys: an identity gets exactly one such
   continuation, so a second ambiguous match on it escalates. A **possible
   false trip with no auto-continue marker** renders as `possible false trip`
   and means only that the loop did not take the rung this round; what to do
   with it follows from the round's exit, not from the line — the escalation
   branch below on an escalating exit, and those exits' own arms on an
   `AWAITING_FIX` or a residue ending. Then implement the
   blockers from the status JSON's `final_changelist.blocking` exactly as
   step 2 implements — **sibling-sweeping each blocker's pattern across the whole
   diff and fixing every instance this round** (#982), so a repeating defect is
   cleared in one round, not dribbled across several — Low suggestions never
   loop — while **subtracting rather than adding**, per the rule stated
   immediately below. Then take the next round's boundary — *The round boundary
   is concurrent* (§3.5) — which mints `T`, starts the full gate and dispatches
   that round's panel together.

   **A fix pass subtracts (#1496) — it deletes, narrows or collapses; it never
   adds arms, cases, flags, paragraphs or restatements.** #982 above says how
   *wide* to fix (every sibling instance of the pattern); this says **what a fix
   pass may add inside the files it already owns**, and the answer is nothing.
   How far the file set may **spread** is bounded here too, because rule 2's
   collapse necessarily edits files the blocker never named: a fix pass may edit
   the sites of the facts this round's findings name — including, per #982
   above, every sibling instance of a pattern a finding names — and no others.
   A pass that grows surface is writing the next round's findings: across the
   #1435 session's fresh cycle, the share of each round's blockers sitting in
   text the previous fix pass had just written *rose* 0.77 -> 0.82 -> 0.86, and
   roughly half of the cycle's findings were restatement or propagation drift.
   Four rules, and the list is closed:

   1. **New behaviour is parked, not applied.** A finding whose smallest fix
      introduces a new flag, a new branch or arm, a new rule paragraph or a new
      enumeration is **not** implemented in this fix pass. Park it (below) and
      fix what is already there. **Three things override this, and all three
      are somebody asking for the surface on purpose**: the story's own
      acceptance criteria, a human's granted-round guidance, and a
      human-promoted suggestion. Apply those and name them as such in the round
      narration — parking what a human explicitly asked for is not restraint,
      it is refusing the work.
   2. **A stale restatement at more than two sites is fixed by removal plus a
      pointer, never by correcting the copy in place** — keep **one** normative
      site and make every other site point at it. Correcting the copy leaves N
      sites to drift again next round, which is how one clause consumed rounds
      7, 8 and 9 of the #687 run. **At two sites or fewer**, correct both copies
      in this same pass and add no pointer: a pair is the shape #1432's
      propagation invariants bless, and collapsing it would rewrite prose the
      finding never named.
   3. **A stale count is fixed by naming instead of counting, never by updating
      the numeral.** "three arms", "five shapes", "both conditions" — replace
      the tally with the names, or with nothing. The #1435 session's
      counted-enumeration defect recurred in four consecutive rounds; the first
      three fixes corrected the numeral, the fourth removed it, and only the
      fourth ended it.
   4. **A test-dimension finding is fixed with the ONE assertion the finding
      names** — never a new helper, fixture family or counter, which is itself
      reviewable next round. That is #1433's regress bar restated for the fix
      side: the cheapest assertion that would have caught the defect, and
      nothing more.

   **Parking, concretely — and never silently. File it NOW, not at a terminal.**
   The moment you park a finding, open its follow-up with `gh issue create`
   (labelled `needs-refinement`, since a finding title is not a story) and
   append a one-line `- parked: <title> -> #<issue>` note to
   `<work-dir>/progress.md` yourself — the work-dir is outside the repo, so the
   note cannot move the tree identity. No new artifact and no new script:
   `render-progress-block.zsh` owns the round block above it, and
   `fix-touched-<round>.txt` is a path list `consolidate-findings.zsh
   --fix-touched` reads, so never write a note into either. **File it once.**
   The finding is parked again on every later round, so reuse the number from
   the earlier `- parked:` note instead of opening a second issue.

   **Filing at a terminal would never happen**, which is why it is not the rule.
   A parked blocker stays in the changelist and the next round re-raises it
   unchanged, so the run trends toward `ESCALATE_NO_CONVERGENCE` — where no PR
   opens and no terminal arm fires. Residue cannot rescue it either: a parked
   blocker sits in a file the fix pass deliberately did **not** write, so it
   fails the residue condition by construction. Narrate it as
   parked-with-issue on every later round, and read a run whose only remaining
   blockers are parked-with-issue items as escalating **by design** — the
   escalation asks a human whether the surface should be added after all, which
   is the decision rule 1 declined to make alone. The issue exists either way,
   which is the whole point: a park nobody filed is a finding the run dropped.

   **The rule binds this fix pass, not the story.** It is about what a *round*
   may add while converging, so the surface rule 1's overrides license is
   implemented and reviewed like any other code: a story's own criteria in §2,
   a human's ask in **this** fix pass, each reviewed by the round that follows
   rather than smuggled in unreviewed. The #1435 session's own
   `--findings-tree` flag arrived in a fix pass with no review and cost eight
   blockers in the next cycle's round 1;
   that is the shape rule 1 refuses.

   **The fix pass is captured for you (#1435), and it needs nothing from you.**
   The loop stamped the pre-fix tree identity at this `AWAITING_FIX` and diffs it
   at the next `--resume`, so whatever you edit in-session becomes that round's
   fix-touched set — which is what the residue decision and the per-blocker
   `class` are derived from. The one discipline it shares with `--gate-attest` is
   already stated there: do not touch the tree between the green gate and the
   `--resume`. A failure to compute the set is never fatal — it only makes a
   residue ending unreachable for the round that follows, which is the
   fail-closed direction.
4. **On a terminal status**, take its bullet below — `CONVERGED` and
   `CONVERGED_WITH_RESIDUE` each have one, and the residue bullet is where its
   ordering relative to the promotion phase is stated; escalations →
   *Escalation*. No ordering is restated here on purpose: a partial restatement
   is how the two statements of it came to disagree once already.
<!-- /moved: round-protocol-tail -->

**Every loop invocation carries the run's `loop_args` (#1226).** The invocation
template in step 2 above predates story-mode telemetry and sits in a byte-frozen
span, so this is recorded here: append the run's `loop_args` (Step 0,
`reference/telemetry.md`) to it — round 1 and every `--resume` alike. They are
`--parent-run-id <the run's run_id>` plus exactly the sink flags the run was
given, so every loop record is parented to the run and lands in its sink.
When `start` failed there is no run file: pass only the sink flags from the
`args` output, with no `--parent-run-id`. An epic child that E3 drives passes
nothing.

**Residue condition 2 was removed (#1571).** The procedure above still describes the fix-touched set as an input to the
**residue decision**. That is no longer true, and the paragraph saying so sits
inside a byte-frozen `moved:` span, so the correction is recorded here rather
than edited into it.

Since #1571 the residue terminal takes **two** conditions — 1 (the last two
rounds are both zero-CRITICAL) and 3 (the declaring round ran as a full sweep).
Condition 2, which required every remaining blocker's file to be in the previous
round's fix-touched set, was removed: `scope-findings` already confines every
round's findings to the story diff before consolidation, so the membership it
tested is guaranteed upstream and re-checking it could never fail.

**The fix-touched set itself is unchanged and still load-bearing** for
everything else the procedure above uses it for — the per-blocker `class`
(`new_defect` / `incomplete_propagation`) that `consolidate-findings.zsh
--fix-touched` stamps, the `by class:` progress row, and the waived-suggestion
exemption. Only the residue predicate stopped reading it.

**An empty story diff is refused on a written `[]` too (#1485).** Step 1's
`"full"` plan branch says that the loop refuses a full round with an empty
scope. Step 2's `STALE_FINDINGS` list states only the no-findings-file half of
that refusal. Both sit inside the byte-frozen span, so the other half is
recorded here. It is the **EMPTY-STORY-DIFF** arm. A **full** round whose
scope is **empty** is refused as `STALE_FINDINGS` whether its findings file is
absent or an actual `[]` that consolidated to zero blockers, because that `[]`
means the panel saw nothing. The arm fires in both wirings. It covers an
implementation that produced no diff, and a story whose only changes sit in the
loop's own state (a repo-internal `--work-dir`, the status, findings, telemetry
or carry-accounting files), which the filter strips. Recover exactly as step
1's `"full"` branch says: go back to **§2 (Implement)**; or, if the story
genuinely needs no code change, say so and stop, and never invent a change to
fill the diff. Like several of step 2's own arms, this cause may therefore end
the run without a re-invocation.

**This note governs wherever step 2's recovery arms would otherwise match.**
Whether the panel wrote an aggregate or, as its contract says, none at all,
step 2's arms that re-invoke with the `--findings-file` or re-run the panel look
like they apply. Take neither. Both plan the same empty scope and are refused
again.

**Every fix pass also applies the loaded profile's fix-pass rule (#1805).**
Step 3's fix pass sits inside the byte-frozen span, so this is recorded here:
read the heading below and apply its rule to each fix pass, unless its body
begins with `none` (the conductor's §1b test). With no profile loaded there is
nothing to apply.
profile: `development-<repo_type>:resolve-profile` § Fix-pass rules

### Selected gates for delta rounds (#1973)

The byte-frozen span says the loop's `--resume` gate is "the **full** suite
(unit **and** integration), never a subset (#604)", and the boundary's step 2
starts "the same `<full gate>` command §3 runs". **The first stays true**: the
loop's own `--test-cmd` is always the full `run-gate.zsh`, in every round, and
hook mode never selects. What #1973 amends, for **intermediate (delta) review
rounds only**, is the gate *the session* starts at a delta round's boundary —
the #979 and #604 guardrails, both. **This section governs wherever the text
above names the gate a boundary starts or the attestation it holds and
disagrees with it**: the round protocol's opening paragraph (its whole-suite
sentence), the boundary's steps 2, 5 and 7, the *No fix pass ran since the last
boundary* bullet, the invariant paragraph's cadence recovery, and step 3's
`AWAITING_FIX` hand-off, which names the full gate.

**Only one gate shape can select: a plugin repo whose `<full gate>` is
`run-gate.zsh` alone** — step 5's first arm. `--select-base` is a `run-gate.zsh`
flag and nothing else's. Every other stack, a **compound** `<full gate>`
(`run-gate.zsh` plus anything else as one command) and a gate whose suite
writes into the tree start their `<full gate>` unchanged before every round, as
the text above says; nothing in this section applies to them.

**One rule: a gate's scope is the `scope_mode` of the round it precedes.** Only
a delta round's gate is `selected`:

1. **Round 1** — §3's gate, the full `run-gate.zsh`. Never selected.
2. **A boundary into a delta round** — any round ≥ 2 that is **not** the closing
   sweep, including rounds a human grant bought and possible-false-trip
   continuations — **starts `<full gate>` with `--select-base <base>` appended**
   (`<base>` is the loop's `--base`). This is the default, not an option: it
   runs only the bats files `select-tests.zsh` maps the story diff to, plus the
   always-run set, and falls back to the whole suite by itself whenever the
   selection cannot be trusted.
3. **A boundary into the closing sweep** — the round `<work-dir>/.closing-sweep`
   names, the grant beyond the ceiling included — starts the **full** gate. That
   includes the sweep a zero-blocker delta round promotes **whenever the
   attestation held from that round is `selected:`**: there the *No fix pass
   ran since the last boundary* exemption does **not** apply, because no full
   gate has proved this tree. Mint `T` and start the full gate beside the
   sweep's panel exactly as steps 1–4 say; a red is step 6's (fix, restart the
   boundary), and a green consolidates with its own bare `tree` **and its
   summary as `--gate-summary`** — the tree has not moved, so that bare id
   equals the selected one, and the summary (green, `"scope":"full"`, that
   tree) is how the loop tells a full run from a rebuilt copy. Only when the
   held attestation is already a full run's bare id does that sweep skip the
   gate, as before.
4. **The loop's own `--test-cmd`** stays `<full gate>` — the full `run-gate.zsh`
   — in the invocation template, every round. Never pass `--select-base` there.

**The held attestation is the gate's reported `tree`, exactly as printed.** For
a selected run that is `selected:` followed by the hex — keep the prefix and
never rebuild the value from `T`, which would claim a full run. That holds at
step 5 and wherever the text above re-passes a *held* attestation: the
findings-file recovery re-invokes and the cadence recovery (the zero-blocker
promotion after a selected gate starts a full gate instead, item 3). (The loop
also remembers every selected identity it accepted and runs
its own full gate when a bare copy of it reaches the closing sweep — unless a
`--gate-summary` proves a green full run on that tree, as item 3's does — but
that is the backstop, not the procedure.) `--findings-tree` stays the bare `T`.

**Steps 5 and 7, for a selected run.** Its summary reports `"scope":"selected"`.
Compare the hex after the `selected:` prefix with `T`: equal and green is step
5's plugin-repo arm, consolidating with the whole reported value as
`--gate-attest`; a different hex is step 7's drift. A `--select-base` run whose
summary says `"scope":"full"` means the selector fell back — it ran the whole
suite, and its bare `tree` is an ordinary full attestation. The loop accepts a
`selected:` attestation **only on a `--resume` into a delta round**; into a
full-scope round it runs `--test-cmd`, so a selected gate can never stand in for
the full one before a round that may open a PR.

**`--gate-summary` — the gate's timings, and item 3's proof of a full run.** It is one more flag
on step 2's invocation template (which sits in the byte-frozen span): save the
gate's JSON summary outside the repo, beside the findings files, and pass it as
`--gate-summary <file>` on the invocation that consolidates the round **that
gate** preceded — round 1's included. **Pass it only when this boundary started
a gate.** A boundary that skipped the gate (a zero-blocker promotion held on a
full run's attestation, the findings-file recovery re-invokes) omits it, so no
round is credited with another round's gate; a re-invoke of the same round
re-passes that round's own file. The loop records the summary's `scope`,
`wall_s` and 10 slowest files as that round's `history[].gate` (`attested:
true`); when the loop ran its own gate instead, that run's summary is recorded
(`attested: false`). It never decides a skip on its own; its one effect on the
gate is item 3's — proving a full run lifts the loop's selected-run backstop.

**Why this is safe.** A selector that misses a dependency lets a regression
surface one round late — at the closing sweep's full gate, as an ordinary red
that step 6 fixes — never in a PR: every round that can end the run
(`CONVERGED`, `CONVERGED_WITH_RESIDUE`) is a full-scope round, and the gate
before it is full. (The loop's own refusal of a selected attestation into the
sweep is the backstop for a session that skipped item 3's gate; its red there
exits `ERROR`, which is why item 3 starts the gate rather than relying on it.)

### The delta-round test bar — fix-pass hunks (#2011)

On a **delta** round the claude-plugin test reviewer reviews at a lower bar for
what the previous fix pass just wrote. An untested branch or an unpinned
sentence inside a range that fix pass **added** is a `SUGGESTION`, not a
`WARNING`; one inside a range that rewrote or removed prior-tree lines keeps
full severity. The rule itself — its hunk-shape exception, the fix-introduced
sentence test and its two fail-closed clauses — lives in that agent's mutation
bar and is not restated here.

**Where the ranges come from.** `review-dispatch.zsh plan` emits `delta_hunks`
whenever it is given `--prior-tree` — the same condition as `delta_files`, and
`null` without it: one `{file, kind, start, end}` entry per new-side range of
the fix pass's diff, `kind` `"added"` or `"changed"`, pure deletions omitted.
The claude-plugin review skill's Step 1 adds a `Fix-pass hunks (delta round):`
line to every reviewer prompt **only when the plan's `scope_mode` is
`"delta"`**. Both are contracts every caller of the panel already reads, so the
rule behaves the same whether the conductor or the panel subagent dispatches it,
and nothing in this file's round protocol changes. Hook mode hands the panel no
descriptor, so no hunk list reaches it and the rule never applies there.

**Round 1 and every full round keep today's bar.** A closing sweep plans with
`--prior-tree`, so its descriptor carries a hunk list, but its `scope_mode` is
`"full"`, so no reviewer is handed one — and that includes the sweep a residue
promotion earned.

**No acceptance-criteria exception exists, by design.** The panel is never
handed the issue text, so no reviewer could apply one. A fix-introduced gap on
behaviour the acceptance criteria name is still caught at the full bar by the
closing full sweep, before any PR opens, at the cost of at most one more round.
A demoted finding stays reported, so the promotion phase can still raise it.

### Topic panels — every `topic_review_skills` entry joins the round (#1072)

**Review panel, in-session** (step 1 above) names one skill, `review_skill`,
and step 2's recovery arms were written for one panel per round. Both sit inside
the byte-frozen span, so the topic-composition rule is recorded here. **Where
step 1 or step 2 and this section disagree, this section governs.**

The plan also carries `topic_review_skills` — an always-present array of
`development-<topic>:review` skills, `[]` when no topic applies (ARCHITECTURE.md,
*Review-panel invocation contract*). With `[]` step 1 is exactly as written.
Otherwise:

- **Start every panel in the same round, against the same descriptor.** Spawn
  the reviewers of `review_skill` **and** of every `topic_review_skills` entry,
  in one message, each scoped exactly as step 1 scopes the language panel — the
  same `changed_files`, the same `worktree_root` rail and opener, the same
  `fix_verification_path` and `adjudicated_path`. A topic panel is never given
  a narrower or wider scope, and never planned by a second `plan` call. Wait for
  **all** of them before step 2.
- **Join their #558 arrays into the one round findings file.** Concatenate every
  panel's findings unchanged. Do no dedup, merge or re-severity of your own: the
  only dedup is `consolidate-findings.zsh`'s existing file + line + dimension
  key, and never drop a finding because another panel reported something
  similar. The round counts once, however many panels contributed.
- **A topic panel with nothing in scope that it reviews adds `[]`** — it
  contributes no findings and does not fail the round, whether it reported
  NOT APPLICABLE with no file or wrote an empty array. You join nothing for it,
  and joining nothing is not authoring a findings file on its behalf: step 2's
  rule against writing `[]` for a panel is about the round's file, which the
  language panel's output still fills. Step 2's NOT APPLICABLE arm fires on the
  **language** panel's verdict alone; a topic panel's never triggers it, so a
  story outside the topic's subject is neither stopped nor re-run over it.
  **Unless the round's carry holds entries of that panel's dimensions**: then it
  still owes a per-entry line for each of them (confirmed / re-raised /
  unconfirmed), exactly as any panel does on a carried round. A bare NOT
  APPLICABLE with no per-entry lines there is the carry arm's wrong branch —
  re-dispatch that panel — and never a clean contribution, since accepting it
  would retire its own blocker unreviewed.
- **A topic panel that fails fails the round**, exactly as the language panel
  failing does: recover by step 2's arms and re-dispatch that panel. Never
  consolidate the other panels' findings as if the failed one had reported
  clean.
- **Each panel checks the carried blockers raised by its own reviewers.** The
  carry is one file for the whole round, and *Carry accounting* below already
  confines a re-raise to the reviewer of the entry's own dimension. That makes
  a dimension name identify its panel **only because no two panels in a round
  share one**: a topic panel's dimensions carry the topic's own name as a
  prefix, disjoint from every other panel's, language or topic
  (ARCHITECTURE.md, *Registering a review topic*) — otherwise
  `consolidate-findings.zsh`'s file + line + dimension dedup would also merge
  two panels' distinct findings. So an entry a topic panel's reviewer raised
  is confirmed or re-raised by that panel;
  another panel's reviewer reports it `unconfirmed` or stays silent. So judge
  step 2's per-panel carry arm over the **union** of every panel's per-entry
  lines, as *Carry accounting* does: a panel whose triple reads `N of M` with
  `N < M` because the rest belong to another panel's dimensions has **not**
  taken the wrong branch, and is never re-run for it. Join **every** panel's
  per-entry lines into the round's **one** accounting file — the
  `--carry-accounting` file in step mode, the `<findings-path>.carry.json`
  sidecar in hook mode — never one file per panel.

Hook mode sees the same array as `REVIEW_TOPIC_SKILLS` (a JSON array), and the
loop's status JSON reports it as `topic_review_skills`. There the hook, not
you, does the joining: it merges every panel's array into the one
`$REVIEW_FINDINGS` and every panel's carry records into its one sidecar, rather
than letting each panel write the file in turn. Nothing about
convergence changes: the severity map, the blocking rule, the dedup key and the
round cap are untouched.

### The decided pass — run every `decides:` command before consolidating (#1584)

**Decide every `decides:` claim before you consolidate (#1584).** This is a step
of *Each round* above, between the panel (step 1) and the loop invocation (step
2), and it is recorded here because step 2 sits inside a byte-frozen `moved:`
span. **Where that span's step 2 and this section disagree — about the order of
work, or about what may be written to the findings file — this section governs**:
nothing there contradicts it, it simply predates it.

A read-only reviewer — anything the panel dispatched with `tools: Read, Grep,
Glob` — cannot run a linter, a suite, a validator or a version-sync script, so
its evidence rule caps any finding whose claim *is* one of those verdicts at
`SUGGESTION`, carrying two description lines: `decides: <command>` and
`proposed-severity: CRITICAL|WARNING`. **The decide subagent is the one who
settles them** (*Decide subagent brief* below), because this is the step that
already runs tools on the minted tree. (This pass
is repo-type-generic, and so is the **reviewer** half: every panel's read-only
reviewers carry the rule (#1644), so on any stack a tool-verdict claim arrives
capped with its `decides:` line. A round whose findings carry none leaves the
pass nothing to run — a no-op, not a misfire.)

**When to run it.** After the boundary's **step 4** has observed the gate's
completion and **step 5** has judged it green — **never while the gate is
live** — and before the step-2 invocation, which runs
`consolidate-findings.zsh` for you and so is too late. The ordering is not
cosmetic: a `decides:` command is often the gate script itself, and launching a
second whole suite over the running one is precisely what the boundary's step 3
bans (it oversubscribes the host, so the verdict may be a contention flake
rather than a defect). On a **red** gate (step 6) — **or a green on a REPORTED
tree that is not `T`** (step 7) — skip this pass entirely: in both cases the
round's findings are discarded unconsolidated, so nothing here has anything to
decide, and step 7's tree is not the one the panel read, which would make every
verdict meaningless anyway.

**On a round the boundary runs with **no gate**, run it after the panel.** The
*no fix pass ran since the last boundary* case above — the zero-blocker
closing-sweep promotion and the findings-file recovery re-invokes — mints
nothing and **skips steps 2 and 4**, so there is no gate to observe and the
green-gate trigger can never be satisfied. The "never while the gate is live"
constraint is then vacuous, and the pass runs between the panel and the step-2
invocation exactly as on a green-gate round. This is not a corner: the promoted
closing sweep is the round whose zero-blocker outcome **is** the `CONVERGED`
condition, so skipping the pass there would converge the run with every
tool-verdict finding still capped and the deciding command never run.

Then, for **every** finding in the round's panel aggregate that carries a
`decides:` line:

1. **Run that command in `<worktree_root>`** — the descriptor's
   `worktree_root`, **never your own cwd**, which on an epic child is the
   invoking session's original checkout rather than the tree the story was
   implemented in (the #1582 rule this file states at length for the reviewer
   prompts applies identically here). Confirm it first:
   `git -C "<worktree_root>" rev-parse --show-toplevel` must print that path.
   That tree is `T`, the one the panel read, so the verdict and the review
   describe one artifact; run it anywhere else and a green hides a real blocker,
   or a pre-existing red in `main` promotes a finding that was never about this
   change. **If it prints anything else, or fails, the descriptor's tree is
   wrong for this run: run no `decides:` command, do not consolidate — report it
   and stop** (never fall back to your own cwd, and never re-plan against it).

   **Run the command AS WRITTEN — never substitute.** The reviewer's own rule
   already requires it to name the repo's **pinned** tool in its *checking*
   invocation. If it instead names a bare binary where this repo pins a
   different one, do **not** swap in the pinned command: settle it like an
   unrunnable one (step 5), leave the finding `SUGGESTION`, and record in the
   log that the `decides:` line named an unpinned tool. Substituting would
   record a verdict for a command no finding proposed — and the obvious
   substitute here, `pre-commit run --all-files`, is the file-rewriting set the
   next paragraph bans. Running it as written when it names an unpinned binary
   is the other half of the same trap: that is the #1558 false blocker wearing
   the conductor's own hands.

   **The command must be READ-ONLY**, in the tool's *checking* invocation, never
   a fixing one. This repo's
   pinned `pre-commit` set includes `trailing-whitespace` and `end-of-file-fixer`,
   which **rewrite files**, and §3 runs `pre-commit` *before* the mint for
   exactly that reason. A command that would write into the worktree is settled
   like an unrunnable one (step 5) rather than run after the mint: running it
   moves the tree out from under `T`, which refuses the round on the cadence arm
   and forfeits the held `--gate-attest`.
2. **Record it** to `<work-dir>/decided-<R>.log` — one entry per finding, naming
   the finding, the exact command, its **exit status** and the **first lines** of
   its output. That file is the evidence for the promotion, and the only thing
   that makes a promoted blocker auditable later. **The conductor truncates
   it before the round's first decide dispatch** (*Decide subagent brief*
   below), and every decide pass only appends — a re-entry within the same
   round included, since its earlier entries are this round's evidence. The
   work-dir is reusable, and appending onto a
   previous run's file would mix another story's verdicts into this round's.

   **Identical commands are run **once**.** A `decides:` command is often the
   gate script, and five findings naming it would otherwise launch five whole
   suites for one answer. Run each distinct command once and record its shared
   exit status and output under **each** finding's entry.
3. **Red** → rewrite that finding's `severity` in the aggregate to its
   `proposed-severity` — **when that value is exactly `CRITICAL` or `WARNING`**
   — and set `"decided": "red"` on it. It now blocks exactly like a
   reviewer-raised one. Any other spelling is a malformed finding (below), not a
   severity: the consolidator maps an unrecognised severity to `Low`, so writing
   `Warning` or `High` would file a tool-confirmed red as a non-blocking
   suggestion, indistinguishable from the legitimate red-at-`SUGGESTION` shape.

   **Red means the command RAN and reported a defect** — not merely "non-zero".
   Before reading a non-zero exit as red, establish that it ran at all: exit
   **126/127**, or an error naming the command itself or a path it could not
   open, is **step 5**, not red. Where the exit alone cannot settle it, re-run
   the tool's own no-op invocation (`--version`, `--help`) and take step 5 if
   that fails too. A run **killed** rather than failed to launch is step 5 as
   well — a timeout or a signal (124/130/137/143, or output saying it was
   killed) reported nothing, and a `decides:` command that *is* the gate suite
   is exactly the kind long enough to be killed. A reviewer's `decides:` line is model-authored and can carry
   a stale path or a flag the pinned tool does not accept; promoting on its
   failure-to-launch would reinstate, at the conductor, the simulated verdict
   this whole rule removes.
4. **Green (the command ran and reported no defect)** → leave the severity at
   `SUGGESTION` and set `"decided": "green"`. A green verdict never lowers
   anything and never drops the finding: it stays a logged suggestion the
   promotion phase can still raise.
5. **The command could not run** — not installed, bad invocation, no such path,
   or it would have written into the tree — → that is **not** a red. Leave the
   finding `SUGGESTION`, set `"decided": "green"`, and say so in the log
   only: a tool you could not run decides nothing, and reading
   "could not execute" as "the tool failed the tree" is the same unobserved
   verdict the rule exists to stop, with the conductor now making the claim.
   `green` therefore means **not red** — the command passed, *or* could not be
   run — and `decided-<R>.log` is where the two are told apart.

**Three malformed shapes promote nothing.** All three arms above read
reviewer-authored fields, and a model writes them:

- a finding carrying `decides:` with **no `proposed-severity:` line** — step 3
  has no value to rewrite to, and inventing one (a plausible `CRITICAL`) blocks
  the round on a severity no reviewer proposed;
- a finding whose `proposed-severity:` is **neither `CRITICAL` nor `WARNING`** —
  `Warning`, `High`, `Critical`, `blocker`. Writing it through would be worse
  than doing nothing: the consolidator's severity map has no arm for it, so the
  item becomes `Low` and a red the tool actually reported stops blocking;
- a finding carrying `decides:` that is **already above `SUGGESTION`** *and*
  carries **no `decided` stamp from this round's pass* — a reviewer that stated
  the rule and did not apply the cap. The stamp is what tells that apart from
  **your own** step-3 promotion, which also leaves a `decides:` finding above
  `SUGGESTION`: on a findings-file recovery re-invoke you re-enter this pass over
  an aggregate you already decided, and without the stamp test you would re-run
  every command and denounce your own correct promotions as rule violations.
  **A finding this pass already decided is not re-decided within the round:
  skip it, leaving its severity and its stamp exactly as they are.**
  For the genuine case, step 4's "leave the severity at `SUGGESTION`" describes
  a state that does not hold, so reading it as *demote* kills a blocker that may
  not be a tool verdict at all, and reading it as *leave it* can consolidate a
  `CRITICAL` whose deciding command came back **green** — the lesser harm, and
  the one this rule takes, because the conductor may never lower a severity a
  reviewer chose.

In all three cases: run the command, record the verdict as usual, set `decided`
from it — and **change no severity in either direction**. Leave the reviewer's
severity exactly as written, and name the malformed finding in the log only.
One rule, because both alternatives are wrong in a way the
bullets above already name: the conductor never *raises* a severity the reviewer
did not propose, and never *demotes* one the reviewer did — a `decides:` line is
evidence a reviewer attached, not a waiver of the severity it chose, and
demoting on it would kill a blocker whose claim may not have been a tool verdict
at all.

**KNOWN LIMITATION — this pass settles a finding on the round that RAISES it,
and nothing re-decides it later (#1647).** A finding this pass promoted in round
R is carried into round R+1 through `verify-<R+1>.json`, and the parties asked
to account for a carried entry are the same read-only reviewers whose evidence
rule forbids them from stating that tool's verdict. So such an entry is either
retired on a "confirmed" no reviewer could observe, or stranded as
CARRY-UNACCOUNTED because none may confirm or re-raise it. **Neither outcome is
fixed here.** Closing it properly needs a command source for an entry whose
`decides:` line dedup stripped, a non-reviewer claimant in #1583's
carry-accounting contract, a panel re-dispatch for the red case, and a
reviewer-side exception to the cap — four contracts, three of them #1583's.
That is **#1647**, not a footnote to this pass.

Until it lands, two things are on you, and both are actionable:

- **Recognise one.** An entry in `verify-<R+1>.json` carrying
  **`"decided": "red"`** *is* one: the loop writes the carry from the
  changelist's `blocking[]` items *whole*, so the stamp rides along. Do **not**
  look for the `decides:` line — dedup keeps the longest description in the
  group, so that line is exactly what goes missing.

  **The stamp's absence proves nothing, though.** The consolidator harvests
  `decided` **same-claim only** — a red-decided member that is neither the
  representative nor same-titled leaves the merged item unstamped (the
  unrestricted group verdict exists, but it is internal and stripped before
  output). So also check `<work-dir>/decided-<R>.log`, and where it records a
  red for a finding at that entry's `file` and `dimension`, treat the entry as a
  tool-verdict carry even though it carries no stamp.
- **Do not read the panel's "confirmed" on one as evidence the tool now
  passes**, and, on a CARRY-UNACCOUNTED refusal naming such an entry, do **not**
  take the carry recovery's re-dispatch: it cannot succeed until #1647 lands,
  because the reviewers it re-dispatches are the ones the evidence rule forbids
  from stating that verdict, so it burns a full panel round to arrive at the
  same refusal. Report the entry and its `decides:` command — taking it from the
  log of the round that **decided** it, `<work-dir>/decided-<R>.log`, **not**
  this round's, since the command was not run this round — and stop.

`decided` is additive and defaulted in `consolidate-findings.zsh` — a finding
without it consolidates exactly as before. It is not what **promotes**: the
severity you rewrote in step 3 is, and a finding left at `SUGGESTION` with
`"decided": "red"` stays a suggestion — so **on a red whose finding carries a
usable `proposed-severity` and is none of the malformed shapes above, do both
edits**: the rewrite alone records no verdict, and the stamp alone promotes
nothing. Two qualifiers, and both are load-bearing. The antecedent is the
**verdict**, not the shape a capped finding has: every capped finding carries a
`proposed-severity` line, green ones included, and dropping the verdict from the
condition would rewrite a `SUGGESTION` to `CRITICAL` on a command that came back
clean — step 4's exact opposite. But it is also **not** every red with such a
line: a malformed finding has one too (shape 2 wrote it *and* a severity above
`SUGGESTION`; shape 3's is not a contracted value), and there "both edits" would
mutate a severity the reviewer chose, which those bullets forbid. **The stamp is
not inert either**, and on every red where the rewrite does not apply it is the
only edit there is to make. A `red` record — on the finding itself, or anywhere in its
dedup group — is the consolidator's **fourth adjudication guard**:
`--adjudicated` never drops a red-decided Low. That is the whole protection for
the red-at-`SUGGESTION` shapes above, where the stamp is the *only* edit this
pass makes to the finding. So on a red, **stamp it even when no severity
changes** — skipping the stamp there hands a waived-suggestion re-raise back to
the drop, and it vanishes with `summary.adjudicated_dropped` as its only trace.

**Never promote on reasoning.** If you **chose not to run** the command — as
opposed to running it and finding it could not launch, which is step 5 and does
get a `green` record — the finding keeps `SUGGESTION` and gets no `decided`
field at all. A conductor that re-derives the verdict from the reviewer's
argument has simply moved the simulation one step downstream.

**Which file you edit, and why that is not a fix pass.** The severity rewrite
lands in **the round's panel aggregate — the file you will pass as
`--findings-file`**, which step 2's work-dir rule keeps **outside the repo**. It
is **never** `<repo>/.review/findings-round-<R>.json`: that is the dispatch
descriptor's `findings_path`, the loop's own sink, which the loop truncates and
which it refuses outright as a `--findings-file`. Editing the sink either loses
the round to that refusal or — worse, and silently — discards every severity
rewrite and every `decided` stamp while the run carries on, leaving tool-verdict
findings at `SUGGESTION` forever with nothing reporting that the pass did
nothing. Because the aggregate lives outside the repo and every `decides:`
command was read-only (step 1), the `--findings-tree` identity you attested
**should** still match and this pass should not trip the cadence guard — a
*should*, not a proof, because step 1's read-only test is your classification of
a model-authored command, not an observation. If the loop nevertheless refuses
on CADENCE right after this pass, treat a `decides:` command as the writer:
**retire every `decides:` command this pass ran** for the rest of the run,
settling each one's finding
like an unrunnable command (step 5: `SUGGESTION`, `"decided": "green"`, named in
the log as a writing command), on this pass and every later one. Only then take
that arm's recovery. *Every*, not "that one": the pass runs many commands and
nothing here identifies which wrote, so retiring a guess leaves the real writer
live. And retiring first is what makes the recovery terminate — the arm re-runs
the round's panel, the panel re-emits the same `decides:` lines, and a pass that
has not retired them runs them again, moves the tree again, and refuses again.

**This is the one exception to the skip rule above**, and it is the only place
the pass lowers a severity. A retired command's finding is re-settled *even
where this pass already decided it*, so "not re-decided within the round" does
not hold here; and that re-settle may lower a severity **this pass itself
raised**, never one a reviewer wrote. It is not a third kind of edit either: it
is the same stamp and the same rewrite, applied again with the retired
command's verdict.

**This pass makes two kinds of edit to that file, and no others**: the `decided`
stamp — steps 3, 4 and 5, and both malformed shapes, most of which change no
severity at all, so an enumeration naming only the rewrite would forbid the very
record this pass exists to leave — and the severity rewrite on a red carrying a
`proposed-severity` (step 3). Both re-state what a panel raised; neither authors
a finding, which remains the panel's alone.

**One other writer touches the same file, and it is not this pass**: the
carry-accounting recovery below re-dispatches the panel for an unaccounted-for
entry and merges that output into the aggregate, under its own trigger and its
own rule (*Carry accounting* → *Recover by ground*). Take it from there, not
from here.

### The risk pass — assess every blocking finding before consolidating (#1921)

**Assess the round's blockers against `corner_case_risk_threshold` after the
decided pass and before the step-2 invocation.** The #1920 variable sets a floor
on risk (probability × impact). Below it, a finding that clears a reviewer's
blocking bar is logged as a suggestion instead of being fixed. That stops the
fix pass chasing negligible corner cases round after round, the treadmill
measured in the #1435 and #1558 post-mortems. It runs in the same slot as the decided
pass, and like that pass it is recorded here because step 2 sits inside a
byte-frozen span.

While the threshold is on, the risk subagent (*Risk subagent brief* below) makes
the assessment this section describes, and the conductor dispatches it and
passes `--risk`.

**First read the variable.** It lives in the environment and nothing in the
conversation shows it:

```bash
printenv corner_case_risk_threshold   # exit 1 → unset
```

Then take exactly one of the three states `reference/residue.md` § *Risk
threshold — assess before filing (#1920)* defines, which the scripts parse with
one shared parser (`scripts/risk-threshold-lib.zsh`):

- **Off** (unset, empty, any spelling of zero): skip this pass. Make no
  assessment and pass no `--risk`. The round consolidates exactly as before.
- **Ignored** (not a decimal in [0, 1] with at most three decimals): behave as
  off, say so once in your narration, and write the one-line PR Summary note
  naming the value that `residue.md` prescribes for this state, once per run,
  whichever terminal the run reaches.
- **On**: in step mode, everything below applies, every round, including the
  promotion sub-loop's rounds and the closing sweep. Hook mode supplies no
  assessment (see below).

**What to assess.** Every finding in the round's panel aggregate, the file you
pass as `--findings-file`, whose severity is `CRITICAL` or `WARNING` after the
decided pass. That includes a finding the decided pass promoted: it is exempt
from demotion, but a stamp still records its risk. Do not assess `SUGGESTION`
findings; they already do not block.

**How to assess.** Record `p` and `impact` with a one-line rationale for each.
Use the definitions `residue.md` § *1. Assess every residual blocker* gives and
do not restate or vary them here:

- `p` is two decimals, with the test-strength definition for `tests` findings
  and the defect definition otherwise;
- `impact` is exactly one of the four anchors `1.0` / `0.7` / `0.4` / `0.1`.

**Severity and impact are independent.** A reviewer's severity decides only
whether a finding is eligible: `CRITICAL` is never demoted, `WARNING` may be,
and `SUGGESTION` is not assessed. Impact is judged on the consequence alone. A
`WARNING` can carry impact `1.0`, and a `CRITICAL` impact `0.1`. Never cap or
floor one by the other.

**Assess afresh every round.** A finding re-raised in a later round is assessed
again, because the fix pass may have changed how likely it is. Never copy an
earlier round's numbers forward unexamined; the changelist keeps each round's
stamp, so the record shows how an assessment moved. When the aggregate gains
findings after this pass — the carry-accounting recovery below merges a
re-dispatch's output into it — re-dispatch the risk subagent over the merged
aggregate before you re-invoke.

**Write and pass it.** Write the assessment to `<work-dir>/risk-<R>.json`,
outside the repo like every other per-round file. It is one JSON array in the
shape #1920 defined, one entry per assessed finding, with the identity copied
**verbatim** from the aggregate — except a digit-string `line` (`"42"`), which
you write as the number it spells, since the validator accepts only a number or
`null` there:

```json
[ { "file": "tests/x.bats", "line": 42, "dimension": "tests",
    "title": "<the finding's title, verbatim>",
    "p": 0.05, "p_why": "…", "impact": 0.4, "impact_why": "…" } ]
```

Add the file to that round's invocation:

```bash
resolve-story-loop.zsh … --resume --findings-file <…> \
  --risk <work-dir>/risk-<R>.json …   # plus the round's other flags, exactly as the templates above
```

- The loop forwards the file to `consolidate-findings.zsh --risk` for that
  round only.
- A malformed file (a `p` with three decimals, an impact off the anchors, a
  blank rationale, a duplicate identity) is **exit 2** before anything is
  written. The message names the entry: make one fresh risk dispatch whose
  prompt carries that stderr line verbatim, then re-invoke the same round with
  the same flags; a second such exit 2 in the same round is report-and-stop.
  This exit 2 is **not** `STALE_FINDINGS` and writes **no**
  status JSON, so `--status-file` still holds the previous invocation's
  verdict — act on the stderr line alone.
- An entry that matches no `CRITICAL` or `WARNING` finding assesses nothing,
  and the consolidator names it on stderr. A finding you leave out keeps its
  severity, because a missing judgement never demotes anything.
- `--risk` is step-mode only. Hook mode supplies no assessment, so every
  blocker is kept.

**What the consolidator does with it.**

- Every assessed item carries `risk_assessment: {p, p_why, impact, impact_why,
  risk, risk_thousandths, threshold, threshold_thousandths}`, recorded beside
  `decided`.
- A `WARNING` item whose risk is **below** the threshold is **demoted**: it
  moves to `suggestions` with `demoted: true` and never blocks convergence. The
  comparison is in integer thousandths, and a risk exactly at the threshold
  stays blocking.
- **Never demoted**, at any threshold or risk: a `CRITICAL` item, a
  human-promoted item (`promoted: true`), and an item a tool decided red
  (`decided: "red"`, or a red anywhere in its dedup group).
- A dedup group is demoted only when every `WARNING` member was assessed and
  its **highest** member risk is below the threshold.

**Where a demotion shows.** A demoted finding never disappears.

- The round's progress block names it.
- The PR dossier lists it in its own table, above the waived suggestions.
- The suggestion-promotion prompt offers it back like any other waived
  suggestion — under `promotion.md`'s own derivation, which keeps a finding's
  earliest occurrence, so a finding that blocked in an earlier round and was
  demoted later is listed in the dossier table but not offered. With
  `enable_suggestions` off there is no prompt, and the progress block and the
  dossier table are the only records. A pick survives the sub-loop's own risk
  pass: the consolidator demotes before its promotion overlay, which raises the
  pick again.
- The residue branch reuses the final round's stamp instead of assessing a
  blocker a second time (`residue.md` § *Risk threshold*).

### Carry accounting — confirmed, re-raised, unconfirmed (#1583)

The `fix_verification_path` bullet above (step 1) tells the reviewers to re-raise a
fix the reviewer failed to confirm at its original severity, and step 2's
carry arm treats a round whose count does not add up — fewer confirmations than
carries and no re-raise of the remainder — as failed. Both sit inside a
byte-frozen `moved:` span, so — exactly as
the #1571 correction above — the rule that replaces them is recorded here
rather than edited into the span. **Where the span and this section disagree, this
section governs.**

**Every carried entry has exactly one owner (#2010): the reviewer of its own
dimension.** The panel splits the carry with `review-dispatch.zsh split-carry
--fix-verification <work_dir>/verify-<R>.json`, which writes each dimension's
entries to `verify-<R>-<dimension>.json` and prints the `{dimension: path}`
map, and hands each reviewer only its own dimension's path; a reviewer whose
dimension is not in the map gets no Fix verification line at all. No reviewer
is ever shown another dimension's entry, so each entry is verified once, by the
one reviewer that can act on it. *(Retired: until #2010 every reviewer was
handed every entry and accounted for each one, and one confirmation from any of
them decided the outcome — about five verifications per entry, almost all of
them `unconfirmed` reports from reviewers that could not re-raise it.)*

The owner reports ONE of three outcomes for each of its entries:
**confirmed** (it names where the fix is); **re-raised** (it observed the
defect **still present** and cites what it saw — the file:line and the
unchanged text, or the passing mutation — never the absence of a fix; the
re-raise goes into the findings file at its original severity, citing the
carried entry, *even when its file is outside this round's delta*); or
**unconfirmed** (it could not establish either). An unconfirmed entry is a
count, not a defect: it never enters the findings file and never becomes a
blocking finding on its own. **The owner's report decides the accounting
outcome** — and a re-raise in the findings file is a finding like any other:
aggregate it unchanged; the loop carries it forward on its own evidence. A
re-raise keeps the entry's own dimension, since the identity the loop matches
on includes it. Cross-dimension observations are no longer a duty: a reviewer
that sees a problem in the same code raises it, if at all, as a finding of its
own dimension. What is refused — by the loop, not by you — is a carried entry
its owner neither confirmed **nor** re-raised, silent or reported-unconfirmed
alike, and that includes an entry whose owning dimension was not dispatched or
contributed no record: fail-closed on every round, the closing sweep and the
final round included.

**Tell each reviewer to account for every carried entry of its own dimension
by the carry's own spelling, one line per entry, before its triple** (the
panels' prompt-template line says so): `carried entry "<title>" (<file>,
<dimension>): confirmed at <file:line> | re-raised (see finding) |
unconfirmed`, then `carried: confirmed N / re-raised M / unconfirmed K of
TOTAL`, where TOTAL is the length of its own dimension's file. The per-entry
lines are what you assemble; each triple is the checksum that its reviewer's
list is complete, and the reviewers' TOTALs together sum to the length of
the file the split ran on. A reviewer that leaves any entry of its own
dimension's file without a per-entry line took the wrong branch —
re-dispatch **the panel** for that reviewer's dimension only (you never spawn
a reviewer agent directly: the panel's Step 1 is what wires the JSON layer and
the fix-verification line into its prompt), never invent a record.

**Supply the accounting — without it the loop refuses.** On every round whose
`verify-<R>.json` is non-empty, assemble one file from the reviewers' per-entry
lines — an array of per-identity records, one per entry of `verify-<R>.json`,
each naming its owning reviewer under the one outcome it reported:

```json
[{"file": "…", "dimension": "…", "title": "…",
  "confirmed": ["<owning reviewer>"], "re_raised": [], "unconfirmed": []}]
```

— and pass it as `--carry-accounting <carry-round-R.json>`, kept **outside**
the repo beside `findings-round-R.json`. The invocation templates above gain
that flag; round 1 carries nothing and needs none:

```bash
resolve-story-loop.zsh … --resume --findings-file <…> \
  --carry-accounting <carry-round-R.json> …   # plus the attestation flags, exactly as the templates above
```

The loop matches each record to the carry by identity (file, dimension, title —
the consolidator's own normalisation: file stripped of `./`, dimension
verbatim, title lower-cased and whitespace-collapsed), counts a carried entry
as re-raised when the findings file carries a **blocking entry at that
identity** — same file, dimension and title, whatever its line — or one the
consolidator matched to the carried prior, stamps `carry_accounting: {total, confirmed[],
re_raised[], unconfirmed[]}` into the round's changelist (the progress block
renders it as `carried: confirmed N / re-raised M / unconfirmed K of T`), and
refuses the round as `STALE_FINDINGS` — the **CARRY-UNACCOUNTED** arm, fired
**before** `verify-<R+1>.json` is written, so `verify-<R>.json` stays the carry
and the accumulators are untouched — when: no accounting was supplied; the file
is not that shape (since #2010 that includes a record whose three arrays name
more than one distinct reviewer); a record names no carried identity; a record claims a
re-raise the findings file does not carry (the accounting alone is not
evidence); or a carried identity has **no confirmation and no re-raise** from
its owner. Its stderr names each such entry (`carry unaccounted: round R
carried entry "…" (…) was neither confirmed nor re-raised by any reviewer
(unconfirmed by: … | no reviewer reported it)`) and the status JSON lists them
in `carry_unconfirmed[]` — never in `.blocking` (a record-only re-raise is
refused by name and populates nothing). Step 2's `STALE_FINDINGS` list above is
to be read as `#974, #1434, #1435, #1583, #1485`, this arm the fourth (the
fifth is the EMPTY-STORY-DIFF arm, recorded after the frozen span); like the
empty-delta, full-round and cadence arms it is wiring-independent and fires in
hook mode too, where the panel writes the same records to
`<findings-path>.carry.json`.

**Recover by ground.** For the first three grounds — no accounting supplied,
a file of the wrong shape, a record naming no carried identity — the panel
already ran and its per-entry lines are in `carry-lines-R.txt`: rebuild
`carry-round-R.json` from them with the panel brief's `carry-repair` mode and
re-invoke; no reviewer runs. For an
**unevidenced re-raise** the reviewer's finding sits under the wrong identity:
re-dispatch **the panel** for that entry, quoting the carried `{file,
dimension, title}` verbatim and saying the finding must carry it — the re-dispatch
reaches **only the owning dimension's reviewer** (#2010), never the whole
panel — with an **empty** scope (a delta-round panel reviews nothing and only accounts for the
carry) and a `fix_verification_path` naming only that entry. For an entry
**neither confirmed nor re-raised**, re-dispatch the panel the same way for
those entries only — **except a tool-verdict carry** (one stamped
`"decided": "red"`, or one *The decided pass*'s KNOWN LIMITATION identifies from
`decided-<R>.log`): that re-dispatch cannot succeed until #1647 lands, because
the reviewers it dispatches are the ones the evidence rule forbids from stating
that verdict, so it burns a full panel round to reach the identical refusal.
Report that entry and its `decides:` command, and stop.

**A re-dispatch writes to its own path** —
`findings-round-R-carry.json`, never `findings-round-R.json`, which still holds
the first pass's findings — and the panel brief's `carry-redispatch` mode merges
the two arrays into `findings-round-R.json` (`jq -s 'add' findings-round-R.json
findings-round-R-carry.json`): panel output, never a hand edit; never retype or
reword a finding yourself (a record-only `re_raised[]` is refused, and a
re-raise that never reaches `.blocking` never reaches the next carry).
Re-assemble the accounting from all the per-entry lines and re-invoke. If the
re-run again leaves an entry unaccounted, report it in the conversation and
stop. A confirmed-clean `[]` is legitimate and says so in its triple; the
`kubernetes` panel's not-applicable arm above likewise dispatches each agent with
its own dimension's carry, and each owner accounts for its entries as one of
confirmed, re-raised, unconfirmed.

**One consequence the procedure above still states the old way.** Its parking
rule concludes that "Residue cannot rescue it either: a parked blocker sits in a
file the fix pass deliberately did **not** write, so it fails the residue
condition by construction", and tells you to read a parked-only run as escalating
**by design**. That rested entirely on condition 2. A parked blocker that is in
the story diff is now residue-eligible, so such a run **can** reach the closing
sweep and exit 14.

So do not read a parked-only run as escalating by design — that inference is
retired. **The `File it NOW` rule above is not**: park-time filing stays
mandatory, and the escalation paths still file nothing, so a park nobody filed
is still a finding the run dropped. Only the *justification* the frozen text
gives for it — that filing at a terminal would never happen — no longer holds.

**What the residue branch should DO about it is deliberately not decided
here — #1581 owns it.** The branch files its plan as built, which means a
parked finding can end up with two issues — the one the fix pass filed when it
parked it, and the residue follow-up. That is a known, tracked wart rather than
a rule you should improvise around: a hand-rolled match between the two is
exactly what #1581 exists to specify, because the builder's identity is four
fields and the obvious three-field version silently drops a **non-parked**
sibling at a colliding spot, losing a residual blocker the dossier claims was
filed. Do not attempt it here.

The normative statement, with the reasoning and what is deliberately not
changed, is in `residue.md` § *Condition 2 — removed; the story-diff rail is
upstream (#1571)*.

### Carry-driven dispatch (#2008)

A panel may skip a dimension on **delta** rounds — its review skill's Step 1
table says which, and when. Skipping must never strand that dimension's carried
entries, because only the owner can account for them, and an entry its owner
never saw is refused as CARRY-UNACCOUNTED (*Carry accounting*). So the generic
rule is:

**A dimension skipped on delta rounds is dispatched on a delta round exactly
when #2010's split-carry map holds its key.** The map is what `review-dispatch.zsh
split-carry` prints for the round's `verify-<R>.json` — in hook mode,
`$REVIEW_FIX_VERIFICATION_BY_DIMENSION`. Holding the key is the whole test:
it means the round carries at least one entry of that dimension, so its owner
is present to confirm or re-raise each one. A delta round whose map does not
hold the key does not dispatch the dimension, and that is a dimension not
planned for the round — not `dimension-not-run` (*Panel subagent brief*).

The rule only ever **adds** a dispatch. Full rounds — round 1 and every closing
sweep, `scope_mode: "full"` — run every dimension their table plans for them,
whatever the carry holds. A dimension dispatched only for its carry still
reviews the round's scope like any other reviewer; the carry is why it runs,
not a limit on what it may raise.

Where it applies today: the claude-plugin panel's `manifest_bump` dimension
(`claude-plugin-manifest-check`), which runs on full rounds and, on a delta
round, only by this rule; and its `contract` dimension on a delta round the plan
marks skippable (*Skippable dimensions*, below). A panel that adds another
delta-skipped dimension cites this subsection rather than restating it.

### Skippable dimensions (#2009)

`review-dispatch.zsh plan` always emits `skippable_dimensions`, a JSON array of
the dimensions this round's panel may leave out. It is `[]` on every full round
and for every repo type but `claude-plugin`. On a claude-plugin **delta** round
the plan runs `select-contract-dimension.zsh` — a pure selector over the delta's
name-status list and its patch — and emits `["contract"]` when the fix pass
touched no contract surface (no `ARCHITECTURE.md`, no `.claude-plugin/` path, no
agent or SKILL.md frontmatter, no script flag, subcommand, exit code, output key
or env seam, no added, deleted, renamed or copied shipped file, no removed
heading in a shipped `.md`). Any input it cannot judge, and any failure to
decide, leaves the field `[]`: the dimension runs.
Hook mode exports it as `$REVIEW_SKIPPABLE_DIMENSIONS`.

The plan only **offers** the skip; the panel's Step 1 table decides, and a
skipped dimension comes back for its carried entries by *Carry-driven dispatch
(#2008)* above. A delta round whose plan omitted `contract` returns no contract
verdict and is consumed like any other round — the loop adds no check of its
own. A round whose table planned `contract` and did not run it is still the
`failed` / `dimension-not-run` row of the *Panel subagent brief*.

Each round's line in `<work-dir>/history.jsonl` records `skipped_dimensions`:
the plan's field less every dimension the round's carry forced back in, `[]`
when none. The loop keeps the plan's field per round in
`<work-dir>/skippable-<R>.json`, and `build-telemetry-record.zsh` reports the
history as `skipped_dimensions_by_round`.

### The third histogram state — present, below the threshold (#1510)

Step 3's fix-pass trigger above closes two histogram states with an explicit
rule-2 binding and leaves the third open: totals at or above the threshold make
rule 2's collapse MANDATORY, an absent histogram relaxes it to advisory, and a
histogram that is **present** with totals **below** the threshold is never
named — the paragraph ends at "Otherwise the histogram is present." That
paragraph sits inside a byte-frozen `moved:` span, so — exactly as the #1571
and #1583 corrections above — the binding is recorded here rather than edited
into it. **Where the span is silent or disagrees with this section — rule 2's
absolute wording inside it included — this section governs.**

**A present histogram whose totals fall below the threshold binds rule 2 no
harder than an absent one**: a restatement at more than two sites may still be
corrected in place, and the threshold is the only thing that makes collapsing
mandatory. So the three states read: at or above the threshold — collapse
MANDATORY; absent — advisory; present and below — advisory, same as absent.
What a fix pass may observably do differently across the threshold is exactly
one thing: whether it may patch a more-than-two-site restatement copy by copy.
Rules 1, 3 and 4 and the ban on adding surface bind on every round, and the
two-sites-or-fewer rule is unchanged in every state, as the span already says.

This reverses the residue finding's own suggested fix (#1510), which would have
made rule 2 bind as written below the threshold and left the threshold deciding
nothing. The two summary sites — ARCHITECTURE.md's *the class condition that
turns collapsing from advisory into mandatory* and
`docs/explanation/review-loop.md`'s *stops being advisory and becomes required*
— are accurate under this reading and are deliberately not edited.

### Round subagents — the conductor reads only verdicts (#1935)

Each round's heavy work runs in **fresh subagents**, not in the conductor's
context: a **panel** subagent reviews, a **decide** subagent settles the
round's `decides:` claims, a **risk** subagent assesses its blockers while
`corner_case_risk_threshold` is on, a **fix** subagent fixes. The conductor
keeps the round boundary, the gate, consolidation and every human decision, and
exchanges work with the subagents only through the `round-handoff/v1` and
`round-verdict/v1` files (ARCHITECTURE.md, *Round handoff and verdict
contracts*). **Where *Each round* above has the conductor plan and dispatch the
panel itself (step 1) or apply the fix pass itself (step 3), this section
governs**: those steps sit in a byte-frozen span, so they are superseded here
rather than edited. What they say a panel or a fix pass must *do* still holds —
the briefs below hand that work to a subagent, they do not change it.

**Depth budget.** No implementation adds a layer:

- single-issue flow: conductor (0) → panel subagent (1) → reviewers (2);
- epic E3 child flow: child conductor (1) → panel (2) → reviewers (3), which is
  Claude Code's default nesting limit;
- the fix subagent dispatches nothing;
- the decide subagent dispatches nothing;
- the risk subagent dispatches nothing.

A panel subagent that has no `Agent` tool cannot dispatch reviewers: it returns
`failed` / `no-agent-tool`, and the conductor reports and stops.

**Dispatch mechanism.** ARCHITECTURE.md's *Subagent dispatch mechanism*
paragraph records a probe **pass**, so the four kinds ship as plugin agents:
`development/agents/round-panel.md`, `development/agents/round-fix.md`,
`development/agents/round-decide.md` and `development/agents/round-risk.md`;
the risk kind is dispatched as *Risk subagent brief* below says. The conductor dispatches `subagent_type:
round-panel` and `subagent_type: round-fix`, and `subagent_type: round-decide`
for the decided pass, one fresh subagent per job — a recovery or a retry is a **new**
dispatch, never a resumed one — with a prompt that names the handoff file and
`<skill-base-dir>`. Make every `round-panel`, `round-fix`, `round-decide` and
`round-risk` dispatch in the foreground (`run_in_background: false`), as
ARCHITECTURE.md's *Subagent dispatch mechanism* records: in the epic E3 child
flow the conductor is itself a subagent, so its own dispatch is nested and
defaults to a background launch, which returns before the verdict is written.
A foreground dispatch returns its verdict in the same turn, so the conductor
carries straight on: **How to wait** governs only the gate and a dispatch that
did launch in the background — it is not restated here. Each agent body only
points at its brief below.

**Contract usage.** The conductor writes every handoff with `round-handoff.zsh
write-handoff --work-dir <work-dir>` and reads every verdict with
`round-handoff.zsh read-verdict --file <work-dir>/verdict-<R>-<kind>.json`. A
subagent reads its handoff with `round-handoff.zsh read-handoff` and writes its
verdict only with `round-handoff.zsh write-verdict --work-dir <work-dir>`.
Neither side hand-writes or hand-parses those files.

**The round boundary is unchanged, and the conductor owns all of it.** It mints
`T`, launches the detached gate, waits on it, and dispatches the panel subagent
while the gate runs — *The round boundary is concurrent* above, or
`reference/sequential.md`'s serial boundary when that mode is on. No subagent
launches or waits on the gate. The panel handoff's `tree_id` is `T`.

**The carry precondition stays with the conductor.** Before writing a panel
handoff for any round ≥ 2, run step 1's read-before-plan check — `jq length` on
`<work-dir>/verify-<R>.json`. An absent, zero-byte or unreadable carry is
report-and-stop.

**What the conductor puts in a handoff.** Every key ARCHITECTURE.md's
`round-handoff/v1` table lists for the kind — the table is the key set. The
values only the conductor can supply:

- **every kind:** `round`; `tree_id` is the round's `T`; `worktree_root` is the
  implementation worktree (*Build each reviewer's scope block* above says how to
  identify it), resolved with `:A`;
- **panel:** `base` is the loop's `--base`, resolved to a commit; `mode` is
  `round`, so `carry_entries` is `[]`, except on the two carry recoveries
  (*Verdict recovery arms (#1937)*); `delta_base` is the tree identity
  **read from** `<work-dir>/tree-<R-1>.txt` on every round ≥ 2 — its content,
  never the path — and `null` on round 1; `carried_finding_ids` names the
  entries of `verify-<R>.json`, and is `[]` when it holds none.

A non-zero `round-handoff.zsh write-handoff` exit, or a `read-verdict` exit 1 or
2, is report-and-stop.

**Consolidation stays with the conductor.** On an `ok` panel verdict, and then
an `ok` decide verdict where the round's decided pass runs (*Decide subagent
brief*), the conductor runs step-mode `resolve-story-loop.zsh` itself, exactly as step 2
says, passing the verdict's `aggregate_findings_file` as `--findings-file` and,
when it is non-null, its `carry_accounting_file` as `--carry-accounting`. It
opens neither file. It narrates the round from the verdict's `findings_count`,
the status JSON and the progress block the loop appended. A non-`ok` panel
verdict takes *Verdict recovery arms (#1937)* below.

**When the fix subagent runs.** On exit 20, read `final_changelist.summary.blocking`
from the status JSON:

- **non-zero** → dispatch the fix subagent with `trigger: awaiting-fix`, and
  `changelist` naming `<work-dir>/changelist-<R>.json`, the round's changelist
  the loop wrote. After an `ok` verdict, take the next round's boundary.
- **zero** → the closing-sweep promotion (step 3). No fix runs; take the next
  round's boundary as step 3 says.

On a **red gate** (the boundary's step 6), dispatch the fix subagent with
`trigger: gate-red` and `gate_log` naming the gate's recorded output. After an
`ok` verdict, the conductor restarts the boundary from its step 1.

In both cases the handoff also carries the round's `grant` (`null` when none was
granted) and its `guidance` (the human's granted-round guidance, or `null`),
`rule2_mandatory` (step 3's histogram trigger), and `profile_fix_rules` — the
loaded profile's *Fix-pass rules* reference, or `null` when that heading begins
with `none` (§1b's test). When it is non-null, the dispatch prompt carries that
heading's body, since the subagent cannot load a skill.

**A fix verdict that is not `ok` is report-and-stop**, on either trigger; on
`gate-red` it is §3's *abandon and report*. **A fix that changed nothing is
report-and-stop** too: an `ok` verdict with `fix_applied: false` or
`files_changed: 0` never restarts the boundary on an unchanged tree. The one
exception is an `awaiting-fix` pass that parked every blocker under step 3's
rule 1 — the `- parked:` notes in `<work-dir>/progress.md` name each of the
round's blocking items. Take the next boundary there, so the parked items are
re-raised as step 3 says.

**Before every dispatch, clear what an earlier dispatch of the same round and
kind left behind**: delete `<work-dir>/verdict-<R>-<kind>.json` and, for a
panel, what its mode replaces:

- a **`round`**-mode panel also deletes `findings-round-<R>.json`,
  `carry-lines-<R>.txt` and `carry-round-<R>.json`;
- a **`carry-repair`** panel deletes nothing more;
- a **`carry-redispatch`** panel also deletes
  `<work-dir>/findings-round-<R>-carry.json` and
  `<work-dir>/verify-<R>-carry.json`, and keeps `findings-round-<R>.json`,
  `carry-lines-<R>.txt` and `carry-round-<R>.json`.

A delete that fails is report-and-stop. Without it, a re-dispatched subagent
that dies reads back as the earlier one's verdict.

**Stall retry.** A missing or invalid verdict is exactly a `round-handoff.zsh
read-verdict` exit 3, a missing file included. It gets exactly one re-dispatch,
then report-and-stop — a fresh subagent with a freshly written handoff. A
verdict that validates but is not `ok` is not a stall, and recovery dispatches
(#1937's) don't count against the retry.

**Everything else is unchanged.** Exit codes 0, 14, 10, 11, 12, 13, 2 and 1 take
their existing paths, from the status JSON alone — except a mid-run exit 2 on
the CARRY-UNACCOUNTED, CADENCE or never-ran arm, which takes
`#### Verdict recovery arms (#1937)`.
Promotion, residue and
escalation stay in the conductor, because each needs a human. A promotion
sub-loop's rounds dispatch the same panel, decide, risk and fix subagents
(`reference/promotion.md`).

**The structural criterion.** The conductor reads only verdicts, status JSON and
its work-dir state — never reviewer output, a findings file's contents or a
diff. There are two named exceptions, both human-driven: NOT APPLICABLE option
(2) on a full round (step 2), *"you read the story diff yourself"*, which only
the human can choose; and the promotion seed procedure with its step-7
verification (`reference/promotion.md`). The risk pass (#1921) is not an
exception: while `corner_case_risk_threshold` is on, the risk subagent assesses
the aggregate and the conductor passes its verdict's `risk_file` as `--risk`
unopened; when the threshold is off or ignored, no risk subagent is dispatched.

#### Verdict recovery arms (#1937)

This is the one statement of what the conductor does with a non-`ok` panel
verdict, and with the loop's CARRY-UNACCOUNTED, CADENCE and never-ran
refusals. Each row names an arm
that already exists; for its reasoning read that arm, which is not restated
here.

**A non-`ok` panel verdict is boundary step 3 refusing or aborting the round.**
Stop the gate with the handle step 2 recorded, then take the arm below. An arm
that resumes the round resumes at step 1, except on a no-fix round, exactly as
step 3 says. **A non-`ok` verdict from a `carry-repair` or `carry-redispatch`
panel takes no row:** its gate has already finished, so nothing is stopped or
resumed, and it is that ground's cap — report-and-stop.

**Dispatch on `cause`.** `not-applicable` and `story-diff-empty` pair with
`not_applicable`; the other nine causes pair with `failed`. A verdict whose
outcome/cause pair is off this table is report-and-stop.

| `cause` | `outcome` | arm |
|---|---|---|
| `dimension-not-run`, `render-failed` | `failed` | step 2's **FAILED** arm: one fresh round-mode panel; the same cause again is report-and-stop |
| `fix-verification-null` | `failed` | the FAILED arm's null carry: re-run the carry precondition on `verify-<R>.json`, then one fresh round-mode panel, whose brief plans with `--fix-verification`; the same cause again is report-and-stop |
| `fix-verification-unreadable` | `failed` | the FAILED arm's unreadable carry: re-run the carry precondition — an unreadable `verify-<R>.json` is report-and-stop — then one fresh round-mode panel; the same cause again is report-and-stop |
| `carry-unconfirmed` | `failed` | the **missing-confirmation** arm: one fresh round-mode panel, and "if the re-run again reports no confirmation count, report it in the conversation and stop" |
| `plan-failed` | `failed` | report-and-stop: the panel brief has already fixed and re-run a `plan` exit 2 once |
| `wrong-worktree-root` | `failed` | report-and-stop: the panel brief has already re-planned against the implementation worktree |
| `empty-excerpt` | `failed` | report-and-stop: the panel brief has already applied *An empty excerpt is not always a stop*, and a fresh panel "fails the same way" |
| `no-agent-tool` | `failed` | report-and-stop |
| `not-applicable` | `not_applicable` | the **NOT APPLICABLE on a full round** arm: autonomous, stop with no commit and no PR; interactive, its three options, none taken without an explicit choice. Never coerced to `[]`, and the panel is not re-run |
| `story-diff-empty` | `not_applicable` | the **empty story diff** shape: go back to **§2 (Implement)** and take the boundary again, or, if the story needs no code change, say so and stop. The three NOT APPLICABLE options are never offered, and, per the #1485 note, neither the re-invoke arm nor the panel re-run arm is taken |

**The never-ran arm is not a verdict.** It applies only when the conductor can
show that no panel subagent was dispatched this round — on a missing/empty
STALE_FINDINGS refusal, say. Dispatch one round-mode panel, then a decide
subagent over its aggregate, then re-invoke. A
panel that was dispatched and returned no valid verdict is a stall, not
never-ran.

**CARRY-UNACCOUNTED.** A mid-run exit 2 on that arm takes this section. Read the
ground from the loop's refusal stderr and the status JSON's
`carry_unconfirmed[]` — loop output, never reviewer output. First apply
the #1647 tool-verdict exception: an entry stamped `"decided": "red"` in
`verify-<R>.json`, or one the *Decide subagent brief*'s narrow `decided-<R'>.log`
lookup finds a red for, is a tool-verdict carry — report it and its `decides:`
command and stop, dispatching nothing. Otherwise, by ground (*Carry accounting →
Recover by ground*):

- **no accounting supplied, a file of the wrong shape, a record naming no
  carried identity** → one panel in **`carry-repair`** mode, `carry_entries`
  every carried identity projected from `verify-<R>.json`. On `ok`, re-invoke
  with the same `--findings-file` and the rebuilt `--carry-accounting`; no
  decide dispatch follows;
- **an unevidenced re-raise, an entry neither confirmed nor re-raised** → one
  panel in **`carry-redispatch`** mode, `carry_entries` the refused identities
  only. On `ok`, dispatch a decide subagent over the merged aggregate, then
  re-invoke.

The cap is that arm's own, per ground: "If the re-run again leaves an entry
unaccounted, report it in the conversation and stop". A different ground takes
its own arm once.

**A stalled `carry-redispatch` is restored, not re-merged.** Before that
dispatch, copy `findings-round-<R>.json` and `carry-lines-<R>.txt` to
`<work-dir>/findings-round-<R>.pre-carry.json` and
`<work-dir>/carry-lines-<R>.pre-carry.txt` without opening them, and before its
stall re-dispatch restore both over the originals, so the retry merges and
appends exactly once. A failed copy or restore is report-and-stop.
`carry-repair` takes no snapshot: it only reads the lines and rebuilds the
accounting, so a re-dispatch repeats it exactly.

**Every recovery is a fresh subagent with a fresh handoff.** The FAILED re-run,
the missing-confirmation arm, the never-ran arm and the CADENCE re-run dispatch
in `round` mode, reusing the original `delta_base` and `carried_finding_ids`
with `carry_entries` `[]`. Before every recovery dispatch, rewrite
`handoff-<R>-panel.json` with `round-handoff.zsh write-handoff` and clear as
*Before every dispatch, clear* says for its mode, which always deletes the
previous `verdict-<R>-panel.json`, so a stalled recovery reads as a stall and
never as the superseded verdict.

**The CADENCE refusal, in full.** First the *Decide subagent brief*'s sequence,
unchanged. Then, for the panel re-run recovery: mint a fresh `--findings-tree`,
dispatch a new round-mode panel, dispatch a decide subagent over its aggregate,
and consolidate with the fresh `--findings-tree` and the **held**
`--gate-attest`, or with it omitted — never the fresh mint. The other recovery,
discarding the fix and re-consolidating, dispatches no panel.

**Caps and the stall retry are separate.** Each arm's cap is its own, and never
the stall retry. The stall retry applies to every recovery dispatch as to any
other — for a `carry-redispatch`, after the snapshot restore — and a recovery
dispatch neither consumes nor resets it. A verdict that validates but is not
`ok` is never a stall.

#### Panel subagent brief

You review one round, in place of the conductor. Read your handoff with
`round-handoff.zsh read-handoff --file <the handoff path your prompt names>`;
the scripts below are under `<skill-base-dir>/scripts/`. Work in the handoff's
`worktree_root`, never your cwd (ARCHITECTURE.md, *Where a subagent works*).
Steps 1–5 are `round` mode. A `carry-repair` handoff takes *Carry modes* below
instead; a `carry-redispatch` handoff runs steps 1–5 with the changes *Carry
modes* names.

1. **Plan.** Run `review-dispatch.zsh plan --repo <worktree_root> --base <base>
   --round <round>`. From round 2 on, add `--prior-tree <delta_base>`,
   `--fix-verification <work_dir>/verify-<round>.json` and `--adjudicated
   <work_dir>/adjudicated.json`. Step 1 above governs when to add `--final`, the
   plan's exit codes, and the `worktree_root` check. **On a carried round, split
   the carry by owner (#2010):** run `review-dispatch.zsh split-carry
   --fix-verification <work_dir>/verify-<round>.json` and keep the
   `{dimension: path}` map it prints; never write `verify-<round>.json`, which
   stays the loop's carry. Its exit 2 is your own malformed invocation — fix it
   and re-run once; an exit 1, or a second exit 2, is `failed` /
   `fix-verification-unreadable`.
2. **Dispatch the reviewers** of the plan's `review_skill` and of every
   `topic_review_skills` entry (*Topic panels*), exactly as each skill's own
   Step 1 says. Its `SKILL.md` is in the same plugin cache as `<skill-base-dir>`:
   `<plugin-root>/<plugin>[/<version>]/skills/<skill>/SKILL.md`. Build each
   prompt as step 1 and *Build each reviewer's scope block* say, carry included
   — each reviewer's Fix verification line names only the path the map gives
   its own dimension, and a reviewer whose dimension the map does not hold gets
   no such line (*Carry accounting*).
   **Dispatch every reviewer in the foreground** (`run_in_background: false`),
   all in one message, whatever that skill's Step 1 says: a background dispatch
   returns before the reviewer replies (ARCHITECTURE.md, *Subagent dispatch
   mechanism*).
3. **On a carried round, settle the carry before writing anything.** Check that
   every carried entry was accounted for by its owning dimension's reviewer —
   judged by the per-entry lines, whose checksum is that the reviewers' TOTALs
   sum to the length of the file step 1 split;
   re-dispatch, once, only a reviewer that left any entry of its own
   dimension's file without a per-entry line, with the prompt step 2 built
   for it — inside the panel subagent, that is what *Carry accounting*'s
   "re-dispatch the panel" means — and keep only its second reply. Then append
   every reviewer's per-entry lines to `<work-dir>/carry-lines-<R>.txt` — one
   owner's line per entry. A script reviewer counts as one (#2008): the
   claude-plugin panel's `check-manifests.zsh` writes its per-entry lines and
   triple to its `--carry-out` file, which you append to `carry-lines-<R>.txt`
   unchanged, and its records name `check-manifests.zsh` as the `manifest`
   owner. Then assemble
   `<work-dir>/carry-round-<R>.json` from them, as *Carry accounting* says.
4. **Write the aggregate once** — every panel's findings joined unchanged, a
   re-dispatched reviewer's from its second reply — to
   `<work-dir>/findings-round-<R>.json`, never to the dispatch sink
   `findings_path`, which the loop truncates and refuses.

   You have no `Write` tool: write every file in steps 3 and 4 with a quoted
   heredoc — `cat > <file> <<'EOF'` to create one, `cat >> <file> <<'EOF'` only
   to append each reviewer's lines to `carry-lines-<R>.txt` — never an unquoted
   one or an interpolated string, so reviewer text that holds backticks or `$`
   lands unchanged.
5. **Write a `panel` verdict** with `round-handoff.zsh write-verdict --work-dir
   <work_dir>`: on success, `ok` with the aggregate's path and length and the two
   carry files (both `null` on round 1 or an empty carry). Return to the
   conductor only that the verdict was written.

**Recover inside the dispatch before returning a non-`ok` verdict.** Three
arms are yours, not the conductor's:

- a `plan` **exit 2** is your own malformed invocation: fix it and re-run once,
  as *A non-zero `plan` exit is never a scope* says. Return `plan-failed` only
  on exit 1, exit 3 or a second exit 2;
- a `worktree_root` that is not the implementation worktree: re-plan against
  the implementation worktree, as step 1's check says. Return
  `wrong-worktree-root` only when the re-planned descriptor still names the
  wrong root;
- an empty excerpt: apply *An empty excerpt is not always a stop*, and
  re-confirm `worktree_root`, before returning `empty-excerpt`.

**Carry modes.** Both write a `panel` verdict exactly as step 5 does.

- **`carry-repair`** dispatches no reviewers. Read `<work-dir>/carry-lines-<R>.txt`
  — one owning reviewer's line per entry since #2010 —
  rebuild `<work-dir>/carry-round-<R>.json` from those lines, and leave
  `findings-round-<R>.json` byte-unchanged. On success the verdict is `ok` with
  that untouched aggregate and its length, the rebuilt `carry-round-<R>.json`
  and `carry-lines-<R>.txt`. When the lines cannot produce a valid accounting,
  return `failed` / `carry-unconfirmed`.
- **`carry-redispatch`** runs steps 1–5 with an **empty** scope and a verify
  file naming only `carry_entries`, as *Carry accounting → Recover by ground*
  says. First project the `verify-<R>.json` entries that `carry_entries` names
  into `<work-dir>/verify-<R>-carry.json` with `jq`; never write
  `verify-<R>.json`, which stays the loop's carry. Step 1 then plans with
  `--prior-tree <tree_id>` in place of `<delta_base>`, so the delta is empty,
  and `--fix-verification <work-dir>/verify-<R>-carry.json`, and never adds
  `--final`. Step 1's split runs on `verify-<R>-carry.json` instead, so
  `carry_entries` are grouped by `dimension` and step 2 dispatches **only**
  each group's owning reviewer (#2010) — never the whole panel, and a
  dimension with no group is not dispatched, which is not
  `dimension-not-run`; the handoff's
  `carry_entries` stay the flat `round-handoff/v1` array.
  Steps 3 and 4 keep their re-dispatch and quoted-heredoc rules on
  these paths: write their output to `<work-dir>/findings-round-<R>-carry.json`,
  merge it into `findings-round-<R>.json` (`jq -s 'add'`) once, atomically,
  append their per-entry lines to `carry-lines-<R>.txt`, and re-assemble
  `carry-round-<R>.json` from every line in that file. The verdict is `ok` with
  the merged aggregate and its length, `carry-round-<R>.json` and
  `carry-lines-<R>.txt`. Never retype or reword a finding.

Where step 1 or the sections it defers to would stop the round, return a
non-`ok` verdict instead, and write no findings file:

| Situation | `outcome` / `cause` |
|---|---|
| a planned dimension did not run | `failed` / `dimension-not-run` |
| a reviewer prompt or a review skill could not be rendered or found | `failed` / `render-failed` |
| round ≥ 2 and the plan's `fix_verification_path` is `null` | `failed` / `fix-verification-null` |
| that path is set but a reviewer could not read it | `failed` / `fix-verification-unreadable` |
| a carried entry is still unaccounted after the one re-dispatch | `failed` / `carry-unconfirmed` |
| `plan` exited non-zero, and step 1 does not say to fix and re-run | `failed` / `plan-failed` |
| `worktree_root` is not the implementation worktree | `failed` / `wrong-worktree-root` |
| a `[DELETED by this story]` excerpt came back empty | `failed` / `empty-excerpt` |
| a full round whose story diff is empty | `not_applicable` / `story-diff-empty` |
| the language panel reported NOT APPLICABLE on a full round | `not_applicable` / `not-applicable` |
| you have no `Agent` tool | `failed` / `no-agent-tool` |

**Planned** is the review skill's own Step 1 table, read for this round (#2008).
A dimension that table does not plan this round produces no verdict at all —
it is neither run nor missing, so it never raises `dimension-not-run`. Rounds
are told apart by the plan's `scope_mode` and the split-carry map, never by the
round number alone (round 1 and every closing sweep are both `"full"`); a
dimension skipped on delta rounds comes back by *Carry-driven dispatch
(#2008)*. `round-verdict/v1` and the cause vocabulary above are unchanged.

Never author a finding, edit one, or write `[]` on a reviewer's behalf.

#### Fix subagent brief

You apply one round's fix pass, in place of the conductor. Read your handoff
with `round-handoff.zsh read-handoff --file <the handoff path your prompt
names>`. Work in its `worktree_root`, never your cwd: first confirm that `git -C
<worktree_root> rev-parse --show-toplevel` prints that path, and if it does not,
edit nothing and return `failed` / `cannot-fix`. The fix subagent dispatches
nothing, and never commits, pushes, or runs the gate.

- **`trigger: awaiting-fix`** → implement every item of the `blocking` array in
  the `changelist` file, exactly as step 3 says:
  sibling-sweep each pattern, and subtract rather than add (*A fix pass
  subtracts*), parking — and filing — what rule 1 refuses.
- **`trigger: gate-red`** → read `gate_log`, find what is red, and fix it.

On either trigger, apply `grant.severity_bar` when a grant is set, the human's
`guidance`, rule 2's collapse as **mandatory** when `rule2_mandatory` is `true`
(advisory otherwise, *The third histogram state*), and the profile's *Fix-pass
rules* when the prompt carries them. Then write a `fix` verdict with
`round-handoff.zsh write-verdict --work-dir <work_dir>`: `ok` with
`fix_applied` and `files_changed` (the number of distinct files you edited), or
`failed` / `cannot-fix` with `fix_applied: false` and `files_changed: 0` when
you could not fix it. Return to the conductor only that the verdict was written.

#### Decide subagent brief

The decide subagent runs one round's decided pass in place of the conductor.
This brief states what it does and what the conductor does around it; the
per-finding procedure — which commands run, how each verdict is settled, the
malformed shapes and the retirement rule — is *The decided pass* above, and is
not restated here. The conductor dispatches `subagent_type: round-decide`; the
decide subagent dispatches nothing.

**The conductor, before the dispatch.**

- **When.** Dispatch it after the boundary's step 5 has judged the gate green,
  or straight after the panel on a round that runs with no gate — the
  closing-sweep promotion and the findings-file recovery re-invokes — and
  straight after the panel a CADENCE recovery re-runs, over its new aggregate.
  Never on a red gate, and never on a green gate that reported a tree other than
  `T`.
- **The handoff.** Write `handoff-<R>-decide.json` with `round-handoff.zsh
  write-handoff`: `aggregate_findings_file` from the panel verdict,
  `worktree_root` as *What the conductor puts in a handoff* says for every
  kind — the same value as the panel handoff's — and `retired_file` =
  `<work-dir>/decides-retired.txt`.
- **The file lifecycle.** Create `decides-retired.txt` empty before round 1's
  panel dispatch, which clears any earlier run's file. Truncate
  `decided-<R>.log` and `<work-dir>/decides-ran-<R>.txt` before the round's
  first decide dispatch; every decide subagent only appends to them, re-entries
  included. An absent retired file reads as empty. None of these writes is a
  read.

**The decide subagent.** Read your handoff with `round-handoff.zsh read-handoff
--file <the handoff path your prompt names>`; the scripts are under
`<skill-base-dir>/scripts/`. Then:

1. **Confirm `worktree_root`**: `git -C <worktree_root> rev-parse
   --show-toplevel` must print that path. If it does not, run nothing, edit
   nothing, and return `failed` / `wrong-worktree-root`.
2. **Settle every retired command as retired, without running it**, before
   anything runs: each command listed in `retired_file` is settled like an
   unrunnable one — step 5, `"decided": "green"`, logged as a writing command —
   including a finding a decide pass already decided.
3. **Run the decided pass** over `aggregate_findings_file`, as *The decided
   pass* specifies, in `worktree_root`. Step 2's findings are already settled:
   never run a command `retired_file` lists. Run every command in the foreground
   and wait for it; a `decides:` command that names the gate script is a
   decided-pass command, not the round's gate, which has already returned.
4. **Append** each finding's entry to `<work-dir>/decided-<R>.log`, and each
   distinct command you ran to `<work-dir>/decides-ran-<R>.txt`, one per line.
5. **Write the aggregate once, atomically**, after every verdict is in: write
   the whole edited aggregate to a temporary file in the work-dir and `mv` it
   over `aggregate_findings_file`, so a re-dispatch never meets a partly edited
   aggregate.
6. **Write a `decide` verdict** with `round-handoff.zsh write-verdict --work-dir
   <work_dir>`: `ok` with `cause: null` and only `decided_red`, `decided_green`
   and `malformed` (the counts of findings this pass stamped `red`, stamped
   `green`, and named malformed) and `ran_commands_file` =
   `<work-dir>/decides-ran-<R>.txt`; or, from step 1, `failed` /
   `wrong-worktree-root` with `decided_red`, `decided_green`, `malformed` and
   `ran_commands_file` all `null`. Return to the conductor only that the
   verdict was written.

**Any other failure writes no verdict.** If reading the handoff, reading
`retired_file` or the aggregate, an append, or the aggregate write or `mv` of
this brief's step 5 fails, write no verdict and return that you failed: the
conductor's stall retry takes it from there. Never write `ok` unless that `mv`
succeeded.

**The conductor, after the verdict.**

- **Risk pass, then consolidation.** Run the risk pass only after reading an
  `ok` decide verdict. Once the decide verdict is `ok`, pass the panel verdict's
  `aggregate_findings_file` as `--findings-file`. On a promotion sub-loop's
  round 1, pass instead the seeded file built from that decided aggregate
  (`reference/promotion.md`). Open neither the aggregate,
  `decides-ran-<R>.txt` nor `decides-retired.txt`.
- **Narration.** Report the verdict's `decided_red`, `decided_green` and
  `malformed` counts and the `decided-<R>.log` path. Findings are named in
  `decided-<R>.log` only.
- **Non-ok and stall.** A decide verdict that is not `ok` is report-and-stop,
  with no consolidation. The stall retry above applies unchanged: one fresh
  re-dispatch on a `read-verdict` exit 3, then report-and-stop.
- **A CADENCE refusal right after a decide pass**, in this order:
  1. append `decides-ran-<R>.txt` to `decides-retired.txt` without reading it;
  2. dispatch a fresh decide subagent over the same aggregate, which re-settles
     the retired commands' findings and runs none of them — a recovery dispatch,
     not a stall re-dispatch;
  3. only then take either of that arm's recoveries. Re-running the panel
     needs a decide pass over its new aggregate, as *When* says.
- **A CARRY-UNACCOUNTED refusal naming a tool-verdict carry** (*The decided
  pass*'s KNOWN LIMITATION). To report the entry and its `decides:` command, the
  conductor may look up only the `decided-<R'>.log` entries matching a
  `carry_unconfirmed[]` identity's `file` and `dimension`, reading only their
  `decides:` command and exit status. That lookup happens only on that
  report-and-stop path, and it counts as work-dir state.

#### Risk subagent brief

The risk subagent makes one round's risk assessment in place of the conductor.
This brief states what it does and what the conductor does around it; the
assessment itself — what is eligible, how `p` and `impact` are judged, the
`risk-<R>.json` shape — is *The risk pass* above and `reference/residue.md` §
*1. Assess every residual blocker*, and is restated by neither. The conductor
dispatches `subagent_type: round-risk`, in the foreground
(`run_in_background: false`), one fresh subagent per job; the risk subagent
dispatches nothing.

**The conductor, before the dispatch.**

- **Threshold.** Read `corner_case_risk_threshold` and take one of its three
  states, as *The risk pass* says. **Off** or **ignored**, or **hook mode**:
  dispatch no risk subagent and pass no `--risk`; ignored keeps its narration
  line and PR Summary note. **On**, in step mode: dispatch it every round, the
  promotion sub-loop's rounds and the closing sweep included.
- **Sequencing.**
  1. Dispatch the risk subagent only after reading an `ok` decide verdict for
     the round's latest decide dispatch.
  2. Pass `--risk` only with the `risk_file` of an `ok` risk verdict whose
     dispatch came after that decide verdict.
  3. Whenever the aggregate changes after a risk dispatch — a fresh decide
     dispatch (the CADENCE sequence) or a carry recovery's merge — re-dispatch
     the risk subagent before the next invocation that passes `--risk`.
- **The handoff.** Write `handoff-<R>-risk.json` with `round-handoff.zsh
  write-handoff`: `aggregate_findings_file` the file the round passes as
  `--findings-file` (*Risk pass, then consolidation* above; on a promotion
  sub-loop's round 1, the seeded file, built in the work-dir),
  `worktree_root` as *What the conductor puts in a handoff* says for every kind,
  and `tree_id` the round's `T`.
- **Clear before every risk dispatch.** Delete `<work-dir>/verdict-<R>-risk.json`
  and `<work-dir>/risk-<R>.json`. A delete that fails is report-and-stop.

**The risk subagent.** Read your handoff with `round-handoff.zsh read-handoff
--file <the handoff path your prompt names>`; the scripts are under
`<skill-base-dir>/scripts/`. Then:

1. **Confirm `worktree_root`**: `git -C <worktree_root> rev-parse
   --show-toplevel` must print that path. If it does not, write nothing and
   return `failed` / `wrong-worktree-root`.
2. **Assess** every `CRITICAL` and `WARNING` finding in
   `aggregate_findings_file` as *The risk pass* says: afresh, never copied from
   an earlier round, with `p`, `impact` and both rationales.
3. **Write `<work-dir>/risk-<R>.json` once, atomically**, in the #1920 shape —
   the identity verbatim, a digit-string `line` as the number it spells, `[]`
   when nothing is eligible — to a temporary file in the work-dir, then `mv` it
   into place.
4. **Write a `risk` verdict** with `round-handoff.zsh write-verdict --work-dir
   <work_dir>`: `ok` with `cause: null`, `risk_file` = `<work-dir>/risk-<R>.json`
   and `assessed_count` the number of entries in it. Return to the conductor
   only that the verdict was written.

When you cannot read or parse the aggregate, or cannot assess an eligible
finding, write no risk file and return `failed` / `assessment-failed`. A
`failed` verdict carries `risk_file` and `assessed_count` both `null`. The risk
subagent edits no repository file, and never commits, pushes or runs the gate.

**The conductor, after the verdict.**

- **Passing it on.** On an `ok` risk verdict, pass the verdict's `risk_file` as
  `--risk` unopened, and the handoff's `aggregate_findings_file` as
  `--findings-file`. Open neither file. Narrate from `assessed_count`, the
  `risk-<R>.json` path, the status JSON and the progress block; demotions show
  in the progress block.
- **Not-ok and stall.** A risk verdict that validates but is not `ok` is
  report-and-stop. The stall retry above applies unchanged: one fresh
  re-dispatch on a `read-verdict` exit 3, then report-and-stop. Never fall back
  to threshold off, and never invoke the loop without `--risk` while the
  threshold is on.
- **A loop exit 2 naming `--risk`** — a malformed risk file, which writes no
  status JSON: make one fresh risk dispatch whose prompt carries that stderr
  line verbatim, then re-invoke the same round with the same flags. A second
  such exit 2 in the same round is report-and-stop.
