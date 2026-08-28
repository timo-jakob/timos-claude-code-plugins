#!/usr/bin/env bats
#
# Behavioral tests for review-dispatch.zsh (#560): the review-panel invocation
# contract for the autonomous review loop (epic #557). The orchestrator must
# pick the right language panel WITHOUT language-specific knowledge (mirroring
# /development:maintenance dispatch), scope review to the STORY'S DIFF (so the
# loop never re-litigates untouched legacy code), and turn an unsupported repo
# type into a TYPED escalation rather than a crash.
#
# Detection is stubbed via the DETECT_STACK_BIN seam so language selection is
# deterministic and needs no git/gh probing; git itself runs against real temp
# repos so the diff-scoping is exercised for real.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"

  # Fake detect-stack.sh: echoes the languages JSON from $DETECT_LANGS_JSON.
  STUB="$BATS_TEST_TMPDIR/detect-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$DETECT_LANGS_JSON"
EOF
  chmod +x "$STUB"

  # A real temp git repo with a committed base on `main`.
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/README.md"
  echo old > "$R/legacy.py"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
}

plan() {  # $1 = languages json ; rest = extra flags
  local langs="$1"; shift
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON="$langs" \
    zsh "$S" plan --repo "$R" --base main "$@"
}

# ---- repo-type → panel mapping (adding a language needs no orchestrator edit)

@test "plan: python repo maps to development-python:review" {
  plan '{"languages":["python"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "python" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-python:review" ]
}

@test "plan: swift repo maps to development-swift:review (same invocation)" {
  plan '{"languages":["swift"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-swift:review" ]
}

@test "plan: java repo maps to development-java:review" {
  plan '{"languages":["java"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-java:review" ]
}

@test "plan: go repo maps to development-go:review (#872)" {
  # Slice C gave Go a conforming panel; without `go` in the supported set the
  # review loop would escalate a Go repo as unsupported_repo_type instead.
  plan '{"languages":["go"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-go:review" ]
}

@test "plan: the unsupported-repo-type error advertises go among the supported panels (#872)" {
  plan '{"languages":["rust"]}'
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.supported | index("go") != null' >/dev/null
}

@test "plan: findings_path is a well-known per-round path in the worktree" {
  # --final, because since #1434 a round past the first must say what it is
  # iterating on. This test is about the artifact PATH, not the scope, so
  # declaring it a closing sweep is the cheapest way to keep it on that subject.
  plan '{"languages":["python"]}' --round 2 --final
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .round)" = "2" ]
  [ "$(echo "$output" | jq -r .findings_path)" = "$R/.review/findings-round-2.json" ]
}

# ---- diff-scoping: only the story's changed files are the review scope

@test "plan: changed_files are the story's diff, not the whole repo" {
  echo "print(1)" > "$R/app.py"        # new (untracked) file = the story
  plan '{"languages":["python"]}'
  [ "$status" -eq 0 ]
  # app.py is in scope; the untouched committed legacy.py is not
  echo "$output" | jq -e '.changed_files | index("app.py")' >/dev/null
  echo "$output" | jq -e '.changed_files | index("legacy.py") | not' >/dev/null
}

# ---- delta scoping: a round past the first ITERATES on the previous one (#1434)
#
# The identity a round is scoped against is git-tree-id.zsh's — the same one the
# loop persists per round — so the tests compute it the same way rather than
# hand-rolling a second notion of "the tree as it was".

tree_id() {  # echo the current working-tree identity of $R
  zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/git-tree-id.zsh" "$R"
}

@test "plan: #1434 round 1 is the full sweep — scope_mode full, no prior tree, no delta" {
  echo "print(1)" > "$R/app.py"
  plan '{"languages":["python"]}' --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "full" ]
  [ "$(echo "$output" | jq -r .scope_empty)" = "false" ]
  [ "$(echo "$output" | jq -r .prior_tree)" = "null" ]
  [ "$(echo "$output" | jq -r .delta_files)" = "null" ]
  [ "$(echo "$output" | jq -r .fix_verification_path)" = "null" ]
  [ "$(echo "$output" | jq -r .adjudicated_path)" = "null" ]
  # unchanged from before #1434: the whole story diff
  [ "$(echo "$output" | jq -c '.changed_files')" = '["app.py"]' ]
}

@test "plan: #1434 an intermediate round is scoped to the DELTA since the prior tree" {
  echo "print(1)" > "$R/app.py"          # changed BEFORE the prior tree
  local t1; t1="$(tree_id)"
  echo "print(2)" > "$R/helper.py"       # changed AFTER it
  # a NESTED path too: `diff-tree` without -r reports the top-level TREE entry
  # (`src`) rather than the file, so a nested delta member is what actually pins
  # the recursive flag — every other fixture here is at the repo root, where the
  # two spellings agree
  mkdir -p "$R/src"
  echo "print(3)" > "$R/src/nested.py"
  plan '{"languages":["python"]}' --round 3 --prior-tree "$t1" \
    --fix-verification /tmp/verify-3.json --adjudicated /tmp/adjudicated.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "delta" ]
  [ "$(echo "$output" | jq -r .scope_empty)" = "false" ]
  [ "$(echo "$output" | jq -r .prior_tree)" = "$t1" ]
  # the review scope IS the delta: the file changed before the prior tree is
  # absent, the ones changed after it are present, as FILE paths. Re-reviewing
  # app.py is the independent-repeat behaviour this story removes.
  [ "$(echo "$output" | jq -c '.changed_files')" = '["helper.py","src/nested.py"]' ]
  [ "$(echo "$output" | jq -c '.delta_files')" = '["helper.py","src/nested.py"]' ]
  # the two carries are echoed through for the panel
  [ "$(echo "$output" | jq -r .fix_verification_path)" = "/tmp/verify-3.json" ]
  [ "$(echo "$output" | jq -r .adjudicated_path)" = "/tmp/adjudicated.json" ]
}

@test "plan: #1434 --final makes a late round a FULL sweep, and still reports the delta" {
  echo "print(1)" > "$R/app.py"
  local t1; t1="$(tree_id)"
  echo "print(2)" > "$R/helper.py"
  plan '{"languages":["python"]}' --round 4 --final --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "full" ]
  # the closing sweep re-reads the WHOLE story diff...
  [ "$(echo "$output" | jq -c '.changed_files')" = '["app.py","helper.py"]' ]
  # ...and delta_files is still computed, because the loop needs it to
  # invalidate adjudications whose file the last fix pass touched
  [ "$(echo "$output" | jq -c '.delta_files')" = '["helper.py"]' ]
}

@test "plan: #1434 a round past the first with neither --prior-tree nor --final is a usage error" {
  echo "print(1)" > "$R/app.py"
  plan '{"languages":["python"]}' --round 3
  [ "$status" -eq 2 ]
  # named, so the caller can fix it — and emphatically NOT a silent fallback to
  # the full diff, which would report scope_mode "delta" while reviewing
  # everything
  echo "$output" | grep -q -- '--prior-tree'
}

@test "plan: #1434 an unresolvable --prior-tree exits 1 with a named line and NO descriptor" {
  echo "print(1)" > "$R/app.py"
  # --separate-stderr, because the point is that STDOUT is empty: with the two
  # streams merged the diagnostic itself would satisfy a naive output check
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main --round 3 \
    --prior-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  [ "$status" -eq 1 ]
  # stdout carries no descriptor at all — a caller must never get a scope here
  [ -z "$output" ]
  echo "$stderr" | grep -q -- '--prior-tree does not resolve to a tree'
}

@test "plan: #1434 a delta with no new work is an EMPTY scope at exit 0, flagged scope_empty" {
  echo "print(1)" > "$R/app.py"
  local t1; t1="$(tree_id)"
  plan '{"languages":["python"]}' --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "delta" ]
  [ "$(echo "$output" | jq -c '.changed_files')" = '[]' ]
  [ "$(echo "$output" | jq -r .scope_empty)" = "true" ]
  # all three delta fields pinned together: changed_files and delta_files are
  # assigned from one variable today, so asserting only the first would survive
  # a refactor that split them — and the loop reads delta_files independently
  [ "$(echo "$output" | jq -c '.delta_files')" = '[]' ]
  [ "$(echo "$output" | jq -r .prior_tree)" = "$t1" ]
}

@test "plan: #1434 a blank --prior-tree is refused, in BOTH spellings" {
  # The realistic slip is `--prior-tree "$(cat tree-1.txt)"` with the file
  # absent, which yields the EMPTY string — so a guard keyed on the value alone
  # short-circuits and accepts exactly the shape it exists to catch. On a
  # --final round nothing about the scope would look wrong; delta_files would
  # simply go null and the loop would stop invalidating adjudications, leaving a
  # waived suggestion suppressed in a file the last fix pass had just edited.
  echo "print(1)" > "$R/app.py"
  # the EMPTY string is caught by the shared `need_value` (its non-empty arm),
  # which every value flag now goes through...
  plan '{"languages":["python"]}' --round 4 --final --prior-tree ''
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--prior-tree requires a non-empty value'
  # ...and a whitespace-only value, which `need_value` cannot see, by this
  # flag's own blank guard. Both exit 2; neither degrades to a null delta.
  plan '{"languages":["python"]}' --round 4 --final --prior-tree '   '
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--prior-tree requires a non-blank value'
  # positive control: a real identity on the same invocation yields a delta
  local t1; t1="$(tree_id)"
  echo "print(2)" > "$R/helper.py"
  plan '{"languages":["python"]}' --round 4 --final --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.delta_files')" = '["helper.py"]' ]
}

@test "plan: #1434 round 0 keeps changed_files an ARRAY, not the delta's null" {
  # --round is contracted as any non-negative integer, and 0 satisfies neither
  # `== 1` nor --final. Scoped as a delta it would emit changed_files: null —
  # `null | length` is 0, so scope_empty would even say true — where the
  # descriptor contract promises an array a consumer may iterate.
  echo "print(1)" > "$R/app.py"
  plan '{"languages":["python"]}' --round 0
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "full" ]
  [ "$(echo "$output" | jq -r '.changed_files | type')" = "array" ]
  [ "$(echo "$output" | jq -c '.changed_files')" = '["app.py"]' ]
}

@test "plan: #1434 a failed delta computation is exit 1, never an empty scope" {
  # The #910 rule, one round later: a git failure while computing the delta must
  # FAIL the scope. Degrading to [] would hand the loop an unreviewed round it
  # can promote to a closing sweep and converge on.
  echo "print(1)" > "$R/app.py"
  local t1; t1="$(tree_id)"
  echo "print(2)" > "$R/helper.py"
  # a git wrapper that works for everything except diff-tree
  local fakegit="$BATS_TEST_TMPDIR/git-no-difftree"
  cat > "$fakegit" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "diff-tree" ]; then echo "boom" >&2; exit 128; fi
done
exec git "$@"
EOF
  chmod +x "$fakegit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_BIN="$fakegit" zsh "$S" plan --repo "$R" --base main --round 3 --prior-tree "$t1"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- 'could not compute the delta against --prior-tree'
}

@test "plan: #1434 an unusable tree-id computation is exit 1 with a named line, never an empty delta" {
  # A git whose write-tree prints nothing. git-tree-id.zsh itself fails closed
  # on an empty identity (exit 1), so this lands on _delta_files' "could not
  # compute" arm rather than its "came back empty" one — the latter stays as
  # defence in depth for a future tree-id that exits 0 with no output, and is
  # deliberately not reachable through this seam. What matters either way is the
  # #910 rule: exit 1 with a named line, never a silently empty scope.
  echo "print(1)" > "$R/app.py"
  local t1; t1="$(tree_id)"
  echo "print(2)" > "$R/helper.py"
  local fakegit="$BATS_TEST_TMPDIR/git-empty-writetree"
  cat > "$fakegit" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "write-tree" ]; then exit 0; fi
