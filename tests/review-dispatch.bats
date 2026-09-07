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
  # Against the RESOLVED toplevel, never the literal $R (#1587/#1590). On macOS
  # $BATS_TEST_TMPDIR sits under a /var/folders symlink and --show-toplevel
  # returns /private/var/…, so a literal-$R comparison passes on Linux and reds
  # `bats (ubuntu-latest)` — the exact platform split #1590 fixed in this file.
  local root; root="$(git -C "$R" rev-parse --show-toplevel)"
  [ "$(echo "$output" | jq -r .findings_path)" = "$root/.review/findings-round-2.json" ]
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
  # #1588: driven over every SPELLING the `sed -nE` handles, not just the bare
  # one. That expression strips leading whitespace, an inline `#` comment and
  # surrounding quotes, then quits at the first match — four behaviours a single
  # `primary: java` fixture leaves entirely unpinned. Mutations each spelling
  # reds, all of which shipped green before this loop existed:
  #   - delete `s/[[:space:]]*(#.*)?$//`  -> the trailing-comment form
  #   - delete either quote strip         -> the "java" / 'java' forms
  #   - delete the `q`                    -> the two-line file below
  # A wrong answer here is not a crash: `primary` fails the `(Ie)` membership
  # test, and the repo escalates as `ambiguous_repo_type` — telling a human to
  # set a key the repo already carries.
  local spelling
  for spelling in \
      'primary: java' \
      'primary: "java"' \
      "primary: 'java'" \
      '   primary: java' \
      'primary: java  # the app is the java service'; do
    printf '%s\n' "$spelling" > "$R/.maintenance.yml"
    plan '{"languages":["python","java"]}'
    [ "$status" -eq 0 ]
    # name the spelling in the failure, or a red loop says only "java != python"
    if [ "$(echo "$output" | jq -r .repo_type)" != "java" ]; then
      echo "spelling [$spelling] resolved to $(echo "$output" | jq -r '.repo_type // .error')" >&2
      return 1
    fi
  done

  # ...and the `q`: the FIRST `primary:` wins. Without it `sed` prints both
  # lines, `primary` becomes a two-line value matching no candidate, and the
  # repo escalates as ambiguous instead of resolving.
  printf 'primary: java\nprimary: python\n' > "$R/.maintenance.yml"
  plan '{"languages":["python","java"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "java" ]
}

@test "#1588 the original_root gloss covers the BARE-repo case, not just a linked worktree" {
  # Item 9, and it is a DELIBERATE DOCUMENTATION TRIPWIRE — the only one in this
  # file. The gloss is a comment, so there is no behaviour to assert instead:
  # the BEHAVIOUR is already driven end-to-end by `#1582 a BARE main repository
  # reports NO original checkout`, which clones bare, adds a worktree and asserts
  # `original_root` is null. This case exists only because the comment CONTRADICTED
  # the two statements either side of it — `_main_root`'s header and the
  # `_worktree_root`/`_main_root` contrast block both say the function succeeds
  # with an EMPTY root for a bare main worktree — so a reader trusting "not a
  # linked worktree" would conclude a null descriptor proves a main checkout.
  #
  # NARROWED to the single token that carries the admission, per the standard the
  # sibling suite declares for its own one tripwire: a reword of the surrounding
  # gloss must not red the suite, only DELETION of the admission may.
  #
  # COUNTED, not merely present, and counted over text whose COMMENT MARKERS are
  # stripped first. Three things had to be got right here, each learned from a
  # failure of the previous form:
  #
  #   * a presence check was satisfied by `_main_root`'s pre-existing header
  #     alone, so deleting the gloss this story added — restoring the very
  #     contradiction item 9 exists to remove — shipped green. That is the
  #     non-uniqueness failure the sibling suite recorded for its own needles,
  #     reintroduced here by narrowing to a single token;
  #   * counting over the RAW flatten still counted only two, because the third
  #     statement of the admission — the `_worktree_root`/`_main_root` contrast
  #     block named in this case's own first paragraph — is split across a
  #     comment-line wrap, and `tr '\n' ' '` leaves the `#` between its halves.
  #     The count was therefore 2 by accident of wrapping, which made it
  #     wrap-SENSITIVE in both directions: rewording the 80-column gloss pushes
  #     `worktree:` onto the next `#` line (count 1, red on a safe reword), and
  #     re-wrapping the contrast block joins its halves (count 3, red again).
  #     Worse, the two cancel: delete the gloss AND re-wrap the contrast block
  #     and the count returns to 2 — green, with the contradiction restored;
  #   * stripping the marker before flattening is the sibling's own `_gap_text`
  #     precedent, and it makes the count mean what the comment says. All THREE
  #     statements are counted, which is the number this case's first paragraph
  #     already names, and deleting ANY of them reds.
  #
  # So: reword-tolerant (including re-wrapping), deletion-sensitive on all three.
  local flat
  flat="$(sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' "$S" | tr '\n' ' ' | tr -s ' ')"
  [ "$(printf '%s' "$flat" | grep -o 'BARE main worktree' | wc -l | tr -d ' ')" -eq 3 ]
}

