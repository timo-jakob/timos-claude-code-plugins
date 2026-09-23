#!/usr/bin/env zsh
# Resolve and validate a repo's quality toolchain for /development:bootstrap (#1651).
#
# Bootstrap used to pick the toolchain from repo visibility alone. Visibility is
# only a stand-in for "which tools can this repo use for free", so the toolchain
# is now a DECLARATION in .maintenance.yml, next to `primary:` and `gate:`:
#
#   tools:
#     static_analysis: sonarcloud   # sonarcloud | sonarqube
#     vulnerabilities: snyk         # snyk | trivy
#     code_scanning: codeql         # codeql | none
#
# The three categories are independent. Each resolves on its own: a RECORDED
# value in `tools:` wins, else a CHOSEN value (its flag — the Q3a picker's
# answer), else the visibility DEFAULT (public: sonarcloud / snyk / codeql;
# private: sonarqube / trivy / none). An absent, empty (`tools:`, `tools: {}`)
# or null `tools:` records nothing, like `gate:`. Reading a file needs yq
# (mikefarah, v4); a repo with no .maintenance.yml needs no yq at all.
#
# Usage:
#   resolve-tools.zsh --visibility public|private
#                     [--maintenance-file <path>]   (default: ./.maintenance.yml)
#                     [--static-analysis sonarcloud|sonarqube]
#                     [--vulnerabilities snyk|trivy]
#                     [--code-scanning codeql|none]
#                     [--record]
#
# Validation runs in this order; the FIRST failing step wins, with exit 1 and
# exactly one message on stderr:
#   1. --visibility is present and public|private; `tools:`, when present and
#      non-empty, is a mapping whose keys are only the three categories.
#   2. every recorded and flag value is in its category's set.
#   3. each category resolves recorded → chosen → default.
#   4. two combinations are rejected, whatever their values' source:
#      - a PUBLIC repo whose resolved static_analysis is sonarqube — SonarQube
#        runs on a self-hosted runner, and a public repo must never have one;
#      - a PRIVATE repo whose resolved code_scanning is codeql (#1670) — CodeQL on
#        a private repository needs GitHub Advanced Security, which we do not
#        have, so it could be neither run nor tested.
#      Neither combination reaches rendering, so no template carries a branch
#      for either.
# A failing step leaves stdout empty. Every other resolution is renderable: the
# quality workflows are composed per tool from these values (#1670).
#
# On success (exit 0) stdout carries, one per line:
#   static_analysis=<v>  static_analysis_source=recorded|chosen|default
#   vulnerabilities=<v>  vulnerabilities_source=...
#   code_scanning=<v>    code_scanning_source=...
#   self_hosted_runner=true|false   (true iff static_analysis is sonarqube:
#                                    then EVERY quality job runs self-hosted)
#
# --record (only on a resolution that exits 0) writes the resolved values into
# an EXISTING --maintenance-file, touching no existing line (§3a's `gate:`
# idempotency rule): no `tools:` key → the template's block is appended, markers
# and all; an empty `tools:` → the three keys are added inside it (an explicit
# `null` / `~` / `{}` value on that line is dropped so the keys can nest); a
# partial block → only the missing keys are added, at the block's own
# indentation, a key present with no value being filled in rather than
# duplicated; a complete block → no write at all.
#
# Exit codes: 0 resolved; 1 a validation step failed, the maintenance file could
# not be read or recorded into, or yq (mikefarah) is missing; 2 usage error.

set -euo pipefail

usage() {
	print -u2 -- "usage: resolve-tools.zsh --visibility public|private [--maintenance-file <path>]"
	print -u2 -- "       [--static-analysis sonarcloud|sonarqube] [--vulnerabilities snyk|trivy]"
	print -u2 -- "       [--code-scanning codeql|none] [--record]"
	exit 2
}

fail() {
	print -u2 -- "resolve-tools: $1"
	exit 1
}

