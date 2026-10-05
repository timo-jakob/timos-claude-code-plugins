<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     topic panels. -->

### Topic panels — every `topic_review_skills` entry joins the round (#1072)

**Review panel, in-session** (step 1 above) names one skill, `review_skill`,
and step 2's recovery arms were written for one panel per round. Both sit inside
the byte-frozen span, so the topic-composition rule is recorded here. **Where
step 1 or step 2 and this section disagree, this section governs.**

The plan also carries `topic_review_skills` — an always-present array of
`development-<topic>:review` skills, `[]` when no topic applies (ARCHITECTURE.md,
*Review-panel invocation contract*). With `[]` step 1 is exactly as written.
Otherwise:

- **Start every panel in the same round, against the same descriptor.** Spawn
  the reviewers of `review_skill` **and** of every `topic_review_skills` entry,
  in one message, each scoped exactly as step 1 scopes the language panel — the
  same `changed_files`, the same `worktree_root` rail and opener, the same
  `fix_verification_path` and `adjudicated_path`. A topic panel is never given
  a narrower or wider scope, and never planned by a second `plan` call. Wait for
  **all** of them before step 2.
- **Join their #558 arrays into the one round findings file.** Concatenate every
  panel's findings unchanged. Do no dedup, merge or re-severity of your own: the
  only dedup is `consolidate-findings.zsh`'s existing file + line + dimension
  key, and never drop a finding because another panel reported something
  similar. The round counts once, however many panels contributed.
- **A topic panel with nothing in scope that it reviews adds `[]`** — it
  contributes no findings and does not fail the round, whether it reported
  NOT APPLICABLE with no file or wrote an empty array. You join nothing for it,
  and joining nothing is not authoring a findings file on its behalf: step 2's
  rule against writing `[]` for a panel is about the round's file, which the
  language panel's output still fills. Step 2's NOT APPLICABLE arm fires on the
  **language** panel's verdict alone; a topic panel's never triggers it, so a
  story outside the topic's subject is neither stopped nor re-run over it.
  **Unless the round's carry holds entries of that panel's dimensions**: then it
  still owes a per-entry line for each of them (confirmed / re-raised /
  unconfirmed), exactly as any panel does on a carried round. A bare NOT
  APPLICABLE with no per-entry lines there is the carry arm's wrong branch —
  re-dispatch that panel — and never a clean contribution, since accepting it
  would retire its own blocker unreviewed.
- **A topic panel that fails fails the round**, exactly as the language panel
  failing does: recover by step 2's arms and re-dispatch that panel. Never
  consolidate the other panels' findings as if the failed one had reported
  clean.
- **Each panel checks the carried blockers raised by its own reviewers.** The
  carry is one file for the whole round, and *Carry accounting* below already
  confines a re-raise to the reviewer of the entry's own dimension. That makes
  a dimension name identify its panel **only because no two panels in a round
  share one**: a topic panel's dimensions carry the topic's own name as a
  prefix, disjoint from every other panel's, language or topic
  (ARCHITECTURE.md, *Registering a review topic*) — otherwise
  `consolidate-findings.zsh`'s file + line + dimension dedup would also merge
  two panels' distinct findings. So an entry a topic panel's reviewer raised
  is confirmed or re-raised by that panel;
  another panel's reviewer reports it `unconfirmed` or stays silent. So judge
  step 2's per-panel carry arm over the **union** of every panel's per-entry
  lines, as *Carry accounting* does: a panel whose triple reads `N of M` with
  `N < M` because the rest belong to another panel's dimensions has **not**
  taken the wrong branch, and is never re-run for it. Join **every** panel's
  per-entry lines into the round's **one** accounting file — the
  `--carry-accounting` file in step mode, the `<findings-path>.carry.json`
  sidecar in hook mode — never one file per panel.

Hook mode sees the same array as `REVIEW_TOPIC_SKILLS` (a JSON array), and the
loop's status JSON reports it as `topic_review_skills`. There the hook, not
you, does the joining: it merges every panel's array into the one
`$REVIEW_FINDINGS` and every panel's carry records into its one sidecar, rather
than letting each panel write the file in turn. Nothing about
convergence changes: the severity map, the blocking rule, the dedup key and the
round cap are untouched.
