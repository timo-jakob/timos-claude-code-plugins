#!/usr/bin/env zsh
# untested-surface.zsh — the claude-plugin pre-review self-check (#2014).
#
# Lists the surface a story diff adds that no bats case tests and no bats needle
# pins, so the writer can close it BEFORE round 1 rather than one review round
# at a time. Advisory, never a gate: it decides nothing and writes nothing but
# stdout.
#
# Usage:
#   untested-surface.zsh --repo PATH [--base REF]
#
# The story diff runs from the merge-base of REF (default origin/main) and HEAD
# to the working tree — committed, staged and unstaged changes to tracked files,
# plus untracked files (every line of one counts as added), since the writer
# runs this before committing.
#
# Output: a JSON array of {file, kind, line, text} on stdout, sorted by file,
# then line, then kind. `file` is repo-relative, `line` the 1-based line in the
# post-change file (a prose item's: the line its sentence starts on), `text` the
# added line, trimmed (a prose item's: the whitespace-flattened sentence). One
# item per line and kind, listed when ANY of that line's surfaces of the kind is
# untested.
#
# Kinds, for an added line of a changed `*.zsh` script. A COVERING FILE is any
# tests/*.bats file that contains the script's basename — file-level: the case
# need not be proven to run the script.
#   exit       a literal `exit N`; tested when a covering file contains
#              `[ "$status" -eq N ]`. A variable exit (`exit $rc`) is skipped.
#   flag       a `case` arm with a `--foo` alternative (the argument parser);
#              tested when a covering file contains the literal `--foo`, for
#              every such alternative. A flag arm is never also a case-arm item.
#   case-arm   any other `case` arm; tested when a covering file contains every
#              literal alternative of its pattern. An alternative holding a glob
#              or `$` is not literal, so a pure-glob arm (`*)`) is skipped.
# and for an added line of a `*.md` file under a skills/ or agents/ directory:
#   rule-sentence  a sentence touching an added line that holds must, never,
#              always or required as a whole word (case-insensitive), or any
#              backtick-quoted term; pinned when some quoted string literal of
#              at least 12 characters in any tests/*.bats file is a substring of
#              the whitespace-flattened sentence. Fenced code is not prose.
#
# Exit: 0 whenever the diff is read, with or without items (`[]` included);
# 2 a usage error, the stderr message naming the offending flag; 1 no merge-base
# between REF and HEAD (nothing on stdout, stderr
# `untested-surface: no merge-base between <base> and HEAD in <repo>`), or a
# runtime failure (jq missing, a git error) named on stderr.

emulate -L zsh
setopt nounset pipefail

readonly SEP=$'\x1f'

usage() {
  print -u2 -- "untested-surface: $1"
  print -u2 -- "usage: untested-surface.zsh --repo PATH [--base REF]"
  exit 2
}