typeset -a categories=(static_analysis vulnerabilities code_scanning)
typeset -A allowed=(
	static_analysis "sonarcloud sonarqube"
	vulnerabilities "snyk trivy"
	code_scanning "codeql none"
)
typeset -A public_default=(static_analysis sonarcloud vulnerabilities snyk code_scanning codeql)
typeset -A private_default=(static_analysis sonarqube vulnerabilities trivy code_scanning none)

visibility=""
visibility_set=0
maintenance_file="./.maintenance.yml"
record=0
typeset c key
typeset -A chosen

while (($# > 0)); do
	case "$1" in
	--visibility | --maintenance-file | --static-analysis | --vulnerabilities | --code-scanning)
		(($# >= 2)) || { print -u2 -- "resolve-tools: $1 needs a value" && usage; }
		case "$1" in
		--visibility) visibility="$2" && visibility_set=1 ;;
		--maintenance-file) maintenance_file="$2" ;;
		--static-analysis) chosen[static_analysis]="$2" ;;
		--vulnerabilities) chosen[vulnerabilities]="$2" ;;
		--code-scanning) chosen[code_scanning]="$2" ;;
		esac
		shift 2
		;;
	--record) record=1 && shift ;;
	--help | -h) usage ;;
	*) print -u2 -- "resolve-tools: unknown argument: $1" && usage ;;
	esac
done

# --- step 1: visibility, and the shape of tools: ------------------------------

((visibility_set)) || fail "--visibility is required — allowed: public | private"
[[ "$visibility" == public || "$visibility" == private ]] ||
	fail "--visibility: $visibility is not supported — allowed: public | private"

# tools_state: none (absent / null / empty — nothing recorded) or map.
tools_state=none
typeset -A recorded
if [[ -f "$maintenance_file" ]]; then
	# Only a file to read needs yq, and only mikefarah's: python-yq answers `type`
	# in jq's vocabulary, which would read every file as a malformed declaration.
	[[ "$(yq --version 2>&1)" == *mikefarah* ]] ||
		fail "yq (mikefarah, v4) is required to read $maintenance_file — install it with: brew install yq"
	tools_type="$(yq -r '.tools | type' "$maintenance_file" 2>/dev/null)" ||
		fail "cannot parse $maintenance_file as YAML"
	case "$tools_type" in
	'!!null') ;;
	'!!map')
		# `tools: {}` is an empty mapping: it records nothing, like `tools:`
		[[ "$(yq -r '.tools | length' "$maintenance_file")" == 0 ]] || tools_state=map
		for key in "${(@f)$(yq -r '.tools | keys | .[]' "$maintenance_file")}"; do
			[[ -n "$key" ]] || continue
			((${categories[(Ie)$key]})) ||
				fail "unknown key tools.$key — allowed: static_analysis, vulnerabilities, code_scanning"
		done
		;;
	'!!seq') fail "tools: must be a mapping of static_analysis, vulnerabilities, code_scanning — got a list" ;;
	*)
		# An empty string records nothing, like an empty key; any other scalar is
		# a malformed declaration.
		if [[ -n "$(yq -r '.tools' "$maintenance_file")" ]]; then
			fail "tools: must be a mapping of static_analysis, vulnerabilities, code_scanning — got a scalar"
		fi
		;;
	esac
fi

if [[ "$tools_state" == map ]]; then
	typeset vtype
	for c in "${categories[@]}"; do
		vtype="$(yq -r ".tools.$c | type" "$maintenance_file")"
		case "$vtype" in
		'!!null') ;; # key absent or null: this category records nothing
		'!!map' | '!!seq') recorded[$c]="$(yq -o=json -I=0 ".tools.$c" "$maintenance_file")" ;;
		*)
			recorded[$c]="$(yq -r ".tools.$c" "$maintenance_file")"
			[[ -n "${recorded[$c]}" ]] || unset "recorded[$c]"
			;;
		esac
	done
fi

# --- step 2: every recorded and flag value is in its category's set -----------

in_set() { # <category> <value>
	local -a set=(${=allowed[$1]})
	((${set[(Ie)$2]}))
}

