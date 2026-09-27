#!/usr/bin/env zsh
# merge-driver-claude-plugin.zsh — the claude-plugin repo type's git merge
# driver for the plugin manifests (epic #1820, child #1821).
#
# Two concurrently open PRs almost always collide in the manifests: each bumps
# its plugin's `version` and appends a release note to its `description`. This
# driver resolves exactly those MECHANICAL conflicts by rule and refuses
# everything else, so a real conflict still stops and goes to a human. Design:
# epic #1820.
#
# The filename IS the registry: the rebase engine (#1822) finds a repo type's
# driver as `merge-driver-<repo_type>.zsh`, asks it for its path patterns and
# wires it in for one rebase only. It is never wired into a plain `git merge`.
#
# Usage:
#   merge-driver-claude-plugin.zsh --patterns
#       print the path patterns this driver handles, one per line; exit 0
#   merge-driver-claude-plugin.zsh <O> <A> <B> <path>
#       git's `%O %A %B %P` call. REBASE orientation: <O> is the replayed
#       commit's parent, <A> is main's side (the current HEAD), <B> is the PR
#       commit being replayed. <path> is the file's repo path; its basename
#       picks the rules (marketplace.json or plugin.json).
#
# Rules, per plugin entry (`marketplace.json` entries matched by `name`;
# `plugin.json` is one entry):
#   1. version     — one side changed it: take that side. Both did: bump <A>'s
#                    version at the PR's level (<O> -> <B>: major / minor /
#                    patch), even when both chose the same value — two PRs that
#                    each cut 1.194.0 are two releases. A version that is not
#                    MAJOR.MINOR.PATCH (digits only), or a PR side that is not a
#                    bump of <O>, is a real conflict.
#   2. description — one side changed it: take that side. Both did and <B> is
#                    <O> plus a non-empty suffix: <A> plus that suffix. Any
#                    other edit is a real conflict — only appending is
#                    mechanical.
#   3. anything else (top-level or per-entry, entries added or removed
#                    included): a change on one side is taken, the same change
#                    on both sides is taken, different changes are a real
#                    conflict.
#
# Output: two-space indent, keys and marketplace entries in <A>'s order (those
# new on <B>'s side appended in <B>'s order; a reorder on <B> alone is not
# carried over), one trailing newline — so a resolved file differs from <A>
# only in the resolved values.
#
# Verdict record: when MERGE_DRIVER_RECORD names a file, every field changed on
# BOTH sides and resolved by rule 1 or 2 appends one JSON line
# {"path","plugin","field","main","pr","result"}. One-side takes are not
# recorded; unset or empty, nothing is written.
#
# A pure function of its inputs: no network, no git calls, no reads outside
# its arguments.
#
# Exit codes:
#   0  resolved — the merged JSON is in <A> (or --patterns printed)
#   1  not resolvable by rule, or unreadable input — <A> is left byte-identical
#      and git keeps the conflict
#   2  usage — wrong argument count

emulate -L zsh
setopt nounset pipefail

local usage="usage: merge-driver-claude-plugin.zsh --patterns
       merge-driver-claude-plugin.zsh <O> <A> <B> <path>"

