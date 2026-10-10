#!/usr/bin/env bats
#
# maintenance's approver-mode detection on a claude-plugin-primary repo is
# decided by plugin-approver-override.zsh (#2134, epic #2129): none unless the
# helper prints override=on, then local. An off for a "no Approver App" reason
# is silent; a helper exit 1 prints one line for Phase 9. Language-primary repos
# never consult the helper and behave exactly as before.
#
# The tests extract the bash block from SKILL.md's "Approver mode — detect once
# per run" section and run it against stubs, so they check behaviour, not
# wording.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  W="$BATS_TEST_TMPDIR"
  awk '/^### Approver mode — detect once per run/{s=1} s&&/^```bash$/{b=1;next} b&&/^```$/{exit} b' \
    "$SKILL" > "$W/block.zsh"
  # checkpoint stub: records what the block saves
  printf '#!/usr/bin/env zsh\ncat > "%s/checkpoint.json"\n' "$W" > "$W/checkpoint.zsh"
  chmod +x "$W/checkpoint.zsh"
  owner_probe 0 "approver: registered"
  mkdir -p "$W/repo"
}

# owner_probe <rc> <stdout>: the claude-apps-owner.zsh stub
owner_probe() {
  printf '#!/usr/bin/env zsh\nprint -r -- %q\nexit %s\n' "$2" "$1" > "$W/owner.zsh"
  chmod +x "$W/owner.zsh"
}

# override_helper <rc> <stdout>: the plugin-approver-override.zsh stub; it also
# leaves a marker so a test can tell whether the block consulted it.
override_helper() {
  printf '#!/usr/bin/env zsh\n: > "%s/override-called"\nprint -r -- %q\nprint -u2 -- "helper diagnostic"\nexit %s\n' \
    "$W" "$2" "$1" > "$W/override.zsh"
  chmod +x "$W/override.zsh"
}

# wire_block: the extracted block with the stubs wired in, as $W/b.zsh.
wire_block() {
  sed -e "s#\"<skill-base-dir>/../bootstrap/scripts/claude-apps-owner.zsh\"#$W/owner.zsh#" \
      -e "s#\"<skill-base-dir>/scripts/checkpoint.zsh\"#$W/checkpoint.zsh#" \
      -e "s#\"<skill-base-dir>/../../scripts/approval/plugin-approver-override.zsh\"#$W/override.zsh#" \
      "$W/block.zsh" > "$W/b.zsh"
}

# run_wired [<primary env>]: run the wired block from the test repo directory
# (no .github/workflows), with `primary` unset or, when given, set to that value
# in the environment; prints the block stdout, then the checkpointed mode on the
# last line.
run_wired() {
  wire_block
  if [ "$#" -gt 0 ]; then
    (cd "$W/repo" && primary="$1" zsh -c 'source "$0"' "$W/b.zsh")
  else
    (cd "$W/repo" && env -u primary zsh -c 'source "$0"' "$W/b.zsh")
  fi
  jq -r .approver_mode "$W/checkpoint.json"
}

# run_block <primary>: declare <primary> in the test repo's .maintenance.yml
# (the block reads it there, as Phase 1 does, never from an inherited shell
# variable) and run the wired block with `primary` unset.
run_block() {
  printf 'primary: %s\n' "$1" > "$W/repo/.maintenance.yml"
  run_wired
}

@test "the block was extracted and calls the override helper" {
  [ -s "$W/block.zsh" ]
  grep -qF '"<skill-base-dir>/../../scripts/approval/plugin-approver-override.zsh"' "$W/block.zsh"
}

@test "plugin-primary, override off for a no-App reason: none, and nothing printed" {
  override_helper 0 $'override=off\nreason=approver-not-installed'
  run --separate-stderr run_block claude-plugin
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "plugin-primary, override off because the variable is unset: none, and nothing printed" {
  override_helper 0 $'override=off\nreason=env-unset'
  run --separate-stderr run_block claude-plugin
  [ "$output" = "none" ]
}

@test "plugin-primary, override on: local" {
  override_helper 0 'override=on'
  run --separate-stderr run_block claude-plugin
  [ "$status" -eq 0 ]
  [ "$output" = "local" ]
}

@test "plugin-primary, helper exit 1: none, with one line for Phase 9 naming the reason" {
  override_helper 1 $'override=off\nreason=approver-key-missing'
  run --separate-stderr run_block claude-plugin
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "AI approval: off — approver-key-missing (see the diagnostic above)" ]
  [ "${lines[1]}" = "none" ]
  contains "$stderr" "helper diagnostic"
}

