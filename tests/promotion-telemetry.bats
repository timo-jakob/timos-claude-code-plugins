#!/usr/bin/env bats
#
# Behavioral tests for suggestion-promotion telemetry + labelling (#995, epic
# #992): the promotion enrichment joined to the run it enriches, the
# `promotion_phase` marker that keeps the documented convergence metrics honest,
# and the per-item `promoted: true` stamp that makes a promoted blocker readable
# as such in every surface that consumes a changelist — the three this suite
# covers, plus build-dossier.zsh's two reads (tests/build-dossier.bats, #1064).
#
# One test per linked test-case issue, named in the title so a reader can trace
# a case to its coverage: #1027 and #1029-#1033 and #1035-#1036 live here;
# #1028 and #1034 (the loop's run_id sidecar) are in
# tests/resolve-story-loop.bats, next to the rest of the loop's telemetry.
#
# The load-bearing properties are the ones a naive implementation gets wrong:
# an enrichment that mints its own run_id validates cleanly and is orphaned
# forever; a promotion sub-loop counted as a story of its own silently inflates
# both published rates; and a label added unconditionally would change every
# artefact of every run that never promoted anything.

bats_require_minimum_version 1.5.0
load assertions

load resolve-issue-corpus

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # #1503 split this skill into a conductor plus reference/*.md. A sweep that
  # counts or reads ACROSS the skill takes the corpus; one that pins WHERE a
  # sentence lives takes the single file. See resolve-issue-corpus.bash.
  CONDUCTOR="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  RI_REF="$REPO_ROOT/development/skills/resolve-issue/reference"
  SKILL="$(resolve_issue_corpus "$REPO_ROOT" "$BATS_TEST_TMPDIR/resolve-issue-corpus.md")"
  EMIT="$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  BTR="$REPO_ROOT/development/skills/resolve-issue/scripts/build-telemetry-record.zsh"
  RPB="$REPO_ROOT/development/skills/resolve-issue/scripts/render-progress-block.zsh"
  BE="$REPO_ROOT/development/skills/resolve-issue/scripts/build-escalation.zsh"
  FIX="$BATS_TEST_DIRNAME/fixtures/promotion-labelling"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" remote add origin https://github.com/timo-jakob/timos-claude-code-plugins.git
  T="$BATS_TEST_TMPDIR/telemetry.jsonl"
  ST="$BATS_TEST_TMPDIR/status.json"
  P="$BATS_TEST_TMPDIR/payload.json"
}

# a phase-1 CONVERGED run record with `n` waived suggestions; prints its run_id
emit_phase1() {   # $1 = waived count · $2 = ts · $3 = wall_s
  local waived="${1:-4}" ts="${2:-1753400000}" wall="${3:-120}"
  local sugg
  sugg=$(jq -nc --argjson n "$waived" '[ range(0; $n)
    | {severity:"SUGGESTION", priority:"Low", blocking:false, dimension:"code_quality",
       file:"s\(.).zsh", line:(10 + .), title:"nit \(.)"} ]')
  jq -nc --argjson s "$sugg" \
    '{status:"CONVERGED", rounds:2, max_rounds:5, promotion_phase:false,
      repo_type:"shell", review_skill:"development-claude-plugin:review",
      escalation_reasons:[], history:[],
      round_changelists:[{round:1, summary:{critical:0,high:0,low:($s|length),blocking:0,conflicts:0},
                          blocking:[], suggestions:$s, conflicts:[]}],
      final_changelist:{blocking:[], suggestions:$s, conflicts:[]}}' > "$ST"
  zsh "$BTR" --status "$ST" > "$P" \
    || { echo "emit_phase1: payload build failed" >&2; return 1; }
  local rid
  rid=$(zsh "$EMIT" --pipeline review-loop --kind run --outcome success --repo-dir "$R" \
    --repo-type shell --issue 995 --ts "$ts" --wall-s "$wall" \
    --telemetry-file "$T" --payload "$P" | jq -r '.run_id')
  # fail LOUDLY: a silent emitter failure yields an empty id and no record, and
  # every caller's assertions would then hold over a sink that never got the
  # phase-1 record — a test that exercises nothing while staying green
  # >&2: the helper is always called inside $( ), so a stdout diagnostic would
  # be captured AS the run_id and pass the caller's non-empty guard
  [ -n "$rid" ] || { echo "emit_phase1: no run_id emitted" >&2; return 1; }
  printf '%s\n' "$rid"
}

# the enrichment SKILL.md appends once the multi-select answer is known
emit_promotion() {   # $1 = run_id · $2 = offered · $3 = promoted
  jq -nc --argjson o "$2" --argjson p "$3" \
    '{event:"suggestion_promotion", suggestions_offered:$o, suggestions_promoted:$p}' \
    > "$BATS_TEST_TMPDIR/enrichment-payload.json"
  run zsh "$EMIT" --pipeline review-loop --kind enrichment --outcome success \
    --run-id "$1" --repo-dir "$R" --repo-type shell --issue 995 \
    --telemetry-file "$T" --payload "$BATS_TEST_TMPDIR/enrichment-payload.json"
}

