#!/usr/bin/env bats
#
# Behavioral tests for dependency-precheck.zsh (#585): the single-issue
# dependency gate of /development:resolve-issue (epic #583). What these tests
# pin down is the typed decision contract on top of the shared reader (#584):
# PROCEED (0) only when no open blockers exist, REJECT_BLOCKED (10) naming
# every open blocker in the argumentation, REJECT_CYCLE (11) winning over
# blockers (a cycle can never be satisfied, so "resolve these first" would be
# a lie), and a machine-findable marker on every rejection comment.
#
# The reader is stubbed via the DEPS_BIN seam: the stub emits $DEPS_JSON with
# exit $DEPS_STATUS and records its argv, so the graph under test is fully
# deterministic and needs no gh/network.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/dependency-precheck.zsh"

  DEPS_ARGS_FILE="$BATS_TEST_TMPDIR/deps-args"
  STUB="$BATS_TEST_TMPDIR/deps-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
# record argv ONE ELEMENT PER LINE, plus the count. "$*" joins with spaces, so
# an extra EMPTY word renders identically to none — and the reader's arg loop
# would die on it with "unknown argument: " at exit 2. That is a live risk here:
# the `${max_depth:+--max-depth} ${max_depth:+$max_depth}` idiom invites a
# "quoting fix" that passes two empty words on every default invocation.
printf '%s\n' "$@" > "$DEPS_ARGS_FILE"
printf 'argc=%s\n' "$#" >> "$DEPS_ARGS_FILE"
echo "$DEPS_JSON"
exit "${DEPS_STATUS:-0}"
EOF
  chmod +x "$STUB"
}

precheck() {  # $1 = reader result JSON ; rest = extra flags
  local json="$1"; shift
  run env DEPS_BIN="$STUB" DEPS_JSON="$json" DEPS_ARGS_FILE="$DEPS_ARGS_FILE" \
    zsh "$S" --repo owner/repo --issue 50 "$@"
}

# ---- usage errors -----------------------------------------------------------

@test "the gate is executable and runs by BARE PATH, with the DEFAULT reader wiring" {
  # every other test runs `zsh "$S"` with DEPS_BIN overridden, so two things
  # ship untested: the shebang + mode bit (the skill invokes this bare-path, so
  # a lost 755 makes step 0a die "permission denied" for every issue), and the
  # `${DEPS_BIN:-<self_dir>/read-dependencies.zsh}` default (a script move or a
  # ${0:A:h} refactor makes every production run die exit 1 "reader failed"
  # while the suite stays green). Stub the READER's own gh seam instead, so the
  # whole chain — bare-path exec, default reader path, forwarded argv, the
  # seven-key contract — runs for real.
  [ -x "$S" ]
  local fixtures="$BATS_TEST_TMPDIR/gfix"
  mkdir -p "$fixtures"
  local ghstub="$BATS_TEST_TMPDIR/gh.sh"
  cat > "$ghstub" <<'EOF'
#!/usr/bin/env bash
prev="" num=""
for a in "$@"; do
  if [ "$prev" = "-F" ]; then case "$a" in number=*) num="${a#number=}" ;; esac; fi
  prev="$a"
done
f="$FIXTURE_DIR/issue-$num.json"
if [ -f "$f" ]; then cat "$f"; else echo '{"data":{"repository":{"issue":null}}}'; fi
EOF
  chmod +x "$ghstub"
  _mkfix() {  # $1 = number, $2 = state, $3 = blockers json
    jq -n --argjson num "$1" --arg state "$2" --argjson b "$3" \
      '{data:{repository:{issue:{
          number:$num, state:$state, body:"", trackedIssuesCount:0,
          subIssuesSummary:{total:0}, labels:{nodes:[]},
          blockedBy:{nodes:($b|map({number:., state:"OPEN",
            repository:{nameWithOwner:"owner/repo"}}))}}}}}' \
      > "$fixtures/issue-$1.json"
  }
  _mkfix 50 OPEN '[11]'
  _mkfix 11 OPEN '[]'
  run env GH_BIN="$ghstub" FIXTURE_DIR="$fixtures" "$S" --repo owner/repo --issue 50
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_BLOCKED" ]
  [ "$(echo "$output" | jq -c '[.open_blockers, .foreign_blockers, .truncated, .reader_blocked]')" \
    = '[[11],[],false,true]' ]
}

