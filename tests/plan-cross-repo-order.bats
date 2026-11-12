#!/usr/bin/env bats
#
# plan-cross-repo-order.zsh (#3082, epic #3073): the cross-repo order of an
# epic's children, and whether one child waits on a same-epic sibling in
# another repo. Child mode feeds resolve-issue's step 0a and blockers-first
# step 2; epic mode feeds E2's cross-repo plan. The script only reads: the
# dependency precheck stays the gate.
#
# gh is stubbed via the GH_BIN seam. The stub tells the parent lookup
# (read-sub-issues.zsh --child, whose query reads `parent{`) from the epic read
# (`subIssues`) by the query text, and serves parent-<N>.json / epic-<N>.json
# by the `-F number=<N>` argument. Prose pins are anchored by content (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/development/skills/resolve-issue"
  S="$SKILL_DIR/scripts/plan-cross-repo-order.zsh"
  FIX="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$FIX"
  STUB="$BATS_TEST_TMPDIR/gh-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_FAIL:-}" ] && exit 1
prev="" num="" q=""
for a in "$@"; do
  if [ "$prev" = "-f" ]; then case "$a" in query=*) q="$a" ;; esac; fi
  if [ "$prev" = "-F" ]; then case "$a" in number=*) num="${a#number=}" ;; esac; fi
  prev="$a"
done
case "$q" in *'parent{'*) f="$FIX/parent-$num.json" ;; *) f="$FIX/epic-$num.json" ;; esac
if [ -f "$f" ]; then cat "$f"; else echo '{"data":{"repository":{"issue":null}}}'; fi
EOF
  chmod +x "$STUB"
}

# mk_parent <child> <parent-number> <parent-repo>
mk_parent() {
  jq -n --argjson c "$1" --argjson p "$2" --arg r "$3" \
    '{data:{repository:{issue:{number:$c, parent:{number:$p, state:"OPEN", repository:{nameWithOwner:$r}}}}}}' \
    > "$FIX/parent-$1.json"
}

# mk_no_parent <child>
mk_no_parent() {
  jq -n --argjson c "$1" '{data:{repository:{issue:{number:$c, parent:null}}}}' > "$FIX/parent-$1.json"
}

# mk_epic <epic> <kids-json>, each kid [number, state, repo, [[n, state, repo], ...blockers]]
mk_epic() {
  jq -n --argjson e "$1" --argjson kids "$2" \
    '{data:{repository:{issue:{number:$e, subIssues:{nodes:($kids | map({
        number:.[0], state:.[1], repository:{nameWithOwner:.[2]},
        blockedBy:{nodes:(.[3] | map({number:.[0], state:.[1], repository:{nameWithOwner:.[2]}}))}}))}}}}}' \
    > "$FIX/epic-$1.json"
}

plan() { run --separate-stderr env GH_BIN="$STUB" FIX="$FIX" zsh "$S" "$@"; }

# The run that prompted #3082: docs#12 first, then infra#40, then web#7, and
# infra#41 waits on web#7. web#8 is closed and blocks nobody.
mk_cross_epic() {
  mk_epic 9 '[
    [12, "OPEN",   "o/docs",  []],
    [40, "OPEN",   "o/infra", [[12, "OPEN", "o/docs"]]],
    [41, "OPEN",   "o/infra", [[7, "OPEN", "o/web"]]],
    [7,  "OPEN",   "o/web",   [[40, "OPEN", "o/infra"]]],
    [8,  "CLOSED", "o/web",   []]
  ]'
}

flat() { tr '\n' ' ' | tr -s ' '; }

# ---- child mode -------------------------------------------------------------