# The promotion phase's step-3 ```bash fence — the command SKILL.md documents
# for emitting the enrichment. Extracted rather than paraphrased, because the
# suite's own `emit_promotion` helper hand-writes an equivalent invocation: with
# nothing pinning the documented one, SKILL.md could drift to `--kind run`, drop
# `--run-id` or `--telemetry-file`, or carry a wrong relative emitter path, and
# every assertion here would keep proving the EMITTER works while the enrichment
# silently never joined. Same doc/executable guard the refine-issue suite
# applies to its Step 7 fence.
skill_promotion_emit_fence() {
  # #1503 moved the promotion phase into reference/promotion.md, byte-for-byte.
  # Read it THERE rather than through the corpus: this helper narrows to one
  # fence, and a file-wide scan of the whole skill would return whichever
  # indented fence came first.
  local sk="$REPO_ROOT/development/skills/resolve-issue/reference/promotion.md" section out
  # narrow to the step-3 record block first — SKILL.md has many indented fences,
  # and a file-wide fence scan would return whichever came first
  section="$(sed -n '/Record the offered-vs-promoted pair/,/^4\. \*\*Write the promote file/p' "$sk")"
  [ -n "$section" ] || {
    echo "promotion-phase step-3 record block not found in reference/promotion.md" >&2; return 1; }
  [ "$(printf '%s\n' "$section" | grep -c '^   ```bash')" -eq 1 ] || {
    echo "the step-3 record block must contain exactly one bash fence" >&2; return 1; }
  out="$(printf '%s\n' "$section" | sed -n '/^   ```bash/,/^   ```$/p')"
  # a renamed step or a moved fence must REDDEN, never pass vacuously
  [ -n "$out" ] || { echo "promotion-phase emit fence not found in reference/promotion.md" >&2; return 1; }
  printf '%s\n' "$out"
}

# Substitute the documented fence's placeholders. Factored because the two
# fence-running tests below had identical nine-expression pipelines: a renamed
# placeholder in SKILL.md then had to be fixed in two places, and the copy that
# was missed would degrade to a script whose `if` guard never fires — which
# looks exactly like the "silent skip" one of those tests asserts. Values are
# quoted into the replacement so a path containing a space cannot word-split the
# generated script.
substitute_fence() {   # $1 = work-dir holding .telemetry-run-id · $2 = promoted count
  sed -e '/^ *```/d' \
      -e "s|<blocking-phase-work-dir>|\"$1\"|g" \
      -e "s|<scratch>|\"$BATS_TEST_TMPDIR/fence-scratch\"|g" \
      -e "s|<repo>|\"$R\"|g" \
      -e "s|<issue-number>|995|g" \
      -e "s|<N-offered>|4|g" \
      -e "s|<N-picked>|$2|g" \
      -e "s|\[--repo-type T\]||g" \
      -e "s|\[--telemetry-file <the same file the loop was given>\]|--telemetry-file \"$T\"|g" \
      -e "s|.<skill-base-dir>/../../scripts/telemetry/emit-telemetry.zsh.|zsh \"$EMIT\"|g"
}

# --- #1027 happy: the enrichment joins the phase-1 run ----------------------

@test "#1027 the promotion enrichment joins its phase-1 run on run_id and validates" {
  local rid
  rid=$(emit_phase1 4)
  [ -n "$rid" ]
  emit_promotion "$rid" 4 2
  [ "$status" -eq 0 ]

  # the sink holds exactly the two records, and the whole thing conforms
  [ "$(grep -c '' "$T")" -eq 2 ]
  run zsh "$VALIDATE" "$T" --require-records
  [ "$status" -eq 0 ]

  # the enrichment's own envelope: joined, wall-less, event-scoped
  local enr
  enr=$(jq -c 'select(.kind == "enrichment")' "$T")
  [ "$(jq -r '.run_id' <<<"$enr")" = "$rid" ]
  [ "$(jq -r '.wall_s' <<<"$enr")" = "null" ]
  [ "$(jq -r '.pipeline' <<<"$enr")" = "review-loop" ]
  [ "$(jq -r '.outcome' <<<"$enr")" = "success" ]
  [ "$(jq -r '.payload.event' <<<"$enr")" = "suggestion_promotion" ]
  # the payload is EXACTLY the three documented keys — an extra one here is a
  # second owner for a fact the run record already owns
  [ "$(jq -c '.payload | keys' <<<"$enr")" = '["event","suggestions_offered","suggestions_promoted"]' ]
  # ts is the enrichment's OWN moment, never a copy of the run's. A type check
  # alone would PASS under exactly that regression — a copied ts is a number
  # too — so compare the values: the run is stamped 1753400000 and the
  # enrichment takes 'now'.
  [ "$(jq -r '.ts | type' <<<"$enr")" = "number" ]
  local run_ts
  run_ts=$(jq -r 'select(.kind == "run") | .ts' "$T")
  [ "$(jq '.ts' <<<"$enr")" -ne "$run_ts" ]
  [ "$(jq '.ts' <<<"$enr")" -gt 1753400000 ]

  # ...and the join actually answers the question the story exists to answer
  run jq -s --arg rid "$rid" '
    (.[] | select(.kind == "run" and .run_id == $rid)) as $run
    | (.[] | select(.kind == "enrichment" and .run_id == $rid
                    and .payload.event == "suggestion_promotion")) as $e
    | {waived: $run.payload.waived,
       offered: $e.payload.suggestions_offered,
       promoted: $e.payload.suggestions_promoted}' "$T"
  [ "$status" -eq 0 ]
  jq -e '.offered == 4 and .promoted == 2' <<<"$output" >/dev/null
  # suggestions_offered equals the phase-1 `waived` BY CONSTRUCTION (same
  # cross-round union, same identity) — a disagreement is the documented bug
  # signal, so pin it rather than assume it
  jq -e '.waived == .offered' <<<"$output" >/dev/null
}

# --- the DOCUMENTED emit command (#995) -------------------------------------