@test "usage: missing --repo exits 2" {
  run zsh "$S" --issue 5
  [ "$status" -eq 2 ]
  # assert the MESSAGE, not just the code: several guards exit 2, so a status
  # check alone cannot tell a dropped guard from a later one catching the fall
  contains "$output" "--repo OWNER/NAME is required"
}

@test "usage: missing --issue exits 2" {
  run zsh "$S" --repo owner/repo
  [ "$status" -eq 2 ]
  contains "$output" "--issue N is required"
}

@test "usage: a dangling value flag exits 2, not a nounset abort" {
  # without the arity guard, $2 is unset under `nounset` and zsh dies with a
  # raw "2: parameter not set" at exit 1 — the code this script documents as
  # "the reader failed", so a malformed invocation reads as a broken reader
  run zsh "$S" --issue 50 --repo
  [ "$status" -eq 2 ]
  contains "$output" "--repo needs a value"
  run zsh "$S" --repo owner/repo --issue
  [ "$status" -eq 2 ]
  contains "$output" "--issue needs a value"
  run zsh "$S" --repo owner/repo --issue 50 --max-depth
  [ "$status" -eq 2 ]
  contains "$output" "--max-depth needs a value"
}

@test "usage: --help prints the usage line and exits 0" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: dependency-precheck.zsh"
}

@test "usage: an unknown argument exits 2 rather than being ignored" {
  # a typo'd flag being silently ignored is how --max-depth stops applying
  run zsh "$S" --repo owner/repo --issue 50 --max_depth 2
  [ "$status" -eq 2 ]
  contains "$output" "unknown argument: --max_depth"
}

# ---- PROCEED ----------------------------------------------------------------

@test "no blockers at all -> PROCEED, exit 0, no comment" {
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .decision)" = "PROCEED" ]
  [ "$(echo "$output" | jq -r .comment_md)" = "null" ]
  # the passthrough on the PROCEED side too: an emitter that filtered these to
  # empty would look identical here and wrong on every rejection
  # `truncated` on its FALSE side too: the emitter used to default it with
  # `// false`, and `false // true` is `true` — so flipping that default would
  # mark every ordinary run truncated, and the skill keys its shape (i)/(ii)
  # split and its withhold rule on exactly this field
  [ "$(echo "$output" | jq -c '[.issue, .open_blockers, .blockers, .cycles, .truncated, .reader_blocked]')" = '[50,[],[],[],false,false]' ]
}

@test "closed-only blockers -> PROCEED (a met prerequisite doesn't block)" {
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[{"number":9,"state":"CLOSED","open":false,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .decision)" = "PROCEED" ]
  # a CLOSED blocker still reaches the document: narrowing the emit to the open
  # ones is the plausible "the consumer only needs those" simplification, and it
  # would lose the record that a prerequisite was already met
  [ "$(echo "$output" | jq -c '[.open_blockers, .blockers]')" \
    = '[[],[{"number":9,"state":"CLOSED","open":false,"kind":"issue","depth":1}]]' ]
}

# ---- REJECT_BLOCKED ---------------------------------------------------------

@test "open blockers -> REJECT_BLOCKED, exit 10" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11],"blockers":[{"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_BLOCKED" ]
  # the PASSTHROUGH, whole. These four keys come from one jq shorthand object,
  # and the skill calls that document "the named source for every array" its
  # remediation reads (blockers[].kind and .depth drive the epic confirmation
  # #1260 exists to enable). The comment assertions are no cover — the comment
  # renders from the reader's document directly, not from this one — so a
  # dropped, misnamed or filtered key ships green and the remediation reads
  # null for the array it was told is authoritative.
  [ "$(echo "$output" | jq -c '[.issue, .open_blockers, .blockers, .cycles, .truncated]')" \
    = '[50,[11],[{"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1}],[],false]' ]
}

