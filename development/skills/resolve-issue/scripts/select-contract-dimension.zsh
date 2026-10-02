#!/usr/bin/env zsh
# select-contract-dimension.zsh — does a claude-plugin DELTA round need the
# `contract` dimension (claude-plugin-contract-integrity)? (#2009, epic #2012)
#
# Why: contract-integrity is the panel's most expensive reviewer, and from round
# 3 on it finds almost nothing, because most fix passes edit bats tests and local
# prose and rarely add, remove or rename a cross-artifact surface. This selector
# decides, from the delta alone, whether the fix pass touched such a surface. It
# is PURE — it reads only its two input files, with no git, clock, network or
# model — so the decision is reproducible and bats-testable. `review-dispatch.zsh
# plan` builds the inputs and turns a `skip` into `skippable_dimensions:
# ["contract"]`; whether the panel then honours it (full rounds and a carried
# `contract` entry always bring the dimension back) is the review skill's Step 1
# table and *Carry-driven dispatch (#2008)*, not this script.
#
# Usage:
#   select-contract-dimension.zsh --files PATH --patch PATH
#
#   --files  a JSON array of {status, path} objects, status one of A C D M R T
#            (the first letter of `git diff --name-status -M`; a rename or copy
#            names its NEW path).
#   --patch  one `-M` patch over the same delta: every agent or SKILL.md path
#            (`*/agents/*.md`, `*/skills/*/SKILL.md`) with whole-file context,
#            every other path `-U0`.
#
# Output: one JSON object on stdout, exit 0:
#   {"contract": "run" | "skip", "triggers": [...]}
# `contract` is "run" exactly when `triggers` is non-empty. The triggers are a
# fixed vocabulary, listed in this order, each at most once:
#   architecture            ARCHITECTURE.md is in --files
#   claude-plugin-manifest  a path has a `.claude-plugin/` segment
#   frontmatter             in a shipped agent or SKILL.md, a changed line lies
#                           on or between the line-1 `---` and the closing `---`
#                           (old side from context + `-`, new side from context
#                           + `+`), whatever the key
#   script-interface        in a shipped *.zsh / *.sh / *.bash, a changed line is
#                           a case-arm label, or contains getopts, zparseopts or
#                           (case-insensitively) usage — internal case statements
#                           over-fire, which is accepted
#   path-change             a shipped file has status A, D, R or C (no citation
#                           lookup: a content edit to a cited file does not fire)
#   heading                 in a shipped .md, a removed line `#{1,6} …`
#   undecidable             the inputs cannot be judged (fail-closed): see the
#                           grounds at `_undecidable` below
# A SHIPPED file is a path whose first segment is not `tests`. A changed line is
# a `+`/`-` line of a hunk, never a `+++`/`---` file header.
#
# A missing or unreadable input FILE is the `undecidable` trigger (exit 0, run),
# because a caller that built no input has decided nothing. An omitted FLAG, a
# flag with no value, an unknown flag or a stray argument is a usage error.
#
# Exit codes: 0 a decision on stdout · 2 usage error · 1 internal (jq/awk failed).

emulate -L zsh
setopt nounset pipefail

local usage="usage: select-contract-dimension.zsh --files PATH --patch PATH"
die_usage() { print -u2 -- "select-contract-dimension: $1"; print -u2 -- "$usage"; exit 2 }

local files="" patch="" files_given=0 patch_given=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --files) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die_usage "--files requires a value"
           files="$2"; files_given=1; shift 2 ;;
  --patch) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die_usage "--patch requires a value"
           patch="$2"; patch_given=1; shift 2 ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) die_usage "unknown flag: $1" ;;
  *) die_usage "unexpected argument: $1" ;;
  esac
done
(( files_given )) || die_usage "--files is required"
(( patch_given )) || die_usage "--patch is required"

command -v jq >/dev/null 2>&1 || { print -u2 -- "select-contract-dimension: jq not found on PATH"; exit 1 }

_emit_undecidable() {
  print -u2 -- "select-contract-dimension: undecidable — $1"
  print -r -- '{"contract":"run","triggers":["undecidable"]}'
  exit 0
}

