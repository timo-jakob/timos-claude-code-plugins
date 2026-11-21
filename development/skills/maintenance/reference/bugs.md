# The bugs concern — fix, analysis and confirmation (#3212, #3213)

The procedure the maintenance orchestrator (`development/skills/maintenance/SKILL.md`)
runs for the `bugs` concern: under `--concern=bugs`, and in an unscoped run at
the bugs position of the concern order (Phase 8). A bug moves through two
steps with a human between them: **analysis** writes a bug spec onto the issue,
a code owner **confirms** it with the `confirmed` label, and only then may a
later run **fix** it (#3213). This file is the fix step, the analysis step and
the confirmation rule. The bug spec's format is ARCHITECTURE.md, *Bug spec
contract (`bug-spec/v1`)*.

**The bugs cap: at most 5 bugs per run, attended or scheduled.** Each fix and
each analysis counts one, fixes first, in the order `list-bugs.zsh` printed.
Each fix is a whole `resolve-issue` run that can take hours, so a run typed by
hand is capped too. Under `--concern=bugs`, `--batch=N` sets the cap to `N`
instead. A bug the cap leaves is listed as "deferred by the cap" and waits for
the next run.

**Analysis writes to the issue only.** It changes no file in the repository,
creates no branch and opens no PR. The falsifying test is part of the spec's
text until the fix step writes it.

**The names this file uses.** `<skill-base-dir>` is the one SKILL.md defines
in Phase 1 — `development/skills/maintenance/`, as its resolved absolute path.
`<scratch>` is the run's scratch directory, the one SKILL.md's start stamp
writes `<scratch>/maintenance-run.json` into; substitute its resolved path.
`<N>` is the number of the bug being worked, the `number` field of its object
in `<scratch>/bugs.json`. `REPO` is the repo's `owner/name`, set in section 1's
first step.

## 1. Classify every open bug

First read the repo's `owner/name` into `REPO`, from the repository root:

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" && [[ -n "$REPO" ]]
```

When that fails or leaves `REPO` empty, stop the bugs concern, quote the
failure in the Phase 9 summary and go on with the run: never run a script or a
`gh` call below with an empty `--repo`. Every later command in this file passes
`--repo "$REPO"`. Shell variables do not survive between steps (SKILL.md,
Phase 4 — the same reason `<skill-base-dir>` is a placeholder), so a command
that runs in a new shell sets `REPO` again with the line above first.

Then, from the repository root:

```bash
"<skill-base-dir>/scripts/list-bugs.zsh" --repo "$REPO" --repo-dir . > <scratch>/bugs.json
```

It prints one object per open `bug`-labelled issue, already in the order the
concern works them, each with a `number`, a `state` and a `reason`. **Exit 1** is a tooling
failure — a `gh` read, the code-owner lookup or a confirmation check that could
not decide: skip the concern, quote its stderr in the Phase 9 summary and go
on with the run. **Exit 2** is your own malformed call: fix it and re-run once.

**Only a code owner's bug is ever analysed.** A bug whose author is not a code
owner of the repo (`codeowners-logins.zsh` reads the first of
`.github/CODEOWNERS`, `CODEOWNERS`, `docs/CODEOWNERS`, expands teams and skips
e-mail entries) is `not-eligible`: its text is never handed to an agent. List
each one in the summary as "needs a code owner to re-file". When every bug is
`not-eligible` because the repo has no code owners — the reason begins
`no code owners:` — say so in one line: with no CODEOWNERS, no bug is eligible.

What each state means for this step:

| `state` | This step |
| --- | --- |
| `needs-analysis` | analyse it (section 3) |
| `awaiting-confirmation` | nothing; list it with its reason — it waits for a code owner |
| `not-a-bug` | nothing; its comment already proposed the reclassification or said the report does not reproduce |
| `confirmed` | fix it (section 2) |
| `held` | nothing; list it with its reason (a hold label, or the open PR) |
| `not-eligible` | nothing; list it as "needs a code owner to re-file" |

## 2. Fix each `confirmed` bug, in order

A `--dry-run` stops at Phase 5 and a `--no-merge` run skips Phase 8, so
neither reaches this file.

For each `confirmed` bug, in the order `list-bugs.zsh` printed, **one after
another** — never two at once — while the cap allows:

1. **Re-check the confirmation immediately before the fix.** A code owner may
   have removed the label, or someone edited the spec, since `list-bugs.zsh`
   read it:

   ```bash
   "<skill-base-dir>/scripts/check-bug-confirmation.zsh" <N> --repo "$REPO" --repo-dir .
   ```

   Exit 0 → fix it (step 2). Exit 1 → do not fix it: list it with the stderr
   reason and go on to the next bug. Exit 3 decided nothing: list it as
   "confirmation could not be checked" and go on. Neither counts against the
   cap.
2. **Run `/development:resolve-issue <N>`** (Skill tool) in this session. It is
   the maintenance pipeline's run, so it is unattended: its session mode is
   `unattended` and it asks no one. It writes the falsifying test first, and
   records it failing before the fix and passing after it; it opens a PR only
   then, with the **Bug evidence** section in the body
   (`development/skills/resolve-issue/reference/fail-first.md`).
3. **Record how the run ended** and start the next bug, whatever the ending:
   - a PR — its number, and whether it merged;
   - a **clean stop** — the clean-stop comment on the issue; a later attended
     `--resume` continues it;
   - **`spec-does-not-reproduce`** — the falsifying test passed on the code
     before the fix, so nothing was fixed; the issue now carries
     `needs-human-decision` and is `held` on later runs;
   - any other stop — the reason the run reported.

   No ending of one bug stops the concern: the next bug starts.

## 3. Analyse each `needs-analysis` bug, in order

For each `needs-analysis` bug, in the order `list-bugs.zsh` printed, while the
cap allows:

1. **Dispatch `development:bug-analyst`** (Task tool, foreground), naming the
   repo, the checkout's path and the issue number. It returns one JSON object;
   write it to `<scratch>/bug-<N>-analysis.json`. A reply that is not one JSON
   object is a failed analysis: list the bug as "analysis failed" with the
   reply's first line and go on to the next.
2. **Write the spec into the body:**

   ```bash
   gh issue view <N> --repo "$REPO" --json body -q .body > <scratch>/bug-<N>-body.md &&
   "<skill-base-dir>/scripts/bug-spec.zsh" render --analysis <scratch>/bug-<N>-analysis.json \
     --body-file <scratch>/bug-<N>-body.md > <scratch>/bug-<N>-new-body.md &&
   gh issue edit <N> --repo "$REPO" --body-file <scratch>/bug-<N>-new-body.md
   ```

   `render` keeps every byte of the reporter's text and appends the spec, or
   replaces the spec a previous analysis wrote. **Exit 1** means the analysis is
   unusable (a key missing, a value outside its enum, a heading missing from
   the prose) or the body holds a spec cut short: write nothing, list the bug
   as "analysis failed" with the stderr line, post no comment, and go on to the
   next bug. **Exit 3**, or either `gh` call failing, is a tooling failure,
   handled the same way. **Exit 2** is your own malformed call: fix it and re-run once.
3. **Comment once.** Post one comment carrying the marker
   `<!-- bug-spec-awaiting/v1 <verdict> -->`, where `<verdict>` is the
   analysis's `verdict` (`bug` or `not-a-bug`), unless a comment on the issue
   already carries it with this verdict
   (`gh issue view <N> --repo "$REPO" --json comments` — a re-analysis
   comments again only when its verdict changed):
   - verdict `bug`: the spec is on the issue and awaits a code owner's
     `confirmed` label; a code owner confirms it by applying that label,
     removing and re-applying it if it is already on, and any edit to the issue
     body after the label voids the confirmation until it is applied again.
   - verdict `not-a-bug`: no existing specification says the current
     behaviour is wrong, so the run proposes reclassifying it as the
     analysis's `reclassify_as` (and names its `intentional_per`, when one
     makes the behaviour intentional); when `reclassify_as` is `null`, it says
     instead that the report does not reproduce. The run stops there for this
     issue: it never relabels it and never fixes it.

   Ensure the label exists first, idempotently:

   ```bash
   gh label create confirmed --repo "$REPO" --color 0e8a16 \
     --description "A code owner confirmed this bug's spec" 2>/dev/null || true
   ```

## 4. Confirmation

A bug is fixable only when
`"<skill-base-dir>/scripts/check-bug-confirmation.zsh" <N> --repo "$REPO" --repo-dir .`
exits 0: a spec exists, its verdict is `bug`, the latest event that applied
`confirmed` was a code owner's, and the spec is unchanged since — its prose
still matches the block's `prose_sha256`, and the body was not edited after the
label. Exit 1 names the first check that failed on one stderr line,
`bug-confirmation: <reason>`; exit 3 decided nothing and is never read as
either answer. The confirmation is what makes a bug fixable, not the absence of
a human at the keyboard, so an attended run applies the same rule.

## 5. Report

The Phase 9 summary gets one `Bugs` block: the bugs fixed this run (each with
how its run ended, section 2), the bugs analysed this run (with their
verdicts), the bugs deferred by the cap, and the counts and numbers of every
other state, each with its reason. A bug whose analysis failed is listed with
why.