need_value() {
  (( $# >= 2 )) || usage "$1 requires a value"
  [[ "$2" != --* ]] || usage "$1 requires a value (got the flag $2)"
  [[ -n "$2" ]] || usage "$1 requires a non-empty value"
}

die() { print -u2 -- "untested-surface: $1"; exit 1 }

repo="" base="origin/main"
while (( $# > 0 )); do
  case "$1" in
  --repo) need_value "$@"; repo="$2"; shift 2 ;;
  --base) need_value "$@"; base="$2"; shift 2 ;;
  *) usage "unknown argument: $1" ;;
  esac
done
[[ -n "$repo" ]] || usage "--repo is required"
[[ -d "$repo" ]] || usage "--repo is not a directory: $repo"

command -v jq >/dev/null 2>&1 || die "jq is required"

no_merge_base() {
  print -u2 -- "untested-surface: no merge-base between $base and HEAD in $repo"
  exit 1
}
top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || no_merge_base
mb="$(git -C "$top" merge-base "$base" HEAD 2>/dev/null)" || no_merge_base
[[ -n "$mb" ]] || no_merge_base

work="$(mktemp -d "${TMPDIR:-/tmp}/untested-surface.XXXXXX")" || die "cannot create a scratch dir"
trap 'rm -rf -- "$work"' EXIT

# --- added lines: "<path>\x1f<line>" per added line; "<path>\x1fALL" per
# untracked file. Prefixes and relativity are pinned so a user's diff config
# cannot change the paths parsed here.
git -C "$top" -c core.quotepath=off diff -U0 --no-color --no-ext-diff \
    --no-renames --no-relative --src-prefix=a/ --dst-prefix=b/ "$mb" -- \
    > "$work/diff" || die "git diff failed"
awk -v sep="$SEP" '
  /^\+\+\+ / { path = substr($0, 7); if ($0 == "+++ /dev/null") path = ""; next }
  /^@@ / {
    h = $0; sub(/^@@ -[0-9,]+ \+/, "", h); sub(/[ ,].*/, "", h); n = h + 0; next
  }
  /^\+/ { if (path != "") print path sep n; n++; next }
' "$work/diff" > "$work/added" || die "could not parse the diff"
git -C "$top" -c core.quotepath=off ls-files --others --exclude-standard \
    > "$work/untracked" || die "git ls-files failed"
while IFS= read -r f; do print -r -- "$f${SEP}ALL"; done < "$work/untracked" >> "$work/added"

# --- every quoted literal of 12+ characters in tests/*.bats, flattened ------
typeset -a bats=("$top"/tests/*.bats(N))

# --- the per-file analysers --------------------------------------------------
# zsh: one row per surface — kind, line, text, then the needles a covering file
# must ALL contain, each prefixed by the separator.
read -r -d '' ZSH_AWK <<'EOF'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function code_of(s) {
  if (s ~ /^[ \t]*#/) return ""
  sub(/[ \t]#.*$/, "", s)
  return s
}
BEGIN { while ((getline l < ADDED) > 0) add[l] = 1; depth = 0 }
{
  raw = $0; c = code_of(raw); added = (ALL || (FNR in add))
  is_case = (c ~ /(^|[;( \t])case[ \t].*[ \t]in([ \t;]|$)/)
  if (!is_case && depth > 0 && added &&
      match(c, /^[ \t]*\(?[ \t]*[^() \t]+([ \t]*\|[ \t]*[^() \t]+)*[ \t]*\)/)) {
    pat = substr(c, RSTART, RLENGTH); sub(/^[ \t]*\(?/, "", pat); sub(/\)$/, "", pat)
    n = split(pat, alt, "|"); flags = ""; lits = ""; nl = 0; nf = 0
    for (i = 1; i <= n; i++) {
      a = trim(alt[i])
      if (a ~ /^".*"$/ || a ~ ("^" SQ ".*" SQ "$")) a = substr(a, 2, length(a) - 2)
      if (a == "" || a ~ /[*?\[\]$]/) continue
      if (a ~ /^--/) { flags = flags SEP a; nf++ } else { lits = lits SEP a; nl++ }
    }
    if (nf > 0) {
      m = split(substr(flags, 2), fl, SEP)
      for (j = 1; j <= m; j++) print "flag" SEP FNR SEP trim(raw) SEP fl[j]
    } else if (nl > 0) {
      print "case-arm" SEP FNR SEP trim(raw) lits
    }
  }
  if (added) {
    rest = c
    while (match(rest, /(^|[^A-Za-z0-9_])exit[ \t]+[0-9]+([^A-Za-z0-9_]|$)/)) {
      hit = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
      sub(/^.*exit[ \t]+/, "", hit); sub(/[^0-9].*$/, "", hit)
      print "exit" SEP FNR SEP trim(raw) SEP "[ \"$status\" -eq " hit " ]"
    }
  }
  if (is_case) depth++
  if (c ~ /(^|[;) \t])esac([ \t;)]|$)/ && depth > 0) depth--
}
EOF

# md: one row per rule sentence touching an added line — line, sentence.
read -r -d '' MD_AWK <<'EOF'
function flush(   i, j, ch, st) {
  if (para == "") return
  st = 1
  for (i = 1; i <= length(para); i++) {
    ch = substr(para, i, 1)
    j = i + 1
    if (ch == "." || ch == "!" || ch == "?") {
      # A sentence may end inside closing markup: **Lead.** or (see X.)
      while (j <= length(para) && index("*_`)\"'", substr(para, j, 1))) j++
    } else if (i < length(para)) continue
    if (j > length(para) || substr(para, j, 1) == " ") {
      emit(st, j - 1); st = j + 1; i = j
    }
  }
  para = ""; nseg = 0
}
function emit(s, e,   sentence, k, ln, touched, lc) {
  sentence = substr(para, s, e - s + 1)
  gsub(/[ \t]+/, " ", sentence); sub(/^ /, "", sentence); sub(/ $/, "", sentence)
  if (sentence == "") return
  ln = 0; touched = 0
  for (k = 1; k <= nseg; k++) {
    if (segend[k] < s || segstart[k] > e) continue
    if (ln == 0) ln = segline[k]
    if (ALL || (segline[k] in add)) touched = 1
  }
  if (!touched) return
  lc = tolower(sentence)
  if (lc ~ /(^|[^a-z0-9_])(must|never|always|required)([^a-z0-9_]|$)/ || sentence ~ /`[^`]+`/)
    print ln SEP sentence
}
function append(text, lineno) {
  text = trimmed(text)
  if (text == "") return
  if (para != "") para = para " "
  nseg++; segstart[nseg] = length(para) + 1; segline[nseg] = lineno
  para = para text; segend[nseg] = length(para)
}
function trimmed(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
BEGIN { while ((getline l < ADDED) > 0) add[l] = 1; fence = 0; front = 0 }
{
  s = $0
  if (FNR == 1 && s == "---") { front = 1; next }
  if (front) { if (s == "---") front = 0; next }
  if (s ~ /^[ \t]*(```|~~~)/) { flush(); fence = !fence; next }
  if (fence) next
  if (s ~ /^[ \t]*$/) { flush(); next }
  if (s ~ /^[ \t]*(#+[ \t]|[-*+][ \t]|[0-9]+\.[ \t]|>)/) {
    flush(); sub(/^[ \t]*(#+|[-*+]|[0-9]+\.|>)[ \t]*/, "", s)
  }
  append(s, FNR)
}
END { flush() }
EOF

