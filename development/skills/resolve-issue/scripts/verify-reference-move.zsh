#!/usr/bin/env zsh
# verify-reference-move.zsh — prove the review-loop carve-out (#1503) is
# byte-preserving.
#
# Why: `resolve-issue/SKILL.md` was ~3 900 lines, of which ~2 250 described
# branches a given run never takes, loaded on every run of every repo type. The
# fix is a MOVE into on-demand `reference/*.md`, not a rewrite — and a move is
# the one restructuring a reviewer can check mechanically instead of re-reading
# as new prose. This script is that check.
#
# What it asserts, per moved chunk: the bytes between the chunk's
# `<!-- moved: NAME -->` / `<!-- /moved: NAME -->` sentinels in the reference
# file are IDENTICAL to the lines the chunk was carved from in the pre-move
# SKILL.md at `--base` (default: the pinned pre-move commit). On a mismatch it
# prints the
# first differing line, with both sides, and exits 1.
#
# WHAT IT DOES NOT PROVE, stated because the header used to overclaim: this is a
# per-chunk check. For each DECLARED chunk it proves the moved bytes are
# unchanged. It does NOT prove conservation — text deleted from the pre-move
# SKILL.md that landed in no reference file, or landed but was never added to the
# manifest, is invisible to every path here. Read the claim as "each declared
# chunk moved verbatim", never as "nothing was lost". (Conservation is tracked
# separately; see #1548.)
#
# Normalisation, stated so the claim is honest: leading and trailing BLANK or
# WHITESPACE-ONLY lines are stripped from BOTH sides before comparison (they are
# section separators, not content). Nothing else is normalised — no whitespace
# collapsing, no case folding, no reflowing.
#
# The source ranges are pinned by CONTENT anchors, never by line number (#1189):
# each is `first line` .. `last line`, both matched in full against the pre-move
# file. A moved chunk whose first or last line was edited fails loudly here
# rather than silently re-anchoring onto neighbouring text.
#
# Usage:
#   verify-reference-move.zsh [--base <git-ref>] [--repo <dir>] [--quiet]
#
# `--base` defaults to the PINNED pre-move commit, never to a moving ref: once
# #1503 merges, `origin/main` holds the POST-move conductor and contains none of
# the seven chunks, so an `origin/main` default would fail its own documented
# invocation forever and read as the very defect this script disproves.
#
# Exit codes:
#   0  every chunk is byte-identical
#   1  at least one chunk differs, or an input could not be read
#   2  usage error

emulate -L zsh
# AFTER emulate, never before: `emulate` resets the emulation-sensitive options
# to their zsh defaults, and UNSET is one of them (default ON), so a `set -u`
# placed above this line would be silently switched back off — leaving the
# script running without the unset-parameter net it declares. Note that the `-L`
# above DOES set `local_options` (and `local_traps`/`local_patterns`) — it is the
# local-options flag. Both are inert here, because a script's top level never
# returns from a function, and harmless if this file is ever sourced from inside
# one; they are not what the ordering rule above is about.
setopt no_unset pipefail

# The pre-move conductor. Pinned, and single-sourced here — the bats gate reads
# this value out of the script rather than restating it.
typeset -r PRE_MOVE_DEFAULT=a45c6b1c1e38e1c56614be6cb9282d83072969e1

typeset base="$PRE_MOVE_DEFAULT"
typeset repo=""
typeset quiet=0