@test "AC2: a child whose same-epic sibling in another repo is open waits, naming the sibling, its repo and the sibling to run first" {
  mk_parent 41 9 o/infra
  mk_cross_epic
  plan --repo o/infra --issue 41
  [ "$status" -eq 10 ]
  [ "$(jq -r .decision <<<"$output")" = wait ]
  [ "$(jq -c .wait_on <<<"$output")" = '["o/web#7"]' ]
  [ "$(jq -c .run_first <<<"$output")" = '["o/docs#12"]' ]
  [ "$(jq -r '.lines[0]' <<<"$output")" = "o/infra#41 waits on its same-epic sibling o/web#7 in o/web" ]
  [ "$(jq -r '.lines[1]' <<<"$output")" = "run first: o/docs#12 — start /development:resolve-issue 12 in a session on o/docs" ]
}

@test "AC2: a child whose cross-repo siblings impose no open blocker proceeds, exit 0" {
  mk_parent 40 9 o/infra
  mk_epic 9 '[
    [12, "CLOSED", "o/docs",  []],
    [40, "OPEN",   "o/infra", [[12, "CLOSED", "o/docs"]]],
    [7,  "OPEN",   "o/web",   [[40, "OPEN", "o/infra"]]]
  ]'
  plan --repo o/infra --issue 40
  [ "$status" -eq 0 ]
  [ "$(jq -r .decision <<<"$output")" = proceed ]
  [ "$(jq -c .wait_on <<<"$output")" = '[]' ]
  [ "$(jq -c .lines <<<"$output")" = '["o/infra#40: no open same-epic blocker in another repo"]' ]
}

@test "child mode: a blocker outside the epic is the precheck's, never a sibling wait" {
  mk_parent 40 9 o/infra
  mk_epic 9 '[
    [40, "OPEN", "o/infra", [[99, "OPEN", "o/elsewhere"]]],
    [7,  "OPEN", "o/web",   []]
  ]'
  plan --repo o/infra --issue 40
  [ "$status" -eq 0 ]
  [ "$(jq -r .decision <<<"$output")" = proceed ]
}

@test "child mode: an open same-repo sibling blocker is not a cross-repo wait" {
  mk_parent 41 9 o/infra
  mk_epic 9 '[
    [40, "OPEN", "o/infra", []],
    [41, "OPEN", "o/infra", [[40, "OPEN", "o/infra"]]],
    [7,  "OPEN", "o/web",   []]
  ]'
  plan --repo o/infra --issue 41
  [ "$status" -eq 0 ]
  [ "$(jq -r .decision <<<"$output")" = proceed ]
}

@test "child mode: the parent epic may live in another repo, and refs match case-insensitively" {
  mk_parent 41 3 O/Hub
  mk_epic 3 '[
    [5,  "OPEN", "O/Docs",  []],
    [41, "OPEN", "O/Infra", [[5, "OPEN", "O/Docs"]]]
  ]'
  plan --repo o/infra --issue 41
  [ "$status" -eq 10 ]
  [ "$(jq -r .epic <<<"$output")" = "o/hub#3" ]
  [ "$(jq -c .wait_on <<<"$output")" = '["o/docs#5"]' ]
}

@test "child mode: siblings that wait on each other leave nothing to run first, and the line says so" {
  mk_parent 41 9 o/infra
  mk_epic 9 '[
    [41, "OPEN", "o/infra", [[7, "OPEN", "o/web"]]],
    [7,  "OPEN", "o/web",   [[6, "OPEN", "o/web"]]],
    [6,  "OPEN", "o/web",   [[7, "OPEN", "o/web"]]]
  ]'
  plan --repo o/infra --issue 41
  [ "$status" -eq 10 ]
  [ "$(jq -c .run_first <<<"$output")" = '[]' ]
  [ "$(jq -c .cycle <<<"$output")" = '["o/infra#41","o/web#7","o/web#6"]' ]
  [ "$(jq -r '.lines[1]' <<<"$output")" = "run first: none ready — the siblings it waits on form a cycle" ]
}

