#!/usr/bin/env bash
# cleanup-hook.sh — PostToolUse hook that runs cleanup.sh after a successful gh pr merge.
# Registered by the plugin itself via development/hooks/hooks.json (PostToolUse/Bash), so
# it needs no manual ~/.claude/settings.json entry. Note it is NOT opt-in: it loads for
# every installer of the `development` plugin and fires whenever a `gh pr merge` exits 0.

input=$(cat)

cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
exit_code=$(echo "$input" | jq -r '.tool_response.exit_code // 1')
cwd=$(echo "$input" | jq -r '.cwd // ""')

# Only run when a gh pr merge succeeded
if [[ "$cmd" =~ gh[[:space:]]+pr[[:space:]]+merge ]] && [[ "$exit_code" == "0" ]]; then
	cd "$cwd" || exit 1
	exec "$(dirname "$0")/cleanup.sh"
fi