@test "#1027 SKILL.md's documented emit fence carries the flags the contract requires" {
  local fence
  fence=$(skill_promotion_emit_fence)
  # the enrichment contract, flag by flag — each of these silently breaks the
  # join (or the sink) if it drifts, and the emitter still exits 0 for some
  contains "$fence" "--kind enrichment"
  contains "$fence" "--outcome success"
  contains "$fence" '--run-id "$(cat <blocking-phase-work-dir>/.telemetry-run-id)"'
  contains "$fence" "--pipeline review-loop"
  contains "$fence" "--repo-dir <repo>"
  # --issue is OPTIONAL to the emitter (it defaults to null), so dropping it
  # from the documented fence keeps every other assertion green while every
  # promotion enrichment lands unattributable in a shared sink
  contains "$fence" "--issue <issue-number>"
  contains "$fence" "--telemetry-file"
  contains "$fence" "--payload <scratch>/promotion-enrichment.json"
  contains "$fence" '{event:"suggestion_promotion", suggestions_offered:$offered, suggestions_promoted:$promoted}'
  # --argjson, not --arg: the jq PROGRAM text is byte-identical under either, so
  # a one-word drift here would put STRING counts in every promotion enrichment
  # (payload is open, so the validator accepts them) and any consumer that adds
  # or divides the pair errors or mis-aggregates
  contains "$fence" '--argjson offered <N-offered>'
  contains "$fence" '--argjson promoted <N-picked>'
  # --wall-s is REJECTED on an enrichment; documenting it would make every
  # promotion run exit 2
  lacks "$fence" "--wall-s"
  # the guard that makes "no id -> no record" silent rather than an exit 2
  contains "$fence" 'if [[ -s <blocking-phase-work-dir>/.telemetry-run-id ]]; then'

  # ...and the documented <skill-base-dir> relative path really resolves to the
  # emitter this suite tests
  contains "$fence" '"<skill-base-dir>/../../scripts/telemetry/emit-telemetry.zsh"'
  [ "$(cd "$REPO_ROOT/development/skills/resolve-issue/../../scripts/telemetry" && pwd)/emit-telemetry.zsh" = "$EMIT" ]
}

@test "#1027 running SKILL.md's documented emit fence produces a joinable enrichment" {
  # execute what is documented, not a paraphrase of it: substitute the
  # placeholders and run the fence against a real phase-1 sink
  local rid
  rid=$(emit_phase1 4)
  local WD="$BATS_TEST_TMPDIR/fence-wd"
  mkdir -p "$WD" "$BATS_TEST_TMPDIR/fence-scratch"
  printf '%s\n' "$rid" > "$WD/.telemetry-run-id"

  local script
  script=$(skill_promotion_emit_fence | substitute_fence "$WD" 2)
  # the substitution must have produced something runnable, and NO placeholder
  # may survive into the command — an unsubstituted one degrades the run into a
  # no-op that looks exactly like the documented silent skip
  [ -n "$script" ]
  lacks "$script" "<blocking-phase-work-dir>"
  lacks "$script" "<skill-base-dir>"
  lacks "$script" "<N-"
  lacks "$script" "<repo>"
  run bash -c "$script"
  [ "$status" -eq 0 ]

  # the documented command produced a conformant, JOINED enrichment
  [ "$(grep -c '' "$T")" -eq 2 ]
  local enr
  enr=$(jq -c 'select(.kind == "enrichment")' "$T")
  [ "$(jq -r '.run_id' <<<"$enr")" = "$rid" ]
  [ "$(jq -r '.payload.event' <<<"$enr")" = "suggestion_promotion" ]
  # strict JSON comparison: `jq -r` prints the string "4" and the number 4
  # identically, so a stringified pair would satisfy a text assertion
  jq -e '.payload.suggestions_offered == 4 and .payload.suggestions_promoted == 2' <<<"$enr" >/dev/null
  [ "$(jq -r '.wall_s' <<<"$enr")" = "null" ]
  # the linkage fields the documented --issue / --repo-dir flags carry: without
  # these the record is unattributable in a shared sink, and the emitter exits 0
  # either way
  [ "$(jq '.issue' <<<"$enr")" -eq 995 ]
  [ "$(jq -r '.repo' <<<"$enr")" = "$(jq -r 'select(.kind == "run") | .repo' "$T")" ]
  run zsh "$VALIDATE" "$T" --require-records
  [ "$status" -eq 0 ]
}

@test "#1027 the documented fence survives a work-dir path containing a space" {
  # the substitution quotes its values; without that the generated script
  # word-splits and the test fails as a confusing emitter usage error on any
  # host whose checkout or TMPDIR has a space in it
  local rid
  rid=$(emit_phase1 4)
  local WD="$BATS_TEST_TMPDIR/fence wd with spaces"
  mkdir -p "$WD" "$BATS_TEST_TMPDIR/fence-scratch"
  printf '%s\n' "$rid" > "$WD/.telemetry-run-id"
  run bash -c "$(skill_promotion_emit_fence | substitute_fence "$WD" 1)"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.kind == "enrichment") | .run_id' "$T")" = "$rid" ]
}

@test "#1035 the documented emit fence emits NOTHING when the sidecar is absent" {
  # the `if [[ -s ... ]]` guard IS the documented silent skip; without it the
  # emitter exits 2 on an empty --run-id and the phase sees a failure it is
  # told never to act on
  emit_phase1 4 >/dev/null
  local before
  before=$(grep -c '' "$T")
  local WD="$BATS_TEST_TMPDIR/fence-wd-empty"
  mkdir -p "$WD" "$BATS_TEST_TMPDIR/fence-scratch"   # no .telemetry-run-id in it

  local script
  script=$(skill_promotion_emit_fence | substitute_fence "$WD" 0)
  [ -n "$script" ]
  lacks "$script" "<blocking-phase-work-dir>"
  lacks "$script" "<skill-base-dir>"
  lacks "$script" "<N-"
  run bash -c "$script"
  [ "$status" -eq 0 ]                       # silent skip, not a failure
  [ "$(grep -c '' "$T")" -eq "$before" ]    # and nothing was appended
}

# --- #1030 corner: promoting none is a SETTLED fact, and is recorded --------