@test "#1588 plan: an UNREADABLE .maintenance.yml exits 1, never ambiguous_repo_type" {
  # The absent file is the ordinary "no primary" case and still escalates as
  # ambiguous. An unreadable one is a fact about the MACHINE, and reporting it
  # as a verdict about the REPO tells a human to set a key the repo may already
  # carry. Mutation: drop the `||` on `primary=$(_primary "$repo")` in
  # review-dispatch.zsh and this goes back to exit 3 / ambiguous_repo_type.
  # Same root guard the detect-stack suite uses for its unreadable-path cases:
  # root reads a mode-000 file, so the branch is simply not reachable there.
  if [ "$(id -u)" -eq 0 ]; then
    skip "root reads every file, so the unreadable-file branch cannot be exercised"
  fi
  printf 'primary: java\n' > "$R/.maintenance.yml"
  chmod 000 "$R/.maintenance.yml"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python","java"]}' \
    zsh "$S" plan --repo "$R" --base main
  # restore before asserting, so a failing assertion cannot leave the fixture
  # unreadable for the next test's cleanup
  chmod 644 "$R/.maintenance.yml"
  [ "$status" -eq 1 ]
  # The exit-1 contract is a stderr diagnostic AND an empty stdout — every other
  # exit-1 case in this file pairs the two, because a caller parsing stdout first
  # must not find a half-document. Without it, a guard that emitted a typed
  # object alongside the diagnostic would still pass here.
  [ -z "$output" ]
  # The negative points at STDERR, the stream that actually carries content:
  # `lacks "$output" …` was tautological once `[ -z "$output" ]` landed above it
  # (no string is findable in one already proved empty), so it read as a check
  # and was inert. What is worth pinning is that the diagnostic does not itself
  # misattribute a machine fault as a verdict about the repo.
  # The rostered helper, not `grep -qv` (passes whenever ANY line differs, #829).
  lacks "$stderr" "ambiguous_repo_type"
  contains "$stderr" "could not read the .maintenance.yml primary key"
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

@test "plan: #1587 a relative --repo is ANCHORED to the toplevel in the descriptor" {
  # Renamed and re-subjected by #1587. This case began as #1177's guard against a
  # doubled `././` in findings_path, produced by rewriting EVERY relative
  # `--repo` rather than only the dash-prefixed one that needs it.
  #
  # Anchoring RETIRED that defect rather than moving it: findings_path is now
  # built from `_repo_anchor`'s output, which is `rev-parse --show-toplevel` — an
  # absolute, `./`-free path — so no normalisation of `--repo` can put anything
  # into that field at all. An earlier cut of this case kept a
  # `case */./*|*//*|./*` guard beside the equality below and claimed it still
  # caught the regression; it could not, since a `//`-bearing path fails the
  # equality on every platform, so the guard was inert. Inert is worse than
  # absent (this file says so at the zero-padded-round case), hence its removal.
  #
  # What this case pins TODAY: `--repo .` yields the same absolute, root-anchored
  # findings_path an absolute `--repo` does. The dash-normalisation arm keeps its
  # own coverage in the four-spelling case in the #1587 section.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    bash -c "cd '$R' && zsh '$S' plan --repo . --base main"
  [ "$status" -eq 0 ]
  local root; root="$(git -C "$R" rev-parse --show-toplevel)"
  [ "$(echo "$output" | jq -r .findings_path)" = "$root/.review/findings-round-1.json" ]
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
  # against the RESOLVED toplevel, never the literal $R — see the note on the
  # `findings_path is a well-known per-round path` case above (#1587/#1590)
  local root; root="$(git -C "$R" rev-parse --show-toplevel)"
  [ "$(echo "$output" | jq -r .findings_path)" = "$root/.review/findings-round-7.json" ]
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
  # whose `sed -nE … "$repo/.maintenance.yml"` reads the path as an option
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
  #
  # #1587 moved WHERE this class is caught, not whether. `_repo_anchor` calls
  # `_worktree_root` before any reader, so a git that cannot answer
  # `--show-toplevel` is now refused at the anchoring site and the named line is
  # the anchor's. The #1582 guarantee this case exists for is untouched and
  # still asserted below: exit 1, NO descriptor on stdout, a named line — never
  # an empty prefix at exit 0.
  #
  # The grep names ONE owner (the anchor) deliberately. An earlier cut widened it
  # to accept either wording, which absorbed the re-ordering silently AND left
  # `cmd_plan`'s own `_worktree_root` guard with no coverage at all — the case
  # below (`the SECOND --show-toplevel`) exists to reach that guard, and this
  # exact needle is what keeps the two cases pinning different owners.
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
  echo "$stderr" | grep -q -- 'could not resolve the repository root'
}

@test "#1582 a BLANK worktree root is exit 1 too — an empty identity is not an answer" {
  # The other half of the guard: a git that succeeds but prints nothing.
  # Caught at the anchoring site since #1587, for the reason the case above
  # states in full; the guarantee asserted here is unchanged. One difference
  # from that case, and it is why this note is not just a pointer: git reports
  # NOTHING here, so the anchor's re-probe captures no cause and the refusal
  # line carries the stated fallback instead of git's own stderr. The empty
  # cause IS the failure on this fixture — and it is ASSERTED below, because
  # this is the only fixture that reaches that branch: without the assertion,
  # deleting the two lines that substitute a stated cause leaves a causeless
  # refusal and a green suite.
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
  echo "$stderr" | grep -q -- 'could not resolve the repository root'
  # the stated fallback cause — the only fixture that reaches that branch
  echo "$stderr" | grep -q -- 'returned no usable root and no error'
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
  # WHAT THIS CASE PINS TODAY: a subdirectory `--repo` still yields the WHOLE
  # repo's diff, root-relative — the story-visible behaviour, which is worth a
  # case whichever mechanism delivers it.
  #
  # It no longer discriminates `:/` or `--full-name`, and this note exists so
  # nobody reads it as if it did. Since #1587 `--repo` is anchored to the
  # toplevel before `_changed_files` runs, so both listings are issued AT the
  # root, where `git diff -- ':/'` and `ls-files --others --full-name ':/'` are
  # byte-identical to the same commands without those flags — dropping either
  # leaves every assertion below passing. The script's `_changed_files` comment
  # says the same of all three flags (`:/`, `--full-name`, `--no-relative`);
  # its `--no-relative` sibling case carries the identical note.
  #
  # Do NOT "restore" a guard here: none can exist while the anchoring holds, and
  # an inert control that claims to discriminate is what this file calls worse
  # than no test. The historical reason the flags exist: pre-#1587 a
  # subdirectory `--repo` made the listings relative to and scoped by that
  # subtree, so files outside it vanished from changed_files, scope_abs and
  # scope-findings' filter.
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
  # WHAT THIS CASE PINS TODAY: the anchored behaviour under `diff.relative=true`
  # — a subdirectory `--repo` still yields the whole repo's diff, root-relative.
  #
  # It no longer discriminates `--no-relative` itself, and saying so is the
  # point of this note. #1587 anchors `--repo` to the toplevel before
  # `_changed_files` runs, so `git diff` is always issued AT the repo root and
  # `diff.relative=true` has no cwd prefix to relativize against; deleting
  # `--no-relative` from the diff half leaves every assertion below passing.
  # The script's own `_changed_files` comment says the same of all three flags
  # (`:/`, `--full-name`, `--no-relative`) — they are defence-in-depth now, kept
  # because they kill the class rather than the one route anchoring closed.
  #
  # Do NOT read this case as a live guard on the flag, and do not "restore" one:
  # there is no fixture that can discriminate it while the anchoring holds, and
  # an inert control that CLAIMS to discriminate is what this file calls worse
  # than no test at all. The historical reason the flag exists: under
  # `diff.relative=true` git emits cwd-relative paths and drops everything
  # outside the cwd, and a pathspec does not countermand it — so pre-#1587,
  # planning from a subdirectory silently lost every tracked change outside that
  # subtree and prefixed the survivors with the repo root.
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

  # FIXTURE SELF-CHECK (#1588). The count above is not self-evidently large
  # enough, and nothing else here notices if it stops being: shorten the
  # synthetic path or trim the count and the listing quietly slips back under
  # the pipe buffer, at which point this case passes with the OLD
  # `git worktree list --porcelain | awk … exit` pipeline restored — i.e. it
  # keeps claiming to be a mutation-checked control while controlling nothing.
  # So assert the volume BEFORE the subject runs, and let a trim red here.
  #
  # The arithmetic: a block is `93 + digits(i)` bytes, so 94 B is the per-block
  # lower bound and 5,000 x 94 B = 470,000 B >= 6 x 65,536 B = 393,216 B. The
  # real listing measures ~484 KB (~7.4x the 64 KiB buffer).
  #
  # Bounded at 6x rather than the buffer's bare 4x deliberately: a `4*65536`
  # bound still PASSES at ~3,100 blocks, which is precisely the trim it would
  # exist to catch. Measured boundary at 6x: 4,060 blocks reds, 4,070 passes.
  local listing_bytes
  listing_bytes=$("$fakegit" worktree list --porcelain | wc -c | tr -d ' ')
  [ "$listing_bytes" -gt $(( 6 * 65536 )) ]

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

# ---- #1587: ONE anchoring rule for --repo ----------------------------------
# `--repo` names the REPOSITORY. Every subcommand resolves it to the git
# toplevel once, before anything that DERIVES from it, so detection, the .maintenance.yml
# lookup, the listings and the default sink all describe the same tree. Before
# this, the listings were repo-wide (#1582) while detection and the sink tracked
# whatever directory --repo named.
#
# Every path assertion here compares against `rev-parse --show-toplevel`, NEVER
# against the literal $R: on macOS $BATS_TEST_TMPDIR sits under a /var/folders
# symlink and the toplevel comes back as /private/var/…, so a literal-$R
# comparison passes on Linux and reds `bats (ubuntu-latest)` — the platform
# split #1590 fixed in this same file.

# A repo whose ROOT and SUBDIRECTORY would detect differently, so a run that
# anchored at the subdirectory could not accidentally agree. The root carries
# the .maintenance.yml that breaks the multi-language tie.
_anchor_fixture() {
  AR="$BATS_TEST_TMPDIR/anchor"
  mkdir -p "$AR/pkg"
  git -C "$AR" init -q
  git -C "$AR" config user.email t@example.com
  git -C "$AR" config user.name tester
  echo base > "$AR/README.md"
  printf 'primary: go\n' > "$AR/.maintenance.yml"
  git -C "$AR" add -A
  git -C "$AR" commit -qm base
  git -C "$AR" branch -M main
  AROOT="$(git -C "$AR" rev-parse --show-toplevel)"
}

@test "plan: #1587 a subdirectory --repo and the root emit an IDENTICAL descriptor" {
  _anchor_fixture
  # byte-identical, not merely agreeing on repo_type: findings_path, both roots
  # and scope_abs are all derived from the anchor, so a partial fix that
  # anchored detection alone would still fail here.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR" --base main
  [ "$status" -eq 0 ]
  local from_root="$output"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR/pkg" --base main
  [ "$status" -eq 0 ]
  [ "$output" = "$from_root" ]
  # and it is the ROOT's answer that both produced — the .maintenance.yml tie
  # break lives at the root, so a subdirectory anchoring would escalate exit 3
  [ "$(echo "$output" | jq -r .repo_type)" = "go" ]
}

@test "plan: #1587 the .maintenance.yml primary resolves from the root, not from --repo" {
  _anchor_fixture
  # The subdirectory holds NO .maintenance.yml. Un-anchored, `_primary` returns
  # empty and the multi-language repo escalates as ambiguous (exit 3) instead of
  # planning — which is the failure this AC names.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR/pkg" --base main
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "go" ]
}

@test "plan: #1587 the default findings_path is root-anchored for ALL FOUR spellings of --repo" {
  _anchor_fixture
  local want="$AROOT/.review/findings-round-1.json"

  # 1. absolute
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR" --base main
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .findings_path)" = "$want" ]

  # 2. `.` from inside the repo
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    bash -c "cd '$AR' && zsh '$S' plan --repo . --base main"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .findings_path)" = "$want" ]

  # 3. a subdirectory
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR/pkg" --base main
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .findings_path)" = "$want" ]

  # 4. a DASH-prefixed relative path — the spelling with its own normalisation
  # arm, so it needs its own case or that arm could regress unseen.
  local dash="$BATS_TEST_TMPDIR/-anchor-dash"
  mkdir -p "$dash"
  git -C "$dash" init -q
  git -C "$dash" config user.email t@example.com
  git -C "$dash" config user.name tester
  echo base > "$dash/README.md"
  git -C "$dash" add -A
  git -C "$dash" commit -qm base
  git -C "$dash" branch -M main
  local dashroot; dashroot="$(git -C "$dash" rev-parse --show-toplevel)"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$S' plan --repo -anchor-dash --base main"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .findings_path)" = "$dashroot/.review/findings-round-1.json" ]
}

