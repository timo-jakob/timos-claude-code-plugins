#!/usr/bin/env bats
#
# Behavioral tests for read-dependencies.zsh (#584): the shared reader for
# GitHub-native issue dependencies (epic #583). Every dependency consumer —
# the readiness gate, the single-issue precheck (#585), the epic recursion
# (#587) — reads through this helper, so what these tests pin down is the
# contract: transitive traversal over `blockedBy`, open/closed + epic/issue
# classification, explicit cycle reporting, and no recursion into CLOSED
# blockers (a met prerequisite's history can't block anything).
#
# gh is stubbed via the GH_BIN seam: the stub extracts the `-F number=N`
# argument and serves a canned raw GraphQL response per issue number, so the
# graph shape under test is fully deterministic and needs no network.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/read-dependencies.zsh"

  FIXTURE_DIR="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FIXTURE_DIR"

  # Fake gh: serves $FIXTURE_DIR/issue-<N>.json for `-F number=<N>`; an issue
  # with no fixture resolves to null (exactly what the API returns for a
  # nonexistent issue). GH_FAIL_ON=<N> makes the call for issue N fail the way
  # a real gh does (nonzero exit, message on stderr) — the seam that lets the
  # transport-failure branch be tested at all.
  STUB="$BATS_TEST_TMPDIR/gh-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
prev="" num="" owner="" name="" query=""
for a in "$@"; do
  if [ "$prev" = "-F" ]; then case "$a" in number=*) num="${a#number=}" ;; esac; fi
  if [ "$prev" = "-f" ]; then
    case "$a" in
      owner=*) owner="${a#owner=}" ;;
      name=*) name="${a#name=}" ;;
      query=*) query="${a#query=}" ;;
    esac
  fi
  prev="$a"
done
if [ -n "${GH_FAIL_ON:-}" ] && [ "$num" = "$GH_FAIL_ON" ]; then
  echo "API rate limit exceeded" >&2
  exit 1
fi
# serve fixtures only for the repository the caller actually named; any other
# owner/name pair gets what the API returns for an unknown repo. This is what
# pins the --repo splice: transposing owner and name, or passing the raw slug
# as either, turns every fetch into "issue not found".
if [ "$owner" != "owner" ] || [ "$name" != "repo" ]; then
  echo '{"data":{"repository":null}}'
  exit 0
fi
f="$FIXTURE_DIR/issue-$num.json"
if [ ! -f "$f" ]; then echo '{"data":{"repository":{"issue":null}}}'; exit 0; fi
# GraphQL returns only what was SELECTED. Serving the full fixture regardless
# would keep the suite green after a selection is dropped from the query, while
# in production the field comes back absent and the reader's `// ""` / `// 0`
# fallbacks silently mis-classify every issue. Delete what the query did not
# ask for, so each classification test is sensitive to its own selection.
[ -n "${QUERY_FILE:-}" ] && printf '%s' "$query" > "$QUERY_FILE"
prune='.'
case "$query" in *nameWithOwner*) ;; *) prune="$prune | del(.data.repository.issue.blockedBy.nodes[].repository)" ;; esac
case "$query" in *subIssuesSummary*) ;; *) prune="$prune | del(.data.repository.issue.subIssuesSummary)" ;; esac
case "$query" in *trackedIssuesCount*) ;; *) prune="$prune | del(.data.repository.issue.trackedIssuesCount)" ;; esac
case "$query" in *labels*) ;; *) prune="$prune | del(.data.repository.issue.labels)" ;; esac
case "$query" in *body*) ;; *) prune="$prune | del(.data.repository.issue.body)" ;; esac
# NB: `state` is deliberately not pruned — it is selected at BOTH the issue and
# the blockedBy-node level, so a substring test cannot tell which one was
# dropped. The query-shape test below pins the node-level selection instead.
jq -c "$prune" "$f"
EOF
  chmod +x "$STUB"
}

deps_failing() {  # $1 = issue number to walk from ; $2 = issue number gh fails on
  : "${2:?deps_failing needs the issue number to fail on}"
  run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" GH_FAIL_ON="$2" \
    zsh "$S" --repo owner/repo --issue "$1"
}

# mk_null_body <num> — the one body shape `mk` cannot express: GitHub returns
# JSON null for a body-less issue, and the classifier's `// ""` guard exists
# only for it. Without this fixture that guard is dead code under test, and
# dropping it would make EVERY body-less issue exit 1 as "not found".
mk_null_body() {
  jq -n --argjson num "$1" \
    '{data:{repository:{issue:{
        number:$num, state:"OPEN", body:null, trackedIssuesCount:0,
        subIssuesSummary:{total:0}, labels:{nodes:[]},
        blockedBy:{nodes:[]}}}}}' \
    > "$FIXTURE_DIR/issue-$1.json"
}

# mk <num> <state> <labels-json> <trackedIssuesCount> <body> <blockers-json> [sub-total]
# writes the raw GraphQL response fixture for one issue. subIssuesSummary is
# ALWAYS present (default total 0) — the live API always sends it, and a
# fixture omitting it would test the epic classifier against a shape
# production never sees (null-coercion instead of {total: 0}).
mk() {
  jq -n --argjson num "$1" --arg state "$2" --argjson labels "$3" \
        --argjson tracked "$4" --arg body "$5" --argjson blockers "$6" \
        --argjson subtotal "${7:-0}" \
    '{data:{repository:{issue:{
        number:$num, state:$state, body:$body, trackedIssuesCount:$tracked,
        subIssuesSummary:{total:$subtotal},
        labels:{nodes:($labels|map({name:.}))},
        blockedBy:{nodes:($blockers|map(
          # a blockedBy edge carries the repository it lives in, because the
          # relation may cross repositories. A plain number here means
          # same-repo; pass an object to place a blocker elsewhere.
          if type == "object" then . else {number:., state:"OPEN",
            repository:{nameWithOwner:"owner/repo"}} end))}}}}}' \
    > "$FIXTURE_DIR/issue-$1.json"
}

deps() {  # $1 = issue number ; rest = extra flags
  local n="$1"; shift
  run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    zsh "$S" --repo owner/repo --issue "$n" "$@"
}

# ---- usage errors ----------------------------------------------------------
#
# Every usage test asserts the MESSAGE, not just exit 2: several guards fall
# through to a later guard that also exits 2 (an empty --repo would be caught
# by the OWNER/NAME shape check), so a status-only assertion cannot fail for
# the branch it names. They also run through the stub, so a dropped guard
# fails as a legible assertion instead of contacting the real github.com.

