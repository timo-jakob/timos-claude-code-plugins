# Suggestion promotion

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

It carries the phase offered on a convergence of an interactive run that
waived at least one suggestion.

Every `<!-- moved: … -->` block below is byte-identical to the text it was
carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit, and is what keeps this file honest.

## Suggestion promotion on convergence — human-curated, opt-in (#994)

<!-- moved: suggestion-promotion -->
Low suggestions never block, so every one the panel raises is **waived** the
moment it is surfaced — logged and never actioned. That is the right default,
but it leaves a human no way to say *"actually, do that one"* at the one moment
they have the full picture and the PR is otherwise ready. This phase is that
opt-in, and nothing else: **suggestions stay non-blocking by default and nothing
is ever auto-promoted.**

**Gate — both conditions, or skip the phase entirely.** Offer it only when the
run is **interactive** (the same human-present determination §0a's remediation
uses) **and** the waived set is non-empty. An **autonomous / headless run never
prompts and never passes `--promote`**: it converges with its suggestions
waived, byte-identically to before this feature existed. Selecting *none* skips
the sub-loop and converges unchanged — but it is still a **presented prompt**, so
step 3's enrichment record (`suggestions_promoted: 0`) is emitted *first*
(subject to step 3's no-id rule — an absent or empty sidecar means no record at
all). Only
an autonomous / headless run, which never prompts, is byte-identical to before
this feature existed.

**First, locate the run's telemetry id (#995).** The blocking phase's terminal
exit wrote the `run_id` of the record it just emitted to
`<blocking-phase-work-dir>/.telemetry-run-id`. Step 3 reads it **directly from
there**, inline, at the moment it emits:

```bash
cat <blocking-phase-work-dir>/.telemetry-run-id     # the join key, read at emit time
```

Two things not to do with it, each of which silently breaks the join:

- **Do not hold it in a shell variable.** Step 3's emit runs after one or more
  `AskUserQuestion` turns, and each `bash` invocation is its own shell — a
  `RUN_ID=…` set here is unset there, the emitter refuses the empty `--run-id`
  with exit 2, and the "never fatal" rule below swallows it, so the enrichment
  silently never lands, on every run.
- **Do not copy it to a fixed scratch path first.** A scratch dir is reused
  within a session (a human resolving several issues back to back; a re-run
  after an escalation), and a copy that fails — the source is absent whenever
  telemetry was skipped, and it fails *silently* — leaves an **earlier story's**
  id at that path to be read as this run's. The work-dir path has no such
  hazard: it is per-run, and the loop clears it on a fresh start and rewrites it
  on every terminal exit.

**Absent or empty is not an error.** Most often it means no record was emitted —
telemetry is best-effort — and there is then nothing to join to: skip the
enrichment entirely and run the phase as normal. Before concluding that, confirm
the path you are reading is the **blocking phase's** `--work-dir` (the one you
passed at §3.5), not a defaulted temp dir or the sub-loop's. Never mint or invent
a `run_id` to fill the gap; a fresh id would validate cleanly and be permanently
orphaned.

1. **Derive the waived set.** It is the **cross-round union of distinct Low
   findings**, keyed `[file, line, dimension, title]`, over the status JSON's
   `round_changelists[]` — the same set `build-telemetry-record.zsh` already
   counts as `waived`, so the prompt and the telemetry record can never
   disagree. It is **not** the final round's `suggestions[]`: that converged
   round holds only *its own* Lows, and a suggestion raised in round 1 and never
   re-raised is still un-actioned work.

   The pipeline must **dedup first, then filter** — the order
   `build-telemetry-record.zsh` uses. Filtering first would offer a key that was
   a *blocker* in an early round and Low in a later one; telemetry excludes it
   (its earliest occurrence wins), so the two surfaces would disagree and the
   human could be offered an item that was already fixed as a blocker. (The
   mirror case — Low early, blocking-and-fixed later — keeps its Low priority and
   is still offered, because the earliest occurrence wins; it falls out as
   unmatched in step 4, and telemetry counts it as waived for the same reason,
   so the two surfaces still agree.)

   ```bash
   jq -c '[ .round_changelists[]? | (.blocking[]?, .suggestions[]?)
            | {file, line, dimension, title, priority: (.priority // "Low")} ]
          | unique_by([.file, .line, .dimension, .title])
          | map(select(.priority == "Low"))
          | map({file, line, dimension, title})' <status.json>
   ```

   **If the derivation fails or yields `[]`** — a malformed status file, or a
   `--no-review`/`SKIPPED` status with no `round_changelists` — there is no
   waived set: **skip the phase and converge unchanged**. Never treat it as an
   error, and never invent a set.

