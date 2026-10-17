#!/usr/bin/env zsh
# Is this repo sole-Go (#2128, #2615)? The one place the predicate is stated.
#
# A repo is sole-Go when its primary is `go` and it has no auxiliary
# Linux-tested language — none of `javascript`, `python` or `java`. Swift does
# not count (its tests run on their own macOS job), so a Go+Swift repo is
# sole-Go. For a sole-Go repo the gate runs every source-only check, so the
# folded CI jobs stop rendering; a mixed-Go repo renders exactly as before.
#
# render.zsh calls this once, from its own --primary and --languages, for the
# SOLE_GO / NOT_SOLE_GO block tags; branch protection (#2616) and the folded-job
# skip (#2617) call it too, rather than restating the rule.
#
# Usage:
#   is-sole-go.zsh --primary <p> --languages "<a b c>"
#
#   --primary is the repo's primary (an empty value is not `go`); --languages is
#   the space-separated detected language list, and may be "".
#
# Exit codes: 0 sole-Go; 1 not sole-Go; 2 usage error (a missing flag or an
# unknown argument). Nothing is printed on stdout.

set -euo pipefail

usage() {
	print -u2 -- "usage: is-sole-go.zsh --primary <p> --languages \"<a b c>\""
	exit 2
}

primary="" languages=""
primary_set=0 languages_set=0
while (($# > 0)); do
	case "$1" in
	--primary | --languages)
		(($# >= 2)) || { print -u2 -- "is-sole-go: $1 needs a value" && usage; }
		if [[ "$1" == --primary ]]; then
			primary="$2" primary_set=1
		else
			languages="$2" languages_set=1
		fi
		shift 2
		;;
	--help | -h) usage ;;
	*) print -u2 -- "is-sole-go: unknown argument: $1" && usage ;;
	esac
done
((primary_set)) || { print -u2 -- "is-sole-go: --primary is required" && usage; }
((languages_set)) || { print -u2 -- "is-sole-go: --languages is required" && usage; }

[[ "$primary" == go ]] || exit 1
typeset -a langs=(${=languages})
typeset l
for l in javascript python java; do
	((${langs[(Ie)$l]})) && exit 1
done
exit 0