usage_run() { run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" zsh "$S" "$@"; }

@test "usage: missing --repo exits 2" {
  usage_run --issue 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo OWNER/NAME is required"
}

@test "usage: missing --issue exits 2" {
  usage_run --repo owner/repo
  [ "$status" -eq 2 ]
  contains "$output" "--issue N is required"
}

@test "usage: --repo without a slash exits 2" {
  usage_run --repo just-a-name --issue 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
}

@test "usage: a --repo with extra segments or dot segments exits 2, not \"not found\"" {
  # the mirrored guard: without it these split into a name containing a slash,
  # GraphQL returns null, and a malformed ARGUMENT is reported as a missing issue
  usage_run --repo owner/name/extra --issue 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  usage_run --repo 'owner/..' --issue 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  usage_run --repo 'owner/repo?x=1' --issue 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  usage_run --repo '/repo' --issue 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
  usage_run --repo 'owner/' --issue 5
  [ "$status" -eq 2 ]
  contains "$output" "--repo must be OWNER/NAME"
}

@test "usage: a leading-dot repo NAME is accepted — only the dot segments are refused" {
  # the guard rejects exactly `.` and `..`, never "must start alphanumeric":
  # OWNER/.github is a real repo that carries issues, and refusing it would
  # report a well-formed invocation as a caller error (exit 2) and make
  # dependency enforcement unreachable for every issue in it. Underscore- and
  # hyphen-leading names are the same family.
  usage_run --repo 'owner/.github' --issue 5
  [ "$status" -ne 2 ]
  lacks "$output" "--repo must be OWNER/NAME"
  usage_run --repo 'owner/_internal' --issue 5
  [ "$status" -ne 2 ]
  lacks "$output" "--repo must be OWNER/NAME"
}

@test "usage: non-numeric --issue exits 2" {
  usage_run --repo owner/repo --issue abc
  [ "$status" -eq 2 ]
  contains "$output" "--issue must be a positive number"
}

@test "usage: non-numeric --max-depth exits 2 before any traversal" {
  usage_run --repo owner/repo --issue 5 --max-depth abc
  [ "$status" -eq 2 ]
  contains "$output" "--max-depth must be a positive number"
}

@test "usage: a dangling value flag exits 2, not a nounset abort" {
  usage_run --repo owner/repo --issue
  [ "$status" -eq 2 ]
  contains "$output" "--issue needs a value"
}

@test "usage: a dangling --repo exits 2, not a nounset abort" {
  usage_run --issue 5 --repo
  [ "$status" -eq 2 ]
  contains "$output" "--repo needs a value"
}

@test "usage: a dangling --max-depth exits 2, not a nounset abort" {
  usage_run --repo owner/repo --issue 5 --max-depth
  [ "$status" -eq 2 ]
  contains "$output" "--max-depth needs a value"
}

@test "a zero-padded --issue is normalised, not read as octal or passed through" {
  # 0010 is octal-distinct (octal 010 = 8): an un-normalised value reaches
  # --argjson only at the FINAL emit, after the whole traversal ran, and an
  # octal misreading would traverse a DIFFERENT issue under the asked-for number
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[]'
  run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    zsh "$S" --repo owner/repo --issue 0010
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.issue')" = "10" ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[11]' ]
}

@test "a missing jq is a named exit 1, not a per-issue \"not found\"" {
  mkdir -p "$BATS_TEST_TMPDIR/nojq"
  run env PATH="$BATS_TEST_TMPDIR/nojq" GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    "$(command -v zsh)" "$S" --repo owner/repo --issue 5
  [ "$status" -eq 1 ]
  contains "$output" "jq not found on PATH"
}

@test "the jq guard sits AFTER argument validation, so --help and usage errors keep their codes" {
  # moving the guard above the parser would turn --help into exit 1 and every
  # usage error into a jq message on a host without jq
  mkdir -p "$BATS_TEST_TMPDIR/nojq"
  run env PATH="$BATS_TEST_TMPDIR/nojq" GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    "$(command -v zsh)" "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: read-dependencies.zsh"
  run env PATH="$BATS_TEST_TMPDIR/nojq" GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" \
    "$(command -v zsh)" "$S" --repo owner/repo --issue abc
  [ "$status" -eq 2 ]
  contains "$output" "--issue must be a positive number"
}

@test "an EMPTY state aborts rather than silently pruning the sub-tree" {
  # an empty state is not OPEN, so the walk below this blocker would be skipped
  # and the blocker set under-reported at exit 0 — the gate's worst outcome
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 "" '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 1 ]
  contains "$output" "empty state for issue #20"
  lacks "$output" '"blocked"'
}

@test "usage: an unknown argument exits 2 rather than being ignored" {
  # a typo'd `--max_depth 2` silently ignored would run an unbounded traversal
  usage_run --repo owner/repo --issue 5 --max_depth 2
  [ "$status" -eq 2 ]
  contains "$output" "unknown argument: --max_depth"
}

@test "usage: --help prints the usage line and exits 0" {
  usage_run --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: read-dependencies.zsh --repo OWNER/NAME --issue N"
}

# ---- the trivial and error base cases --------------------------------------

@test "an issue with no blockers is not blocked" {
  mk 10 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.blocked, .open_blockers, .blockers, .cycles, .truncated]')" \
    = '[false,[],[],[],false]' ]
}

@test "a nonexistent issue is an internal error (exit 1), named as such" {
  # exit 1 covers TWO branches — an unparseable/absent issue and a failed gh
  # call — so the message is the contract, not just the status: a jq program
  # that stopped compiling would exit 1 here too, and a status-only assertion
  # would stay green while the reader called every issue nonexistent
  deps 999
  [ "$status" -eq 1 ]
  contains "$output" "issue #999 not found in owner/repo"
  lacks "$output" '"blocked"'
}

@test "a failed gh call is an internal error, distinct from a missing issue" {
  mk 10 OPEN '[]' 0 "" '[]'
  deps_failing 10 10
  [ "$status" -eq 1 ]
  contains "$output" "gh api graphql failed for issue #10"
  lacks "$output" '"blocked"'
}

