#!/usr/bin/env bats
#
# #3214: the budget of a /development:maintenance run. apply-run-budget.zsh
# splits the concern-ordered groups into what runs and what is deferred — by a
# per-concern cap, by the open-queue cap or by the cutoff — and
# count-open-queue.zsh counts the Maintenance App's open PRs that still wait
# for a human. `gh` is a stub that serves fixture JSON from $FIX; it sits FIRST
# on PATH, so a host copy of `gh` (the ubuntu runner ships one in /usr/bin) is
# never reached. Every login and repo here is invented.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GITHUB_ACTIONS GH_TOKEN
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/maintenance/scripts"
  BUDGET="$SCRIPTS/apply-run-budget.zsh"
  QUEUE="$SCRIPTS/count-open-queue.zsh"
  export FIX="$BATS_TEST_TMPDIR/fix"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FIX"
  [ -x "$BUDGET" ]
  [ -x "$QUEUE" ]
  stub_gh
}

# gh: logs argv; `pr list` is served from $FIX/prs.json. GH_FAIL=prs fails it.
# `repo view` names the repo Acme/widgets, so the owner's App is
# claude-maintenance-acme.
stub_gh() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr list") [ "${GH_FAIL:-}" != prs ] || exit 1; cat "$FIX/prs.json" ;;
  "repo view") echo Acme/widgets ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}

# One group: concern $1, opens_pr $2 (default true), tool $3 (default t).
group() {
  jq -cn --arg c "$1" --argjson o "${2:-true}" --arg t "${3:-t}" '{tool: $t, concern: $c, opens_pr: $o}'
}

# An array of groups: each argument is "<concern>[:<opens_pr>]", tools t1, t2, …
groups() {
  local i=0 spec out=()
  for spec in "$@"; do
    i=$((i + 1))
    case "$spec" in
      *:*) out+=("$(group "${spec%%:*}" "${spec#*:}" "t$i")") ;;
      *) out+=("$(group "$spec" true "t$i")") ;;
    esac
  done
  printf '%s\n' "${out[@]}" | jq -cs .
}

# Run the budget over $IN with the given flags.
budget() {
  run --separate-stderr zsh "$BUDGET" "$@" <<<"$IN"
}

# ---- apply-run-budget.zsh: caps ---------------------------------------------

@test "budget: scheduled, the sixth security group is deferred by cap and the order holds" {
  IN="$(groups security security security security security security dependencies)"
  budget --caps '{}' --scheduled --queue 0 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.run[].tool] | join(",")' <<<"$output")" = "t1,t2,t3,t4,t5,t7" ]
  [ "$(jq -r '[.deferred[] | "\(.tool):\(.deferred_by)"] | join(",")' <<<"$output")" = "t6:cap" ]
}

@test "budget: scheduled, each default cap — dependencies 5, bugs 5, codequality 10, topic 10" {
  local specs=() c n
  for c in dependencies:6 bugs:6 codequality:11 topic:11; do
    for n in $(seq 1 "${c#*:}"); do specs+=("${c%%:*}"); done
  done
  IN="$(groups "${specs[@]}")"
  budget --caps '{}' --scheduled --queue 0 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.run[].concern] | group_by(.) | map({(.[0]): length}) | add' <<<"$output")" = '{"bugs":5,"codequality":10,"dependencies":5,"topic":10}' ]
  [ "$(jq -c '[.deferred[] | .concern + ":" + .deferred_by]' <<<"$output")" = '["dependencies:cap","bugs:cap","codequality:cap","topic:cap"]' ]
}

@test "budget: a capped group yields to the next concern, which still runs" {
  IN="$(groups dependencies dependencies codequality)"
  budget --caps '{"dependencies":1}' --scheduled --queue 0 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.run[].tool] | join(",")' <<<"$output")" = "t1,t3" ]
  [ "$(jq -r '.deferred[0].tool + ":" + .deferred[0].deferred_by' <<<"$output")" = "t2:cap" ]
}

@test "budget: --caps overrides only the concerns it names" {
  IN="$(groups security security security codequality codequality codequality)"
  budget --caps '{"security":2,"codequality":1}' --scheduled --queue 0 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.run[].tool] | join(",")' <<<"$output")" = "t1,t2,t4" ]
  [ "$(jq -r '[.deferred[].tool] | join(",")' <<<"$output")" = "t3,t5,t6" ]
}