@test "plan: #1587 the DEFAULTED sink is excluded under a subdirectory --repo, and nested story .review/ is not" {
  # The #909 leak, closed at the anchoring site rather than at the exclusion.
  # Both halves in ONE run deliberately: a fix that widened `_normalise_paths`
  # to match `.review/` at any depth would pass the first assertion and fail the
  # second, which is exactly the contract this must not trade away.
  _anchor_fixture
  local sink
  sink="$(env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR/pkg" --base main | jq -r .findings_path)"
  [ "$sink" = "$AROOT/.review/findings-round-1.json" ]
  mkdir -p "$(dirname "$sink")" "$AR/src/.review"
  echo '[]' > "$sink"
  echo cfg > "$AR/src/.review/config.json"
  echo "print(1)" > "$AR/app.py"

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR/pkg" --base main
  [ "$status" -eq 0 ]
  # the sink never reaches the panel …
  echo "$output" | jq -e '.changed_files | map(select(startswith(".review/"))) | length == 0' >/dev/null
  # … while the nested story file and the ordinary story file both stay
  echo "$output" | jq -e '.changed_files | index("src/.review/config.json") != null' >/dev/null
  echo "$output" | jq -e '.changed_files | index("app.py") != null' >/dev/null
}

@test "detect: #1587 a subdirectory --repo detects as the repository" {
  _anchor_fixture
  # detect and plan must never disagree about a repo (the #1504 contract), so
  # anchoring plan alone would break it for a subdirectory --repo.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" detect --repo "$AR/pkg"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "go" ]
}

