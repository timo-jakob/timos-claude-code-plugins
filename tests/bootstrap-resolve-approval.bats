#!/usr/bin/env bats
#
# Tests for resolve-approval.zsh (#1684) — the approval model as a DECLARATION
# in .maintenance.yml's `approval:` line rather than a consequence of which
# Claude Apps the bootstrapping machine has registered. The contract pinned
# here: resolution recorded → chosen (--claude-approver) → default, the default
# per --kind (a language repo asks the per-owner registry probe, #1683; a plugin
# repo and an IaC repo are human-only),
# the probe running only when it can matter and only against the target repo,
# ignored_flag= whenever a passed flag did not decide, and --record's
# line-preserving merge with its --expect guard.
#
# The registry is the stubbed one tests/claude-apps-stubs.bash builds: a personal
# pair for timo-jakob and a writer-only organisation acme-corp.

bats_require_minimum_version 1.5.0
load assertions
load claude-apps-stubs

setup() {
  claude_apps_stubs
  # The stubs' yq only answers --version; the resolver reads real YAML, and
  # only mikefarah's — any other yq would red these tests for its own reasons.
  rm -f "$BATS_TEST_TMPDIR/bin/yq"
  case "$(yq --version 2>&1)" in
    *mikefarah*) ;;
    *) skip "needs mikefarah yq v4" ;;
  esac
  S="$SCRIPTS/resolve-approval.zsh"
  TEMPLATE="$SCRIPTS/../templates/common/.maintenance.yml.tmpl"
  M="$WORK/.maintenance.yml"
}

# expected stdout: approval=<v>, approval_source=<src>, then any extra lines
lines() { # <approval> <source> [<extra line>...]
  local a="$1" s="$2"
  shift 2
  printf 'approval=%s\napproval_source=%s' "$a" "$s"
  local l
  for l in "$@"; do printf '\n%s' "$l"; done
}

probe_ran() { [ -s "$STUB_DIR/gh.log" ]; }

# --- the language-repo default: the per-owner probe ----------------------------

@test "resolve-approval: an owner with only the writer registered defaults to human (AC1)" {
  write_registry
  in_org_repo acme-corp
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default probe=not-registered)" ]
  # the probe's report is relayed, naming what is not registered
  contains "$stderr" "approver: not registered"
  contains "$stderr" "maintenance: registered"
}

@test "resolve-approval: an owner with both Apps registered defaults to approver (AC3)" {
  write_registry
  in_personal_repo timo-jakob
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines approver default probe=registered)" ]
  contains "$stderr" "owner: timo-jakob"
  contains "$stderr" "approver: registered"
}

@test "resolve-approval: an Approver whose Keychain key is gone defaults to human and relays the fix" {
  write_registry
  rm -f "$KC_DIR/claude-plugins.timo-jakob.claude-approver"
  in_personal_repo timo-jakob
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default probe=not-registered)" ]
  contains "$stderr" "approver: key missing"
  contains "$stderr" "fix: "
}

@test "resolve-approval: a repo with no GitHub owner yet defaults to human" {
  write_registry
  export GH_REPO_FAIL=1
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default probe=no-owner)" ]
}

@test "resolve-approval: the probe asks about the maintenance file's repo, not the working directory's" {
  write_registry
  in_personal_repo timo-jakob
  mkdir -p "$BATS_TEST_TMPDIR/target" "$BATS_TEST_TMPDIR/elsewhere"
  # the gh stub reports the repo whose directory holds this marker
  printf '#!/usr/bin/env bash\n[ -f .org-repo ] && export REPO_OWNER=acme-corp REPO_IN_ORG=true\nexec "%s" "$@"\n' \
    "$BATS_TEST_TMPDIR/bin/gh.real" > "$BATS_TEST_TMPDIR/gh-by-cwd"
  mv "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/gh.real"
  mv "$BATS_TEST_TMPDIR/gh-by-cwd" "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  touch "$BATS_TEST_TMPDIR/target/.org-repo"
  cd "$BATS_TEST_TMPDIR/elsewhere"
  run --separate-stderr zsh "$S" --kind language --maintenance-file "$BATS_TEST_TMPDIR/target/.maintenance.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default probe=not-registered)" ]
  contains "$stderr" "owner: acme-corp"
}

