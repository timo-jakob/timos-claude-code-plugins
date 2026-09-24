#!/usr/bin/env zsh
# size-preflight.zsh — judge a story's DECLARED change inventory against the
# three size thresholds before the first implementation edit (#1437, epic #1431).
#
# #687 landed as one 49-file change and nine review rounds never reached zero;
# #1435 was 27 files and ten rounds never did either. No round budget rescues a
# change that size, because the cross-artifact consistency obligations grow
# with the artifacts touched. So resolve-issue §2 declares what it intends to
# touch, and this script says whether that plan can be reviewed to a fixed
# point — a story that cannot is split before it is built, not reviewed to
# death after.
#
# The input is a JUDGEMENT, not a measured diff: the session writes it before
# anything is touched. That is the accepted cost of checking before the work
# rather than after (a `git diff --name-only` only exists once the expensive
# change does). Inventory shape — exactly one JSON object:
#   { "files": ["development/skills/resolve-issue/SKILL.md", …],
#     "plugins": ["development"] }      # optional; re-derived, must match
#
# The three thresholds — each a strict comparison, so a test can straddle it:
#   1. files      — more than MAX_FILES distinct files stops (20 passes, 21 stops).
#   2. plugin     — ANY owned file outside the primary plugin stops, and so does
#                   a tie for primary (a tie IS a straddling change).
#   3. bootstrap-straddle — a path under BOOTSTRAP_TEMPLATES together with an
#                   OWNED path outside BOOTSTRAP_SKILL stops. The bootstrap skill
#                   edited with its own templates passes, and so does the
#                   templates' own plugin manifest (development/.claude-plugin/
#                   plugin.json) — the version bump every content change carries.
#
# Ownership: a path's owning plugin is its first segment when that segment is a
# plugin in the marketplace manifest, or a plugin this change creates (the
# inventory lists `<segment>/.claude-plugin/plugin.json`). Anything else —
# ARCHITECTURE.md, docs/, tests/, .github/ — is unowned: it counts toward the
# file total and never toward the plugin rule. The primary plugin owns the
# plurality of owned files; an all-unowned inventory has primary_plugin null,
# and the plugin rule cannot fire. A declared `plugins` that disagrees with the
# derived set is a malformed inventory (exit 3).
#
# A repo with NO marketplace manifest — every app repo resolve-issue runs in —
# has no known plugins: unless the change creates one, every path is unowned and
# only the files trigger can fire. That holds only for the DEFAULT manifest
# path; an explicit --manifest that is missing is a usage error.
#
# Paths are normalised segment by segment — empty and `.` segments dropped —
# before ownership and the distinct count, and the bootstrap prefixes are
# compared by whole segment, so no spelling of a path (a trailing slash, a bare
# directory) can move its owner or dodge a prefix check. A path with a `..` segment is refused for the
# same reason, and so is one that normalises to nothing, or an empty `files`.
#
# Output (exits 0 and 1 only), one object:
#   { "verdict": "pass"|"stop", "triggers": [...], "files": N, "plugins": N,
#     "primary_plugin": "<name>"|null, "unowned": N }
# "overridden" is never a verdict here: this script judges size, the human
# overrides, and the session records that (SKILL.md §2).
#
# Pure function of its input: no GitHub, no git, no writes.
#
# Exit codes:
#   0 — pass: no threshold crossed; the verdict is on stdout. (`-h` also exits 0,
#       with its usage on STDERR and nothing on stdout.)
#   1 — stop-and-ask: at least one threshold crossed; the verdict on stdout
#       names the triggers. Not an error.
#   2 — usage error (unknown/dangling flag, a missing or unreadable inventory,
#       an explicit --manifest that is missing or unreadable, a default manifest
#       that exists but is unreadable, no --file with a terminal on stdin).
#   3 — runtime error (invalid JSON, jq missing, a malformed inventory or
#       manifest).
# Exits 2 and 3 print NOTHING on stdout — never read an empty document as a pass.
#
# Usage:
#   size-preflight.zsh --file <inventory.json> [--manifest <marketplace.json>]
#   size-preflight.zsh < inventory.json
#   size-preflight.zsh -h
# --manifest defaults to .claude-plugin/marketplace.json under the cwd.