@test "detect: #1587 a NON-git --repo is its own anchor and still reads its .maintenance.yml" {
  # The no-toplevel fallback, as an explicit branch. `detect` deliberately keeps
  # accepting a directory outside any git repository — the #1504 dash fixture is
  # exactly that shape — so the rule must degrade rather than refuse. `plan` and
  # `scope-findings` cannot reach this: `_verify_base` rejects a non-git --repo
  # first, which the companion case below pins.
  local nogit="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$nogit"
  printf 'primary: java\n' > "$nogit/.maintenance.yml"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["java","python"]}' \
    zsh "$S" detect --repo "$nogit"
  [ "$status" -eq 0 ]
  # java, not an exit-3 ambiguity: the fallback anchor still found the file
  [ "$(echo "$output" | jq -r .repo_type)" = "java" ]
}

@test "plan: #1587 a non-git --repo is still refused by _verify_base, not silently anchored" {
  # The fallback must not become a back door: `plan` still names the repo, with
  # the #1177 wording, rather than planning against a directory with no repo.
  local nogit="$BATS_TEST_TMPDIR/nogit-plan"
  mkdir -p "$nogit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$nogit" --base main
  [ "$status" -eq 1 ]
  echo "$stderr" | grep -q 'not a git repository'
}

@test "scope-findings: #1587 anchoring is behaviour-neutral for a subdirectory --repo" {
  # scope-findings is anchored for uniformity, not for correctness — it has no
  # sink and no detection, and its listings were already repo-wide. This pins
  # that the anchoring did not CHANGE what it filters.
  _anchor_fixture
  echo "print(1)" > "$AR/app.py"
  local f="$BATS_TEST_TMPDIR/findings.json"
  cat > "$f" <<'JSON'
[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"real","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"never-touched.py","line":1,"title":"out","description":"d","reviewer":"r"}]
JSON
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" scope-findings --repo "$AR" --base main --findings "$f"
  [ "$status" -eq 0 ]
  local from_root="$output"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" scope-findings --repo "$AR/pkg" --base main --findings "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$from_root" ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].file')" = "app.py" ]
}

