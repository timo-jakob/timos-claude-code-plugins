#!/usr/bin/env zsh
# check-manifests.zsh — the claude-plugin panel's `manifest` dimension (#2008).
#
# The deterministic half of what `claude-plugin-manifest-check` used to judge in
# every round: bump presence, needless bumps, plugin.json <-> marketplace.json
# lockstep (version, plugin set, source path) and X.Y.Z well-formedness. The
# agent keeps only what needs judgment — bump SIZE and stale descriptions — as
# the `manifest_bump` dimension. This script runs on every round, delta rounds
# included, at script cost.
#
# Usage:
#   check-manifests.zsh --base <rev> --round <R>
#                       [--fix-verification <path> --carry-out <path>]
#                       [--repo <dir>]
#
# Pure: it reads only git and the working tree of --repo (default: the cwd's
# repository) — no clock, no network, no model. It prints a JSON array in the
# Review finding schema (ARCHITECTURE.md) on stdout: every finding carries
# dimension "manifest", reviewer "check-manifests.zsh" and round <R>, and its
# REAL severity — never a `proposed-severity:` line, because this script is the
# tool actually run.
#
# The six title templates, keyed by plugin name:
#   <plugin>: content changed with no version bump                         CRITICAL
#   <plugin>: plugin.json and marketplace.json versions out of lockstep    CRITICAL
#   <plugin>: listed in only one manifest                                  CRITICAL
#   <plugin>: marketplace.json source path does not match the plugin directory  CRITICAL
#   <plugin>: needless version bump (no plugin content changed)            WARNING
#   <plugin>: version is not plain X.Y.Z                                   SUGGESTION
#
# "Content" is anything under <plugin>/ outside .claude-plugin/ — skills/,
# agents/, scripts/, docs/, hooks/, templates/ alike, since an install ships all
# of it. Content changed with no bump is a no-bump finding; a bump with no
# content change is a needless one.
#
# Detection reads `git diff --name-only --no-renames <base>` plus untracked
# files, so a file moved between plugins counts as a change to BOTH. The file a
# finding names is picked from the loop's own set (`review-dispatch.zsh`
# _changed_files: the same listing with git's default rename detection), so
# `scope-findings` keeps it — a no-bump finding names the plugin's first changed
# content file in that set, since the unbumped plugin.json is by definition not
# in the diff; when the plugin's only change is a move out, it names the move's
# destination, the one path of the pair that set lists.
#
# The lockstep checks mirror development/skills/maintenance/scripts/
# gather-claude-plugin-findings.zsh (version_mismatch, missing_from_marketplace,
# missing_plugin_json) rather than sourcing it across plugins; a parity bats case
# holds the two together.
#
# Carry (#2010's split-carry map hands this script the `manifest` file): for each
# carried entry, a condition that still holds is RE-RAISED verbatim (the carried
# file, dimension and title, with the carried line or null); otherwise the entry
# is CONFIRMED at the plugin's version line. It never reports `unconfirmed`. One
# line per entry is written to --carry-out in the reviewers' carry-line format,
# followed by the triple `carried: confirmed N / re-raised M / unconfirmed 0 of
# TOTAL`; the panel appends that file to carry-lines-<R>.txt.
#
# Exit: 0 findings printed (possibly []); 2 usage — a missing or malformed flag,
# an unresolvable --base, a carry that is not a JSON array, or a carried entry
# whose dimension is not `manifest` or whose title matches no template (nothing
# is printed or written); 1 a runtime failure (jq missing, a git error, an
# unwritable --carry-out).

emulate -L zsh
setopt nounset pipefail extended_glob

readonly REVIEWER="check-manifests.zsh"
readonly MARKETPLACE=".claude-plugin/marketplace.json"
readonly T_NOBUMP="content changed with no version bump"
readonly T_LOCKSTEP="plugin.json and marketplace.json versions out of lockstep"
readonly T_ONEMANIFEST="listed in only one manifest"
readonly T_SOURCE="marketplace.json source path does not match the plugin directory"
readonly T_NEEDLESS="needless version bump (no plugin content changed)"
readonly T_XYZ="version is not plain X.Y.Z"
readonly TITLE_RE='^(.+): (content changed with no version bump|plugin\.json and marketplace\.json versions out of lockstep|listed in only one manifest|marketplace\.json source path does not match the plugin directory|needless version bump \(no plugin content changed\)|version is not plain X\.Y\.Z)$'

