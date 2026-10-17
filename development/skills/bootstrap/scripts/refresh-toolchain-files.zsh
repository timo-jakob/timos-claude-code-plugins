#!/usr/bin/env zsh
# Re-compose the toolchain-composed files an EXISTING repo already carries, after
# its recorded toolchain changed (#2121).
#
# The normal way to add a deferred tool is to change `.maintenance.yml`'s
# `tools.<category>` from `none` to the tool and re-run /development:bootstrap.
# The tool's own new files (sonar-project.properties, infra/sonarqube/, …) are
# missing on disk, so State D's gap-fill renders them. But the files composed
# per tool are ALREADY on disk — the quality workflow, its noop, the pre-commit
# config and SETUP.md, plus go-ci.yml on a sole-Go repo, whose Sonar job lives
# there (#2615; sole-Go is is-sole-go.zsh's verdict on the --primary and
# --languages passed after `--`, and no --languages there is not sole-Go) — and
# nothing else updates them: the drift detector compares template hashes, which a
# toolchain change never moves. This script is that update.
#
# It never overwrites a file wholesale. For each of those files it:
#   1. finds the file's BASE — the render, under every toolchain this visibility
#      allows, that is closest to the file on disk (fewest differing lines; the
#      provenance marker set aside). A pristine file matches its own toolchain
#      exactly; a customised one is still closest to the toolchain it was
#      rendered with, since a customisation is local and a toolchain change is
#      not;
#   2. three-way merges the toolchain delta into the file — `git merge-file`
#      with the file as ours, the base, and the render under the CURRENT
#      toolchain as theirs — so only the per-tool blocks the change touches move
#      and every edit outside them stays;
#   3. for SETUP.md, rewrites the bootstrap-owned DEFERRED-TOOLS-START/END block
#      to the current render's on every run: the block is set aside from all
#      three inputs before the merge, so it is never merged, then inserted after
#      the line that precedes it in the render (omitted when nothing is
#      deferred).
# A file whose closest renders tie with different content is `ambiguous`, and a
# merge with conflicts is `conflict`: both are left untouched for the
# idempotency reviewer. A file whose base already renders as the current
# toolchain is `current`. The provenance marker is kept byte-for-byte, so drift
# tracking is unchanged.
#
# Usage:
#   refresh-toolchain-files.zsh --repo <path> --visibility public|private \
#     --static-analysis sonarcloud|sonarqube|none --vulnerabilities snyk|trivy|none \
#     --code-scanning codeql|none [--dry-run] [-- <render.zsh value flags>...]
#
#   Pass the toolchain resolve-tools.zsh printed, and after `--` the same value
#   flags the run renders with (--project-name, --languages, --docker, …) —
#   never --templates, --out, --visibility or a toolchain flag, which this
#   script sets per candidate. --dry-run reports without writing.
#
# Output: one JSON object per file on stdout —
#   {"file": "<repo-relative path>", "status": "<status>", "base": "<sa>/<v>/<cs>"|null}
#   status: absent | current | refreshed | conflict | ambiguous
#   (`refreshed` under --dry-run means "would be refreshed").
#
# Exit codes: 0 every present file is current or refreshed; 3 at least one is
# `conflict` or `ambiguous` (a human decides; nothing was written to it);
# 1 a runtime error (a render failed, git or jq missing, an unwritable file);
# 2 usage error, a value outside its category's set, or a combination
# resolve-tools.zsh rejects.

set -euo pipefail

usage() {
	print -u2 -- "usage: refresh-toolchain-files.zsh --repo <path> --visibility public|private"
	print -u2 -- "       --static-analysis sonarcloud|sonarqube|none --vulnerabilities snyk|trivy|none"
	print -u2 -- "       --code-scanning codeql|none [--dry-run] [-- <render.zsh value flags>...]"
	exit 2
}

die() {
	print -u2 -- "refresh-toolchain-files: $1"
	exit 1
}

script_dir="${0:A:h}"
templates="${script_dir:h}/templates"
render="$script_dir/render.zsh"

repo="" vis="" dry_run=0
typeset -A cur
typeset -a passthrough=()
while (($# > 0)); do
	case "$1" in
	--repo | --visibility | --static-analysis | --vulnerabilities | --code-scanning)
		(($# >= 2)) || { print -u2 -- "refresh-toolchain-files: $1 needs a value" && usage; }
		case "$1" in
		--repo) repo="$2" ;;
		--visibility) vis="$2" ;;
		--static-analysis) cur[sa]="$2" ;;
		--vulnerabilities) cur[v]="$2" ;;
		--code-scanning) cur[cs]="$2" ;;
		esac
		shift 2
		;;
	--dry-run) dry_run=1 && shift ;;
	--) shift && passthrough=("$@") && break ;;
	--help | -h) usage ;;
	*) print -u2 -- "refresh-toolchain-files: unknown argument: $1" && usage ;;
	esac
done