@test "the blocked argumentation names every open blocker, not the closed ones" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11,13],"blockers":[
    {"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1},
    {"number":12,"state":"CLOSED","open":false,"kind":"issue","depth":1},
    {"number":13,"state":"OPEN","open":true,"kind":"issue","depth":2}],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  comment="$(echo "$output" | jq -r .comment_md)"
  contains "$comment" "#11"
  contains "$comment" "#13"
  lacks "$comment" "#12"
}

@test "an epic blocker is called out as an epic in the argumentation" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[20],"blockers":[{"number":20,"state":"OPEN","open":true,"kind":"epic","depth":1}],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  contains "$(echo "$output" | jq -r .comment_md)" "**epic**"
}

@test "the blocked comment carries the machine-findable marker and a re-run hint" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11],"blockers":[{"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[],"truncated":false}'
  comment="$(echo "$output" | jq -r .comment_md)"
  contains "$comment" "<!-- dependency-precheck: REJECT_BLOCKED -->"
  contains "$comment" "/development:resolve-issue 11"
  contains "$comment" "/development:resolve-issue 50"
}

@test "a truncated traversal adds the incompleteness caution" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11],"blockers":[{"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[],"truncated":true}'
  contains "$(echo "$output" | jq -r .comment_md)" "may be incomplete"
}

# ---- fail-closed on what could not be checked --------------------------------

@test "a TRUNCATED traversal rejects rather than PROCEEDing on an empty finding set" {
  # NB the stock reader cannot produce this shape: truncation only fires while
  # expanding an OPEN blocker, which is therefore already recorded, so
  # open_blockers is non-empty and the earlier rule wins. This is the DEPS_BIN
  # double the script header points at — it pins the fail-closed default for a
  # non-conforming or future reader. Empty arrays after a cap are evidence of
  # not having LOOKED, not of no blockers, so PROCEED would be the gate saying
  # "ready" about a graph it never read.
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":true}'
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_BLOCKED" ]
  [ "$(echo "$output" | jq -r .truncated)" = "true" ]
  # with nothing enumerated, the comment must not claim to list open blockers
  contains "$(echo "$output" | jq -r .comment_md)" "No blocker could be enumerated"
  contains "$(echo "$output" | jq -r .comment_md)" "depth cap"
}

@test "a missing jq is a named exit 1, never a PROCEED" {
  # every decision predicate is a jq call. Without the guard they all produce
  # empty output, each (( )) test errors, control falls through the whole
  # chain, and the gate answers PROCEED — a fail-OPEN gate is worthless.
  mkdir -p "$BATS_TEST_TMPDIR/nobin"
  run env PATH="$BATS_TEST_TMPDIR/nobin" DEPS_BIN="$STUB" \
    DEPS_JSON='{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":false}' \
    DEPS_ARGS_FILE="$DEPS_ARGS_FILE" "$(command -v zsh)" "$S" --repo owner/repo --issue 50
  [ "$status" -eq 1 ]
  contains "$output" "jq not found on PATH"
  lacks "$output" '"decision"'
}

@test "an unreadable reader document is a named exit 1, never a PROCEED" {
  # a DEPS_BIN that exits 0 with a truncated or non-JSON payload must not read
  # as "no findings": the counts call fails, and the gate refuses.
  precheck 'not json at all'
  [ "$status" -eq 1 ]
  contains "$output" "unreadable reader document"
  lacks "$output" '"decision"'
}

@test "a WELL-FORMED document that is not the reader contract is exit 1, never a PROCEED" {
  # the subtle half: `.cycles | length` on a MISSING key is 0, not an error, so
  # a renamed field would make every count read zero and the gate PROCEED on an
  # issue with a cycle. Only asserting the shape catches it.
  precheck '{"issue":50,"blocked":true,"cycle_paths":[[1,2,1]]}'
  [ "$status" -eq 1 ]
  contains "$output" "unreadable reader document"
  lacks "$output" '"decision"'
}

@test "a bare null from the reader is exit 1, never a PROCEED" {
  # null | .cycles | length is also 0 — empty stdout is not the only way a
  # reader can say nothing useful
  precheck 'null'
  [ "$status" -eq 1 ]
  contains "$output" "unreadable reader document"
  lacks "$output" '"decision"'
}

@test "a rejection listing only CLOSED blockers renders the no-rung wording" {
  # the shape the skill must NOT read as "blockers were enumerated": the
  # comment builds its list with select(.open), so a closed-only document says
  # "No blocker could be enumerated" — while a non-emptiness test would call it
  # shape (i) and send the model into a remediation whose question must name
  # the open blockers with none to name, and whose chain has no rungs.
  precheck '{"issue":50,"blocked":true,"open_blockers":[],"blockers":[{"number":9,"state":"CLOSED","open":false,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  contains "$(echo "$output" | jq -r .comment_md)" "No blocker could be enumerated"
  # the closed record still reaches the document, so the human can see it
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[9]' ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[]' ]
}

