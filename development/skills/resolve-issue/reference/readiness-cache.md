# resolve-issue — the readiness-verdict cache

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it
when step 0b or E1b points here, never up front. A story whose inputs have not
changed since its last gate keeps that gate's verdict, stamped on the issue
(ARCHITECTURE.md, *Readiness stamp contract*). `readiness-stamp.zsh` reads and
writes the stamps, and `readiness-cache-plan.zsh` turns its `check` into one
decision; each script's header states its document and exit codes, and this
file is only the procedure that consumes them (#2955).

## Step 0b — gate only a stamp miss

From the repository root (`check` re-runs the size check there):

```bash
"<skill-base-dir>/scripts/readiness-stamp.zsh" check --repo "$REPO" --issue <N> \
  > <scratch>/stamp-check.json
rc=$?
"<skill-base-dir>/scripts/readiness-cache-plan.zsh" --targets <N> \
  --check <scratch>/stamp-check.json --check-exit "$rc" > <scratch>/readiness-plan.json
```

- **The issue is in `hits`** → take its `verdict` as if the gate had just
  returned it, `risk` included, and branch on it as step 0b says. Spawn no gate
  and write no stamp. A cached verdict that failed the dependency check is never
  a hit: the planner gates it fresh as `dependencies_recheck`, since the edge that
  resolves it may sit on another issue and moves no stamp key.
- **The issue is in `dispatch`** → spawn the gate as step 0b says, after reading
  the issue's key, and stamp its verdict (*Stamping a fresh verdict*, below).
- **`fallback` is `true`** → the stamp check failed, so the story is gated
  fresh. Say so once in the run output, quoting `fallback_reason`. It never
  halts the run.
- **The planner exits 2** → your own malformed call: fix it and re-run once. Any
  other nonzero exit, or a second 2, gates the story fresh; say so.

Keep `<scratch>/readiness-plan.json`: §2's `story-preflight` record carries its
`readiness_cache` (`--readiness-cache <scratch>/readiness-plan.json`). Leave
the flag out only when the planner failed and the story was gated fresh.

## E1b — gate only the stamp misses

Before spawning anything, start `<scratch>/deps.jsonl` from an empty file, append
one `"<skill-base-dir>/scripts/read-dependencies.zsh" --repo "$REPO" --issue <child>`
record per child to it, then read the stamps and plan. Only this run's records may be in the file: an
earlier run's line would stand in for a read that failed or a cycle since broken.
A child whose read fails gets no line, and the planner then gates it fresh. From
the repository root:

```bash
: > <scratch>/deps.jsonl
for child in <the open leaves>; do
  "<skill-base-dir>/scripts/read-dependencies.zsh" --repo "$REPO" --issue "$child" \
    >> <scratch>/deps.jsonl || true
done
"<skill-base-dir>/scripts/readiness-stamp.zsh" check --repo "$REPO" --epic <N> \
  > <scratch>/stamp-check.json
rc=$?
"<skill-base-dir>/scripts/readiness-cache-plan.zsh" --targets <the open leaves, comma-separated> \
  --check <scratch>/stamp-check.json --check-exit "$rc" --deps <scratch>/deps.jsonl \
  > <scratch>/readiness-plan.json
```

`check --epic` targets the open same-repo leaves at any depth, and `--targets`
and `--deps` list the same leaves, so `reference/epic-tree.md`'s E1b rules hold
for a cached leaf exactly as for a freshly gated one.

- **`dispatch`** → spawn `story-readiness` for exactly these children, in
  parallel, as E1b says. An empty list spawns none. Read each child's key first
  and stamp each fresh verdict (*Stamping a fresh verdict*, below).
- **`hits`** → take each cached `verdict`, `risk` included, as if the gate had
  just returned it. A cached verdict that failed the dependency check, a cycle
  included, is never a hit: the planner dispatches it as `dependencies_recheck`,
  so the current graph decides it.
- **`cycle_members`** → each counts `NEEDS_REFINEMENT`, with the cycle from
  `cycles` as its refinement question, and gets the label and comment like any
  unready child. A cycle is never stamped and never read from a cached verdict:
  the dependency records are tested on every run, before ordering.
- **`fallback` is `true`** → every child in `dispatch` is gated fresh; the
  `cycle_members` still count as above. Say so once in the run output, quoting
  `fallback_reason`; it never halts the run. A planner exit 2 is your own call:
  fix it and re-run once. Any other nonzero exit, or a second 2, gates every
  child fresh: no plan exists.

E1b's halt and proceed rules then apply to the combined verdict set, unchanged.
Keep the plan's `readiness_cache` for the epic record
(`reference/epic-telemetry.md`).

## Stamping a fresh verdict

Before spawning the gate on a miss, read the issue's key:
`"<skill-base-dir>/scripts/readiness-stamp.zsh" key --repo "$REPO" --issue <N>`
prints it. **Stamp every fresh verdict, `READY` and `NEEDS_REFINEMENT` alike**,
right after the gate returns and before you post any label or comment. Write the
verdict JSON exactly as returned to a scratch file and record it:

```bash
"<skill-base-dir>/scripts/readiness-stamp.zsh" write --repo "$REPO" --issue <N> --verdict-file \
  <scratch>/verdict-<N>.json --expect-key <the key read before the gate>
```

An `action` of `skipped_stale` means the issue changed while the gate ran:
nothing is stamped, so the next run gates it fresh. Proceed with this verdict all
the same. When `key` failed, run `write` without `--expect-key`. Neither a failed
`key` nor a `write` that exits nonzero is fatal: report it and go on, since the
next run simply misses. A cached hit is never re-stamped.
