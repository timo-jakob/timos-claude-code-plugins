<!-- Shard of reference/promotion.md (#2057), read in its index's order:
     steps 4-6 of the promotion phase, the promote file and sub-loop, the
     budget, one-shot. -->
<!-- The frozen chunk below continues the phase's numbered list at item 4, so
     its numbering cannot restart at 1 here. -->
<!-- markdownlint-disable MD029 -->

<!-- moved: suggestion-promotion-step-4 -->
4. **Write the promote file and run the sub-loop.** The selected identity keys
   go to a JSON array file **outside the repo** (the scratch dir the work-dir
   and findings files already live in, §3.5 — anything written inside the repo
   changes the tree identity and defeats every `--gate-attest` match). Then run
   the promotion sub-loop exactly like the blocking phase — a **fresh
   `--work-dir`** and a **`--status-file` path distinct from the blocking
   phase's kept status JSON** (the `rm -f` below deletes **the promotion status
   file**, and §6 still needs the blocking-phase one), the same `--test-cmd`,
   the round protocol above — adding `--promote`. Its fix passes are bound by
   *A fix pass subtracts* (§3.5's round protocol, step 3)
   exactly like the blocking phase's — with the human's promoted picks among
   the overrides rule 1 names, so a pick whose smallest fix really is a new arm
   is applied rather than parked back to the person who asked for it. Read the
   rule there; it is not restated here.

   **Do not run the command below yet.** Round 1's `--findings-file` is the
   **seeded** file built by the ordered procedure that follows, and a
   NONE-matched classification means the sub-loop is never invoked at all. Read
   the procedure first, then come back to this invocation.
   **`rm -f <promotion-status.json> && [[ ! -e <promotion-status.json> ]] ||
   { echo "could not delete the promotion status file — its existence is no
   longer a signal; do NOT invoke the sub-loop"; exit 1; }` immediately before
   every invocation** (round 1, each `--resume`, each recovery re-invoke) so
   step 7's exit taxonomy can tell a status this invocation wrote from one the
   last one left behind — and so a *failed* delete is visible rather than
   silently turning the next exit's taxonomy into a guess. **On a failed delete,
   do not invoke the sub-loop at all**: step 7 could not then tell this
   invocation's verdict from the previous one's. Report it in the conversation
   and stop, or point `--status-file` at a fresh, deletable path and continue:

   ```bash
   "<skill-base-dir>/scripts/resolve-story-loop.zsh" --repo <repo> --base <base> \
     --work-dir <promotion-work-dir> --status-file <promotion-status.json> \
     --issue <N> --findings-file <findings-promo-round-R.json> \
     --promote <promoted.json> --test-cmd '<full gate>' [--resume] \
     [--gate-attest <T>] [--findings-tree <T>]
   ```

   The consolidator raises each matching Low to `WARNING`/`High` **before** the
   conflict and non-convergence classification, so a promoted item is blocking
   in every downstream sense — and a regression introduced while fixing one is
   gated exactly like any other blocker. Matching **reuses the #983 identity
   rules** (gather on file + dimension + line proximity, decide by normalized
   title), so **a promoted item survives its own fix shifting the line** rather
   than silently reverting to Low.

   **Establish what is still there, then seed only what needs it.** The overlay
   can only *raise* a Low that is present in **that round's** findings — it never
   injects one. But the waived set is the cross-round union, so a suggestion
   raised in round 1 and never re-raised (exactly the case step 1 exists to
   cover) would match nothing in the sub-loop's fresh panel: zero blockers,
   `CONVERGED` on round 1, and step 7 would read that as the promoted set having
   been cleared when it was never even seen.

   This is an **ordered procedure**, not a set of independent rules — running it
   out of order destroys the evidence the verification needs:

   1. **Run the round-1 panel and keep its aggregate at its own path**
      (`<pre-seed-round-1.json>`, in the same scratch dir outside the repo as
      the promote file and the work-dir — §3.5). This is the verification
      baseline; do not overwrite it.
   2. **Classify each promoted key against that file**, in the *engine's* terms
      and never by exact key equality: it was **raised** when the panel reported
      an item with the same `file` and `dimension`, a line within the proximity
      window (**±10 lines**; an absent or null line is a wildcard within the
      file+dimension — ARCHITECTURE.md's consolidate-findings contract), and a
      title not fully disjoint from the promoted one (the #983 rules the overlay
      applies). A literal key-appearance check would call a
      genuinely present item missing the moment dedup kept a different
      representative title or its line drifted.
      - **Raised** → **matched, and it needs no seed**: the overlay will raise
        the panel's own item, which is the one at the *current* line. Seeding a
        second copy from the blocking phase's stale `line` would survive dedup as
        a separate entry, and the same defect would be raised twice — with the
        fix pass sent to a line where it no longer is.
      - **Not raised** → **look before calling it gone.** A panel is not
        deterministic, so silence is absence of evidence, not evidence of
        absence — and this branch ends in a claim in the PR body. Open the cited
        **`file`** and look for the defect the changelist item's
        `title`/`description` names — **search the file, not just the cited
        line**: the blocking phase's own fixes shift lines, which is exactly why
        the engine matches by identity rather than by line. Three outcomes, each
        with its own class:
        **still there (anywhere in the file)** → **matched**: this is what the
        seed is for. Seed it (projected as below) using **the line you actually
        found it at**, not the stale cited one — **and re-anchor the key to
        match**: rewrite that key's `line` in `<promoted.json>` to the same found
        line (or to `null`, the documented file+dimension wildcard) before
        invoking the sub-loop. The overlay gathers candidates within ±10 of the
        **key's** line, so a seed at the found line while the key keeps the stale
        one is never gathered — the item stays Low and the promotion silently
        fails to fire;
        **confirmably gone** (the pattern is absent from the whole file, or the
        file is) → **unmatched**;
        **cannot tell** → **unverified** — a third class, not a flavour of
        unmatched: do not seed it, do not count it matched, and never fabricate
        a change to satisfy a blocker you cannot locate.
   3. **Build the round-1 findings file** as the pre-seed aggregate **plus only
      the still-present-but-unraised keys** from step 2.

   **Projecting a seed.** `round_changelists[]` holds *consolidator output*
   (`priority`, `blocking`, `reviewers[]`, `agreement`), not findings, so copying
   one verbatim lands it with no `reviewer` — it then shows as `agreement: 0`,
   attributed to nobody, in progress.md and the dossier. Project instead, taking
   the fields from the **changelist item** you find by looking the promoted key
   up in `<status.json>`'s `round_changelists[]` on
   `[file, line, dimension, title]` (the key itself carries only those four, so
   `description` and `suggested_fix` can come from nowhere else). **Project the
   seed BEFORE re-anchoring the key**, and look it up on its **original**
   (as-derived) `line`: `<status.json>` only ever holds the stale line, so a key
   already re-anchored to the found line — or to `null` — matches nothing there,
   and the fields it says can come from nowhere else would have to be
   fabricated. If you have already re-anchored, look the item up on
   `[file, dimension, title]` alone:
   `{severity: "SUGGESTION", round: 1, dimension, file, line, title, description,
   suggested_fix, reviewer}` — where `line` is **the line you FOUND it at**, the
   same one you re-anchor the key to, never the changelist item's stale one (a
   seed outside the key's ±10 gather window is never raised, and step 7 would
   then report a still-present item as promoted-but-not-reproducible) (the #558 schema declares `round`), with `reviewer`
   from that item's `reviewers[0]`, or `"promoted-by-human"` when it has none.

   **Keep the matched set** — every key classed matched in step 2, seeded or not
   — in the **same scratch dir outside the repo** as the promote file and the
   work-dir (a file written inside the repo changes the tree identity, defeats
   every `--gate-attest` match, and risks being committed at §5). It is the set
   §6 **reconciles against the engine's raised count** (`promotion.promoted`) —
   not itself the cleared figure: a matched key the engine never raised is
   reported as promoted-but-not-reproducible, never counted as cleared.

   - **Report each class in the PR body's Summary by its own name** — never
     collapse them: **unmatched** keys are *promoted but no longer present*;
     **unverified** keys are *promoted but could not be verified*. Saying "no
     longer present" about a key you could not check is the one claim this whole
     procedure exists to prevent.
   - **If some keys matched**, continue as step 7. **If NONE matched**, treat the
     run as converged **with nothing promoted**, say so plainly, note the split
     between unmatched and unverified in the Summary, and continue to **§4
     (Version bump)** — via the **residue branch** first when the blocking phase
     ended `CONVERGED_WITH_RESIDUE`, which is ordered immediately before §4 and
     is the step that files the remainder §6 then requires you to name. Do not
     escalate and do not re-prompt — but never let a
     bare `CONVERGED` imply work that never happened.

   **Re-pass `--promote` on EVERY invocation of the sub-loop** — each
   `AWAITING_FIX` `--resume`, the interactive extension's resume, and a
   `STALE_FINDINGS` recovery alike. The loop persists the promoted set in its
   work-dir and re-adopts it when the flag is absent, so a slip degrades to a
   warning rather than a silent un-promotion — but do not rely on that: pass it
   explicitly, because an explicit `--promote` is what keeps the command you run
   and the overlay that is applied the same thing.

5. **Budget — the same one as the blocking phase.** Pass **no
   `--max-rounds` override**: the sub-loop inherits the loop's own
   `MAX_REVIEW_ROUNDS` default and is extended by the identical
   +3-per-approval interactive extension. There is deliberately **no second
   budget constant** — one number governs both phases.

   **`grants` starts at 0 for the promotion phase.** It is a separate loop with
   its own work-dir and its own ceiling, so it gets its own counter rather than
   inheriting the blocking phase's total; otherwise a story that spent four
   grants clearing real blockers would hit the soft-cap nudge on the promotion
   phase's *first* grant and be told "this isn't converging" about a phase that
   has consumed nothing. When you summarize an escalation here, report **both**
   counts ("2 grants this phase; 4 earlier on the blocking phase") so the human
   sees the story's true cost.

6. **One-shot.** New suggestions surfacing *during* the sub-loop are waived, not
   re-prompted — this phase runs once per story. New blockers (regressions)
   gate normally.
<!-- /moved: suggestion-promotion-step-4 -->