@test "#1030 promoting none still yields a record with suggestions_promoted 0" {
  local rid
  rid=$(emit_phase1 4)
  emit_promotion "$rid" 4 0
  [ "$status" -eq 0 ]
  local enr
  enr=$(jq -c 'select(.kind == "enrichment")' "$T")
  jq -e '.payload.suggestions_offered == 4' <<<"$enr" >/dev/null
  # 0 must be RECORDED, not omitted: "shown four, chose none" is the single most
  # informative datum for "do humans act on suggestions?"
  jq -e '.payload.suggestions_promoted == 0' <<<"$enr" >/dev/null
  # Selecting none means no sub-loop runs, so the sink holds exactly the phase-1
  # record and this enrichment. Asserting that alone would be vacuous (nothing
  # in the test could have written a third record), so also prove the join is
  # to the PHASE-1 run specifically: add a promotion-phase record afterwards and
  # require the enrichment's run_id still to be the phase-1 one.
  [ "$(jq -s '[.[] | select(.kind == "run")] | length' "$T")" -eq 1 ]
  [ "$(jq -s '[.[] | select(.payload.promotion_phase == true)] | length' "$T")" -eq 0 ]

  jq -nc '{status:"CONVERGED", rounds:1, max_rounds:5, promotion_phase:true,
           repo_type:"shell", round_changelists:[], final_changelist:{blocking:[]}}' > "$ST"
  zsh "$BTR" --status "$ST" > "$P"
  local sub_id
  sub_id=$(zsh "$EMIT" --pipeline review-loop --kind run --outcome success --repo-dir "$R" \
    --issue 995 --ts 1753400900 --wall-s 30 --telemetry-file "$T" --payload "$P" | jq -r '.run_id')
  # separate statements: in an `a && b` list a failing `a` is exempt from errexit
  # AND short-circuits, so a failed emit above would silently skip both halves
  # and leave the assertion below holding trivially (no second record exists)
  [ -n "$sub_id" ]
  [ "$sub_id" != "$rid" ]
  [ "$(jq -s '[.[] | select(.kind == "run")] | length' "$T")" -eq 2 ]
  [ "$(jq -r 'select(.kind == "enrichment") | .run_id' "$T")" = "$rid" ]
}

# --- #1031 corner: a headless run records nothing extra --------------------

@test "#1031 a headless run of the LOOP emits its run record and no enrichment" {
  # Drive the real path, not the helper: a headless/autonomous run passes no
  # --promote, is never prompted, and therefore has no offered-vs-promoted pair
  # to record. Asserting that over hand-emitted records would be true by
  # construction — the enrichment is emitted by SKILL.md prose, which no fixture
  # can invoke — so run the loop itself and pin what its sink actually holds.
  local LR="$BATS_TEST_TMPDIR/loop-repo"
  mkdir -p "$LR"
  git -C "$LR" init -q
  git -C "$LR" config user.email t@example.com
  git -C "$LR" config user.name tester
  echo base > "$LR/README.md"
  git -C "$LR" add -A
  git -C "$LR" commit -qm base
  git -C "$LR" branch -M main
  echo "print(1)" > "$LR/app.py"
  local STUB="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "{\\"languages\\":[\\"python\\"]}"\n' > "$STUB"
  chmod +x "$STUB"

  local HT="$BATS_TEST_TMPDIR/headless.jsonl"
  run env DETECT_STACK_BIN="$STUB" \
    zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/resolve-story-loop.zsh" \
    --repo "$LR" --base main --work-dir "$BATS_TEST_TMPDIR/headless-wd" \
    --issue 995 --telemetry-file "$HT" \
    --review-cmd 'printf "%s" '"'"'[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"d","reviewer":"q"}]'"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # it logged the suggestion and waived it — the state the phase exists to act on
  [ "$(echo "$output" | jq '.round_changelists[0].summary.low')" -eq 1 ]

  # exactly ONE record, a run, phase-1, and NO enrichment: identical to the
  # behaviour before this story existed
  [ "$(grep -c '' "$HT")" -eq 1 ]
  [ "$(jq -r '.kind' "$HT")" = "run" ]
  jq -e '.payload.promotion_phase == false' "$HT" >/dev/null
  [ "$(jq -s '[.[] | select(.kind == "enrichment")] | length' "$HT")" -eq 0 ]
  # that last assertion is cheap but weak on its own — the loop has no
  # enrichment code path at all, so no script regression could add one. The rule
  # that actually gates it lives in SKILL.md; pin it there.
  local skill_flat
  skill_flat=$(tr '\n' ' ' < "$SKILL" | tr -s ' ')
  contains "$skill_flat" "A headless run, or one with nothing to offer, never reaches here and gets **no record at all**"
  [ "$(jq '.payload.waived' "$HT")" -eq 1 ]
  run zsh "$VALIDATE" "$HT" --require-records
  [ "$status" -eq 0 ]
}

@test "#1031 the enrichment is purely additive: it appends and rewrites nothing" {
  # the other half of "identical to today": adding the pair must not touch the
  # run record that was already on disk
  emit_phase1 4 >/dev/null
  cp "$T" "$BATS_TEST_TMPDIR/before.jsonl"
  local rid
  rid=$(jq -r '.run_id' "$BATS_TEST_TMPDIR/before.jsonl")
  emit_promotion "$rid" 4 1
  [ "$status" -eq 0 ]
  [ "$(head -1 "$T")" = "$(head -1 "$BATS_TEST_TMPDIR/before.jsonl")" ]
  [ "$(grep -c '' "$T")" -eq 2 ]
}

# --- #1035 error: an absent/empty sidecar must never mint an orphan ---------