@test "child mode: a run-first sibling that blocks the issue in its own repo is cleared by this run, never a separate session (#3088)" {
  mk_parent 41 9 o/infra
  mk_epic 9 '[
    [40, "OPEN", "o/infra", []],
    [41, "OPEN", "o/infra", [[40, "OPEN", "o/infra"], [7, "OPEN", "o/web"]]],
    [7,  "OPEN", "o/web",   [[40, "OPEN", "o/infra"]]]
  ]'
  plan --repo o/infra --issue 41
  [ "$status" -eq 10 ]
  [ "$(jq -c .run_first <<<"$output")" = '["o/infra#40"]' ]
  [ "$(jq -r '.lines[1]' <<<"$output")" = "run first: o/infra#40 — a blocker of o/infra#41 in this session's repo: a blockers-first run clears it before the wait; otherwise start /development:resolve-issue 40 here" ]
  [ "$(jq -c .lines <<<"$output" | grep -c 'in a session on o/infra')" -eq 0 ]
}

@test "child mode: a foreign sibling reached through a sibling blocker in this repo is waited on, as the precheck sees it" {
  mk_parent 41 9 o/infra
  mk_epic 9 '[
    [7,  "OPEN", "o/web",   []],
    [40, "OPEN", "o/infra", [[7, "OPEN", "o/web"]]],
    [41, "OPEN", "o/infra", [[40, "OPEN", "o/infra"]]]
  ]'
  plan --repo o/infra --issue 41
  [ "$status" -eq 10 ]
  [ "$(jq -c .wait_on <<<"$output")" = '["o/web#7"]' ]
  [ "$(jq -r '.lines[1]' <<<"$output")" = "run first: o/web#7 — start /development:resolve-issue 7 in a session on o/web" ]
}

@test "child mode: a same-repo run-first sibling reached only through another repo keeps the separate-session line" {
  mk_parent 41 9 o/infra
  mk_epic 9 '[
    [40, "OPEN", "o/infra", []],
    [41, "OPEN", "o/infra", [[7, "OPEN", "o/web"]]],
    [7,  "OPEN", "o/web",   [[40, "OPEN", "o/infra"]]]
  ]'
  plan --repo o/infra --issue 41
  [ "$status" -eq 10 ]
  [ "$(jq -r '.lines[1]' <<<"$output")" = "run first: o/infra#40 — start /development:resolve-issue 40 in a session on o/infra" ]
}

@test "child mode: an issue with no parent epic exits 3 with nothing on stdout" {
  mk_no_parent 41
  plan --repo o/infra --issue 41
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# ---- epic mode --------------------------------------------------------------

@test "AC3: a cross-repo epic prints the full order and the next session in each other repo; only same-repo children are this session's" {
  mk_cross_epic
  plan --repo o/infra --epic 9
  [ "$status" -eq 0 ]
  [ "$(jq -c .order <<<"$output")" = '["o/docs#12","o/infra#40","o/web#7","o/infra#41"]' ]
  [ "$(jq -c .local_order <<<"$output")" = '[40,41]' ]
  [ "$(jq -c .next_sessions <<<"$output")" = '[{"repo":"o/docs","next":"o/docs#12","waits_on":[]},{"repo":"o/web","next":null,"waits_on":["o/infra#40"]}]' ]
  run jq -r '.lines[]' <<<"$output"
  [ "${lines[0]}" = "cross-repo order of o/infra#9:" ]
  [ "${lines[1]}" = "  1. o/docs#12 — ready" ]
  [ "${lines[2]}" = "  2. o/infra#40 — after o/docs#12" ]
  [ "${lines[3]}" = "  3. o/web#7 — after o/infra#40" ]
  [ "${lines[4]}" = "  4. o/infra#41 — after o/web#7" ]
  [ "${lines[5]}" = "this session (o/infra) resolves: #40, #41" ]
  [ "${lines[6]}" = "next session in o/docs: /development:resolve-issue 12 (o/docs#12)" ]
  [ "${lines[7]}" = "next session in o/web: none ready — waits on o/infra#40" ]
  [ "${#lines[@]}" -eq 8 ]
}

@test "epic mode: the order keeps sub-issue order where no edge forces another" {
  mk_epic 9 '[
    [3, "OPEN", "o/infra", []],
    [1, "OPEN", "o/web",   []],
    [2, "OPEN", "o/infra", []]
  ]'
  plan --repo o/infra --epic 9
  [ "$status" -eq 0 ]
  [ "$(jq -c .order <<<"$output")" = '["o/infra#3","o/web#1","o/infra#2"]' ]
  [ "$(jq -c .local_order <<<"$output")" = '[3,2]' ]
}