emulate -L zsh
set -euo pipefail

typeset -r MAX_FILES=20
typeset -r BOOTSTRAP_TEMPLATES="development/skills/bootstrap/templates/"
typeset -r BOOTSTRAP_SKILL="development/skills/bootstrap/"

local file="" manifest=".claude-plugin/marketplace.json" manifest_explicit=0
while (( $# > 0 )); do
  case "$1" in
    --file|--manifest)
      (( $# >= 2 )) && [[ -n "$2" ]] \
        || { print -u2 "size-preflight.zsh: $1 needs a value"; exit 2; }
      if [[ "$1" == --file ]]; then file="$2"; else manifest="$2"; manifest_explicit=1; fi
      shift 2 ;;
    -h|--help)
      print -u2 -r -- "usage: size-preflight.zsh [--file <inventory.json>] [--manifest <marketplace.json>]  (else reads stdin)"
      print -u2 -r -- "exit 0 pass, 1 stop-and-ask (verdict on stdout for both), 2 usage, 3 runtime."
      exit 0 ;;
    *) print -u2 "size-preflight.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -n "$file" ]]; then
  [[ -f "$file" && -r "$file" ]] \
    || { print -u2 "size-preflight.zsh: inventory not found or unreadable: $file"; exit 2; }
else
  [[ ! -t 0 ]] || { print -u2 "size-preflight.zsh: no --file and stdin is a terminal"; exit 2; }
fi
if (( manifest_explicit )); then
  [[ -f "$manifest" && -r "$manifest" ]] \
    || { print -u2 "size-preflight.zsh: marketplace manifest not found or unreadable: $manifest"; exit 2; }
fi
command -v jq >/dev/null 2>&1 || { print -u2 "size-preflight.zsh: jq not found on PATH"; exit 3; }

local inv
if [[ -n "$file" ]]; then inv="$(<"$file")"; else inv="$(cat)"; fi
# -s: a stream of several documents is refused, not judged as its last one.
print -r -- "$inv" | jq -se 'length == 1' >/dev/null 2>&1 \
  || { print -u2 "size-preflight.zsh: inventory is not exactly one valid JSON document"; exit 3; }

# The known plugins. A default manifest that is absent means none (an app repo);
# one that is present must parse and list at least one local plugin.
local plugins_json="[]"
if [[ -e "$manifest" ]]; then
  [[ -r "$manifest" ]] || { print -u2 "size-preflight.zsh: marketplace manifest unreadable: $manifest"; exit 2; }
  plugins_json="$(jq -c '[.plugins[]? | objects | .source | select(type == "string")
                          | sub("^(\\./)+"; "") | split("/")[0] | select(length > 0)] | unique' \
                    "$manifest" 2>/dev/null)" \
    || { print -u2 "size-preflight.zsh: marketplace manifest is not valid JSON: $manifest"; exit 3; }
  [[ "$plugins_json" != "[]" ]] \
    || { print -u2 "size-preflight.zsh: marketplace manifest lists no local plugins: $manifest"; exit 3; }
fi

# One path normalisation, shared by the shape check and the verdict, and one
# whole-segment prefix test: `under($d)` holds for $d itself and anything below
# it, so `…/templates`, `…/templates/` and `…/templates/x` all count.
typeset -r NORM='def norm: split("/") | map(select(. != "" and . != ".")) | join("/");
def under($d): ($d | rtrimstr("/")) as $r | . == $r or startswith($r + "/");'

