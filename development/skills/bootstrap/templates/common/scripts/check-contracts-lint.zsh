#!/usr/bin/env zsh
# check-contracts-lint.zsh — lint this repository's newest contract majors with the pinned
# Spectral, the contracts lint stage every language gate shares (#2640, epic #1608). Owned and
# re-rendered by /development:bootstrap, copied verbatim: a gate calls it rather than carrying
# its own copy of the selection, so every gate selects exactly what contracts-lint.yml selects.
#
# It selects the newest strict vN major of contracts/ and of contracts/ops/ that holds an
# openapi.yaml, refusing a newest vN directory without one rather than falling back to an older,
# frozen major, and runs Spectral with the repo's .spectral.yaml over what it selected. It needs
# node; Spectral is pinned below and runs through npx.
#
# Usage: zsh scripts/check-contracts-lint.zsh [--caller <name>] [-h|--help], from the
# repository root. --caller names the calling gate, and prefixes every line this script prints:
# `<caller>: FAIL contracts lint — <reason>` on stderr, informational lines on stdout. Without
# it the prefix is check-contracts-lint.
#
# Exit codes: 0 linted; 1 failed, the reason on stderr; 2 an unknown or malformed argument;
# 3 no contracts/vN/openapi.yaml to lint.

emulate -L zsh
setopt pipefail no_unset

caller="${${0:t}%.zsh}"
while (( $# )); do
	case "$1" in
	-h | --help)
		awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
		exit 0
		;;
	--caller)
		[[ $# -ge 2 && -n "$2" ]] || { print -u2 -r -- "$caller: --caller needs a value"; exit 2; }
		caller="$2"
		shift 2
		;;
	*)
		print -u2 -r -- "$caller: unknown argument: $1"
		exit 2
		;;
	esac
done

# the version of the Spectral CLI the stage runs without installing it first
spectral_cli="@stoplight/spectral-cli@6.15.0"

fail() { print -u2 -r -- "$caller: FAIL contracts lint — $1"; exit 1 }

# --- selector-start (tests/render-contracts-templates.bats runs it beside contracts-lint.yml's)
# newest_major <family> <file>: the newest strict vN directory of <family> holding <file>, as
# <family>/vN/<file>; with an empty <file>, the newest vN directory itself. A v3-draft or v2.bak
# is not a major, and majors compare as integers, so v10 is newer than v9.
newest_major() {
	local c n best="" best_n=-1
	for c in "$1"/v[0-9]*/"$2"(N); do
		n="${c#"$1"/v}"
		n="${n%%/*}"
		[[ "$n" == <-> ]] || continue
		if (( n > best_n )); then
			best_n=$n
			best="$c"
		fi
	done
	print -rn -- "$best"
}
# contract_specs: the newest major's openapi.yaml of contracts/ and of contracts/ops/, one a line.
# A newest vN directory without an openapi.yaml fails, rather than falling back to an older,
# frozen major that nobody may change.
contract_specs() {
	local family spec dir
	for family in contracts contracts/ops; do
		spec="$(newest_major "$family" openapi.yaml)"
		dir="$(newest_major "$family" "")"
		if [[ -n "$dir" && "$spec" != "${dir}openapi.yaml" ]]; then
			print -u2 -r -- "$caller: ${dir} is the newest major of ${family} but has no openapi.yaml —" \
				"refusing to fall back to an older, frozen major. Commit the spec, or remove the directory."
			return 1
		fi
		[[ -z "$spec" ]] || print -r -- "$spec"
	done
}
# --- selector-end

command -v node >/dev/null 2>&1 || fail "node is not installed"
spec_list="$(contract_specs)" || fail "the newest contract major has no openapi.yaml"
specs=(${(f)spec_list})
(( ${#specs} )) || exit 3
print -r -- "$caller: linting ${specs[*]}"
npx --yes "$spectral_cli" lint --ruleset .spectral.yaml --fail-severity error "${specs[@]}" ||
	fail "spectral"
