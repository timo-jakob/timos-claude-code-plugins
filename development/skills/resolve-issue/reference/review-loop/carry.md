<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     carry accounting, carry-driven dispatch, skippable dimensions, the third histogram state. -->

### Carry accounting — confirmed, re-raised, unconfirmed (#1583)

The `fix_verification_path` bullet above (step 1) tells the reviewers to re-raise a
fix the reviewer failed to confirm at its original severity, and step 2's
carry arm treats a round whose count does not add up — fewer confirmations than
carries and no re-raise of the remainder — as failed. Both sit inside a
byte-frozen `moved:` span, so — exactly as
the #1571 correction above — the rule that replaces them is recorded here
rather than edited into the span. **Where the span and this section disagree, this
section governs.**

**Every carried entry has exactly one owner (#2010): the reviewer of its own
dimension.** The panel splits the carry with `review-dispatch.zsh split-carry
--fix-verification <work_dir>/verify-<R>.json`, which writes each dimension's
entries to `verify-<R>-<dimension>.json` and prints the `{dimension: path}`
map, and hands each reviewer only its own dimension's path; a reviewer whose
dimension is not in the map gets no Fix verification line at all. No reviewer
is ever shown another dimension's entry, so each entry is verified once, by the
one reviewer that can act on it. *(Retired: until #2010 every reviewer was
handed every entry and accounted for each one, and one confirmation from any of
them decided the outcome — about five verifications per entry, almost all of
them `unconfirmed` reports from reviewers that could not re-raise it.)*

The owner reports ONE of three outcomes for each of its entries:
**confirmed** (it names where the fix is); **re-raised** (it observed the
defect **still present** and cites what it saw — the file:line and the
unchanged text, or the passing mutation — never the absence of a fix; the
re-raise goes into the findings file at its original severity, citing the
carried entry, *even when its file is outside this round's delta*); or
**unconfirmed** (it could not establish either). An unconfirmed entry is a
count, not a defect: it never enters the findings file and never becomes a
blocking finding on its own. **The owner's report decides the accounting
outcome** — and a re-raise in the findings file is a finding like any other:
aggregate it unchanged; the loop carries it forward on its own evidence. A
re-raise keeps the entry's own dimension, since the identity the loop matches
on includes it. Cross-dimension observations are no longer a duty: a reviewer
that sees a problem in the same code raises it, if at all, as a finding of its
own dimension. What is refused — by the loop, not by you — is a carried entry
its owner neither confirmed **nor** re-raised, silent or reported-unconfirmed
alike, and that includes an entry whose owning dimension was not dispatched or
contributed no record: fail-closed on every round, the closing sweep and the
final round included.

**Tell each reviewer to account for every carried entry of its own dimension
by the carry's own spelling, one line per entry, before its triple** (the
panels' prompt-template line says so): `carried entry "<title>" (<file>,
<dimension>): confirmed at <file:line> | re-raised (see finding) |
unconfirmed`, then `carried: confirmed N / re-raised M / unconfirmed K of
TOTAL`, where TOTAL is the length of its own dimension's file. The per-entry
lines are what you assemble; each triple is the checksum that its reviewer's
list is complete, and the reviewers' TOTALs together sum to the length of
the file the split ran on. A reviewer that leaves any entry of its own
dimension's file without a per-entry line took the wrong branch —
re-dispatch **the panel** for that reviewer's dimension only (you never spawn
a reviewer agent directly: the panel's Step 1 is what wires the JSON layer and
the fix-verification line into its prompt), never invent a record.

**Supply the accounting — without it the loop refuses.** On every round whose
`verify-<R>.json` is non-empty, assemble one file from the reviewers' per-entry
lines — an array of per-identity records, one per entry of `verify-<R>.json`,
each naming its owning reviewer under the one outcome it reported:

```json
[{"file": "…", "dimension": "…", "title": "…",
  "confirmed": ["<owning reviewer>"], "re_raised": [], "unconfirmed": []}]
```

— and pass it as `--carry-accounting <carry-round-R.json>`, kept **outside**
the repo beside `findings-round-R.json`. The invocation templates above gain
that flag; round 1 carries nothing and needs none:

```bash
resolve-story-loop.zsh … --resume --findings-file <…> \
  --carry-accounting <carry-round-R.json> …   # plus the attestation flags, exactly as the templates above
```

The loop matches each record to the carry by identity (file, dimension, title —
the consolidator's own normalisation: file stripped of `./`, dimension
verbatim, title lower-cased and whitespace-collapsed), counts a carried entry
as re-raised when the findings file carries a **blocking entry at that
identity** — same file, dimension and title, whatever its line — or one the
consolidator matched to the carried prior, stamps `carry_accounting: {total, confirmed[],
re_raised[], unconfirmed[]}` into the round's changelist (the progress block
renders it as `carried: confirmed N / re-raised M / unconfirmed K of T`), and
refuses the round as `STALE_FINDINGS` — the **CARRY-UNACCOUNTED** arm, fired
**before** `verify-<R+1>.json` is written, so `verify-<R>.json` stays the carry
and the accumulators are untouched — when: no accounting was supplied; the file
is not that shape (since #2010 that includes a record whose three arrays name
more than one distinct reviewer); a record names no carried identity; a record claims a
re-raise the findings file does not carry (the accounting alone is not
evidence); or a carried identity has **no confirmation and no re-raise** from
its owner. Its stderr names each such entry (`carry unaccounted: round R
carried entry "…" (…) was neither confirmed nor re-raised by any reviewer
(unconfirmed by: … | no reviewer reported it)`) and the status JSON lists them
in `carry_unconfirmed[]` — never in `.blocking` (a record-only re-raise is
refused by name and populates nothing). Step 2's `STALE_FINDINGS` list above is
to be read as `#974, #1434, #1435, #1583, #1485`, this arm the fourth (the
fifth is the EMPTY-STORY-DIFF arm, recorded after the frozen span); like the
empty-delta, full-round and cadence arms it is wiring-independent and fires in
hook mode too, where the panel writes the same records to
`<findings-path>.carry.json`.