[[ -n "$repo" ]] || { print -u2 -- "refresh-toolchain-files: --repo is required" && usage; }
[[ -d "$repo" ]] || { print -u2 -- "refresh-toolchain-files: --repo is not a directory: $repo" && usage; }
[[ "$vis" == public || "$vis" == private ]] ||
	{ print -u2 -- "refresh-toolchain-files: --visibility must be public or private" && usage; }
typeset -A allowed=(sa "sonarcloud sonarqube none" v "snyk trivy none" cs "codeql none")
typeset -A flag=(sa --static-analysis v --vulnerabilities cs --code-scanning)
typeset k
typeset -a set
for k in sa v cs; do
	set=(${=allowed[$k]})
	((${+cur[$k]})) && ((${set[(Ie)${cur[$k]}]})) ||
		{ print -u2 -- "refresh-toolchain-files: ${flag[$k]} must be one of ${allowed[$k]// / | }" && usage; }
done
[[ "$vis/${cur[sa]}" != public/sonarqube && "$vis/${cur[cs]}" != private/codeql ]] ||
	{ print -u2 -- "refresh-toolchain-files: $vis + ${cur[sa]}/${cur[cs]} is a combination resolve-tools.zsh rejects" && usage; }
for k in "${passthrough[@]}"; do
	case "$k" in
	--templates | --out | --visibility | --static-analysis | --vulnerabilities | --code-scanning)
		print -u2 -- "refresh-toolchain-files: $k is set by this script — do not pass it after --" && usage
		;;
	esac
done

command -v git >/dev/null 2>&1 || die "git is required (git merge-file)"
command -v jq >/dev/null 2>&1 || die "jq is required"