usage() {
  print -u2 -- "usage: check-manifests.zsh --base <rev> --round <R> [--fix-verification <path> --carry-out <path>] [--repo <dir>]"
  [[ -n "${1:-}" ]] && print -u2 -- "check-manifests: $1"
  exit 2
}

local base="" round="" fixver="" carry_out="" repo="."
while (( $# )); do
  case "$1" in
  --base | --round | --fix-verification | --carry-out | --repo)
    (( $# >= 2 )) && [[ -n "$2" ]] || usage "$1 needs a value"
    case "$1" in
    --base) base="$2" ;;
    --round) round="$2" ;;
    --fix-verification) fixver="$2" ;;
    --carry-out) carry_out="$2" ;;
    --repo) repo="$2" ;;
    esac
    shift 2 ;;
  -h | --help) usage ;;
  *) usage "unknown argument: $1" ;;
  esac
done
[[ -n "$base" ]] || usage "--base is required"
[[ "$round" == <1-> && "$round" != 0* ]] || usage "--round must be a positive integer"
if [[ -n "$fixver" && -z "$carry_out" ]] || [[ -z "$fixver" && -n "$carry_out" ]]; then
  usage "--fix-verification and --carry-out go together"
fi
command -v jq >/dev/null 2>&1 || { print -u2 -- "check-manifests: jq required, not on PATH"; exit 1 }

local top
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || usage "--repo is not inside a git work tree: $repo"
cd "$top" || exit 1
git rev-parse --verify --quiet "${base}^{commit}" >/dev/null || usage "--base does not resolve to a commit: $base"

