#!/usr/bin/env zsh
# Does a product charter keep to `charter/v1` (#3205)?
#
#   validate-charter.zsh <charter.md>
#
# The contract is ARCHITECTURE.md, *Product charter contract (`charter/v1`)*.
# This script is its single-file check: it reads one charter and judges it
# alone, so it cannot see an active entry reworded in place, an entry deleted,
# or an id renumbered or reused, which only the file's history would show.
#
# Every violation is reported, not only the first: one stderr line each,
#   charter: <rule>: <detail>
# where <rule> is one of schema, bad-id-shape, duplicate-id, statement-and-ref,
# neither-statement-nor-ref, retired-unnamed, unresolved-affects,
# unresolved-serves, ref-missing, appendix-missing, bad-date, stale-prose.
#
# The repo is the git work tree holding the charter, or the current directory
# outside git. A `ref` path and an appendix must be the repo's own file:
# `resolve-product-doc.zsh` (beside this script) must answer `own`, so a path
# found only in a linked submodule is missing. The persona registry is the
# lookup's answer for `docs/personas.md`, linked submodules included.
#
# Exit codes:
#   0 valid      (stdout: `charter: valid`)
#   1 invalid    (stderr: one line per violation)
#   2 usage error, an unreadable charter, or a check that cannot complete
#     (jq or a sibling script missing, a lookup that fails internally, a
#     persona-registry lookup stopped by an uninitialised submodule) —
#     none of which is a verdict on the charter

emulate -L zsh
setopt extended_glob
set -uo pipefail

local me="${0:t}"
local here="${0:A:h}"

usage() {
  print -r -- "usage: $me <charter.md>" >&2
  exit 2
}

local file=""
local -i have_file=0
while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      print -r -- "usage: $me <charter.md>"
      exit 0 ;;
    --) shift
        (( $# == 1 && have_file == 0 )) || usage
        file="$1"; have_file=1; shift ;;
    -*) print -r -- "$me: unknown flag: $1" >&2; usage ;;
    *)
      (( have_file == 0 )) || { print -r -- "$me: more than one charter given" >&2; usage; }
      file="$1"; have_file=1; shift ;;
  esac
done
(( have_file == 1 )) && [[ -n "$file" ]] || { print -r -- "$me: a charter file is required" >&2; usage; }
[[ -f "$file" && -r "$file" ]] || { print -r -- "$me: cannot read: $file" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { print -r -- "$me: jq is not on PATH" >&2; exit 2; }
local hasher="$here/prose-hash.zsh" lookup="$here/resolve-product-doc.zsh"
[[ -r "$hasher" && -r "$lookup" ]] || { print -r -- "$me: a sibling script is missing in $here" >&2; exit 2; }

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
# flattened so each violation stays one line
flag() {
  local detail="${2//$'\r'/}"
  detail="${detail//$'\n'/ }"
  detail="${detail//$'\t'/ }"
  violations+=( "charter: $1: $detail" )
}

# --- the layout: sentinels, prose sections, the machine block ---------------

local -a lines
lines=( "${(@f)$(tr -d '\r' < "$file")}" )

local -i i n=${#lines} start=0 end=0 starts=0 ends=0
for (( i = 1; i <= n; i++ )); do
  case "${lines[i]%%[[:space:]]#}" in
    '<!-- charter:prose:start -->') (( starts++ )); (( start == 0 )) && start=i ;;
    '<!-- charter:prose:end -->')   (( ends++ ));   (( end == 0 )) && end=i ;;
  esac
done

local -i layout_ok=1
if (( starts != 1 || ends != 1 )); then
  local sentinels='<!-- charter:prose:start --> and one <!-- charter:prose:end -->'
  flag schema "expected one $sentinels line, found $starts and $ends"
  layout_ok=0
elif (( start > end )); then
  flag schema "<!-- charter:prose:end --> comes before <!-- charter:prose:start -->"
  layout_ok=0
fi

# The prose sections, in the contract's order.
local -a expected_sections=(
  'Summary'
  'Purpose and background'
  'Who it serves'
  'Values'
  'What we build'
  "What we deliberately don't build"
  'Direction changes'
)
if (( layout_ok )); then
  local -a found_sections=()
  local line
  for (( i = start + 1; i < end; i++ )); do
    line="${lines[i]}"
    [[ "$line" == '## '* ]] || continue
    line="${${line#\#\# }%%[[:space:]]#}"
    found_sections+=( "${line##[[:space:]]#}" )
  done
  if [[ "${(j:|:)found_sections}" != "${(j:|:)expected_sections}" ]]; then
    flag schema "prose sections are [${(j:, :)found_sections}], expected [${(j:, :)expected_sections}]"
  fi
fi