while (( $# )); do
  case "$1" in
    # Both flags reject an EMPTY value, not merely a missing one. An empty
    # `--repo` used to fall through to the script-relative default and verify
    # the real tree while the caller believed it verified the one it named; an
    # empty `--base` made `git show ":<path>"` read the INDEX — git's staged-blob
    # syntax — and report success against whatever happened to be staged.
    --base)
      shift
      [[ ${1-} == ?* ]] || { print -u2 -- "verify-reference-move: --base needs a non-empty value"; exit 2 }
      base="$1" ;;
    --repo)
      shift
      [[ ${1-} == ?* ]] || { print -u2 -- "verify-reference-move: --repo needs a non-empty value"; exit 2 }
      repo="$1" ;;
    --quiet) quiet=1 ;;
    -h|--help)
      print -r -- "usage: verify-reference-move.zsh [--base <git-ref>] [--repo <dir>] [--quiet]"
      exit 0 ;;
    *) print -u2 -- "verify-reference-move: unknown argument: $1"; exit 2 ;;
  esac
  shift
done

if [[ -z "$repo" ]]; then
  repo="${0:A:h}/../../../.."
fi
repo="${repo:A}"
[[ -d "$repo" ]] || { print -u2 -- "verify-reference-move: not a directory: $repo"; exit 2 }

typeset SKILL_REL="development/skills/resolve-issue/SKILL.md"
typeset REF_DIR="$repo/development/skills/resolve-issue/reference"

# Resolve the base to a commit before reading through it, so a ref that is not a
# commit (or an accidental index/tree spelling) is a named failure rather than a
# silent read of something else.
if ! git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
  print -u2 -- "verify-reference-move: '$base' does not resolve to a commit in $repo — is it fetched?"
  exit 1
fi

typeset pre
if ! pre=$(git -C "$repo" show "${base}:${SKILL_REL}" 2>/dev/null); then
  print -u2 -- "verify-reference-move: could not read ${base}:${SKILL_REL} — is '$base' fetched?"
  exit 1
fi

# --- the manifest ----------------------------------------------------------
# One row per moved chunk: NAME<TAB>REF_FILE<TAB>FIRST_LINE<TAB>LAST_LINE
# FIRST_LINE / LAST_LINE are matched in full (fixed-string, whole line) against
# the pre-move SKILL.md. Keep this list in sync with the reference files'
# sentinels — a chunk present in one and not the other is reported below.
typeset -a MANIFEST
MANIFEST=(
"interactive-remediation	interactive.md	Applies **only** with a human present, and only to a **shape (i)**	  what the gate exists to prevent.
"
"round-protocol	review-loop.md	**The round boundary is concurrent — one minted tree, two readers (#1497).**	   is how the two statements of it came to disagree once already.
"
"residue-branch	residue.md	Runs **only** on \`CONVERGED_WITH_RESIDUE\` (exit 14). The loop has already	  them, and do not read the story's own work as unstartable.
"
"suggestion-promotion	promotion.md	Low suggestions never block, so every one the panel raises is **waived** the	   exactly the history it exists to attest.
"
"escalation-head	escalation.md	A bad escalation costs a human an afternoon; a good one costs two minutes. On	tell the human the opposite of what happened.
"
"interactive-extension	interactive.md	**Interactive extension (human present, \`BUDGET_EXHAUSTED\` /	   later with \`/development:resolve-issue <N>\`.
"
"escalation-terminal	escalation.md	If the interactive extension ended in \`CONVERGED\`, skip the terminal below,	   the next run can converge. No PR exists until it does.
"
)

# Extract the inclusive range [first .. last] from a file's text, by full-line
# match. Prints nothing and returns non-zero when either anchor is missing or
# the pair is out of order.
# A HERE-STRING, not `print -r -- "$text" | awk`: awk `exit`s the moment it sees
# the closing anchor, which SIGPIPEs the feeding `print`, and under `pipefail`
# that makes the whole pipeline non-zero — reported as "could not locate the
# source range" for every chunk that ends early in the file, while the extraction
# in fact succeeded. (It was invisible until the `emulate` ordering above was
# fixed, because `emulate` had been silently switching `pipefail` back off.)
extract_range() {
  local text="$1" first="$2" last="$3"
  awk -v f="$first" -v l="$last" '
    !started && $0 == f { started = 1 }
    started            { buf = buf $0 "\n" }
    started && $0 == l { printf "%s", buf; found = 1; exit }
    END { if (!found) exit 3 }
  ' <<< "$text"
}

