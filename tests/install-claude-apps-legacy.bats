#!/usr/bin/env bats
#
# Behavioral tests for install-claude-apps.zsh's legacy CI-era cleanup (#498).
#
# Epic #476 retired the Actions-based Approver: tokens are minted locally
# from the Keychain, so the per-repo secrets/variables that pre-#476
# installs stored (App PEMs, ANTHROPIC_API_KEY, gate variables) have no
# consumer left. check_legacy_repo_config must flag them read-only, delete
# only the unambiguously-ours names under --fix (both Actions and
# Dependabot secret scopes), skip any name a workflow file still
# references, and never auto-delete ANTHROPIC_API_KEY. These tests source
# the script (its `main` is guarded, so sourcing has no side effects) and
# drive the function against a PATH-shimmed fake `gh`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/scripts/install-claude-apps.zsh"
  WORK="$BATS_TEST_TMPDIR/repo"
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$WORK" "$STUB"
  CALLS="$BATS_TEST_TMPDIR/calls";              : > "$CALLS"
  ACTIONS="$BATS_TEST_TMPDIR/actions_secrets";  : > "$ACTIONS"
  DEPBOT="$BATS_TEST_TMPDIR/dependabot_secrets"; : > "$DEPBOT"
  VARS="$BATS_TEST_TMPDIR/variables";           : > "$VARS"

  # Fake gh: list subcommands read the fixture files above; delete
  # subcommands append their full argv to $CALLS and touch nothing.
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "secret list")
    if printf '%s ' "\$@" | grep -q -- '--app dependabot'; then
      cat "$DEPBOT"
    else
      cat "$ACTIONS"
    fi ;;
  "variable list")  cat "$VARS" ;;
  "secret delete"|"variable delete") echo "\$*" >> "$CALLS" ;;
esac
exit 0
EOF
  chmod +x "$STUB/gh"
}

# Run check_legacy_repo_config in the WORK repo; $1 is the fix flag.
cleanup_run() {
  run zsh -c "cd '$WORK'; export PATH='$STUB:$PATH'; source '$S'; check_legacy_repo_config '${1:-}'"
}

@test "legacy: clean repo reports nothing to do and deletes nothing" {
  cleanup_run ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"No legacy CI-era secrets/variables"* ]]
  [ ! -s "$CALLS" ]
}

@test "legacy: read-only run flags leftovers but deletes nothing" {
  echo "CLAUDE_APPROVER_PRIVATE_KEY" > "$ACTIONS"
  echo "CLAUDE_APPROVER_APP_ID"      > "$VARS"
  cleanup_run ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_APPROVER_PRIVATE_KEY present"* ]]
  [[ "$output" == *"CLAUDE_APPROVER_APP_ID present"* ]]
  [[ "$output" == *"--verify --fix"* ]]
  [ ! -s "$CALLS" ]
}

@test "legacy: --fix deletes CLAUDE_* secrets in both scopes and the variables" {
  printf 'CLAUDE_APPROVER_PRIVATE_KEY\nCLAUDE_MAINTENANCE_PRIVATE_KEY\n' > "$ACTIONS"
  printf 'CLAUDE_APPROVER_PRIVATE_KEY\n' > "$DEPBOT"
  printf 'CLAUDE_APPROVER_APP_ID\nCLAUDE_APPROVER_AUTHOR_ALLOWLIST\n' > "$VARS"
  cleanup_run 1
  [ "$status" -eq 0 ]
  grep -q "secret delete CLAUDE_APPROVER_PRIVATE_KEY$" "$CALLS"
  grep -q "secret delete CLAUDE_APPROVER_PRIVATE_KEY --app dependabot" "$CALLS"
  grep -q "secret delete CLAUDE_MAINTENANCE_PRIVATE_KEY$" "$CALLS"
  grep -q "variable delete CLAUDE_APPROVER_APP_ID" "$CALLS"
  grep -q "variable delete CLAUDE_APPROVER_AUTHOR_ALLOWLIST" "$CALLS"
}

@test "legacy: a name still referenced by a workflow is skipped, not deleted" {
  echo "CLAUDE_APPROVER_PRIVATE_KEY" > "$ACTIONS"
  mkdir -p "$WORK/.github/workflows"
  printf 'env:\n  KEY: ${{ secrets.CLAUDE_APPROVER_PRIVATE_KEY }}\n' \
    > "$WORK/.github/workflows/legacy-approver.yml"
  cleanup_run 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"still referenced by"* ]]
  [[ "$output" == *"legacy-approver.yml"* ]]
  [ ! -s "$CALLS" ]
}

@test "legacy: ANTHROPIC_API_KEY is never auto-deleted, even under --fix" {
  echo "ANTHROPIC_API_KEY" > "$ACTIONS"
  cleanup_run 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not auto-deleted"* ]]
  [[ "$output" == *"gh secret delete ANTHROPIC_API_KEY"* ]]
  ! grep -q "ANTHROPIC_API_KEY" "$CALLS"
}