# Shape errors are reported by name, then the verdict is computed. Everything
# happens in one jq program so the counts and the triggers cannot disagree.
local problem
problem="$(print -r -- "$inv" | jq -r "$NORM"'
  if type != "object" then "the inventory is not a JSON object"
  elif (.files | type) != "array" then "files must be an array"
  elif (.files | length) == 0 then "files must list at least one path"
  elif any(.files[]; (type != "string") or (length == 0)) then "every file must be a non-empty string"
  elif any(.files[]; startswith("/")) then "files must be repo-relative, not absolute"
  elif any(.files[]; split("/") | index("..")) then "files must not contain a .. segment"
  elif any(.files[]; norm == "") then "every file must name a path, not only . or /"
  elif has("plugins") and ((.plugins | type) != "array" or any(.plugins[]; type != "string"))
    then "plugins, when present, must be an array of strings"
  else "" end')" \
  || { print -u2 "size-preflight.zsh: could not read the inventory's shape"; exit 3; }
[[ -z "$problem" ]] || { print -u2 "size-preflight.zsh: malformed inventory: $problem"; exit 3; }

local verdict
verdict="$(print -r -- "$inv" | jq -c \
  --argjson known "$plugins_json" --argjson max "$MAX_FILES" \
  --arg tpl "$BOOTSTRAP_TEMPLATES" --arg bs "$BOOTSTRAP_SKILL" "$NORM"'
  ([.files[] | norm] | unique) as $files
  # the templates ship in this plugin, whose version bump is not a straddle
  | (($tpl | split("/")[0]) + "/.claude-plugin/plugin.json") as $tpl_manifest
  # a plugin this change creates: its own manifest is in the inventory
  | ($known + [$files[] | select(test("^[^/]+/\\.claude-plugin/plugin\\.json$")) | split("/")[0]]
     | unique) as $owners
  | [$files[] | {path: ., owner: (split("/")[0] as $s
                   | if ($owners | index($s)) then $s else null end)}] as $rows
  | [$rows[] | select(.owner != null)] as $owned
  | ($owned | group_by(.owner) | map({p: .[0].owner, n: length})) as $counts
  | ([$counts[].n] | max // 0) as $top
  | [$counts[] | select(.n == $top) | .p] as $leaders
  | (if ($leaders | length) == 1 then $leaders[0] else null end) as $primary
  | ([$owned[].owner] | unique) as $distinct
  | ((.plugins // null) as $declared
     | if $declared == null or (($declared | unique) == $distinct) then null
       else "declared plugins \($declared | unique) disagree with the derived \($distinct)" end) as $mismatch
  | [ (if ($files | length) > $max then "files" else empty end),
      (if ($distinct | length) > 1 then "plugin" else empty end),
      (if any($files[]; under($tpl))
          and any($owned[]; (.path | under($bs) or . == $tpl_manifest) | not)
       then "bootstrap-straddle" else empty end) ] as $triggers
  | { mismatch: ($mismatch // ""),
      out: { verdict: (if ($triggers | length) > 0 then "stop" else "pass" end),
             triggers: $triggers,
             files: ($files | length),
             plugins: ($distinct | length),
             primary_plugin: $primary,
             unowned: ([$rows[] | select(.owner == null)] | length) } }')" \
  || { print -u2 "size-preflight.zsh: failed to compute the verdict"; exit 3; }

# Unpack once, guarded: a jq failure here is a runtime error (exit 3), never
# jq's own status leaking out as a usage error or a stop.
local mismatch out decision
{ IFS= read -r mismatch; IFS= read -r decision; IFS= read -r out } \
  < <(print -r -- "$verdict" | jq -r '.mismatch, .out.verdict, (.out | tojson)') \
  || { print -u2 "size-preflight.zsh: failed to read the verdict"; exit 3; }
[[ -z "$mismatch" ]] || { print -u2 "size-preflight.zsh: malformed inventory: $mismatch"; exit 3; }
[[ "$decision" == pass || "$decision" == stop ]] \
  || { print -u2 "size-preflight.zsh: failed to read the verdict"; exit 3; }
print -r -- "$out"
[[ "$decision" == pass ]] && exit 0
exit 1