@test "resolve-approval: an existing Approver policy neither decides the default nor skips the probe" {
  write_registry
  in_org_repo acme-corp
  mkdir -p "$WORK/.claude"
  printf 'policy\n' > "$WORK/.claude/approver-policy.md"
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default probe=not-registered)" ]
}

@test "resolve-approval: an unreadable registry stops the resolution (exit 1, empty stdout)" {
  write_schema1_registry
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "still schema 1"
  contains "$stderr" "resolve-approval: the Claude Apps probe (claude-apps-owner.zsh status) exited 1"
}

# --- recorded → chosen → default -------------------------------------------------

@test "resolve-approval: a recorded human survives a machine with both Apps, and no probe runs (AC2)" {
  write_registry
  in_personal_repo timo-jakob
  printf 'primary: python\napproval: human\n' > "$M"
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human recorded)" ]
  run ! probe_ran
}

@test "resolve-approval: a recorded human outranks --claude-approver true, which is reported ignored" {
  printf 'approval: human\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --claude-approver true
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human recorded 'ignored_flag=--claude-approver true')" ]
}

@test "resolve-approval: a recorded approver outranks --claude-approver false, which is reported ignored" {
  printf 'approval: approver\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --claude-approver false
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines approver recorded 'ignored_flag=--claude-approver false')" ]
}

@test "resolve-approval: a flag that agrees with the recorded value is not reported ignored" {
  printf 'approval: approver\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --claude-approver true
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines approver recorded)" ]
}

@test "resolve-approval: --claude-approver false chooses human, with no probe (AC3)" {
  write_registry
  in_personal_repo timo-jakob
  run --separate-stderr zsh "$S" --kind language --claude-approver false
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human chosen)" ]
  run ! probe_ran
}

@test "resolve-approval: --claude-approver true chooses approver, with no probe" {
  write_registry
  in_org_repo acme-corp
  run --separate-stderr zsh "$S" --kind language --claude-approver true
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines approver chosen)" ]
  run ! probe_ran
}

@test "resolve-approval: an absent, empty, null or blank approval: records nothing" {
  write_registry
  in_personal_repo timo-jakob
  local body
  for body in 'primary: java' 'approval:' 'approval: null' 'approval: ~' 'approval: ""' "approval: '  '"; do
    printf 'primary: java\n%s\n' "$body" > "$M"
    run --separate-stderr zsh "$S" --kind language
    [ "$status" -eq 0 ]
    [ "$output" = "$(lines approver default probe=registered)" ]
  done
}

@test "resolve-approval: --maintenance-file is read instead of ./.maintenance.yml" {
  printf 'approval: approver\n' > "$BATS_TEST_TMPDIR/other.yml"
  printf 'approval: human\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --maintenance-file "$BATS_TEST_TMPDIR/other.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines approver recorded)" ]
}

# --- the human-only kinds: plugin and IaC ---------------------------------------------

@test "resolve-approval: a plugin repo is human whatever the machine, with no probe (AC4)" {
  write_registry
  in_personal_repo timo-jakob
  run --separate-stderr zsh "$S" --kind claude-plugin
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default)" ]
  run ! probe_ran
}

@test "resolve-approval: a plugin repo takes --claude-approver false as chosen" {
  run --separate-stderr zsh "$S" --kind claude-plugin --claude-approver false
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human chosen)" ]
}

@test "resolve-approval: a plugin repo ignores --claude-approver true and says so" {
  run --separate-stderr zsh "$S" --kind claude-plugin --claude-approver true
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default 'ignored_flag=--claude-approver true')" ]
}

@test "resolve-approval: a plugin repo honours its own recorded human" {
  printf 'primary: claude-plugin\napproval: human\n' > "$M"
  run --separate-stderr zsh "$S" --kind claude-plugin
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human recorded)" ]
}

@test "resolve-approval: a plugin repo recording approval: approver is refused" {
  printf 'primary: claude-plugin\napproval: approver\n' > "$M"
  run --separate-stderr zsh "$S" --kind claude-plugin
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-approval: approval: approver is not supported on a Claude plugin repository — a plugin repo is human-only (no AI auto-approval). Declare approval: human." ]
}

@test "resolve-approval: an IaC repo defaults to human with no probe" {
  write_registry
  in_personal_repo timo-jakob
  run --separate-stderr zsh "$S" --kind iac
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default)" ]
  run ! probe_ran
}

