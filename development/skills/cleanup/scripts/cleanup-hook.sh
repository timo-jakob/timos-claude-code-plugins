#!/usr/bin/env bash
# cleanup-hook.sh — PostToolUse hook that runs cleanup.sh after a successful gh pr merge.
# Install by adding a PostToolUse hook pointing to this script in ~/.claude/settings.json.

input=$(cat)

cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
exit_code=$(echo "$input" | jq -r '.tool_response.exit_code // 1')
cwd=$(echo "$input" | jq -r '.cwd // ""')

# Only run when a gh pr merge succeeded
if [[ "$cmd" =~ gh[[:space:]]+pr[[:space:]]+merge ]] && [[ "$exit_code" == "0" ]]; then
	cd "$cwd" || exit 1
	exec "$(dirname "$0")/cleanup.sh"
fi