done
exec git "$@"
EOF
  chmod +x "$fakegit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_BIN="$fakegit" zsh "$S" plan --repo "$R" --base main --round 3 --prior-tree "$t1"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- 'could not compute the current working-tree identity'
  echo "$stderr" | grep -q -- 'could not compute the delta against --prior-tree'
}

@test "plan: #1434 GIT_BIN reaches the tree-id sibling too — one override, every git call" {
  # The Seams header promises GIT_BIN is handed to git-tree-id.zsh, so a caller
  # that overrides it does not end up with two different git binaries computing
  # the two sides of the delta. Nothing else in this file exercises that.
  echo "print(1)" > "$R/app.py"
  local t1; t1="$(tree_id)"
  echo "print(2)" > "$R/helper.py"
  local log="$BATS_TEST_TMPDIR/git-calls.log"
  local fakegit="$BATS_TEST_TMPDIR/git-logging"
  cat > "$fakegit" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec git "\$@"
EOF
  chmod +x "$fakegit"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_BIN="$fakegit" zsh "$S" plan --repo "$R" --base main --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.delta_files')" = '["helper.py"]' ]
  # the delta's own diff went through the override...
  grep -q 'diff-tree' "$log"
  # ...and so did the tree-id computation on the other side of it, which only
  # happens if GIT_BIN is propagated as git-tree-id.zsh's own seam
  grep -q 'write-tree' "$log"
}

@test "plan: #1434 an artifact-only delta is empty too — the #909 exclusions still apply" {
  echo "print(1)" > "$R/app.py"
  local t1; t1="$(tree_id)"
  # the loop's OWN outputs must never become review scope, on a delta round any
  # more than on a full one — one file-listing path, one set of exclusions
  mkdir -p "$R/.review" "$R/.claude/telemetry"
  echo '[]' > "$R/.review/findings-round-2.json"
  echo '{}' > "$R/.claude/telemetry/telemetry.jsonl"
  plan '{"languages":["python"]}' --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.changed_files')" = '[]' ]
  [ "$(echo "$output" | jq -r .scope_empty)" = "true" ]
}

@test "plan: #1434 scope_empty is reported on a FULL round too, not only a delta one" {
  # The field is contracted as always present and independent of scope_mode.
  # Every other true-valued assertion in this file is on a delta round, so an
  # emitter narrowed to `scope_mode == "delta" and empty` would keep the suite
  # green while the caller-facing half of the contract silently went false.
  # An artifact-only change is the round-1 case that produces it (#909).
  mkdir -p "$R/.review"
  echo '[]' > "$R/.review/findings-round-1.json"
  plan '{"languages":["python"]}' --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "full" ]
  [ "$(echo "$output" | jq -c '.changed_files')" = '[]' ]
  [ "$(echo "$output" | jq -r .scope_empty)" = "true" ]
}

@test "scope-findings: #1434 still filters on the FULL story diff, never the delta" {
  # A fix-verification finding about a file changed earlier in the story but not
  # since the previous round is exactly what a delta round exists to surface;
  # filtering it by the delta would silently drop it, so scope-findings is never
  # handed --prior-tree.
  echo "print(1)" > "$R/app.py"          # in the story diff, not in any delta
  local t1; t1="$(tree_id)"
  echo "print(2)" > "$R/helper.py"
  local f="$BATS_TEST_TMPDIR/findings.json"
  printf '%s' '[{"severity":"WARNING","dimension":"bugs","file":"app.py","line":1,"title":"t","description":"d","reviewer":"r"}]' > "$f"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" scope-findings --repo "$R" --base main --findings "$f"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].file')" = "app.py" ]
}

# ---- unsupported / ambiguous repo type is a TYPED escalation, not a crash

@test "plan: unsupported repo type (rust/ts) exits 3 with a typed error" {
  # Was go/typescript until #872 gave Go a panel; the case still needs a pair
  # with no panel on either side, so it moved to rust/javascript.
  plan '{"languages":["rust","javascript"]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: a supported language alongside an unsupported one still dispatches (#872)" {
  # go+javascript is no longer the unsupported case: go has a panel, javascript
  # does not, so the single supported language wins rather than escalating.
  plan '{"languages":["go","javascript"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-go:review" ]
}

@test "plan: no detected languages exits 3 with a typed error" {
  plan '{"languages":[]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: multiple panels with no primary is an ambiguous typed error (exit 3)" {
  plan '{"languages":["python","java"]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
  echo "$output" | jq -e '.candidates | index("python") and index("java")' >/dev/null
}

@test "plan: .maintenance.yml primary disambiguates multiple panels" {
  printf 'primary: java\n' > "$R/.maintenance.yml"
  plan '{"languages":["python","java"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "java" ]
}

# ---- claude-plugin fallback repo_type (#809): a plugin repo detects no
# language, so is_claude_plugin selects the plugin panel — but ONLY as a
# fallback: a language always wins, and ambiguity is never defused by it.

@test "plan: #809 no language + is_claude_plugin maps to the plugin panel" {
  plan '{"languages":[],"is_claude_plugin":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-claude-plugin:review" ]
}

@test "plan: #809 a language always wins over the plugin fallback (no regression)" {
  plan '{"languages":["python"],"is_claude_plugin":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "python" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-python:review" ]
}

@test "plan: #809 no language and is_claude_plugin false stays a typed error" {
  plan '{"languages":[],"is_claude_plugin":false}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #809 absent is_claude_plugin key defaults to false, no crash" {
  # an older detect-stack that omits the key must fall through cleanly
  plan '{"languages":[]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #809 the plugin fallback does not defuse language ambiguity" {
  plan '{"languages":["python","java"],"is_claude_plugin":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
}

# ---- kubernetes fallback repo_type (#1153): a GitOps repo detects no language
# either — its content is charts, overlays and Argo CD resources. Same fallback
# rules as claude-plugin, plus an ORDERING rule between the two.

@test "plan: #1153 no language + is_kubernetes maps to the kubernetes panel" {
  plan '{"languages":[],"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "kubernetes" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-kubernetes:review" ]
}

@test "plan: #1153 a language always wins over the kubernetes fallback" {
  # the language-first principle: a Go service whose repo also carries a Helm
  # chart is reviewed by the Go panel, not the manifest panel
  plan '{"languages":["go"],"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "go" ]
  # .review_skill too, not just .repo_type: it is the field the orchestrator
  # actually invokes, and the #809 twin above asserts both
  [ "$(echo "$output" | jq -r .review_skill)" = "development-go:review" ]
}

@test "plan: #1153 an UNSUPPORTED language DOES block the kubernetes fallback" {
  # the asymmetry that keeps the manifest panel from reviewing application code.
  # `supported` is empty both for a language-less GitOps repo AND for a
  # JavaScript service, and `is_kubernetes` composes with any language — so a
  # JS/TS service shipping its own Helm chart (an ordinary shape) would be
  # handed to the manifest panel for a story whose diff is JS. That panel has no
  # competence there: it converges finding-free and the loop records a clean
  # review that never happened. Such a repo must keep the typed escalation,
  # which names the languages so a human can route it.
  plan '{"languages":["javascript"],"is_kubernetes":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
  [ "$(echo "$output" | jq -e '.languages | index("javascript") != null')" = "true" ]
}

@test "plan: #1153 an UNSUPPORTED language does NOT block the claude-plugin fallback" {
  # the deliberate asymmetry with the case above, pinned so the two cannot be
  # "harmonised" by mistake: a `.claude-plugin/plugin.json` is definitional for
  # what the repo IS, and a plugin repo carrying one unsupported-language file
  # is still a plugin repo. A Chart.yaml is routinely incidental to an
  # application repo, which is why kubernetes needs the stricter gate.
  plan '{"languages":["rust"],"is_claude_plugin":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
}

@test "plan: #1153 claude-plugin still wins when a language is detected AND both markers fire" {
  # the ordering rule survives the stricter kubernetes gate: with a language
  # present, kubernetes is excluded outright and claude-plugin still applies
  plan '{"languages":["rust"],"is_claude_plugin":true,"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
}

@test "plan: #1153 a fallback primary does NOT defuse language ambiguity" {
  # both the script and ARCHITECTURE state "neither fallback ever joins the
  # ambiguity tiebreak", but every other fallback test here runs with no
  # .maintenance.yml — so the branch where _primary actually returns a value is
  # exercised only for LANGUAGE primaries. The tempting "improvement" (teach
  # _primary to accept the fallback tokens so a GitOps repo can declare its
  # panel) passes every other test in this file while silently pointing an
  # ambiguous polyglot repo at the manifest panel.
  printf 'primary: kubernetes\n' > "$R/.maintenance.yml"
  plan '{"languages":["python","java"],"is_kubernetes":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
  [ "$(echo "$output" | jq -r .primary)" = "kubernetes" ]
}

@test "plan: #1153 a claude-plugin primary does not defuse ambiguity either" {
  # mirrored so the two fallbacks cannot drift apart — the precedent this file
  # already sets for every other fallback rule
  printf 'primary: claude-plugin\n' > "$R/.maintenance.yml"
  plan '{"languages":["python","java"],"is_claude_plugin":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
}

@test "plan: #1153 a single supported language wins before primary is consulted" {
  # the single-supported-language branch precedes _primary entirely, so a
  # declared kubernetes primary cannot override a detected Go service
  printf 'primary: kubernetes\n' > "$R/.maintenance.yml"
  plan '{"languages":["go"],"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "go" ]
}

@test "plan: #1153 the REAL detect-stack drives the kubernetes fallback end-to-end" {
  # every other case here stubs detect-stack via DETECT_STACK_BIN, so the
  # producer's key name and the consumer's jq path are pinned INDEPENDENTLY —
  # rename `.is_kubernetes` in both the script and this file's stub fixtures and
  # both suites stay green while every real GitOps repo escalates as
  # unsupported_repo_type (silently: the `// false` default degrades, it does not
  # crash). This one un-stubbed case is what joins the two halves.
  mkdir -p "$R/charts/app"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$R/charts/app/Chart.yaml"
  run env -u DETECT_STACK_BIN zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "kubernetes" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-kubernetes:review" ]
}

@test "plan: #1153 every repo_type the dispatcher can emit names a shipped review skill" {
  # review_skill is SYNTHESISED as development-${repo_type}:review, so a renamed
  # or typo'd panel directory is caught by no assertion in either suite — every
  # test here compares the synthesised string to another string.
  #
  # The language half is DERIVED from the script, so a seventh panel language
  # added there is swept automatically rather than leaving this test's title
  # false — the very failure mode it exists to prevent one level down. The two
  # fallbacks stay literal: they are not in that loop, and naming them here is
  # what documents them as the complete fallback set.
  local langs t
  langs="$(sed -n 's/^  for l in \(.*\); do$/\1/p' "$S")"
  [ -n "$langs" ]
  [ "$(printf '%s\n' "$langs" | wc -w | tr -d ' ')" -eq 4 ]
  for t in $langs claude-plugin kubernetes; do
    [ -f "$REPO_ROOT/development-$t/skills/review/SKILL.md" ]
    # and each panel's skill really is named `review`, or the synthesised
    # `development-<type>:review` resolves to nothing
    grep -qx 'name: review' "$REPO_ROOT/development-$t/skills/review/SKILL.md"
  done
}

