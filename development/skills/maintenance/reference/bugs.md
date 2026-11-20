# The bugs concern — analysis and confirmation (#3212)

The procedure the maintenance orchestrator (`development/skills/maintenance/SKILL.md`)
runs for the `bugs` concern: under `--concern=bugs`, and in an unscoped run at
the bugs position of the concern order (Phase 8). A bug moves through two
steps with a human between them: **analysis** writes a bug spec onto the issue,
a code owner **confirms** it with the `confirmed` label, and only then may a
later run **fix** it. This file is the analysis step and the confirmation rule;
the fix step is a later story of the scheduled-maintenance epic (#3210). The
bug spec's format is ARCHITECTURE.md, *Bug spec contract (`bug-spec/v1`)*.

**Analysis writes to the issue only.** It changes no file in the repository,
creates no branch and opens no PR. The falsifying test is part of the spec's
text until the fix step writes it.

## 1. Classify every open bug

From the repository root:

```bash
"<skill-base-dir>/scripts/list-bugs.zsh" --repo "$REPO" --repo-dir . > <scratch>/bugs.json
```

It prints one object per open `bug`-labelled issue, already in the order the
concern works them, each with a `state` and a `reason`. **Exit 1** is a tooling
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
| `needs-analysis` | analyse it (section 2) |
| `awaiting-confirmation` | nothing; list it with its reason — it waits for a code owner |
| `not-a-bug` | nothing; its comment already proposed the reclassification |
| `confirmed` | nothing here; the fix step takes it |
| `held` | nothing; list it with its reason (a hold label, or the open PR) |
| `not-eligible` | nothing; list it as "needs a code owner to re-file" |

## 2. Analyse each `needs-analysis` bug, in order

Under `--dry-run`, stop after section 1 and list what a live run would
analyse: a dry run writes nothing, to GitHub included.

For each `needs-analysis` bug, in the order `list-bugs.zsh` printed:

1. **Dispatch `development:bug-analyst`** (Task tool, foreground), naming the
   repo, the checkout's path and the issue number. It returns one JSON object;
   write it to `<scratch>/bug-<N>-analysis.json`. A reply that is not one JSON
   object is a failed analysis: list the bug as "analysis failed" with the
   reply's first line and go on to the next.
2. **Write the spec into the body:**

   ```bash
   gh issue view <N> --repo "$REPO" --json body -q .body > <scratch>/bug-<N>-body.md
   "<skill-base-dir>/scripts/bug-spec.zsh" render --analysis <scratch>/bug-<N>-analysis.json \
     --body-file <scratch>/bug-<N>-body.md > <scratch>/bug-<N>-new-body.md
   gh issue edit <N> --repo "$REPO" --body-file <scratch>/bug-<N>-new-body.md
   ```

   `render` keeps every byte of the reporter's text and appends the spec, or
   replaces the spec a previous analysis wrote. **Exit 1** means the analysis is
   unusable (a key missing, a value outside its enum, a heading missing from
   the prose) or the body holds a spec cut short: write nothing, list the bug
   as "analysis failed" with the stderr line, and go on. **Exit 3** is a
   tooling failure, listed the same way.
3. **Comment once.** Post one comment carrying the marker
   `<!-- bug-spec-awaiting/v1 -->`, unless a comment on the issue already
   carries it (`gh issue view <N> --json comments` — a re-analysis does not
   comment twice):
   - verdict `bug`: the spec is on the issue and awaits a code owner's
     `confirmed` label; a code owner confirms it by applying that label, and an
     edit to the spec after the label voids the confirmation.
   - verdict `not-a-bug`: no existing specification says the current
     behaviour is wrong, so the run proposes reclassifying it as the
     analysis's `reclassify_as` (and names its `intentional_per`, when one
     makes the behaviour intentional). The run stops there for this issue: it
     never relabels it and never fixes it.

   Ensure the label exists first, idempotently:
   `gh label create confirmed --color 0e8a16 --description "A code owner confirmed this bug's spec" 2>/dev/null || true`.

## 3. Confirmation

A bug is fixable only when
`"<skill-base-dir>/scripts/check-bug-confirmation.zsh" <N> --repo "$REPO" --repo-dir .`
exits 0: a spec exists, its verdict is `bug`, the latest event that applied
`confirmed` was a code owner's, and the spec is unchanged since — its prose
still matches the block's `prose_sha256`, and the body was not edited after the
label. Exit 1 names the first check that failed on one stderr line,
`bug-confirmation: <reason>`; exit 3 decided nothing and is never read as
either answer. The confirmation is what makes a bug fixable, not the absence of
a human at the keyboard, so an attended run applies the same rule.

## 4. Report

The Phase 9 summary gets one `Bugs` block: the bugs analysed this run (with
their verdicts), and the counts and numbers of every other state, each with
its reason. A bug whose analysis failed is listed with why.
