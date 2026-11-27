#!/usr/bin/env zsh
# Does a target architecture keep to `target-architecture/v1` (#3353)?
#
#   validate-target-architecture.zsh <target-architecture.md>
#
# The contract is ARCHITECTURE.md, *Target architecture contract
# (`target-architecture/v1`)*. This script is its single-file check: it reads
# one file and judges it alone, so it cannot see an active clause reworded in
# place, a clause deleted, an id renumbered or reused, or a retired clause named
# only by the change that introduced it, which only the file's history would
# show.
#
# Every violation is reported, not only the first: one stderr line each,
#   target-architecture: <rule>: <detail>
# where <rule> is one of schema, bad-id-shape, duplicate-id, statement-and-ref,
# neither-statement-nor-ref, retired-unnamed, unresolved-affects, ref-missing,
# bad-date, stale-prose.
#
# The repo is the git work tree holding the file, or the current directory
# outside git. A `ref` path must be the repo's own file: `resolve-product-doc.zsh`
# (beside this script) must answer `own`, so a path found only in a linked
# submodule is missing. The prose hash is the refine-issue skill's
# `story-spec-prose-hash.zsh`, the persona contract's recipe.
#
# Exit codes:
#   0 valid      (stdout: `target-architecture: valid`)
#   1 invalid    (stderr: one line per violation)
#   2 usage error, an unreadable file, or a check that cannot complete (jq or
#     a sibling script missing, a lookup that fails internally) — none of which
#     is a verdict on the file

emulate -L zsh
setopt extended_glob
set -uo pipefail

local me="${0:t}"
local here="${0:A:h}"

usage() {
  print -r -- "usage: $me <target-architecture.md>" >&2
  exit 2
}

local file=""
local -i have_file=0
while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      print -r -- "usage: $me <target-architecture.md>"
      exit 0 ;;
    --) shift
        (( $# == 1 && have_file == 0 )) || usage
        file="$1"; have_file=1; shift ;;
    -*) print -r -- "$me: unknown flag: $1" >&2; usage ;;
    *)
      (( have_file == 0 )) || { print -r -- "$me: more than one file given" >&2; usage; }
      file="$1"; have_file=1; shift ;;
  esac
done
(( have_file == 1 )) && [[ -n "$file" ]] || { print -r -- "$me: a target-architecture file is required" >&2; usage; }
[[ -f "$file" && -r "$file" ]] || { print -r -- "$me: cannot read: $file" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { print -r -- "$me: jq is not on PATH" >&2; exit 2; }
local hasher="${here:h:h}/skills/refine-issue/scripts/story-spec-prose-hash.zsh"
local lookup="$here/resolve-product-doc.zsh"
[[ -r "$hasher" && -r "$lookup" ]] || { print -r -- "$me: a sibling script is missing: $hasher or $lookup" >&2; exit 2; }

file="${file:A}"

local root=""
if command -v git >/dev/null 2>&1 && root="$(git -C "${file:h}" rev-parse --show-toplevel 2>/dev/null)" \
   && [[ -n "$root" ]]; then
  root="${root:A}"
else
  root="${PWD:A}"
fi

local -a violations=()
# flag <rule> <detail> — one violation; a newline or tab in the detail is
# flattened so each violation stays one line. The jq reading below flattens a
# newline itself, since its output is split into violations by line.
flag() {
  local detail="${2//$'\r'/}"
  detail="${detail//$'\n'/ }"
  detail="${detail//$'\t'/ }"
  violations+=( "target-architecture: $1: $detail" )
}

# --- the layout: sentinels and the machine block ----------------------------

local -a lines
lines=( "${(@f)$(tr -d '\r' < "$file")}" )

local -i i n=${#lines} start=0 end=0 starts=0 ends=0
local open_s='<!-- target-architecture:prose:start -->' close_s='<!-- target-architecture:prose:end -->'
for (( i = 1; i <= n; i++ )); do
  case "${lines[i]%%[[:space:]]#}" in
    "$open_s")  (( starts++ )); (( start == 0 )) && start=i ;;
    "$close_s") (( ends++ ));   (( end == 0 )) && end=i ;;
  esac
done

local -i layout_ok=1
if (( starts != 1 || ends != 1 )); then
  flag schema "expected one $open_s and one $close_s line, found $starts and $ends"
  layout_ok=0
elif (( start > end )); then
  flag schema "$close_s comes before $open_s"
  layout_ok=0
fi

