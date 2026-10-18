#!/usr/bin/env zsh
# The folded CI a sole-Go repo still carries from before #2617 (epic #2128).
#
# A fresh sole-Go render no longer emits the workflows and jobs the gate now
# runs (sole-go-skipped-templates.zsh, render.zsh's NOT_SOLE_GO tags), but a
# re-run never deletes or edits a file (#2126 owns removal). This script names
# what an existing repo still carries, so bootstrap's Step 5 final report can
# say so, and the drift detector (#2618) reuses it:
#
#   - every file sole-go-skipped-templates.zsh skips that is still on disk, by
#     its deploy path (the template relpath minus its tree and `.tmpl`);
#   - every folded job (test-and-coverage, trivy-fs, license-fs, semgrep,
#     pre-commit, sonarcloud, sonarqube) that an on-disk
#     .github/workflows/quality-<visibility>.yml or its noop still defines under
#     `jobs:`, as `<file>#<job>`. On a Go+Swift repo the noop's
#     `test-and-coverage` is not a leftover: it reports the check #2616 still
#     requires there.
#
# Sole-Go is decided only by is-sole-go.zsh, from the recorded `primary:` in
# .maintenance.yml and the languages detect-stack.sh detects in the repo. A repo
# with no recorded primary is not sole-Go. The repo is only read, never written.
#
# Usage:
#   sole-go-leftovers.zsh --repo <path> --visibility public|private --docker true|false
#
# Output: the file lines, then the `<file>#<job>` lines, each group sorted
# (LC_ALL=C); nothing for a repo that is not sole-Go, or one with no leftovers.
# Exit codes: 0 printed (possibly nothing); 1 detect-stack.sh, is-sole-go.zsh
# or the skip-set selector failed; 2 usage error.

set -euo pipefail

usage() {
	print -u2 -- "usage: sole-go-leftovers.zsh --repo <path> --visibility public|private --docker true|false"
	exit 2
}

typeset -A val
while (($# > 0)); do
	case "$1" in
	--repo | --visibility | --docker)
		(($# >= 2)) || { print -u2 -- "sole-go-leftovers: $1 needs a value" && usage; }
		val[${1#--}]="$2"
		shift 2
		;;
	--help | -h) usage ;;
	*) print -u2 -- "sole-go-leftovers: unknown argument: $1" && usage ;;
	esac
done

typeset k
for k in repo visibility docker; do
	((${+val[$k]})) || { print -u2 -- "sole-go-leftovers: --$k is required" && usage; }
done
[[ -d "${val[repo]}" ]] || { print -u2 -- "sole-go-leftovers: --repo is not a directory: ${val[repo]}" && usage; }
[[ "${val[visibility]}" == (public|private) ]] ||
	{ print -u2 -- "sole-go-leftovers: --visibility must be public or private" && usage; }
[[ "${val[docker]}" == (true|false) ]] ||
	{ print -u2 -- "sole-go-leftovers: --docker must be true or false" && usage; }

typeset here="${0:A:h}" repo="${val[repo]:A}" vis="${val[visibility]}"

# the recorded primary, read the way detect-stack.sh reads it: comment and
# trailing whitespace stripped first, then one pair of quotes
typeset primary=""
if [[ -f "$repo/.maintenance.yml" ]]; then
	primary="$(sed -n 's/^[[:space:]]*primary:[[:space:]]*//p' "$repo/.maintenance.yml" | head -n1 |
		sed -E -e 's/[[:space:]]*(#.*)?$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//')" || primary=""
fi
[[ -n "$primary" ]] || exit 0

typeset detected
detected="$(cd "$repo" && bash "$here/detect-stack.sh" 2>/dev/null)" ||
	{ print -u2 -- "sole-go-leftovers: detect-stack.sh failed in $repo" && exit 1; }
typeset languages
languages="$(jq -r '.languages | join(" ")' <<<"$detected")" ||
	{ print -u2 -- "sole-go-leftovers: detect-stack.sh printed no languages" && exit 1; }

typeset skip
skip="$(zsh "$here/sole-go-skipped-templates.zsh" --primary "$primary" --languages "$languages" \
	--visibility "$vis" --docker "${val[docker]}")" ||
	{ print -u2 -- "sole-go-leftovers: sole-go-skipped-templates.zsh failed" && exit 1; }
# not sole-Go: the selector prints nothing
[[ -n "$skip" ]] || exit 0

typeset -a files=() jobs=()
typeset rel deploy
for rel in ${(f)skip}; do
	deploy="${${rel#*/}%.tmpl}"
	[[ -e "$repo/$deploy" ]] && files+=("$deploy")
done

typeset -a langs=(${=languages})
typeset -a folded=(test-and-coverage trivy-fs license-fs semgrep pre-commit sonarcloud sonarqube)
typeset wf job
for wf in ".github/workflows/quality-$vis.yml" ".github/workflows/quality-$vis-noop.yml"; do
	[[ -f "$repo/$wf" ]] || continue
	# the keys directly under the top-level `jobs:` mapping
	for job in ${(f)"$(awk '/^jobs:[[:space:]]*$/ { on = 1; next }
		on && /^[^[:space:]#]/ { on = 0 }
		on && /^  [A-Za-z0-9_-]+:/ { sub(/^  /, ""); sub(/:.*/, ""); print }' "$repo/$wf")"}; do
		((${folded[(Ie)$job]})) || continue
		[[ "$wf" == *-noop.yml && "$job" == test-and-coverage ]] && ((${langs[(Ie)swift]})) && continue
		jobs+=("$wf#$job")
	done
done

((${#files})) && print -rl -- "${files[@]}" | LC_ALL=C sort
((${#jobs})) && print -rl -- "${jobs[@]}" | LC_ALL=C sort
exit 0