@test "the reader's own blocked verdict rejects even when no count names a reason" {
  # the shared reader publishes one fail-closed verdict so the judgment cannot
  # drift between consumers. If it ever sets blocked for a fifth reason, this
  # gate must reject by default rather than PROCEED on a reason it cannot name.
  precheck '{"issue":50,"blocked":true,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_BLOCKED" ]
  # reader_blocked is what lets the skill tell shape (ii)'s two sub-causes
  # apart; unpinned, projecting the wrong field would leave the model unable to
  # name the cause on the one rejection whose point is that it has no rungs
  [ "$(echo "$output" | jq -c '[.truncated, .reader_blocked]')" = '[false,true]' ]
  # the comment must NOT blame the depth cap: it did not fire, the same
  # document says truncated false, and this text posts verbatim to the issue —
  # sending the human to raise --max-depth for a rejection it would not clear
  contains "$(echo "$output" | jq -r .comment_md)" "a reason this gate cannot name"
  lacks "$(echo "$output" | jq -r .comment_md)" "depth cap"
}

@test "usage: an EMPTY --max-depth value is a usage error, not a silent default" {
  # the conditional forwarding drops an empty value entirely, so the caller's
  # explicit cap would vanish into the reader's default with no diagnostic
  run zsh "$S" --repo owner/repo --issue 50 --max-depth ''
  [ "$status" -eq 2 ]
  contains "$output" "--max-depth must be a positive number"
  run zsh "$S" --repo owner/repo --issue 50 --max-depth abc
  [ "$status" -eq 2 ]
  contains "$output" "--max-depth must be a positive number"
}

@test "the depth-cap comment does not also claim the list above may be incomplete" {
  # both truncation strings used to render together, so the comment said
  # nothing could be enumerated and then referred to the list it had just said
  # does not exist — posted verbatim to a GitHub issue, that reads as a bug
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":true}'
  [ "$status" -eq 10 ]
  contains "$(echo "$output" | jq -r .comment_md)" "No blocker could be enumerated"
  lacks "$(echo "$output" | jq -r .comment_md)" "list above may be incomplete"
}

@test "a truncated walk that DID enumerate blockers keeps the incompleteness caution" {
  # the other side: with a list present the caution is exactly right, and
  # suppressing it would hide that the list is a floor
  precheck '{"issue":50,"blocked":true,"open_blockers":[11],"blockers":[{"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[],"truncated":true}'
  [ "$status" -eq 10 ]
  contains "$(echo "$output" | jq -r .comment_md)" "list above may be incomplete"
  lacks "$(echo "$output" | jq -r .comment_md)" "No blocker could be enumerated"
}

