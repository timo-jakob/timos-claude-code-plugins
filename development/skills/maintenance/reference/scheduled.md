# Scheduled runs — `--scheduled` and the run budget (#3214)

The rules the maintenance orchestrator (`development/skills/maintenance/SKILL.md`)
follows under `--scheduled`, the flag a run that nobody watches is started with,
and the run budget every run applies. Under `--scheduled` the run **never asks**:
each place the skill would otherwise ask has its path below. It also never
installs a tool or a runtime, never resumes an interrupted run, and never
approves its own work — approval stays whatever the repo declares, the Approver
where one is configured, a human otherwise.

`<skill-base-dir>` is the one SKILL.md defines in Phase 1, as its resolved
absolute path. `<scratch>` is the run's scratch directory, the one SKILL.md's
start stamp writes `<scratch>/maintenance-run.json` into.

## 1. Every prompt and its path under `--scheduled`

Three rules cover every prompt the skill has. Each is reported: the Phase 9
summary gets one line per prompt that took its scheduled path, naming the
prompt and what the run did instead.

- **A missing tool or runtime → skip the work that needed it and report.**
  That work, which its row below names, is not done this run, and nothing is
  installed.
- **An earlier run's checkpoint → discard it past the age its row below
  gives, start fresh and report; a younger one ends the run untouched, reported.**
  The run never resumes. Of the PRs the interrupted run left open, only those Phase
  2.5's inventory or the standing-PR slot collects are picked up; any other is
  not reconciled, and its group can be planned and opened again.
- **Any other prompt → the choice that changes nothing, reported.**

The sites, in the order a run meets them:

| Site | Without `--scheduled` | Under `--scheduled` |
| --- | --- | --- |
| Resume entry, a checkpoint and neither `--resume` nor `--fresh` | asks: resume or start fresh | `age=` beyond 6h, since a live run saves at every stage transition: `checkpoint.zsh clear`, then Phase 1; report the discarded checkpoint's last phase and age. Younger: a run may still be going, so end this run with the checkpoint untouched and report its last phase and age. Under `--dry-run`, the checkpoint is left as it is |
| Phase 3 state pre-flight, exit 1 (a tool is not installed) | halts the run | skip that language: drop it from `supported` and record it in `unsupported`, noted `skipped under --scheduled`, and move every topic that requires it to `unsupported_topics`; report its stderr; the other languages go on |
| Phase 3 state pre-flight, exit 2 (R.4) | `AskUserQuestion` with three options | no question and none of the options: skip that language and the topics that require it as for exit 1, reporting the script's blockers |
| Phase 8 step 8, the post-merge pre-flight exits 1 or 2 (R.4) | halts on exit 1; `AskUserQuestion` on exit 2, as in Phase 3 | the remaining stages of the language and of every topic that requires it are not started: each is recorded `deferred` and reported with the stderr or blockers |
| Phase 8 pre-dispatch hook, the runtime is missing | `AskUserQuestion`: install, install it myself, skip | no question and never `install`: this group and every not-yet-started group of its concern for that target are recorded `deferred` and reported with the hook's `label` |

`--scheduled` with `--resume` is refused in Phase 0, since a scheduled run never
resumes itself; a `--resume` typed later restores `--scheduled` with the other
recorded flags (SKILL.md, *Resume entry*). `--fresh` is accepted, and clears a checkpoint of any age.

A prompt added to the skill later gets its row here and an "under
`--scheduled`" clause beside it in the skill. `tests/maintenance-scheduled-prose.bats`
sweeps every `AskUserQuestion` and "ask the user" in the skill for that clause.

## 2. The run budget

Every run applies the budget, attended or not, once Phase 8 holds the
concern-ordered queue and before the `--batch=N` cap.
`<skill-base-dir>/scripts/apply-run-budget.zsh` decides it; its header is the
contract, and this section is only how the orchestrator calls it.

**The caps.** Per concern and per run: security 5, dependencies 5, bugs 5,
codequality 10, topic 10, counted in planner groups — one per stage. Without
`--scheduled` only the bugs cap applies, so a run typed by hand gets every
other group as before. The open-queue cap is 5. A repo overrides any of them in
the optional `budget:` block of `.maintenance.yml`:

```yaml
budget:
  caps:
    codequality: 4    # any of security, dependencies, bugs, codequality, topic
  queue_cap: 3
```

Read it once per run, before the first budget check — Stage 0's when one
runs, else Phase 8's — and only when `.maintenance.yml` exists at the repo root:

```bash
yq -o=json '.budget' .maintenance.yml > <scratch>/budget.json
```

With no `.maintenance.yml`, or no `budget:` block, every default holds. When
`yq` is missing or fails on the file, every default holds too, and the summary
reports why. `--caps` is the block's `caps` object, `{}` when it has none;
`--queue-cap` is its `queue_cap`, left out when it has none. The bugs cap
`reference/bugs.md` counts against is the same figure: `caps.bugs`, else 5.

**The call.** Add `"opens_pr"` to each group of the ordered queue: `true` unless
the group's `isolation` is `false` (a vendor-PR stage that only triages or
merges standing PRs) or it is `advisory`. Under `--scheduled`, count the open
queue first, as its own call:

