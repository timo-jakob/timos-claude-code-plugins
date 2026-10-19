#!/usr/bin/env zsh
# recommend-ui-shape.zsh — recommend the UI shape a React repo is scaffolded as:
# the shell (the family default) or a remote (#1127, epic #1122).
#
# Usage:
#   recommend-ui-shape.zsh --languages <csv> --react-overlay <applies|absent|skipped> <repo_path>
#
# The bootstrap SKILL runs it while assembling the Step 2 plan (Shared questions
# Q7). Browser UI is never asked about: it is §3k.5's *Does the overlay apply?*
# verdict, passed as --react-overlay. The only question a user can see is shell
# or remote, and only when this script exits 0.
#
#   --languages      detect-stack.sh's `languages`, comma-separated. An empty or
#                    all-space value is the empty list (no-javascript). Any other
#                    value is malformed (exit 2) when an element is empty (`a,,b`,
#                    a leading or trailing comma) or, spaces trimmed, is not a
#                    lowercase identifier ([a-z][a-z0-9_-]*).
#   --react-overlay  §3k.5's verdict: `applies`; `absent` (react-marker exit 1);
#                    or `skipped` (no root Vite config, a function-exported Vite
#                    config, or react-marker UNEVALUATED).
#
# Gates, checked in this order (the first that matches decides):
#   1. javascript not in --languages        → exit 3, reason no-javascript
#   2. --react-overlay absent               → exit 3, reason no-browser-ui
#   3. --react-overlay skipped              → exit 3, reason react-overlay-skipped
#      (kept apart from no-browser-ui, so an undecided marker is never reported
#      as "no UI here")
#   4. src/shell/loader.ts AND src/remote/entry.tsx
#                                           → exit 3, reason conflicting-markers
#   5. one shape marker                     → exit 3, reason shape-marker:
#      src/shell/loader.ts marks a shell; src/remote/entry.tsx a remote, a widget
#      when src/remote/manifest.ts sits beside it, else a page
#   6. otherwise                            → exit 0, the shell recommendation.
#      With no marker nothing on disk tells a future remote from a shell, so the
#      recommendation is the family default and says so in `basis`.
#
# Exit 0 prints {"applicable": true, "shape": "shell", "remote_kind": null,
#   "basis": "default", "plan_line": "<the Step 2 plan line>"}.
# Exit 3 prints {"applicable": false, "reason": "<reason>", "shape", "remote_kind",
#   "marker"}: shape and remote_kind are non-null only for shape-marker; marker
#   only for shape-marker (the marker found) and conflicting-markers (the remote
#   marker).
# Exit 2 is a usage or precondition error — a missing or unknown flag, a malformed
#   --languages value, an unknown --react-overlay value, a missing or non-directory repo path, an argument after
#   the path, or no jq. It writes a diagnostic to stderr and nothing to stdout,
#   so malformed input is never read as "no UI here".
#
# It only reads <repo_path>; it never writes a file.

emulate -L zsh
setopt extended_glob
set -euo pipefail

PLAN_LINE='React UI shape: shell (default) — reply `remote: page` or `remote: widget` to scaffold a remote instead (#1127)'

usage() {
	print -u2 "usage: recommend-ui-shape.zsh --languages <csv> --react-overlay <applies|absent|skipped> <repo_path>"
	exit 2
}

languages="" overlay="" have_languages=0
while (($# > 0)); do
	case "$1" in
		--languages)
			(($# >= 2)) || usage
			languages="$2"
			have_languages=1
			shift 2
			;;
		--react-overlay)
			(($# >= 2)) || usage
			case "$2" in
				applies | absent | skipped) overlay="$2" ;;
				*)
					print -u2 "recommend-ui-shape: unknown --react-overlay '$2' (expected applies, absent or skipped)."
					usage
					;;
			esac
			shift 2
			;;
		--*)
			print -u2 "recommend-ui-shape: unknown flag '$1'."
			usage
			;;
		*) break ;;
	esac
done

repo="${1:-}"
if (($# > 1)); then
	print -u2 "recommend-ui-shape: unexpected argument after the repo path: '$2'."
	usage
fi
((have_languages)) || {
	print -u2 "recommend-ui-shape: --languages is required."
	usage
}
lang_list=()
if [[ -n "${languages//[[:space:]]/}" ]]; then
	for lang in "${(@s:,:)languages}"; do
		lang="${${lang##[[:space:]]#}%%[[:space:]]#}"
		[[ "$lang" == [a-z][a-z0-9_-]# ]] || {
			print -ru2 "recommend-ui-shape: malformed --languages '$languages' (expected comma-separated lowercase names)."
			usage
		}
		lang_list+=("$lang")
	done
fi
[[ -n "$overlay" ]] || {
	print -u2 "recommend-ui-shape: --react-overlay is required."
	usage
}
[[ -n "$repo" ]] || usage
[[ -d "$repo" ]] || {
	print -u2 "recommend-ui-shape: '$repo' is not a directory."
	exit 2
}
command -v jq >/dev/null 2>&1 || {
	print -u2 "recommend-ui-shape: jq is required but not on PATH."
	exit 2
}

# not_applicable <reason> [shape] [remote_kind] [marker]
not_applicable() {
	jq -n --arg reason "$1" --arg shape "${2:-}" --arg kind "${3:-}" --arg marker "${4:-}" \
		'{applicable: false, reason: $reason,
		  shape: (if $shape == "" then null else $shape end),
		  remote_kind: (if $kind == "" then null else $kind end),
		  marker: (if $marker == "" then null else $marker end)}'
	exit 3
}

has_javascript=0
((${lang_list[(Ie)javascript]})) && has_javascript=1
((has_javascript)) || not_applicable no-javascript
[[ "$overlay" != absent ]] || not_applicable no-browser-ui
[[ "$overlay" != skipped ]] || not_applicable react-overlay-skipped

shell_marker="src/shell/loader.ts"
remote_marker="src/remote/entry.tsx"
widget_marker="src/remote/manifest.ts"
if [[ -f "$repo/$shell_marker" && -f "$repo/$remote_marker" ]]; then
	not_applicable conflicting-markers "" "" "$remote_marker"
fi
[[ -f "$repo/$shell_marker" ]] && not_applicable shape-marker shell "" "$shell_marker"
if [[ -f "$repo/$remote_marker" ]]; then
	if [[ -f "$repo/$widget_marker" ]]; then
		not_applicable shape-marker remote widget "$remote_marker"
	fi
	not_applicable shape-marker remote page "$remote_marker"
fi

jq -n --arg line "$PLAN_LINE" \
	'{applicable: true, shape: "shell", remote_kind: null, basis: "default", plan_line: $line}'
exit 0