@test "#1035 a minted run_id would validate cleanly — which is why the guard is on the caller" {
  # The emitter cannot catch this: --run-id is only required to be NON-EMPTY, so
  # a fabricated id produces a perfectly conformant, permanently orphaned
  # record. Prove exactly that, so the reason the guard lives in SKILL.md is
  # pinned by a test rather than by a comment.
  emit_phase1 4 >/dev/null
  jq -nc '{event:"suggestion_promotion", suggestions_offered:4, suggestions_promoted:2}' \
    > "$BATS_TEST_TMPDIR/orphan.json"
  run zsh "$EMIT" --pipeline review-loop --kind enrichment --outcome success \
    --run-id "review-loop-9999999999-dead" --repo-dir "$R" --issue 995 \
    --telemetry-file "$T" --payload "$BATS_TEST_TMPDIR/orphan.json"
  [ "$status" -eq 0 ]
  run zsh "$VALIDATE" "$T" --require-records
  [ "$status" -eq 0 ]                      # conformant...
  # ...and joined to nothing: that orphan is the damage the SKILL.md guard
  # prevents, and no validator ever will
  # bind the id first: `$runs | index(.run_id)` would evaluate .run_id against
  # $runs (an array), not against the enrichment
  run jq -s '[.[] | select(.kind == "enrichment")] as $es
    | [ .[] | select(.kind == "run") | .run_id ] as $runs
    | [ $es[] | .run_id as $r | select(($runs | index($r)) == null) ] | length' "$T"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # The guard is documented where the caller can act on it. Normalize whitespace
  # first: the sentences are re-wrapped whenever the paragraph is edited, so a
  # line-oriented grep would redden on a pure reflow while a genuine deletion of
  # the guard slipped past a looser pattern.
  local skill_flat
  skill_flat=$(tr '\n' ' ' < "$SKILL" | tr -s ' ')
  contains "$skill_flat" "Absent or empty is not an error"
  contains "$skill_flat" 'Never mint or invent a `run_id`'
  # ...and the two ways of losing the join the skill explicitly forbids: holding
  # the id in a shell variable across the prompt turn, and copying it to a fixed
  # scratch path a later story would read as its own
  contains "$skill_flat" "Do not hold it in a shell variable"
  contains "$skill_flat" "Do not copy it to a fixed scratch path first"
}

@test "#1035 the join key is read from the WORK-DIR, never from a copy" {
  # The emit fence must read the loop's own per-run sidecar. A fixed scratch
  # copy is what makes a stale id from an earlier story readable as this run's,
  # so the documented command must not reintroduce one.
  local fence
  fence=$(skill_promotion_emit_fence)
  contains "$fence" '--run-id "$(cat <blocking-phase-work-dir>/.telemetry-run-id)"'
  contains "$fence" 'if [[ -s <blocking-phase-work-dir>/.telemetry-run-id ]]; then'
  lacks "$fence" "<scratch>/telemetry-run-id"
}

# --- #1036 error: the two emitter contract pins this story leans on ---------

@test "#1036 --kind enrichment rejects --wall-s and requires --run-id, appending nothing" {
  jq -nc '{event:"suggestion_promotion", suggestions_offered:1, suggestions_promoted:1}' \
    > "$BATS_TEST_TMPDIR/pin.json"
  : > "$T"

  run zsh "$EMIT" --pipeline review-loop --kind enrichment --outcome success \
    --run-id "review-loop-1-aaaa" --wall-s 5 --repo-dir "$R" \
    --telemetry-file "$T" --payload "$BATS_TEST_TMPDIR/pin.json"
  [ "$status" -eq 2 ]
  contains "$output" "--wall-s"
  [ ! -s "$T" ]

  run zsh "$EMIT" --pipeline review-loop --kind enrichment --outcome success \
    --repo-dir "$R" --telemetry-file "$T" --payload "$BATS_TEST_TMPDIR/pin.json"
  [ "$status" -eq 2 ]
  contains "$output" "--run-id"
  [ ! -s "$T" ]
}

# --- #1033 corner: the promotion pass must not skew the published rates -----

@test "#1033 the documented rate one-liners exclude the promotion pass and the enrichment" {
  # A promotion sub-loop is a fresh invocation: new .t0 -> new ts -> its own
  # (repo, issue, ts) group. Without the predicate it inflates the per-record
  # rate AND adds a second group for ONE story to the first-pass rate.
  local rid
  rid=$(emit_phase1 4 1753400000 120)          # phase 1: CONVERGED
  emit_promotion "$rid" 4 2
  [ "$status" -eq 0 ]

  # a second story that never converged, so the rates are not trivially 1
  jq -nc '{status:"BUDGET_EXHAUSTED", rounds:5, max_rounds:5, promotion_phase:false,
           repo_type:"shell", round_changelists:[], final_changelist:{blocking:[]}}' > "$ST"
  zsh "$BTR" --status "$ST" > "$P"
  zsh "$EMIT" --pipeline review-loop --kind run --outcome escalated --repo-dir "$R" \
    --issue 996 --ts 1753500000 --wall-s 300 --telemetry-file "$T" --payload "$P" >/dev/null

  local RL='[.[] | select(.kind == "run" and .pipeline == "review-loop")]'
  local FILTERED="$RL"' | map(select(.payload.status != "SKIPPED"))
    | map(select(.payload.promotion_phase != true))'
  local RATE=' | if length == 0 then null else ([.[] | select(.payload.status == "CONVERGED")] | length) / length end'

  local before_rate before_fp
  before_rate=$(jq -s "$FILTERED$RATE" "$T")
  before_fp=$(jq -s "$FILTERED"' | group_by([.repo, .issue, .ts]) | map(min_by(.wall_s))'"$RATE" "$T")
  [ "$before_rate" = "0.5" ]
  [ "$before_fp" = "0.5" ]

  # now the promotion sub-loop's OWN run record lands: same issue, NEW ts
  jq -nc '{status:"CONVERGED", rounds:1, max_rounds:5, promotion_phase:true,
           repo_type:"shell", round_changelists:[], final_changelist:{blocking:[]}}' > "$ST"
  zsh "$BTR" --status "$ST" > "$P"
  # strict: jq -r cannot tell the boolean true from the string "true", and the
  # documented predicate below is a strict JSON comparison
  jq -e '.promotion_phase == true' "$P" >/dev/null
  zsh "$EMIT" --pipeline review-loop --kind run --outcome success --repo-dir "$R" \
    --issue 995 --ts 1753400900 --wall-s 60 --telemetry-file "$T" --payload "$P" >/dev/null

  # the figures are UNCHANGED — that is the whole point of the predicate
  [ "$(jq -s "$FILTERED$RATE" "$T")" = "$before_rate" ]
  [ "$(jq -s "$FILTERED"' | group_by([.repo, .issue, .ts]) | map(min_by(.wall_s))'"$RATE" "$T")" = "$before_fp" ]

  # and WITHOUT the predicate they would have moved — proving the test is not
  # vacuously passing on a sink the promotion record never entered
  local UNFILTERED="$RL"' | map(select(.payload.status != "SKIPPED"))'
  [ "$(jq -s "$UNFILTERED$RATE" "$T")" != "$before_rate" ]
  [ "$(jq -s "$UNFILTERED"' | group_by([.repo, .issue, .ts]) | map(min_by(.wall_s))'"$RATE" "$T")" != "$before_fp" ]

  # the enrichment needs no predicate of its own: kind == "run" already drops it
  [ "$(jq -s "$RL"' | length' "$T")" -eq 3 ]
  [ "$(jq -s '[.[] | select(.kind == "enrichment")] | length' "$T")" -eq 1 ]
}