@test "plan: #1587 an explicit --findings-path is HONOURED, not overwritten by the anchored default" {
  # The `[[ -n "$findings_path" ]] ||` guard on the default had no coverage at
  # all: the flag appeared in the suite only in the need_value roster, which
  # exercises parse-time refusal and never an accepted value. Deleting the guard
  # (so the anchored default unconditionally overwrites the caller's sink) left
  # the whole suite green — and the redirection would be invisible in the
  # descriptor too, since _normalise_paths strips the anchored path from scope.
  _anchor_fixture
  local custom="$BATS_TEST_TMPDIR/custom-sink.json"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR/pkg" --base main --findings-path "$custom"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .findings_path)" = "$custom" ]
  # FIXTURE SELF-CHECK: $custom is unequal to the anchored default by
  # construction, so the equality above already settles this. Kept because it
  # names the specific wrong answer in the failure output, not because a
  # mutation reds it alone.
  [ "$(echo "$output" | jq -r .findings_path)" != "$AROOT/.review/findings-round-1.json" ]
}

@test "plan: #1587 a RELATIVE --findings-path is passed through verbatim, never anchored" {
  # The other half of the same guard: anchoring governs the DEFAULT only. A
  # caller's own relative spelling is its business — the header documents the
  # override as unfollowed by the scope exclusion, which is only true if it
  # reaches the descriptor unchanged.
  _anchor_fixture
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR/pkg" --base main --findings-path "some/relative/sink.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .findings_path)" = "some/relative/sink.json" ]
}

@test "detect: #1587 a git FAULT is refused, never silently anchored at the subdirectory" {
  # The fallback is keyed on the CAUSE, not the status. A git that fails for a
  # reason other than the DISCOVERY fatal — dubious ownership (this fixture), a
  # broken GIT_BIN, the gitfile fatal (its own case below) — must NOT be read as
  # "there is no repository here", which would anchor at the subdirectory and
  # reproduce the very misattribution #1587 removes, at exit 0 with nothing on
  # either stream. An unreadable `.git` is deliberately NOT in that list: it
  # takes the FALLBACK, because git's validation fails and discovery continues
  # upward — `_repo_anchor`'s KNOWN LIMIT block owns that case.
  _anchor_fixture
  local shim="$BATS_TEST_TMPDIR/faultgit"
  mkdir -p "$shim"
  cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
# fail ONLY on --show-toplevel, and with a cause that is not "not a git repository"
for a in "$@"; do
  if [ "$a" = "--show-toplevel" ]; then
    echo "fatal: detected dubious ownership in repository at '/x'" >&2
    exit 128
  fi
done
exec /usr/bin/env git "$@"
SH
  chmod +x "$shim/git"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    GIT_BIN="$shim/git" zsh "$S" detect --repo "$AR/pkg"
  [ "$status" -eq 1 ]
  # named line, and git's own cause relayed rather than swallowed
  echo "$stderr" | grep -q 'could not resolve the repository root'
  echo "$stderr" | grep -q 'dubious ownership'
  # and NO repo_type document was emitted on the fault path
  [ -z "$output" ]
}

@test "plan: #1587 a --repo with NO WORK TREE is refused, not anchored on the raw path" {
  # `_verify_base` probes `rev-parse --git-dir`, which SUCCEEDS for a bare
  # repository while `--show-toplevel` fails — so this case really does reach
  # `_repo_anchor`'s refusal arm from `plan`, contrary to an earlier draft of
  # the comment that called it unreachable. Without the refusal it anchored on
  # the raw path and surfaced as an exit-3 `unsupported_repo_type`: a verdict
  # about the repo when the truth is that the path has no tree to review.
  # CLONED from $R, not `init --bare`: an empty bare repo has no `main`, so
  # `_verify_base` would fail first and this case would pass for the wrong
  # reason — exit 1 with "--base does not resolve to a commit", never reaching
  # the anchor at all. The clone gives it a resolvable `main`.
  local bare="$BATS_TEST_TMPDIR/bare.git"
  git clone -q --bare "$R" "$bare"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$bare" --base main
  # exit 1 (environment), never 3 (a typed verdict about the repo's languages)
  [ "$status" -eq 1 ]
  echo "$stderr" | grep -q 'could not resolve the repository root'
  # git's own cause is relayed, not swallowed — this is what distinguishes the
  # no-work-tree refusal from a generic failure
  echo "$stderr" | grep -q 'must be run in a work tree'
  [ -z "$output" ]
  # FIXTURE SELF-CHECK, not a discriminating assertion: the script exits at the
  # first failing guard, so `_verify_base`'s message and the anchor's are
  # mutually exclusive and this can only fire once the grep above already has.
  # It is here to catch a fixture that stopped reaching the anchor (an empty
  # bare repo has no `main`), which is a mistake worth a loud failure — but no
  # mutation of the SUBJECT reds it alone. Same idiom as the SIGPIPE volume
  # check. Via the rostered `lacks` helper: a bare `! … | grep` is inert under
  # bats (#829) and so is a bare `[[ ]]` (#1011/#1067).
  lacks "$stderr" 'does not resolve to a commit'
}