# The machine block: the first fenced `json` object after the prose, inside a
# <details> element.
local block="" details_open=0 details_close=0
local -i fence_open=0 fence_close=0
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
    def lists: [["values", "V"], ["scope", "S"], ["non_goals", "NG"]];
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
    def v($rule; $detail): "\($rule)\t\($detail)";
    . as $c
    | (
      # schema: the top-level shape
      (if .schema != "charter/v1" then v("schema"; "schema is \(.schema | show), expected \"charter/v1\"")
       else empty end),
      (if (.provenance | type) != "object" then v("schema"; "provenance is missing or not an object")
       else (["generated_by", "generated_at"][] as $k
             | select((.provenance[$k] | str) | not)
             | v("schema"; "provenance.\($k) is missing or empty")),
            (select((.provenance.prose_sha256 | type == "string" and test("^[0-9a-f]{64}$")) | not)
             | v("schema"; "provenance.prose_sha256 is not 64 lowercase hex digits"))
       end),
      (["title", "purpose", "background"][] as $k
       | select((.[$k] | str) | not) | v("schema"; "\($k) is missing or empty")),
      (["appendices", "serves"][] as $k
       | select((.[$k] | type == "array" and all(.[]; str)) | not)
       | v("schema"; "\($k) is not an array of strings")),
      ((lists[][0], "direction_changes") as $k
       | select((.[$k] | type == "array" and all(.[]; type == "object")) | not)
       | v("schema"; "\($k) is not an array of objects")),

      # the entries: values, scope, non-goals
      (lists[] as [$k, $p] | objs($k)[] as $e
       | ($e.id | if type == "string" then . else "\($k)[?]" end) as $name
       | (if ($e.status | IN("active", "retired")) | not
          then v("schema"; "\($name): status is \($e.status | show), expected active or retired") else empty end),
         (if ($e.id | type) != "string" then v("bad-id-shape"; "a \($k) entry has no string id")
          elif ($e.id | test("^\($p)-[1-9][0-9]*$") | not)
          then v("bad-id-shape"; "\($e.id) in \($k) does not match \($p)-<n>") else empty end),
         (if ($e | has("statement")) and ($e | has("ref"))
          then v("statement-and-ref"; "\($name) has both a statement and a ref") else empty end),
         (if ($e | has("statement") or has("ref")) | not
          then v("neither-statement-nor-ref"; "\($name) has neither a statement nor a ref") else empty end),
         (if ($e | has("statement")) and (($e.statement | str) | not)
          then v("schema"; "\($name): statement is empty or not a string") else empty end),
         (if ($e | has("ref")) and (($e.ref | type == "object" and (.path | str) and (.title | str)
                                     and (.anchor | type == "string")) | not)
          then v("schema"; "\($name): ref needs string path, anchor and title") else empty end),
         (if $k == "non_goals" and ($e | has("statement")) and (($e.rationale | str) | not)
          then v("schema"; "\($name): a non-goal with a statement needs a rationale") else empty end)),

      # the direction changes
      (objs("direction_changes")[] as $d
       | ($d.id | if type == "string" then . else "direction_changes[?]" end) as $name
       | (if ($d.id | type) != "string" then v("bad-id-shape"; "a direction change has no string id")
          elif ($d.id | test("^DC-[0-9]{4}-(0[1-9]|1[0-2])-[1-9][0-9]*$") | not)
          then v("bad-id-shape"; "\($d.id) does not match DC-<yyyy>-<mm>-<n>") else empty end),
         (if ($d.date | isodate) | not
          then v("bad-date"; "\($name): date \($d.date | show) is not a calendar date YYYY-MM-DD")
          elif ($d.id | type == "string" and test("^DC-[0-9]{4}-[0-9]{2}-"))
               and ($d.id[3:10] != $d.date[0:7])
          then v("bad-date"; "\($name): date \($d.date) is not in the month its id names") else empty end),
         (["from", "to", "rationale"][] as $f
          | select(($d[$f] | str) | not) | v("schema"; "\($name): \($f) is missing or empty")),
         (["affects", "evidence"][] as $f
          | select(($d[$f] | type == "array" and all(.[]; type == "string")) | not)
          | v("schema"; "\($name): \($f) is not an array of strings"))),

      # ids: unique across the whole charter
      ([(lists[][0], "direction_changes") as $k | objs($k)[] | .id | select(type == "string")]
       | group_by(.)[] | select(length > 1)
       | v("duplicate-id"; "\(.[0]) is used \(length) times")),

      # affects: every id names a value, scope item or non-goal
      ([lists[][0] as $k | objs($k)[] | .id | select(type == "string")] as $ids
       | objs("direction_changes")[] as $d
       | ($d.affects | if type == "array" then .[] else empty end) as $a
       | select(($a | type) != "string" or ($ids | index([$a]) | not))
       | v("unresolved-affects"; "\($d.id | show) affects \($a | show), which no value, scope item or non-goal has")),

      # retired: every retired entry is named by some direction change
      ([objs("direction_changes")[] | .affects | if type == "array" then .[] else empty end] as $named
       | lists[][0] as $k | objs($k)[]
       | select(.status == "retired" and (.id | type == "string")) | .id as $id
       | select($named | index([$id]) | not)
       | v("retired-unnamed"; "\($id) is retired but no direction change names it in affects"))
    )')" || { print -r -- "$me: jq failed reading the block" >&2; exit 2; }
  local rule detail
  for line in "${(@f)judged}"; do
    [[ -n "$line" ]] || continue
    rule="${line%%$'\t'*}"
    detail="${line#*$'\t'}"
    flag "$rule" "$detail"
  done