@test "#1033 promotion_phase is always present, and false on a status JSON that predates it" {
  # An older status file must read as a phase-1 record, never as a missing key a
  # consumer has to special-case.
  jq -nc '{status:"CONVERGED", rounds:1, max_rounds:3, repo_type:"python",
           round_changelists:[], final_changelist:{blocking:[]}}' > "$ST"
  run zsh "$BTR" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.promotion_phase == false' >/dev/null
  [ "$(jq -r 'has("promotion_phase")' <<<"$output")" = "true" ]
}

# --- #1029 happy: three of the FIVE lockstep copies agree on the count ------
# (build-dossier.zsh holds the other two reads, covered by build-dossier.bats)

@test "#1029 one changelist yields the SAME promoted count in all three surfaces" {
  # Two promoted + one reviewer-raised blocker. Each surface derives the count
  # from the per-item stamp with the identical expression, so a drift in any one
  # copy is a failing assertion rather than a silent inconsistency.
  # the test's own claim is "ONE changelist" — pin that the two fixtures it feeds
  # really are the same document, or the lockstep comparison is hollow the
  # moment either is edited alone
  [ "$(jq -S . "$FIX/changelist-promoted.json")" = "$(jq -S .final_changelist "$FIX/status-promoted.json")" ]
  local payload progress escalation
  payload=$(zsh "$BTR" --status "$FIX/status-promoted.json")
  # the fixture is a real promotion sub-loop's status, so both markers are set
  # together — promoted stamps can only exist under --promote
  echo "$payload" | jq -e '.promotion_phase == true' >/dev/null
  progress=$(zsh "$RPB" --changelist "$FIX/changelist-promoted.json" --round 2 --verdict "blockers remain")
  escalation=$(zsh "$BE" --status "$FIX/status-promoted.json" --issue 995 --format summary)

  # 1. telemetry: a SUBSET of Warning (4), never a fourth severity added to it
  [ "$(jq '.findings_by_round[1].promoted' <<<"$payload")" -eq 3 ]
  [ "$(jq '.findings_by_round[1].by_severity.Warning' <<<"$payload")" -eq 4 ]
  [ "$(jq -c '[.findings_by_round[].promoted]' <<<"$payload")" = "[3,3]" ]

  # 2. progress.md: the severity term, then one line per promoted item
  contains "$progress" "- blockers: 4 (critical: 0, warning: 4, promoted: 3)"
  [ "$(grep -c '^- promoted suggestion: ' <<<"$progress")" -eq 3 ]
  contains "$progress" '- promoted suggestion: `development/skills/resolve-issue/scripts/consolidate-findings.zsh:113` [code_quality] "LINEWIN is a magic number" — raised from Suggestion by the human at convergence; blocking until cleared'
  contains "$progress" '- promoted suggestion: `tests/consolidate-findings.bats:40` [tests] "Assertion could be stronger"'
  # a promoted blocker with NO line (the overlay promotes line-less findings, see
  # tests/promotion-overlay.bats) must render file-only in every surface — a
  # dropped `(.line | type) == "number"` guard would print `file:null`
  contains "$progress" '- promoted suggestion: `development/skills/resolve-issue/SKILL.md` [prose_logic] "the gate paragraph contradicts step 3"'
  run ! grep -q ':null' <<<"$progress"
  contains "$escalation" '`development/skills/resolve-issue/SKILL.md` [prose_logic/Warning (promoted)] the gate paragraph contradicts step 3'
  run ! grep -q ':null' <<<"$escalation"

  # the reviewer-raised blocker gets NO such line — that is the distinction
  local promoted_lines
  promoted_lines=$(grep '^- promoted suggestion: ' <<<"$progress")
  run ! grep -q 'emitter stdout is discarded' <<<"$promoted_lines"

  # 3. the escalation: the column, its cell, and the labelled bullets
  contains "$escalation" "| Round | Critical | Warning | Suggestion | Promoted | New | Carried | Fixed since prior |"
  # the separator is rendered by its OWN $anyprom ternary, and the 7-column form
  # is a PREFIX of the 8-column one — so only asserting the 8-column separator
  # catches a wrong --- count, which renders a broken table in every viewer
  contains "$escalation" "|---|---|---|---|---|---|---|---|"
  # BOTH rendered rows, so a header/body column-count mismatch on the first one
  # cannot ship green either
  contains "$escalation" "| 1 | 0 | 4 | 1 | 3 | 4 | 0 | – |"
  contains "$escalation" "| 2 | 0 | 4 | 1 | 3 | 4 | 0 | 4 |"
  contains "$escalation" "[code_quality/Warning (promoted)] LINEWIN is a magic number"
  contains "$escalation" "[tests/Warning (promoted)] Assertion could be stronger"
  # ...and the reviewer-raised one stays unlabelled
  contains "$escalation" "[bugs/Warning] emitter stdout is discarded"
}