@test "plan: #1153 the fallback branch never consults .maintenance.yml primary" {
  # the branch the fallbacks actually live in — zero SUPPORTED languages. The
  # tempting "let a GitOps repo declare its panel" change would teach _primary
  # to be consulted here, and every other test in this file would stay green
  # while `primary: python` on a repo with no Python routed review to
  # development-python:review.
  printf 'primary: python\n' > "$R/.maintenance.yml"
  plan '{"languages":[],"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "kubernetes" ]
}

@test "plan: #1153 claude-plugin WINS when both fallback markers fire" {
  # not hypothetical: a plugin repo that also carries Kubernetes content fires
  # both markers, and THIS repo becomes exactly that once #1155 lands its
  # fixtures under tests/fixtures/. Reversing the branch order would then point
  # this repo's own review loop at a manifest panel.
  plan '{"languages":[],"is_claude_plugin":true,"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-claude-plugin:review" ]
}

@test "plan: #1153 no language and is_kubernetes false stays a typed error" {
  plan '{"languages":[],"is_claude_plugin":false,"is_kubernetes":false}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #1153 absent is_kubernetes key defaults to false, no crash" {
  # an older detect-stack that omits the key must fall through cleanly, exactly
  # as #809's absent-key case does
  plan '{"languages":[],"is_claude_plugin":false}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #1153 the kubernetes fallback does not defuse language ambiguity" {
  plan '{"languages":["python","java"],"is_kubernetes":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
}

# ---- scope-findings: findings outside the story's diff do not appear

@test "scope-findings: drops findings in untouched files, keeps in-diff ones" {
  echo "print(1)" > "$R/app.py"         # the story touches only app.py
  cat > "$R/findings.json" <<'EOF'
[
  {"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"in-diff"},
  {"severity":"WARNING","dimension":"code_quality","file":"legacy.py","line":3,"title":"out-of-diff"},
  {"severity":"SUGGESTION","dimension":"tests","file":"./app.py","line":1,"title":"in-diff-dot"}
]
EOF
  run env GIT_BIN=git zsh "$S" scope-findings --repo "$R" --base main --findings "$R/findings.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  echo "$output" | jq -e 'all(.[]; .title != "out-of-diff")' >/dev/null
}

@test "scope-findings: missing findings file yields an empty array" {
  run zsh "$S" scope-findings --repo "$R" --base main --findings "$R/absent.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

# ---- usage

@test "plan: --repo is required (usage error, exit 2)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --base main
  [ "$status" -eq 2 ]
}

@test "no subcommand is a usage error (exit 2)" {
  run zsh "$S"
  [ "$status" -eq 2 ]
}

@test "unknown subcommand is a usage error (exit 2)" {
  run zsh "$S" frobnicate
  [ "$status" -eq 2 ]
}

# ---- loop-artifact exclusion (#909): the loop's own outputs never enter scope

@test "plan: .review/ and .claude/telemetry/ artifacts are excluded from changed_files" {
  # simulate a prior run's artifacts (untracked) alongside a real story file
  mkdir -p "$R/.review" "$R/.claude/telemetry"
  echo '[]' > "$R/.review/findings-round-1.json"
  echo '{}' > "$R/.claude/telemetry/telemetry.jsonl"
  echo "print(1)" > "$R/app.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.changed_files | index("app.py")' >/dev/null
  echo "$output" | jq -e '.changed_files | map(select(startswith(".review/"))) | length == 0' >/dev/null
  echo "$output" | jq -e '.changed_files | map(select(startswith(".claude/telemetry/"))) | length == 0' >/dev/null
}

@test "plan: the exclusion is start-anchored — nested/lookalike paths stay in scope" {
  # a nested .review dir inside story code, and a top-level lookalike file,
  # are legitimate story files — only the repo-root artifact dirs are excluded
  mkdir -p "$R/src/.review"
  echo "cfg" > "$R/src/.review/config.json"
  echo "notes" > "$R/.review-notes.md"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.changed_files | index("src/.review/config.json")' >/dev/null
  echo "$output" | jq -e '.changed_files | index(".review-notes.md")' >/dev/null
}

@test "plan: a scope that is ONLY artifacts yields empty changed_files, not an error" {
  mkdir -p "$R/.review"
  echo '[]' > "$R/.review/findings-round-1.json"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.changed_files == []' >/dev/null
}

@test "scope-findings: a finding filed against a loop artifact is dropped" {
  mkdir -p "$R/.review"
  echo '[]' > "$R/.review/findings-round-1.json"
  echo "print(1)" > "$R/app.py"
  F="$BATS_TEST_TMPDIR/findings.json"
  cat > "$F" <<'JSON'
[{"severity":"CRITICAL","dimension":"bugs","file":".review/findings-round-1.json","line":1,"title":"bogus","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"real","description":"d","reviewer":"r"}]
JSON
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" scope-findings --repo "$R" --base main --findings "$F"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].file')" = "app.py" ]
}

# ---- base-ref validation (#910): a bad base must fail fast, never mis-scope

@test "plan: an unresolvable --base exits 1 naming the ref, not a degraded scope" {
  echo "print(1)" > "$R/app.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base refs/heads/does-not-exist
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'does-not-exist'
}

@test "scope-findings: an unresolvable --base exits 1, not a silently-empty scope" {
  echo "print(1)" > "$R/app.py"
  F="$BATS_TEST_TMPDIR/findings-910.json"
  echo '[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"t","description":"d","reviewer":"r"}]' > "$F"
  run zsh "$S" scope-findings --repo "$R" --base refs/heads/does-not-exist --findings "$F"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'does-not-exist'
}

@test "plan: a non-git --repo exits 1 naming the repo, not the ref" {
  NR="$BATS_TEST_TMPDIR/not-a-repo"; mkdir -p "$NR"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$NR" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'not a git repository'
  run ! grep -q 'does not resolve' <<< "$output"
}

@test "plan: #1153 an ABSENT .languages key still reaches the kubernetes fallback" {
  # the new lang_count read must degrade through `.languages // []` exactly as
  # the two marker reads degrade through `// false` — the same missing-key edge
  # this file already covers for is_claude_plugin and is_kubernetes
  plan '{"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "kubernetes" ]
}

@test "plan: #1153 an empty detect payload stays a typed escalation" {
  plan '{}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #1153 a malformed .languages FAILS CLOSED with the internal-error exit" {
  # the guard's own comment states the stakes: an unchecked `local -i` read would
  # fail OPEN — jq dying (or emitting nothing) would coerce to 0, exactly the
  # value that opens the kubernetes gate, handing a language-bearing repo to the
  # manifest panel. Nothing exercised that branch, so replacing the guards with
  # `local -i lang_count=$(...)` left every other test in this file green.
  # A boolean has no `length`, so jq errors here.
  plan '{"languages":true,"is_kubernetes":true}'
  [ "$status" -eq 1 ]
  # and emphatically NOT a successful kubernetes dispatch
  [ "$(echo "$output" | jq -r '.repo_type // "none"' 2>/dev/null || echo none)" != "kubernetes" ]
  # WHICH guard fires moved with #1177: the probe loop now runs first and
  # `index($l)` on a boolean exits 5, so this fixture is caught there rather than
  # at lang_count. Asserting the message keeps the test honest about its subject
  # — and makes a future re-ordering visible instead of silent. The lang_count
  # guards have their own shim test above.
  echo "$output" | grep -q 'could not test the detected-language set'
}

# ---- #1177: the three marker reads, and the argument parsers ----------------
#
# The three `jq` reads that build langs_json / is_plugin / is_k8s already failed
# CLOSED — an empty value matches neither "true" nor a language — so no misroute
# was ever reachable through them. What was wrong is the STATUS: the header
# contract promises exit 1 for an internal failure, and an unchecked read
# delivered the exit-3 typed escalation instead, telling the orchestrator to
# relay "no review panel exists for the detected languages" about a repo whose
# languages were never read. A jq that dies is a fact about the machine, not a
# verdict about the repo.
#
# Reaching it needs a failing jq, since `_detect_json` has already proved the
# payload parses — hence the PATH shim: a jq that fails for one filter and
# delegates every other call to the real binary.
jq_failing_on() {  # $1 = substring of the jq filter that should fail
  local shim_dir="$BATS_TEST_TMPDIR/shim-$$"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *'$1'*) exit 5 ;; esac
done
exec "$(command -v jq)" "\$@"
EOF
  chmod +x "$shim_dir/jq"
  printf '%s' "$shim_dir"
}

@test "plan: #1177 a failing .languages read is exit 1, not the typed escalation" {
  local shim; shim="$(jq_failing_on '.languages')"
  run env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '.languages'
  # NOT the exit-3 typed escalation about the repo. Asserted by its ABSENCE from
  # the payload rather than by re-testing the status, which -eq 1 already settled
  run ! grep -q 'unsupported_repo_type' <<< "$output"
}

@test "plan: #1177 a detect-stack that EXITS non-zero is exit 1, with its stderr relayed" {
  # nothing in THIS suite made the stub fail before, so both _detect_json failure
  # branches were uncovered while the path reaching them became newly reachable
  # in production (detect-stack gained its first non-zero exit in this change;
  # gather-docs-findings.zsh already branched on its status). The relay matters
  # as much as the
  # status: the named marker-search message IS the deliverable of the hardening,
  # and a generic "detect-stack failed" sends the operator back to re-run into
  # the same wall.
  local stub="$BATS_TEST_TMPDIR/detect-fail.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
echo "detect-stack: the kubernetes marker search did not complete (find exit 1, grep exit 2)" >&2
exit 2
EOF
  chmod +x "$stub"
  run env DETECT_STACK_BIN="$stub" zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'detect-stack failed'
  echo "$output" | grep -q 'did not complete'
  run ! grep -q 'unsupported_repo_type' <<< "$output"
}

@test "plan: #1177 a detect-stack emitting non-JSON is exit 1, not a typed escalation" {
  local stub="$BATS_TEST_TMPDIR/detect-garbage.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
echo "not json at all"
EOF
  chmod +x "$stub"
  run env DETECT_STACK_BIN="$stub" zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'could not parse detect-stack output'
}

@test "plan: #1177 a failing .is_claude_plugin read is exit 1, not the typed escalation" {
  local shim; shim="$(jq_failing_on '.is_claude_plugin')"
  run env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"is_claude_plugin":true}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'is_claude_plugin'
}

@test "plan: #1177 a failing .is_kubernetes read is exit 1, not the typed escalation" {
  local shim; shim="$(jq_failing_on '.is_kubernetes')"
  run env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"is_kubernetes":true}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'is_kubernetes'
}

@test "plan: #1177 an UNREADABLE --repo is named as such, not blamed on detect-stack" {
  # the gate's whole purpose: without it `cd` fails inside _detect_json and the
  # failure reads "detect-stack failed" — naming a script that never ran, with no
  # stderr to relay, which is the one non-zero exit the new relay cannot explain.
  # The sibling gather script carries exactly this test.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  local locked="$BATS_TEST_TMPDIR/locked-repo"
  mkdir -p "$locked"
  chmod 000 "$locked"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$locked" --base main
  chmod 755 "$locked"   # restore BEFORE asserting
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'not a readable directory'
  # and emphatically NOT the wrong culprit
  run ! grep -q 'detect-stack failed' <<< "$stderr"
}

@test "plan: #1177 a missing --repo directory exits 1 naming the directory" {
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$BATS_TEST_TMPDIR/does-not-exist" --base main
  [ "$status" -eq 1 ]
  echo "$stderr" | grep -q 'not a directory'
}