# Ground 1: an input file that is missing, unreadable or a directory.
[[ -f "$files" && -r "$files" ]] || _emit_undecidable "--files is missing or unreadable: $files"
[[ -f "$patch" && -r "$patch" ]] || _emit_undecidable "--patch is missing or unreadable: $patch"

# Ground 2: --files is not a JSON array of {status, path} with a known status.
# `-s` so concatenated documents are refused rather than judged one by one.
jq -e -s 'length == 1 and (.[0] | type == "array" and all(.[];
    type == "object"
    and (.status | type == "string" and IN("A", "C", "D", "M", "R", "T"))
    and (.path | type == "string" and length > 0)))' -- "$files" >/dev/null 2>&1 \
  || _emit_undecidable "--files is not a JSON array of {status, path} objects with status A/C/D/M/R/T"

# One TSV record per `diff --git` section of the patch:
#   path  binary  mode_change  nhunks  whole  fm_change  fm_unclosed  iface  heading
# `path` is the new-side path (the old one for a deletion). `whole` is 1 when the
# section is exactly one hunk whose old and new ranges each start at line 1 or
# are `0,0`. The frontmatter columns are computed from that one hunk and are only
# meaningful when `whole` is 1, which is the only case the judge below reads
# them in. Headers (`---`, `+++`, `rename to`, `old mode`, …) are read only
# BEFORE a section's first `@@`: inside a hunk a removed line whose text begins
# `-- ` prints as `--- …` too.
local sections
sections=$(awk '
  function hdr_path(p, pre) {
    sub(/\t$/, "", p)
    if (substr(p, 1, 1) == "\"") { p = substr(p, 2); sub(/"$/, "", p) }
    if (substr(p, 1, length(pre)) == pre) p = substr(p, length(pre) + 1)
    return p
  }
  function is_arm(s,   t, a, core, q1, q2) {
    sq = sprintf("%c", 39)
    t = s
    sub(/^[ \t]+/, "", t)
    split(t, a, /[ \t]/)
    t = a[1]
    if (t !~ /\)$/) return 0
    core = substr(t, 1, length(t) - 1)
    if (substr(core, 1, 1) == "(") core = substr(core, 2)
    if (core == "" || core ~ /[()=]/) return 0
    q1 = gsub(/"/, "\"", core); q2 = gsub(sq, sq, core)
    return (q1 % 2 == 0 && q2 % 2 == 0)
  }
  function side_fm(side,   i, n, close_at, changed) {
    # side "o": context + removed lines; side "n": context + added lines
    n = 0
    for (i = 1; i <= nb; i++) {
      if (bt[i] == " " || bt[i] == (side == "o" ? "-" : "+")) {
        n++; sl[n] = bs[i]; sc[n] = (bt[i] != " ")
      }
    }
    if (n == 0) return
    if (fence(sl[1]) == 0) return
    close_at = 0
    for (i = 2; i <= n; i++) if (fence(sl[i])) { close_at = i; break }
    if (close_at == 0) { unclosed = 1; return }
    for (i = 1; i <= close_at; i++) if (sc[i]) { fm = 1; return }
  }
  function fence(s) { sub(/[ \t\r]+$/, "", s); return s == "---" }
  function flush() {
    if (!insec) return
    fm = 0; unclosed = 0
    if (nhunks == 1) { side_fm("o"); side_fm("n") }
    printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", path, binary, mode, nhunks, whole, fm, unclosed, iface, heading
  }
  /^diff --git / {
    flush()
    insec = 1; inhunk = 0; nhunks = 0; binary = 0; mode = 0; whole = 0
    iface = 0; heading = 0; nb = 0; oldp = ""
    rest = substr($0, 12)
    path = substr(rest, length(rest) - ((length(rest) - 5) / 2 + 2) + 1)
    path = hdr_path(path, "b/")
    next
  }
  !insec { next }
  !inhunk && /^--- / { oldp = hdr_path(substr($0, 5), "a/"); next }
  !inhunk && /^\+\+\+ / {
    p = hdr_path(substr($0, 5), "b/")
    path = (p == "/dev/null") ? oldp : p
    next
  }
  !inhunk && /^(rename|copy) to / { path = hdr_path(substr($0, index($0, " to ") + 4), ""); next }
  !inhunk && /^old mode / { mode = 1; next }
  !inhunk && /^Binary files / { binary = 1; next }
  /^@@ / {
    inhunk = 1; nhunks++
    if (nhunks == 1 && match($0, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/)) {
      h = substr($0, 4, RLENGTH - 6)
      split(h, sd, " ")
      k = split(substr(sd[1], 2), o, ","); os = o[1] + 0; oc = (k > 1) ? o[2] + 0 : 1
      k = split(substr(sd[2], 2), w, ","); ns = w[1] + 0; nc = (k > 1) ? w[2] + 0 : 1
      whole = ((os == 1 || (os == 0 && oc == 0)) && (ns == 1 || (ns == 0 && nc == 0)))
    } else whole = 0
    next
  }
  inhunk {
    c = substr($0, 1, 1)
    if (c == "\\") next
    s = substr($0, 2)
    if (c == "+" || c == "-") {
      if (is_arm(s) || index(s, "getopts") || index(s, "zparseopts") || index(tolower(s), "usage")) iface = 1
      if (c == "-" && match(s, /^#+ /) && RLENGTH - 1 <= 6) heading = 1
    }
    if (nhunks == 1 && (c == " " || c == "+" || c == "-")) { nb++; bt[nb] = c; bs[nb] = s }
    next
  }
  END { flush() }
' < "$patch") || { print -u2 -- "select-contract-dimension: could not parse --patch: $patch"; exit 1 }

# The judge. Every ground of `undecidable` beyond the two above is here:
#   - a `Binary files … differ` line for a shipped file;
#   - a shipped file with status T;
#   - a shipped M file with no `diff --git` section (list and patch disagree);
#   - a mode-only change (old/new mode, no content hunk) on a shipped script,
#     agent or SKILL.md;
#   - a shipped agent or SKILL.md with an opening `---` on line 1 but no
#     closing `---` on that side;
#   - a shipped agent or SKILL.md section with a content hunk but no whole-file
#     context, so the fences cannot be located.
jq -nc --slurpfile f "$files" --arg secs "$sections" '
  def shipped: (split("/")[0]) != "tests";
  def script: test("\\.(zsh|sh|bash)$");
  def agent_or_skill: test("(^|/)agents/[^/]+\\.md$") or test("(^|/)skills/[^/]+/SKILL\\.md$");
  def md: test("\\.md$");
  $f[0] as $files
  | [ $secs | split("\n")[] | select(length > 0) | split("\t")
      | {path: .[0], binary: (.[1] == "1"), mode: (.[2] == "1"), nhunks: (.[3] | tonumber),
         whole: (.[4] == "1"), fm: (.[5] == "1"), unclosed: (.[6] == "1"),
         iface: (.[7] == "1"), heading: (.[8] == "1")} ] as $s
  | ($s | map(select(.path | shipped))) as $ss
  | ($s | map(.path)) as $sec_paths
  | [
      (if any($files[]; .path == "ARCHITECTURE.md") then "architecture" else empty end),
      (if any($files[]; .path | test("(^|/)\\.claude-plugin/")) then "claude-plugin-manifest" else empty end),
      (if any($ss[]; (.path | agent_or_skill) and .whole and .fm) then "frontmatter" else empty end),
      (if any($ss[]; (.path | script) and .iface) then "script-interface" else empty end),
      (if any($files[]; (.path | shipped) and (.status | IN("A", "D", "R", "C"))) then "path-change" else empty end),
      (if any($ss[]; (.path | md) and .heading) then "heading" else empty end),
      (if any($ss[]; .binary)
          or any($files[]; (.path | shipped) and .status == "T")
          or any($files[]; (.path | shipped) and .status == "M" and (.path as $p | any($sec_paths[]; . == $p) | not))
          or any($ss[]; ((.path | script) or (.path | agent_or_skill)) and .mode and .nhunks == 0)
          or any($ss[]; (.path | agent_or_skill) and .nhunks > 0 and (.whole | not))
          or any($ss[]; (.path | agent_or_skill) and .whole and .unclosed)
        then "undecidable" else empty end)
    ] as $t
  | {contract: (if ($t | length) > 0 then "run" else "skip" end), triggers: $t}
' || { print -u2 -- "select-contract-dimension: could not judge the delta"; exit 1 }
