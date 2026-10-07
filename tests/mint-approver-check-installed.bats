#!/usr/bin/env bats
#
# mint-approver-token.zsh --check-installed (#2130): the quiet installation
# probe the plugin-Approver override reads. "Not installed" is a supported
# setup (no AI approvals), so it is a silent exit 3; every other lookup failure
# keeps exit 2 and today's diagnostics, and the probe never mints a token.
#
# covers: development/skills/maintenance/scripts/mint-approver-token.zsh

bats_require_minimum_version 1.5.0
load assertions
load claude-apps-stubs

setup() {
  claude_apps_stubs
  write_registry
  in_personal_repo "timo-jakob"
}

# How many access_tokens (mint) requests the stubbed GitHub received.
mint_requests() {
  grep -c 'access_tokens' "$STUB_DIR/curl.log" || true
}

@test "check-installed: an installed App exits 0, prints nothing and mints no token" {
  run --separate-stderr zsh "$MINT_APPROVER" --check-installed
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  grep -q '/repos/timo-jakob/widget/installation' "$STUB_DIR/curl.log"
  [ "$(mint_requests)" = "0" ]
  # No token file was written either.
  run find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'claude-approver-token.*'
  [ -z "$output" ]
}

@test "check-installed: Not Found exits 3 with empty stdout and empty stderr" {
  export CURL_NO_INSTALL=1
  run --separate-stderr zsh "$MINT_APPROVER" --check-installed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ "$(mint_requests)" = "0" ]
}

@test "check-installed: a rejected lookup exits 2 with the key diagnostic, never as not installed" {
  export CURL_INSTALL_REJECTED=1
  run --separate-stderr zsh "$MINT_APPROVER" --check-installed
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "GitHub rejected the claude-approver installation lookup on timo-jakob/widget"
  contains "$stderr" "API response:"
  lacks "$stderr" "is not installed"
  [ "$(mint_requests)" = "0" ]
}

@test "check-installed: an unreachable GitHub exits 2 with the network diagnostic, never as not installed" {
  export CURL_OFFLINE=1
  run --separate-stderr zsh "$MINT_APPROVER" --check-installed
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "Could not reach GitHub to look up the claude-approver installation on timo-jakob/widget"
  lacks "$stderr" "is not installed"
  [ "$(mint_requests)" = "0" ]
}

@test "without the flag, Not Found still exits 2 with the install hint (open-pr's fallback key)" {
  export CURL_NO_INSTALL=1
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "claude-approver App is not installed on timo-jakob/widget."
  contains "$stderr" "Run /development:bootstrap to install."
}

@test "without the flag, an installed App still mints a token" {
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  [ "$(cat "$output")" = "ghs_minted_by_111" ]
  [ "$(mint_requests)" = "1" ]
}

@test "a misspelled flag (--check-install) exits 1 with the usage line and makes no access_tokens request" {
  run --separate-stderr zsh "$MINT_APPROVER" --check-install
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "usage: mint-approver-token.zsh [--stdout|--check-installed]"
  # Rejected before any GitHub call: no lookup, so no access_tokens request.
  [ ! -e "$STUB_DIR/curl.log" ]
}

@test "a second argument (--stdout --check-installed) exits 1 with the usage line and makes no GitHub request" {
  # --stdout first: were the second argument ignored, this would mint a token.
  run --separate-stderr zsh "$MINT_APPROVER" --stdout --check-installed
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "usage: mint-approver-token.zsh [--stdout|--check-installed]"
  [ ! -e "$STUB_DIR/curl.log" ]
}

@test "the header comment documents --check-installed and exit 3" {
  header=$(sed -n '1,/^setopt/p' "$MINT_APPROVER")
  contains "$header" "--check-installed"
  contains "$header" "3 — --check-installed only: the App is not installed on this repo"
}
