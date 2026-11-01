#!/usr/bin/env bats
#
# refine-issue's readiness-stamp touch points (#2956, epic #2953):
# readiness-stamp-step.zsh `diagnose` (Step 1 reuses a still-valid stamp) and
# `stamp` (Step 4 stamps the re-gate), and the SKILL.md wiring that orders them.
# readiness-stamp.zsh is stubbed through the STAMP_BIN seam: the stub prints
# $CHECK_OUT for `check` with exit $CHECK_RC, and for `write` logs its argv and
# prints $WRITE_OUT with exit $WRITE_RC. The planner is the real
# readiness-cache-plan.zsh, so a hit or miss here is the one resolve-issue sees.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  P="$REPO_ROOT/development/skills/refine-issue/scripts/readiness-stamp-step.zsh"
  SKILL="$REPO_ROOT/development/skills/refine-issue/SKILL.md"
  DOC="$REPO_ROOT/docs/explanation/workflow-refine-issue.md"
  LOG="$BATS_TEST_TMPDIR/stamp.log"
  VF="$BATS_TEST_TMPDIR/verdict.json"
  printf '{"verdict":"READY"}\n' > "$VF"
  STUB="$BATS_TEST_TMPDIR/stamp-stub.zsh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env zsh
print -r -- "$*" >> "$LOG"
case "$1" in
  check) [[ -n "${CHECK_OUT:-}" ]] && print -r -- "$CHECK_OUT"; exit "${CHECK_RC:-0}" ;;
  write) [[ -n "${WRITE_OUT:-}" ]] && print -r -- "$WRITE_OUT"; exit "${WRITE_RC:-0}" ;;
esac
exit 9
EOF
  chmod +x "$STUB"
}

# step <args…> — run the script against the stub
step() { run --separate-stderr env STAMP_BIN="$STUB" LOG="$LOG" zsh "$P" "$@"; }

# a check document carrying issue 7 as a hit with verdict $1 and dependencies_resolved $2
hit_doc() {
  printf '{"gate_version":"g","hits":[{"issue":7,"verdict":{"issue":7,"verdict":"%s","risk":"elevated","checks":{"dependencies_resolved":%s},"refinement_questions":["Q1"],"size":{"verdict":"pass","triggers":[],"inventory":["a.zsh"]}}}],"misses":[]}' "$1" "$2"
}

@test "#2956 diagnose: a Step 1 hit returns the cached verdict, so no diagnosis gate is spawned" {
  CHECK_OUT="$(hit_doc NEEDS_REFINEMENT true)" step diagnose --repo o/r --issue 7
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hit' <<<"$output")" = true ]
  [ "$(jq -r '.verdict.verdict' <<<"$output")" = NEEDS_REFINEMENT ]
  [ "$(jq -r '.verdict.risk' <<<"$output")" = elevated ]
  [ "$(jq -r '.verdict.refinement_questions[0]' <<<"$output")" = Q1 ]
  [ "$(jq -r '.verdict.size.verdict' <<<"$output")" = pass ]
  grep -qx 'check --repo o/r --issue 7' "$LOG"
}

@test "#2956 diagnose: a stamp miss names its reason" {
  CHECK_OUT='{"gate_version":"g","hits":[],"misses":[{"issue":7,"reason":"key_changed"}]}' \
    step diagnose --repo o/r --issue 7
  [ "$status" -eq 0 ]
  [ "$output" = '{"hit":false,"reason":"key_changed"}' ]
}

@test "#2956 diagnose: a cached verdict that failed the dependency check is a miss" {
  CHECK_OUT="$(hit_doc NEEDS_REFINEMENT false)" step diagnose --repo o/r --issue 7
  [ "$status" -eq 0 ]
  [ "$output" = '{"hit":false,"reason":"dependencies_recheck"}' ]
}

@test "#2956 AC4 diagnose: a failed check falls back to a fresh diagnosis and exits 0" {
  CHECK_RC=3 step diagnose --repo o/r --issue 7
  [ "$status" -eq 0 ]
  [ "$output" = '{"hit":false,"reason":"check_failed"}' ]
}

@test "#2956 diagnose: a failed planner is a miss, never an exit" {
  run --separate-stderr env STAMP_BIN="$STUB" LOG="$LOG" PLAN_BIN=/nonexistent/plan.zsh \
    zsh "$P" diagnose --repo o/r --issue 7
  [ "$status" -eq 0 ]
  [ "$output" = '{"hit":false,"reason":"plan_failed"}' ]
}

@test "#2956 stamp: writes with the key read before the re-gate, as the race guard" {
  WRITE_OUT='{"issue":7,"key":"k2","gate_version":"g","action":"created","comment_id":1}' \
    step stamp --repo o/r --issue 7 --verdict-file "$VF" --expect-key k2
  [ "$status" -eq 0 ]
  [ "$output" = '{"stamped":true,"action":"created","reason":null}' ]
  [ -z "$stderr" ]
  grep -qx "write --repo o/r --issue 7 --verdict-file $VF --expect-key k2" "$LOG"
}