@test "resolve-approval: an IaC repo ignores --claude-approver true and says so" {
  run --separate-stderr zsh "$S" --kind iac --claude-approver true
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default 'ignored_flag=--claude-approver true')" ]
}

@test "resolve-approval: an IaC repo honours a recorded human" {
  printf 'primary: kubernetes\napproval: human\n' > "$M"
  run --separate-stderr zsh "$S" --kind iac
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human recorded)" ]
}

@test "resolve-approval: an IaC repo recording approval: approver is refused" {
  printf 'primary: kubernetes\napproval: approver\n' > "$M"
  run --separate-stderr zsh "$S" --kind iac
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-approval: approval: approver is not supported on the IaC path — it has no Approver-capable language, so no Approver could ever be wired. Declare approval: human." ]
}

# --- validation ----------------------------------------------------------------------

@test "resolve-approval: an unsupported recorded value is refused, naming the allowed set" {
  local body
  for body in 'approval: auto' 'approval: Human' 'approval: true'; do
    printf '%s\n' "$body" > "$M"
    run --separate-stderr zsh "$S" --kind language --claude-approver false
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    contains "$stderr" "is not supported — allowed: human | approver"
  done
}

@test "resolve-approval: a mapping under approval: is refused" {
  printf 'approval:\n  model: human\n' > "$M"
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 1 ]
  [ "$stderr" = "resolve-approval: approval: must be human or approver — got a map" ]
}

@test "resolve-approval: a list under approval: is refused" {
  printf 'approval:\n  - human\n' > "$M"
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 1 ]
  [ "$stderr" = "resolve-approval: approval: must be human or approver — got a list" ]
}

@test "resolve-approval: a .maintenance.yml that does not parse is refused" {
  printf 'primary: [unclosed\n' > "$M"
  run --separate-stderr zsh "$S" --kind language
  [ "$status" -eq 1 ]
  [ "$stderr" = "resolve-approval: cannot parse ./.maintenance.yml as YAML" ]
}

@test "resolve-approval: a yq that is not mikefarah's is refused when there is a file to read" {
  printf '#!/usr/bin/env bash\necho "yq 3.2.3"\n' > "$BATS_TEST_TMPDIR/bin/yq"
  chmod +x "$BATS_TEST_TMPDIR/bin/yq"
  printf 'approval: human\n' > "$M"
  run --separate-stderr zsh "$S" --kind iac
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "brew install yq"
}

@test "resolve-approval: a repo with no .maintenance.yml needs no yq at all" {
  run --separate-stderr env PATH=/nonexistent "$(command -v zsh)" "$S" --kind iac
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human default)" ]
}

@test "resolve-approval: no arguments is a usage error" {
  run --separate-stderr zsh "$S"
  [ "$status" -eq 2 ]
}

@test "resolve-approval: an unsupported --kind is a usage error" {
  run --separate-stderr zsh "$S" --kind app
  [ "$status" -eq 2 ]
  contains "$stderr" "--kind must be language, claude-plugin or iac"
}

@test "resolve-approval: a --claude-approver outside true | false is a usage error" {
  run --separate-stderr zsh "$S" --kind language --claude-approver yes
  [ "$status" -eq 2 ]
  contains "$stderr" "--claude-approver must be true or false, got: yes"
}

@test "resolve-approval: a flag with no value is a usage error" {
  run --separate-stderr zsh "$S" --kind language --claude-approver
  [ "$status" -eq 2 ]
  contains "$stderr" "--claude-approver needs a value"
}