@test "budget: a cap of 0 defers every group of that concern" {
  IN="$(groups topic topic)"
  budget --caps '{"topic":0}' --scheduled --queue 0 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq '.run | length' <<<"$output")" -eq 0 ]
  [ "$(jq -r '[.deferred[].deferred_by] | join(",")' <<<"$output")" = "cap,cap" ]
}

@test "budget: every field of a group is kept, in run and in deferred" {
  IN='[{"tool":"ruff","concern":"codequality","opens_pr":true,"target":"python","priority_score":7},
       {"tool":"semgrep","concern":"codequality","opens_pr":true,"target":"python","priority_score":3}]'
  budget --caps '{"codequality":1}' --scheduled --queue 0 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -c '.run[0]' <<<"$output")" = '{"tool":"ruff","concern":"codequality","opens_pr":true,"target":"python","priority_score":7}' ]
  [ "$(jq -c '.deferred[0]' <<<"$output")" = '{"tool":"semgrep","concern":"codequality","opens_pr":true,"target":"python","priority_score":3,"deferred_by":"cap"}' ]
}

# ---- apply-run-budget.zsh: an attended run ----------------------------------

@test "budget: without --scheduled only bugs is capped, at 5" {
  local specs=() n
  for n in 1 2 3 4 5 6 7; do specs+=(security); done
  for n in 1 2 3 4 5 6 7; do specs+=(bugs); done
  IN="$(groups "${specs[@]}")"
  budget --caps '{}'
  [ "$status" -eq 0 ]
  [ "$(jq '[.run[] | select(.concern == "security")] | length' <<<"$output")" -eq 7 ]
  [ "$(jq '[.run[] | select(.concern == "bugs")] | length' <<<"$output")" -eq 5 ]
  [ "$(jq -c '[.deferred[] | .concern + ":" + .deferred_by]' <<<"$output")" = '["bugs:cap","bugs:cap"]' ]
}

@test "budget: without --scheduled the queue and the cutoff are ignored" {
  IN="$(groups security codequality)"
  budget --caps '{"security":0}' --queue 9 --queue-cap 5 --cutoff-epoch 50 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.run[].tool] | join(",")' <<<"$output")" = "t1,t2" ]
  [ "$(jq '.deferred | length' <<<"$output")" -eq 0 ]
}

@test "budget: without --scheduled --caps still moves the bugs cap" {
  IN="$(groups bugs bugs bugs)"
  budget --caps '{"bugs":2}'
  [ "$status" -eq 0 ]
  [ "$(jq '.run | length' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.deferred[0].deferred_by' <<<"$output")" = "cap" ]
}

# ---- apply-run-budget.zsh: the open queue -----------------------------------

@test "budget: a queue at the cap defers every PR-opening group and none of the others" {
  IN="$(groups security:true dependencies:false dependencies:true codequality:false)"
  budget --caps '{}' --scheduled --queue 5 --queue-cap 5 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.run[].tool] | join(",")' <<<"$output")" = "t2,t4" ]
  [ "$(jq -r '[.deferred[] | "\(.tool):\(.deferred_by)"] | join(",")' <<<"$output")" = "t1:queue,t3:queue" ]
}

@test "budget: a queue above the cap defers the same way; one below it defers nothing" {
  IN="$(groups security)"
  budget --caps '{}' --scheduled --queue 7 --queue-cap 5 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '.deferred[0].deferred_by' <<<"$output")" = "queue" ]
  budget --caps '{}' --scheduled --queue 4 --queue-cap 5 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq '.run | length' <<<"$output")" -eq 1 ]
}

@test "budget: --queue-cap overrides the default" {
  IN="$(groups security)"
  budget --caps '{}' --scheduled --queue 2 --queue-cap 2 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '.deferred[0].deferred_by' <<<"$output")" = "queue" ]
}

@test "budget: --queue-cap defaults to 5" {
  IN="$(groups security)"
  budget --caps '{}' --scheduled --queue 5 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '.deferred[0].deferred_by' <<<"$output")" = "queue" ]
  budget --caps '{}' --scheduled --queue 4 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq '.deferred | length' <<<"$output")" -eq 0 ]
}

@test "budget: a group the queue defers does not count against its concern's cap" {
  IN="$(groups dependencies:true dependencies:false)"
  budget --caps '{"dependencies":1}' --scheduled --queue 5 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.run[].tool] | join(",")' <<<"$output")" = "t2" ]
  [ "$(jq -r '.deferred[0].deferred_by' <<<"$output")" = "queue" ]
}

# ---- apply-run-budget.zsh: the cutoff ---------------------------------------

