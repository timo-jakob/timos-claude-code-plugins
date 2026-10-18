#!/usr/bin/env bats
#
# Needles for #2632: a language Approver agent that restates the policy's
# maintenance-bot special case ("start at `HIGH` ... `APPROVE`") also states
# its #2586 exception, in the same paragraph — a Review dossier reporting
# `open > 0` keeps the policy's cap at `LOW`. A paragraph is a blank-line
# delimited block with its lines joined by single spaces, so re-wrapping one
# never reds a needle.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  EXCEPTION='It does not apply when the Review dossier reports `open > 0` on any lens: the policy'"'"'s cap at `LOW` holds.'
  export LC_ALL=C
}

# The flattened paragraph of <file> that contains <anchor>, one per line.
_para() {
  awk -v anchor="$2" 'BEGIN { RS = "" } {
    gsub(/[ \t]*\n[ \t]*/, " "); gsub(/  +/, " ")
    if (index($0, anchor)) print
  }' "$1"
}

# Passes when exactly one paragraph of <file> holds <anchor> and it carries
# the exception sentence.
_carries_exception() {
  local para
  para="$(_para "$1" "$2")"
  [ -n "$para" ] || { printf 'no paragraph in %s holds: %s\n' "$1" "$2" >&2; return 1; }
  [ "$(printf '%s\n' "$para" | wc -l | tr -d ' ')" -eq 1 ] || {
    printf 'more than one paragraph in %s holds: %s\n' "$1" "$2" >&2; return 1; }
  case "$para" in
    *"$EXCEPTION"*) : ;;
    *) printf 'the paragraph in %s holding "%s" lacks the exception:\n%s\n' "$1" "$2" "$para" >&2
       return 1 ;;
  esac
}

@test "#2712 go-approver's Maintenance-bot special case section carries the open > 0 exception" {
  _carries_exception "$REPO_ROOT/development-go/agents/go-approver.md" \
    'tool findings start at `HIGH` confidence and can `APPROVE` directly'
}

@test "#2712 go-approver's Step 11 special case from the policy carries the open > 0 exception" {
  _carries_exception "$REPO_ROOT/development-go/agents/go-approver.md" \
    'Special case from the policy: PRs from `claude-maintenance[bot]`'
}