@test "scope-findings: #1177 an UNREADABLE --repo is named as such, not 'not a git repository'" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  local locked="$BATS_TEST_TMPDIR/locked-scope"
  mkdir -p "$locked"
  chmod 000 "$locked"
  run --separate-stderr zsh "$S" scope-findings --repo "$locked" --base main --findings /dev/null
  chmod 755 "$locked"
  [ "$status" -eq 1 ]
  # empty stdout too: scope-findings' success contract IS a JSON array on stdout,
  # so a rearrangement reaching the empty-findings shortcut before the gates would
  # print `[]`, and a caller reading stdout first would see "nothing in scope" for
  # a repo that was never scoped
  [ -z "$output" ]
  echo "$stderr" | grep -q 'not a readable directory'
  run ! grep -q 'not a git repository' <<< "$stderr"
}

@test "scope-findings: #1177 a missing --repo directory exits 1 naming the directory" {
  # the mirror of plan's twin: cmd_scope_findings gained BOTH gates, and the
  # script's own comment insists both subcommands name one cause with one
  # wording — but only the readability half was tested. Without `[[ -d ]]` a
  # nonexistent --repo is reported by _verify_base as "not a git repository":
  # a confident claim about a path that does not exist.
  run --separate-stderr zsh "$S" scope-findings \
    --repo "$BATS_TEST_TMPDIR/does-not-exist" --base main --findings /dev/null
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'not a directory'
  run ! grep -q 'not a git repository' <<< "$stderr"
}

@test "plan: #1177 a READABLE but non-traversable --repo is still rejected" {
  # the `-x` half of `[[ -r && -x ]]`. Every other fixture is chmod 000, which
  # falsifies BOTH operands — so narrowing the conjunction to `[[ -r ]]` (the
  # plausible "drop the redundant test" edit) would keep the whole suite green
  # while a mode-444 directory went back to failing inside `cd` and being
  # reported as "detect-stack failed", naming a script that never ran.
  if [ "$(id -u)" -eq 0 ]; then skip "root traverses any directory"; fi
  local ro="$BATS_TEST_TMPDIR/readable-not-traversable"
  mkdir -p "$ro"
  chmod 444 "$ro"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$ro" --base main
  chmod 755 "$ro"
  [ "$status" -eq 1 ]
  echo "$stderr" | grep -q 'not a readable directory'
  run ! grep -q 'detect-stack failed' <<< "$stderr"
}

@test "scope-findings: #1177 a READABLE but non-traversable --repo is still rejected" {
  if [ "$(id -u)" -eq 0 ]; then skip "root traverses any directory"; fi
  local ro="$BATS_TEST_TMPDIR/ro-scope"
  mkdir -p "$ro"
  chmod 444 "$ro"
  run --separate-stderr zsh "$S" scope-findings --repo "$ro" --base main --findings /dev/null
  chmod 755 "$ro"
  [ "$status" -eq 1 ]
  echo "$stderr" | grep -q 'not a readable directory'
  run ! grep -q 'not a git repository' <<< "$stderr"
}

@test "plan: #1177 the REAL detect-stack's failure is relayed end-to-end, unstubbed" {
  # every other failure fixture is a stub whose stderr this file itself invents,
  # so the producer's real wording and the consumer's relay are pinned
  # INDEPENDENTLY — the coupling this suite already refuses to leave unstated on
  # the success path ("the REAL detect-stack drives the kubernetes fallback
  # end-to-end"). If detect-stack ever wrote its diagnostic to stdout instead of
  # stderr, review-dispatch would report "could not parse detect-stack output"
  # and the named cause would vanish, with no test noticing.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$R/locked"
  chmod 000 "$R/locked"
  run --separate-stderr env -u DETECT_STACK_BIN zsh "$S" plan --repo "$R" --base main
  chmod 755 "$R/locked"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # the consumer's frame AND the producer's own wording, which this test did not author
  echo "$stderr" | grep -q 'detect-stack failed'
  echo "$stderr" | grep -q 'did not complete'
  run ! grep -q 'unsupported_repo_type' <<< "$stderr"
}

@test "plan: #1177 a detect-stack aborting with a NON-2 status is still handled and relayed" {
  # every other failure fixture exits 2, so narrowing `(( rc != 0 ))` to
  # `(( rc == 2 ))` — the enum-read-literally mistake both the script header and
  # ARCHITECTURE.md single out — would keep them all green. detect-stack runs
  # under `set -euo pipefail`, so an internal abort really does exit 1 with the
  # same empty stdout.
  local stub="$BATS_TEST_TMPDIR/detect-abort1.sh"
  printf '#!/usr/bin/env bash\necho "detect-stack: internal abort under errexit" >&2\nexit 1\n' > "$stub"
  chmod +x "$stub"
  run --separate-stderr env DETECT_STACK_BIN="$stub" zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$stderr" | grep -q 'detect-stack failed'
  # the RELAY is what distinguishes the rc != 0 branch from a fall-through: the
  # status alone would be 1 either way
  echo "$stderr" | grep -q 'internal abort under errexit'
  [ -z "$output" ]
}

@test "plan: #1177 an ordinary relative --repo is NOT rewritten into the descriptor" {
  # only a dash-prefixed path needs normalising; rewriting every relative
  # spelling put `././` into findings_path for the ordinary `--repo .`
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    bash -c "cd '$R' && zsh '$S' plan --repo . --base main"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .findings_path)" = "./.review/findings-round-1.json" ]
}

@test "plan: #1177 a failing lang_count read is exit 1 and does NOT open the kubernetes gate" {
  # the malformed-.languages test below no longer reaches this guard: the newer
  # probe_rc check short-circuits on the same fixture. Both lang_count guards
  # exist to fail CLOSED on the kubernetes fallback (an empty value
  # arithmetic-evaluates to 0, the value that OPENS the gate), so they need a
  # fixture of their own or a regression to `local -i lang_count=$(…)` would hand
  # a language-bearing repo to the manifest panel with the suite green.
  local shim; shim="$(jq_failing_on 'length')"
  run env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":[],"is_kubernetes":true}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  # the `plan: ` PREFIX, not just the message body (#1504): `_repo_type` is
  # shared, and its diagnostics take the caller's name from `ctx`. Asserting the
  # body alone leaves that parameter free to be dropped or mis-passed.
  echo "$output" | grep -q 'plan: could not compute the detected-language count'
  run ! grep -q 'kubernetes' <<< "$output"
}

@test "plan: #1177 a failing mktemp DEGRADES the stderr relay, it does not fail the plan" {
  # the buffer exists only to forward a diagnostic and is never needed on the
  # success path, so an unwritable TMPDIR must not fail a repo that plans fine.
  # Tightening this to `|| exit 1` — the obvious "don't ignore errors" cleanup —
  # would ship green without this test.
  local shim="$BATS_TEST_TMPDIR/shim-mktemp"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/mktemp"
  chmod +x "$shim/mktemp"
  # --separate-stderr: the warning goes to stderr and the descriptor to stdout,
  # and the descriptor must stay parseable JSON — a merged stream would put the
  # warning line inside it, which is itself the thing to guard against
  run --separate-stderr env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "python" ]
  echo "$stderr" | grep -q 'stderr will not be relayed'
}

@test "plan: #1177 with no buffer, a detect-stack failure is still reported" {
  # the other half of the degrade fork: without an err_file there is nothing to
  # relay, but the failure itself must still surface with the documented status
  local shim="$BATS_TEST_TMPDIR/shim-mktemp2"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/mktemp"
  chmod +x "$shim/mktemp"
  local stub="$BATS_TEST_TMPDIR/detect-fail2.sh"
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$stub"
  chmod +x "$stub"
  run env PATH="$shim:$PATH" DETECT_STACK_BIN="$stub" zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'detect-stack failed'
}

@test "scope-findings: #1177 a --repo beginning with a dash is scoped, not misattributed" {
  # the plan half has this test; the scope-findings copy of the normalisation had
  # none, so deleting it left the suite green while the path that decides which
  # findings survive the round failed with "not a git repository"
  local dashrepo="$BATS_TEST_TMPDIR/-dash-scope"
  mkdir -p "$dashrepo"
  git -C "$dashrepo" init -q
  git -C "$dashrepo" config user.email t@example.com
  git -C "$dashrepo" config user.name tester
  echo old > "$dashrepo/app.py"
  git -C "$dashrepo" add -A
  git -C "$dashrepo" commit -qm base
  git -C "$dashrepo" branch -M main
  echo new > "$dashrepo/app.py"
  local findings="$BATS_TEST_TMPDIR/f.json"
  printf '[{"file":"app.py","title":"x"},{"file":"other.py","title":"y"}]\n' > "$findings"
  run bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$S' scope-findings --repo -dash-scope --base main --findings '$findings'"
  [ "$status" -eq 0 ]
  # the LENGTH, not just the status: a regression returning [] for everything
  # would pass a status-only assertion
  [ "$(echo "$output" | jq 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.[0].file')" = "app.py" ]
}

@test "scope-findings: #1177 an unparseable findings file names the file, at exit 1" {
  # reachable with no shim at all, and previously unpinned
  local findings="$BATS_TEST_TMPDIR/garbage.json"
  printf 'not json\n' > "$findings"
  run zsh "$S" scope-findings --repo "$R" --base main --findings "$findings"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'could not parse findings JSON'
}

@test "plan: #1177 a failing changed-files encode names ITS step, not the emitter's" {
  # the last pair of checked jq calls without a fixture. With the guard removed
  # an empty changed_json reaches `--argjson changed ''`, jq rejects it, and the
  # failure surfaces as "could not emit the dispatch descriptor" — a message
  # naming the wrong step, the misattribution class this whole change removes.
  # `-R` reaches only the changed-files encode on a single-language plan (the
  # candidate encode is unreachable on that branch).
  local shim; shim="$(jq_failing_on '-R')"
  run env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'could not compute changed files'
}

@test "scope-findings: #1177 a failing changed-files encode names ITS step too" {
  local shim; shim="$(jq_failing_on '-R')"
  local findings="$BATS_TEST_TMPDIR/some.json"
  printf '[{"file":"legacy.py","title":"x"}]\n' > "$findings"
  run env PATH="$shim:$PATH" zsh "$S" scope-findings --repo "$R" --base main --findings "$findings"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'could not compute changed files'
}

@test "plan: #1177 a failing candidate-list encode is exit 1, not a payload-less exit 3" {
  # the ambiguous branch builds its candidate array with `jq -R . | jq -sc .`.
  # Unchecked, a failure leaves `--argjson cand ''`, jq rejects it, and the
  # `exit 3` still runs — the orchestrator is told to escalate and handed nothing
  # to relay. The shim fails the FIRST `-sc` call, which is that encode.
  local shim; shim="$(jq_failing_on '-sc')"
  run env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python","java"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'could not encode the candidate list'
  run ! grep -q 'ambiguous_repo_type' <<< "$output"
}

@test "plan: #1177 a failing ambiguity emitter is exit 1, not a silent exit 3" {
  # without its guard the script exits 3 having printed NOTHING — a typed
  # escalation the orchestrator cannot relay, which is the failure class this
  # whole change set out to remove
  local shim; shim="$(jq_failing_on 'ambiguous_repo_type')"
  run env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python","java"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'could not emit the ambiguous-repo-type error'
}

