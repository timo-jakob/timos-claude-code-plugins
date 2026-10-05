<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     the round protocol's head: the concurrent round boundary, steps 1–7, and the end-the-turn wait. -->

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

**Each round continues in the shards `reference/review-loop.md` lists (#2055)**:
read them in its read order before round 1's step 1.
