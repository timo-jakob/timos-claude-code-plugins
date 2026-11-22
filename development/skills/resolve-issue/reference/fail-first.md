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

At the start of §2, before the size pre-flight, and again at §6 before *Before
the PR* below — on every run, a resumed one included, since a resume skips §2 —
from the repository root:

```bash
gh issue view <N> --json body -q .body > <scratch>/issue-<N>-body.md
"<skill-base-dir>/scripts/fail-first.zsh" spec --body-file <scratch>/issue-<N>-body.md \
  > <scratch>/bug-test-<N>.json
```

- **Exit 1** — the issue carries no bug spec. **An issue without the block is
  untouched by all of this**: run §2 to §7 exactly as written, and read nothing
  more of this file.
- **Exit 0** — `<scratch>/bug-test-<N>.json` is the falsifying test,
  `{path, name, command}`, and this run is a **bug fix** only once
  `"<skill-base-dir>/../maintenance/scripts/check-bug-confirmation.zsh" <N> --repo "$REPO" --repo-dir .`
  exits 0. Its exit 1 edits nothing and stops, the run's record `failed` and a
  step's verdict `stopped`, cause `failed`, with its stderr line as the reason;
  its exit 3 is Exit 3's stop. At §2, plan and pass §2's size pre-flight with the
  test's `path` in its inventory, then take *The falsifying test first* below
  as the first implementation edit; at §6, take *Before the PR*.
- **Exit 4** — a bug spec this run cannot fix from; stderr names the reason
  (`unreadable-spec`, `spec-prose-edited`, `not-a-bug`, `no-falsifying-test`,
  `command-not-in-prose`). Edit nothing. On `spec-prose-edited` or
  `not-a-bug`, stop as the confirmation's exit 1 above does, so the bug's
  analysis decides again. On the others, post one comment carrying
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
the prose still matches its hash and its last line, which `bug-spec.zsh render`
writes, is exactly ``Falsifying test: `<command>` ``, so an edit to the block
alone can never choose what this run executes.

## The falsifying test first (#3213)

Note the **base**: the `base` §1's branch script printed, the commit this
branch was cut from. A resumed run skips §1 and takes the full id
`git rev-parse <the branch's first wip(resolve-issue #<N>) commit>^` instead.
The record file lives in `<durable>`, the run's durable folder — the `base` path
`clean-stop.zsh dir --repo-dir <worktree> --issue <N>` prints (create it when
absent) — so a resumed run finds it. Any stop below while the test is still
uncommitted first discards it (`git clean -f -- <path>`, or
`git checkout -- <path>` when it extended an existing file), so the next run
starts from a clean tree:

1. **Write the falsifying test, and nothing else.** The first implementation
   edit adds the test named `name` at `path`. No source file changes yet.
2. **Record it at the base**, from the repository root, the test still
   uncommitted on top of the base:

   ```bash
   "<skill-base-dir>/scripts/fail-first.zsh" record --phase before --sha <base> \
     --test "$(jq -r .path <scratch>/bug-test-<N>.json)" \
     --out <durable>/fail-first.jsonl --log <durable>/fail-first.log \
     -- zsh -c "$(jq -r .command <scratch>/bug-test-<N>.json)"
   ```

   Exit 0 recorded it, whatever the test exited, with a hash of the test's file
   as it is now. Exit 3 is a tooling stop:
   report the stderr, emit the record as `failed`, and end a step `stopped`
   with cause `tooling`. Exit 2 is your own call: fix it and re-run once.
3. **Read the result** — the last line's `exit` in `<durable>/fail-first.jsonl`.
   A non-zero exit must be the test's own assertion failing, as
   `<durable>/fail-first.log` shows it. A test that cannot run (a syntax error,
   a missing tool) proves nothing: rewrite it and record again, at most twice,
   then stop as step 4 does, with `test-cannot-run` in place of
   `spec-does-not-reproduce`. Only the last
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
5. **When it fails on its own assertion, fix the bug**, and go on with §3's
   gate and §3.5's loop as usual. The falsifying test stays in the change,
   unchanged after its last `before` record. The script enforces it: every
   record hashes the test's file, and `check` refuses with `test-changed` when
   the test the PR ships is not the one that last failed at the base.
6. **An edit to the test at `path` records `before` again at once** — whether
   it comes from the fix, §3's gate or a §3.5 finding. Never record it from the
   working tree, which holds the fix, and never `git stash` the fix: run the
   edited test in a scratch `git worktree` of the branch's merge-base with
   `origin/main`, with only the test's file copied in, then remove that
   worktree. From the repository root, `<scratch>` and `<durable>` being
   absolute paths:

   ```bash
   test_path="$(jq -r .path <scratch>/bug-test-<N>.json)"
   merge_base="$(git merge-base HEAD origin/main)"
   base_wt="$(mktemp -d)/base"
   git worktree add --detach "$base_wt" "$merge_base"
   mkdir -p "$base_wt/$(dirname -- "$test_path")"
   cp -- "$test_path" "$base_wt/$test_path"
   ( cd "$base_wt" && "<skill-base-dir>/scripts/fail-first.zsh" record --phase before \
       --sha "$merge_base" --test "$test_path" \
       --out <durable>/fail-first.jsonl --log <durable>/fail-first.log \
       -- zsh -c "$(jq -r .command <scratch>/bug-test-<N>.json)" )
   git worktree remove --force "$base_wt"
   ```

   Remove the worktree whatever the record exited. The merge-base is the base
   noted above unless the branch has taken `origin/main` in since; the record
   names the commit it really ran at, and `check` refuses one that is not the
   base. Read the result as step 3 does. A pass means the edit made the test
   stop reproducing the bug: undo the edit to the test and record `before`
   again the same way, so the last `before` record is a failing one.

## Before the PR — record it again and check (#3213)

At §6, after open-pr's Step 1b and before its Step 2, whose fallback can
already push and open the PR, so the commit recorded is the one the PR
carries, from the repository root:

```bash
"<skill-base-dir>/scripts/fail-first.zsh" record --phase after --sha "$(git rev-parse HEAD)" \
  --test "$(jq -r .path <scratch>/bug-test-<N>.json)" \
  --out <durable>/fail-first.jsonl --log <durable>/fail-first.log \
  -- zsh -c "$(jq -r .command <scratch>/bug-test-<N>.json)"
"<skill-base-dir>/scripts/fail-first.zsh" check --base <base> <durable>/fail-first.jsonl
```

**`check` must exit 0 before a PR is opened.** Exit 1 names the reason on
stderr (`fail-first: <reason>`): open no PR, and **hold the bug**, so a later
maintenance run does not rebuild it. Post one comment carrying
`<!-- fail-first/v1 <reason> -->` that names the failed check
(`fail-first.zsh check`) and its stderr line, then apply
`needs-human-decision` — step 4's three commands, with this comment — which
`list-bugs.zsh` reports as `held` until a human clears the hold by removing the
label. Then emit the record as `failed` and stop, a step ending `stopped`,
cause `failed`, with that line as its reason. Exit 3 decided nothing, so it
holds nothing: a plain stop with cause `tooling`.

On exit 0, `render <durable>/fail-first.jsonl` prints the **Bug evidence**
section — the command, both exits and both commits. It goes into the PR body
once, as open-pr's *Bug evidence (#3213)* paragraph places it. A render that
exits 1 holds the bug and stops as a failed `check` does, its comment naming
`fail-first.zsh render`; its exit 3 is the plain tooling stop.
