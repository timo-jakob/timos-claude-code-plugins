#!/usr/bin/env zsh
# update-claude-plugins.zsh — refresh the timos-claude-code-plugins marketplace
# and update its installed plugins to the latest version, WITHOUT changing which
# plugins are enabled or disabled.
#
# Why: updating the plugins is a prerequisite for getting the latest maintenance
# behavior + bootstrap templates, but it's easy to forget or do half-way. This
# brings the dev family current in one command before a /development:maintenance
# run. It ONLY calls `claude plugin marketplace update` and `claude plugin
# update` — never `enable`/`disable` — so each plugin's active/inactive state is
# preserved. Claude Code must be RESTARTED afterwards to apply the updates.
#
# Usage:
#   update-claude-plugins.zsh                      # update the family marketplace
#   update-claude-plugins.zsh --marketplace <name> # if you added it under another name
#   update-claude-plugins.zsh --dry-run            # list what would update, change nothing
#
# Env: CLAUDE_BIN overrides the `claude` binary (default: claude).

set -euo pipefail

marketplace="timos-claude-code-plugins"
dry_run="false"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

usage() {
  print -- "Usage: update-claude-plugins.zsh [--marketplace <name>] [--dry-run]"
  print -- "Refresh the '$marketplace' marketplace and update its installed plugins"
  print -- "to the latest version, without changing which plugins are enabled."
}

while (( $# > 0 )); do
  case "$1" in
    --marketplace) marketplace="${2:?--marketplace needs a name}"; shift 2 ;;
    --dry-run)     dry_run="true"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) print -u2 -- "update-claude-plugins: unknown arg: $1 (try --help)"; exit 2 ;;
  esac
done

command -v "$CLAUDE_BIN" >/dev/null 2>&1 || {
  print -u2 -- "update-claude-plugins: '$CLAUDE_BIN' not on PATH — is Claude Code installed?"
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  print -u2 -- "update-claude-plugins: jq not on PATH — install it (brew install jq)."
  exit 1
}

# Installed plugins from our marketplace, as id|scope|enabled lines (enabled or
# not — we update all of them, but never flip the enabled flag).
typeset -a entries
entries=( ${(f)"$("$CLAUDE_BIN" plugin list --json 2>/dev/null \
  | jq -r --arg m "$marketplace" \
      '.[] | select(.id | endswith("@" + $m)) | "\(.id)|\(.scope)|\(.enabled)"')"} )

if [[ "$dry_run" == "true" ]]; then
  print -- "[dry-run] would refresh marketplace: $marketplace"
  if (( ${#entries} == 0 )); then
    print -- "[dry-run] no installed plugins from '$marketplace' — nothing to update."
  else
    print -- "[dry-run] would update (enabled/disabled state left unchanged):"
    for e in "${entries[@]}"; do
      parts=( "${(@s:|:)e}" )
      print -- "  - ${parts[1]}  (scope=${parts[2]}, enabled=${parts[3]})"
    done
  fi
  exit 0
fi

# Refresh the marketplace first (the "update the marketplace" half), then update
# its installed plugins (the "update the plugins" half).
print -- "Refreshing marketplace: $marketplace"
"$CLAUDE_BIN" plugin marketplace update "$marketplace"

if (( ${#entries} == 0 )); then
  print -- "Marketplace refreshed. No installed plugins from '$marketplace' to update."
  print -- "  (Check installed plugins with: $CLAUDE_BIN plugin list)"
  exit 0
fi

failed=0
for e in "${entries[@]}"; do
  parts=( "${(@s:|:)e}" )
  id="${parts[1]}"; scope="${parts[2]}"
  print -- "Updating ${id} (scope=${scope}) ..."
  if ! "$CLAUDE_BIN" plugin update "$id" --scope "$scope"; then
    print -u2 -- "  ! failed to update ${id}"
    failed=$(( failed + 1 ))
  fi
done

print --
if (( failed > 0 )); then
  print -u2 -- "Done with ${failed} failure(s). Enabled/disabled state unchanged."
  exit 1
fi
print -- "✓ Updated ${#entries} plugin(s) from ${marketplace}. Enabled/disabled state unchanged."
print -- "↻ Restart Claude Code to apply the updates."