@test "epic mode: next is a repo's first ready sibling, waits_on its earliest sibling's blockers, and a repo of closed siblings has no entry" {
  mk_epic 9 '[
    [1,  "OPEN",   "o/a",     []],
    [2,  "OPEN",   "o/a",     []],
    [10, "OPEN",   "o/infra", []],
    [3,  "OPEN",   "o/b",     [[10, "OPEN", "o/infra"]]],
    [11, "OPEN",   "o/infra", []],
    [4,  "OPEN",   "o/b",     [[11, "OPEN", "o/infra"]]],
    [12, "OPEN",   "o/infra", []],
    [5,  "OPEN",   "o/c",     [[12, "OPEN", "o/infra"]]],
    [6,  "OPEN",   "o/c",     []],
    [7,  "CLOSED", "o/d",     []]
  ]'
  plan --repo o/infra --epic 9
  [ "$(jq -c .next_sessions <<<"$output")" = '[{"repo":"o/a","next":"o/a#1","waits_on":[]},{"repo":"o/b","next":null,"waits_on":["o/infra#10"]},{"repo":"o/c","next":"o/c#6","waits_on":[]}]' ]
}

@test "epic mode: a cycle is listed apart and its line says no order places it" {
  mk_epic 9 '[
    [1, "OPEN", "o/infra", [[2, "OPEN", "o/web"]]],
    [2, "OPEN", "o/web",   [[1, "OPEN", "o/infra"]]]
  ]'
  plan --repo o/infra --epic 9
  [ "$status" -eq 0 ]
  [ "$(jq -c .order <<<"$output")" = '[]' ]
  [ "$(jq -c .cycle <<<"$output")" = '["o/infra#1","o/web#2"]' ]
  contains "$(jq -r '.lines[]' <<<"$output")" "  cycle: o/infra#1, o/web#2 — no order places these"
  contains "$(jq -r '.lines[]' <<<"$output")" "this session (o/infra) resolves: none"
}

# ---- failures ---------------------------------------------------------------

@test "a failed gh read is an internal failure, exit 1" {
  mk_cross_epic
  run --separate-stderr env GH_BIN="$STUB" FIX="$FIX" GH_FAIL=1 zsh "$S" --repo o/infra --epic 9
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a missing epic, or an issue not among its parent's sub-issues, is exit 1" {
  plan --repo o/infra --epic 77
  [ "$status" -eq 1 ]
  mk_parent 41 9 o/infra
  mk_epic 9 '[[40, "OPEN", "o/infra", []]]'
  plan --repo o/infra --issue 41
  [ "$status" -eq 1 ]
  contains "$stderr" "is not among them"
}

@test "a failed parent lookup is exit 1, never a no-parent exit 3" {
  plan --repo o/infra --issue 41
  [ "$status" -eq 1 ]
  contains "$stderr" "read-sub-issues.zsh --child failed"
}

@test "--help prints the usage line and exits 0 without a gh call" {
  run --separate-stderr env GH_BIN=/nonexistent zsh "$S" --help
  [ "$status" -eq 0 ]
  [ "$output" = "usage: plan-cross-repo-order.zsh --repo OWNER/NAME (--issue N | --epic N)" ]
}

@test "usage errors exit 2" {
  plan --issue 4
  [ "$status" -eq 2 ]
  plan --repo nope --issue 4
  [ "$status" -eq 2 ]
  plan --repo o/r --issue 4 --epic 5
  [ "$status" -eq 2 ]
  plan --repo o/r
  [ "$status" -eq 2 ]
  plan --repo o/r --epic x
  [ "$status" -eq 2 ]
  plan --repo o/r --bogus
  [ "$status" -eq 2 ]
}