```bash
"<skill-base-dir>/scripts/count-open-queue.zsh"   # prints <q>
caps=''
if [[ -f <scratch>/budget.json ]]; then
  caps="$(jq -c 'if . == null then {} elif type == "object" then (if .caps == null then {} else .caps end) else . end' <scratch>/budget.json)" || caps=''
fi
[[ -n "$caps" ]] || caps='{}'
"<skill-base-dir>/scripts/apply-run-budget.zsh" --caps "$caps" [--queue-cap <n>] \
  [--scheduled --queue <q>] \
  [--cutoff-epoch "$MAINTENANCE_CUTOFF_EPOCH"] < <ordered.json> > <scratch>/budget-split.json
```

The caps object reaches the script through `$caps`, read from
`<scratch>/budget.json` in the same command, and is never pasted into the
command line: a JSON object inside shell quotes loses its own quotes. A
`budget:` block that is not a mapping — `budget: off`, say — reaches the script
as it is, so the script refuses it and the failure arm below reports it; it is
never silently read as the defaults.

Without the Maintenance App (SKILL.md, *Identity for PR creation*) this
run's PRs are opened as the user and the script never sees them, so add to
`<q>` each stage of `phase8-stages` whose `pr` is set and whose `status` is
not `merged`, and each PR the `Bugs` block records and does not record as
merged. PRs an earlier run opened that way are counted by nothing, so without
the App the queue cap holds within one run only; the Phase 9 summary says so.

Pass `--scheduled` and `--queue` only under `--scheduled`, and
`--cutoff-epoch` only when `MAINTENANCE_CUTOFF_EPOCH` is set — the epoch
second of the window's cutoff, which the scheduler that starts the run
exports. `run` is the queue Phase 8 works; `--batch=N` then applies to `run`
alone. Each group in `deferred` is recorded as a `deferred` stage in
`phase8-stages` and listed in the Phase 9 summary with its `deferred_by`:
`cap` (its concern's cap was reached), `queue` (the open queue was full) or
`cutoff` (the window had closed).

**The failure arms.** `count-open-queue.zsh` exit 1 printed no count: pass
`--queue <the queue cap>`, so no new PR opens while the queue cannot be read,
and report its stderr. `apply-run-budget.zsh` exit 2 on a `budget:` block it
refuses, or on a `MAINTENANCE_CUTOFF_EPOCH` that is not an epoch second:
report its stderr and call it again without the refused part — the defaults
for a refused block; for a refused cutoff, under `--scheduled`, start nothing
new and record every group `deferred` by `cutoff`, since a window that cannot
be read has to count as closed. Any other exit 2 is your own malformed call:
fix it and re-run once. Exit 1 (jq) decided nothing, so report its stderr.
So did an exit 2 that survives that re-run, and so does the queue SKILL.md
Phase 8's `order-groups.zsh` fallback (its exit 2 or 1) leaves: its groups
carry no `concern`, so never call the script on them; report the
`order-groups.zsh` stderr instead. Without `--scheduled`, work the queue as it is: only the bugs cap would have
applied, and the bugs concern keeps its own count. Under `--scheduled`, start
no group: record each `deferred` with no `deferred_by`, since a run nobody
watches never works without its budget. A group deferred with no
`deferred_by` — here, or by § 1's missing runtime or failed pre-flight, never
by `--batch=N` — is listed in the Phase 9 summary with its reason instead.

## 3. Before each group starts — the cutoff and the queue again

Under `--scheduled`, the budget is checked again before each group of `run`
starts, because the clock moves and a PR this run opened may now be waiting.
Count the queue afresh, as section 2 does, and pipe the one group through the
same script. Stage 0, the coverage improver's PR, is checked the
same way before it is pushed (SKILL.md, *Stage 0*), and with its group before
each Phase 6 dispatch, which only a `cutoff` deferral stops (SKILL.md,
*Phase 6*), and so is each
conflicting bot PR before the standing-PR slot rebases it, with the group
`{"tool": "conflicting_bot_pr", "concern": "codequality", "opens_pr": false}`
(SKILL.md, *Conflicting bot-PR remediation*, which says how one the cutoff
stops is reported). Write the group, as
JSON, to `<scratch>/group.json` with the Write tool first, never inline in the
command: a group's free-text `description` can hold an apostrophe or a quote.

```bash
"<skill-base-dir>/scripts/count-open-queue.zsh"   # prints <q>
jq -c '[.]' <scratch>/group.json | "<skill-base-dir>/scripts/apply-run-budget.zsh" --caps '{}' \
  --scheduled --queue <q> [--queue-cap <n>] [--cutoff-epoch "$MAINTENANCE_CUTOFF_EPOCH"]
```

A group it defers is not started: record it `deferred` with that
`deferred_by`, and go on to the next, which is checked the same way. Once the
cutoff has passed every later group is deferred by `cutoff` too. A group in
progress — its agent spawned — always finishes, its CI cycle and approval gate
included; the cutoff is only ever checked between groups. The same failure
arms as section 2 apply.

## 4. The bugs concern under `--scheduled`

The bugs concern has no planner groups, so `reference/bugs.md` keeps its own
count against the bugs cap. Under `--scheduled`, before each bug it starts,
check it the way section 3 checks a group, with the group
`{"tool": "bugs", "concern": "bugs", "opens_pr": <true for a fix, false for an analysis>}`:
after the cutoff no bug starts; with the queue full no fix starts, while
analyses, which open no PR, go on. A bug it defers is listed in the `Bugs`
block with its `deferred_by` and does not count against the cap.
