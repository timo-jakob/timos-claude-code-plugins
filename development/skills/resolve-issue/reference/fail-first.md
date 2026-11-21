# resolve-issue — a bug fix proves itself fail-first

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it
when §2 or §6 points here, never up front. A bug a code owner confirmed
carries a `bug-spec/v1` block naming a falsifying test (ARCHITECTURE.md, *Bug
spec contract (`bug-spec/v1`)*). The fix must show that test failing on the
code before the fix and passing with it, and the PR carries both results
(ARCHITECTURE.md, *Fail-first evidence (#3213)*). `fail-first.zsh` reads the
test, runs and records it, checks the pair and renders the evidence; its header
states each subcommand's output and exit codes, and this file is only the
procedure that consumes them.

## Detect the bug spec (#3213)

At the start of §2, before the size pre-flight, from the repository root:

```bash
gh issue view <N> --json body -q .body > <scratch>/issue-<N>-body.md
"<skill-base-dir>/scripts/fail-first.zsh" spec --body-file <scratch>/issue-<N>-body.md \
  > <scratch>/bug-test-<N>.json
```

- **Exit 1** — the issue carries no bug spec. **An issue without the block is
  untouched by all of this**: run §2 to §7 exactly as written, and read nothing
  more of this file.
- **Exit 0** — `<scratch>/bug-test-<N>.json` is the falsifying test,
  `{path, name, command}`. This run is a **bug fix**: take *The falsifying test
  first* below before any other edit, and §6's and §7's steps of this file
  later.
- **Exit 4** — a bug spec this run cannot fix from; stderr names the reason
  (`unreadable-spec`, `spec-prose-edited`, `not-a-bug`, `no-falsifying-test`,
  `command-not-in-prose`). Edit nothing, and post one comment carrying
  `<!-- fail-first/v1 <reason> -->` with the stderr line, then apply
  `needs-human-decision` (created idempotently, as below). Emit the run's
  record as `failed` (§7) and stop: a step's verdict is `stopped`, cause
  `failed`, with the stderr line as its reason.
- **Exit 3** decided nothing — the issue body could not be read or the spec
  reader failed. Report the stderr, emit the run's record as `failed` and
  stop: a step's verdict is `stopped`, cause `tooling`. **Exit 2** is your own
  malformed call: fix it and re-run once.

**The command is trusted only as the code owner confirmed it.** The prose is
what a code owner reads before applying `confirmed`, and only the prose is
hashed; the JSON block is not. `spec` therefore hands back a command only when
the prose still matches its hash and carries that command verbatim, so an edit
to the block alone can never choose what this run executes.

## The falsifying test first (#3213)

Note the **base**: the `base` §1's branch script printed, the commit this
branch was cut from. A run resumed from a checkpoint skips §1 and takes the
parent of the branch's first `wip(resolve-issue #<N>)` commit instead. The
record file lives in `<durable>`, the run's durable folder — the `base` path
`clean-stop.zsh dir --repo-dir <worktree> --issue <N>` prints (create it when
absent) — so a checkpoint resume finds it:

1. **Write the falsifying test, and nothing else.** The size pre-flight's
   inventory lists its `path`. The first implementation edit adds the test
   named `name` at `path`. No source file changes yet.
2. **Record it at the base**, from the repository root, the test still
   uncommitted on top of the base:

   ```bash
   "<skill-base-dir>/scripts/fail-first.zsh" record --phase before --sha <base> \
     --out <durable>/fail-first.jsonl --log <durable>/fail-first.log \
     -- zsh -c "$(jq -r .command <scratch>/bug-test-<N>.json)"
   ```

   Exit 0 recorded it, whatever the test exited. Exit 3 is a tooling stop:
   report the stderr, emit the record as `failed`, and end a step `stopped`
   with cause `tooling`. Exit 2 is your own call: fix it and re-run once.
3. **Read the result** — the last line's `exit` in `<durable>/fail-first.jsonl`.
   A non-zero exit must be the test's own assertion failing, as
   `<durable>/fail-first.log` shows it. A test that cannot run (a syntax error,
   a missing tool) proves nothing: rewrite it and record again. Only the last
   `before` record counts.
4. **When the test passes on the base, the spec does not reproduce.** The run
   **fixes nothing**: it changes no source file, pushes nothing and opens no PR.
   Its outcome is `spec-does-not-reproduce`. Post one comment carrying
   `<!-- fail-first/v1 spec-does-not-reproduce -->`, naming the command and the
   base, then apply `needs-human-decision`, which holds the bug out of later
   maintenance runs (`list-bugs.zsh` reports it `held`):

   ```bash
   gh label create needs-human-decision --color d93f0b \
     --description "Needs a human decision before automation continues" \
     2>/dev/null || true   # idempotent: ignore "already exists"
   gh issue comment <N> --body-file <scratch>/fail-first-comment-<N>.md
   gh issue edit <N> --add-label needs-human-decision
   ```

   Emit the run's record as `failed` (§7) and stop. A step's verdict is
   `stopped`, cause `failed`, reason `spec-does-not-reproduce`.
5. **Otherwise fix the bug**, and go on with §2's size pre-flight already passed,
   §3's gate and §3.5's loop as usual. The falsifying test stays in the change.

## Before the PR — record it again and check (#3213)

At §6, after open-pr's Step 1b and before its Step 3 push, so the commit
recorded is the one the PR carries, from the repository root:

```bash
"<skill-base-dir>/scripts/fail-first.zsh" record --phase after --sha "$(git rev-parse HEAD)" \
  --out <durable>/fail-first.jsonl --log <durable>/fail-first.log \
  -- zsh -c "$(jq -r .command <scratch>/bug-test-<N>.json)"
"<skill-base-dir>/scripts/fail-first.zsh" check --base <base> <durable>/fail-first.jsonl
```

**`check` must exit 0 before a PR is opened.** Exit 1 names the reason on
stderr (`fail-first: <reason>`): open no PR, emit the record as `failed` and
stop, a step ending `stopped`, cause `failed`, with that line as its reason.
Exit 3 is the same stop with cause `tooling`.

On exit 0, `render <durable>/fail-first.jsonl` prints the **Bug evidence**
section — the command, both exits and both commits. It goes into the PR body
once, as open-pr's *Bug evidence (#3213)* paragraph places it. A render that
exits non-zero stops the PR the same way.
