<!-- Shard of reference/promotion.md (#2057), read in its index's order:
     step 3 of the promotion phase, the multi-select and its telemetry record. -->
<!-- The frozen chunk below continues the phase's numbered list at item 3, so
     its numbering cannot restart at 1 here. -->
<!-- markdownlint-disable MD029 -->

<!-- moved: suggestion-promotion-step-3 -->
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
<!-- /moved: suggestion-promotion-step-3 -->
