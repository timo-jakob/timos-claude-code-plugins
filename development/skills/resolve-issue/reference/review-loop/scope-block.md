<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     the #1582 reviewer scope block, descriptor confirmation and antecedent probe. -->

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