# --- the carry is validated BEFORE anything is printed ------------------------
local carry="[]"
if [[ -n "$fixver" ]]; then
  [[ -r "$fixver" ]] || usage "--fix-verification is not readable: $fixver"
  carry=$(jq -c 'if type == "array" then . else error("not an array") end' "$fixver" 2>/dev/null) \
    || usage "--fix-verification is not a JSON array: $fixver"
  local bad
  bad=$(jq -r --arg re "$TITLE_RE" '
    [ .[] | select((.dimension // "") != "manifest"
                   or ((.title // "") | gsub("\\s+"; " ") | test($re) | not)) ]
    | first | if . == null then "" else "\(.title // "<no title>") (\(.file // "<no file>"), \(.dimension // "<no dimension>"))" end
  ' <<< "$carry") || exit 1
  [[ -z "$bad" ]] || usage "carried entry is not a manifest entry this script owns: $bad"
fi

# --- the changed-file sets (see header) ----------------------------------------
changed_files() {  # changed_files [--no-renames] → repo-root-relative paths, one per line
  { git -c core.quotePath=false diff --name-only --no-relative "$@" "$base" -- ':/' &&
    git -c core.quotePath=false ls-files --others --exclude-standard --full-name ':/'; } |
    sed 's#^\./##' | sort -u
}
local -a changed listed
changed=("${(@f)$(changed_files --no-renames)}") \
  || { print -u2 -- "check-manifests: could not compute the changed files against $base"; exit 1 }
listed=("${(@f)$(changed_files)}") \
  || { print -u2 -- "check-manifests: could not compute the changed files against $base"; exit 1 }
changed=(${changed:#})
listed=(${listed:#})
local -A moved_to  # rename source → destination, as the loop's set pairs them
local st s t
while IFS=$'\t' read -r st s t; do
  [[ "$st" == R* ]] && moved_to[$s]="$t"
done < <(git -c core.quotePath=false diff --name-status --no-relative "$base" -- ':/')

in_listed() { (( ${listed[(Ie)$1]} )) }

# --- manifest lookups ----------------------------------------------------------
local have_market=0
[[ -f "$MARKETPLACE" ]] && have_market=1

market_field() {  # market_field <name> <field> → the entry's field value, or ""
  (( have_market )) || return 0
  jq -r --arg n "$1" --arg f "$2" \
    'first(.plugins[]? | select(.name == $n)) | .[$f] // empty | tostring' "$MARKETPLACE"
}
market_has() {  # market_has <name>
  (( have_market )) || return 1
  jq -e --arg n "$1" 'any(.plugins[]?; .name == $n)' "$MARKETPLACE" >/dev/null
}
market_line() {  # market_line <name> <field> → line of <field> in <name>'s entry, or ""
  (( have_market )) || return 0
  awk -v n="$1" -v f="$2" '
    !seen && $0 ~ "\"name\"[[:space:]]*:[[:space:]]*\"" n "\"" { seen = 1; if (f == "name") { print NR; exit } next }
    seen && $0 ~ "\"" f "\"[[:space:]]*:" { print NR; exit }
  ' "$MARKETPLACE"
}
pj_line() {  # pj_line <plugin.json> → line of its "version" key, or ""
  grep -n -m1 '"version"[[:space:]]*:' "$1" 2>/dev/null | cut -d: -f1
}

# name → plugin directory, from plugin.json on disk first, then the marketplace
local -A dir_of
local pj n
for pj in */.claude-plugin/plugin.json(N); do
  n=$(jq -r '.name // empty' "$pj" 2>/dev/null) || n=""
  [[ -n "$n" ]] || n="${pj%%/*}"
  dir_of[$n]="${pj%%/*}"
done
local -a names
names=(${(k)dir_of})
if (( have_market )); then
  local mn src
  for mn in "${(@f)$(jq -r '.plugins[]?.name // empty' "$MARKETPLACE")}"; do
    [[ -n "$mn" ]] || continue
    (( ${names[(Ie)$mn]} )) || names+=("$mn")
    if [[ -z "${dir_of[$mn]:-}" ]]; then
      src=$(market_field "$mn" source)
      src="${${src#./}%/}"
      dir_of[$mn]="${src:-$mn}"
    fi
  done
fi
names=(${(o)names})

# --- detection -------------------------------------------------------------------
local -a found
emit() {  # emit <severity> <plugin> <template> <file> <line|""> <description> <fix>
  found+=("$(jq -cn --arg sev "$1" --arg title "$2: $3" --arg file "$4" --arg line "$5" \
    --arg desc "$6" --arg fix "$7" --arg rev "$REVIEWER" --argjson round "$round" '
    {severity: $sev, dimension: "manifest", file: $file,
     line: (if $line == "" then null else ($line | tonumber) end),
     title: $title, description: $desc, suggested_fix: $fix, reviewer: $rev, round: $round}')")
}

local d pjf pv mv base_pv src_raw f
local -a content shown
for n in $names; do
  d="${dir_of[$n]}"
  pjf="$d/.claude-plugin/plugin.json"
  pv="" mv=""
  [[ -f "$pjf" ]] && pv=$(jq -r '.version // empty | tostring' "$pjf" 2>/dev/null)
  if market_has "$n"; then mv=$(market_field "$n" version); fi

  if [[ -f "$pjf" ]] && ! market_has "$n"; then
    emit CRITICAL "$n" "$T_ONEMANIFEST" "$pjf" "$(pj_line "$pjf")" \
      "$n has a plugin.json but no entry in $MARKETPLACE, so the marketplace never offers it." \
      "add a $MARKETPLACE entry for $n at version ${pv:-<its plugin.json version>}"
  elif [[ ! -f "$pjf" ]] && market_has "$n"; then
    emit CRITICAL "$n" "$T_ONEMANIFEST" "$MARKETPLACE" "$(market_line "$n" name)" \
      "$MARKETPLACE lists $n but $pjf does not exist." \
      "remove the stale $n entry from $MARKETPLACE, or restore $pjf"
  elif [[ -f "$pjf" ]]; then
    if [[ "$pv" != "$mv" ]]; then
      if in_listed "$MARKETPLACE" || ! in_listed "$pjf"; then f="$MARKETPLACE"; else f="$pjf"; fi
      emit CRITICAL "$n" "$T_LOCKSTEP" "$f" \
        "$([[ "$f" == "$pjf" ]] && pj_line "$pjf" || market_line "$n" version)" \
        "$n version mismatch: plugin.json=${pv:-<none>} marketplace.json=${mv:-<none>}; installs see the marketplace version." \
        "set the $MARKETPLACE entry for $n to ${pv:-<its plugin.json version>} (plugin.json is the source of truth)"
    fi
    src_raw=$(market_field "$n" source)
    src="${${src_raw#./}%/}"
    if [[ "$src" != "$d" ]]; then
      emit CRITICAL "$n" "$T_SOURCE" "$MARKETPLACE" "$(market_line "$n" source)" \
        "the $MARKETPLACE entry for $n has source \"${src_raw:-<none>}\", but the plugin lives in $d/." \
        "set the $n entry's source to \"./$d\""
    fi
  fi

  if [[ -f "$pjf" && -n "$pv" && ! "$pv" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    emit SUGGESTION "$n" "$T_XYZ" "$pjf" "$(pj_line "$pjf")" \
      "$pjf carries version \"$pv\", which is not plain X.Y.Z semver." "use a plain X.Y.Z version"
  fi
  if [[ -n "$mv" && ! "$mv" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    emit SUGGESTION "$n" "$T_XYZ" "$MARKETPLACE" "$(market_line "$n" version)" \
      "the $MARKETPLACE entry for $n carries version \"$mv\", which is not plain X.Y.Z semver." \
      "use a plain X.Y.Z version"
  fi

  [[ -f "$pjf" ]] || continue
  base_pv=$(git show "${base}:$pjf" 2>/dev/null | jq -r '.version // empty | tostring' 2>/dev/null) || base_pv=""
  content=(${(M)changed:#$d/*})
  content=(${content:#$d/.claude-plugin/*})
  shown=(${(M)listed:#$d/*})
  shown=(${shown:#$d/.claude-plugin/*})
  (( ${#shown} )) || shown=("${moved_to[${content[1]:-}]:-${content[1]:-}}")
  if (( ${#content} )) && [[ -n "$base_pv" && "$pv" == "$base_pv" ]]; then
    emit CRITICAL "$n" "$T_NOBUMP" "${shown[1]}" "" \
      "$n content changed (${#content} file(s), first ${content[1]}) but $pjf still carries $pv, the version at $base — installs never see the change." \
      "bump $pjf and its $MARKETPLACE entry in lockstep"
  fi
  if [[ -n "$base_pv" && "$pv" != "$base_pv" ]] && (( ${#content} == 0 )); then
    emit WARNING "$n" "$T_NEEDLESS" "$pjf" "$(pj_line "$pjf")" \
      "$pjf moved $base_pv -> $pv, but nothing under $d/ outside .claude-plugin/ changed." \
      "revert the $n version bump in $pjf and $MARKETPLACE"
  fi
done

local findings
findings=$(print -rl -- $found | jq -sc '.') || exit 1

# --- carry: re-raise what still holds, confirm the rest -------------------------
if [[ -n "$fixver" ]]; then
  local -a lines
  local total=0 confirmed=0 reraised=0 entry title cfile key idx loc plugin
  local -a used
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    (( total += 1 ))
    title=$(jq -r '.title' <<< "$entry")
    cfile=$(jq -r '.file // ""' <<< "$entry")
    key=$(jq -rn --arg t "$title" '$t | ascii_downcase | gsub("\\s+"; " ")')
    # same title and file first, then same title alone
    idx=$(jq -r --arg k "$key" --arg f "${cfile#./}" --argjson used "[${(j:,:)used}]" '
      def norm: ascii_downcase | gsub("\\s+"; " ");
      [ to_entries[] | select(.key as $i | $used | index($i) | not) | select(.value.title | norm == $k) ] as $c
      | (first($c[] | select(.value.file == $f)) // first($c[]) // null) | if . == null then "" else .key end
    ' <<< "$findings") || exit 1
    if [[ -n "$idx" ]]; then
      used+=("$idx")
      findings=$(jq -c --argjson i "$idx" --argjson e "$entry" \
        '.[$i] |= (.file = $e.file | .title = $e.title | .dimension = "manifest" | .line = ($e.line // null))' \
        <<< "$findings") || exit 1
      (( reraised += 1 ))
      lines+=("carried entry \"$title\" ($cfile, manifest): re-raised (see finding)")
    else
      # validated above, so the match always holds (whitespace collapsed, as there)
      [[ "${title//[[:space:]]##/ }" =~ "$TITLE_RE" ]]
      plugin="${match[1]}"
      d="${dir_of[$plugin]:-$plugin}"
      pjf="$d/.claude-plugin/plugin.json"
      if [[ -f "$pjf" && -n "$(pj_line "$pjf")" ]]; then
        loc="$pjf:$(pj_line "$pjf")"
      elif [[ -n "$(market_line "$plugin" version)" ]] && market_has "$plugin"; then
        loc="$MARKETPLACE:$(market_line "$plugin" version)"
      else
        loc="$MARKETPLACE:1"
      fi
      (( confirmed += 1 ))
      lines+=("carried entry \"$title\" ($cfile, manifest): confirmed at $loc")
    fi
  done < <(jq -c '.[]' <<< "$carry")
  lines+=("carried: confirmed $confirmed / re-raised $reraised / unconfirmed 0 of $total")
  print -rl -- $lines > "$carry_out" || { print -u2 -- "check-manifests: cannot write --carry-out: $carry_out"; exit 1 }
fi

print -r -- "$findings"