if (( $# == 1 )) && [[ "$1" == --patterns ]]; then
  print -r -- '**/.claude-plugin/*.json'
  exit 0
fi
(( $# == 4 )) || { print -u2 -- "merge-driver-claude-plugin: expected --patterns or 4 arguments, got $#
$usage"; exit 2 }

local base="$1" ours="$2" theirs="$3" repo_path="$4"

local mode
case "${repo_path:t}" in
  marketplace.json) mode=marketplace ;;
  plugin.json) mode=plugin ;;
  *) print -u2 -- "merge-driver-claude-plugin: $repo_path: not a plugin manifest; left conflicted"; exit 1 ;;
esac

command -v jq >/dev/null 2>&1 || {
  print -u2 -- "merge-driver-claude-plugin: jq not found on PATH; $repo_path left conflicted"; exit 1 }

# Each side of a field is [] (absent) or [value] (present), so "removed" is a
# value like any other and one comparison covers adds, removals and edits.
local prog='
def side($x; $k): if $x | has($k) then [$x[$k]] else [] end;

# The changed side when only one side changed; null when both did.
def one_side($o; $a; $b): if $o == $b then $a elif $o == $a then $b else null end;

def generic($what; $o; $a; $b):
  one_side($o; $a; $b)
  // (if $a == $b then $a else error("\($what): changed differently on both sides") end);

def semver($what):
  if type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$") then split(".") | map(tonumber)
  else error("\($what): \(tojson) is not MAJOR.MINOR.PATCH") end;

def version_rule($what; $o; $a; $b):
  one_side($o; $a; $b) as $one
  | if $one != null then {v: $one, resolved: false}
    elif ([$o, $a, $b] | map(length) | min) == 0 then
      error("\($what): added or removed on both sides")
    else
      ($o[0] | semver($what)) as $ov | ($a[0] | semver($what)) as $av | ($b[0] | semver($what)) as $bv
      | (if $bv[0] > $ov[0] then [$av[0] + 1, 0, 0]
         elif $bv[0] == $ov[0] and $bv[1] > $ov[1] then [$av[0], $av[1] + 1, 0]
         elif $bv[0:2] == $ov[0:2] and $bv[2] > $ov[2] then [$av[0], $av[1], $av[2] + 1]
         else error("\($what): PR side \($b[0]) is not a bump of \($o[0])") end)
      | {v: [map(tostring) | join(".")], resolved: true}
    end;

def description_rule($what; $o; $a; $b):
  one_side($o; $a; $b) as $one
  | if $one != null then {v: $one, resolved: false}
    elif ([$o, $a, $b] | map(length) | min) == 1
         and ([$o[0], $a[0], $b[0]] | all(type == "string"))
         and ($b[0] | startswith($o[0]))
         and ($b[0] | length) > ($o[0] | length) then
      {v: [$a[0] + $b[0][($o[0] | length):]], resolved: true}
    else error("\($what): not an append on the PR side") end;

# The marketplace plugin list, keyed by name; anything not matchable by name
# cannot be merged per entry.
def entries($what):
  if type == "array" and all(type == "object" and (.name | type) == "string")
     and (map(.name) | length) == (map(.name) | unique | length) then .
  else error("\($what): not a list of uniquely named plugin entries") end;

def entry($list; $n): [$list[] | select(.name == $n)];

# Merge objects key by key, in the key order of <A>, with keys new on <B>
# appended in the order of <B>. `field` is the per-key rule: it receives {k, w, ov, av, bv} and
# returns {v, recs}. Returns {res, recs}.
def merge_obj($what; field; $o; $a; $b):
  ([$a | keys_unsorted[]] + [$b | keys_unsorted[] | select(. as $k | $a | has($k) | not)]) as $ks
  | reduce $ks[] as $k ({res: {}, recs: []};
      ({k: $k, w: "\($what).\($k)", ov: side($o; $k), av: side($a; $k), bv: side($b; $k)} | field) as $r
      | .res += (if ($r.v | length) == 1 then {($k): $r.v[0]} else {} end)
      | .recs += $r.recs);

# A both-sides resolution by rule 1 or 2 is recorded; a one-side take is not.
def recorded:
  . as $f | if $f.r.resolved then [{field: $f.k, main: $f.av[0], pr: $f.bv[0], result: $f.r.v[0]}] else [] end;

# The rule for one key of a plugin entry: rules 1 and 2, else rule 3.
def entry_field:
  if .k == "version" then . + {r: version_rule(.w; .ov; .av; .bv)} | {v: .r.v, recs: recorded}
  elif .k == "description" then . + {r: description_rule(.w; .ov; .av; .bv)} | {v: .r.v, recs: recorded}
  else {v: generic(.w; .ov; .av; .bv), recs: []} end;

# The marketplace plugin list, merged per entry matched by name, in the order
# of <A>, with entries new on <B> appended in the order of <B>.
# (No apostrophes anywhere in this program: it is one single-quoted string.)
def merge_plugins($what; $o; $a; $b):
  ($o | entries($what)) as $o | ($a | entries($what)) as $a | ($b | entries($what)) as $b
  | ([$a[].name] + [$b[].name | select(. as $n | [$a[].name] | index([$n]) | not)]) as $names
  | reduce $names[] as $n ({v: [[]], recs: []};
      entry($o; $n) as $oe | entry($a; $n) as $ae | entry($b; $n) as $be
      | "\($what)[\($n)]" as $w
      | if ([$oe, $ae, $be] | map(length) | min) == 1 then
          merge_obj($w; entry_field; $oe[0]; $ae[0]; $be[0]) as $m
          | .v[0] += [$m.res]
          | .recs += [$m.recs[] | {plugin: $n} + .]
        else
          generic($w; $oe; $ae; $be) as $g | .v[0] += $g
        end);

# The marketplace top level: its own keys take rule 3 only; its plugin list is
# merged per entry when every side has one.
def marketplace_field:
  if .k == "plugins" and ([.ov, .av, .bv] | map(length) | min) == 1 then
    merge_plugins(.w; .ov[0]; .av[0]; .bv[0])
  else {v: generic(.w; .ov; .av; .bv), recs: []} end;

($o | length) as $n_o | ($a | length) as $n_a | ($b | length) as $n_b
| if [$n_o, $n_a, $n_b] != [1, 1, 1] or ([$o[0], $a[0], $b[0]] | any(type != "object")) then
    error("\($path): each side must be exactly one JSON object")
  else . end
| (if $mode == "marketplace" then merge_obj($path; marketplace_field; $o[0]; $a[0]; $b[0])
   else merge_obj($path; entry_field; $o[0]; $a[0]; $b[0])
        | .recs |= map({plugin: ($a[0].name // null)} + .) end)
| {result: .res,
   records: [.recs[] | {path: $path, plugin, field, main, pr, result}]}
'

local work
work="$(mktemp -d)" || { print -u2 -- "merge-driver-claude-plugin: mktemp failed; $repo_path left conflicted"; exit 1 }
# The staged result and the backup live beside <A> so the final move is a
# rename within one filesystem, never a partial copy over <A>.
local staged="" backup=""
trap 'rm -rf -- "$work"; [[ -n "$staged" ]] && rm -f -- "$staged"; [[ -n "$backup" ]] && rm -f -- "$backup"' EXIT

jq -n -c --arg mode "$mode" --arg path "$repo_path" \
  --slurpfile o "$base" --slurpfile a "$ours" --slurpfile b "$theirs" \
  "$prog" > "$work/merged.json" || {
  print -u2 -- "merge-driver-claude-plugin: $repo_path: not resolvable by rule; left conflicted"; exit 1 }

jq '.result' "$work/merged.json" > "$work/result.json" \
  && jq -c '.records[]' "$work/merged.json" > "$work/records.jsonl" || {
  print -u2 -- "merge-driver-claude-plugin: $repo_path: could not render the result; left conflicted"; exit 1 }

staged="$(mktemp "${ours:h}/.merge-driver-result.XXXXXX")" \
  && backup="$(mktemp "${ours:h}/.merge-driver-backup.XXXXXX")" \
  && cat -- "$work/result.json" > "$staged" \
  && cat -- "$ours" > "$backup" || {
  print -u2 -- "merge-driver-claude-plugin: $repo_path: could not stage the result; left conflicted"; exit 1 }

mv -f -- "$staged" "$ours" || {
  print -u2 -- "merge-driver-claude-plugin: $repo_path: could not write the result; left conflicted"; exit 1 }
staged=""

# Records are appended only once <A> holds the result they describe; if the
# append fails, <A> is restored so an exit 1 always means <A> is untouched.
if [[ -n "${MERGE_DRIVER_RECORD:-}" && -s "$work/records.jsonl" ]]; then
  cat -- "$work/records.jsonl" >> "$MERGE_DRIVER_RECORD" || {
    mv -f -- "$backup" "$ours" && backup=""
    print -u2 -- "merge-driver-claude-plugin: $repo_path: could not append to MERGE_DRIVER_RECORD; left conflicted"
    exit 1 }
fi
exit 0