@test "plan: #1177 a failing descriptor emitter is exit 1, emphatically not jq's 5" {
  # the emitter is the last command of the last function, so unchecked it leaves
  # jq's own status as the script's — a code outside the documented set {0,1,2,3}
  # that the orchestrator cannot map to internal-error vs typed-escalation
  local shim; shim="$(jq_failing_on 'review_skill')"
  run env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  # `-eq 1` already rules out jq's 5 — a second `-ne 5` could never fail
  # independently, and this file's standard is that every assertion discriminates
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'could not emit the dispatch descriptor'
}

@test "plan: #1177 a --repo beginning with a dash is planned, not blamed on detect-stack" {
  # `[[ -d ]]` passes for `-dash-repo` (test operators parse no options) but `cd`
  # reads it as a flag, so without the ./ normalisation the run fails with
  # "detect-stack failed" — naming the wrong culprit entirely. The sibling
  # gather script carries exactly this test.
  local dashrepo="$BATS_TEST_TMPDIR/-dash-repo"
  mkdir -p "$dashrepo"
  git -C "$dashrepo" init -q
  git -C "$dashrepo" config user.email t@example.com
  git -C "$dashrepo" config user.name tester
  echo base > "$dashrepo/README.md"
  git -C "$dashrepo" add -A
  git -C "$dashrepo" commit -qm base
  git -C "$dashrepo" branch -M main
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$S' plan --repo -dash-repo --base main"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "python" ]
}

@test "plan: #1177 a value-taking flag in last position is the usage exit, not a nounset abort" {
  # the script runs under `setopt nounset`, so reading "$2" of an absent value
  # aborted raw: exit 1 with a zsh diagnostic naming its own internals, where
  # the contract documents exit 2 and a message naming the flag. A caller that
  # distinguishes "you called me wrong" from "something broke" was told the
  # wrong one.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main --round
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--round requires a value'
}

@test "plan: #1177 every value-taking plan flag checks its value" {
  # one flag proving the pattern would let the others keep the raw abort — so
  # the list must be the WHOLE flag set, and #1434 added three more to it
  # (--prior-tree, --fix-verification, --adjudicated). Without them, deleting
  # need_value from any of the three re-introduces the exact #1177 regression
  # (a nounset abort at exit 1 where the contract documents exit 2) with the
  # whole suite green.
  local flag
  for flag in --repo --base --round --findings-path \
              --prior-tree --fix-verification --adjudicated; do
    run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
      zsh "$S" plan "$flag"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q -- "$flag requires a value"
    # ...and the FLAG-SHAPED value, the realistic unquoted `--flag $VAR` with
    # VAR unset. Without this arm the next flag is swallowed as the value:
    # `--prior-tree --final` plans a delta and then fails inside
    # _verify_prior_tree at exit 1 (internal error) with "does not resolve to a
    # tree: --final" — the wrong code AND a confidently wrong cause.
    run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
      zsh "$S" plan --repo "$R" --base main "$flag" --final
    [ "$status" -eq 2 ]
    echo "$output" | grep -q -- "$flag requires a value (got the flag --final)"
    # ...and an explicitly empty one, which reads downstream as "flag omitted"
    run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
      zsh "$S" plan --repo "$R" --base main "$flag" ''
    [ "$status" -eq 2 ]
    echo "$output" | grep -q -- "$flag requires a non-empty value"
  done
}

@test "scope-findings: #1177 its parser checks flag values too" {
  local flag
  for flag in --repo --base --findings; do
    run zsh "$S" scope-findings "$flag"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q -- "$flag requires a value"
  done
}

@test "plan: #1177 a non-numeric --round is rejected at parse time" {
  # unvalidated, it reached jq as `--argjson round abc` — a jq parse error at
  # the very END of an otherwise successful plan, long after the typo, and with
  # a message about JSON rather than about the flag
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main --round abc
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- '--round must be a non-negative integer'
}

@test "plan: #1177 a negative --round is rejected too, and a numeric one still works" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main --round -2
  [ "$status" -eq 2 ]
  # the positive control: the guard must not reject the values the loop passes
  # (--final keeps this on the --round guard, not on #1434's scoping rule)
  plan '{"languages":["python"]}' --round 7 --final
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .round)" = "7" ]
}

@test "plan: #1434 an over-wide --round is rejected by WIDTH, and 18 digits still pass" {
  # A 19/20-digit value passes the `<->` class but WRAPS in the arithmetic
  # normalisation below it: the round goes negative, `round <= 1` forces
  # scope_mode "full" (a caller asking for a delta silently gets the whole
  # story diff), and the sink is minted as
  # findings-round--7766279631452241920.json. The three siblings in this
  # family (--issue, --max-rounds, .closing-sweep) all carry the same cap.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main --round 99999999999999999999 --final
  [ "$status" -eq 2 ]
  # the WIDTH wording specifically: the digits-only refusal shares the prefix,
  # so asserting on `--round` alone would pass with the cap deleted
  echo "$output" | grep -q -- 'at most 18 digits'
  # the positive control pins the cap's SIZE, not merely its existence
  plan '{"languages":["python"]}' --round 999999999999999999 --final
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .round)" = "999999999999999999" ]
}

@test "plan: #1177 a zero-padded --round is NORMALISED, not passed to --argjson" {
  # `007` passes the non-negative-integer pattern but is not valid JSON, so
  # `--argjson round 007` would fail with jq's exit 5 at the very end of an
  # otherwise successful plan — the late, misattributed failure the parse-time
  # check exists to prevent, and a status outside the documented set {0,1,2,3}.
  # Normalising also stops findings-round-007.json becoming a second, colliding
  # artifact path for round 7.
  plan '{"languages":["python"]}' --round 007 --final
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .round)" = "7" ]
  [ "$(echo "$output" | jq -r .findings_path)" = "$R/.review/findings-round-7.json" ]
}

# NOTE (updated #1177): the lang_count READ now has its own shim test above
# ("a failing lang_count read is exit 1 and does NOT open the kubernetes gate"),
# because the probe guard added in #1177 short-circuits the malformed-.languages
# fixture that used to reach it. What follows still applies to the NUMERIC half.
#
# No companion test for the `[[ "$lang_count" == <-> ]]` half. Every
# SINGLE-DOCUMENT input reachable through this seam that jq accepts yields one
# number (an object's length is 1, a string's is its length), so an assertion
# built on one would behave identically with the guard removed — an inert test,
# which is worse than no test. The guard IS reachable via a multi-document
# payload (`{...} {...}` survives `jq -c .` and makes `jq 'length'` emit two
# lines), but that requires a detect-stack emitting a JSON stream, which nothing
# in the family does; the numeric check stands as defence-in-depth for it and
# for a jq that succeeds while emitting nothing. The case above covers the
# reachable failure.

# ---- detect: plan's repo-type half, with the diff work removed (#1504) ------
#
# The resolve-issue conductor calls this at its §1b step to load
# `development-<repo_type>:resolve-profile`, where the branch is still empty and
# a diff would be pure waste. The contract that matters is that it can never
# disagree with `plan` — same detector, same fallback ordering, same exit codes —
# so the agreement property below is the load-bearing test here, not the shape.

detect() {  # $1 = languages json ; rest = extra flags
  local langs="$1"; shift
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON="$langs" \
    zsh "$S" detect --repo "$R" "$@"
}

@test "detect: #1504 emits ONLY repo_type, and nothing else" {
  detect '{"languages":["python"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "python" ]
  # the whole document, not merely a document containing the key: a detect that
  # quietly echoed plan's descriptor would satisfy a repo_type check alone.
  [ "$(echo "$output" | jq -r 'keys | join(",")')" = "repo_type" ]
}

@test "detect: #1504 the claude-plugin fallback reaches it too" {
  detect '{"languages":[],"is_claude_plugin":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
}

@test "detect: #1504 agrees with plan on the same repo — one detector, not two" {
  # THE property. `plan` (§3.5) and `detect` (§1b) run at different points of one
  # run, so a second detector would let a story be profiled as one type and
  # reviewed as another, with nothing to say so. Exercised across the fallback
  # branches, not just the single-language happy path.
  local langs from_plan from_detect
  for langs in '{"languages":["python"]}' \
               '{"languages":["go"]}' \
               '{"languages":[],"is_claude_plugin":true}' \
               '{"languages":[],"is_kubernetes":true}'; do
    plan "$langs"
    [ "$status" -eq 0 ] || { echo "plan failed for $langs: $output"; return 1; }
    from_plan="$(echo "$output" | jq -r .repo_type)"
    detect "$langs"
    [ "$status" -eq 0 ] || { echo "detect failed for $langs: $output"; return 1; }
    from_detect="$(echo "$output" | jq -r .repo_type)"
    [ "$from_plan" = "$from_detect" ] || {
      echo "$langs: plan says $from_plan, detect says $from_detect"; return 1; }
  done
}

@test "detect: #1504 an unsupported repo type is plan's TYPED error, exit 3" {
  detect '{"languages":["rust"]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
  [ "$(echo "$output" | jq -r '.languages | join(",")')" = "rust" ]
}

@test "detect: #1504 an ambiguous repo type is plan's TYPED error, exit 3" {
  detect '{"languages":["python","go"]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
}

@test "detect: #1504 a dangling --repo is a usage error (exit 2), not a crash" {
  run zsh "$S" detect --repo
  [ "$status" -eq 2 ]
  contains "$output" "detect: --repo requires a value"
}

@test "detect: #1504 --repo is required (usage error, exit 2)" {
  run zsh "$S" detect
  [ "$status" -eq 2 ]
  contains "$output" "detect: --repo is required"
}

@test "detect: #1504 --base is REFUSED — there is no diff surface here" {
  # Not a stylistic assertion: accepting and ignoring --base would let a caller
  # believe it had scoped something. A flag this subcommand does not have is a
  # usage error like any other.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" detect --repo "$R" --base main
  [ "$status" -eq 2 ]
  contains "$output" "detect: unknown flag: --base"
}

@test "detect: #1504 a --repo naming nothing is exit 1, not a silent type" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" detect --repo "$BATS_TEST_TMPDIR/no-such-dir"
  [ "$status" -eq 1 ]
  contains "$output" "detect: --repo not a directory"
}

@test "detect: #1504 _repo_type's OWN diagnostics take the caller's name" {
  # THE `ctx` seam. `_repo_type` was lifted out of cmd_plan and is shared, and
  # its header states the reason for the parameter: "every diagnostic RAISED
  # HERE still says which invocation failed — the one thing lifting this out of
  # cmd_plan could lose." Nothing asserted it until #1504's closing sweep.
  #
  # The fixture matters. An unparseable detect-stack fails inside `_detect_json`,
  # whose three messages deliberately keep the script-wide `review-dispatch:`
  # prefix and never touch `ctx` — so a `lacks "…" "plan:"` on THAT path is
  # tautological: no mutation of `ctx` could make it fire. Reach a `${ctx}:`
  # message instead, through the jq shim, and assert the prefix POSITIVELY.
  #
  # Mutations this now catches, both of which left the whole suite green:
  #   * `_repo_type "$repo" plan` in cmd_detect — every detect failure blaming a
  #     subcommand that was never invoked;
  #   * deleting the `ctx` parameter and hard-coding the script-wide prefix,
  #     which is the entire rationale for the parameter.
  local shim; shim="$(jq_failing_on '.languages')"
  run --separate-stderr env PATH="$shim:$PATH" DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" detect --repo "$R"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'detect: could not read .languages'
  lacks "$stderr" "plan:"
}