@test "review-dispatch: #1587 all THREE subcommands anchor --repo — one call site each" {
  # A structural pin, in the idiom this file already uses for source-derived
  # invariants. What it covers is the shapes no behavioural case can see: a
  # SECOND call inside one subcommand, a line-wrapped or `|| { … }` spelling,
  # and a deleted call in a subcommand that has no refusal fixture of its own.
  #
  # It is NOT the only thing standing behind scope-findings' call site — an
  # earlier cut of this comment said so, and that stopped being true when
  # `scope-findings: #1587 a --repo with NO WORK TREE is refused` landed:
  # deleting the call there lets the bare-repo fixture pass `_verify_base`,
  # reach the empty-findings shortcut and print `[]` at exit 0, so that case
  # reds on plain deletion too. Do not delete either as redundant; they catch
  # different mutations.
  # THE REQUIREMENT THIS PINS, stated so a red here is actionable: each anchoring
  # call must be `repo=$(_repo_anchor "$repo") || exit 1` on ONE line. The grep
  # tolerates requoting the substitution and whitespace around the `||`, and
  # skips comment lines so a header quoting the call cannot inflate the count —
  # but it does NOT accept a line-wrapped spelling or the `|| { print …; exit 1 }`
  # form this script uses at its other error sites. That is deliberate rather
  # than an oversight: adding a per-site diagnostic there is a reasonable
  # follow-up, and it must update this pattern in the same change.
  # The awk half checks one call per subcommand and does NOT skip comments.
  local n
  n="$(grep -v '^[[:space:]]*#' "$S" \
       | grep -cE 'repo=.?\$\(_repo_anchor "\$repo"\).?[[:space:]]*\|\|[[:space:]]*exit 1')"
  [ "$n" -eq 3 ]
  # and one inside each subcommand, so three calls in cmd_plan would not pass.
  # The function-header regex is loosened for the same reason — `cmd_plan () {`
  # is the same function.
  local fn
  for fn in cmd_plan cmd_detect cmd_scope_findings; do
    awk -v f="$fn" '
      $0 ~ "^"f"[[:space:]]*\\(\\)" {inside=1}
      inside && /_repo_anchor "\$repo"/ {found++}
      inside && /^\}/ {inside=0}
      END {exit(found==1?0:1)}
    ' "$S" || { echo "$fn does not anchor exactly once"; return 1; }
  done
}

@test "plan: #1587 cmd_plan's OWN _worktree_root guard still fires — the SECOND --show-toplevel" {
  # Coverage restored for the guard #1582 added. Anchoring made `_repo_anchor`
  # the first thing to ask for the toplevel, so every fixture that fails EVERY
  # `--show-toplevel` now stops at the anchor and can never reach cmd_plan's own
  # guard. Without this case, replacing that guard with a bare
  # `worktree_root=$(_worktree_root "$repo")` leaves the whole suite green.
  #
  # The shim passes the FIRST --show-toplevel (so the anchor succeeds and the
  # plan proceeds) and fails the SECOND, which is cmd_plan's call: _verify_base
  # uses --git-dir and --verify, and no other site asks for --show-toplevel.
  echo "print(1)" > "$R/app.py"
  local counter="$BATS_TEST_TMPDIR/toplevel-calls"
  : > "$counter"
  local fakegit="$BATS_TEST_TMPDIR/git-second-toplevel-fails"
  cat > "$fakegit" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "--show-toplevel" ]; then
    printf 'x' >> "$counter"
    if [ "\$(wc -c < "$counter")" -ge 2 ]; then
      echo "second toplevel refused" >&2
      exit 128
    fi
  fi
done
exec git "\$@"
EOF
  chmod +x "$fakegit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_BIN="$fakegit" zsh "$S" plan --repo "$R" --base main --round 1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # the OWNER-SPECIFIC needle: this case cannot be satisfied by the anchor's line
  echo "$stderr" | grep -q -- 'plan: could not resolve the worktree root'
  # and the shim really did let the anchor through first, or the case would be
  # pinning the anchor again under a different name
  [ "$(wc -c < "$counter" | tr -d ' ')" -ge 2 ]
}

@test "scope-findings: #1587 a --repo with NO WORK TREE is refused, not silently scoped" {
  # The refusal arm reaches scope-findings too (its own comment says so), but
  # only the structural grep pinned that call site — which asserts the line
  # EXISTS, not that its status is honoured or that it runs before the
  # subcommand can answer. Concrete mutation this case reds and the structural
  # one does not: move the anchor (and _verify_base) BELOW the empty-findings
  # shortcut, a realistic "fast-path the empty case" edit. scope-findings then
  # prints [] at exit 0 where the contract says exit 1, telling a caller
  # "nothing in scope" for a repo that was never scoped.
  #
  # The MISSING findings file is what makes it discriminate: it is the input
  # that would take the shortcut.
  local bare="$BATS_TEST_TMPDIR/sf-bare.git"
  git clone -q --bare "$R" "$bare"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" scope-findings --repo "$bare" --base main \
      --findings "$BATS_TEST_TMPDIR/no-such-findings.json"
  [ "$status" -eq 1 ]
  # the load-bearing half: it must NOT be the `[]` shortcut
  [ -z "$output" ]
  echo "$stderr" | grep -q 'could not resolve the repository root'
  echo "$stderr" | grep -q 'must be run in a work tree'
}

@test "detect: #1587 a BROKEN gitfile is refused, not read as 'no repository here'" {
  # git emits two distinct fatals carrying `not a git repository`, meaning
  # opposite things. The discovery form — `(or any of the parent directories)` —
  # is the genuine no-repo case that anchors to itself. The gitfile form —
  # `not a git repository: <path>` — is a BROKEN repository: a `.git` FILE
  # pointing at a gitdir that is gone, exactly what `git worktree prune` or a
  # moved linked worktree leaves behind. This repo runs everything in worktrees,
  # so it is reachable.
  #
  # A bare `not a git repository` substring test matches both, and the broken
  # case would then anchor on the raw path at exit 0 with nothing on either
  # stream — the silent misattribution the cause-keying exists to refuse.
  local orphan="$BATS_TEST_TMPDIR/orphan"
  mkdir -p "$orphan"
  printf 'gitdir: %s/nowhere/.git/worktrees/gone\n' "$BATS_TEST_TMPDIR" > "$orphan/.git"
  printf 'primary: java\n' > "$orphan/.maintenance.yml"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["java","python"]}' \
    zsh "$S" detect --repo "$orphan"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'could not resolve the repository root'
  # git's own cause is relayed — this is what separates it from the discovery form
  echo "$stderr" | grep -q 'not a git repository'
}