@test "#1029 the ESCALATE_NO_CONVERGENCE branch labels promoted blockers too" {
  # build-escalation renders the (promoted) suffix in TWO independent detail
  # branches. BUDGET_EXHAUSTED lists every blocker; this one additionally
  # filters on select(.non_converging), so nothing above proves a promoted,
  # carried blocker reaches the Details list at all — and this is the DOMINANT
  # terminal status for a promotion pass (a promoted item the fix pass cannot
  # clear survives two rounds and escalates exactly here).
  run zsh "$BE" --status "$FIX/status-promoted-noconv.json" --issue 995 --format summary
  [ "$status" -eq 0 ]
  contains "$output" "ESCALATE_NO_CONVERGENCE"
  contains "$output" "[code_quality/Warning (promoted)] LINEWIN is a magic number"
  contains "$output" "[tests/Warning (promoted)] Assertion could be stronger"
  contains "$output" "[bugs/Warning] emitter stdout is discarded"
  contains "$output" "| Round | Critical | Warning | Suggestion | Promoted | New | Carried | Fixed since prior |"
  contains "$output" "|---|---|---|---|---|---|---|---|"
  # cells too, not just the header — a per-row regression on THIS branch would
  # otherwise render a column with no matching cell and stay green
  contains "$output" "| 1 | 0 | 3 | 1 | 2 | 3 | 0 | – |"
  # the comment render carries it too — byte-exactly, so every unstamped golden
  # now has a stamped counterpart and a grown column cannot hide behind
  # substring needles on any of the five renders
  run zsh "$BE" --status "$FIX/status-promoted-noconv.json" --issue 995
  [ "$status" -eq 0 ]
  contains "$output" "[code_quality/Warning (promoted)] LINEWIN is a magic number"
  zsh "$BE" --status "$FIX/status-promoted-noconv.json" --issue 995 \
    > "$BATS_TEST_TMPDIR/noconv-comment.md"
  cmp "$FIX/golden-escalation-noconv-comment-promoted.md" "$BATS_TEST_TMPDIR/noconv-comment.md"
}

@test "#1032 the ESCALATE_NO_CONVERGENCE branch is byte-identical without the stamps" {
  # the no-promote identity claim must hold on BOTH detail branches, not just
  # the one the other byte-identity test happens to exercise
  zsh "$BE" --status "$FIX/status-unstamped-noconv.json" --issue 995 > "$BATS_TEST_TMPDIR/esc-noconv.md"
  cmp "$FIX/golden-escalation-noconv-unstamped.md" "$BATS_TEST_TMPDIR/esc-noconv.md"
  run ! grep -qi 'promoted' "$BATS_TEST_TMPDIR/esc-noconv.md"
  # the summary is a SEPARATE assembly from the comment — and it is what the
  # interactive grant prompt shows the human, so it needs its own golden
  zsh "$BE" --status "$FIX/status-unstamped-noconv.json" --format summary > "$BATS_TEST_TMPDIR/esc-noconv-summary.md"
  cmp "$FIX/golden-escalation-noconv-summary-unstamped.md" "$BATS_TEST_TMPDIR/esc-noconv-summary.md"
  run ! grep -qi 'promoted' "$BATS_TEST_TMPDIR/esc-noconv-summary.md"
}

@test "#1029 the Promoted column is table-WIDE: a round with none still renders its 0 cell" {
  # $anyprom is computed over ALL rounds precisely so the column cannot be
  # present in one row and absent in another. With a promotion in round 1 only
  # (the item was fixed), a per-row regression would emit a ragged table — and
  # every row's column count is asserted here, not just the last one's.
  run zsh "$BE" --status "$FIX/status-promoted-mixed.json" --format summary
  [ "$status" -eq 0 ]
  contains "$output" "| Round | Critical | Warning | Suggestion | Promoted | New | Carried | Fixed since prior |"
  contains "$output" "|---|---|---|---|---|---|---|---|"
  contains "$output" "| 1 | 0 | 3 | 1 | 2 | 3 | 0 | – |"
  contains "$output" "| 2 | 0 | 1 | 1 | 0 | 1 | 0 | 3 |"
  # every body row has the same cell count as the header (8 columns -> 9 pipes)
  local row
  while IFS= read -r row; do
    [ "$(printf '%s' "$row" | tr -cd '|' | wc -c)" -eq 9 ] \
      || { echo "ragged table row: $row"; return 1; }
  done < <(printf '%s\n' "$output" | grep -E '^\| [0-9]+ \|')
}