@test "resolve-approval: an unknown argument is a usage error with empty stdout" {
  run --separate-stderr zsh "$S" --kind language --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "resolve-approval: --expect without --record is a usage error" {
  run --separate-stderr zsh "$S" --kind iac --expect human
  [ "$status" -eq 2 ]
  contains "$stderr" "--expect only applies with --record"
}

@test "resolve-approval: --expect outside human | approver is a usage error" {
  run --separate-stderr zsh "$S" --kind iac --record --expect auto
  [ "$status" -eq 2 ]
  contains "$stderr" "--expect must be human or approver, got: auto"
}

@test "resolve-approval: a blank --maintenance-file is a usage error, never the working directory" {
  run --separate-stderr zsh "$S" --kind language --maintenance-file ''
  [ "$status" -eq 2 ]
  contains "$stderr" "--maintenance-file needs a non-empty path"
  run ! probe_ran
}

@test "resolve-approval: a --maintenance-file under a missing directory is refused before the probe" {
  run --separate-stderr zsh "$S" --kind language --maintenance-file "$BATS_TEST_TMPDIR/missing/.maintenance.yml"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "is not a directory"
  run ! probe_ran
}

@test "resolve-approval: a directory at the maintenance-file path is refused, not read as absent" {
  mkdir "$M"
  run --separate-stderr zsh "$S" --kind iac
  [ "$status" -eq 1 ]
  [ "$stderr" = "resolve-approval: ./.maintenance.yml is not a regular file" ]
}

@test "resolve-approval: an unreadable maintenance file is reported as unreadable" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 file"
  printf 'approval: human\n' > "$M"
  chmod 0000 "$M"
  run --separate-stderr zsh "$S" --kind iac
  chmod 0644 "$M"
  [ "$status" -eq 1 ]
  [ "$stderr" = "resolve-approval: cannot read ./.maintenance.yml" ]
}

@test "resolve-approval: a multi-document maintenance file is refused" {
  printf 'approval: human\n---\nprimary: go\n' > "$M"
  run --separate-stderr zsh "$S" --kind iac
  [ "$status" -eq 1 ]
  [ "$stderr" = "resolve-approval: ./.maintenance.yml holds more than one YAML document — keep it to one" ]
}

# --- --record ---------------------------------------------------------------------------

@test "resolve-approval: --record appends the template's lines, leaving every existing line alone (AC3)" {
  write_registry
  in_personal_repo timo-jakob
  printf '# my own note\nprimary: python   # keep this\ntools:\n  code_scanning: codeql\n' > "$M"
  local before
  before="$(cat "$M")"
  run --separate-stderr zsh "$S" --kind language --record
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines approver default probe=registered)" ]
  # the template's approval lines, byte for byte, with the resolved value
  local expected
  expected="$(grep -B2 '^approval: {{APPROVAL}}$' "$TEMPLATE" | sed 's/{{APPROVAL}}/approver/')"
  [ "$(cat "$M")" = "$before"$'\n'"$expected" ]
}

@test "resolve-approval: a recorded value is left byte-identical by a later --record on another machine" {
  printf 'primary: go\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --claude-approver false --record
  [ "$status" -eq 0 ]
  [ "$(yq -r '.approval' "$M")" = human ]
  local first
  first="$(cksum < "$M")"
  # the machine changes, the record does not
  write_registry
  in_personal_repo timo-jakob
  run --separate-stderr zsh "$S" --kind language --record
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human recorded)" ]
  [ "$(cksum < "$M")" = "$first" ]
}

@test "resolve-approval: --record never rewrites a recorded line the resolver would have written differently" {
  printf 'primary: go\napproval: "human"   # our call\n' > "$M"
  local before
  before="$(cat "$M")"
  run --separate-stderr zsh "$S" --kind iac --record
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines human recorded)" ]
  [ "$(cat "$M")" = "$before" ]
}

@test "resolve-approval: --record matches only a top-level approval: key, never a comment or a nested one" {
  printf '# approval: decide later\nprimary: go\ntools:\n  approval: x\n' > "$M"
  local before
  before="$(cat "$M")"
  run --separate-stderr zsh "$S" --kind iac --record
  [ "$status" -eq 0 ]
  local expected
  expected="$(grep -B2 '^approval: {{APPROVAL}}$' "$TEMPLATE" | sed 's/{{APPROVAL}}/human/')"
  [ "$(cat "$M")" = "$before"$'\n'"$expected" ]
}

@test "resolve-approval: --record adds the missing newline before appending" {
  printf 'primary: go' > "$M"
  run --separate-stderr zsh "$S" --kind iac --record
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$M")" = "primary: go" ]
  [ "$(yq -r '.approval' "$M")" = human ]
}

@test "resolve-approval: --record fills a key present with no value, keeping its comment and every other line" {
  printf 'primary: go\napproval:   # who approves\ngate: make lint\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --claude-approver true --record
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = $'primary: go\napproval: approver # who approves\ngate: make lint' ]
}

