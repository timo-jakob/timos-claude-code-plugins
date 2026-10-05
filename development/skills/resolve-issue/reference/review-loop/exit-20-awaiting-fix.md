<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     round steps 3–4: AWAITING_FIX (exit 20), the fix pass, and terminal statuses. -->
<!-- The frozen chunk below continues the round protocol's numbered list at
     item 3, so its numbering cannot restart at 1 here. -->
<!-- markdownlint-disable MD029 -->

<!-- moved: round-protocol-steps-3-4 -->
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
<!-- /moved: round-protocol-steps-3-4 -->

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

**Every fix pass also applies the loaded profile's fix-pass rule (#1805).**
Step 3's fix pass sits inside the byte-frozen span, so this is recorded here:
read the heading below and apply its rule to each fix pass, unless its body
begins with `none` (the conductor's §1b test). With no profile loaded there is
nothing to apply.
profile: `development-<repo_type>:resolve-profile` § Fix-pass rules