@test "plugin-primary, Approver not registered: none, and the helper is not consulted" {
  owner_probe 3 "approver: not registered"
  override_helper 0 'override=on'
  run --separate-stderr run_block claude-plugin
  [ "$output" = "none" ]
  [ ! -e "$W/override-called" ]
}

@test "plugin-primary declared with quotes and a comment: the helper decides" {
  printf 'primary: "claude-plugin"  # the topic\n' > "$W/repo/.maintenance.yml"
  override_helper 0 $'override=off\nreason=env-unset'
  run --separate-stderr run_wired
  [ "$output" = "none" ]
  [ -e "$W/override-called" ]
}

@test "plugin-primary declared in single quotes: the helper decides" {
  printf "primary: 'claude-plugin'\n" > "$W/repo/.maintenance.yml"
  override_helper 0 $'override=off\nreason=env-unset'
  run --separate-stderr run_wired
  [ "$output" = "none" ]
  [ -e "$W/override-called" ]
}

@test "an undeclared plugin repo counts as one by its .claude-plugin files: the helper decides" {
  local f
  for f in plugin.json marketplace.json; do
    rm -rf "$W/repo/.claude-plugin" "$W/override-called"
    mkdir -p "$W/repo/.claude-plugin"
    printf '{}\n' > "$W/repo/.claude-plugin/$f"
    override_helper 0 $'override=off\nreason=env-unset'
    run --separate-stderr run_wired
    [ "$output" = "none" ] || { echo "$f: got $output"; return 1; }
    [ -e "$W/override-called" ] || { echo "$f: helper not consulted"; return 1; }
  done
}

@test "a python-primary repo carrying .claude-plugin files is still asked: the helper decides" {
  mkdir -p "$W/repo/.claude-plugin"
  printf '{}\n' > "$W/repo/.claude-plugin/plugin.json"
  override_helper 0 'override=on'
  run --separate-stderr run_block python
  [ "$output" = "local" ]
  [ -e "$W/override-called" ]
}

@test "an inherited primary variable alone is ignored: no declaration, helper not consulted" {
  override_helper 0 $'override=off\nreason=env-unset'
  run --separate-stderr run_wired claude-plugin
  [ "$output" = "local" ]
  [ ! -e "$W/override-called" ]
}

@test "an inherited primary variable cannot override a claude-plugin declaration" {
  printf 'primary: claude-plugin\n' > "$W/repo/.maintenance.yml"
  override_helper 0 $'override=off\nreason=env-unset'
  run --separate-stderr run_wired python
  [ "$output" = "none" ]
  [ -e "$W/override-called" ]
}

@test "an unreadable declaration fails closed: the helper decides" {
  printf 'primary: python\n' > "$W/repo/.maintenance.yml"
  chmod 000 "$W/repo/.maintenance.yml"
  if [ -r "$W/repo/.maintenance.yml" ]; then
    chmod 600 "$W/repo/.maintenance.yml"
    skip "running as a user that can read mode-000 files"
  fi
  override_helper 0 $'override=off\nreason=env-unset'
  run --separate-stderr run_wired
  chmod 600 "$W/repo/.maintenance.yml"
  [ "$output" = "none" ]
  [ -e "$W/override-called" ]
}

@test "language-primary is untouched: local when registered, helper not consulted" {
  override_helper 0 $'override=off\nreason=not-plugin-repo'
  run --separate-stderr run_block python
  [ "$output" = "local" ]
  [ ! -e "$W/override-called" ]
}