@test "resolve-approval: --record refuses a null written on the line after the key, leaving the file unchanged" {
  printf 'primary: go\napproval:\n  ~\n' > "$M"
  run --separate-stderr zsh "$S" --kind iac --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "would not read back; left it unchanged"
  [ "$(cat "$M")" = $'primary: go\napproval:\n  ~' ]
  run ls -A "$WORK"
  [ "$output" = .maintenance.yml ]
}

@test "resolve-approval: --record fills an explicit null in place" {
  printf 'approval: ~\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --claude-approver false --record
  [ "$status" -eq 0 ]
  [ "$(cat "$M")" = 'approval: human' ]
}

@test "resolve-approval: a plugin repo records human (AC4)" {
  write_registry
  in_personal_repo timo-jakob
  printf 'primary: claude-plugin\n' > "$M"
  run --separate-stderr zsh "$S" --kind claude-plugin --claude-approver true --record
  [ "$status" -eq 0 ]
  [ "$(yq -r '.approval' "$M")" = human ]
}

@test "resolve-approval: --record --expect records the value the plan showed" {
  printf 'primary: go\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --claude-approver true --record --expect approver
  [ "$status" -eq 0 ]
  [ "$(yq -r '.approval' "$M")" = approver ]
}

@test "resolve-approval: --record --expect refuses a resolution that changed since the plan" {
  write_registry
  export GH_REPO_FAIL=1 # the plan saw approver; this run's probe cannot reach gh
  printf 'primary: go\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --record --expect approver
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "approval now resolves human (default), not the approver that was planned — nothing recorded"
  [ "$(cat "$M")" = 'primary: go' ]
}

@test "resolve-approval: --record --expect refuses a recorded value that differs from the plan" {
  printf 'approval: human\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --record --expect approver
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "approval now resolves human (recorded), not the approver that was planned"
  [ "$(cat "$M")" = 'approval: human' ]
}

@test "resolve-approval: --record writes through the file — same mode, same inode, no temp file left" {
  printf 'primary: go\n' > "$M"
  chmod 0644 "$M"
  local before
  before="$(ls -li "$M" | awk '{print $1, $2}')"
  run --separate-stderr zsh "$S" --kind iac --record
  [ "$status" -eq 0 ]
  [ "$(ls -li "$M" | awk '{print $1, $2}')" = "$before" ]
  run ls -A "$WORK"
  [ "$output" = .maintenance.yml ]
}

@test "resolve-approval: a failed write-back exits 1 and keeps the merged text in the temp file it names" {
  [ "$(id -u)" -ne 0 ] || skip "root can write a read-only file"
  printf 'primary: go\n' > "$M"
  chmod 0444 "$M"
  run --separate-stderr zsh "$S" --kind iac --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "the merged text is in"
  local kept="${stderr##*the merged text is in }"
  [ "$(yq -r '.approval' "$kept")" = human ]
  [ "$(cat "$M")" = 'primary: go' ]
}

@test "resolve-approval: --record needs an existing file and leaves no temp file behind" {
  run --separate-stderr zsh "$S" --kind iac --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "resolve-approval: --record needs an existing ./.maintenance.yml — a fresh repo gets approval: from .maintenance.yml.tmpl" ]
  run ls -A "$WORK"
  [ -z "$output" ]
}

@test "resolve-approval: --record into a flow-style file that would not read back leaves it unchanged" {
  printf '{primary: go}\n' > "$M"
  run --separate-stderr zsh "$S" --kind iac --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "would not read back; left it unchanged"
  [ "$(cat "$M")" = '{primary: go}' ]
  run ls -A "$WORK"
  [ "$output" = .maintenance.yml ]
}

@test "resolve-approval: --record names a quoted approval key it cannot fill, leaving the file unchanged" {
  printf 'primary: go\n"approval":\n' > "$M"
  run --separate-stderr zsh "$S" --kind iac --record
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "cannot find the top-level approval: line"
  [ "$(cat "$M")" = $'primary: go\n"approval":' ]
}

@test "resolve-approval: a refused resolution never records" {
  printf 'approval: auto\n' > "$M"
  run --separate-stderr zsh "$S" --kind language --claude-approver false --record
  [ "$status" -eq 1 ]
  [ "$(cat "$M")" = 'approval: auto' ]
}

# --- the SKILL.md contracts this script serves --------------------------------------------

SKILL_MD() { tr -s '[:space:]' ' ' < "$SCRIPTS/../SKILL.md"; }