for c in "${categories[@]}"; do
	# Set-ness, not emptiness: a flag passed as "" is still a declared value.
	if ((${+recorded[$c]})) && ! in_set "$c" "${recorded[$c]}"; then
		fail "tools.$c: ${recorded[$c]} is not supported — allowed: ${allowed[$c]// / | }"
	fi
	if ((${+chosen[$c]})) && ! in_set "$c" "${chosen[$c]}"; then
		fail "tools.$c: ${chosen[$c]} is not supported — allowed: ${allowed[$c]// / | }"
	fi
done

# --- step 3: resolve recorded → chosen → default --------------------------------

typeset -A resolved source
for c in "${categories[@]}"; do
	if ((${+recorded[$c]})); then
		resolved[$c]="${recorded[$c]}" source[$c]=recorded
	elif ((${+chosen[$c]})); then
		resolved[$c]="${chosen[$c]}" source[$c]=chosen
	elif [[ "$visibility" == public ]]; then
		resolved[$c]="${public_default[$c]}" source[$c]=default
	else
		resolved[$c]="${private_default[$c]}" source[$c]=default
	fi
done

self_hosted_runner=false
[[ "${resolved[static_analysis]}" == sonarqube ]] && self_hosted_runner=true

# --- step 4: the two combinations that never reach rendering --------------------

if [[ "$visibility" == public && "${resolved[static_analysis]}" == sonarqube ]]; then
	fail "tools.static_analysis: sonarqube is not supported on a public repository — SonarQube runs on a self-hosted runner, and a public repository must never have one (fork pull requests could run code on it). Declare static_analysis: sonarcloud, or make the repository private."
fi
if [[ "$visibility" == private && "${resolved[code_scanning]}" == codeql ]]; then
	fail "tools.code_scanning: codeql is not supported on a private repository — CodeQL on a private repository needs GitHub Advanced Security. Declare code_scanning: none, or make the repository public."
fi

emit() {
	for c in "${categories[@]}"; do
		print -r -- "$c=${resolved[$c]}"
		print -r -- "${c}_source=${source[$c]}"
	done
	print -r -- "self_hosted_runner=$self_hosted_runner"
}

# --- --record: write the resolved values without touching an existing line -----