@test "language-primary with a pre-476 CI Approver workflow stays ci" {
  mkdir -p "$W/repo/.github/workflows"
  printf 'on:\n  check_suite:\n    types: [completed]\njobs:\n  claude-approver: {}\n' > "$W/repo/.github/workflows/approver.yml"
  override_helper 0 'override=on'
  run --separate-stderr run_block python
  [ "$output" = "ci" ]
}

@test "SKILL.md: the none bullet states the claude-plugin-primary rule and names the approve skill" {
  local text
  text="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')"
  contains "$text" "A **claude-plugin-primary** repo is also \`none\` unless \`plugin-approver-override.zsh\` prints \`override=on\`"
  contains "$text" "then it is \`local\`, and the gate drives \`/development-claude-plugin:approve\`; Phase 8 still gates a PR the Maintenance App did not author as \`none\`."
  contains "$text" "An off for a \"no Approver App\" reason is silent; a helper exit 1 (a broken setup) is relayed and listed in Phase 9."
}

@test "SKILL.md: Phase 8 runs the claude-plugin approve skill on a claude-plugin-primary repo" {
  local text
  text="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')"
  contains "$text" "On a claude-plugin-primary repo as § Approver mode defines it — the gate re-applies that section's test to the repo, never Phase 1's detected primary — the gate always runs \`/development-claude-plugin:approve\`, whatever the stage's language; elsewhere it runs \`/development-<lang>:approve\` for the stage's language."
  contains "$text" "# claude-plugin on a claude-plugin-primary repo as § Approver mode defines it, # whatever the stage's language"
  contains "$text" "(<lang> is claude-plugin on a claude-plugin-primary repo as # § Approver mode defines it, see above):"
}

@test "SKILL.md: Phase 8 gates a PR the Maintenance App did not author as none on a plugin repo" {
  local text
  text="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')"
  contains "$text" "That skill reviews only a PR the Maintenance App authored, so on such a repo every other PR — a vendor PR (Dependabot, Renovate, Snyk) included — is gated as \`none\` instead: a human review, no wait."
}

@test "SKILL.md: the local-mode recipe checks the PR author before any approve call or wait" {
  local text
  text="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')"
  contains "$text" "# 0. on a claude-plugin-primary repo as § Approver mode defines it, read the # PR's author first: unless it is the \`claude-maintenance\` App (login # prefix match, as Phase 2.5 tells a bot PR), gate this PR as \`none\` — # no approve call, no wait — and skip steps 1-3: gh pr view \"<pr_number>\" --json author --jq .author.login # 1. wait for green"
  contains "$text" "add --update first for a vendor PR that's BEHIND under strict branch # protection (never on a plugin repo: step 0 gated it as \`none\`). Exit 4"
}

@test "SKILL.md: a resumed run re-detects the approver mode instead of restoring it" {
  local text
  text="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')"
  contains "$text" "The **approver-mode detection** (*Approver mode*, Phase 2.5) is likewise re-run, never restored: the \`CLAUDE_PLUGIN_APPROVER\` opt-in belongs to the session, so a resumed run's detection overwrites the \`approver_mode\` an earlier session saved."
  contains "$text" "\`checkpoint.zsh load --phase approver_mode\` (defaulting to \`none\` when absent)."
}

@test "SKILL.md: Phase 2.5 defines claude-plugin-primary once, for Phase 8 too" {
  local text
  text="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')"
  contains "$text" "A repo counts as claude-plugin-primary — here and wherever this skill uses the term, Phase 8 included — when it declares \`primary: claude-plugin\` or carries \`.claude-plugin/plugin.json\` or \`marketplace.json\` — the helper's own test, whatever primary Phase 1 detected."
}

@test "SKILL.md: every claude-plugin-primary use outside Phase 2.5 points at its definition" {
  run awk '/^## Phase 2\.5 /{p=1} /^## Phase 3 /{p=0} !p && /claude-plugin-primary repo/ && !/repo as$/ && !/as § Approver mode defines it/' "$SKILL"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no maintenance file reads the raw variable" {
  run grep -rnE '\$\{?CLAUDE_PLUGIN_APPROVER' "$REPO_ROOT/development/skills/maintenance"
  [ "$status" -eq 1 ]
}
