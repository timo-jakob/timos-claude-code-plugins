<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     the decided pass. -->

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
  passes**, and, on a CARRY-UNACCOUNTED refusal on the *neither confirmed nor
  re-raised* ground that names such an entry in `carry_unconfirmed[]`, do
  **not** take the carry recovery's re-dispatch: it cannot succeed until #1647
  lands, because the reviewers it re-dispatches are the ones the evidence rule
  forbids from stating that verdict, so it burns a full panel round to arrive at
  the same refusal. Report the entry and its `decides:` command — taking it from
  the log of the round that **decided** it, `<work-dir>/decided-<R>.log`,
  **not** this round's, since the command was not run this round — and stop.
  Every other ground, an unevidenced re-raise of such an entry included, takes
  its own recovery (*Verdict recovery arms*).

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
