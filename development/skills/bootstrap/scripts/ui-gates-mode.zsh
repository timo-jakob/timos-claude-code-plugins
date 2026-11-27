#!/usr/bin/env zsh
# ui-gates-mode.zsh — the React overlay's per-repo gate switch, ui-gates.json (#3018).
#
# Usage:
#   ui-gates-mode.zsh mode --repo <dir>
#   ui-gates-mode.zsh write --repo <dir> --mode <warn|block>
#   ui-gates-mode.zsh predecessor --file <path>
#
# The bootstrap SKILL (§3k.5) runs `mode` in Step 2, before any step renders a
# file, and `write` when §3k.5 renders. ARCHITECTURE.md, "React WebUI gates —
# blocking in the app, advisory in maintenance (#1946, #1947)", states the switch.
#
# mode — the a11y mode bootstrap writes when no a11y value exists, the first match of:
#   1. family-matcher: <dir>/src/test/setup.ts registers `toHaveNoViolations`
#      through `expect.extend` and imports neither jest-axe nor vitest-axe (an
#      app bootstrapped before #3018)                               → block
#   2. own-axe: not a family app, and the root package.json's devDependencies
#      carry an axe package — axe-core, vitest-axe, jest-axe or a name starting
#      with @axe-core/ (the maintenance audit's definition)         → warn
#   3. ui-code: a .tsx or .jsx file outside tests, other than src/main.tsx and
#      src/App.tsx (the two files create-vite generates)             → warn
#   4. fresh: none of the above                                      → block
#   "Outside tests" skips any directory named test, tests or __tests__, any file
#   named *.test.* or *.spec.*, and node_modules, dist, build, coverage and every
#   dot-directory. Prints {"mode": "<warn|block>", "rule": "<rule>"}; exit 0.
#   Exit 3 when the root package.json is missing or is not a JSON object: rule 2
#   cannot be judged, so no mode is printed.
#
# write — writes <dir>/ui-gates.json when the file or its a11y key is absent,
#   with a11y set to --mode (normally what `mode` printed). An a11y value already
#   in the file is never changed and the file is not written; every other key is
#   preserved, and "schema": "ui-gates/v1" is added when absent. The file is
#   written by jq with two-space indentation, which Prettier leaves as it is, so
#   the a11y key sits on its own line. Prints {"action": "written"|"kept",
#   "a11y": <value>}; exit 0. Exit 3 when the file exists but is not a JSON
#   object: it is left untouched.
#
# predecessor — whether <path> is byte-identical to a #1946 template this story
#   replaced: src/test/setup.ts or src/test/a11y-canary.test.tsx. Such a file is a
#   known predecessor, upgraded without a prompt. Prints {"known": true,
#   "template": "<relpath>"} or {"known": false}; exit 0.
#
# Exit 2 is a usage or precondition error (an unknown subcommand or flag, a
# missing value, a bad --mode, a missing directory or file, no jq or no sha256
# tool): a diagnostic on stderr, nothing on stdout. Exit 1 is an internal failure
# (a write that did not complete).

emulate -L zsh
setopt extended_glob
set -euo pipefail

# sha256 of the #1946 templates, as they shipped before #3018.
typeset -A PREDECESSORS=(
	[75dc6e4d2953efacea42118b896074e9ea1747dfad04364d432f28230b656619]=src/test/setup.ts
	[b71b7740537244c9692ae68c120eb9c1cbd2f5812cbbb0347400385ccffb6f16]=src/test/a11y-canary.test.tsx
)

usage() {
	print -u2 "usage: ui-gates-mode.zsh mode --repo <dir>"
	print -u2 "       ui-gates-mode.zsh write --repo <dir> --mode <warn|block>"
	print -u2 "       ui-gates-mode.zsh predecessor --file <path>"
	exit 2
}

(($# >= 1)) || usage
cmd="$1"
shift
case "$cmd" in
	mode | write | predecessor) ;;
	*)
		print -u2 "ui-gates-mode: unknown subcommand '$cmd'."
		usage
		;;
esac

repo="" mode="" file=""
while (($# > 0)); do
	case "$1" in
		--repo | --mode | --file)
			(($# >= 2)) || usage
			case "$1" in
				--repo) repo="$2" ;;
				--mode) mode="$2" ;;
				--file) file="$2" ;;
			esac
			shift 2
			;;
		*)
			print -u2 "ui-gates-mode: unknown argument '$1'."
			usage
			;;
	esac