@test "the reader's USAGE exit 2 is re-raised, not laundered into the internal-error 1" {
  # exit 1 is documented here as "the reader failed", so collapsing a malformed
  # argument into it tells the caller to retry when it must fix the call
  run env DEPS_BIN="$STUB" DEPS_JSON='' DEPS_STATUS=2 DEPS_ARGS_FILE="$DEPS_ARGS_FILE" \
    zsh "$S" --repo owner/repo --issue 50
  [ "$status" -eq 2 ]
  run env DEPS_BIN="$STUB" DEPS_JSON='' DEPS_STATUS=1 DEPS_ARGS_FILE="$DEPS_ARGS_FILE" \
    zsh "$S" --repo owner/repo --issue 50
  [ "$status" -eq 1 ]
}

@test "the re-run hint names the DEEPEST open blocker, not the first discovered" {
  # open_blockers is in DFS discovery order, so element 0 is a direct blocker —
  # which this same gate rejects if it is itself blocked, costing a wasted
  # round on a comment posted verbatim to the issue. The skill rule is
  # deepest-first, and the comment must agree with it.
  precheck '{"issue":50,"blocked":true,"open_blockers":[586,587],"blockers":[{"number":586,"state":"OPEN","open":true,"kind":"issue","depth":1},{"number":587,"state":"OPEN","open":true,"kind":"issue","depth":2}],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  contains "$(echo "$output" | jq -r .comment_md)" "resolve-issue 587"
  lacks "$(echo "$output" | jq -r .comment_md)" "resolve-issue 586"
}

# ---- cross-repo blockers ----------------------------------------------------

@test "an OPEN cross-repo blocker rejects, even with no same-repo blocker" {
  # the reader cannot traverse another repository, so a foreign blocker never
  # reaches open_blockers. Deciding on that field alone would PROCEED on an
  # issue the reader itself reported blocked:true — a gate saying "ready" about
  # a prerequisite it could not check, the one wrong answer it must never give.
  precheck '{"issue":50,"blocked":true,"open_blockers":[],"blockers":[],"foreign_blockers":[{"ref":"other/elsewhere#7","open":true}],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_BLOCKED" ]
  # the comment names the REF — a bare number is meaningless in another repo
  contains "$(echo "$output" | jq -r .comment_md)" "other/elsewhere#7"
  contains "$(echo "$output" | jq -r .comment_md)" "another repository"
  # with no same-repo blocker there is nothing to suggest resolving first, and
  # the old wording indexed open_blockers[0] unconditionally — which would have
  # rendered a literal "null" into the instruction a human follows
  lacks "$(echo "$output" | jq -r .comment_md)" "resolve-issue null"
  contains "$(echo "$output" | jq -r .comment_md)" "<!-- dependency-precheck: REJECT_BLOCKED -->"
  [ "$(echo "$output" | jq -c .foreign_blockers)" = '[{"ref":"other/elsewhere#7","open":true}]' ]
}

@test "a CLOSED cross-repo blocker alone still PROCEEDs" {
  # the other side: a met cross-repo prerequisite must not wedge the gate shut.
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[{"ref":"other/elsewhere#7","open":false}],"cycles":[],"truncated":false}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .decision)" = "PROCEED" ]
  [ "$(echo "$output" | jq -c .foreign_blockers)" = '[{"ref":"other/elsewhere#7","open":false}]' ]
}