@test "detect: #1504 a failing emitter is exit 1, not jq's 5" {
  # plan's identical guard is covered above; detect's was not. Without it a
  # failed emit leaks jq's exit 5 — a code outside the {0,1,2,3} set both the
  # script header and §1b's four-arm exit table document, leaving the session
  # with no branch for what it sees.
  local shim; shim="$(jq_failing_on 'repo_type')"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' PATH="${shim}:$PATH" \
    zsh "$S" detect --repo "$R"
  [ "$status" -eq 1 ]
  # the exit-1 contract is a stderr diagnostic AND an empty stdout — without
  # this, a guard that printed a placeholder document before exiting would pass.
  [ -z "$output" ]
  echo "$stderr" | grep -q 'could not emit the repo-type document'
}

@test "detect: #1504 is advertised in the usage string" {
  run zsh "$S" bogus-subcommand
  [ "$status" -eq 2 ]
  contains "$output" "expected plan|detect|scope-findings"
}

# ---- detect: the gaps round 1's test reviewer named (#1504) ----------------

@test "detect: #1504 an UNREADABLE --repo is named as such, not blamed on detect-stack" {
  # The sibling of the plan/scope-findings tests above. Without the `-r`/`-x`
  # gate, `cd` fails inside _detect_json and the operator is told
  # "detect-stack failed" — naming a script that never ran, with no stderr to
  # relay. Stream-separated, so the exit-1 contract (a stderr diagnostic, an
  # EMPTY stdout) is asserted rather than assumed: a `detect` that printed its
  # diagnostic on stdout would leave a caller parsing a non-document.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  local locked="$BATS_TEST_TMPDIR/locked-detect"
  mkdir -p "$locked"
  chmod 000 "$locked"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" detect --repo "$locked"
  chmod 755 "$locked"   # restore BEFORE asserting
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'not a readable directory'
  # `lacks`, NOT `grep -qv`: the latter passes whenever ANY line lacks the
  # needle, so it means "absent" only while stderr is exactly one line —
  # and the mutation this guards (degrading the gate to a warning that
  # continues) makes stderr two lines, one of which matches.
  lacks "$stderr" "detect-stack failed"
}

@test "detect: #1504 a READABLE-but-not-traversable --repo is caught by the -x half" {
  # Every other fixture is chmod 000, which falsifies BOTH operands — so
  # narrowing the conjunction to `[[ -r ]]` (the plausible "drop the redundant
  # test" edit) would keep the suite green while a mode-444 directory went back
  # to failing inside `cd`.
  if [ "$(id -u)" -eq 0 ]; then skip "root traverses any directory"; fi
  local ro="$BATS_TEST_TMPDIR/detect-readable-not-traversable"
  mkdir -p "$ro"
  chmod 444 "$ro"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" detect --repo "$ro"
  chmod 755 "$ro"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'not a readable directory'
}

@test "detect: #1504 a --repo beginning with a dash is detected, not misattributed" {
  # `cmd_detect` carries `if [[ "$repo" == -* ]]; then repo="./$repo"; fi`. Both
  # siblings gained a regression test for their copy precisely because deleting
  # it left the suite green. Without it a `--repo -weird` reaches `_primary`,
  # whose `grep -E … "$repo/.maintenance.yml"` reads the path as an option
  # bundle: the tiebreak silently vanishes and detect escalates exit 3 where
  # plan returns a type — breaking the one property this block calls
  # load-bearing.
  local dash="$BATS_TEST_TMPDIR/-detect-dash"
  mkdir -p "$dash"
  printf 'primary: go\n' > "$dash/.maintenance.yml"
  # RELATIVE, from inside the tmpdir: an absolute path never enters the
  # `[[ "$repo" == -* ]]` arm, so an absolute fixture leaves the normalisation
  # deletable with this test still green. The plan sibling above builds it this
  # way for exactly that reason.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python","go"]}' \
    bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$S' detect --repo -detect-dash"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "go" ]
}

@test "detect: #1504 agrees with plan on a DASH-named repo too" {
  # The agreement property above only ever exercises \$R, so it cannot see the
  # normalisation gap. This closes it on the fixture that has one.
  local dash="$BATS_TEST_TMPDIR/-agree-dash"
  mkdir -p "$dash"
  git -C "$dash" init -q
  git -C "$dash" config user.email t@example.com
  git -C "$dash" config user.name tester
  printf 'primary: java\n' > "$dash/.maintenance.yml"
  git -C "$dash" add -A
  git -C "$dash" commit -qm base
  git -C "$dash" branch -M main
  # Both invocations RELATIVE, from inside the tmpdir — with an absolute path
  # neither subcommand's dash arm is entered, and this degenerates into a
  # duplicate of the plain agreement property above.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["java","python"]}' \
    bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$S' plan --repo -agree-dash --base main"
  [ "$status" -eq 0 ]
  local from_plan; from_plan="$(echo "$output" | jq -r .repo_type)"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["java","python"]}' \
    bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$S' detect --repo -agree-dash"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "$from_plan" ]
  [ "$from_plan" = "java" ]
}

@test "detect: #1504 a positional argument is a usage error (exit 2)" {
  # The parse loop's second rejection arm. Only the `-*` arm was covered, so
  # changing `*)` to `*) shift ;;` would make `detect --repo . stray` silently
  # ignore the operand and exit 0 with the suite green.
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" detect --repo "$R" stray
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'detect: unexpected argument: stray'
}

@test "detect: #1504 the typed exit-3 object is on STDOUT, where the orchestrator reads it" {
  # `run` alone merges the streams, so every typed-error assertion above would
  # survive the emitters being redirected to stderr — leaving the orchestrator
  # an empty stdout and nothing to relay. Assert the stream, not just the text.
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["rust"]}' \
    zsh "$S" detect --repo "$R"
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "detect: #1504 a usage error prints NOTHING on stdout" {
  # The converse: exit 2 is a stderr diagnostic, so a caller that parses stdout
  # first must find an empty document rather than a half-message.
  run --separate-stderr zsh "$S" detect --repo
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'detect: --repo requires a value'
}

@test "detect: #1504 a FLAG-SHAPED --repo value is refused, not consumed" {
  # `need_value`'s second shape. Realistic as an unquoted `--repo $VAR` with VAR
  # unset, which swallows the next flag as the value.
  run --separate-stderr zsh "$S" detect --repo --base
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'detect: --repo requires a value (got the flag --base)'
}

@test "detect: #1504 an explicitly EMPTY --repo value is refused, not read as omitted" {
  # `need_value`'s third shape: `--repo ""` would otherwise be indistinguishable
  # from the flag being absent, and reach the "--repo is required" arm with a
  # message naming the wrong problem.
  run --separate-stderr zsh "$S" detect --repo ""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'detect: --repo requires a non-empty value'
}

@test "detect: #1504 the no-arg usage string advertises it too" {
  # Three usage strings emit the subcommand list; only the unknown-subcommand
  # one was asserted. §1b tells a session to call `detect`, so a `-h` or no-arg
  # invocation that still advertises `plan|scope-findings` sends it to a
  # subcommand that does not exist.
  run --separate-stderr zsh "$S"
  [ "$status" -eq 2 ]
  echo "$stderr" | grep -q 'plan|detect|scope-findings'
}

@test "detect: #1504 --help advertises it as well, at exit 0" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "plan|detect|scope-findings"
}

# ---- detect ∘ the profile roster: §1b's composition, end to end (#1505) -----
#
# §1b does two things: read `detect`'s repo_type, then load
# `development-<that value>:resolve-profile` by name. Each half is covered
# above and in tests/resolve-profile-contract.bats — but nothing joined them, so
# `detect` could emit a value no profile is named for and both suites stay
# green while every run of that type silently takes the conductor's generic
# floor. This drives the JOIN.
#
# §1b renders only the generic `development-<repo_type>:resolve-profile`
# template — it never emits a per-type literal — so there is no rendering to
# needle. Substituting detect's real output into that template is the closest
# thing to what §1b actually does, and it is what this asserts.

# Is $1 (a repo-relative path) tracked? `ls-files` alone exits 0 with EMPTY
# output for an untracked path, so the `grep -qxF` is what makes this decide
# anything. Extracted so the join and its non-vaciuty control drive the SAME
# code — a control holding its own copy of the pipeline cannot see that copy
# and the real one diverge.
_profile_is_tracked() {
  git -C "$REPO_ROOT" ls-files -- "$1" | grep -qxF -- "$1"
}

@test "detect: #1505 every emitted repo_type resolves to a shipped profile" {
  local langs type path
  for langs in '{"languages":["python"]}' \
               '{"languages":["java"]}' \
               '{"languages":["go"]}' \
               '{"languages":["swift"]}' \
               '{"languages":[],"is_kubernetes":true}' \
               '{"languages":[],"is_claude_plugin":true}'; do
    detect "$langs"
    [ "$status" -eq 0 ] || { echo "detect failed for $langs: $output"; return 1; }
    # the whole document, so a descriptor leaking extra keys is caught here too
    [ "$(echo "$output" | jq -r 'keys | join(",")')" = "repo_type" ] \
      || { echo "$langs: detect emitted more than repo_type: $output"; return 1; }
    type="$(echo "$output" | jq -r .repo_type)"
    path="development-$type/skills/resolve-profile/SKILL.md"
    _profile_is_tracked "$path" \
      || { echo "$langs -> repo_type '$type', but $path is not tracked"; return 1; }
  done
}

@test "detect: #1505 non-vacuity: an unshipped repo_type fails the same join" {
  # Proves the join above discriminates rather than passing because `ls-files`
  # returns something for anything. `rust` is not a repo type this script emits,
  # so no profile exists for it — the exact shape a new type without a profile
  # would have. Drives the join's OWN helper, so dropping the `| grep -qxF`
  # from it reds here too.
  run _profile_is_tracked "development-rust/skills/resolve-profile/SKILL.md"
  [ "$status" -ne 0 ]
  # ...and the same helper DOES resolve for a type that ships one
  run _profile_is_tracked "development-python/skills/resolve-profile/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "#1571 scope-findings IS residue's file rail: an out-of-diff blocker never reaches the changelist" {
  # Residue condition 2 used to re-check that every remaining blocker sat in a
  # file this story wrote. #1571 removed it as redundant — and THIS is what it
  # was redundant WITH. If this filter ever stops dropping out-of-diff findings,
  # the residue terminal starts filing follow-up issues against code the run
  # never touched, with nothing downstream to catch it.
  #
  # Asserted on the FILTERED OUTPUT, never on a loop exit code: a run whose only
  # finding is dropped here is zero-blocking and exits CONVERGED (0), which
  # satisfies `status != 14` while proving nothing — it would pass with the
  # filter deleted.
  echo "print(1)" > "$R/app.py"          # the story's diff
  cat > "$R/findings.json" <<'JSON'
[
  {"severity":"WARNING","dimension":"bugs","file":"app.py","line":7,"title":"in the story diff"},
  {"severity":"WARNING","dimension":"bugs","file":"legacy.py","line":3,"title":"shipped behaviour this run never opened"}
]
JSON
  run env GIT_BIN=git zsh "$S" scope-findings --repo "$R" --base main --findings "$R/findings.json"
  [ "$status" -eq 0 ]
  # the out-of-diff one is GONE — the rail residue now leans on
  [ "$(echo "$output" | jq '[.[] | select(.file == "legacy.py")] | length')" -eq 0 ]
  # ...and the in-diff one SURVIVES, or the filter would "pass" by dropping all
  [ "$(echo "$output" | jq '[.[] | select(.file == "app.py")] | length')" -eq 1 ]
}