@test "a blocker that does not exist aborts the traversal (exit 1)" {
  # distinct from the transport failure: gh SUCCEEDS and returns issue:null, so
  # the abort comes from jq. A rewrite that let the null case yield an object
  # would record a {number:null} blocker and report blocked:false
  mk 10 OPEN '[]' 0 "" '[998]'
  deps 10
  [ "$status" -eq 1 ]
  contains "$output" "issue #998 not found in owner/repo"
  lacks "$output" '"blocked"'
}

@test "a gh failure MID-traversal aborts — never a partial result" {
  # the worst failure mode for a gate that decides whether an issue is blocked:
  # swallowing the error and reporting {"blocked": false} for an unreachable API
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[]'
  deps_failing 10 12
  [ "$status" -eq 1 ]
  contains "$output" "gh api graphql failed for issue #12"
  lacks "$output" '"blocked"'
}

# ---- classification: open/closed, epic/issue -------------------------------

@test "direct blockers are classified open/closed; only open ones block" {
  mk 10 OPEN '[]' 0 "" '[11,12]'
  mk 11 OPEN '[]' 0 "" '[]'
  mk 12 CLOSED '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .blocked)" = "true" ]
  [ "$(echo "$output" | jq -c .open_blockers)" = '[11]' ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==11) | .open')" = "true" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==12) | .open')" = "false" ]
}

@test "closed blockers only means not blocked (but still recorded)" {
  mk 10 OPEN '[]' 0 "" '[12]'
  mk 12 CLOSED '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .blocked)" = "false" ]
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[12]' ]
}

@test "a blocker with the epic label is kind=epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '["epic"]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a blocker with native sub-issues is kind=epic (#802)" {
  mk 10 OPEN '[]' 0 "" '[20]'
  # native-only epic: no label, no tracked issues, no task-list body — only
  # subIssuesSummary marks it (the post-#802 shape once markdown lists fade)
  mk 20 OPEN '[]' 0 "" '[]' 3
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a blocker with subIssuesSummary total 0 and no other epic marker is kind=issue" {
  # the live API always sends subIssuesSummary — {total: 0} must classify as a
  # plain issue (guards against a null-coercion rewrite of the #802 clause)
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 "" '[]' 0
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a blocker with a NULL body classifies as kind=issue, not an error" {
  # GitHub sends body: null for a body-less issue — the `// ""` guard exists
  # only for this shape, and dropping it would exit 1 on every such issue
  mk 10 OPEN '[]' 0 "" '[20]'
  mk_null_body 20
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a NULL-bodied ROOT issue traverses normally" {
  mk_null_body 20
  deps 20
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blocked')" = "false" ]
}