@test "resolve-approval: SKILL.md renders no Approver policy for approval: human" {
  contains "$(SKILL_MD)" '**`approval: human` renders nothing here** (#1684)'
}

@test "resolve-approval: SKILL.md skips Step 4f on a resolved approval: human" {
  contains "$(SKILL_MD)" 'a resolved `approval: human` **skips this step** whatever else is on disk'
}

@test "resolve-approval: SKILL.md's Step 2 plan carries the Approval: line with its source" {
  contains "$(SKILL_MD)" 'Approval: approval: <human | approver> (<recorded | chosen | default>)'
}

@test "resolve-approval: SKILL.md's final report names the model and the unwritten policy" {
  contains "$(SKILL_MD)" 'For `approval: human` it also says that **no Approver policy was written**'
}

@test "resolve-approval: SKILL.md passes the resolved model to the Step 4.5 preflight" {
  contains "$(SKILL_MD)" 'A recorded `approval: human` passes `false` even on a machine where both Apps are registered.'
}

@test "resolve-approval: SKILL.md records with --expect set to the planned value" {
  contains "$(SKILL_MD)" '`--record --expect <the planned value>`'
}

@test "resolve-approval: SKILL.md's composition path records no approval:" {
  contains "$(SKILL_MD)" '*Resolve the approval model* do not apply: this path has none of those values, and its scaffold records no `approval:` (#1684)'
}

@test "resolve-approval: SKILL.md's State D gap-fill resolves the model and records it into an existing file" {
  contains "$(SKILL_MD)" 'Its value is the `--approval` a missing `.maintenance.yml` renders with'
  contains "$(SKILL_MD)" '**existing** `.maintenance.yml` is never in `missing_artifacts`, so record it here'
}

@test "resolve-approval: SKILL.md's IaC path resolves the model as --kind iac" {
  contains "$(SKILL_MD)" 'resolve it with `resolve-approval.zsh --kind iac`'
}

@test "resolve-approval: SKILL.md's plan discloses an approver repo with no Approver-capable language" {
  contains "$(SKILL_MD)" 'no Approver-capable language yet: the writer App only, a human approves'
}

@test "resolve-approval: SKILL.md's preflight asks for the Approver only when the full install will run" {
  contains "$(SKILL_MD)" '`true` exactly when the full `install-claude-apps.zsh` row below will run'
}

@test "resolve-approval: SKILL.md warns in the plan when the flag was ignored" {
  contains "$(SKILL_MD)" '**warn** in the plan that it was ignored, and for a recorded value name the fix, editing `approval:` in `.maintenance.yml`'
  contains "$(SKILL_MD)" '**only when `resolve-approval.zsh` reported `ignored_flag=`**'
}

@test "resolve-approval: SKILL.md offers to stop and re-run when no owner resolved" {
  contains "$(SKILL_MD)" 'ask at the plan whether to record it now — a recorded value is never re-evaluated later — or to stop here, fix the cause (a GitHub remote, or `gh auth login`) and re-run `/development:bootstrap`'
}

@test "resolve-approval: SKILL.md's State D no-drift stop lets a pending record through" {
  contains "$(SKILL_MD)" 'So does a pending `approval:` record'
  contains "$(SKILL_MD)" 'do not stop — continue to the Step 2 plan, and on confirmation its `--record` is the delta'
}

@test "resolve-approval: SKILL.md's Step 3 render passes --approval" {
  contains "$(SKILL_MD)" '--approval "<human|approver>" \'
}

@test "resolve-approval: SKILL.md's IaC plan names no writer-App install" {
  contains "$(SKILL_MD)" 'off the §3l IaC path, where the trimmed form below stands and the writer App is Step 4e'"'"'s offer'
}

@test "resolve-approval: SKILL.md's 4d/4e skip only a run that recorded no approval:" {
  contains "$(SKILL_MD)" 'generated or recorded nothing in the working tree'
  contains "$(SKILL_MD)" 'run, either one with no `approval:` recorded — there is nothing to commit'
  contains "$(SKILL_MD)" 'run, either one with no `approval:` recorded, commit nothing'
}

@test "resolve-approval: SKILL.md stops on a resolver exit 1 and never overrides a record" {
  contains "$(SKILL_MD)" '**exit 1** → stdout is empty; relay stderr verbatim and **stop**'
  contains "$(SKILL_MD)" 'Never pick a different value over a recorded one.'
}