@test "same-repo and cross-repo blockers are BOTH listed in the argumentation" {
  # a mixed graph must not lose either kind: the human is told to resolve the
  # same-repo one, and the foreign one is still visible as a prerequisite.
  precheck '{"issue":50,"blocked":true,"open_blockers":[9],"blockers":[{"number":9,"state":"OPEN","open":true,"kind":"issue","depth":1}],"foreign_blockers":[{"ref":"other/elsewhere#7","open":true},{"ref":"third/one#2","open":false}],"cycles":[],"truncated":false}'
  [ "$status" -eq 10 ]
  contains "$(echo "$output" | jq -r .comment_md)" "#9"
  contains "$(echo "$output" | jq -r .comment_md)" "other/elsewhere#7"
  # the CLOSED foreign one is not presented as something to resolve
  lacks "$(echo "$output" | jq -r .comment_md)" "third/one#2"
  contains "$(echo "$output" | jq -r .comment_md)" "resolve-issue 9"
}

@test "a reader document MISSING a fail-closed key is exit 1, never a PROCEED" {
  # foreign_blockers / truncated / blocked are the fields whose `//` default is
  # the PERMISSIVE value, so defaulting them away is exactly the hole the shape
  # assertion exists to close: a reader that renamed one would otherwise have
  # its cross-repo blockers and its un-walked graph read as "nothing found".
  # The two ship together in one plugin, so a missing key is a broken install,
  # not a version skew to tolerate.
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 1 ]
  contains "$output" "unreadable reader document"
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[]}'
  [ "$status" -eq 1 ]
  precheck '{"issue":50,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 1 ]
}

@test "a per-element open flag that is missing or null is exit 1, never a PROCEED" {
  # the top-level type check is not enough: every consumer reads `.open`
  # through select(), which silently DROPS an element whose open is missing or
  # null — the permissive direction. A foreign blocker lacking it makes all
  # five counts zero and the gate PROCEEDs on an unverifiable cross-repo
  # prerequisite, the one wrong answer the fail-closed rule exists to prevent.
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[{"ref":"o/r#5"}],"cycles":[],"truncated":false}'
  [ "$status" -eq 1 ]
  contains "$output" "wrong field types"
  lacks "$output" '"decision"'
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[{"number":9,"state":"OPEN","open":null,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 1 ]
  contains "$output" "wrong field types"
}

@test "a non-array cycles element is exit 1, not a decided cycle lost to a render crash" {
  # .cycles drives the exit-11 decision AND is iterated by the renderer. A
  # string element passes a top-level array check, the gate correctly decides
  # REJECT_CYCLE, and then the renderer aborts — so the run exits 1 ("the
  # reader failed", i.e. retry) for a document it had already classified, and
  # the typed escalation plus its comment are lost.
  precheck '{"issue":50,"blocked":true,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":["50 -> 7 -> 50"],"truncated":false}'
  [ "$status" -eq 1 ]
  contains "$output" "wrong field types"
  lacks "$output" '"decision"'
}

@test "a blocker whose kind is neither epic nor issue is exit 1" {
  # the comment renders epic-vs-issue from this field and posts it verbatim;
  # the distinction is what tells the human whether to decompose or implement,
  # so a null or mis-cased kind silently mislabels an epic as an ordinary issue
  precheck '{"issue":50,"blocked":true,"open_blockers":[9],"blockers":[{"number":9,"state":"OPEN","open":true,"kind":"Epic","depth":1}],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 1 ]
  contains "$output" "wrong field types"
}

@test "TWO distinct cycles are both named in the argumentation" {
  # the outer join is only exercised with more than one element here. Narrowing
  # the renderer to the head keeps the verdict and exit code right, but the
  # human breaks the one cycle named, re-runs, and is rejected again by the one
  # the comment never mentioned.
  precheck '{"issue":50,"blocked":true,"open_blockers":[20,30],"blockers":[{"number":20,"state":"OPEN","open":true,"kind":"issue","depth":1},{"number":30,"state":"OPEN","open":true,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[[50,20,50],[50,30,50]],"truncated":false}'
  [ "$status" -eq 11 ]
  contains "$(echo "$output" | jq -r .comment_md)" "#50 → #20 → #50"
  contains "$(echo "$output" | jq -r .comment_md)" "#50 → #30 → #50"
  [ "$(echo "$output" | jq -c .cycles)" = '[[50,20,50],[50,30,50]]' ]
}