@test "a blocker with tracked issues is kind=epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 3 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a blocker with a task-list body referencing issues is kind=epic" {
  # ONE form per body — `has_child_task_list` is an OR over lines, so a body
  # mixing forms proves only that *some* form still matches
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'## Children\n\n- [ ] #21\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a task list without issue refs does NOT make a blocker an epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'- [ ] add tests\n- [ ] write docs\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

# ---- the child-task-list rule (#1260) --------------------------------------
#
# A checkbox line declares a CHILD only when its content STARTS with an issue
# reference. A checkbox that merely MENTIONS one is an acceptance criterion —
# and a good criterion routinely cites an issue, so counting those classified
# the best-specified single stories as epics (the #937 / #936 misfire).
#
# Each accepted form gets its OWN body: the rule is an OR over lines, so a body
# carrying several forms would stay green after any single alternative was
# dropped from the regex.

@test "acceptance criteria that cite issue numbers are NOT an epic (#1260)" {
  # the live #937 / #936 shape: refined stories, zero sub-issues, criteria that
  # name sibling issues mid-sentence
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'## Acceptance criteria\n\n- [ ] `DependencyHealth` implements #937\'s `async`/`Sendable` seam.\n- [ ] The ARCHITECTURE.md note added by #1189 is updated (both the #936/#937 sentence and the table).\n- [ ] bats coverage asserts the fallback still holds (#809).\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a criterion whose ONLY issue ref is mid-sentence is not a child line" {
  # the minimal false positive: one checkbox, one ref, not at the start
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'- [ ] `docs/personas.md` no longer cites #1245 anywhere.\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a lowercase-x CHECKED child line is an epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'## Children\n\n- [x] #683 — `development-javascript` language plugin\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "an uppercase-X CHECKED child line is an epic (the other half of [ xX])" {
  # narrowing the class to [ x] would leave the suite green while epics whose
  # children were checked off as [X] stopped classifying
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'## Children\n\n- [X] #684 — uppercase checkmark\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a star-bulleted child line is an epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'* [ ] #689 — API styleguide rules\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a plus-bulleted child line is an epic" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'+ [ ] #944 — pagination rules\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "an owner/repo-prefixed child line is an epic (the cross-repo prefix)" {
  # the second fixture uses a REALISTIC slug — every real one carries a hyphen,
  # and often a dot or underscore. Narrowing the `[A-Za-z0-9_.-]` class would
  # stop it being a child line, so an epic that writes its children fully
  # qualified would classify as a plain issue and be built as one story
  mk 10 OPEN '[]' 0 "" '[20,21]'
  mk 20 OPEN '[]' 0 $'- [ ] owner/repo#687 — `development-composition` topic plugin\n' '[]'
  # all three non-alphanumeric members of the slug class, matching the
  # migration mirror — a classifier-only narrowing would leave an epic whose
  # children are fully qualified classifying as a plain issue
  mk 21 OPEN '[]' 0 $'- [ ] other-org/other.repo_2#687 — a fully-qualified child\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "epic" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "epic" ]
}

@test "an INDENTED child line is an epic (the leading-blank prefix)" {
  # epics that group children under a phase indent them; narrowing the rule to
  # `^[-*+]` must not ship green
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'## Children\n\n  - [ ] #21 — a nested child\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a bare-issue-URL task list is NOT an epic — deliberate, backfill cannot migrate it" {
  # `backfill-sub-issues.zsh` needs a `#N` ref, so detecting this shape would
  # funnel an epic into a migration that attaches nothing. The pre-#1260 rule
  # did not match it either. Widening this means widening BOTH scripts.
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'## Children\n\n- [ ] https://github.com/owner/repo/issues/944 — pagination rules\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "an ordered-list checkbox is NOT an epic — deliberate, matching backfill's bullet set" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'## Children\n\n1. [ ] #687 — a child\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "an epic with BOTH child lines and citing criteria is still an epic" {
  # the realistic un-backfilled epic: a Children list plus its own acceptance
  # criteria — the child lines must still win
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'## Children\n\n- [ ] #1059 — WebUI positions\n\n## Acceptance criteria\n\n- [ ] Each conflict is resolved in one direction, recorded against #1058.\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a task list QUOTED inside a code fence does NOT make an issue an epic" {
  # an issue that reproduces an epic body in a fenced block is not itself an
  # epic. backfill-sub-issues.zsh skips fenced lines too — that is invariant
  # (b) of the two-rule contract, not the two rules being "the same rule"
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'A real epic declares children like this:\n\n```markdown\n- [ ] #687 — a child\n- [x] #689 — another child\n```\n\nThat is the shape this issue is about.\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a child line AFTER a closed fence still makes the blocker an epic" {
  # fence tracking must toggle back off — otherwise everything past the first
  # fenced block would stop being read at all
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'```\n- [ ] #21 — quoted, not a child\n```\n\n## Children\n\n- [ ] #22 — a real child\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a quoted child line in a SECOND fenced block is still ignored" {
  # the toggle must come back ON: a machine that only ever clears the flag
  # after the first close would read the second block as body text
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'```\nsome sample\n```\n\nprose in between\n\n```markdown\n- [ ] #21 — quoted, not a child\n```\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "an UNCLOSED fence swallows the rest of the body" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'Here is the shape:\n\n```markdown\n- [ ] #21 — quoted\n- [ ] #22 — quoted\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a task list quoted inside a ~~~ fence is not an epic either" {
  # markdown accepts tilde fences equally; the false-positive class #1260
  # closes is the QUOTE, not the fence character
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'A real epic writes:\n\n~~~markdown\n- [ ] #687 — a child\n~~~\n\nThat is the shape.\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a shorter inner backtick fence does NOT reopen a longer outer fence" {
  # markdown-about-markdown — the shape an issue discussing task lists has.
  # The inner fence is deliberately UNBALANCED: under a bare toggle the single
  # inner ``` closes the outer block and the quoted child line reads as real
  # (kind=epic), so this test fails the moment the run-length rule is lost
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'````markdown\n```\n- [ ] #21 — quoted, not a child\n````\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a LONGER run does close a shorter fence, and the child after it counts" {
  # the other half of the length rule: >= the opener closes. Pins that the
  # comparison is not simply equality, and that the close path still works
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'```markdown\n- [ ] #21 — quoted\n````\n\n## Children\n\n- [ ] #22 — a real child\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a tilde line inside a backtick fence does not close it" {
  # a fence closes only on a run of the SAME character
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'```markdown\n~~~\n- [ ] #21 — quoted, not a child\n```\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a closing fence with an info string does not close the block" {
  # only a bare run closes; `\`\`\`markdown` mid-block is an opener-shaped line
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'```\n```markdown\n- [ ] #21 — still quoted\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a ~~~ fence CLOSES, so a child after it still counts" {
  # the tilde test above pins only the OPEN: if ~ fences opened but never
  # closed, every epic with a tilde-quoted example above its Children list
  # would silently reclassify as a plain issue
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'~~~markdown\n- [ ] #21 — quoted\n~~~\n\n## Children\n\n- [ ] #22 — a real child\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "extra blanks around the bullet and checkbox still make a child line" {
  # the migration side asserts it accepts these "as the classifier accepts
  # them" — pin the classifier half of that claim
  mk 10 OPEN '[]' 0 "" '[20,21]'
  mk 20 OPEN '[]' 0 $'-  [ ] #21 — hand-aligned child\n' '[]'
  mk 21 OPEN '[]' 0 $'- [ ]  #22 — extra gap after the checkbox\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "epic" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "epic" ]
}

@test "a line STARTING with an inline code span does not open a fence" {
  # a fence needs THREE or more marker characters. A one-or-more run would
  # open a fence on ordinary prose like "`read-dependencies.zsh` codifies …"
  # and swallow the Children list below it — the epic would read as an issue,
  # and the migration parser (which requires three) would disagree
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'`read-dependencies.zsh` codifies the rule.\n\n## Children\n\n- [ ] #687 — a real child\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "an inline code span does not invert fence parity for a REAL fence below it" {
  # the companion failure: one spurious opener would make the real ``` a
  # CLOSE, so the quoted child would read as live — #1260 all over again
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'`gh` is required.\n\n```\n- [ ] #21 — quoted, not a child\n```\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a line starting with a struck-through span does not open a fence either" {
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'~~dropped~~ — see below.\n\n## Children\n\n- [ ] #687 — a real child\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a TAB in any bullet position IS a child line (the positive half of [ \\t])" {
  # the negative half (NBSP) is pinned below; without this, an implementation
  # reading the bracket escape as {space, backslash, t} would classify a
  # tab-indented epic while awk resolved no ref — invariant (a), silently
  mk 10 OPEN '[]' 0 "" '[20,21,22]'
  mk 20 OPEN '[]' 0 $'\t- [ ] #21 — tab-indented\n' '[]'
  mk 21 OPEN '[]' 0 $'-\t[ ] #21 — tab after the bullet\n' '[]'
  mk 22 OPEN '[]' 0 $'- [ ]\t#21 — tab after the checkbox\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "epic" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "epic" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==22) | .kind')" = "epic" ]
}

@test "a NON-ASCII blank in any bullet position is NOT a child line" {
  # the discriminating half of the blank-class pair. Respelling either of the
  # two [ \t] runs AROUND THE BULLET as [[:blank:]] makes Oniguruma accept
  # blockers 20/21 while awk (ASCII) resolves no ref from them — its own
  # ^[ \t]*[-*+][ \t]+\[[ xX]\] guard rejects the line — so that is the
  # invariant-(a) break: an epic detected that migrates nothing. The run AFTER
  # the checkbox (blocker 22) is the one-sided-strictness position instead:
  # awk's guard stops at \] and its ref match is position-independent, so it
  # migrates #790 from that line anyway (same family as the glued-to-checkbox
  # pair). All three must stay non-children; only the reason differs.
  local nbsp_lead nbsp_bullet nbsp_box
  nbsp_lead="$(printf '\xc2\xa0- [ ] #790 — NBSP before the bullet\n')"
  nbsp_bullet="$(printf -- '-\xc2\xa0[ ] #790 — NBSP after the bullet\n')"
  nbsp_box="$(printf -- '- [ ]\xc2\xa0#790 — NBSP after the checkbox\n')"
  mk 10 OPEN '[]' 0 "" '[20,21,22]'
  mk 20 OPEN '[]' 0 "$nbsp_lead" '[]'
  mk 21 OPEN '[]' 0 "$nbsp_bullet" '[]'
  mk 22 OPEN '[]' 0 "$nbsp_box" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "issue" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "issue" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==22) | .kind')" = "issue" ]
}