: > "$work/rows"
typeset -A seen
b=""
while IFS="$SEP" read -r rel ln; do
  [[ -n "${seen[$rel]:-}" ]] && continue
  seen[$rel]=1
  [[ -f "$top/$rel" ]] || continue
  case "$rel" in
  *.zsh) ;;
  *.md) [[ "$rel" == (skills|agents)/* || "$rel" == */(skills|agents)/* ]] || continue ;;
  *) continue ;;
  esac
  all=0
  grep -F -x -- "$rel${SEP}ALL" "$work/added" >/dev/null && all=1
  grep -F -- "$rel${SEP}" "$work/added" | grep -v -F -x -- "$rel${SEP}ALL" \
    | awk -F"$SEP" -v p="$rel" '$1 == p { print $2 }' > "$work/lines" || true

  if [[ "$rel" == *.zsh ]]; then
    awk -v SEP="$SEP" -v SQ="'" -v ADDED="$work/lines" -v ALL="$all" "$ZSH_AWK" "$top/$rel" \
      > "$work/surfaces" || die "could not analyse $rel"
    [[ -s "$work/surfaces" ]] || continue
    : > "$work/cover"
    for b in "${bats[@]}"; do
      grep -q -F -- "${rel:t}" "$b" && print -r -- "$b" >> "$work/cover"
    done
    # a surface is tested when EVERY needle it carries is in one covering file's
    # text — the needles of an arm in the same file, as a case would hold them
    awk -v SEP="$SEP" -v p="$rel" -v COVER="$work/cover" '
      BEGIN {
        nc = 0
        while ((getline f < COVER) > 0) {
          nc++; body[nc] = ""
          while ((getline l < f) > 0) body[nc] = body[nc] l "\n"
          close(f)
        }
      }
      {
        n = split($0, fld, SEP); kind = fld[1]; ln = fld[2]; text = fld[3]
        ok = 0
        for (c = 1; c <= nc && !ok; c++) {
          all = 1
          for (i = 4; i <= n; i++) if (index(body[c], fld[i]) == 0) { all = 0; break }
          if (all) ok = 1
        }
        key = kind SEP ln
        if (!(key in out)) { out[key] = text; order[++no] = key }
        if (!ok) bad[key] = 1
      }
      END {
        for (i = 1; i <= no; i++) if (order[i] in bad) {
          split(order[i], kl, SEP); print p SEP kl[1] SEP kl[2] SEP out[order[i]]
        }
      }
    ' "$work/surfaces" >> "$work/rows" || die "could not check coverage for $rel"
  else
    awk -v SEP="$SEP" -v ADDED="$work/lines" -v ALL="$all" "$MD_AWK" "$top/$rel" \
      > "$work/sentences" || die "could not analyse $rel"
    [[ -s "$work/sentences" ]] || continue
    if [[ ! -s "$work/literals" ]] && (( ${#bats} > 0 )); then
      # quoted literals: '...' and "..." on one line, a double-quoted one
      # unescaped, flattened, kept at 12+ characters
      awk -v SQ="'" '
        BEGIN { re = SQ "[^" SQ "]*" SQ "|\"([^\"\\\\]|\\\\.)*\"" }
        {
          s = $0
          while (match(s, re)) {
            lit = substr(s, RSTART + 1, RLENGTH - 2); q = substr(s, RSTART, 1)
            s = substr(s, RSTART + RLENGTH)
            if (q == "\"") {
              out = ""; i = 1
              while (i <= length(lit)) {
                ch = substr(lit, i, 1)
                if (ch == "\\" && i < length(lit) && index("`\"$\\", substr(lit, i + 1, 1))) {
                  out = out substr(lit, i + 1, 1); i += 2
                } else { out = out ch; i++ }
              }
              lit = out
            }
            gsub(/[ \t]+/, " ", lit)
            if (length(lit) >= 12 && !(lit in seen)) { seen[lit] = 1; print lit }
          }
        }
      ' "${bats[@]}" > "$work/literals" || die "could not read the bats literals"
    fi
    awk -v SEP="$SEP" -v p="$rel" -v LITS="$work/literals" '
      BEGIN { n = 0; while ((getline l < LITS) > 0) lit[++n] = l }
      {
        i = index($0, SEP); ln = substr($0, 1, i - 1); sentence = substr($0, i + 1)
        pinned = 0
        for (k = 1; k <= n; k++) if (index(sentence, lit[k])) { pinned = 1; break }
        if (!pinned) print p SEP "rule-sentence" SEP ln SEP sentence
      }
    ' "$work/sentences" >> "$work/rows" || die "could not check pins for $rel"
  fi
done < "$work/added"

jq -R -s --arg sep "$SEP" '
  [ split("\n")[] | select(length > 0) | split($sep)
    | {file: .[0], kind: .[1], line: (.[2] | tonumber), text: (.[3:] | join($sep))} ]
  | sort_by(.file, .line, .kind)
' "$work/rows" || die "could not emit the items"