@test "#2956 stamp: an issue edited while the re-gate ran is skipped_stale, not stamped" {
  WRITE_OUT='{"issue":7,"key":"k3","expected_key":"k2","gate_version":"g","action":"skipped_stale"}' \
    step stamp --repo o/r --issue 7 --verdict-file "$VF" --expect-key k2
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stamped' <<<"$output")" = false ]
  [ "$(jq -r '.action' <<<"$output")" = skipped_stale ]
}

@test "#2956 AC2 stamp: a failed write is one stderr line and exit 0" {
  WRITE_RC=3 step stamp --repo o/r --issue 7 --verdict-file "$VF" --expect-key k2
  [ "$status" -eq 0 ]
  [ "$output" = '{"stamped":false,"action":null,"reason":"write exited 3"}' ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  contains "$stderr" 'readiness stamp not written for #7 (write exited 3); the next resolve-issue run gates it fresh'
}

@test "#2956 stamp: an empty key (key failed) writes nothing and says so in one line" {
  step stamp --repo o/r --issue 7 --verdict-file "$VF" --expect-key ''
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stamped' <<<"$output")" = false ]
  [ ! -e "$LOG" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
}

@test "#2956 usage errors exit 2" {
  step
  [ "$status" -eq 2 ]
  step lookup --repo o/r --issue 7
  [ "$status" -eq 2 ]
  step diagnose --repo o/r --issue 0
  [ "$status" -eq 2 ]
  step stamp --repo o/r --issue 7 --verdict-file "$VF"
  [ "$status" -eq 2 ]
  step stamp --repo o/r --issue 7 --expect-key k
  [ "$status" -eq 2 ]
}

@test "#2956 --help prints the usage; a missing jq is an internal failure (exit 1)" {
  step --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage: readiness-stamp-step.zsh diagnose"
  local zsh_bin; zsh_bin="$(command -v zsh)"
  mkdir -p "$BATS_TEST_TMPDIR/nojq"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/nojq" "$zsh_bin" "$P" diagnose --repo o/r --issue 7
  [ "$status" -eq 1 ]
  contains "$stderr" "jq not found on PATH"
}

@test "#2956 AC2 SKILL.md orders the stamp after Step 3's body edit and before Step 5" {
  local edit stamp step5 key regate
  edit=$(grep -n 'gh issue edit <N> --body-file <new-body.md>' "$SKILL" | head -1 | cut -d: -f1)
  key=$(grep -n 'readiness-stamp.zsh" key --repo "$REPO" --issue <N>' "$SKILL" | head -1 | cut -d: -f1)
  stamp=$(grep -n 'readiness-stamp-step.zsh" stamp --repo' "$SKILL" | head -1 | cut -d: -f1)
  step5=$(grep -n '^## Step 5 — resolve the label' "$SKILL" | cut -d: -f1)
  regate=$(grep -n '^## Step 4 — re-gate' "$SKILL" | cut -d: -f1)
  [ -n "$edit" ] && [ -n "$key" ] && [ -n "$stamp" ] && [ -n "$step5" ] && [ -n "$regate" ]
  [ "$edit" -lt "$regate" ] && [ "$regate" -lt "$key" ] && [ "$key" -lt "$stamp" ] && [ "$stamp" -lt "$step5" ]
}

@test "#2956 AC1 SKILL.md consults the stamp before spawning the Step 1 gate" {
  local s1 diag spawn
  s1=$(grep -n '^## Step 1 — diagnose' "$SKILL" | cut -d: -f1)
  diag=$(grep -n 'readiness-stamp-step.zsh" diagnose --repo' "$SKILL" | head -1 | cut -d: -f1)
  spawn=$(grep -n '^Otherwise spawn \*\*`story-readiness`\*\*' "$SKILL" | cut -d: -f1)
  [ -n "$s1" ] && [ -n "$diag" ] && [ -n "$spawn" ]
  [ "$s1" -lt "$diag" ] && [ "$diag" -lt "$spawn" ]
}

@test "#2956 the wiring's rules and the docs are pinned" {
  local n
  for n in \
    '**First, reuse a still-valid readiness stamp (#2956).** From the repository root:' \
    '- **`"hit": true`** → its `verdict` is the diagnosis, exactly as if' \
    '- **`"hit": false`**, or any nonzero exit → spawn the gate as below. A miss,' \
    'a failed check included, never stops the session.' \
    '**Stamp the re-gate verdict (#2956)**, `READY` and `NEEDS_REFINEMENT` alike, so' \
    'to Step 2 stamps again at its next Step 4, in place, so a deferred park in' \
    'prints one line on stderr: relay it to the human as is and go on to Step 5. A' \
    'stamp never changes the verdict, the label handling or Step 7'"'"'s outcome.' \
    'Step 4'"'"'s stamp included (#2956). A child either reaches'; do
    grep -qF -- "$n" "$SKILL" || { echo "missing from SKILL.md: $n" >&2; return 1; }
  done
  grep -qF 'that still-valid verdict and spawns no gate.' "$DOC"
  grep -qF 'verdict. The skill then stamps the verdict on the issue, so the next resolve run reuses it instead of gating the' "$DOC"
}
