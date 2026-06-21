#!/usr/bin/env bats
#
# Behavioral tests for install-claude-apps.zsh's base_author_allowlist (#425).
#
# The Claude Approver's Gate 3 matches the REST `.user.login` of the PR author
# against CLAUDE_APPROVER_AUTHOR_ALLOWLIST. A Renovate repo's dependency PRs are
# authored by `renovate[bot]`, a Dependabot repo's by `dependabot[bot]` — so the
# allowlist's dependency-bot entry MUST track the repo's actual tool, or every
# vendor PR is policy-skipped and never auto-merges. These tests source the
# script (its `main` is guarded, so sourcing has no side effects) and assert the
# computed allowlist for each tool layout.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/scripts/install-claude-apps.zsh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/.github"
}

# Compute the base allowlist for the WORK repo layout.
allowlist() { run zsh -c "source '$S'; base_author_allowlist '$WORK'"; }

# Membership helpers against the JSON array in $output.
has() { echo "$output" | jq -e --arg b "$1" 'any(. == $b)' >/dev/null; }
hasnt() { ! echo "$output" | jq -e --arg b "$1" 'any(. == $b)' >/dev/null; }

@test "allowlist: #425 Renovate repo seeds renovate[bot], not a stray dependabot[bot]" {
  echo '{}' > "$WORK/renovate.json"
  allowlist
  [ "$status" -eq 0 ]
  has "renovate[bot]"
  hasnt "dependabot[bot]"
  has "github-actions[bot]"
}

@test "allowlist: #425 .github/renovate.json is also detected as Renovate" {
  echo '{}' > "$WORK/.github/renovate.json"
  allowlist
  has "renovate[bot]"
  hasnt "dependabot[bot]"
}

@test "allowlist: #425 Dependabot repo seeds dependabot[bot], not renovate[bot]" {
  echo 'version: 2' > "$WORK/.github/dependabot.yml"
  allowlist
  has "dependabot[bot]"
  hasnt "renovate[bot]"
  has "github-actions[bot]"
}

@test "allowlist: #425 both tools present -> both bots seeded" {
  echo '{}' > "$WORK/renovate.json"
  echo 'version: 2' > "$WORK/.github/dependabot.yml"
  allowlist
  has "renovate[bot]"
  has "dependabot[bot]"
  has "github-actions[bot]"
}

@test "allowlist: #425 neither configured -> dependabot[bot] (family default)" {
  allowlist
  has "dependabot[bot]"
  hasnt "renovate[bot]"
  has "github-actions[bot]"
}

@test "allowlist: output is a valid compact JSON array" {
  echo '{}' > "$WORK/renovate.json"
  allowlist
  echo "$output" | jq -e 'type == "array"' >/dev/null
}

@test "allowlist: sourcing install-claude-apps does not run main (no side effects)" {
  run zsh -c "source '$S'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
