#!/usr/bin/env bats
#
# Behavioral tests for register-claude-apps.zsh's App permission definitions.
#
# #418: GitHub tallies an APPROVE toward a branch's required_approving_review_count
# ONLY from a reviewer who can push to the repo — and "push access" is the
# Contents permission, not Pull requests. So the claude-approver App MUST register
# with contents:write or its approvals never satisfy branch protection and green
# PRs stay BLOCKED. These tests source the script (its `main` is guarded so
# sourcing has no side effects) and assert the permission JSON directly — no gh
# auth required.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/scripts/register-claude-apps.zsh"
}

# Emit the permission JSON for an app by sourcing the script and calling the fn.
perms() { run zsh -c "source '$S'; app_permissions_json '$1'"; }

@test "register: #418 claude-approver requests contents:write (so approvals count)" {
  perms claude-approver
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .contents)" = "write" ]
}

@test "register: claude-approver keeps pull_requests:write (to post the review)" {
  perms claude-approver
  [ "$(echo "$output" | jq -r .pull_requests)" = "write" ]
}

@test "register: claude-approver other scopes stay read-only (least privilege)" {
  perms claude-approver
  [ "$(echo "$output" | jq -r .issues)" = "read" ]
  [ "$(echo "$output" | jq -r .actions)" = "read" ]
  [ "$(echo "$output" | jq -r .checks)" = "read" ]
  [ "$(echo "$output" | jq -r .metadata)" = "read" ]
}

@test "register: claude-maintenance still requests contents:write (unchanged)" {
  perms claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .contents)" = "write" ]
  [ "$(echo "$output" | jq -r .pull_requests)" = "write" ]
}

@test "register: #750 claude-maintenance requests workflows:write (bot-authored workflow-file PRs)" {
  perms claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .workflows)" = "write" ]
}

@test "register: sourcing the script does not run main (no side effects)" {
  # If the guard were missing, sourcing with no args would run the registration
  # flow and print to stdout. A clean source emits nothing.
  run zsh -c "source '$S'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
