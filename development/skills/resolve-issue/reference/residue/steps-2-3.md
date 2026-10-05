<!-- Shard of reference/residue.md (#2056), read in its index's order:
     steps 2-3 of the residue branch, the --dry-run diff and the empty plan. -->
<!-- The frozen chunk below continues the residue branch's numbered list at
     item 2, so its numbering cannot restart at 1 here. -->
<!-- markdownlint-disable MD029 -->

<!-- moved: residue-branch-steps-2-3 -->
2. **Always run `--dry-run` too, and diff the two lengths.** The real plan is
   already filtered, so on its own it cannot tell you whether the idempotency
   read dropped anything — and "how many did it drop" is what step 5 has to
   report. `--dry-run` makes **no** GitHub call and emits every candidate
   unfiltered, so the two lists differ by exactly the already-filed set:

   ```bash
   "<skill-base-dir>/scripts/build-residue-issues.zsh" --dry-run \
     --status <blocking-status.json> --changelist <blocking-work-dir>/changelist-<final round>.json \
     --issue <N> [--epic <E>] > <scratch>/residue-candidates.json

   # the candidates the read filtered out, by their RENDERED title
   jq -n --slurpfile all <scratch>/residue-candidates.json \
         --slurpfile live <scratch>/residue-plan.json \
     '($live[0] | map(.title)) as $l | $all[0] | map(select(.title as $t | ($l | index($t)) == null) | .title)' \
     > <scratch>/residue-already-filed-titles.json
   ```

   **Then recover their NUMBERS**, which the plan does not carry — the builder's
   read keeps `title` and `labels` and discards `.number`, so without this the
   step-5 rule would ask for something no artifact holds.

   `PARENT` is **the number step 1 resolved** — the epic when `--epic <E>` was
   passed, the story `<N>` otherwise. Bind it from that decision, never from the
   plan: on the legitimate re-run the plan is *empty*, so it carries no entry to
   read a parent from, and an unbound `$PARENT` makes this an
   `issues//sub_issues` request whose 404 sends you down the read-failed branch
   on a run whose numbers were perfectly readable.

   ```bash
   PARENT=<E-if-passed-else-N>
   gh api --paginate "repos/$REPO/issues/$PARENT/sub_issues" \
     --jq '.[] | select((.labels // []) | map(.name) | index("review-residue")) | {number, title}' \
     > <scratch>/residue-existing.json
   ```

   Match those on the filtered titles to get the pre-existing numbers. **Split
   the empty result from the failure by EXIT STATUS**, not by an empty file — a
   parent with no `review-residue` children reads successfully and emits nothing,
   which is a fact, while a failed read is a gap:

   - **exit 0** → the numbers you have are the numbers there are.
   - **non-zero** → do not guess and do not drop the point: say in the Summary
     that *N candidates were filtered as already filed, but their issue numbers
     could not be read*. A named gap is fine; a bare filed-count below `open` is
     the thing that reads as a failure.

3. **An empty plan is a legitimate answer in exactly ONE case**: every candidate
   is already filed **and parented** (an immediate re-run). The qualifier is
   load-bearing — an issue created but never attached is matched by the key (which
   spans the repo, not just the parent) yet is parented to nothing, so it tracks
   no blocker (step 4).
   Say so and go to step 5; create nothing. **The unfiled-remainder disclaimer
   does NOT apply here** — the follow-ups exist and are parented, so the dossier's
   "filed as follow-up issue(s)" is true. Name the pre-existing issue numbers in
   the Summary instead; writing the disclaimer would report an untracked
   remainder that is tracked.

   **An empty plan for any other reason is a wrong-input anomaly, not a zero.**
   Exit 14 fires only *with* remaining blocking findings, so a plan that is empty
   because the **changelist carries no blockers** means you passed the wrong file
   — and the builder cannot catch that one (it refuses a changelist whose
   `.round` *disagrees*; a leftover with no `.round` at all passes every guard).

   **Two of the arms below apply on EVERY run; the rest test an EMPTY plan.** The
   *read-failed* and *created-but-unparented* arms are about the FILTERED
   candidates, which exist whether or not the plan is empty — so with a NON-empty
   plan, apply those two to the filtered set and then go to step 4; skip the
   others. Running the empty-plan arms unconditionally is a live hazard rather
   than a hypothetical — on the ordinary FIRST residue
   run nothing has been filed yet, so *every* candidate is unmatched, and a model
   applying arm 3 there takes the builder-failure handling, files nothing, and
   ships a residue PR whose dossier says "filed as follow-up issue(s)" with no
   issue ever created.

   **Test it PER CANDIDATE, and against the RENDERED title.** The issue title is
   a composite the builder assembles — `review residue: <finding title> — <file>[:line]
   [<dimension>]`, sanitised and length-bounded — **never** the finding's own
   `.title`, so comparing the raw title matches nothing even on a perfectly
   healthy re-run. The `--dry-run` list from the step above is exactly that set
   of rendered titles — reuse it rather than running the builder again or
   reconstructing the titles by hand. The arms, in order — the first two apply on
   every run, and the last is a genuine last resort:

   - **(EVERY RUN) Step 2's `sub_issues` read exited non-zero** → you cannot
     classify at all. Do **not** read "unmatched" as "untracked": no candidate
     can match a read that did not happen, and the two failures are correlated
     — the builder's own parent-scoped read hits the same endpoint. Report the
     named gap step 2 specifies and treat the builder-filtered set as filed by an
     earlier run. **Then follow the plan, not the failure**: if the plan is
     NON-empty, go to step 4 and file every entry it holds — a failed
     *classification* read never suppresses *filing*, and skipping step 4 here
     would ship a residue PR whose dossier says the remainder was filed when
     nothing was created. Only with an empty plan go straight to step 5. None of
     the PER-CANDIDATE arms below apply either way — the empty-dry-run arm still
     does, since it reads no GitHub state at all.
   - **(EVERY RUN) A filtered candidate that `residue-existing.json` lacks** →
     the builder suppressed it on the **repo-wide** half of its key, so an issue
     with that exact title exists *somewhere*. Find it and read its parent before
     concluding anything — the builder documents **two** producers of this state,
     and they need opposite actions:

     ```bash
     # --arg, never interpolation: a rendered title is sanitised of newlines and
     # backticks but NOT of double quotes, and one spliced into the jq program
     # makes gh exit non-zero on a perfectly ordinary finding.
     TITLE=$(jq -r ".[$i]" <scratch>/residue-already-filed-titles.json)
     NUM=$(gh issue list --label review-residue --state all --limit 200 \
             --json number,title \
           | jq -r --arg t "$TITLE" '.[] | select(.title == $t) | .number' | head -1)
     [[ -n "$NUM" ]] && "<skill-base-dir>/scripts/read-sub-issues.zsh" --repo "$REPO" --child "$NUM"
     ```

     - **the lookup failed, or found no number** → you cannot classify this one.
       Reachable without anything being wrong: a race against the builder's own
       read, or a `gh` failure. Say so in the Summary as a named gap, count the
       candidate **untracked**, and carry on with the rest — do **not** fall into
       the read-failed arm, which is about the whole classification rather than
       one candidate.
     - **exit 0 whose parent IS this run's parent** → it is already attached;
       step 2's read simply raced it. Count it **filed** and re-attach nothing.
     - **exit 3 (no parent)** → **created-but-unparented**: an earlier run
       created it and its attach failed. **Re-attach it** with step 4's
       `sub_issues` POST, then count it filed. Not an anomaly, and no doubt about
       the `--changelist`.
     - **exit 0 with a DIFFERENT parent** → the builder's documented cross-parent
       over-suppression: somebody else's residue happens to render the same
       title. Do **not** re-attach — it is not yours. Count the candidate
       **untracked** for the remainder rule and name the colliding issue number
       in the Summary, so a human can see why this blocker has no follow-up.
     - **any other non-zero** → unclassifiable for THIS candidate: say so as a
       named gap, count it untracked, and carry on with the rest. Never the
       read-failed arm — that one is about the whole classification.
   - **The dry-run list is itself EMPTY** → the anomaly, always. Exit 14 fires
     only *with* remaining blocking findings, so zero candidates proves the
     `--changelist` is the wrong file. **First re-derive its path** from the
     status JSON's own `.rounds` and re-run step 1 — that is usually the whole
     fix. Only if the correct changelist still yields nothing, take the
     builder-failure handling. Do **not** let this fall into the arm below: with
     no candidates, "every candidate matched" is vacuously true, and the run
     would report 0 follow-ups on a story that had real residual blockers.
   - **At least one candidate, and EVERY one matched** a `review-residue`
     sub-issue of the parent with that exact title → the legitimate re-run case.
   - **Any candidate unmatched for none of the reasons above, the plan still empty** → the anomaly: take the **builder-failure
     handling** above. Name the remaining blockers **from the status JSON's
     `final_changelist.blocking`** — the set that handling specifies, and the
     same set the dossier's `open` counts derive from, so the two **counts**
     agree. For what the Summary owes beyond the counts, apply **the remainder
     rule** — this arm is a route, not a row. It fires with the plan EMPTY and at
     least one candidate unmatched. (A run where four of five matched leaves a
     plan of one, which is not this arm at all — that is step 4.) Here
     the candidate set is the only rendering you have, so it is what decides the
     row: matched candidates count as tracked, unmatched as untracked. The
     unmatched *candidate titles* go in as
     **evidence of the anomaly**, never as the remainder: they come from the file
     this mismatch puts in doubt (arm 1 is where a changelist is *established*
     wrong; here it is only suspect). A question like "is
   anything filed under the parent?" is the wrong test: on an epic parent an
   earlier child's run routinely leaves `review-residue` children, so it answers
   yes while none of *this* run's candidates is filed — and reporting "0 follow-up
   issues filed" there is the silent loss this whole branch exists to prevent.
<!-- /moved: residue-branch-steps-2-3 -->
