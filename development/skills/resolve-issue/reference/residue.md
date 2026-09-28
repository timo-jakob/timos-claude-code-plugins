# Residue — file the remainder, then ship

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

It carries the branch taken on a `CONVERGED_WITH_RESIDUE` (exit 14)
ending.

Every `<!-- moved: … -->` block below is byte-identical to the text it was
carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit, and is what keeps this file honest.

**Before step 1, read § *Risk threshold — assess before filing (#1920)* at the
end of this file FIRST.** It tells you how to read the
`corner_case_risk_threshold` environment variable. Set to a usable value, that
section adds an assessment before step 1 and amends steps 1, 2, 3 and 5 of the
frozen branch below, which cannot carry the change itself. Set to a value it
cannot use, it adds only one line to the PR Summary. Unset, empty or zero, the
branch runs exactly as written.

## Residue branch — file the remainder, then ship (#1435)

<!-- moved: residue-branch -->
Runs **only** on `CONVERGED_WITH_RESIDUE` (exit 14). The loop has already
decided; your job is to make the remainder visible.

**Order it LAST — after the suggestion-promotion phase below has resolved, and
immediately before §4.** This branch is the one place in the flow that writes to
GitHub before the PR exists, and a promotion sub-loop can still **escalate**,
which ends the run with no PR at all. Filing first would leave issues on the
board for work that never shipped, and the next run would re-decide the whole
blocking phase around them. Nothing is lost by waiting: the promotion phase is a
separate sub-loop over waived Lows and never changes the blocking phase's
residual set, which is what the plan below reads.

**Ordering last shrinks that window; it does not close it.** Everything after
this branch can still end the run with no PR — §5's commit (pre-commit can
fail), §6's token mint or push, and open-pr's explicitly terminal *stop rather
than open the PR* when a dossier input cannot be restored. By then the
follow-up issues are already on GitHub. If the run ends after this branch
without a PR:

- **Do NOT delete them.** They record real remaining blockers, and the epic walk
  has to see them rather than have them vanish.
- **Comment on each filed issue and on the story** that the PR was never opened,
  naming the branch and what stopped it, so the next reader is not looking for a
  merged change that does not exist.
- **Report it in the conversation** with the same detail.