@test "budget: at the cutoff everything is deferred by cutoff" {
  IN="$(groups security:true dependencies:false codequality:true)"
  budget --caps '{}' --scheduled --queue 0 --cutoff-epoch 100 --now-epoch 100
  [ "$status" -eq 0 ]
  [ "$(jq '.run | length' <<<"$output")" -eq 0 ]
  [ "$(jq -r '[.deferred[].deferred_by] | join(",")' <<<"$output")" = "cutoff,cutoff,cutoff" ]
}

@test "budget: after the cutoff the cutoff wins over a full queue and a cap" {
  IN="$(groups security security)"
  budget --caps '{"security":0}' --scheduled --queue 9 --cutoff-epoch 100 --now-epoch 160
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.deferred[].deferred_by] | join(",")' <<<"$output")" = "cutoff,cutoff" ]
}

@test "budget: one second before the cutoff nothing is deferred by it" {
  IN="$(groups security)"
  budget --caps '{}' --scheduled --queue 0 --cutoff-epoch 100 --now-epoch 99
  [ "$status" -eq 0 ]
  [ "$(jq '.run | length' <<<"$output")" -eq 1 ]
}

@test "budget: --scheduled without --cutoff-epoch has no cutoff" {
  IN="$(groups security)"
  budget --caps '{}' --scheduled --queue 0
  [ "$status" -eq 0 ]
  [ "$(jq '.run | length' <<<"$output")" -eq 1 ]
}

@test "budget: --now-epoch defaults to the clock, so a cutoff in the past defers" {
  IN="$(groups security)"
  budget --caps '{}' --scheduled --queue 0 --cutoff-epoch 1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.deferred[0].deferred_by' <<<"$output")" = "cutoff" ]
}

@test "budget: an empty plan is an empty split" {
  IN='[]'
  budget --caps '{}' --scheduled --queue 0
  [ "$status" -eq 0 ]
  [ "$output" = '{"run":[],"deferred":[]}' ]
}

# ---- apply-run-budget.zsh: usage --------------------------------------------

@test "budget: no --caps is a usage error" {
  IN='[]'
  budget --scheduled --queue 0
  [ "$status" -eq 2 ]
  contains "$stderr" "--caps is required"
}

@test "budget: --scheduled without --queue is a usage error" {
  IN='[]'
  budget --caps '{}' --scheduled
  [ "$status" -eq 2 ]
  contains "$stderr" "--scheduled needs --queue"
}

@test "budget: --caps naming an unknown concern, or a negative or fractional cap, is a usage error" {
  IN='[]'
  local bad
  for bad in '{"lint":3}' '{"security":-1}' '{"security":1.5}' '[]' 'nope'; do
    budget --caps "$bad"
    [ "$status" -eq 2 ]
    contains "$stderr" "--caps must be one JSON object"
  done
}

@test "budget: a flag value that is not a non-negative integer is a usage error" {
  IN='[]'
  local flag
  for flag in --queue --queue-cap --cutoff-epoch --now-epoch; do
    budget --caps '{}' --scheduled --queue 0 "$flag" -3
    [ "$status" -eq 2 ]
  done
  budget --caps '{}' --scheduled --queue x
  [ "$status" -eq 2 ]
  contains "$stderr" "--queue must be a non-negative integer"
}

@test "budget: an unknown flag, a repeated flag or a flag without its value is a usage error" {
  IN='[]'
  budget --caps '{}' --batch 3
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown argument '--batch'"
  budget --caps '{}' --caps '{}'
  [ "$status" -eq 2 ]
  contains "$stderr" "--caps given twice"
  budget --caps '{}' --scheduled --scheduled --queue 0
  [ "$status" -eq 2 ]
  contains "$stderr" "--scheduled given twice"
  budget --caps
  [ "$status" -eq 2 ]
  contains "$stderr" "--caps needs a value"
}

@test "budget: a group with no opens_pr, or an unknown concern, is a usage error" {
  IN='[{"tool":"ruff","concern":"codequality"}]'
  budget --caps '{}'
  [ "$status" -eq 2 ]
  contains "$stderr" 'a boolean "opens_pr"'
  IN='[{"tool":"ruff","concern":"lint","opens_pr":true}]'
  budget --caps '{}'
  [ "$status" -eq 2 ]
  IN='{"tool":"ruff"}'
  budget --caps '{}'
  [ "$status" -eq 2 ]
}

@test "budget: no jq is an internal failure (exit 1)" {
  local bin="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$bin"
  ln -s "$(command -v zsh)" "$bin/zsh"
  IN='[]'
  run --separate-stderr env PATH="$bin" zsh "$BUDGET" --caps '{}' <<<"$IN"
  [ "$status" -eq 1 ]
  contains "$stderr" "jq not found"
}