# The machine block: the first fenced `json` object after the prose, inside a
# <details> element.
local block="" line
local -i details_open=0 details_close=0 fence_open=0 fence_close=0
if (( layout_ok )); then
  for (( i = end + 1; i <= n; i++ )); do
    line="${lines[i]%%[[:space:]]#}"
    line="${line##[[:space:]]#}"
    if (( fence_open == 0 )); then
      [[ "$line" == '<details>'* ]] && details_open=1
      [[ "$line" == '```json' ]] && fence_open=i
    elif (( fence_close == 0 )); then
      [[ "$line" == '```' ]] && fence_close=i
    else
      [[ "$line" == '</details>'* ]] && { details_close=1; break; }
    fi
  done
  if (( fence_open == 0 || fence_close == 0 )); then
    flag schema "no fenced json block follows the prose"
  else
    (( details_open && details_close )) \
      || flag schema "the json block is not inside a <details> element after the prose"
    block="$(print -rl -- "${(@)lines[fence_open+1,fence_close-1]}")"
  fi
fi

local -i block_ok=0
if (( fence_open && fence_close )); then
  if print -r -- "$block" | jq -e 'type == "object"' >/dev/null 2>&1; then
    block_ok=1
  else
    flag schema "the json block is not one valid JSON object"
  fi
fi

# --- the rules a JSON reading decides ---------------------------------------