@test "detect: #1587 the no-repository fallback survives a non-English locale" {
  # The cause key is a substring of git's own message, so it is closed only
  # because the probe pins LC_ALL=C. Without the pin, a developer with a
  # translated git refuses the ONE documented success path — `detect` on a plain
  # directory — while CI stays green.
  #
  # Driven by a GIT_BIN SHIM, deliberately, not by exporting a host locale. A
  # host-locale fixture is a canary, not a guard: `de_DE.UTF-8` is not generated
  # on ubuntu-latest and macOS's system git is commonly built without NLS, so on
  # both CI legs git would print English anyway and the case would pass with the
  # pin DELETED — the mutation it exists to catch. Worse, it would then mean
  # different things on the two legs. The shim makes the pin's presence the only
  # thing that decides, on every platform.
  #
  # The shim answers --show-toplevel in German UNLESS the probe pinned the C
  # locale, so: pin present -> English discovery fatal -> fallback -> exit 0
  # with the directory's own .maintenance.yml read; pin deleted -> German ->
  # no match -> exit 1. Everything else is delegated to the real git.
  local nogit="$BATS_TEST_TMPDIR/nogit-locale"
  mkdir -p "$nogit"
  printf 'primary: java\n' > "$nogit/.maintenance.yml"
  local fakegit="$BATS_TEST_TMPDIR/git-localised"
  cat > "$fakegit" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "--show-toplevel" ]; then
    if [ "${LC_ALL:-}" = "C" ]; then
      echo "fatal: not a git repository (or any of the parent directories): .git" >&2
    else
      echo "fatal: Kein Git-Repository (oder eines der uebergeordneten Verzeichnisse): .git" >&2
    fi
    exit 128
  fi
done
exec git "$@"
EOF
  chmod +x "$fakegit"
  # A hostile ambient locale on top, so the case also proves the pin is what
  # wins rather than the absence of a locale in the environment.
  # --separate-stderr, like every other contract case here: $output must be the
  # document alone. Merged, a stray warning about the bogus ambient locale would
  # surface as a jq parse failure rather than a meaningful red.
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["java","python"]}' \
    GIT_BIN="$fakegit" LC_ALL=de_DE.UTF-8 LANGUAGE=de LANG=de_DE.UTF-8 \
    zsh "$S" detect --repo "$nogit"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "java" ]
}

@test "plan: #1587 an UNREADABLE repository root is named, even when --repo itself is readable" {
  # The subcommands' -r/-x gates judge the RAW --repo; every reader below uses
  # the ANCHOR, which with a subdirectory --repo is a different directory. A
  # traversable-but-unreadable root is reachable through a readable pkg/, and
  # detect-stack would then report no languages — an exit-3
  # `unsupported_repo_type` verdict about a repo the process could not read.
  #
  # 0311, NOT 0711: the fixture's owner is the process running it, and 0711
  # grants the owner rwx, so a 0711 root is perfectly readable here and the case
  # passed at exit 0. 0311 (owner -wx) is what actually clears `-r` while
  # keeping `-x`, so git can still walk up to the toplevel and the guard is what
  # refuses.
  #
  # This drives the `-r` half ONLY. The gate is `[[ -r "$root" && -x "$root" ]]`,
  # and narrowing it to `-r` alone leaves the suite green — deliberately
  # unpinned, because no fixture can reach it: a subdirectory `--repo` must be
  # traversable to be opened at all, so a non-traversable ROOT is unreachable
  # through the only spelling that makes this gate load-bearing. The `-x` half is
  # defence-in-depth, in the same category as `:/` / `--full-name` /
  # `--no-relative` above. Do not "restore" an inert control for it.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  local ro="$BATS_TEST_TMPDIR/unreadable-root"
  mkdir -p "$ro/pkg"
  git -C "$ro" init -q
  git -C "$ro" config user.email t@example.com
  git -C "$ro" config user.name tester
  echo base > "$ro/README.md"
  git -C "$ro" add -A
  git -C "$ro" commit -qm base
  git -C "$ro" branch -M main
  chmod 0311 "$ro"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$ro/pkg" --base main
  chmod 0755 "$ro"
  [ "$status" -eq 1 ]
  # the exit-1 contract is a stderr diagnostic AND an empty stdout — paired here
  # like every other refusal case in this file, so a caller parsing stdout first
  # cannot find a half-document
  [ -z "$output" ]
  # named as the root, not blamed on detect-stack and not a typed exit 3
  echo "$stderr" | grep -q 'the repository root is not a readable directory'
}

@test "plan: #1587 the usability gates run BEFORE the anchor and name the caller's own spelling" {
  # The documented division of labour (script header, ARCHITECTURE.md): the
  # `-d`/`-r`/`-x` gates and `_verify_base` deliberately read the RAW `--repo`
  # and own the diagnostics that name it; the anchor runs after, for the readers
  # that DERIVE from it. Nothing pinned that ordering, so hoisting the anchor
  # above `_verify_base` — a plausible "resolve it as early as possible" edit —
  # left the whole suite green while every base/usability diagnostic silently
  # started naming the resolved ROOT instead of what the caller typed.
  _anchor_fixture
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" plan --repo "$AR/pkg" --base refs/heads/does-not-exist
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # the ref is named …
  echo "$stderr" | grep -q -- 'does not resolve to a commit'
  # … against the SUBDIRECTORY the caller passed, not the anchored root. This is
  # the discriminating half: with the anchor hoisted, stderr names $AROOT.
  echo "$stderr" | grep -qF -- "$AR/pkg"
}