@test "a document that disagrees with itself about the open blockers is exit 1" {
  # the decision reads open_blockers while the comment renders from blockers.
  # A divergent document would reject correctly and then post "No blocker could
  # be enumerated" over a document that names #5 — sending the human to
  # investigate an unnameable cause for a fully nameable rejection.
  precheck '{"issue":50,"blocked":true,"open_blockers":[5],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 1 ]
  contains "$output" "disagrees with itself"
  lacks "$output" '"decision"'
}

@test "a key present but NULL is exit 1, never a PROCEED" {
  # has() is satisfied by a null value and null|length is 0, so the key check
  # alone would still read as no findings
  precheck '{"issue":50,"blocked":false,"open_blockers":null,"blockers":null,"foreign_blockers":null,"cycles":null,"truncated":false}'
  [ "$status" -eq 1 ]
  contains "$output" "unreadable reader document"
  lacks "$output" '"decision"'
}

# ---- REJECT_CYCLE -----------------------------------------------------------

@test "a cycle -> REJECT_CYCLE, exit 11, comment names the cycle path" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[21],"blockers":[{"number":21,"state":"OPEN","open":true,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[[50,21,50]],"truncated":false}'
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_CYCLE" ]
  comment="$(echo "$output" | jq -r .comment_md)"
  contains "$comment" "#50 → #21 → #50"
  contains "$comment" "<!-- dependency-precheck: REJECT_CYCLE -->"
  # cycles are passed through in the DOCUMENT too, not only rendered into the
  # comment — the comment renders from the reader's output, so it is no cover
  [ "$(echo "$output" | jq -c .cycles)" = '[[50,21,50]]' ]
}

@test "cycle wins over open blockers (both present -> REJECT_CYCLE)" {
  precheck '{"issue":50,"blocked":true,"open_blockers":[11,21],"blockers":[
    {"number":11,"state":"OPEN","open":true,"kind":"issue","depth":1},
    {"number":21,"state":"OPEN","open":true,"kind":"issue","depth":1}],"foreign_blockers":[],"cycles":[[50,21,50]],"truncated":false}'
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r .decision)" = "REJECT_CYCLE" ]
}

# ---- plumbing ---------------------------------------------------------------

@test "reader failure propagates as internal error (exit 1)" {
  DEPS_STATUS=1
  run env DEPS_BIN="$STUB" DEPS_JSON='' DEPS_STATUS=1 DEPS_ARGS_FILE="$DEPS_ARGS_FILE" \
    zsh "$S" --repo owner/repo --issue 50
  [ "$status" -eq 1 ]
}

@test "--max-depth is forwarded to the reader as TWO separate words" {
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":false}' --max-depth 3
  [ "$status" -eq 0 ]
  # exact argv, not a substring of a joined line: collapsing the flag and its
  # value into one word renders identically when joined, but the reader then
  # sees one bogus argument and exits 2 on every --max-depth run
  [ "$(cat "$DEPS_ARGS_FILE")" = "$(printf '%s\n' --repo owner/repo --issue 50 --max-depth 3 argc=6)" ]
}

@test "repo and issue are forwarded with NO extra empty word" {
  precheck '{"issue":50,"blocked":false,"open_blockers":[],"blockers":[],"foreign_blockers":[],"cycles":[],"truncated":false}'
  [ "$status" -eq 0 ]
  # argc is the load-bearing half: with no --max-depth given, a "quoting fix"
  # to the conditional expansion passes two EMPTY words, the reader's arg loop
  # dies on "unknown argument: " at exit 2, and every default invocation in
  # production fails — while a space-joined recording looks unchanged
  [ "$(cat "$DEPS_ARGS_FILE")" = "$(printf '%s\n' --repo owner/repo --issue 50 argc=4)" ]
}