record_tools() {
	local file="$maintenance_file"
	[[ -f "$file" ]] || fail "--record needs an existing $file — a fresh repo gets tools: from .maintenance.yml.tmpl"

	local -a missing
	for c in "${categories[@]}"; do
		((${+recorded[$c]})) || missing+=("$c")
	done
	((${#missing})) || return 0 # complete block: no write at all

	if [[ "$tools_state" == map && "$(yq -r '.tools | style' "$file")" == flow ]]; then
		fail "cannot record into the flow-style tools: mapping in $file — rewrite it as a block mapping"
	fi

	local -a lines
	lines=("${(@f)$(<"$file")}")
	local i tools_line=0
	for ((i = 1; i <= ${#lines}; i++)); do
		if [[ "${lines[i]}" == tools:* ]]; then
			tools_line=$i
			break
		fi
	done

	if ((tools_line == 0)); then
		[[ "$(yq -r 'has("tools")' "$file")" != true ]] ||
			fail "cannot find the top-level tools: line in $file to record into"
		# No tools: key at all — append the block, byte-for-byte what the template
		# renders (markers included), so a merged repo and a fresh one agree.
		record_tmp="$(mktemp "${file:h}/.resolve-tools.XXXXXX")"
		{
			cat "$file"
			# $(…) strips a trailing newline, so a non-empty last byte means it is missing
			if [[ -n "$(tail -c 1 "$file")" ]]; then print; fi
			print -r -- "# --- TOOLCHAIN-START ---"
			print -r -- "# The quality toolchain /development:bootstrap resolved (#1651). A recorded value wins on every"
			print -r -- "# re-run: static_analysis sonarcloud | sonarqube, vulnerabilities snyk | trivy, code_scanning codeql | none."
			print -r -- "tools:"
			for c in "${categories[@]}"; do print -r -- "  $c: ${resolved[$c]}"; done
			print -r -- "# --- TOOLCHAIN-END ---"
		} >"$record_tmp" || fail "could not record the toolchain into $file"
		write_back "$file" "$record_tmp"
		return 0
	fi

	# Where the new keys go, and at what indentation. `repl` holds whole-line
	# replacements (`<lineno>\t<text>`): only a line that carries NO value today —
	# a null `tools:` or a null category key — is ever rewritten, and only to give
	# it one.
	local indent="  " insert_after=$tools_line repl="" rest value comment
	typeset -A null_key_line
	if [[ "$tools_state" == map ]]; then
		local first=1 k
		for ((i = tools_line + 1; i <= ${#lines}; i++)); do
			[[ -z "${lines[i]//[[:space:]]/}" ]] && continue  # blank line inside
			[[ "${lines[i]}" =~ '^[[:space:]]*#' ]] && continue # a comment, at any indent
			[[ "${lines[i]}" == [[:space:]]* ]] || break        # dedent: block over
			if ((first)); then
				indent="${lines[i]%%[^[:space:]]*}"
				first=0
			fi
			insert_after=$i
			# the key as YAML reads it: `code_scanning :` and `"code_scanning":` name
			# the same key as `code_scanning:`
			k="${${lines[i]#"${lines[i]%%[^[:space:]]*}"}%%:*}"
			k="${k%"${k##*[![:space:]]}"}"
			k="${${k#[\"\']}%[\"\']}"
			((${categories[(Ie)$k]})) && null_key_line[$k]=$i
		done
	else
		# `tools:` with no value, or an explicit null / "": keys nest under a bare `tools:`.
		rest="${lines[tools_line]#tools:}" comment=""
		value="${rest%%\#*}"
		[[ "$rest" == *\#* ]] && comment=" #${rest#*\#}"
		[[ -n "${value//[[:space:]]/}" ]] && repl+="$tools_line"$'\t'"tools:$comment"$'\n'
	fi

	local block=""
	for c in "${missing[@]}"; do
		if ((${+null_key_line[$c]})); then
			# the key is already there with no value: fill that line in rather than
			# add a duplicate key, keeping any trailing comment
			rest="${lines[${null_key_line[$c]}]#*:}" comment=""
			[[ "$rest" == *\#* ]] && comment=" #${rest#*\#}"
			repl+="${null_key_line[$c]}"$'\t'"${indent}$c: ${resolved[$c]}$comment"$'\n'
		else
			block+="${indent}$c: ${resolved[$c]}"$'\n'
		fi
	done
	record_tmp="$(mktemp "${file:h}/.resolve-tools.XXXXXX")"
	local tmp="$record_tmp"
	# Both texts travel through the environment: BSD awk rejects a newline in -v.
	REPL="$repl" BLOCK="$block" awk -v at="$insert_after" '
		BEGIN {
			n = split(ENVIRON["REPL"], r, "\n")
			for (j = 1; j <= n; j++) if (r[j] != "") { t = index(r[j], "\t"); rl[substr(r[j], 1, t - 1)] = substr(r[j], t + 1) }
		}
		{ if (NR in rl) print rl[NR]; else print }
		NR == at { printf "%s", ENVIRON["BLOCK"] }
	' "$file" >"$tmp" || fail "could not record the toolchain into $file"
	write_back "$file" "$tmp"
}

# Never write back a merge that YAML does not read as the resolved toolchain (a
# value on the line AFTER `tools:`, a flow-style top level): the file would stop
# parsing. The write goes through the file itself, keeping its mode and inode.
write_back() { # <file> <merged temp>
	for c in "${categories[@]}"; do
		[[ "$(yq -r ".tools.$c" "$2" 2>/dev/null)" == "${resolved[$c]}" ]] ||
			fail "could not record the toolchain into $1 — merging into its tools: layout would not read back; left it unchanged"
	done
	cat "$2" >"$1" || { record_tmp="" && fail "could not record the toolchain into $1 — the merged text is in $2"; }
}

# Never leave --record's temp file in the consumer repo — except as the only
# good copy, when the write-back itself failed (record_tmp is cleared there).
record_tmp=""
trap '[[ -z "$record_tmp" ]] || rm -f "$record_tmp"' EXIT

((record)) && record_tools

emit