**Recover by ground.** For the first three grounds — no accounting supplied,
a file of the wrong shape, a record naming no carried identity — the panel
already ran and its per-entry lines are in `carry-lines-R.txt`: rebuild
`carry-round-R.json` from them with the panel brief's `carry-repair` mode and
re-invoke; no reviewer runs. For an
**unevidenced re-raise** the reviewer's finding sits under the wrong identity:
re-dispatch **the panel** for that entry, quoting the carried `{file,
dimension, title}` verbatim and saying the finding must carry it — the re-dispatch
reaches **only the owning dimension's reviewer** (#2010), never the whole
panel — with an **empty** scope (a delta-round panel reviews nothing and only accounts for the
carry) and a `fix_verification_path` naming only that entry. For an entry
**neither confirmed nor re-raised**, re-dispatch the panel the same way for
those entries only — **except a tool-verdict carry** (one stamped
`"decided": "red"`, or one *The decided pass*'s KNOWN LIMITATION identifies from
`decided-<R>.log`): that re-dispatch cannot succeed until #1647 lands, because
the reviewers it dispatches are the ones the evidence rule forbids from stating
that verdict, so it burns a full panel round to reach the identical refusal.
Report that entry and its `decides:` command, and stop.

**A re-dispatch writes to its own path** —
`findings-round-R-carry.json`, never `findings-round-R.json`, which still holds
the first pass's findings — and the panel brief's `carry-redispatch` mode merges
the two arrays into `findings-round-R.json` (`jq -s 'add' findings-round-R.json
findings-round-R-carry.json`): panel output, never a hand edit; never retype or
reword a finding yourself (a record-only `re_raised[]` is refused, and a
re-raise that never reaches `.blocking` never reaches the next carry).
Re-assemble the accounting from all the per-entry lines and re-invoke. If the
re-run again leaves an entry unaccounted, report it in the conversation and
stop. A confirmed-clean `[]` is legitimate and says so in its triple; the
`kubernetes` panel's not-applicable arm above likewise dispatches each agent with
its own dimension's carry, and each owner accounts for its entries as one of
confirmed, re-raised, unconfirmed.

**One consequence the procedure above still states the old way.** Its parking
rule concludes that "Residue cannot rescue it either: a parked blocker sits in a
file the fix pass deliberately did **not** write, so it fails the residue
condition by construction", and tells you to read a parked-only run as escalating
**by design**. That rested entirely on condition 2. A parked blocker that is in
the story diff is now residue-eligible, so such a run **can** reach the closing
sweep and exit 14.

So do not read a parked-only run as escalating by design — that inference is
retired. **The `File it NOW` rule above is not**: park-time filing stays
mandatory, and the escalation paths still file nothing, so a park nobody filed
is still a finding the run dropped. Only the *justification* the frozen text
gives for it — that filing at a terminal would never happen — no longer holds.

**What the residue branch should DO about it is deliberately not decided
here — #1581 owns it.** The branch files its plan as built, which means a
parked finding can end up with two issues — the one the fix pass filed when it
parked it, and the residue follow-up. That is a known, tracked wart rather than
a rule you should improvise around: a hand-rolled match between the two is
exactly what #1581 exists to specify, because the builder's identity is four
fields and the obvious three-field version silently drops a **non-parked**
sibling at a colliding spot, losing a residual blocker the dossier claims was
filed. Do not attempt it here.

