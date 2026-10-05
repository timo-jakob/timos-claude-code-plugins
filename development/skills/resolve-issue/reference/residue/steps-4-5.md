<!-- Shard of reference/residue.md (#2056), read in its index's order:
     steps 4-5 of the residue branch, and the known consequence by linkage shape. -->
<!-- The frozen chunk below continues the residue branch's numbered list at
     item 4, so its numbering cannot restart at 1 here. -->
<!-- markdownlint-disable MD029 -->

<!-- moved: residue-branch-steps-4-5 -->
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
<!-- /moved: residue-branch-steps-4-5 -->