# ---- count-open-queue.zsh ---------------------------------------------------

@test "queue: counts the Maintenance App's open PRs with no approving review" {
  cat > "$FIX/prs.json" <<'EOF'
[{"number":1,"author":{"login":"app/claude-maintenance-acme"},"latestReviews":[]},
 {"number":2,"author":{"login":"claude-maintenance-acme[bot]"},"latestReviews":[{"state":"COMMENTED"}]},
 {"number":3,"author":{"login":"app/claude-maintenance-acme"},"latestReviews":[{"state":"CHANGES_REQUESTED"}]}]
EOF
  run --separate-stderr zsh "$QUEUE"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "queue: the App's slug comes from the registry when it holds one" {
  mkdir -p "$HOME/.config/claude-plugins"
  printf '{"owners":{"acme":{"claude_maintenance":{"slug":"acme-upkeep"}}}}\n' > "$HOME/.config/claude-plugins/apps.json"
  cat > "$FIX/prs.json" <<'EOF'
[{"number":1,"author":{"login":"acme-upkeep[bot]"},"latestReviews":[]},
 {"number":2,"author":{"login":"app/acme-upkeep"},"latestReviews":[]},
 {"number":3,"author":{"login":"app/claude-maintenance-acme"},"latestReviews":[]}]
EOF
  run --separate-stderr zsh "$QUEUE"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "queue: a vendor PR is never counted" {
  cat > "$FIX/prs.json" <<'EOF'
[{"number":1,"author":{"login":"app/dependabot"},"latestReviews":[]},
 {"number":2,"author":{"login":"app/renovate"},"latestReviews":[]},
 {"number":3,"author":{"login":"snyk-bot"},"latestReviews":[]},
 {"number":4,"author":{"login":"app/claude-maintenance-acme"},"latestReviews":[]}]
EOF
  run --separate-stderr zsh "$QUEUE"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "queue: an approved bot PR is not counted, nor a human's or a look-alike login's" {
  cat > "$FIX/prs.json" <<'EOF'
[{"number":1,"author":{"login":"app/claude-maintenance-acme"},"latestReviews":[{"state":"APPROVED"}]},
 {"number":2,"author":{"login":"app/claude-maintenance-acme"},"latestReviews":[{"state":"COMMENTED"},{"state":"APPROVED"}]},
 {"number":3,"author":{"login":"alice-dev"},"latestReviews":[]},
 {"number":4,"author":{"login":"app/claude-maintenance-other"},"latestReviews":[]},
 {"number":5,"author":{"login":"app/claude-approver"},"latestReviews":[]}]
EOF
  run --separate-stderr zsh "$QUEUE"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "queue: no open PR counts zero; --repo reaches gh" {
  printf '[]\n' > "$FIX/prs.json"
  run --separate-stderr zsh "$QUEUE" --repo acme/widgets
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  contains "$(cat "$GH_LOG")" "--repo acme/widgets"
  contains "$(cat "$GH_LOG")" "--state open"
  contains "$(cat "$GH_LOG")" "--limit 1000 --json number,author,latestReviews"
}

@test "queue: a failing gh, or output that is not one array, is exit 1 with nothing printed" {
  export GH_FAIL=prs
  run --separate-stderr zsh "$QUEUE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "gh pr list failed"
  unset GH_FAIL
  printf '{"not":"an array"}\n' > "$FIX/prs.json"
  run --separate-stderr zsh "$QUEUE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "did not return one JSON array"
}

@test "queue: an unknown argument, a repeated --repo or --repo without a value is a usage error" {
  run --separate-stderr zsh "$QUEUE" --all
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown argument '--all'"
  run --separate-stderr zsh "$QUEUE" --repo a/b --repo c/d
  [ "$status" -eq 2 ]
  contains "$stderr" "--repo given twice"
  run --separate-stderr zsh "$QUEUE" --repo
  [ "$status" -eq 2 ]
  contains "$stderr" "--repo needs a value"
}

@test "queue: no gh is an internal failure (exit 1)" {
  local bin="$BATS_TEST_TMPDIR/nogh"
  mkdir -p "$bin"
  ln -s "$(command -v zsh)" "$bin/zsh"
  ln -s "$(command -v jq)" "$bin/jq"
  run --separate-stderr env PATH="$bin" zsh "$QUEUE"
  [ "$status" -eq 1 ]
  contains "$stderr" "gh not found"
}