2. **Render it** as a numbered list — title · `file:line` · dimension — and
   **state the stake in one line**: promoted items become blockers, so if the
   sub-loop cannot clear them the run escalates and **no PR is opened this
   run**. A human promoting one cosmetic Low from an already-PR-ready change is
   entitled to know that before they pick, not after.

3. **Multi-select** which to promote (0..N) with `AskUserQuestion`
   (`multiSelect: true`), at most **3 suggestions per question** so the fourth
   option can carry the decline — declining should be a first-class choice, not
   something the human has to express through the "Other" escape hatch.
   - **One question covers the whole set** → label the fourth option
     **"Promote nothing — converge now"**.
   - **A larger set is chunked** → selections **accumulate across chunks**, and
     the decline option is labelled **"None from this batch"** (it declines
     *that chunk*, not the phase). **Ask every chunk before acting**, and
     re-state the running selection before the last one so the human can see
     what they have picked so far.
   - **The decline option selected TOGETHER with one or more suggestions** is an
     ambiguous answer, not a resolvable one — `multiSelect` puts both in the
     same question, so the human can tick both. Re-present that chunk rather
     than deciding which half to honour; emit no enrichment until the answer is
     unambiguous.
   - **A free-text question** (the built-in **"Other"** channel used to ask
     rather than answer — "which file is #3 in?") is **not an answer**: answer
     it and **re-present the same chunk**. A question never ends the phase, the
     same rule the interactive extension applies to its own "Other".
   - **Any other free text** is the human's **final** answer: stop chunking
     (never re-prompt a chunk they have ended), then:
     - free text that **names items** ("also do #2 and #7, that's all") **adds
       exactly those** — matched by their rendered number or title, including
       items from a chunk not yet asked — to the accumulated selection, and then
       ends the phase. If any name is ambiguous, treat the answer as a
       **question** (answer it, re-present that chunk) rather than guessing
       which item was meant;
     - free text that **names no items** declines **only the remaining chunks**,
       never the earlier picks.
     Either way the phase converges unchanged only when the accumulated
     selection over **every chunk actually asked** is empty — and the prompt
     *was* presented, so step 3's enrichment is still owed.
   - **Record the answer first, then branch** (below). Converge unchanged only
     when the **accumulated** selection over **every chunk actually asked** is
     empty; otherwise proceed to step 4 of this phase with the accumulated set.

   **Record the offered-vs-promoted pair (#995) — once the answer is known,
   before either branch above.** This is the one fact the sink cannot
   reconstruct: `waived` counts what the loop *logged*, never what a human was
   *shown* or *chose*. Append **one** `telemetry/v1` enrichment joined to the
   phase-1 run, via the shared emitter (no skill hand-rolls an envelope):

   ```bash
   # the guard IS the documented "no id -> no record, silently": unguarded, an
   # absent file makes `cat` complain and the emitter exit 2 on the empty
   # --run-id, handing you a failure you are separately told never to act on
   if [[ -s <blocking-phase-work-dir>/.telemetry-run-id ]]; then
     jq -nc --argjson offered <N-offered> --argjson promoted <N-picked> \
       '{event:"suggestion_promotion", suggestions_offered:$offered, suggestions_promoted:$promoted}' \
       > <scratch>/promotion-enrichment.json   # <scratch>: the same
       # outside-the-repo dir as the work-dir and findings files (§3.5), never a
       # path inside the worktree — one more file §5 could otherwise commit
     "<skill-base-dir>/../../scripts/telemetry/emit-telemetry.zsh" \
       --pipeline review-loop --kind enrichment --outcome success \
       --run-id "$(cat <blocking-phase-work-dir>/.telemetry-run-id)" \
       --repo-dir <repo> --issue <issue-number> [--repo-type T] \
       [--telemetry-file <the same file the loop was given>] \
       --payload <scratch>/promotion-enrichment.json >/dev/null
   fi
   ```

   - **`suggestions_offered`** is the size of the set step 1 derived and step 2
     rendered (it equals the phase-1 record's `waived` by construction — same
     union, same identity — and is repeated here only so the enrichment stands
     alone without a join). **`suggestions_promoted`** is the **accumulated**
     selection across every chunk — *how many the human picked*, recorded here
     at answer time and therefore **before** step 4's matching runs. It is not a
     count of items that reached the sub-loop: a run whose keys all fall out
     unmatched/unverified legitimately carries a non-zero value with no sub-loop
     at all (step 4's "**If NONE matched**" terminal), so never divide the
     sub-loop's `fixed` by it.
   - **No `--wall-s`** — the emitter rejects it on an enrichment, and `wall_s`
     lands `null`; **`--outcome success`** describes *the enrichment event*
     (the promotion facts were settled), never the run's outcome.
   - **`--repo-dir` must be the loop's `--repo` value** (a *path* — not the
     emitter's own `--repo`, which is the `owner/name` identity), **and
     `--telemetry-file` the same `--telemetry-file`.** Since #1006 the emitter
     has three sink determinants — `--telemetry-file`, `--telemetry-dir`, and
     `--repo-dir` (via the local default) — in the precedence
     `--telemetry-file` > `--telemetry-dir` > the local default
     `<repo-dir>/.claude/telemetry/telemetry.jsonl`. A differing
     `--telemetry-file`/`--telemetry-dir` lands the record in a *different*
     sink; a differing `--repo-dir` mis-derives `repo` (and picks a different
     sink too whenever `--telemetry-file` is absent — under `--telemetry-dir`
     the derived `repo` also chooses the file inside `DIR`) — and the emitter exits 0
     either way, so nothing surfaces the loss. The loop has no
     `--telemetry-dir` of its own, so the enrichment must not pass one either:
     mirror exactly what the loop was given and the two records share a sink.
   - **Emit exactly when the prompt was presented** — that is this step. A
     headless run, or one with nothing to offer, never reaches here and gets
     **no record at all**. Promoting **none** is a *settled* fact and **does**
     get a record (`suggestions_promoted: 0`) — it is the single most
     informative datum for "do humans act on suggestions?", so emit it and
     *then* converge unchanged.
   - **No id (absent/empty `<blocking-phase-work-dir>/.telemetry-run-id`) → no
     record.** The `-s` guard above *is* that rule: skip silently and carry on.
     A failed emit is likewise never fatal — telemetry never changes what the
     run does.

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

7. **Terminal.** The sub-loop clearing the promoted set is the run's final
   `CONVERGED` → continue to **§4 (Version bump)**, taking the **residue branch**
   first when the blocking phase ended `CONVERGED_WITH_RESIDUE` (it is ordered
   immediately before §4). If the sub-loop **cannot**
   clear the promoted set — blockers still open when the budget runs out — it
   escalates through the existing taxonomy and the existing interactive
   extension: the human opted into making those items blocking, so they are
   treated as blocking, not quietly re-waived.

   **`CONVERGED_WITH_RESIDUE` (exit 14) is UNREACHABLE here, by construction.**
   The loop never declares residue while a promoted set is in effect (#1435):
   these blockers are the human's own picks, raised from Low because they said
   "actually, do that one", and #994 contracts them as *treated as blocking, not
   quietly re-waived* — which is exactly what residue would do, filing the
   human's explicit request back to them as a follow-up issue. So this phase ends
   only in the arms above. If you somehow see exit 14 from the sub-loop, that is
   a defect in the loop, not a verdict: report it and stop.

   **Every exit the sub-loop can produce is covered**: 0 and 10-13 by the arms
   above, 14 by the paragraph above, 20 by the §3.5 round protocol, and 1/2 by
   the taxonomy below. **Any OTHER exit** is unhandled — report it in the
   conversation and stop, rather than mapping it onto the nearest arm.

   **A round-1 `CONVERGED` with
   a non-empty matched set is not a verdict yet** — first check that round 1's
   `--findings-file` was the file built by **step 4's ordered procedure, item 3**
   (the pre-seed aggregate plus any still-present-but-unraised keys — identical
   to the pre-seed aggregate when nothing needed seeding) and that `--promote`
   was passed. The two answers lead opposite ways:

   - **Either was wrong** → this `CONVERGED` is an artifact of the slip, not a
     result. **Discard it**, fix the invocation, and re-invoke as a **fresh
     round 1** (a new `--work-dir` and `--status-file`, never `--resume`, which
     would run the seeded findings as round 2 against the phantom round's
     changelist). **Report nothing as not-reproducible** — nothing has been
     tested yet. Never re-invoke unchanged more than once.
   - **Both were correct** → the engine legitimately raised nothing, most likely
     because dedup kept a representative whose title is fully disjoint from the
     promoted keys. **Note what this proves: ZERO keys were raised**, since any
     raise would have produced a blocker and an `AWAITING_FIX`. So treat the
     **entire** matched set as not-reproducible — never just the one key you
     suspect — report every one of them in the Summary as
     promoted-but-not-reproducible, converge with **nothing** promoted, and
     continue to **§4 (Version bump)** — via the **residue branch** first when
     the blocking phase ended `CONVERGED_WITH_RESIDUE`, exactly as the other two
     terminals of this phase do. Every path out of this phase passes that branch
     or the story ships with its remainder unfiled and §6 with no numbers to
     name.

   **Neither exit 1 nor exit 2 is an escalation or a convergence here.** Both
   have several causes, so read the status file and stderr before acting —
   and **delete the status file immediately before each sub-loop invocation**,
   so "a status JSON exists afterwards" is an unambiguous signal rather than a
   guess about whether the file is this round's or the last one's.

   - **exit 2, `status: "STALE_FINDINGS"`** → the §3.5 *Each round* step-2
     refusal: recover
     by cause and re-invoke (re-passing `--promote`). Not a bad command line.
   - **exit 2, no status JSON written** → a genuine usage error in the
     invocation. **Stderr names the offending argument**: a missing, empty,
     non-file or wrong-shaped `--promote` path, a persisted promote path that
     has since vanished or been rewritten badly, a `--max-rounds` at or below
     the resumed round, or `--promote` passed together with `--no-review`. Fix the command and re-invoke.
   - **On an exit 1 or 2 whose pre-invocation delete was NOT verified**, any
     status JSON found is a **LEFTOVER** — the previous invocation's, because
     the delete above failed or was skipped. **The content test only works when the
     pre-invocation delete provably succeeded** — verify the path is absent
     (`[[ ! -e <promotion-status.json> ]]`) before invoking, and then any status
     found afterwards is provably this invocation's. If absence was **not**
     verified, the taxonomy is unreliable for *every* status, `STALE_FINDINGS`
     and `ERROR` included: a skipped delete can leave the previous
     invocation's refusal or red gate behind, and the cross-matched
     combinations (exit 2 over a leftover `ERROR`, exit 1 over a leftover
     `STALE_FINDINGS`) match no branch at all. Treat them all as leftovers.
     (Under a **verified-absent** delete the reverse holds, and it is keyed on
     the **write contract**, not on the status shape: exit 2 writes only
     `STALE_FINDINGS` or nothing, exit 1 only `ERROR` or nothing. So **any**
     freshly-written pairing those rules forbid — a neither-status, but equally
     exit 1 over a `STALE_FINDINGS` or exit 2 over an `ERROR` — is an **engine
     anomaly**, never a previous invocation's verdict, and never the
     same-status branch keyed to the other exit code. The action is the same,
     report and stop — the repoint-and-re-invoke option below applies only to a
     **LEFTOVER** (a stale path); re-invoking cannot fix an engine that just
     violated its write contract. Exit 0 and exits 20 / 10-13
     always write their own status, so they are never in question.)
     A **LEFTOVER** is never this invocation's verdict, and
     the delete discipline that makes the taxonomy readable has broken:
     **report the leftover in the conversation and stop** — or repoint
     `--status-file` at a fresh, deletable path (step 4) before any re-invoke.
     Do **not** take the "no status JSON written" branches' fix-and-re-invoke
     handling: re-invoking without clearing the stale file leaves the next
     exit's taxonomy just as unreadable, which is the hazard this rule exists
     to prevent. Reading a leftover round-1 `CONVERGED` as this exit's result
     would converge the promotion phase on a run that actually failed.
     **Exits 20 and 10-13 are not covered by this rule**: each always writes its
     own status, so that status *is* this invocation's verdict — take the round
     protocol (`AWAITING_FIX`) or the escalation branch, never this one.
   - **exit 1** → an operational failure, and **not necessarily the promote
     file**. A freshly written `status: "ERROR"` is a **red gate after the
     previous round's fix** — follow §3's rule (fix the gate, or abandon and
     report), never rewrite the promote file and never build an escalation
     comment from it. With **no** status JSON, stderr names the cause:
     `consolidate failed at round N` may be the promote file's contents *or* an
     invalid round-findings aggregate; a dispatch failure is neither. Fix what
     stderr names and re-invoke; if stderr names nothing you can act on, report
     in the conversation and stop.

8. **Keep BOTH status files — the dossier covers both phases (#1064).** The
   phase leaves a second status JSON, and §6 merges the two into the **one**
   section and **one** hidden `<!-- review-dossier: … -->` block the Approver
   parses (#563), by passing the promotion pair alongside the blocking-phase
   `--status`:

   ```bash
   "<skill-base-dir>/scripts/build-dossier.zsh" --status <blocking-status.json> \
     --promotion-status <promotion-status.json> --promoted <promoted.json>
   ```

   So keep all three paths: the blocking-phase status, the promotion-phase
   status, and the promote file. **Append its output exactly once** — never two
   hidden blocks in one body, or the Approver reads only the first — and
   **never hand-edit its output**. The rule is about *appended output*, not
   processes: a wrong-form run whose output was never appended is discarded and
   the correct invocation re-run (open-pr owns that recovery); one already
   appended means stop and report.

   The two promotion flags are an **atomic pair**: passing one without the other
   is a usage error (exit 2), never a silent fall back to a blocking-only
   dossier. Pass them exactly when **a promotion-phase status JSON that THIS run
   wrote and did not discard exists** — and not otherwise. Stated as the artifact
   rather than as "the phase ran", but note the two qualifiers, because a bare
   "a file is at that path" would be wrong twice over: the scratch dir is reused
   within a session, so an earlier story can leave one there (step 4's `rm -f`
   before every invocation is exactly what makes its later existence a signal —
   step 7's **LEFTOVER** rule), and step 7's discard branch abandons a phantom
   status that must never be passed either. Neither hazard is a terminal and
   neither prescribes a dossier form: a **LEFTOVER** means report and stop
   (step 7) — no PR, so no invocation at all — and after a **discard** it is the
   re-invoked sub-loop's own status, never the discarded file, that this
   condition tests. With that settled, the two terminals differ:

   - the *If NONE matched* terminal (step 4) **never invokes** the sub-loop, so
     there is no promotion status to pass → the plain `--status` invocation;
   - the **not-reproducible** terminal (step 7) *did* invoke it — a full round 1
     that wrote a `CONVERGED` status — so **pass the pair**. The dossier then
     records `selected: N, promoted: 0`, which is the honest shape: the human
     picked N and the engine raised none. Dropping the pair here would discard a
     real phase's rounds and the pick count, which is exactly the record #1064
     exists to preserve.

   The merged dossier drops a promoted-and-fixed item from the waived list and
   from the per-dimension suggestion counts, and carries a
   `promotion: {rounds, status, selected, promoted}` object — so the waived list
   no longer contradicts what the run did. §6 still owns the Summary's count
   contract (both counts plus step 4's unmatched / unverified split); what it no
   longer needs is the "dossier covers the blocking phase only" caveat.

   **On a non-zero exit, do not open the PR without the dossier.** The script
   prints nothing on stdout when it fails, so an unchecked invocation is
   indistinguishable from the legitimate "no loop ran" no-op — the silent-loss
   failure its own validation exists to prevent. Check the status: **2** is a
   usage error (a broken atomic pair, a flag missing its value) and **1** an
   input error (a status that is not one JSON object, a `null`-holding or
   two-object scratch file, a wrong-shaped promote file); stderr names the
   offending flag and file in both cases. Fix what it names and re-run. Treat
   **empty output at exit 0** the same way whenever the loop is known to have run
   a round — it means `--status` points at the wrong file.

   If what stderr names **cannot be restored** — a kept status or promote file
   lost or clobbered after convergence — **report in the conversation and stop**:
   no PR. Never reconstruct a status or promote file by hand to satisfy the
   command; the dossier is an audit record, and a hand-built input fabricates
   exactly the history it exists to attest.
<!-- /moved: suggestion-promotion -->