@test "a NON-ASCII blank does not open a fence, matching the migration parser" {
  # Oniguruma reads [[:blank:]] as Unicode-aware and awk's as ASCII, so the
  # same spelling would denote different sets; both now use [ \t], and an
  # NBSP-indented fence marker opens a fence in NEITHER parser
  # the NBSP is spelled explicitly: a raw invisible byte is the whole
  # discriminating power of this test, and any normalising tool would fold
  # it into an ASCII space, silently inverting what the fixture asserts
  local nbsp_fence
  nbsp_fence="$(printf '\xc2\xa0```markdown\n- [ ] #21 — still a real child\n')"
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 "$nbsp_fence" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a CRLF body still opens and CLOSES its fences" {
  # the fence-close guard tolerates a trailing \r purely for web-UI bodies;
  # drop it and every CRLF fence stays open, swallowing the real Children list
  mk 10 OPEN '[]' 0 "" '[20,21]'
  mk 20 OPEN '[]' 0 $'```markdown\r\n- [ ] #21 — quoted\r\n```\r\n\r\n## Children\r\n\r\n- [ ] #22 — a real child\r\n' '[]'
  mk 21 OPEN '[]' 0 $'```markdown\r\n- [ ] #21 — quoted, the only task list\r\n```\r\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "epic" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "issue" ]
}

@test "a decorated ref is NOT a child line — the classifier is stricter here" {
  # NOT a two-sided case: the backfill's match-anywhere parser resolves #687
  # inside `**#687**` and would migrate it, so widening the classifier here
  # would be a ONE-sided change violating neither invariant. It stays strict
  # because a widened anchor is the likeliest way #1260's false positive returns
  mk 10 OPEN '[]' 0 "" '[20,21]'
  mk 20 OPEN '[]' 0 $'## Children\n\n- [ ] **#687** — bolded\n' '[]'
  mk 21 OPEN '[]' 0 $'## Children\n\n- [ ] [#687](https://github.com/owner/repo/issues/687) — linked\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "issue" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "issue" ]
}

@test "a closing fence with TRAILING BLANKS still closes it" {
  # every other fixture closes with a bare run, so the close guard's [ \t]* is
  # only ever matched against "". Narrowing it to == "" would keep the suite
  # green while a real body — GitHub keeps trailing whitespace — never closed
  # its fence, swallowing the Children list below at exit 0
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'```markdown\n- [ ] #21 — quoted\n```  \t\n\n## Children\n\n- [ ] #22 — a real child\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "an INDENTED fence marker still opens a fence" {
  # every other fixture puts the marker at column 0, so the opener's leading
  # [ \t]* is unpinned; dropping it would unfence this here while the migration
  # parser still fences it — the misparent direction of invariant (b)
  mk 10 OPEN '[]' 0 "" '[20,21]'
  # blocker 21 indents with a TAB — the other member of the shared [ \t]
  # class. A one-sided respelling to `[ ]*` would unfence it here while awk
  # still fences it, so the classifier would read the quoted lines as children
  mk 20 OPEN '[]' 0 $'  ```markdown\n- [ ] #21 — quoted, not a child\n  ```\n' '[]'
  mk 21 OPEN '[]' 0 $'\t```markdown\n- [ ] #21 — quoted, not a child\n\t```\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "issue" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "issue" ]
}

@test "a body whose ONLY checkbox cites its own number is still an epic" {
  # the classifier half of the documented empty-plan premise: such a body IS
  # an epic here, and the migration resolves the ref but attaches nothing —
  # which is why E1 halts on an empty plan rather than reading exit 0 as done
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 $'- [ ] #20 stays open as the tracker and closes only when all slices close.\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "epic" ]
}

@test "a ref glued to a NON-ASCII word character is NOT a child line (the classifier is stricter)" {
  # the documented one-sided strictness, verified: Oniguruma's \b IS
  # Unicode-aware, so this line is no child here — while the migration parser
  # resolves it (its boundary test is ASCII). Widening the classifier's \b to
  # an explicit ASCII class would flip this silently.
  local glued
  glued="$(printf -- '- [ ] #687\xc3\xa4 — glued to a non-ASCII word character\n')"
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 "$glued" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[0].kind')" = "issue" ]
}

@test "a ref glued to the checkbox or to a word is NOT a child line" {
  # the blank after the checkbox, and the word boundary after the ref.
  # `_` is the member a hand-written `[^0-9A-Za-z]` most plausibly drops, and
  # a digit cannot test the class (the `[0-9]+` consumes it), so it is the one
  # member worth pinning explicitly on both sides.
  # blocker 23 pins the LOWER bound of the post-bullet run: loosening only the
  # classifier's `[-*+][ \t]+` to `*` would call it a child while awk (which
  # requires one) resolves nothing — invariant (a), an epic with an empty plan
  mk 10 OPEN '[]' 0 "" '[20,21,22,23]'
  mk 20 OPEN '[]' 0 $'- [ ]#687 — no blank after the checkbox\n' '[]'
  mk 21 OPEN '[]' 0 $'- [ ] #687abc — no word boundary\n' '[]'
  mk 22 OPEN '[]' 0 $'- [ ] #687_x — glued to an underscore\n' '[]'
  mk 23 OPEN '[]' 0 $'-[ ] #687 — no blank before the checkbox\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==23) | .kind')" = "issue" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "issue" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "issue" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==22) | .kind')" = "issue" ]
}

@test "a CRLF body classifies the same as an LF one, in both directions" {
  # bodies authored in the GitHub web UI come back with \r\n, so every line the
  # filter sees carries a trailing \r — nothing else pins that
  mk 10 OPEN '[]' 0 "" '[20,21]'
  mk 20 OPEN '[]' 0 $'## Children\r\n\r\n- [ ] #21 — a real child\r\n' '[]'
  mk 21 OPEN '[]' 0 $'## Acceptance criteria\r\n\r\n- [ ] The note added by #1189 is updated.\r\n' '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "epic" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "issue" ]
}