# ---- the prose that consumes it ----------------------------------------------

@test "AC1/AC2: step 0a runs the sibling report before the precheck and a blockers-first stop carries its lines" {
  skill="$(flat < "$SKILL_DIR/SKILL.md")"
  contains "$skill" "Before the gate or a branch, report same-epic siblings in other repos (\`reference/epic-tree.md\` § *Same-epic siblings in other repos (#3082)*), then run the precheck:"
  s="$(flat < "$SKILL_DIR/reference/epic-tree.md")"
  contains "$s" "## Same-epic siblings in other repos (#3082) Step 0a runs this report right before the dependency precheck, on every single-issue run, an epic's leaves included: \`\"<skill-base-dir>/scripts/plan-cross-repo-order.zsh\" --repo \"\$REPO\" --issue <N>\`."
  contains "$s" "It reads the parent epic's sub-issues in every repo, with their blocked-by links, and decides nothing: the precheck stays the one gate."
  contains "$s" "Exit 10 means a same-epic sibling in another repo still blocks the issue: say its \`lines\` once, which name that sibling and the sibling to run first, each with its repo; a blockers-first stop on that sibling adds them to its reason (\`reference/interactive/blockers-first.md\` step 2)."
  contains "$s" "Exit 1 costs only that report: say so in one line and go on."
  contains "$s" "Exit 0 and exit 3 (no parent epic) add nothing."
  contains "$s" "Exit 2 is your own call: fix it and re-run once."
}

@test "AC2: blockers-first runs the planner before the bounded wait on a foreign blocker" {
  s="$(flat < "$SKILL_DIR/reference/interactive/blockers-first.md")"
  contains "$s" "Before the first wait, run \`\"<skill-base-dir>/scripts/plan-cross-repo-order.zsh\" --repo <owner/name> --issue <target>\` once and print its \`lines\` (#3082)."
  contains "$s" "On its exit 10 they name each open same-epic sibling the target waits on and the sibling to run first, each with its repo, so the human can start that repo's session while the root waits."
  contains "$s" "Its exit 0 or 3 prints nothing more."
  contains "$s" "Its exit 1, or a second exit 2, never stops the wait: name it in one line."
  plan_at="${s%%plan-cross-repo-order.zsh*}"
  lacks "$plan_at" "Watch it with one bounded"
}

@test "AC3: E2 prints the cross-repo plan, orders same-repo children by it and never drives another repo" {
  s="$(flat < "$SKILL_DIR/reference/epic-tree.md")"
  contains "$s" "**A cross-repo epic is ordered across its repos (#3082).** When the tree holds a \`foreign\` node, run \`\"<skill-base-dir>/scripts/plan-cross-repo-order.zsh\" --repo \"\$REPO\" --epic <P>\` once for each open node \`P\` with a \`foreign\` child, the target included, and print its \`lines\` in the run output."
  contains "$s" "They give the full cross-repo order and name the next session to start in each other repo."
  contains "$s" "Order \`P\`'s same-repo children by its \`local_order\`, which places each one after every sibling it waits on in any repo; an inner child's leaves take that child's place."
  contains "$s" "The run never drives another repo: a \`foreign\` node is still listed, never built, and a leaf whose foreign sibling blocker is still open is parked by its own step 0a."
  contains "$s" "E3's summary comment carries the same \`lines\`."
  contains "$s" "An exit 1, or a second exit 2, costs only the plan: order as above without it, and say in the summary that the cross-repo plan could not be read."
}

@test "the explanation page names the sibling report and the cross-repo plan" {
  s="$(flat < "$REPO_ROOT/docs/explanation/workflow-resolve-issue.md")"
  contains "$s" "When that foreign blocker is a sibling under the same epic, the run also reads the epic's children in every repository and names the sibling to run first, and its repository (#3082)."
  contains "$s" "An epic with children in other repositories also gets a cross-repo plan: the full order across its repositories, and the next session to start in each other one. The run resolves only its own repository's children (#3082)."
}