# Extract the body between the sentinels of one chunk in a reference file.
extract_chunk() {
  local file="$1" name="$2"
  awk -v n="$name" '
    $0 == "<!-- moved: " n " -->"  { inside = 1; next }
    $0 == "<!-- /moved: " n " -->" { inside = 0; found = 1; exit }
    inside                         { print }
    END { if (!found) exit 3 }
  ' "$file"
}

# Strip leading and trailing blank lines.
strip_blanks() {
  awk '
    { line[NR] = $0 }
    END {
      s = 1; e = NR
      while (s <= e && line[s] ~ /^[[:space:]]*$/) s++
      while (e >= s && line[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print line[i]
    }
  '
}

typeset -i chunk_failures=0 sweep_failures=0 verified=0
typeset row name ref_name first last ref_file src_raw src dst
typeset -a a b

for row in "${MANIFEST[@]}"; do
  row="${row%$'\n'}"
  name="${row%%$'\t'*}";        row="${row#*$'\t'}"
  ref_name="${row%%$'\t'*}";    row="${row#*$'\t'}"
  first="${row%%$'\t'*}"
  last="${row#*$'\t'}"

  ref_file="$REF_DIR/$ref_name"
  if [[ ! -f "$ref_file" ]]; then
    print -u2 -- "FAIL $name: reference file not found: $ref_file"
    (( chunk_failures++ )); continue
  fi

  if ! src_raw=$(extract_range "$pre" "$first" "$last"); then
    print -u2 -- "FAIL $name: could not locate the source range in ${base}:${SKILL_REL}"
    print -u2 -- "  first anchor: $first"
    print -u2 -- "  last  anchor: $last"
    (( chunk_failures++ )); continue
  fi
  if ! dst=$(extract_chunk "$ref_file" "$name"); then
    print -u2 -- "FAIL $name: no <!-- moved: $name --> block in $ref_name"
    (( chunk_failures++ )); continue
  fi

  src=$(print -r -- "$src_raw" | strip_blanks)
  dst=$(print -r -- "$dst" | strip_blanks)

  # An empty-vs-empty comparison would pass and be counted as verified — a gate
  # whose whole job is to notice unmoved text signing off on a chunk containing
  # nothing. Reachable without any awk failure (anchors that both match a blank
  # line, against adjacent sentinels), so refuse it outright.
  if [[ -z "$src" || -z "$dst" ]]; then
    (( chunk_failures++ ))
    print -u2 -- "FAIL $name: empty chunk after normalisation (source ${#src} bytes, moved ${#dst} bytes)"
    continue
  fi
  if [[ "$src" == "$dst" ]]; then
    (( verified++ ))
    (( quiet )) || print -r -- "ok   $name — $(print -r -- "$src" | wc -l | tr -d ' ') lines byte-identical → reference/$ref_name"
    continue
  fi

  (( chunk_failures++ ))
  print -u2 -- "FAIL $name: reference/$ref_name differs from ${base}:${SKILL_REL}"
  # First differing line, with both sides.
  a=("${(@f)src}"); b=("${(@f)dst}")
  typeset -i i n
  n=$(( ${#a} > ${#b} ? ${#a} : ${#b} ))
  for (( i = 1; i <= n; i++ )); do
    if [[ "${a[$i]-$'\0MISSING'}" != "${b[$i]-$'\0MISSING'}" ]]; then
      print -u2 -- "  first difference at chunk line $i:"
      print -u2 -- "    ${base}: ${a[$i]-<end of chunk>}"
      print -u2 -- "    moved  : ${b[$i]-<end of chunk>}"
      break
    fi
  done
  print -u2 -- "  (${#a} source lines vs ${#b} moved lines)"
done

# Every sentinel present in the reference files must appear in the manifest —
# otherwise a chunk could be added to a reference file and never verified.
#
# The name pattern is `.+`, not `[a-z-]+`: extract_chunk matches ANY name, so a
# chunk called `escalation-1503` or `round_protocol` would extract and compare
# fine while this sweep skipped the line entirely, leaving it unverified with the
# script still exiting 0. And stderr is NOT discarded — a grep that fails
# outright must be distinguishable from one that found nothing.
typeset -a sentinels stray dupes
sentinels=("${(@f)$(grep -rhoE '^<!-- moved: .+ -->$' "$REF_DIR" | sed -E 's/^<!-- moved: (.*) -->$/\1/' | sort)}")
sentinels=(${sentinels:#})
# Duplicates are a failure, not something to dedupe away: extract_chunk exits at
# the FIRST matching close, so a chunk copy-pasted into a second reference file
# has an unverified twin that can drift freely.
dupes=("${(@f)$(print -rl -- "${sentinels[@]}" | sort | uniq -d)}")
dupes=(${dupes:#})
typeset d
for d in "${dupes[@]}"; do
  print -u2 -- "FAIL: chunk '$d' is declared by more than one <!-- moved: --> sentinel; only the first is verified"
  (( sweep_failures++ ))
done
stray=("${(@f)$(print -rl -- "${sentinels[@]}" | sort -u)}")
stray=(${stray:#})
typeset s known
for s in "${stray[@]}"; do
  [[ -n "$s" ]] || continue
  known=0
  for row in "${MANIFEST[@]}"; do
    [[ "${row%%$'\t'*}" == "$s" ]] && { known=1; break }
  done
  (( known )) || { print -u2 -- "FAIL: reference/ declares chunk '$s' that this script does not verify"; (( sweep_failures++ )) }
done

# An EMPTIED MANIFEST (a bad merge, a botched edit to the multi-line array
# literal) would otherwise leave every counter at 0 and print "all 0 declared
# chunks are byte-identical" at exit 0 — a gate reporting success having verified
# nothing, which the bats caller's `status -eq 0` would accept.
#
# Be precise about when that is actually reachable, because an earlier wording
# here was wrong: against the REAL reference tree the stray-sentinel sweep above
# already fails first, finding seven sentinels no manifest row declares. This
# guard is the second net for the state where BOTH were lost together — an
# emptied manifest AND a reference tree carrying no sentinels — which is the only
# one that reaches the summary line. It also fires only at exactly zero rows: a
# PARTIALLY truncated manifest never reaches it, and is caught by the sweep.
if (( ${#MANIFEST} == 0 )); then
  print -u2 -- "verify-reference-move: the manifest is empty — there is nothing to verify"
  exit 1
fi

# The real per-chunk invariant: every declared row either compared byte-identical
# or was counted as a failure. `verified` is incremented ONLY on the identical
# branch, so a row that fell out of the loop by some path nobody anticipated is
# caught here rather than held by inspection.
if (( verified + chunk_failures != ${#MANIFEST} )); then
  print -u2 -- "verify-reference-move: ${#MANIFEST} chunk(s) declared but $verified verified + $chunk_failures failed — a row was neither"
  exit 1
fi

# Reported separately, because they are different defects and the counts do not
# share a denominator: a sentinel problem is not "a declared chunk did not move".
if (( chunk_failures )); then
  print -u2 -- ""
  print -u2 -- "$chunk_failures of ${#MANIFEST} declared chunk(s) did not move verbatim."
fi
if (( sweep_failures )); then
  print -u2 -- "$sweep_failures sentinel problem(s) in reference/ (undeclared or duplicated)."
fi
if (( chunk_failures || sweep_failures )); then
  exit 1
fi

(( quiet )) || print -r -- ""
(( quiet )) || print -r -- "all $verified declared chunks are byte-identical to ${base}:${SKILL_REL}"
exit 0