# ---- #1582: reviewers resolve paths against the WORKTREE, never the original
# checkout. The descriptor names both roots and carries an absolute scope list,
# because a finding records only the path a reviewer REPORTED, never the one it
# READ — so a repo-root file read from the wrong tree yields an in-diff,
# repo-relative path that no downstream filter can tell from a correct finding.
# That is the #1558 CRITICAL false positive, and it is why this is a dispatch
# rail rather than an output check.

@test "#1582 plan in a LINKED WORKTREE names both roots and prefixes a non-empty scope_abs" {
  # A worktree of the fixture repo. The diff is deliberately NON-EMPTY: the
  # per-entry prefix assertion below is vacuously true on an empty array, so an
  # empty-diff fixture would stay green with scope_abs deleted outright.
  # `--detach`: `main` is already checked out in $R, and git refuses to check the
  # same branch out twice. The base ref still resolves — a linked worktree shares
  # the object store and refs with its main checkout, which is the whole reason
  # this hazard exists.
  local wt; wt="$BATS_TEST_TMPDIR/worktree-brisk-otter"
  git -C "$R" worktree add -q --detach "$wt" main
  echo "print(1)" > "$wt/app.py"
  echo "print(2)" > "$wt/second.py"

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$wt" --base main --round 1
  [ "$status" -eq 0 ]

  local wt_top; wt_top="$(git -C "$wt" rev-parse --show-toplevel)"
  local main_top; main_top="$(git -C "$R" rev-parse --show-toplevel)"

  [ "$(echo "$output" | jq -r .worktree_root)" = "$wt_top" ]
  [ "$(echo "$output" | jq -r .original_root)" = "$main_top" ]
  # the two roots genuinely DIFFER, or the case proves nothing about a worktree
  [ "$wt_top" != "$main_top" ]

  # non-empty, and index-aligned with changed_files — same order, same length
  [ "$(echo "$output" | jq '.scope_abs | length')" -gt 0 ]
  [ "$(echo "$output" | jq '.scope_abs | length')" \
    -eq "$(echo "$output" | jq '.changed_files | length')" ]
  # entry i == worktree_root + "/" + changed_files[i], asserted elementwise
  [ "$(echo "$output" | jq -r '[ .scope_abs[] ] == [ .changed_files[] | $r + "/" + . ]' \
       --arg r "$wt_top")" = "true" ]
}

@test "#1582 plan on an ORDINARY checkout emits original_root as JSON null, not a string or an absent key" {
  echo "print(1)" > "$R/app.py"
  plan '{"languages":["python"]}' --round 1
  [ "$status" -eq 0 ]

  # JSON null — not the string "null" (which would render into the reviewer
  # sentence verbatim), and not absent (the key is read unconditionally).
  [ "$(echo "$output" | jq -r '.original_root | type')" = "null" ]
  [ "$(echo "$output" | jq 'has("original_root")')" = "true" ]

  local top; top="$(git -C "$R" rev-parse --show-toplevel)"
  [ "$(echo "$output" | jq -r .worktree_root)" = "$top" ]
  # and scope_abs is populated exactly as in the worktree case
  [ "$(echo "$output" | jq '.scope_abs | length')" -gt 0 ]
  [ "$(echo "$output" | jq -r '[ .scope_abs[] ] == [ .changed_files[] | $r + "/" + . ]' \
       --arg r "$top")" = "true" ]
}

@test "#1582 an EMPTY scope still carries all three keys, with scope_abs []" {
  # The vacuity case, pinned separately so the worktree case above can never be
  # satisfied by an empty scope. No working-tree change at all -> empty diff.
  plan '{"languages":["python"]}' --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .changed_files)" = "[]" ]
  [ "$(echo "$output" | jq -c .scope_abs)" = "[]" ]
  [ "$(echo "$output" | jq -r .scope_empty)" = "true" ]
  # worktree_root is still emitted — an empty scope is not a missing root
  [ -n "$(echo "$output" | jq -r .worktree_root)" ]
  [ "$(echo "$output" | jq -r '.worktree_root | type')" = "string" ]
}

@test "#1582 worktree_root comes from the git TOPLEVEL, never from --repo" {
  # --repo accepts any readable directory, but changed_files is always
  # repo-root-relative. Prefixing with a --repo that is a SUBDIRECTORY would
  # emit scope_abs entries naming no file at all.
  mkdir -p "$R/pkg/inner"
  echo "print(1)" > "$R/pkg/inner/app.py"

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R/pkg/inner" --base main --round 1
  [ "$status" -eq 0 ]

  local top; top="$(git -C "$R" rev-parse --show-toplevel)"
  [ "$(echo "$output" | jq -r .worktree_root)" = "$top" ]
  [ "$(echo "$output" | jq -r .worktree_root)" != "$R/pkg/inner" ]

  # every emitted absolute path names a file that actually EXISTS — the real
  # point of the criterion, and what a --repo-derived prefix would break.
  # Counted, not just looped: on an empty scope_abs the loop body never runs and
  # the claim would pass having checked nothing.
  local n_abs seen=0 p
  n_abs="$(echo "$output" | jq '.scope_abs | length')"
  [ "$n_abs" -gt 0 ]
  while IFS= read -r p; do
    [ -e "$p" ]
    seen=$(( seen + 1 ))
  done < <(echo "$output" | jq -r '.scope_abs[]')
  [ "$seen" -eq "$n_abs" ]
}

@test "#1582 scope_abs ACCOMPANIES changed_files — the repo-relative form is untouched" {
  # scope-findings filters on the repo-relative spelling, so absolutising
  # changed_files would silently drop every finding and converge the loop on a
  # review that filtered everything out. Pin that they round-trip.
  echo "print(1)" > "$R/app.py"
  plan '{"languages":["python"]}' --round 1
  [ "$status" -eq 0 ]
  local top; top="$(git -C "$R" rev-parse --show-toplevel)"
  # EVERY scope_abs entry is genuinely absolute and genuinely prefixed. Asserted
  # before the round-trip below, which alone would not catch a dropped prefix:
  # `ltrimstr` on an unprefixed entry is a no-op, so `[a.py] == [a.py]` holds
  # just as well when scope_abs is a bare copy of changed_files.
  [ "$(echo "$output" | jq '.scope_abs | length')" -gt 0 ]
  [ "$(echo "$output" | jq -r '[ .scope_abs[] | startswith($r + "/") ] | all' \
       --arg r "$top")" = "true" ]
  # stripping the root off scope_abs reproduces changed_files exactly
  [ "$(echo "$output" | jq -r '[ .scope_abs[] | ltrimstr($r + "/") ] == .changed_files' \
       --arg r "$top")" = "true" ]
  # and changed_files itself carries no absolute entry
  [ "$(echo "$output" | jq '[ .changed_files[] | select(startswith("/")) ] | length')" -eq 0 ]
}

@test "#1582 an unresolvable worktree root is exit 1 with a named line, never an empty prefix" {
  # Without the guard, `worktree_root` comes back empty and every scope_abs entry
  # is `/src/app.py` — absolute paths rooted at `/` that name no file, handed to
  # every reviewer, at exit 0 with a descriptor that looks well-formed.
  echo "print(1)" > "$R/app.py"
  local fakegit="$BATS_TEST_TMPDIR/git-no-toplevel"
  cat > "$fakegit" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "--show-toplevel" ]; then echo "boom" >&2; exit 128; fi
done
exec git "$@"
EOF
  chmod +x "$fakegit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_BIN="$fakegit" zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- 'could not resolve the worktree root'
}

@test "#1582 a BLANK worktree root is exit 1 too — an empty identity is not an answer" {
  # The other half of the guard: a git that succeeds but prints nothing.
  echo "print(1)" > "$R/app.py"
  local fakegit="$BATS_TEST_TMPDIR/git-blank-toplevel"
  cat > "$fakegit" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "--show-toplevel" ]; then exit 0; fi
done
exec git "$@"
EOF
  chmod +x "$fakegit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_BIN="$fakegit" zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- 'could not resolve the worktree root'
}

@test "#1582 an unresolvable original-checkout root is exit 1, never a false original_root: null" {
  # The more dangerous twin. Left ungated, `main_root` comes back empty, compares
  # unequal to worktree_root, and the descriptor confidently reports "ordinary
  # checkout" for a run that IS in a linked worktree — the sentence drops its
  # second clause and the #1558 false-positive class reopens at exit 0.
  echo "print(1)" > "$R/app.py"
  local fakegit="$BATS_TEST_TMPDIR/git-no-worktree-list"
  cat > "$fakegit" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "worktree" ]; then echo "boom" >&2; exit 128; fi
done
exec git "$@"
EOF
  chmod +x "$fakegit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_BIN="$fakegit" zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- 'could not resolve the original checkout root'
}

@test "#1582 an EMPTY worktree listing is exit 1, not a silent original_root: null" {
  # A `worktree list --porcelain` that succeeds but emits nothing (or whose shape
  # changed under us). Asserted as a NAMED failure rather than as `original_root:
  # null`, which is what makes it distinguishable from an ordinary checkout.
  echo "print(1)" > "$R/app.py"
  local fakegit="$BATS_TEST_TMPDIR/git-empty-worktree-list"
  cat > "$fakegit" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "worktree" ]; then exit 0; fi
done
exec git "$@"
EOF
  chmod +x "$fakegit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_BIN="$fakegit" zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- 'could not resolve the original checkout root'
}

@test "#1582 a --repo SUBDIRECTORY still scopes the WHOLE repo, not just that subtree" {
  # The repo-WIDE half of the `:/` pathspec fix, which the root-relative half
  # cannot catch. Dropping `:/` while keeping `--full-name` leaves every path
  # repo-root-relative — so an existence check still passes — while files outside
  # the subdirectory vanish from changed_files, scope_abs and scope-findings'
  # filter: the scope loss this story exists to fix.
  mkdir -p "$R/pkg/inner"
  echo "print(1)" > "$R/pkg/inner/app.py"   # untracked, INSIDE the subdir
  echo "print(2)" > "$R/outside.py"         # untracked, OUTSIDE it
  echo "changed"  >> "$R/legacy.py"         # tracked modification, outside it

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R/pkg/inner" --base main --round 1
  [ "$status" -eq 0 ]

  # all three are in scope, in their repo-root-relative spelling
  [ "$(echo "$output" | jq -r '.changed_files | index("pkg/inner/app.py") != null')" = "true" ]
  [ "$(echo "$output" | jq -r '.changed_files | index("outside.py") != null')" = "true" ]
  [ "$(echo "$output" | jq -r '.changed_files | index("legacy.py") != null')" = "true" ]
  # ...and scope_abs mirrors that, elementwise
  local top; top="$(git -C "$R" rev-parse --show-toplevel)"
  [ "$(echo "$output" | jq -r '[ .scope_abs[] ] == [ .changed_files[] | $r + "/" + . ]' \
       --arg r "$top")" = "true" ]
}