@test "the epic-label and sub-issue signals outrank a citing-criteria body" {
  # the body clause is the only one that narrowed: an epic that ALSO writes
  # citing criteria must keep classifying as an epic via its other markers
  mk 10 OPEN '[]' 0 "" '[20,21]'
  mk 20 OPEN '["epic"]' 0 $'- [ ] Resolve the conflict recorded in #1059.\n' '[]'
  mk 21 OPEN '[]' 0 $'- [ ] Resolve the conflict recorded in #1059.\n' '[]' 4
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==20) | .kind')" = "epic" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==21) | .kind')" = "epic" ]
}

# ---- transitive traversal ---------------------------------------------------

@test "blockers resolve transitively with depth per hop" {
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .open_blockers)" = '[11,12]' ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==11) | .depth')" = "1" ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==12) | .depth')" = "2" ]
}

@test "a CLOSED blocker is not recursed into" {
  mk 10 OPEN '[]' 0 "" '[30]'
  mk 30 CLOSED '[]' 0 "" '[31]'
  mk 31 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .blocked)" = "false" ]
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[30]' ]
}

@test "a blocker reached by two paths records its MINIMUM depth" {
  # DFS reaches 12 at depth 2 (via 11) before the top-level pass reaches it at
  # depth 1, and `depth: 1` is documented as "direct blocker" — a claim that
  # reaches the human verbatim in the `comment_md` the precheck renders
  mk 10 OPEN '[]' 0 "" '[11,12]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==12) | .depth')" = "1" ]
  # still recorded once, in discovery order
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[11,12]' ]
}

@test "a blocker reached SHALLOW first is not re-stamped deeper" {
  # the mirror graph: 12 is recorded at depth 1 and then re-reached at depth 2.
  # Without it, simply dropping the guard (last-write-wins) would satisfy the
  # test above, since there the last write happens to be the minimum
  mk 10 OPEN '[]' 0 "" '[12,11]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blockers[] | select(.number==12) | .depth')" = "1" ]
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[12,11]' ]
}

@test "a diamond records the shared blocker once" {
  mk 10 OPEN '[]' 0 "" '[2,3]'
  mk 2 OPEN '[]' 0 "" '[4]'
  mk 3 OPEN '[]' 0 "" '[4]'
  mk 4 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.blockers[] | select(.number==4)] | length')" = "1" ]
  [ "$(echo "$output" | jq -c '.open_blockers | sort')" = '[2,3,4]' ]
}

# ---- cycles ------------------------------------------------------------------

@test "the GraphQL query selects every field the classifier and the walk depend on" {
  # the direct pin for the selections the pruning stub cannot disambiguate, and
  # a second line of defence for the ones it can. Each of these drives a
  # documented decision: nameWithOwner splits same-repo from cross-repo
  # blockers, the node-level state decides whether a foreign blocker still
  # blocks, and the other four are the epic classifier's own four clauses.
  # Dropping any one degrades silently in production — the field comes back
  # absent and the reader's `// ""` / `// 0` fallbacks answer for it. The
  # issue-level `state` is the worst case and the one the stub cannot prune
  # (it is selected at two levels): without it every node normalises to
  # state null, the non-empty guard passes on the STRING "null", no blocker is
  # ever OPEN, and the reader reports blocked:false for every issue in the repo.
  mk 10 OPEN '[]' 0 "" '[]'
  local qf="$BATS_TEST_TMPDIR/query.txt"
  run env GH_BIN="$STUB" FIXTURE_DIR="$FIXTURE_DIR" QUERY_FILE="$qf" \
    zsh "$S" --repo owner/repo --issue 10
  [ "$status" -eq 0 ]
  # assert the exact SELECTIONS, not bare field names. A bare needle passes
  # when a selection is narrowed to different sub-fields — `subIssuesSummary`
  # still matches `{percentCompleted}`, `labels` still matches `{nodes{id}}` —
  # and the stub then does not prune, so the fixture keeps the old shape and
  # the epic classifier silently stops firing in production.
  contains "$(cat "$qf")" "number state body trackedIssuesCount"
  contains "$(cat "$qf")" "subIssuesSummary{total}"
  contains "$(cat "$qf")" "labels(first:100){nodes{name}}"
  # the blockedBy node carries its OWN state, not just the issue-level one
  contains "$(cat "$qf")" "blockedBy(first:100){nodes{number state repository{nameWithOwner}}}"
}

@test "a CROSS-REPO blocker is never re-resolved against --repo" {
  # a blockedBy edge may point at another repository, but _fetch_node is
  # hard-bound to --repo — so re-resolving the bare number looks up a DIFFERENT
  # issue that merely shares it. Here owner/repo#7 exists and is CLOSED while
  # the real blocker other/elsewhere#7 is OPEN: without the split the walk
  # reads CLOSED, emits blocked:false, and work starts on a blocked issue.
  mk 10 OPEN '[]' 0 "" '[{"number":7,"state":"OPEN",
       "repository":{"nameWithOwner":"other/elsewhere"}}]'
  mk 7 CLOSED '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  # the same-repo #7 is NOT walked, so it never appears as a blocker
  [ "$(echo "$output" | jq -c '.blockers')" = '[]' ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[]' ]
  # ...and the foreign one is carried through, keeping `blocked` fail-closed
  [ "$(echo "$output" | jq -r '.blocked')" = "true" ]
  [ "$(echo "$output" | jq -c '.foreign_blockers')" \
    = '[{"ref":"other/elsewhere#7","open":true}]' ]
}

@test "a CLOSED cross-repo blocker is recorded but does not block" {
  # the other side: a met cross-repo prerequisite must not wedge the gate shut
  # forever. It is still reported, so the omission from the walk is visible.
  mk 10 OPEN '[]' 0 "" '[{"number":7,"state":"CLOSED",
       "repository":{"nameWithOwner":"other/elsewhere"}}]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blocked')" = "false" ]
  [ "$(echo "$output" | jq -c '.foreign_blockers')" \
    = '[{"ref":"other/elsewhere#7","open":false}]' ]
}

