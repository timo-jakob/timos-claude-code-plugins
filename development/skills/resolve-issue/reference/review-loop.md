# Review loop — the round protocol

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

It carries §3.5's round protocol, including the loop's invocation
template.

Every `<!-- moved: … -->` block below is byte-identical to the text it was
carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit, and is what keeps this file honest.

**One region is outside that proof.** The text between
`<!-- /moved: round-protocol-head -->` and `<!-- moved: round-protocol-tail -->`
is NEW prose (#1582's reviewer-path rule), verified by nothing — the gate proves
only that no *original* line migrated into it, by asserting the two anchors stay
adjacent in the pinned commit. Edit that region knowing the byte check does not
cover it.

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
blockers landed, and step 1 requires a carried entry to be re-raised when it
cannot be confirmed **even when its file is outside this round's delta** — so on
a delta round that file is, by construction, not in the scope block. Left there,
the two rules collide: a reviewer honouring the sentence above declines to open
it and re-raises a blocker that was in fact fixed (every round, trending the run
to `ESCALATE_NO_CONVERGENCE`), and a reviewer that opens it anyway has only the
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
> that the carried blocker landed, and **re-raise it at its original severity if
> you cannot**. Where it carries the note **`exists in neither tree`** instead,
> the file the finding was about is in no tree the round can read: **count the
> entry as confirmed, say so in your count, and do not re-raise it.** The scope
> block's *neither raise a finding nor fail the round* rule covers reviewing the
> deletion as new work; it never licenses leaving a carried entry unaccounted
> for.

The two forms are why the blockquote keys on **which of them the entry carries**
rather than on the marking alone. An entry with no excerpt and no note would
leave the reviewer unable to confirm and obliged to re-raise — every round, on a
file that can never come back — so the run would trend to
`ESCALATE_NO_CONVERGENCE` on a blocker the fix pass legitimately disposed of.
Emit one or the other, never neither.

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
account for the blocker, from the excerpt, and re-raise it if it cannot confirm.
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
