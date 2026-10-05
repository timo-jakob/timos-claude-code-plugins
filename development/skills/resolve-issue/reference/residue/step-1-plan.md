<!-- Shard of reference/residue.md (#2056), read in its index's order:
     step 1 of the residue branch, build the plan, with the remainder rule. -->

<!-- moved: residue-branch-step-1 -->
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
<!-- /moved: residue-branch-step-1 -->