@test "a same-repo blocker whose slug differs only by CASE is still traversed" {
  # GitHub slugs are case-insensitive; treating OWNER/REPO as foreign would
  # drop a real blocker out of the walk and under-report the blocker set.
  mk 10 OPEN '[]' 0 "" '[{"number":11,"state":"OPEN",
       "repository":{"nameWithOwner":"OWNER/REPO"}}]'
  mk 11 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[11]' ]
  [ "$(echo "$output" | jq -c '.foreign_blockers')" = '[]' ]
}

@test "the same cross-repo blocker reached twice is recorded once" {
  # the dedup key is the slug-qualified ref, not the bare number: two distinct
  # foreign repos may both have a #7, and collapsing them would hide one.
  mk 10 OPEN '[]' 0 "" '[11,{"number":7,"state":"OPEN",
       "repository":{"nameWithOwner":"other/elsewhere"}}]'
  mk 11 OPEN '[]' 0 "" '[{"number":7,"state":"OPEN",
       "repository":{"nameWithOwner":"other/elsewhere"}},
       {"number":7,"state":"OPEN","repository":{"nameWithOwner":"third/one"}}]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.foreign_blockers[].ref]')" \
    = '["other/elsewhere#7","third/one#7"]' ]
}

@test "the --repo slug reaches the query as owner and name, in that order" {
  # the accepting branch of the --repo guard: every other test would still pass
  # if owner and name were transposed, or the raw slug spliced into either,
  # because nothing observed which repository was queried. In production that
  # regression reports every issue as "not found in owner/repo" — the exact
  # malformed-argument-as-missing-issue confusion the guard exists to prevent —
  # or, where the transposition names a real repo, silently returns another
  # repository's blocker graph and the gate decides "blocked" from it.
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[11]' ]
}

@test "a two-issue cycle is reported explicitly" {
  mk 20 OPEN '[]' 0 "" '[21]'
  mk 21 OPEN '[]' 0 "" '[20]'
  deps 20
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.cycles')" = '[[20,21,20]]' ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[21]' ]
}

@test "a cycle reached from outside reports only the cycle, not the path to it" {
  # both other cycle tests start the cycle AT the walked issue, so the chain is
  # exactly the cycle and the first-occurrence slice is a no-op. Here #10 only
  # REACHES the cycle: dropping the slice would emit [[10,20,21,20]] — a path
  # that is not a cycle, naming an issue with no part in it. That array is what
  # dependency-precheck renders verbatim into the REJECT_CYCLE comment a human
  # reads, so it would send them to break a cycle #10 is not in.
  mk 10 OPEN '[]' 0 "" '[20]'
  mk 20 OPEN '[]' 0 "" '[21]'
  mk 21 OPEN '[]' 0 "" '[20]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.cycles')" = '[[20,21,20]]' ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[20,21]' ]
}

@test "a self-blocking issue is a one-node cycle" {
  mk 40 OPEN '[]' 0 "" '[40]'
  deps 40
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.cycles')" = '[[40,40]]' ]
}

# ---- depth cap ---------------------------------------------------------------

@test "--max-depth stops traversal and sets truncated" {
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[13]'
  mk 13 OPEN '[]' 0 "" '[]'
  deps 10 --max-depth 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .truncated)" = "true" ]
  # traversal proceeds UP TO the cap, then stops: exactly the depth-1 and
  # depth-2 blockers are recorded, never an empty set nor the depth-3 one
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[11,12]' ]
}

@test "usage: --max-depth 0 is a usage error, not a cap" {
  # a cap of 0 reads no edge at all: an issue that HAS dependencies comes back
  # with an empty blocker set (truncated, hence rejected), and one that has
  # none is "cleared" without a single edge being read. The second is the real
  # hazard — a silent clearance, not a universal rejection. Neither is a cap;
  # both are a usage error. Mirrored in dependency-precheck.zsh.
  usage_run --repo owner/repo --issue 10 --max-depth 0
  [ "$status" -eq 2 ]
  contains "$output" "--max-depth must be a positive number"
}

@test "--max-depth 1 expands only DIRECT blockers and marks the walk truncated" {
  # the boundary that 0 used to pin: an off-by-one rewrite to `>` would expand
  # one level further while still claiming truncation
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[]'
  deps 10 --max-depth 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .truncated)" = "true" ]
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[11]' ]
}

@test "a cap reached on a LEAF does not claim truncation" {
  # the node at the cap is already fetched, so a leaf leaves NOTHING unread.
  # Claiming truncation there tells the human the blocker list is a floor and
  # makes dependency-precheck render "the list above may be incomplete" — for a
  # walk that in fact enumerated the whole graph.
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[]'
  deps 10 --max-depth 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .truncated)" = "false" ]
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[11]' ]
}

@test "a node RE-ENTERED at the cap does not claim truncation once its edges were read" {
  # R -> [A, B]; A -> [C]; B -> [A]; C a leaf, cap 2. DFS reads A at depth 1
  # and C at depth 2, then reaches A again via B with the chain already at the
  # cap. A's edges were ALREADY read, so nothing is unread — deciding
  # truncation at the moment of the cap would report a floor for a walk that
  # enumerated the whole graph, and the precheck would render "the list above
  # may be incomplete" onto the issue.
  mk 10 OPEN '[]' 0 "" '[11,12]'
  mk 11 OPEN '[]' 0 "" '[13]'
  mk 12 OPEN '[]' 0 "" '[11]'
  mk 13 OPEN '[]' 0 "" '[]'
  deps 10 --max-depth 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .truncated)" = "false" ]
  # discovery order: 11 at depth 1, its child 13 at depth 2, then 12
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[11,13,12]' ]
}

@test "a node DEFERRED at the cap clears itself once expanded from a shallower path" {
  # the mirror: the deep visit defers, the shallow one expands. Deciding the
  # flag at the cap would leave it stuck true for a complete walk; deriving it
  # at the end from what is STILL deferred lets the later expansion clear it.
  mk 10 OPEN '[]' 0 "" '[11,12]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[13]'
  mk 13 OPEN '[]' 0 "" '[]'
  deps 10 --max-depth 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .truncated)" = "false" ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[11,12,13]' ]
}