A re-run does not duplicate what this run filed — the idempotency read matches
on label + exact title across the parent's sub-issues **and** the repo, so even
an issue whose **attach** failed is filtered from the next plan. But that is
exactly why a re-run is not a recovery for it: it stays **orphaned**, linked to
no story, and the next run will not re-file it either. Re-attach it yourself
(step 4's `sub_issues` POST, with the id it already has) and name it in the
comments below. What is *not* safe is
silence — a `review-residue` child parented to an epic will halt that epic's next
walk, and a maintainer with no comment to read cannot tell a deliberate deferral
from an abandoned run.

**If the promotion sub-loop DOES escalate, this branch never runs and no PR
opens.** File nothing — but do not let the remainder vanish with the run: name
the blocking phase's residual blockers (from its `final_changelist.blocking`) in
the escalation comment, so they survive somewhere. The next run re-decides the
blocking phase from scratch and will re-derive them.

1. **Build the plan.** Deterministic, and it creates nothing:

   ```bash
   "<skill-base-dir>/scripts/build-residue-issues.zsh" \
     --status <blocking-status.json> \
     --changelist <blocking-work-dir>/changelist-<final round>.json \
     --issue <N> [--epic <E>] > <scratch>/residue-plan.json
   ```

   **Both inputs are the BLOCKING phase's**, and by the time you run this you are
   holding two of each — the promotion phase left its own status and work-dir
   (step 8 tells you to keep them). The promotion sub-loop can never end in
   residue (step 7 says why), so its artifacts are never the right ones here;
   passing them would file the human's promoted picks back to them as follow-ups.
   The builder cannot catch that: a promotion status and its own changelist are
   self-consistent, so both its guards pass.

   `<scratch>` is the same outside-the-repo dir the work-dir and findings files
   live in (§3.5) — a file written inside the worktree changes the tree identity,
   defeats every `--gate-attest` match, and is one more thing §5 could commit.
   The final round's changelist is `<work-dir>/changelist-<rounds>.json`, where
   `rounds` is the status JSON's own `.rounds`. Get that right: the builder
   refuses a changelist whose `.round` disagrees with the status (exit 2, naming
   both numbers), because an off-by-one would otherwise file issues for an
   earlier round's blockers — findings the fix pass already cleared, with titles
   new enough that the idempotency read filters none of them.

   **`--epic <E>` comes from the NATIVE parent, never from the body.** Parenthood
   is native or it does not exist (#802) — this skill says so about epics and
   must not make an exception here. An epic-driven run already holds the epic
   number; otherwise read the native relationship with the **blessed reader**,
   not an ad-hoc `gh` call — it is the same primitive E1 and §0a use, and it
   returns the one field an ad-hoc read omits:

   ```bash
   "<skill-base-dir>/scripts/read-sub-issues.zsh" --repo "$REPO" --child <N>
   #   { "child": N, "parent": { "number": P, "state": …, "open": …,
   #                             "repo": "owner/name" } }
   #   exit 3 = typed no-parent (JSON still emitted)
   ```

   **Never** infer it from prose: a story that IS natively a child but whose body
   does not mention the epic would get `--epic` dropped, and the residue would be
   parented to a story this same PR is about to close.

   **Branch on the exit, and then on the parent's repo** — **four** arms: exit 3,
   exit 0 in this repo, exit 0 in another repo, and any other non-zero. The last
   is the one a two-way split loses, and losing it is not cosmetic: a transport
   failure would read as "no native parent" and the residue would be parented to
   the story this PR is about to close.
   - **exit 3** → there genuinely is no native parent. Omit `--epic`, parent to
     the story, and say so in the PR body.
   - **exit 0, and `.parent.repo` equals `$REPO`** → that number is the epic.
     Pass it as `--epic`.
   - **exit 0, but `.parent.repo` is a DIFFERENT repository** → the parent is
     real and is **not usable as `--epic`**. Both the builder's idempotency read
     (`repos/{owner}/{repo}/issues/<E>/sub_issues`) and step 4's attach POST are
     bound to the session repo, so a foreign number either attaches the residue
     to whichever unrelated **local** issue happens to share it, or 404s into the
     fail-open path. The issues then stay **unparented** — the idempotency key is
     repo-wide, so a re-run will not duplicate them, but nothing will ever link
     them to the story either. Omit `--epic`, parent to the story, and say in the PR body that the
     native parent is cross-repo and was not used. This is §0a's foreign-blocker
     rule — *never re-run on the bare number against this repo* — applied to
     parenthood; a bare issue number means nothing outside its own repo.
   - **any other non-zero exit** → nothing was read, and that is *not* "no
     parent" (exit 3 is the only reading that means that). Re-run it. If it fails
     again, do **not** guess: file nothing and take the builder-failure handling
     below (name the remaining blockers in the PR body), rather than parenting
     residue to a story this PR is about to close. **Exit 2 is your own
     malformed invocation** — fix the command and re-run, the same rule E1 and
     §0a apply to their scripts.

   **Exit 2 is your own malformed invocation** — a bad flag, a `--status` that is
   not a `CONVERGED_WITH_RESIDUE` run (an escalation opens no PR, so its blockers
   must not be filed), or a `--changelist` from the wrong round. Fix the command
   and re-run. **Exit 1** is an input failure (an unreadable or non-object status
   / changelist, no `jq`); stderr names the file. Fix what it names and re-run —
   and if you cannot, **which file it named decides what happens next**:

   - it named the **`--changelist`**, or `jq` is missing → report it in the
     conversation and **still open the PR**. The code is reviewed and green, and
     a builder failure is not a reason to withhold it. Say plainly in the PR body
     that the residue could not be filed, and name the remaining blockers from
     the status JSON's `final_changelist.blocking` so they are not lost.
   - it named the **`--status`** → **stop, with no PR.** That same kept
     blocking-phase status JSON is `build-dossier.zsh`'s input, so §6 and
     open-pr already govern it: a kept status lost or clobbered after
     convergence is reported and the run stops. Opening anyway would ship a
     residue PR with no dossier, no `open` counts and no follow-up issues — one
     that reads as an ordinary converged PR and auto-merges on approval, which
     is the single outcome this whole path exists to prevent. Nor could you
     honour the fallback above: the blocker list it prescribes comes from the
     very file you could not read.

   **When the PR opens with the remainder UNFILED — no follow-up issue exists for
   it, from this run or an earlier one — the Summary must contradict the dossier
   in so many words.** The antecedent is the *remainder's* state, not this run's
   activity: step 3's legitimate re-run case also creates nothing, and there the
   issues **do** exist and are parented, so the dossier's "filed" claim is TRUE
   and this disclaimer must **not** be written — doing so would report an
   untracked remainder that is in fact tracked, and send a human hunting for a
   failure that did not happen. This is not optional
   belt-and-braces: `build-dossier.zsh` gates its residue wording on the
   **status alone**, so §6 appends "each was filed as a labelled follow-up issue"
   and a per-dimension "N still open (filed as follow-up issue(s))" to this very
   PR — that is deliberate (residue is single-phase, so the terminal *is* the
   predicate), and the script has no way to learn that the filing step failed.
   Left alone, the body asserts tracking that does not exist, and the hidden
   block's `open > 0` — which `approver-policy-core` is contracted to read as
   scoped, disclosed, **tracked** risk — makes the Approver's leniency rest on
   issues nobody opened. So write, above the dossier:

   > **The dossier below reports these blockers as filed as follow-up issues.
   > They were NOT filed on this run** (`<why>`). The open blockers are:
   > `<list>`.

   Never paraphrase it into something a reader could take as a formatting note:
   the sentence exists to override a machine-generated claim.

   <!-- the-remainder-rule -->
   **THE REMAINDER RULE — one rule, stated once, and every arm below points
   here.** "Filed" means **created AND parented**. An issue that exists but was
   never attached links to nothing: the epic walk never meets it, and no `open`
   count it is supposed to cover is really covered. (The builder's idempotency
   key — label + exact title, resolved across the parent's sub-issues **and**
   repo-wide — *does* match it, so a re-run will not duplicate it; the failure
   mode is a permanently orphaned issue, not a pile of copies. Either way it is
   not *filed*.) Counting a bare `create` as filed is what makes the arms look
   complete when they are not.

   Now count the remainder — the blockers in `final_changelist.blocking` — by how
   many are filed **in that sense**, from this run *or* an earlier one:

   | Filed | The Summary owes | Why |
   |---|---|---|
   | **none** | the verbatim sentence above | nothing tracks any of it |
   | **some, not all** | the reconciliation: name the tracked numbers (this run's **and** the pre-existing ones step 2 recovered), name the blockers nothing tracks — flagging any created-but-unparented separately — and state both counts against `open` | the dossier's `open` exceeds what is tracked, and neither end describes it |
   | **all** | every tracked issue number — this run's **and** the pre-existing ones step 2 recovered — plus one line stating that together they account for `open`; no disclaimer | the dossier's claim is true; the disclaimer would report tracked work as lost, and a bare this-run count below `open` reads as a partial filing |

   **The antecedent is the remainder, never the arm you arrived by.** Every arm
   below — the exit-1 handling above, the repeated-reader-failure arm, both
   step-3 anomaly arms, and a step-4 run that filed zero entries — is a *route*
   to one of those three rows, not a row itself. Each is reachable with part of
   the remainder already tracked (a re-run whose plan the idempotency read
   filtered to 3 of 5 whose remaining 3 then fail; a step-3 anomaly where some
   candidates matched an existing sub-issue), and reading the arm instead of the
   remainder is how a Summary comes to report issues that exist as never filed.

   Two shapes worth naming because they read as the wrong row. **Every `create`
   succeeded and no `attach` did** (one missing `sub_issues` permission fails
   every POST identically) looks partial — the issues exist! — and is row one
   **when the plan covered the whole remainder**, because an unparented issue
   tracks nothing. Name the created-but-unparented numbers inside the verbatim
   sentence so the next reader can attach them by hand.

   If the **builder's** idempotency read (step 1) filtered part of the plan — a
   fact step 2's `--dry-run` diff *reveals* rather than causes — then count those
   filtered candidates by **parenthood, not by having been filtered**. The
   builder matches `review-residue` issues repo-wide as well as the parent's
   sub-issues, precisely so a created-but-unattached issue is not re-filed; so a
   filtered candidate counts as **tracked** only when `residue-existing.json`
   (the parent's sub-issues, step 2) contains its rendered title. One that is
   filtered but absent from that read is **not tracked by this read** — classify
   it with **step 3's arm 2**, which owns that state and resolves it four ways,
   one of which must NOT be re-attached. Do not decide it here.

   **That test presupposes step 2's `sub_issues` read exited 0.** On a non-zero
   exit `residue-existing.json` is empty for *every* candidate, and absence there
   is evidence of nothing — least of all of unparenthood. The two failures are
   correlated, not independent: the builder's own parent-scoped read hits the
   same endpoint, so when it fails the builder still filters the plan off its
   repo-wide half, and you are left with an empty plan AND an empty
   `residue-existing.json`. Read literally, the test then calls the whole
   remainder untracked and writes the verbatim disclaimer over a remainder an
   earlier run filed perfectly well. So: on a failed read take **step 3's
   read-failed arm** — count the builder-filtered set as filed by an earlier run,
   report step 2's named-numbers gap, and choose the row from what is left.
   **Never write the verbatim sentence off a read that did not happen.** And **the
   remainder's state cannot be determined at all** — no candidate list to match
   against `residue-existing.json`, which is the case on step 3's empty-dry-run
   arm and on a builder or repeated-reader failure — is *also* row one: take the
   verbatim sentence and add one line saying pre-existing coverage could not be
   checked. Fail-closed, because the alternative is leaving the dossier's "filed"
   claim standing over a remainder nothing may be tracking.

   The script is **fail-open on its GitHub reads**, and there are two of them, so
   relay what stderr actually says: losing the **repo-wide** read narrows the key
   back to the parent alone (announced — a residue issue an earlier run created
   but failed to attach may then be re-filed); losing **both** emits an
   unfiltered plan (announced — a re-run may duplicate anything); losing only the
   **parent** read leaves the plan filtered on the repo-wide half. Whichever it
   is, pass it on rather than paraphrasing it as "the read failed".

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

4. **Create each issue, then attach it as a native sub-issue.** One `gh issue
   create` per entry, with **both** labels, then the `sub_issues` POST
   `backfill-sub-issues.zsh` already makes. Ensure the labels exist first, with
   the repo's idempotent idiom:

   ```bash
   gh label create review-residue --color fbca04 \
     --description "Filed by the review loop residue path — a remaining non-critical blocker" \
     2>/dev/null || true
   gh label create needs-refinement --color d4c5f9 \
     --description "Sent back by the readiness gate — needs clarification before implementation" \
     2>/dev/null || true

   # per entry, indexed — the BODY goes via a file, never a --body argument: a
   # finding body routinely contains backticks and $(...) that a double-quoted
   # --body would hand to the shell to execute
   TITLE=$(jq -r ".[$i].title" <scratch>/residue-plan.json)
   PARENT=$(jq -r ".[$i].parent" <scratch>/residue-plan.json)
   jq -r ".[$i].body" <scratch>/residue-plan.json > <scratch>/residue-body-$i.md
   URL=$(gh issue create --title "$TITLE" --body-file <scratch>/residue-body-$i.md \
           --label review-residue --label needs-refinement)
   NUM="${URL##*/}"
   CHILD_ID=$(gh api "repos/$REPO/issues/$NUM" --jq .id)
   gh api -X POST "repos/$REPO/issues/$PARENT/sub_issues" -F sub_issue_id="$CHILD_ID"
   ```

   Take the labels from the entry rather than hardcoding them if you prefer —
   but they must be **both**, on every issue, and `--label` is what the plan's
   `labels` array is for. `parent` is per-entry too, so read it from the entry
   rather than re-deriving the epic.

   A failed **attach** is not a failed run: the issue exists and carries both
   labels, so report which ones could not be parented and carry on. A failed
   **create** is the same — report it, name the finding, and continue with the
   rest. **Both feed the remainder rule in step 1** — count how much of the
   remainder ends up filed (created AND parented) and take the row that matches.
   Do not shortcut it from here: "every create failed" is a route, not a row, and
   on a re-run whose plan the idempotency read had already filtered it lands on
   the partly-tracked row, not the verbatim sentence. The dossier will say those
   blockers were filed either way, which is why the row has to be counted rather
   than inferred from what went wrong.

   **An unparented issue IS matched by the idempotency key** — label + exact
   title, resolved across the parent's sub-issues **and** repo-wide — so a re-run
   will not duplicate it. It will silently **skip** it, which is worse for this
   purpose: the issue stays permanently orphaned, linked to no story, and no
   later run will ever re-file it. That is why the re-run is not the recovery.
   Record its number in the PR body and **re-attach that one issue** (the
   `sub_issues` POST above, with the id it already has); only then is it filed in
   the sense step 3 means.

5. **Say it in the PR body.** §6's Summary names the residue ending, how many
   follow-up issues were filed (and their numbers), and their parent. A residue
   PR that reads like an ordinary converged one is the one outcome this whole
   path must not produce.

   **When the idempotency read filtered part of the plan, name BOTH sets.** A
   plan of 3 against a dossier reporting `open: 5` is the *normal* shape of a
   re-run, not a failure: the read legitimately drops candidates an **earlier**
   run already filed, and all five are tracked. But "3 follow-up issues filed"
   beside `open: 5` is exactly what a partial-filing failure looks like, and
   §6's count rule and the Approver's `open > 0` rule both read it that way — so
   an honest run gets treated as an untracked one. Write the numbers filed on
   **this** run *and* the pre-existing `review-residue` numbers the read matched,
   and state that together they account for the dossier's `open` count. (**Step 2
   is where both sets of numbers come from** — its `--dry-run` diff names what the
   idempotency read filtered, and its `sub_issues` read turns those titles into
   numbers. Step 3 handles only the *wholly*-empty plan; this mixed shape is the
   one it does not reach.)

**Known consequence — and it differs by linkage shape.** Step 0 treats native
sub-issues as authoritative, so a parent that acquires them walks as an **epic**
on its next `/development:resolve-issue` run, and E1b halts that walk on any
child the readiness gate sends back — which an auto-generated finding always is.
That halt is the *intended* prompt: residue must be refined before it is built,
and the `needs-refinement` label is what makes it legible, so the human meets a
child already carrying the reason it stopped the walk.

**But the halt is only reachable on the EPIC shape**, and #1435's claim that it
"applies to both linkage shapes" does not survive contact with this same flow:

- **Epic-parented and the epic is OPEN** — it acquires open `needs-refinement`
  children and halts at E1b next time. Its own E5 then **cannot** close it, which
  is correct rather than a defect: the positive-evidence rule wants closed
  children, and these are open. See the epic-flow note at E5.
- **Epic-parented but the epic is already CLOSED** — a human may have closed it
  early, or the story may have been attached to an already-closed epic. Step 0
  then stops on a non-`OPEN` issue and no pre-flight ever runs, so this behaves
  like the story shape below: the labels and the PR body are the whole surfacing
  mechanism. **Read the parent's state, do not assume it** (`gh issue view <E>
  --json state`) — the arm you pick decides what you tell the human, and
  promising a pre-flight that will never run is worse than promising nothing.
- **Story-parented** (no epic) — the halt **stops firing once the PR merges**,
  because this run's own PR carries `Closes #<story>`, so the story closes and
  Step 0 stops on a non-`OPEN` issue before E1b is ever reached. There the
  residue is surfaced by its **labels** and by the **PR body**, which is why §6
  requires the Summary to name the issue numbers — so tell the human *that*, not
  that a pre-flight will meet them.

  **Until then it is still open, and this branch runs BEFORE §5/§6.** In the
  window between filing and merge — and permanently if the PR is never opened or
  never merged, which in a human-approval repo is a real state — the story is
  `OPEN` and now carries native sub-issues, so a `/development:resolve-issue` on
  it walks it as an **epic** and halts at E1b on this run's own residue findings.
  **That halt is the residue prompt, not a classification defect**: refine the
  residue children (or close them), then re-run. Do not "fix" it by detaching
  them, and do not read the story's own work as unstartable.
<!-- /moved: residue-branch -->

## Condition 2 — removed; the story-diff rail is upstream (#1571)

The residue terminal once took **three** conditions. It now takes **two** —
condition 1 (the last two rounds are both zero-CRITICAL) and condition 3 (the
declaring round ran as a full sweep). Condition 2 —

> every remaining blocking finding's `.file` is in the **previous** round's
> fix-touched set

— was **removed**. Nothing replaced it, and the numbering keeps its gap on
purpose: every other surface names the survivors as 1 and 3, so renumbering 3
to 2 would silently repoint them at the condition that was deleted.

**The guarantee it stood for still holds — one step earlier.** Its purpose was
that residue lives in what *this story* wrote, never in shipped behaviour nobody
has just rewritten. That is enforced by `review-dispatch.zsh scope-findings`,
which filters **every** round's findings to the story diff (`_changed_files`:
`git diff --name-only <base>` plus `ls-files --others --exclude-standard`)
before consolidation. The filtered array `$scoped` is the **only** input to the
changelist's `.blocking` — the fix-verification carry goes to `plan`, never to
the consolidator. So every blocker that can reach `_residue_holds()` is in the
story diff **by construction**, and a blocker in a file this run never opened is
dropped long before it could become residue.

Re-testing that inside the predicate would be a test that can never fail, which
is worse than no test: it reads as a rail while guaranteeing nothing.

**Why the round-granular reading had to go.** A zero-blocking delta round
promotes the closing sweep and runs **no fix pass**, so the loop deliberately
writes it an empty fix-touched set (that empty write is load-bearing, and for a
narrower reason than it looks: an **empty** set is a real answer, so every
blocker the sweep raises is stamped `new_defect`, whereas an **absent** file
makes the loop omit `--fix-touched` and stamp nothing at all. Writing it is what
keeps hook mode and step mode agreeing on which of those two the sweep is).
Against an empty set every blocker counts as "outside" — so condition 2 was
false *by construction on precisely the path that earns the sweep*, and the
terminal built for the closing sweep was unreachable from the closing sweep.
That is why `CONVERGED_WITH_RESIDUE` never fired in the #1558 session even
though its sweeps were zero-CRITICAL twice.

**What is deliberately NOT changed.** The fix-touched capture stays exactly as
it was. It still feeds `consolidate-findings.zsh --fix-touched`, which stamps
each blocker's `class` (`new_defect` / `incomplete_propagation`) for the progress
histogram and the grant decision, and it still keys the waived-suggestion
exemption in `review-loop.md`. Those are different consumers; deleting the
capture because the residue predicate stopped reading it would blank every
blocker's `class`. `scope-findings` is not changed either — this rule *relies*
on it, and pins it with a test rather than touching it.

## Risk threshold — assess before filing (#1920)

**First read the variable — it is invisible until you do.** It lives in the
environment your shell commands inherit (a maintainer sets it in their
settings' `env`), so nothing in the conversation shows it. Read it with a
command that expands nothing, so no worktree guard refuses it:

```bash
printenv corner_case_risk_threshold   # exit 1 → unset
```

Then take exactly one of three states — the builder parses the value the same
way:

- **Off — unset, empty, or any spelling of zero (`0`, `0.0`, `.000`).** Skip
  the rest of this section: make no assessment, pass no new flag, and the branch
  above runs exactly as written.
- **Ignored — set to anything else that is not a decimal in [0, 1] with at most
  three decimals** (`30`, `1.5`, `-0.1`, `0.0005`, `abc`). Behave exactly as off
  — no assessment, no new flag — but say so in the PR Summary in one line naming
  the value, so the maintainer learns the setting did nothing. The builder says
  so on stderr too; that is a run log, not the PR.
- **On — any other value** (`0.05`, `.05`, `1`). Everything below applies.

If the builder ever prints `corner_case_risk_threshold is set but no --risk
assessment was given`, you misread the state: go back to step 1 below, assess,
and re-run the builder. Never proceed on that plan — it files every blocker the
maintainer's floor was set to drop.

Why it exists: every residual blocker used to be filed, however unlikely or
harmless, and each filed issue runs its own review loop that can file more —
epic #1795 grew from 3 children to 21 that way. The threshold lets the
maintainer set a floor on **risk**, and everything below it is reported, not
filed.

### 1. Assess every residual blocker — before step 1

**Assess only what the loop has not already assessed (#1921).** With the
threshold on, the loop's risk pass (`review-loop.md` § *The risk pass*) assessed
every blocking finding afresh each round, and the consolidator stamped each
one's changelist entry with `risk_assessment` — so the final changelist carries
the final round's judgement. A residual blocker that carries that stamp is **not
assessed again**: the builder reuses the stamp's `p` and `impact` against the
current threshold (its dropped record says `assessed_in: "loop"`), and a
`--risk` entry naming a stamped finding is exit 2 (*already assessed in the
loop*). A stamp below its own recorded threshold marks a blocker the loop kept
on purpose — a `CRITICAL`, a tool red, a human pick, a partly assessed group —
and the builder keeps it too. So the set to assess here is the residual
blockers **without** a stamp — typically none in step mode — and when there are
none you still pass `--risk`, holding `[]`, so the builder applies the stamps
and writes the dropped record.

For each **unstamped** finding in the BLOCKING phase's final changelist
`.blocking` (the same file step 1 passes as `--changelist`), record two values,
each with a one-line rationale:

**Probability `p`** — a decimal in [0, 1] with at most two decimals. Which
definition applies follows the finding's `dimension`:

- **`tests`** (a test-strength finding — "mutation X still passes", "branch Y
  is never tested"): the probability that a plausible future change breaks
  exactly that unpinned behaviour without another test catching it.
- **every other dimension** (a defect finding): the probability that the
  described input or state actually arises in this repository's real use.

**Impact** — exactly one of four anchors, the **highest** the consequence
reaches:

| `impact` | consequence if it happens |
|---|---|
| `1.0` | a false result that is trusted — a green gate, a passing check or a merged PR that should have failed; data loss; a security exposure |
| `0.7` | a hang, runaway resource use (CPU, processes, API quota), or a shipped pipeline or skill that does the wrong thing |
| `0.4` | degraded or misleading output, or a run that needs a manual retry or a human to notice and correct it |
| `0.1` | cosmetic, or a test-only nicety with no behavioural consequence |

For a test-strength finding, impact is the impact of the **defect the unpinned
behaviour would let through**, never of the test gap itself.

**Risk** is `p × impact`. A finding is **kept** (filed) when `risk >=
threshold`, **dropped** when `risk < threshold`. The builder computes this in
integer thousandths (`p` in hundredths × `impact` in tenths), so a risk exactly
at the threshold is kept and no floating-point rounding moves a finding across
it. You judge; the builder does the arithmetic — never pre-filter the
changelist yourself.

Write the assessment to `<scratch>/residue-risk.json` — outside the worktree,
for the reason step 1 gives — as one JSON array, one entry per finding, keyed by
the loop-wide finding identity (`file`, `line`, `dimension`, `title`, copied
**verbatim** from the changelist entry, `line` included when it is `null`):

```json
[ { "file": "tests/x.bats", "line": 42, "dimension": "tests",
    "title": "<the changelist entry's title, verbatim>",
    "p": 0.05, "p_why": "…", "impact": 0.4, "impact_why": "…" } ]
```

A finding you leave out is **kept** — a missing assessment never drops anything
— and an entry whose identity matches no finding assesses nothing (the builder
names it on stderr; fix the identity and re-run if you meant to assess that
finding).

### 2. Amendments to the frozen branch

- **Step 1 and step 2** — add `--risk <scratch>/residue-risk.json
  --dropped-file <scratch>/residue-dropped.json` to **both** invocations, the
  real plan and the `--dry-run`. The builder drops the same set in both, before
  either is built, so step 2's length diff still measures only the idempotency
  filter. An **exit 2** naming `--risk` is your own malformed assessment (a `p`
  with three decimals, an impact off the four anchors, a blank rationale, a
  duplicate identity, an entry for a finding the loop already stamped) — the
  message names the entry; fix it and re-run. It is
  never "file everything" or "file nothing".
- **Step 1's exit-1 handling** — the builder has exit-1 causes that name
  neither `--status` nor `--changelist`: `could not write --dropped-file`,
  `could not create a temp file`, `could not write the filtered changelist`,
  `could not build the dropped record`. None of them is the `--status` arm, so
  none of them stops the run with no PR. They are output-side: fix what they
  name (the scratch path, `TMPDIR`) and re-run. If one persists, fall back to
  filing everything: re-run both invocations **without** `--risk` and
  `--dropped-file` and with the variable **blanked for those two calls only**
  (`corner_case_risk_threshold= <builder> …`), so the builder parses it as off
  — then nothing is dropped, every blocker is filed, and the section 1
  guardrail message never fires. Say in the Summary, in one line, that the
  threshold could not be applied and why, and treat the rest of this section as
  off, as the ignored state does — do not read `residue-dropped.json`, which is
  absent or left over. (The one risk-path exit 1 that names
  the changelist, `could not apply the risk threshold to <changelist>`, is the
  frozen `--changelist` arm: that file is what is wrong.)
- **After step 2's `sub_issues` read, settle what the dropped record really
  dropped — before step 3 and before the remainder rule.** Read
  `<scratch>/residue-dropped.json`:
  - **`threshold_state` is `ignored`** → whatever you read in section 1, the
    builder parsed the value as unusable and dropped nothing. Write the ignored
    value's one-line Summary note, and treat the rest of this section as off.
  - **A dropped finding an EARLIER run already filed is not dropped.** The
    threshold can be switched on, and an assessment can move, between two runs
    of one story — and a re-run is exactly what this branch expects after a PR
    that never opened. So look up every dropped record's `issue_title` (the
    title an issue for it would carry) among the `review-residue` issues, and
    classify each exactly as step 3 classifies a builder-filtered candidate,
    because that is what it is. Run the repo-wide listing **once, on its own**
    (`gh issue list --label review-residue --state all --limit 200 --json
    number,title > <scratch>/residue-listing.json`) and note its exit status
    before matching anything — the arm-2 snippet pipes it into `head`, which
    hides a failed listing behind an empty match. Then take the arms **in
    order; the first arm that settles a record settles it**:
    - a sub-issue of **this run's parent** (step 2's `sub_issues` read) →
      **filed**, from an earlier run: it rejoins the remainder as a
      pre-existing follow-up, and step 5 names its number;
    - present in the repo-wide listing but not settled by arm 1 (absent from
      step 2's read, or that read failed) — matched against
      `<scratch>/residue-listing.json`, never by running the listing again → it
      rejoins the remainder and takes **step 3's arm 2**: take its number from
      that file, run only that arm's `read-sub-issues.zsh --child` read for its
      parent, and settle it by **all** of that arm's own sub-arms, exactly as
      written there — including its *any other non-zero* sub-arm, which counts
      the record untracked. A `--child` read that fails never sends a
      listing-matched record to the arm below;
    - **a lookup that did not happen** — a read this record needed exited
      non-zero: **only** step 2's `sub_issues` read, or (for a record absent
      from it) the repo-wide listing; the `--child` read belongs to the arm
      above and is settled there — → it **stays dropped**, and the Summary says in one
      line that its earlier-run status could not be checked. A record an earlier
      arm settled is never moved here by a failure that did not concern it.
      Step 3's read-failed arm (*count the builder-filtered set as filed*) does
      **not** apply here: a dropped record was never filtered by the builder's
      idempotency read, so there is no filtered set to credit;
    - found nowhere, both reads having succeeded → it **stays dropped**.
- **Everywhere the branch says *the remainder*** — `final_changelist.blocking`,
  the candidates, the blockers the remainder rule counts, the set step 3's arms
  match — read it as that set **minus the records that stay dropped** after the
  settling above. That is the only definition: a record that rejoined is in the
  remainder and counted like any other; a record that stays dropped is neither
  filed nor untracked — its own row, decided on purpose.
- **Step 3** — an empty plan **and an empty `--dry-run`** are legitimate
  **because every candidate was dropped** only when both hold: the dropped
  record's `dropped` array is **non-empty** — the builder dropped at least one
  finding, whatever the settling then did with it — and every entry of the
  status JSON's
  `final_changelist.blocking` is among the dropped records — whether it stays
  dropped or rejoined, as filed or as untracked (matched by `file`, `line`,
  `dimension` and `title`). A record that rejoined is still absent from both
  lists, because the builder drops it before either is built; only a blocker
  that **no** dropped record covers makes an empty dry-run suspect. This overrides
  the frozen *dry-run list is itself EMPTY* arm, whose "anomaly, always" was
  written before anything could drop a candidate. When every dropped record
  rejoined, the remainder is the whole set and the remainder rule decides its
  row — an all-filed rejoin is the **all** row, naming the pre-existing numbers,
  with no dropped table. With an **empty** `dropped` array, an empty dry-run is
  still that anomaly arm — the changelist you passed is the suspect — because
  "every candidate was dropped" is vacuously true of no candidates.
- **An EMPTY remainder takes no remainder-rule row.** When every blocker stays
  dropped, the rule's rows all read vacuously true, and its fail-closed clause
  would pick the verbatim *They were NOT filed on this run* disclaimer —
  presenting a deliberate drop as a filing failure. Do **not** write that
  disclaimer. The Summary carries step 5's paragraph and one line: `0 filed,
  <dropped> dropped, 0 untracked of <open> open`.
- **Step 5 (the PR body)** — the dossier's residue wording is gated on the
  status alone, so it still says every open blocker was filed as a follow-up.
  When at least one record stays dropped, write this above the dossier,
  verbatim apart from the placeholder, then the table:

  > **Dropped by the risk threshold (`corner_case_risk_threshold` =
  > `<value>`):** the dossier below counts these blockers as open and filed.
  > **They were NOT filed** — each one's risk (probability × impact) is below
  > the threshold. Re-file any of them by hand if you disagree with its
  > assessment.

  | finding | p | impact | risk | why |
  |---|---|---|---|---|

  followed by **each staying-dropped record's `row`, pasted as it is** — never
  re-rendered from its raw fields. The builder renders that row with the
  finding's untrusted text neutralised (newlines and backticks out, pipes
  escaped), which a hand-built row from `title` or `p_why` would not be. Then,
  unless the remainder is empty (above), apply the remainder rule to what is
  left. When the Summary counts the follow-ups against the dossier's `open`,
  state the three numbers — filed, dropped, and (if any) untracked — so they
  sum to `open`.

What this section does **not** change: which runs reach the residue terminal,
and the dossier's residue counts. What the loop fixes before it gets there is
now shaped by the same threshold — a `WARNING` below it is demoted to a
suggestion in the round that raises it (#1921, `review-loop.md` § *The risk
pass*), so it never reaches this section as residue at all; the blockers the
loop never demotes reach it with their stamp, and section 1 says what happens
to them. The dossier's
hidden block still counts a finding dropped **here** in its `open`, which
`approver-policy-core` reads as tracked risk; step 5's paragraph is the only
place that says otherwise, so a reader of the hidden block alone over-counts
what is tracked. Carrying a dropped count in the dossier is the follow-up story
(#1932).
