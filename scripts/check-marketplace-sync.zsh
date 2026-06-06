#!/usr/bin/env zsh
# check-marketplace-sync.zsh — verify .claude-plugin/marketplace.json's
# per-plugin version entries match the corresponding plugin.json files.
#
# Exits 0 when every plugin is in sync, 1 on any mismatch, 2 on usage
# errors (jq missing, marketplace file missing).
#
# Invoked by .github/workflows/marketplace-sync.yml on every PR touching
# a plugin.json or marketplace.json. Also runnable locally before
# pushing — no arguments, no environment expected.
#
# Why this script exists: see issue #188 and MAINTAINING.md's
# "Per-merge: bump plugin versions" section. The drift this enforcement
# prevents accumulated across PRs #177 → #186 before #187 reset the
# baseline.

setopt err_exit nounset pipefail

# Repo root is two levels up from this script (scripts/<file>.zsh).
readonly REPO_ROOT="${0:A:h:h}"
readonly MARKETPLACE="${REPO_ROOT}/.claude-plugin/marketplace.json"

command -v jq >/dev/null 2>&1 \
  || { print -u2 -- "jq required, not on PATH."; exit 2; }
[[ -f "$MARKETPLACE" ]] \
  || { print -u2 -- "Marketplace file missing: $MARKETPLACE"; exit 2; }

# --- forward direction: every plugin.json must have a matching marketplace entry
mismatches=0

# Zsh glob (N) suffix turns "no matches" into "empty list" instead of
# an error — protects against the edge case of a fresh repo with no
# plugins yet.
for plugin_json in "$REPO_ROOT"/*/.claude-plugin/plugin.json(N); do
  plugin_name=$(jq -r '.name'    "$plugin_json")
  plugin_version=$(jq -r '.version' "$plugin_json")

  marketplace_version=$(jq -r --arg name "$plugin_name" \
    '.plugins[] | select(.name == $name) | .version' "$MARKETPLACE")

  if [[ -z "$marketplace_version" || "$marketplace_version" == "null" ]]; then
    print -u2 -- "✗ $plugin_name (version $plugin_version) is NOT listed in marketplace.json"
    mismatches=$((mismatches + 1))
    continue
  fi

  if [[ "$plugin_version" != "$marketplace_version" ]]; then
    print -u2 -- "✗ $plugin_name version mismatch:"
    print -u2 -- "    ${plugin_json#$REPO_ROOT/}"
    print -u2 -- "       version: $plugin_version"
    print -u2 -- "    .claude-plugin/marketplace.json"
    print -u2 -- "       version: $marketplace_version"
    mismatches=$((mismatches + 1))
  else
    print -- "✓ $plugin_name @ $plugin_version (in sync)"
  fi
done

# --- reverse direction: every marketplace entry must have a matching plugin.json
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if [[ ! -f "$REPO_ROOT/${name}/.claude-plugin/plugin.json" ]]; then
    print -u2 -- "✗ marketplace.json lists '$name' but $name/.claude-plugin/plugin.json doesn't exist"
    mismatches=$((mismatches + 1))
  fi
done < <(jq -r '.plugins[].name' "$MARKETPLACE")

if (( mismatches > 0 )); then
  print -u2 ""
  print -u2 -- "$mismatches mismatch(es) between plugin.json files and .claude-plugin/marketplace.json."
  print -u2 -- ""
  print -u2 -- "Either bump the marketplace.json entry to match the plugin.json version,"
  print -u2 -- "or revert the plugin.json bump if it was unintentional."
  print -u2 -- "See MAINTAINING.md → 'Per-merge: bump plugin versions whenever you change a plugin'."
  exit 1
fi

print ""
print "All plugins in sync."
