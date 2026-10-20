#!/usr/bin/env bats
#
# go-runtime-upgrade moves the golangci-lint pins with the go directive (#2873).
#
# golangci-lint refuses a module whose `go` directive names a newer Go
# (major.minor) than the Go its binary was built with, so an agent that raises
# the directive and leaves the pins behind turns the format and lint gates red.
# These pin the agent's instructions by content: where the pins live, when they
# move, how the built-with Go is read, which release is picked, the one-pin
# case, the third escalation scenario, and how a moved pin is recorded.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AGENT="$REPO_ROOT/development-go/agents/go-runtime-upgrade.md"
  BODY="$(cat "$AGENT")"
}

# The lines from the first one matching $1 up to (not including) the next one
# matching $2, so a needle is pinned to its section rather than the whole file.
# awk -v unescapes its values, so the patterns use [.] and [*], never \. or \*.
_between() {
  awk -v from="$1" -v to="$2" '$0 ~ from { on = 1; next } on && $0 ~ to { exit } on' "$AGENT"
}

@test "#2873 the agent names both golangci-lint pin locations" {
  contains "$BODY" '`GOLANGCI_LINT_VERSION`
in the Makefile and the golangci-lint `rev` in .pre-commit-config.yaml'
  contains "$BODY" "grep -nE '^GOLANGCI_LINT_VERSION' Makefile"
  contains "$BODY" "'golangci/golangci-lint' .pre-commit-config.yaml"
}

@test "#2873 step 3 states when the pins move: only when the pinned build Go's major.minor is lower" {
  local step
  step="$(_between '^### 3[.] Swap the pins' '^### 4[.]')"
  contains "$step" 'settle them before you swap anything'
  contains "$step" 'Run this check only when you raise
the `go` directive, in both `auto` and `skip` modes'
  contains "$step" 'The pins move only
   when that Go'"'"'s major.minor is lower than the new `go` directive'"'"'s
   major.minor. Otherwise leave them alone.'
}

@test "#2873 step 3 names the method: install into scratch, read 'built with', never the tag's go.mod" {
  local step
  step="$(_between '^### 3[.] Swap the pins' '^### 4[.]')"
  contains "$step" 'Install the tag into a scratch directory with upstream'"'"'s
   install.sh and read the `built with goX.Y.Z` line from `golangci-lint
   version`. Compare major.minor only.'
  contains "$step" 'Never use the release tag'"'"'s go.mod
   `go` line'
  contains "$step" 'A tag whose built-with line you could not read,
   because listing the releases, the download, the install or `version`
   failed, counts as built with too old a Go; never guess it.'
  contains "$step" 'sh "$SCRATCH/install.sh" -b "$SCRATCH/bin" "<tag>"'
}

@test "#2873 step 3 picks the lowest qualifying v2 release and sets both pins equal" {
  local step
  step="$(_between '^### 3[.] Swap the pins' '^### 4[.]')"
  contains "$step" 'pick the **lowest** whose built-with
   major.minor is at least the new directive'"'"'s'
  contains "$step" 'Never cross to a new golangci-lint major. Set both pins to that
   release, so they are equal afterwards.'
}

@test "#2873 the closed escalation list carries the third golangci-lint scenario" {
  local list
  list="$(_between '^The [*][*]only[*][*] scenarios where you escalate are:' '^You [*][*]do NOT[*][*]:')"
  contains "$list" '**No golangci-lint v2 release is built with a Go at least as new as the
  new `go` directive**'
  contains "$list" 'Change no pin and commit nothing; escalate
  naming the current golangci-lint pin, the newest release you checked, and
  that release'"'"'s built-with Go.'
}

@test "#2873 one pin missing: bump the one that exists, note the other, never add it or escalate" {
  local step
  step="$(_between '^### 3[.] Swap the pins' '^### 4[.]')"
  contains "$step" 'Bump the pin that exists and note the missing
   location in your output; do not add the missing pin, and do not escalate.'
  contains "$step" 'When neither pin exists, skip this check and note that.'
}

@test "#2873 a moved pin is recorded in pins_updated and as a Runtime line" {
  local output_block runtime
  output_block="$(_between '^## Output' '^## Constraints')"
  contains "$output_block" '"Makefile (GOLANGCI_LINT_VERSION)"'
  contains "$output_block" '".pre-commit-config.yaml (golangci-lint rev)"'
  runtime="$(_between '^Runtime:' '^Cascade upgrades:')"
  contains "$runtime" '- Makefile (GOLANGCI_LINT_VERSION): v2.12.2 -> v2.14.0'
  contains "$runtime" '- .pre-commit-config.yaml (golangci-lint rev): v2.12.2 -> v2.14.0'
}

@test "#2873 the maintenance skill names no golangci-lint version" {
  local skill
  skill="$(cat "$REPO_ROOT/development-go/skills/maintenance/SKILL.md")"
  lacks "$skill" 'v2.12.2'
  run grep -nE 'golangci-lint[^|]*v2\.[0-9]+\.[0-9]+' "$REPO_ROOT/development-go/skills/maintenance/SKILL.md"
  [ "$status" -eq 1 ]
}
