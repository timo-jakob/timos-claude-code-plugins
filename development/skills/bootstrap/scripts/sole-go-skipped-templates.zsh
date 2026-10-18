#!/usr/bin/env zsh
# The templates a sole-Go render skips (#2617), the file-level half of folding
# the source-only CI checks into the Go gate (#2128).
#
# For a sole-Go repo (#2615's is-sole-go.zsh is the only judge) the gate in
# go-ci.yml runs every source-only check (#2614), so the workflows that ran them
# stop rendering. The job-level half lives inside the quality templates, as
# render.zsh's NOT_SOLE_GO block tags; this script is the one place the
# file-level half is written down. SKILL.md Step 3 subtracts what it prints from
# what it renders or copies, detect-stack.sh holds the same set out of
# missing_artifacts, and the bats render tests enumerate their rows through it.
#
#   sole-Go, always     common/.github/workflows/gitleaks.yml
#                       common/.github/workflows/no-cluster-deploy.yml.tmpl
#                       common/.github/workflows/docs.yml.tmpl
#                       common/.github/workflows/contracts-lint.yml.tmpl
#                       common/.github/workflows/contracts-semver.yml.tmpl
#   sole-Go, unless a   <vis>/.github/workflows/quality-<vis>.yml.tmpl
#   Dockerfile or swift <vis>/.github/workflows/quality-<vis>-noop.yml.tmpl
#
# A Dockerfile keeps both quality files, for the Docker lane (`image`,
# `push-and-sign`; the noop carries only `image`). Swift keeps both too: the
# workflow's `test-and-coverage-swift` job reports the `test-and-coverage` check
# #2616 still requires for Go+Swift, and the noop's `test-and-coverage` reports it
# on the doc-only PRs the workflow's `paths-ignore` skips.
#
# Usage:
#   sole-go-skipped-templates.zsh --primary <p> --languages "<a b c>" \
#     --visibility public|private --docker true|false
#
# Output: one template relpath (relative to templates/) per line, sorted
# (LC_ALL=C), and nothing for a repo that is not sole-Go.
# Exit codes: 0 printed (possibly nothing); 1 is-sole-go.zsh failed;
# 2 usage error (a missing flag or a value outside its set).

set -euo pipefail

usage() {
	print -u2 -- "usage: sole-go-skipped-templates.zsh --primary <p> --languages \"<a b c>\""
	print -u2 -- "       --visibility public|private --docker true|false"
	exit 2
}

typeset -A val
while (($# > 0)); do
	case "$1" in
	--primary | --languages | --visibility | --docker)
		(($# >= 2)) || { print -u2 -- "sole-go-skipped-templates: $1 needs a value" && usage; }
		val[${1#--}]="$2"
		shift 2
		;;
	--help | -h) usage ;;
	*) print -u2 -- "sole-go-skipped-templates: unknown argument: $1" && usage ;;
	esac
done

typeset k
for k in primary languages visibility docker; do
	((${+val[$k]})) || { print -u2 -- "sole-go-skipped-templates: --$k is required" && usage; }
done
[[ "${val[visibility]}" == (public|private) ]] ||
	{ print -u2 -- "sole-go-skipped-templates: --visibility must be public or private" && usage; }
[[ "${val[docker]}" == (true|false) ]] ||
	{ print -u2 -- "sole-go-skipped-templates: --docker must be true or false" && usage; }

typeset rc=0
zsh "${0:A:h}/is-sole-go.zsh" --primary "${val[primary]}" --languages "${val[languages]}" || rc=$?
case $rc in
0) ;;
1) exit 0 ;;
*) print -u2 -- "sole-go-skipped-templates: is-sole-go.zsh failed (exit $rc)" && exit 1 ;;
esac

typeset vis="${val[visibility]}"
typeset -a skipped=(
	common/.github/workflows/gitleaks.yml
	common/.github/workflows/no-cluster-deploy.yml.tmpl
	common/.github/workflows/docs.yml.tmpl
	common/.github/workflows/contracts-lint.yml.tmpl
	common/.github/workflows/contracts-semver.yml.tmpl
)
typeset -a langs=(${=val[languages]})
if [[ "${val[docker]}" != true ]] && ((!${langs[(Ie)swift]})); then
	skipped+=("$vis/.github/workflows/quality-$vis.yml.tmpl" "$vis/.github/workflows/quality-$vis-noop.yml.tmpl")
fi
print -rl -- "${skipped[@]}" | LC_ALL=C sort