The normative statement, with the reasoning and what is deliberately not
changed, is in `residue.md` § *Condition 2 — removed; the story-diff rail is
upstream (#1571)*.

### Carry-driven dispatch (#2008)

A panel may skip a dimension on **delta** rounds — its review skill's Step 1
table says which, and when. Skipping must never strand that dimension's carried
entries, because only the owner can account for them, and an entry its owner
never saw is refused as CARRY-UNACCOUNTED (*Carry accounting*). So the generic
rule is:

**A dimension skipped on delta rounds is dispatched on a delta round exactly
when #2010's split-carry map holds its key.** The map is what `review-dispatch.zsh
split-carry` prints for the round's `verify-<R>.json` — in hook mode,
`$REVIEW_FIX_VERIFICATION_BY_DIMENSION`. Holding the key is the whole test:
it means the round carries at least one entry of that dimension, so its owner
is present to confirm or re-raise each one. A delta round whose map does not
hold the key does not dispatch the dimension, and that is a dimension not
planned for the round — not `dimension-not-run` (*Panel subagent brief*).

The rule only ever **adds** a dispatch. Full rounds — round 1 and every closing
sweep, `scope_mode: "full"` — run every dimension their table plans for them,
whatever the carry holds. A dimension dispatched only for its carry still
reviews the round's scope like any other reviewer; the carry is why it runs,
not a limit on what it may raise.

Where it applies today: the claude-plugin panel's `manifest_bump` dimension
(`claude-plugin-manifest-check`), which runs on full rounds and, on a delta
round, only by this rule; and its `contract` dimension on a delta round the plan
marks skippable (*Skippable dimensions*, below). A panel that adds another
delta-skipped dimension cites this subsection rather than restating it.

### Skippable dimensions (#2009)

`review-dispatch.zsh plan` always emits `skippable_dimensions`, a JSON array of
the dimensions this round's panel may leave out. It is `[]` on every full round
and for every repo type but `claude-plugin`. On a claude-plugin **delta** round
the plan runs `select-contract-dimension.zsh` — a pure selector over the delta's
name-status list and its patch — and emits `["contract"]` when the fix pass
touched no contract surface (no `ARCHITECTURE.md`, no `.claude-plugin/` path, no
agent or SKILL.md frontmatter, no script flag, subcommand, exit code, output key
or env seam, no added, deleted, renamed or copied shipped file, no removed
heading in a shipped `.md`). Any input it cannot judge, and any failure to
decide, leaves the field `[]`: the dimension runs.
Hook mode exports it as `$REVIEW_SKIPPABLE_DIMENSIONS`.

The plan only **offers** the skip; the panel's Step 1 table decides, and a
skipped dimension comes back for its carried entries by *Carry-driven dispatch
(#2008)* above. A delta round whose plan omitted `contract` returns no contract
verdict and is consumed like any other round — the loop adds no check of its
own. A round whose table planned `contract` and did not run it is still the
`failed` / `dimension-not-run` row of the *Panel subagent brief*.

Each round's line in `<work-dir>/history.jsonl` records `skipped_dimensions`:
the plan's field less every dimension the round's carry forced back in, `[]`
when none. The loop keeps the plan's field per round in
`<work-dir>/skippable-<R>.json`, and `build-telemetry-record.zsh` reports the
history as `skipped_dimensions_by_round`.

### The third histogram state — present, below the threshold (#1510)

Step 3's fix-pass trigger above closes two histogram states with an explicit
rule-2 binding and leaves the third open: totals at or above the threshold make
rule 2's collapse MANDATORY, an absent histogram relaxes it to advisory, and a
histogram that is **present** with totals **below** the threshold is never
named — the paragraph ends at "Otherwise the histogram is present." That
paragraph sits inside a byte-frozen `moved:` span, so — exactly as the #1571
and #1583 corrections above — the binding is recorded here rather than edited
into it. **Where the span is silent or disagrees with this section — rule 2's
absolute wording inside it included — this section governs.**

**A present histogram whose totals fall below the threshold binds rule 2 no
harder than an absent one**: a restatement at more than two sites may still be
corrected in place, and the threshold is the only thing that makes collapsing
mandatory. So the three states read: at or above the threshold — collapse
MANDATORY; absent — advisory; present and below — advisory, same as absent.
What a fix pass may observably do differently across the threshold is exactly
one thing: whether it may patch a more-than-two-site restatement copy by copy.
Rules 1, 3 and 4 and the ban on adding surface bind on every round, and the
two-sites-or-fewer rule is unchanged in every state, as the span already says.

This reverses the residue finding's own suggested fix (#1510), which would have
made rule 2 bind as written below the threshold and left the threshold deciding
nothing. The two summary sites — ARCHITECTURE.md's *the class condition that
turns collapsing from advisory into mandatory* and
`docs/explanation/review-loop.md`'s *stops being advisory and becomes required*
— are accurate under this reading and are deliberately not edited.