@test "#1582 the repo-wide listing keeps the START-ANCHORED artifact contract" {
  # Making the listings repo-wide must not change WHICH paths count as
  # artifacts. The root sink is excluded; a nested `.review/` inside story code
  # stays IN scope, because it is story code — the contract
  # `plan: the exclusion is start-anchored` pins, and which a match-at-any-depth
  # pattern would silently violate for every review scope.
  mkdir -p "$R/src/.review" "$R/.review"
  echo '[]'  > "$R/.review/findings-round-1.json"
  echo "cfg" > "$R/src/.review/config.json"
  echo "print(1)" > "$R/app.py"

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 0 ]
  # root artifact: out
  [ "$(echo "$output" | jq '[ .changed_files[] | select(startswith(".review/")) ] | length')" -eq 0 ]
  # nested story file: in, and mirrored into scope_abs
  [ "$(echo "$output" | jq -r '.changed_files | index("src/.review/config.json") != null')" = "true" ]
  local top; top="$(git -C "$R" rev-parse --show-toplevel)"
  [ "$(echo "$output" | jq -r --arg p "$top/src/.review/config.json" \
       '.scope_abs | index($p) != null')" = "true" ]
  # non-vacuous: the ordinary file DID make it into the scope
  [ "$(echo "$output" | jq -r '.changed_files | index("app.py") != null')" = "true" ]
}

@test "#1582 scope_abs mirrors changed_files on a DELTA round too, not just a full one" {
  # Every other #1582 case is a full round, where changed_files == the full diff.
  # Building scope_abs from the full diff instead of the round's scope would stay
  # green in all of them while pointing an iteration round's reviewers at the
  # whole story diff.
  echo "print(1)" > "$R/app.py"
  local t1; t1="$(tree_id)"
  echo "print(2)" > "$R/helper.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main --round 3 --prior-tree "$t1"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .scope_mode)" = "delta" ]
  # the delta is the fix-pass file only, and scope_abs mirrors exactly that
  [ "$(echo "$output" | jq -c .changed_files)" = '["helper.py"]' ]
  local top; top="$(git -C "$R" rev-parse --show-toplevel)"
  [ "$(echo "$output" | jq -r '[ .scope_abs[] ] == [ .changed_files[] | $r + "/" + . ]' \
       --arg r "$top")" = "true" ]
}

@test "#1582 plan's descriptor key set is pinned, so a key cannot appear or vanish silently" {
  # detect has had this since #1504; plan did not, so each of its keys was pinned
  # only by whichever assertion happened to name it, and ARCHITECTURE.md's
  # documented shape could drift from the emitter with the suite green.
  echo "print(1)" > "$R/app.py"
  plan '{"languages":["python"]}' --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r 'keys_unsorted | join(",")')" = \
    "repo_type,review_skill,round,base,findings_path,changed_files,worktree_root,original_root,scope_abs,scope_mode,scope_empty,prior_tree,delta_files,fix_verification_path,adjudicated_path" ]
}

@test "#1582 --no-relative survives a user-level diff.relative=true" {
  # `--no-relative` is the load-bearing half of the diff fix and is INERT in
  # every other fixture, because a bare `git diff` is already repo-wide and
  # root-relative when diff.relative is unset. Under `diff.relative=true` git
  # emits cwd-relative paths and DROPS everything outside the cwd, and a
  # pathspec does not countermand it — so without the flag, planning from a
  # subdirectory silently loses every tracked change outside that subtree and
  # prefixes the survivors with the repo root, naming files that do not exist.
  git -C "$R" config diff.relative true
  mkdir -p "$R/pkg/inner"
  echo "print(1)" > "$R/pkg/inner/app.py"   # untracked, inside
  echo "changed"  >> "$R/legacy.py"         # TRACKED modification, outside

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R/pkg/inner" --base main --round 1
  [ "$status" -eq 0 ]
  # the tracked change outside the subdirectory is the one diff.relative would eat
  [ "$(echo "$output" | jq -r '.changed_files | index("legacy.py") != null')" = "true" ]
  [ "$(echo "$output" | jq -r '.changed_files | index("pkg/inner/app.py") != null')" = "true" ]
  # and no entry is subdirectory-relative
  [ "$(echo "$output" | jq -r '.changed_files | index("inner/app.py")')" = "null" ]
  # every absolute path still names a real file
  local p
  while IFS= read -r p; do [ -e "$p" ]; done < <(echo "$output" | jq -r '.scope_abs[]')
}

@test "#1582 a BARE main repository reports NO original checkout" {
  # `_main_root`'s bare arm. Without it the first porcelain entry is the bare
  # repo's own path, so original_root becomes a .git directory that compares
  # unequal to worktree_root — and every reviewer is told "this run's tree is
  # that directory, not /path/to/bare.git", a path that is not a checkout.
  local bare="$BATS_TEST_TMPDIR/bare.git"
  git clone --bare -q "$R" "$bare"
  local wt="$BATS_TEST_TMPDIR/wt-of-bare"
  git -C "$bare" worktree add -q --detach "$wt" main
  echo "print(1)" > "$wt/app.py"

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$wt" --base main --round 1
  [ "$status" -eq 0 ]
  # JSON null, not the bare repo's path
  [ "$(echo "$output" | jq -r '.original_root | type')" = "null" ]
  # discriminating: the ordinary linked-worktree case DOES report a root, so
  # this is not passing merely because original_root is always null
  [ "$(echo "$output" | jq -r .worktree_root)" = "$(git -C "$wt" rev-parse --show-toplevel)" ]
}

@test "#1582 an inherited GIT_DIR/GIT_WORK_TREE cannot redirect the roots" {
  # GIT_DIR and GIT_WORK_TREE take precedence over `git -C`, and since #1582 the
  # two roots are what every reviewer prompt is built from — so an inherited one
  # would send the whole panel to read another checkout, at exit 0, with no
  # visible symptom.
  local other="$BATS_TEST_TMPDIR/other-repo"
  mkdir -p "$other"
  git -C "$other" init -q
  git -C "$other" config user.email t@example.com
  git -C "$other" config user.name tester
  echo other > "$other/README.md"
  git -C "$other" add -A
  git -C "$other" commit -qm base
  git -C "$other" branch -M main
  echo "print(1)" > "$R/app.py"

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_DIR="$other/.git" GIT_WORK_TREE="$other" \
    zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .worktree_root)" = "$(git -C "$R" rev-parse --show-toplevel)" ]
  [ "$(echo "$output" | jq -r .worktree_root)" != "$other" ]

  # GIT_WORK_TREE alone, so neither name can be dropped from the scrub
  # independently
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_WORK_TREE="$other" \
    zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .worktree_root)" = "$(git -C "$R" rev-parse --show-toplevel)" ]
}

@test "#1582 a LARGE worktree listing does not SIGPIPE the producer into a false failure" {
  # _main_root reads the listing into a variable instead of piping it into an
  # early-exiting awk. Past roughly 20 linked worktrees the producer's second
  # buffer flush hits EPIPE, git re-raises SIGPIPE (141), `pipefail` promotes it,
  # and `|| return 1` aborts EVERY plan on a healthy repo. Measured, not
  # reasoned: the old pipeline returns 0 on a short listing and 141 on a long
  # one. Driven with a stub rather than 300 real worktrees — deterministic, and
  # it exercises the same buffer boundary.
  echo "print(1)" > "$R/app.py"
  # The first block names a path that is DELIBERATELY not this repo's toplevel,
  # so `original_root` is non-null on every platform. Asserting it equals `$R`
  # was a latent platform dependency: on macOS `$BATS_TEST_TMPDIR` lives under
  # `/var/folders/…`, a symlink to `/private/var/…`, so `rev-parse
  # --show-toplevel` (resolved) and `$R` (unresolved) differ by accident and the
  # roots compared unequal; on Linux there is no such symlink, both are
  # identical, `original_root` is correctly `null`, and the assertion failed.
  # The code was right both times — the fixture was reading a symlink quirk as
  # the behaviour under test.
  local synthetic_main="/synthetic-main-checkout"
  local fakegit="$BATS_TEST_TMPDIR/git-many-worktrees"
  # 5000 blocks at ~95 bytes is ~475 KB against a 64 KiB pipe buffer — ~7x, not
  # the ~5% an earlier count left. The margin is the point: at ~69 KB a later
  # trim of the count or the path length would silently stop crossing the
  # boundary, and the case would pass with the old `awk … exit` pipeline
  # restored, i.e. stop being the control its comment claims to be.
  cat > "$fakegit" <<EOF
#!/usr/bin/env bash
if [ "\$3" = "worktree" ] || [ "\$1" = "worktree" ]; then
  printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/main\n\n' "$synthetic_main"
  for i in \$(seq 1 5000); do
    printf 'worktree /synthetic-linked-worktree-%s\nHEAD 0000000000000000000000000000000000000000\ndetached\n\n' "\$i"
  done
  exit 0
fi
exec git "\$@"
EOF
  chmod +x "$fakegit"

  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_BIN="$fakegit" zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 0 ]
  # the FIRST block is the answer — not the 5000 that follow it, and not null
  [ "$(echo "$output" | jq -r .original_root)" = "$synthetic_main" ]
  # and it did not fail for the SIGPIPE reason specifically. The rostered helper,
  # not `grep -qv … || true` (never fails), not a bare `! … | grep` (inert, #829)
  # and not a bare `[[ ]]` (inert, #1011) — three shapes that all look like
  # assertions and none of which reds.
  lacks "$stderr" "could not resolve the original checkout root"
}

@test "#1582 a non-ASCII path stays in scope and is never quoted-escaped" {
  # Both listings carry `-c core.quotePath=false`, on the two command lines this
  # story rewrote. With the default TRUE, git emits `"src/caf\303\251.zsh"` —
  # quotes and octal escapes included — which can never match the plain UTF-8
  # `.file` a reviewer reports, so the file vanishes from changed_files,
  # scope_abs and scope-findings' filter.
  # BOTH halves need their own file: committing café.py makes it TRACKED, so on
  # its own it exercises only `diff --name-only` and the `ls-files --others`
  # invocation keeps its flag untested.
  printf 'x\n' > "$R/café.py"
  git -C "$R" add café.py
  git -C "$R" -c user.email=t@e -c user.name=t commit -qm add-nonascii
  printf 'y\n' >> "$R/café.py"                 # tracked-modification half
  printf 'z\n' > "$R/naïve.py"                 # untracked half — never added

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 0 ]
  # nothing arrives quoted
  [ "$(echo "$output" | jq '[ .changed_files[] | select(startswith("\"")) ] | length')" -eq 0 ]
  # ...and BOTH files really are in scope (non-vacuity), matched normalisation-
  # agnostically so macOS NFD cannot make this flaky
  [ "$(echo "$output" | jq '[ .changed_files[] | select(test("caf")) ] | length')" -ge 1 ]
  [ "$(echo "$output" | jq '[ .changed_files[] | select(test("na")) ] | length')" -ge 1 ]
  [ "$(echo "$output" | jq '[ .scope_abs[] | select(test("caf")) ] | length')" -ge 1 ]
  [ "$(echo "$output" | jq '[ .scope_abs[] | select(test("na")) ] | length')" -ge 1 ]
}

@test "#1582 an inherited GIT_INDEX_FILE cannot inflate the scope" {
  # The third name in the scrub, and the only one whose effect is on scope
  # CONTENT rather than on the roots: git hooks and filter drivers export it, and
  # `ls-files --others --exclude-standard` read against a foreign (empty) index
  # reports every tracked file as an untracked addition.
  echo "print(1)" > "$R/app.py"
  local foreign="$BATS_TEST_TMPDIR/foreign.index"
  : > "$foreign"

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_INDEX_FILE="$foreign" zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 0 ]
  # committed files must NOT show up as untracked additions
  [ "$(echo "$output" | jq -r '.changed_files | index("README.md")')" = "null" ]
  [ "$(echo "$output" | jq -r '.changed_files | index("legacy.py")')" = "null" ]
  # the story's own change still is in scope
  [ "$(echo "$output" | jq -r '.changed_files | index("app.py") != null')" = "true" ]
}