@test "a cycle closing at the cap on an already-expanded node is still reported" {
  # R -> [A, B]; A -> [B]; B -> [A], cap 2 — the loop closes on BOTH directions
  # here, so this pins the record's shape (closes on its own first node, no
  # route-in prefix), not the recorder's position relative to the
  # already-expanded early return. The test above pins that.
  # The reader would then emit cycles [] with truncated false: a document
  # asserting a complete walk over a graph that provably contains a cycle. The
  # precheck returns REJECT_BLOCKED instead of REJECT_CYCLE and tells the human
  # to resolve A deepest-first — which is blocked by B, which is blocked by A.
  # That unsatisfiable instruction is exactly what REJECT_CYCLE exists to refuse.
  mk 10 OPEN '[]' 0 "" '[11,12]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[11]'
  deps 10 --max-depth 2
  [ "$status" -eq 0 ]
  # the loop IS reported — that is the load-bearing half: without it the
  # document claims a complete, acyclic walk
  [ "$(echo "$output" | jq -c '.cycles')" != '[]' ]
  # every reported path is the 11<->12 loop, closing on its own first node,
  # never a route into it from #10
  [ "$(echo "$output" | jq -r '[.cycles[] | (.[0] == .[-1]) and ((. | unique) == [11,12])] | all')" = "true" ]
  [ "$(echo "$output" | jq -r '[.cycles[][] | . == 10] | any')" = "false" ]
  # NB the same loop is currently reported once per direction — deduping
  # cycles is the recorded follow-up, not something this assertion pins
}

@test "a cycle whose ONLY closure is a cap visit to an already-expanded node is reported" {
  # 12 is expanded via 11, and its 12 -> 13 edge is read there while 13 is not
  # yet on the chain; the loop 12 -> 13 -> 14 -> 12 closes only later, when 12
  # is re-reached at the cap from [10,13,14] and is ALREADY expanded. The
  # recorder therefore has to run BEFORE the expanded early-return — the
  # natural "skip already-expanded nodes first" refactor loses the graph's only
  # cycle, and the reader then claims a complete ACYCLIC walk, so the gate
  # returns REJECT_BLOCKED and posts "resolve #14 first" onto the issue, an
  # instruction the loop makes unsatisfiable. The neighbouring cap-cycle test
  # cannot pin this: its graph records the same loop from a non-expanded visit.
  mk 10 OPEN '[]' 0 "" '[11,13]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[13]'
  mk 13 OPEN '[]' 0 "" '[14]'
  mk 14 OPEN '[]' 0 "" '[12]'
  deps 10 --max-depth 3
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.cycles')" = '[[13,14,12,13]]' ]
  # the pair that makes the loss legible: without the recorder the walk is
  # reported both complete AND acyclic
  [ "$(echo "$output" | jq -r .truncated)" = "false" ]
}

@test "a SELF-blocking issue reached exactly at the cap is still a one-node cycle" {
  # at the cap the current node is deliberately not yet pushed onto the chain,
  # so an on_path test alone never sees a self-edge. The non-cap path DOES
  # report this shape (pinned as [[40,40]] elsewhere), so without the explicit
  # case the two cycle recorders disagree about a shape the repo has
  # contracted — and the gate returns REJECT_BLOCKED telling the human to
  # resolve #40 first, an issue that blocks itself.
  mk 10 OPEN '[]' 0 "" '[40]'
  mk 40 OPEN '[]' 0 "" '[40]'
  deps 10 --max-depth 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.cycles')" = '[[40,40]]' ]
}

@test "a cap reached on a node with only a CROSS-REPO edge still claims truncation" {
  # the walk returns at the cap BEFORE the foreign-blocker recording loop, so a
  # cross-repo edge hanging off the capped node is never entered into
  # foreign_blockers and never counted anywhere else — the truncated flag is
  # the consumer's ONLY signal that it exists. Dropping the foreign term from
  # the pending count (the obvious "they are not traversed anyway"
  # simplification) makes the reader claim a complete walk, and the precheck
  # then suppresses its incompleteness caution on a comment posted verbatim to
  # the issue, presenting a list that omits an open prerequisite as complete.
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[{"number":7,"state":"OPEN",
       "repository":{"nameWithOwner":"other/elsewhere"}}]'
  deps 10 --max-depth 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .truncated)" = "true" ]
  # the decisive pair: the foreign edge is NOT recorded, so nothing but the
  # flag reveals it
  [ "$(echo "$output" | jq -c '.foreign_blockers')" = '[]' ]
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[11]' ]
}

@test "a blockedBy node with NO repository slug is traversed as same-repo, never dropped" {
  # the documented fail-safe: an absent slug cannot be proven foreign, so it
  # counts as same-repo. Collapsing the disjunct to a plain slug-equality test
  # keeps every other test green while a slug-less node falls out of blocked_by
  # AND fails foreign_blocked_by's non-empty guard — the blocker vanishes
  # entirely and the reader emits blocked:false at exit 0, so the gate PROCEEDs
  # on an issue that has an open blocker. That is the one fail-open answer the
  # whole design exists to prevent. The migration side pins its mirror already.
  mk 10 OPEN '[]' 0 "" '[{"number":11,"state":"OPEN"}]'
  mk 11 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .blocked)" = "true" ]
  [ "$(echo "$output" | jq -c '.open_blockers')" = '[11]' ]
  # proves it was traversed, not merely re-routed into the foreign array
  [ "$(echo "$output" | jq -c '.foreign_blockers')" = '[]' ]
}

@test "usage: --issue 0 is a usage error, not an exit-1 not-found" {
  # GitHub issue numbers start at 1, so 0 cannot name one. Without the lower
  # bound the query returns a null issue and the run dies exit 1 as
  # "issue #0 not found" — a malformed ARGUMENT reported as a missing issue,
  # which dependency-precheck then relays as "the reader failed" (retry)
  # instead of "fix the call".
  usage_run --repo owner/repo --issue 0
  [ "$status" -eq 2 ]
  contains "$output" "--issue must be a positive number"
}

@test "the DEFAULT depth cap reaches well past two hops without truncating" {
  # pins the documented default of 20: a typo'd default of 2 would silently
  # truncate real epics while still exiting 0
  mk 10 OPEN '[]' 0 "" '[11]'
  mk 11 OPEN '[]' 0 "" '[12]'
  mk 12 OPEN '[]' 0 "" '[13]'
  mk 13 OPEN '[]' 0 "" '[]'
  deps 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .truncated)" = "false" ]
  [ "$(echo "$output" | jq -c '[.blockers[].number]')" = '[11,12,13]' ]
}