fi

# --- the rules that look outside the block ----------------------------------

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
    3) why="no such file in the repo"; return 1 ;;
    4) why="no such file in the repo"; return 1 ;;
    5) why="lies inside a submodule, not in the repo"; return 1 ;;
    *) print -r -- "$me: the product-document lookup failed for $p (exit $rc)" >&2; exit 2 ;;
  esac
}

if (( block_ok )); then
  local entry_id p
  # refs: every entry's ref.path
  for line in "${(@f)$(print -r -- "$block" | jq -r '
      ["values", "scope", "non_goals"][] as $k | (.[$k] // []) | if type == "array" then .[] else empty end
      | select(type == "object" and (.ref | type == "object") and (.ref.path | type == "string" and . != ""))
      | "\(.id // "?")\t\(.ref.path)"')}"; do
    [[ -n "$line" ]] || continue
    entry_id="${line%%$'\t'*}"; p="${line#*$'\t'}"
    own_path "$p" || flag ref-missing "$entry_id: ref path $p: $why"
  done

  # appendices
  for p in "${(@f)$(print -r -- "$block" | jq -r '
      (.appendices // []) | if type == "array" then .[] else empty end | select(type == "string" and . != "")')}"; do
    [[ -n "$p" ]] || continue
    own_path "$p" || flag appendix-missing "$p: $why"
  done

  # serves: every persona id is in the persona registry
  local -a serves=()
  serves=( "${(@f)$(print -r -- "$block" | jq -r '
      (.serves // []) | if type == "array" then .[] else empty end | select(type == "string")')}" )
  serves=( ${serves:#} )
  if (( ${#serves} > 0 )); then
    local reg_out reg_path reg_why=""
    local -i reg_rc=0
    reg_out="$(zsh "$lookup" --repo "$root" docs/personas.md 2>/dev/null)" || reg_rc=$?
    local -a known=()
    case $reg_rc in
      0) reg_path="${reg_out%%$'\t'*}"
         local reg_block
         reg_block="$(tr -d '\r' < "$reg_path" | awk '
             /^<!-- personas:prose:end -->[[:space:]]*$/ { after = 1; next }
             after && !inside && /^[[:space:]]*```json[[:space:]]*$/ { inside = 1; next }
             inside && /^[[:space:]]*```[[:space:]]*$/ { exit }
             inside { print }')"
         if known=( "${(@f)$(print -r -- "$reg_block" \
                 | jq -r '.personas[] | .id | select(type == "string")' 2>/dev/null)}" ) \
            && (( ${#${known:#}} > 0 )); then
           known=( ${known:#} )
         else
           known=(); reg_why="the persona registry $reg_path has no readable personas/v1 block"
         fi ;;
      3|5) reg_why="no persona registry (docs/personas.md) was found" ;;
      4) print -r -- "$me: the persona registry cannot be looked up: a declared submodule is not" \
           "initialised (run git submodule update --init)" >&2
         exit 2 ;;
      *) print -r -- "$me: the persona-registry lookup failed (exit $reg_rc)" >&2; exit 2 ;;
    esac
    local s
    for s in "${serves[@]}"; do
      if [[ -n "$reg_why" ]]; then
        flag unresolved-serves "$s: $reg_why"
      elif (( ${known[(Ie)$s]} == 0 )); then
        flag unresolved-serves "$s is not a persona id in the registry"
      fi
    done
  fi
fi

# stale-prose: the block's prose hash matches the prose between the sentinels
if (( layout_ok && block_ok )); then
  local stored actual
  stored="$(print -r -- "$block" | jq -r '.provenance.prose_sha256? // empty | select(type == "string")' 2>/dev/null)"
  if [[ -n "$stored" ]]; then
    actual="$(print -rl -- "${(@)lines[start+1,end-1]}" | zsh "$hasher")" \
      || { print -r -- "$me: prose-hash.zsh failed" >&2; exit 2; }
    [[ "$actual" == "$stored" ]] \
      || flag stale-prose "provenance.prose_sha256 is $stored, the prose hashes to $actual; regenerate the block"
  fi
fi

if (( ${#violations} > 0 )); then
  print -rl -- "${violations[@]}" >&2
  exit 1
fi
print -r -- "charter: valid"
exit 0