# the toolchain-composed files: repo path -> template relpath
typeset -a targets=(
	".github/workflows/quality-$vis.yml" "$vis/.github/workflows/quality-$vis.yml.tmpl"
	".github/workflows/quality-$vis-noop.yml" "$vis/.github/workflows/quality-$vis-noop.yml.tmpl"
	".pre-commit-config.yaml" "common/.pre-commit-config.yaml.tmpl"
	"SETUP.md" "common/SETUP.md.tmpl"
)
typeset i
# a sole-Go repo's Sonar job is go-ci.yml's (#2615), so that file is composed per tool too
# (a passthrough without --languages is never sole-Go: the verdict needs the list)
typeset p_primary="" p_languages=""
integer p_languages_set=0
for ((i = 1; i < ${#passthrough}; i++)); do
	case "${passthrough[i]}" in
	--primary) p_primary="${passthrough[i + 1]}" ;;
	--languages) p_languages="${passthrough[i + 1]}" && p_languages_set=1 ;;
	esac
done
sole_rc=1
if ((p_languages_set)); then
	sole_rc=0
	zsh "$script_dir/is-sole-go.zsh" --primary "$p_primary" --languages "$p_languages" || sole_rc=$?
fi
case $sole_rc in
0) targets+=(".github/workflows/go-ci.yml" "languages/go/.github/workflows/go-ci.yml.tmpl") ;;
1) ;;
*) die "is-sole-go.zsh failed (exit $sole_rc)" ;;
esac
typeset -a tmpls=()
for ((i = 2; i <= ${#targets}; i += 2)); do tmpls+=("${targets[i]}"); done

work="$(mktemp -d "${TMPDIR:-/tmp}/refresh-toolchain.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# every toolchain this visibility allows (resolve-tools.zsh step 4's rule)
typeset -a combos=()
typeset sa v cs
for sa in sonarcloud sonarqube none; do
	[[ "$vis" == public && "$sa" == sonarqube ]] && continue
	for v in snyk trivy none; do
		for cs in codeql none; do
			[[ "$vis" == private && "$cs" == codeql ]] && continue
			combos+=("$sa/$v/$cs")
		done
	done
done

render_combo() { # <sa/v/cs> -> renders into $work/<sa_v_cs>/
	local c="$1" out="$work/${1//\//_}"
	[[ -d "$out" ]] && return 0
	local -a p=("${(@s:/:)c}")
	zsh "$render" --templates "$templates" --out "$out" --visibility "$vis" \
		--static-analysis "${p[1]}" --vulnerabilities "${p[2]}" --code-scanning "${p[3]}" \
		"${passthrough[@]}" "${tmpls[@]}" >/dev/null 2>"$work/render.err" ||
		die "render.zsh failed for toolchain $c: $(<"$work/render.err")"
}

ndiff() { # <a> <b> -> number of differing lines
	diff "$1" "$2" | grep -c '^[<>]' || true
}

emit() { # <file> <status> <base or "">
	jq -nc --arg f "$1" --arg s "$2" --arg b "$3" '{file: $f, status: $s, base: (if $b == "" then null else $b end)}'
}

# The DEFERRED-TOOLS block of a rendered SETUP.md, START through END inclusive.
deferred_block() { # <file>
	awk '/<!-- --- DEFERRED-TOOLS-START --- -->/ { on = 1 } on { print } /<!-- --- DEFERRED-TOOLS-END --- -->/ { on = 0 }' "$1"
}

# <file> without its DEFERRED-TOOLS block, into <out>.
strip_deferred() { # <file> <out>
	awk '/<!-- --- DEFERRED-TOOLS-START --- -->/ { skip = 1 } !skip { print }
		/<!-- --- DEFERRED-TOOLS-END --- -->/ { skip = 0 }' "$1" >"$2"
}

# Insert <rendered>'s DEFERRED-TOOLS block into <body> (which has none), in place.
sync_deferred() { # <body> <rendered>
	local body="$1" rendered="$2" block anchor
	block="$(deferred_block "$rendered")"
	[[ -n "$block" ]] || return 0
	# the line the block follows in the render; when the file no longer has it
	# exactly once, the block goes at the end
	anchor="$(awk '/<!-- --- DEFERRED-TOOLS-START --- -->/ { print prev; exit } { prev = $0 }' "$rendered")"
	if [[ -n "$anchor" && "$(grep -cxF -- "$anchor" "$body" || true)" == 1 ]]; then
		ANCHOR="$anchor" BLOCK="$block" awk '{ print } $0 == ENVIRON["ANCHOR"] { print ENVIRON["BLOCK"] }' "$body" >"$body.new"
	else
		{ cat "$body"; print; print -r -- "$block"; } >"$body.new"
	fi
	mv "$body.new" "$body"
}

typeset c
for c in "${combos[@]}" "${cur[sa]}/${cur[v]}/${cur[cs]}"; do render_combo "$c"; done
current_dir="$work/${cur[sa]}_${cur[v]}_${cur[cs]}"

needs_human=0
typeset target tmpl rel on_disk body marker_at best_d d base_combo state new
typeset -a marker_lines best
for ((i = 1; i <= ${#targets}; i += 2)); do
	target="${targets[i]}" tmpl="${targets[i + 1]}"
	rel="${tmpl%.tmpl}"
	on_disk="$repo/$target"
	if [[ ! -f "$on_disk" ]]; then
		emit "$target" absent ""
		continue
	fi
	new="$current_dir/$rel"

	# set the provenance marker aside: its two lines, wherever they sit in the
	# first ten (after a shebang, when there is one)
	body="$work/body"
	marker_at="$(awk 'NR <= 10 && index($0, "# claude-bootstrap: rendered from ") == 1 { print NR; exit }' "$on_disk")"
	marker_lines=()
	if [[ -n "$marker_at" ]]; then
		marker_lines=("${(@f)$(sed -n "${marker_at},$((marker_at + 1))p" "$on_disk")}")
		sed "${marker_at},$((marker_at + 1))d" "$on_disk" >"$body"
	else
		cp "$on_disk" "$body"
	fi

	# the base: the closest render; a tie between different contents is ambiguous
	best_d=-1 best=()
	for c in "${combos[@]}"; do
		d="$(ndiff "$body" "$work/${c//\//_}/$rel")"
		if ((best_d < 0 || d < best_d)); then
			best_d=$d best=("$c")
		elif ((d == best_d)); then
			best+=("$c")
		fi
	done
	base_combo="${best[1]}"
	for c in "${best[@]:1}"; do
		if ! cmp -s "$work/${base_combo//\//_}/$rel" "$work/${c//\//_}/$rel"; then
			emit "$target" ambiguous ""
			needs_human=1
			continue 2
		fi
	done

	# SETUP.md's bootstrap-owned block is set aside from all three inputs, so it
	# is never merged — sync_deferred puts the render's back afterwards
	cp "$work/${base_combo//\//_}/$rel" "$work/base"
	cp "$new" "$work/theirs"
	cp "$body" "$work/merged"
	if [[ "$target" == SETUP.md ]]; then
		strip_deferred "$body" "$work/merged"
		strip_deferred "$new" "$work/theirs"
		strip_deferred "$work/${base_combo//\//_}/$rel" "$work/base"
	fi
	if ! git merge-file --quiet "$work/merged" "$work/base" "$work/theirs" 2>/dev/null; then
		emit "$target" conflict "$base_combo"
		needs_human=1
		continue
	fi
	cp "$work/merged" "$body.merged"
	[[ "$target" != SETUP.md ]] || sync_deferred "$body.merged" "$new"
	state=current
	cmp -s "$body.merged" "$body" || state=refreshed

	if [[ "$state" == refreshed ]] && ((!dry_run)); then
		# put the marker back where it was, byte for byte, and write through the
		# file so its mode and inode stay
		if ((${#marker_lines})); then
			awk -v at="$marker_at" -v m1="${marker_lines[1]}" -v m2="${marker_lines[2]:-}" \
				'NR == at { print m1; print m2 } { print } END { if (NR < at) { print m1; print m2 } }' \
				"$body.merged" >"$work/final"
		else
			cp "$body.merged" "$work/final"
		fi
		cat "$work/final" >"$on_disk" || die "could not write $on_disk"
	fi
	emit "$target" "$state" "$base_combo"
done

((needs_human)) && exit 3
exit 0