# ---- #1587 the classifier needle's three disciplines ------------------------
# `_repo_anchor`'s discovery-fatal test is the whole anchoring enum, and its
# comment claims three deliberate disciplines: the C-locale pin, the `${err:l}`
# case fold, and the `fatal: `-at-line-start anchor around a `(or any` prefix
# chosen to cover BOTH discovery wordings. Only the locale one had a fixture, so
# three mutations passed. These drive the other two, and the wording breadth.
#
# All go through one shim: it answers --show-toplevel with an arbitrary fatal and
# delegates everything else to the real git, so each case differs only in the
# message under test.
_git_fatal_shim() {  # $1 = fatal text to emit on --show-toplevel
  # A per-call path, so two shims in one test body cannot collide and silently
  # give both call sites the second message.
  _GIT_FATAL_SHIM_N=$(( ${_GIT_FATAL_SHIM_N:-0} + 1 ))
  local path="$BATS_TEST_TMPDIR/fatal-shim-git-$_GIT_FATAL_SHIM_N"
  # The message goes in a SIDECAR file and the shim body is a SINGLE-quoted
  # heredoc, so no message content ever reaches the shell parser. Interpolating
  # $1 into the script would make a message containing a quote, `$` or a
  # backtick a fixture error rather than a result — the same class as the
  # `print -r --` 127 this helper already tripped over.
  printf '%s\n' "$1" > "$path.msg"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "--show-toplevel" ]; then
    cat "$0.msg" >&2
    exit 128
  fi
done
exec git "$@"
EOF
  chmod +x "$path"
  # printf, not zsh's `print`: bats bodies run under BASH, so a `print -r --`
  # here is a status-127 "command not found" that reads as a fixture failure.
  printf '%s\n' "$path"
}

# A plain directory carrying its own .maintenance.yml, so a successful fallback
# is observable as repo_type=java and a refusal as exit 1.
_fatal_fixture() {
  FF="$BATS_TEST_TMPDIR/fatal-fixture"
  mkdir -p "$FF"
  printf 'primary: java\n' > "$FF/.maintenance.yml"
}

@test "detect: #1587 the classifier is CASE-FOLDED — an older git's capital-N fatal still falls back" {
  # git emitted `Not a git repository (or any …)` before the message
  # lowercasing. Without `${err:l}` that git refuses the one documented success
  # path — `detect` on a plain directory — which is the same class the C-locale
  # pin closes. Mutation: `${err:l}` -> `${err}` leaves the suite green without
  # this case.
  _fatal_fixture
  local g; g="$(_git_fatal_shim 'fatal: Not a git repository (or any of the parent directories): .git')"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["java","python"]}' \
    GIT_BIN="$g" zsh "$S" detect --repo "$FF"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "java" ]
}

@test "detect: #1587 the classifier covers the MOUNT-POINT discovery wording too" {
  # git's second discovery wording, emitted when discovery stops at a filesystem
  # boundary — the message a /tmp-on-tmpfs host produces for an ordinary non-git
  # directory. `(or any` is the prefix chosen to cover both; narrowing it to
  # `(or any of the parent directories` refuses this at exit 1, contradicting
  # both ARCHITECTURE.md and the script's KNOWN LIMIT block, and the suite would
  # stay green without this case.
  _fatal_fixture
  local g; g="$(_git_fatal_shim 'fatal: not a git repository (or any parent up to mount point /tmp)')"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["java","python"]}' \
    GIT_BIN="$g" zsh "$S" detect --repo "$FF"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "java" ]
}

@test "detect: #1587 an interpolated PATH cannot impersonate the discovery fatal" {
  # `$err` carries caller-supplied paths on other fatals, so the test is anchored
  # at `fatal: ` on a LINE START. Unanchored, this dubious-ownership refusal —
  # whose quoted path embeds the needle — would match, and `detect` would anchor
  # at the subdirectory at exit 0: the silent misattribution the cause-keying
  # exists to refuse, arrived at through the message rather than the status.
  #
  # The embedded path carries `fatal: ` too, deliberately. That makes the case
  # discriminate BOTH halves of the needle: dropping the `$'\n'` line anchors
  # alone (keeping the `fatal: ` literal) still matches this fixture, so without
  # the prefix in the path the anchor half would be unpinned.
  _fatal_fixture
  local g; g="$(_git_fatal_shim "fatal: detected dubious ownership in repository at '/x/fatal: not a git repository (or any/y'")"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["java","python"]}' \
    GIT_BIN="$g" zsh "$S" detect --repo "$FF"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q 'could not resolve the repository root'
  echo "$stderr" | grep -q 'dubious ownership'
}

@test "scope-findings: #1587 the usability gates run BEFORE the anchor and name the caller's spelling" {
  # The plan twin of this case landed in round 3; scope-findings' half was
  # unpinned, so hoisting `repo=$(_repo_anchor "$repo") || exit 1` above
  # `_verify_base` in cmd_scope_findings left the suite green while every
  # base/usability diagnostic silently began naming the resolved root instead of
  # what the caller typed. The only other scope-findings base-failure case passes
  # the ROOT as --repo, so it cannot see which spelling is named.
  _anchor_fixture
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    DETECT_LANGS_JSON='{"languages":["go","python"]}' \
    zsh "$S" scope-findings --repo "$AR/pkg" --base refs/heads/does-not-exist \
      --findings "$BATS_TEST_TMPDIR/anything.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- 'does not resolve to a commit'
  # the discriminating half: with the anchor hoisted, stderr names $AROOT, which
  # never contains '/pkg'
  echo "$stderr" | grep -qF -- "$AR/pkg"
}