@test "#1029 every promoted render is pinned EXACTLY, not just by substrings" {
  # `contains` is a substring test, so a render that GREW a column (header,
  # separator and rows alike) or appended a term to the blockers line satisfies
  # every needle in the tests above. The no-promote path is anchored by five
  # byte-identical goldens; the stamped path needs the same, and each of these
  # four renders is assembled by different code:
  #   - progress.md            render-progress-block.zsh
  #   - BUDGET_EXHAUSTED summary / comment   build-escalation.zsh, two assemblies
  #   - ESCALATE_NO_CONVERGENCE summary      its own detail jq program
  zsh "$RPB" --changelist "$FIX/changelist-promoted.json" --round 2 --verdict "blockers remain" \
    | sed -E 's/\([0-9]{2}:[0-9]{2}:[0-9]{2}\)/(TS)/' > "$BATS_TEST_TMPDIR/promoted-progress.md"
  cmp "$FIX/golden-progress-promoted.md" "$BATS_TEST_TMPDIR/promoted-progress.md"

  zsh "$BE" --status "$FIX/status-promoted.json" --issue 995 > "$BATS_TEST_TMPDIR/promoted-comment.md"
  cmp "$FIX/golden-escalation-promoted.md" "$BATS_TEST_TMPDIR/promoted-comment.md"

  zsh "$BE" --status "$FIX/status-promoted-noconv.json" --format summary \
    > "$BATS_TEST_TMPDIR/promoted-noconv-summary.md"
  cmp "$FIX/golden-escalation-noconv-summary-promoted.md" "$BATS_TEST_TMPDIR/promoted-noconv-summary.md"
}

@test "#1029 the BUDGET_EXHAUSTED promoted summary is pinned EXACTLY" {
  # every other promoted assertion is `contains`, which a render that grew an
  # extra column would still satisfy — header, separator and rows alike. The
  # no-promote path has five byte-identical goldens; the promoted path needs at
  # least one, or column-count regressions are invisible in that direction.
  zsh "$BE" --status "$FIX/status-promoted.json" --format summary > "$BATS_TEST_TMPDIR/promoted-summary.md"
  cmp "$FIX/golden-escalation-summary-promoted.md" "$BATS_TEST_TMPDIR/promoted-summary.md"
}

@test "#1029 the Promoted column is UNGATED: a stamp-less round still counts, while New/Carried degrade" {
  # The escalation twin of the render-progress-block stamp-less test. New /
  # Carried / Fixed need the #913 per-item stamp and honestly degrade to "–"
  # without it; Promoted deliberately does not, so a regression that gated it
  # like its neighbours would silently report 0 promoted on any pre-#913
  # changelist. Asserting both halves in one row is what separates the two
  # behaviours.
  run zsh "$BE" --status "$FIX/status-promoted-mixed-unstamped.json" --format summary
  [ "$status" -eq 0 ]
  contains "$output" "| 1 | 0 | 3 | 1 | 2 | – | – | – |"
  # ...and the payload's per-round count agrees on the same stamp-less round
  run zsh "$BTR" --status "$FIX/status-promoted-mixed-unstamped.json"
  [ "$status" -eq 0 ]
  [ "$(jq '.findings_by_round[0].promoted' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.findings_by_round[0].carried' <<<"$output")" = "null" ]
}

@test "#1029 the escalation COMMENT carries the same labelling as the summary" {
  # the summary and the comment are separate renders of the same extraction; a
  # label added to only one of them is exactly the drift this pins
  run zsh "$BE" --status "$FIX/status-promoted.json" --issue 995
  [ "$status" -eq 0 ]
  contains "$output" "| Round | Critical | Warning | Suggestion | Promoted | New | Carried | Fixed since prior |"
  contains "$output" "|---|---|---|---|---|---|---|---|"
  contains "$output" "| 2 | 0 | 4 | 1 | 3 | 4 | 0 | 4 |"
  contains "$output" "[code_quality/Warning (promoted)] LINEWIN is a magic number"
}

# --- #1032 corner: without --promote, nothing changes ----------------------

@test "#1032 an unstamped changelist renders byte-identically to the pre-change goldens" {
  # The goldens were generated from the scripts as they stood BEFORE this story
  # (origin/main at the time) and are committed, so they cannot drift into
  # comparing the new implementation against itself.
  local got="$BATS_TEST_TMPDIR/progress.md"
  zsh "$RPB" --changelist "$FIX/changelist-unstamped.json" --round 2 --verdict "blockers remain" \
    | sed -E 's/\([0-9]{2}:[0-9]{2}:[0-9]{2}\)/(TS)/' > "$got"
  cmp "$FIX/golden-progress-unstamped.md" "$got"

  zsh "$BE" --status "$FIX/status-unstamped.json" --issue 995 > "$BATS_TEST_TMPDIR/esc.md"
  cmp "$FIX/golden-escalation-unstamped.md" "$BATS_TEST_TMPDIR/esc.md"

  zsh "$BE" --status "$FIX/status-unstamped.json" --format summary > "$BATS_TEST_TMPDIR/esc-summary.md"
  cmp "$FIX/golden-escalation-summary-unstamped.md" "$BATS_TEST_TMPDIR/esc-summary.md"

  # no promoted term ANYWHERE, in either case — the header included
  run ! grep -qi 'promoted' "$got"
  run ! grep -qi 'promoted' "$BATS_TEST_TMPDIR/esc.md"
  run ! grep -qi 'promoted' "$BATS_TEST_TMPDIR/esc-summary.md"
}

@test "#1032 an unstamped changelist counts 0 promoted in the payload (no stamp gate)" {
  # The payload legitimately GAINS the key (it is additive), so byte-identity is
  # the two RENDERED artefacts' criterion; here the criterion is that an absent
  # flag counts 0 rather than null — no stamped-round gate, the #983 precedent.
  run zsh "$BTR" --status "$FIX/status-unstamped.json"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.findings_by_round[].promoted]' <<<"$output")" = "[0,0]" ]
  echo "$output" | jq -e '.promotion_phase == false' >/dev/null
  # the Warning counts are untouched — promoted is a subset, not an addend
  [ "$(jq -c '[.findings_by_round[].by_severity.Warning]' <<<"$output")" = "[3,3]" ]
}