done

command -v jq >/dev/null 2>&1 || {
	print -u2 "ui-gates-mode: jq is required."
	exit 2
}

if [[ "$cmd" == predecessor ]]; then
	[[ -z "$repo" && -z "$mode" ]] || usage
	[[ -n "$file" ]] || usage
	[[ -f "$file" ]] || {
		print -u2 "ui-gates-mode: no such file '$file'."
		exit 2
	}
	if command -v shasum >/dev/null 2>&1; then
		sum="$(shasum -a 256 "$file")"
	elif command -v sha256sum >/dev/null 2>&1; then
		sum="$(sha256sum "$file")"
	else
		print -u2 "ui-gates-mode: shasum or sha256sum is required."
		exit 2
	fi
	sum="${sum%% *}"
	if [[ -n "${PREDECESSORS[$sum]:-}" ]]; then
		jq -cn --arg t "${PREDECESSORS[$sum]}" '{known: true, template: $t}'
	else
		jq -cn '{known: false}'
	fi
	exit 0
fi

[[ -z "$file" ]] || usage
[[ -n "$repo" ]] || usage
[[ -d "$repo" ]] || {
	print -u2 "ui-gates-mode: no such directory '$repo'."
	exit 2
}

if [[ "$cmd" == write ]]; then
	case "$mode" in
		warn | block) ;;
		*)
			print -u2 "ui-gates-mode: --mode must be warn or block."
			usage
			;;
	esac
	target="$repo/ui-gates.json"
	current='{}'
	if [[ -e "$target" ]]; then
		if ! current="$(jq -ce 'if type == "object" then . else error("not an object") end' "$target" 2>/dev/null)"; then
			print -u2 "ui-gates-mode: $target is not a JSON object; left untouched."
			exit 3
		fi
		if jq -e 'has("a11y")' <<<"$current" >/dev/null; then
			jq -c '{action: "kept", a11y: .a11y}' <<<"$current"
			exit 0
		fi
	fi
	tmp="$(mktemp "$repo/.ui-gates.json.XXXXXX")"
	if ! jq --arg m "$mode" '(if has("schema") then . else {schema: "ui-gates/v1"} + . end) + {a11y: $m}' \
		<<<"$current" >"$tmp" || ! mv -f "$tmp" "$target"; then
		rm -f "$tmp"
		print -u2 "ui-gates-mode: could not write $target."
		exit 1
	fi
	jq -cn --arg m "$mode" '{action: "written", a11y: $m}'
	exit 0
fi

# mode
[[ -z "$mode" ]] || usage
emit() { jq -cn --arg m "$1" --arg r "$2" '{mode: $m, rule: $r}'; }

setup="$repo/src/test/setup.ts"
if [[ -f "$setup" ]] && grep -q 'expect\.extend' "$setup" && grep -q 'toHaveNoViolations' "$setup" \
	&& ! grep -Eq "(from|import|require\()[[:space:]]*[\"'](jest|vitest)-axe" "$setup"; then
	emit block family-matcher
	exit 0
fi

pkg="$repo/package.json"
if ! axe="$(jq -er 'if type == "object" then [(.devDependencies // {}) | keys[]
	| select(. == "axe-core" or . == "vitest-axe" or . == "jest-axe" or startswith("@axe-core/"))] | length
	else error("not an object") end' "$pkg" 2>/dev/null)"; then
	print -u2 "ui-gates-mode: $pkg is missing or not a JSON object; the own-axe rule cannot be judged."
	exit 3
fi
if ((axe > 0)); then
	emit warn own-axe
	exit 0
fi

# find prunes the skipped directories, so node_modules is never walked.
if ! found="$(find "$repo" \( -type d ! -path "$repo" \( -name node_modules -o -name dist -o -name build \
	-o -name coverage -o -name test -o -name tests -o -name __tests__ -o -name '.*' \) -prune \) \
	-o \( -type f \( -name '*.tsx' -o -name '*.jsx' \) ! -name '*.test.*' ! -name '*.spec.*' -print \))"; then
	print -u2 "ui-gates-mode: could not scan $repo for UI code."
	exit 1
fi
for f in "${(@f)found}"; do
	[[ -n "$f" ]] || continue
	rel="${f#"$repo"/}"
	[[ "$rel" == src/main.tsx || "$rel" == src/App.tsx ]] && continue
	emit warn ui-code
	exit 0
done

emit block fresh