if (( block_ok )); then
  local judged
  judged="$(print -r -- "$block" | jq -r '
    def arr($k): (.[$k] // []) | if type == "array" then . else [] end;
    def objs($k): [arr($k)[] | select(type == "object")];
    def str: type == "string" and test("\\S");
    def show: if type == "string" then . else tojson end;
    def leap($y): ($y % 4 == 0 and $y % 100 != 0) or ($y % 400 == 0);
    def days($y; $m): if $m == 2 then (if leap($y) then 29 else 28 end)
                      elif ($m | IN(4, 6, 9, 11)) then 30 else 31 end;
    def isodate: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
      and (split("-") | map(tonumber) as [$y, $m, $d]
           | $m >= 1 and $m <= 12 and $d >= 1 and $d <= days($y; $m));
    def v($rule; $detail): "\($rule)\t\($detail | gsub("\\n"; " "))";
    (
      # schema: the top-level shape
      (if .schema != "target-architecture/v1"
       then v("schema"; "schema is \(.schema | show), expected \"target-architecture/v1\"") else empty end),
      (if (.provenance | type) != "object" then v("schema"; "provenance is missing or not an object")
       else (["generated_by", "generated_at"][] as $k
             | select((.provenance[$k] | str) | not)
             | v("schema"; "provenance.\($k) is missing or empty")),
            (select((.provenance.prose_sha256 | type == "string" and test("^[0-9a-f]{64}$")) | not)
             | v("schema"; "provenance.prose_sha256 is not 64 lowercase hex digits"))
       end),
      (["clauses", "changes"][] as $k
       | select((.[$k] | type == "array" and all(.[]; type == "object")) | not)
       | v("schema"; "\($k) is not an array of objects")),

      # the clauses
      (objs("clauses")[] as $e
       | ($e.id | if type == "string" then . else "clauses[?]" end) as $name
       | (if ($e.status | IN("active", "retired")) | not
          then v("schema"; "\($name): status is \($e.status | show), expected active or retired") else empty end),
         (if ($e.area | str) | not then v("schema"; "\($name): area is missing or empty") else empty end),
         (if ($e.id | type) != "string" then v("bad-id-shape"; "a clause has no string id")
          elif ($e.id | test("^TA-[1-9][0-9]*$") | not)
          then v("bad-id-shape"; "\($e.id) does not match TA-<n>") else empty end),
         (if ($e | has("statement")) and ($e | has("ref"))
          then v("statement-and-ref"; "\($name) has both a statement and a ref") else empty end),
         (if ($e | has("statement") or has("ref")) | not
          then v("neither-statement-nor-ref"; "\($name) has neither a statement nor a ref") else empty end),
         (if ($e | has("statement")) and (($e.statement | str) | not)
          then v("schema"; "\($name): statement is empty or not a string") else empty end),
         (if ($e | has("ref")) and (($e.ref | type == "object" and (.path | str) and (.title | str)
                                     and (.anchor | type == "string")) | not)
          then v("schema"; "\($name): ref needs string path, anchor and title") else empty end)),

      # the changes
      (objs("changes")[] as $d
       | ($d.id | if type == "string" then . else "changes[?]" end) as $name
       | (if ($d.id | type) != "string" then v("bad-id-shape"; "a change has no string id")
          elif ($d.id | test("^TC-[0-9]{4}-(0[1-9]|1[0-2])-[1-9][0-9]*$") | not)
          then v("bad-id-shape"; "\($d.id) does not match TC-<yyyy>-<mm>-<n>") else empty end),
         (if ($d.date | isodate) | not
          then v("bad-date"; "\($name): date \($d.date | show) is not a calendar date YYYY-MM-DD")
          elif ($d.id | type == "string" and test("^TC-[0-9]{4}-[0-9]{2}-"))
               and ($d.id[3:10] != $d.date[0:7])
          then v("bad-date"; "\($name): date \($d.date) is not in the month its id names") else empty end),
         (["from", "to", "rationale"][] as $f
          | select(($d[$f] | str) | not) | v("schema"; "\($name): \($f) is missing or empty")),
         (["affects", "evidence"][] as $f
          | select(($d[$f] | type == "array" and all(.[]; type == "string")) | not)
          | v("schema"; "\($name): \($f) is not an array of strings"))),

      # ids: unique across the whole file
      ([("clauses", "changes") as $k | objs($k)[] | .id | select(type == "string")]
       | group_by(.)[] | select(length > 1)
       | v("duplicate-id"; "\(.[0]) is used \(length) times")),

      # affects: every id names a clause
      ([objs("clauses")[] | .id | select(type == "string")] as $ids
       | objs("changes")[] as $d
       | ($d.affects | if type == "array" then .[] else empty end) as $a
       | select(($a | type) != "string" or ($ids | index([$a]) | not))
       | v("unresolved-affects"; "\($d.id | show) affects \($a | show), which no clause has")),

      # retired: every retired clause is named by some change
      ([objs("changes")[] | .affects | if type == "array" then .[] else empty end] as $named
       | objs("clauses")[]
       | select(.status == "retired" and (.id | type == "string")) | .id as $id
       | select($named | index([$id]) | not)
       | v("retired-unnamed"; "\($id) is retired but no change names it in affects"))
    )')" || { print -r -- "$me: jq failed reading the block" >&2; exit 2; }
  local rule detail
  for line in "${(@f)judged}"; do
    [[ -n "$line" ]] || continue
    rule="${line%%$'\t'*}"
    detail="${line#*$'\t'}"
    flag "$rule" "$detail"
  done
fi

# --- the rule that looks outside the block ----------------------------------

# own_path <path> — succeeds when <path> is the repo's own file; otherwise sets
# `why` to the reason. Exits 2 when the lookup itself fails.
local why=""
own_path() {
  local p="$1" out
  local -i rc=0
  why=""
  if [[ "$p" == /* || "$p" == -* ]]; then why="not a repo-relative path"; return 1; fi
  if [[ "/$p/" == */../* ]]; then why="leaves the repo"; return 1; fi
  out="$(zsh "$lookup" --repo "$root" "$p" 2>/dev/null)" || rc=$?
  case $rc in
    0) [[ "${out##*$'\t'}" == own ]] && return 0
       why="found only in ${out##*$'\t'}, and refs are repo-local"; return 1 ;;
    3|4) why="no such file in the repo"; return 1 ;;
    5) why="lies inside a submodule, not in the repo"; return 1 ;;
    *) print -r -- "$me: the reference-document lookup failed for $p (exit $rc)" >&2; exit 2 ;;
  esac
}

if (( block_ok )); then
  local clause_id p
  # NUL-framed, so an id or a path holding a newline or a tab stays one field
  for clause_id p in "${(@0)$(print -r -- "$block" | jq -j '
      (.clauses // []) | if type == "array" then .[] else empty end
      | select(type == "object" and (.ref | type == "object") and (.ref.path | type == "string" and . != ""))
      | (.id // "?" | tostring | gsub("\u0000"; "")), "\u0000", (.ref.path | gsub("\u0000"; "\ufffd")), "\u0000"')}"; do
    [[ -n "$p" ]] || continue
    own_path "$p" || flag ref-missing "$clause_id: ref path $p: $why"
  done
fi

# stale-prose: the block's prose hash matches the prose between the sentinels
if (( layout_ok && block_ok )); then
  local stored actual
  stored="$(print -r -- "$block" | jq -r '.provenance.prose_sha256? // empty | select(type == "string")' 2>/dev/null)"
  if [[ -n "$stored" ]]; then
    actual="$(print -rl -- "${(@)lines[start+1,end-1]}" | zsh "$hasher")" \
      || { print -r -- "$me: story-spec-prose-hash.zsh failed" >&2; exit 2; }
    [[ "$actual" == "$stored" ]] \
      || flag stale-prose "provenance.prose_sha256 is $stored, the prose hashes to $actual; regenerate the block"
  fi
fi

if (( ${#violations} > 0 )); then
  print -rl -- "${violations[@]}" >&2
  exit 1
fi
print -r -- "target-architecture: valid"
exit 0
