#!/usr/bin/env zsh
# extract-declared-containers.zsh — the canonical parser for the c4/v1
# declared-container shape (epic #746 child (a), #790).
#
# The C4 documentation machinery compares the containers a repo *declares* (in
# its Mermaid `C4Container` diagram) against the containers #799's detector
# *finds* in the tree. "Declared" is only mechanically comparable if it has a
# parseable shape — so this one script owns the parse, and every consumer CALLS
# it rather than re-implementing it:
#
#   - (c) #792  development/skills/resolve-issue/scripts/check-c4-currency.zsh
#   - (d) #793  development/skills/maintenance/scripts/gather-docs-findings.zsh
#
# Two independent quote-aware parsers would diverge on the comma-in-quoted-field
# case (Mermaid's own canonical labels use "Java, Spring MVC"), so there is only
# one. The full contract — membership, per-entry fields, lexical rules — lives in
# ARCHITECTURE.md ("C4 architecture docs contract", c4/v1); this is its executable
# half.
#
# What counts as a declared container (see the contract for the rationale):
#   - `Container`, `ContainerDb`, `ContainerQueue` entries inside the file's
#     `C4Container` fenced block, at ANY boundary nesting depth
#     (System_Boundary / Container_Boundary / Enterprise_Boundary / Node are
#     grouping, never a membership filter).
#   - The `_Ext` variants, and every `System*` / `Person*` / `Component*` entry,
#     are excluded — an external dependency drawn in the diagram is deliberately
#     invisible here (we do not build it, so #799 can never detect it).
#
# Per-entry shape: `Container(<alias>, "<label>", "<technology>")` with an
# optional 4th `"<description>"` argument. `alias` is an unquoted identifier and
# the join key; `label` / `technology` / `description` are double-quoted (commas
# are legal inside the quotes, so the parse is quote-aware). One entry per line,
# no line breaks inside the parens.
#
# Output (stdout, exit 0): a JSON array of
#   {alias, label, technology, description}
# in document order, with `description: null` when the 4th argument is absent.
# The declared side says `label`; #799's detected side says `name` — distinct
# vocabularies on purpose. The join is declared.alias <-> detected.name, folded
# on case and -/_ at COMPARISON time (the fold is the consumers' job; this parser
# emits the alias verbatim).
#
# Exit codes (mirroring plan-user-docs.zsh's idiom, which #792 already reuses):
#   0 — success, the declared set is on stdout ([] for a block with no
#       in-scope containers).
#   1 — precondition absent: no c4-container.md to read (the repo hasn't adopted
#       the Container diagram yet) — a reported no-op, NOT an error.
#   2 — usage error (bad flag / missing or empty value).
#   3 — unparseable declared block, unreadable target, or runtime error — never a
#       silent skip and never a partial set; the page is named on stderr.
#
# Usage:
#   extract-declared-containers.zsh [--repo <dir>] [--file <c4-container.md>]
#     --repo <dir>   repo root; the target is <dir>/docs/architecture/c4-container.md
#                    (default: the current directory).
#     --file <path>  parse this file directly instead of the default target
#                    (used by the bats fixtures).

emulate -L zsh
set -euo pipefail

local repo="." file=""
while (( $# > 0 )); do
  case "$1" in
    --repo)
      # short-circuit keeps $2 from tripping nounset when it is absent
      (( $# >= 2 )) && [[ -n "$2" ]] || {
        print -r -u2 -- "extract-declared-containers.zsh: --repo needs a non-empty value"; exit 2; }
      repo="$2"; shift 2 ;;
    --file)
      (( $# >= 2 )) && [[ -n "$2" ]] || {
        print -r -u2 -- "extract-declared-containers.zsh: --file needs a non-empty value"; exit 2; }
      file="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: extract-declared-containers.zsh [--repo <dir>] [--file <c4-container.md>]"
      print -r -- "prints the declared container set as a JSON array; exit 1 when no c4-container.md."
      exit 0 ;;
    *) print -r -u2 -- "extract-declared-containers.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  print -r -u2 -- "extract-declared-containers.zsh: jq not found on PATH"; exit 3; }

local target
if [[ -n "$file" ]]; then target="$file"; else target="$repo/docs/architecture/c4-container.md"; fi
# Precondition: the container page must EXIST — its absence is a reported no-op
# (exit 1, "the repo hasn't adopted the C4 Container diagram yet"). But a target
# that exists and cannot be read (a directory, a permissions failure, a file
# removed between here and the read) is NOT non-adoption — it is a runtime error
# (exit 3, naming the page), so consumers never misread a broken diagram as clean.
# `-e` follows symlinks, so a DANGLING symlink is absent to `-e` yet clearly not
# "unadopted" — `-L` catches it so it falls through to the readable-file check
# (exit 3), never a benign exit-1 no-op that hides a broken page from consumers.
[[ -e "$target" || -L "$target" ]] || exit 1
{ [[ -f "$target" && -r "$target" ]] } || {
  print -r -u2 -- "extract-declared-containers.zsh: cannot read $target"; exit 3; }
local content
content="$(<"$target")" || {
  print -r -u2 -- "extract-declared-containers.zsh: cannot read $target"; exit 3; }

# A valid in-scope entry: one of the three membership keywords, an unquoted
# alias, then quoted label + technology, then an optional quoted description.
# The quoted fields are matched as "[^"]*", so a comma INSIDE the quotes stays
# part of the field — the whole point of a quote-aware parse.
local entry_re='^[[:space:]]*(ContainerDb|ContainerQueue|Container)[[:space:]]*\(([A-Za-z0-9_-]+)[[:space:]]*,[[:space:]]*"([^"]*)"[[:space:]]*,[[:space:]]*"([^"]*)"([[:space:]]*,[[:space:]]*"([^"]*)")?[[:space:]]*\)[[:space:]]*;?[[:space:]]*$'
# A line that OPENS a membership entry: one of the keywords followed by `(`, a
# space, or end-of-line. It matches the valid entries above AND the malformed
# ones (bare label, line-broken, a paren typo'd to a space) — but NOT the
# `_Ext`/`_Boundary` variants, whose next char is `_`. A line matching this but
# NOT entry_re is a hard error (exit 3), never a silent skip that would drop a
# real container and yield a partial set.
local prefix_re='^[[:space:]]*(ContainerDb|ContainerQueue|Container)([[:space:]]|\(|$)'
# A fenced-code delimiter, capturing its backtick run so a closing fence can be
# required to be at least as long as its opener (CommonMark) — otherwise a
# 4-backtick block wrapping an illustrative ```mermaid example would desync a
# blind ``` parity toggle.
local fence_re='^[[:space:]]*(`{3,})[[:space:]]*(.*)$'

local -a entries
local -A seen_alias
local in_fence=0 this_mermaid=0 found_block=0 fence_len=0
local -a buf
local line ticks rest
# Declared ONCE, up front: re-running `local name` at script (non-function)
# scope on a name that already holds a value makes zsh print `name=value` to
# stdout (it lists the parameter), which would corrupt the JSON output. So the
# per-block loop below assigns these, never re-declares them.
local isC4 b l alias label tech descgroup desc obj

for line in "${(@f)content}"; do
  if [[ "$line" =~ $fence_re ]]; then
    ticks="${match[1]}"; rest="${match[2]:-}"
    if (( in_fence == 1 )) && (( ${#ticks} >= fence_len )) && [[ -z "${rest//[[:space:]]/}" ]]; then
      # a valid closing fence — process it if it was a C4Container mermaid block
      if (( this_mermaid == 1 )); then
        isC4=0
        for b in "${buf[@]}"; do
          if [[ "$b" =~ '^[[:space:]]*C4Container([[:space:]]|$)' ]]; then isC4=1; break; fi
        done
        if (( isC4 == 1 )); then
          # The contract speaks of THE C4Container block (singular). A second
          # qualifying block would silently merge two declared sets — refuse it.
          if (( found_block == 1 )); then
            print -r -u2 -- "extract-declared-containers.zsh: multiple C4Container blocks in $target"; exit 3
          fi
          found_block=1
          for l in "${buf[@]}"; do
            if [[ "$l" =~ $entry_re ]]; then
              alias="${match[2]}"; label="${match[3]}"; tech="${match[4]}"
              descgroup="${match[5]:-}"; desc="${match[6]:-}"
              if [[ -n "${seen_alias[$alias]:-}" ]]; then
                print -r -u2 -- "extract-declared-containers.zsh: duplicate alias '$alias' in $target"; exit 3
              fi
              seen_alias[$alias]=1
              if [[ -n "$descgroup" ]]; then
                obj="$(jq -cn --arg a "$alias" --arg l "$label" --arg t "$tech" --arg d "$desc" \
                  '{alias:$a,label:$l,technology:$t,description:$d}')" || {
                  print -r -u2 -- "extract-declared-containers.zsh: jq failed on entry '$alias' in $target"; exit 3; }
              else
                obj="$(jq -cn --arg a "$alias" --arg l "$label" --arg t "$tech" \
                  '{alias:$a,label:$l,technology:$t,description:null}')" || {
                  print -r -u2 -- "extract-declared-containers.zsh: jq failed on entry '$alias' in $target"; exit 3; }
              fi
              entries+=("$obj")
            elif [[ "$l" =~ $prefix_re ]]; then
              print -r -u2 -- "extract-declared-containers.zsh: malformed container entry in $target: ${l#"${l%%[![:space:]]*}"}"
              exit 3
            fi
            # else: boundary / Rel / System* / Person* / Component* / blank — skip
          done
        fi
      fi
      in_fence=0; this_mermaid=0; buf=(); fence_len=0
      continue
    elif (( in_fence == 0 )); then
      # an opening fence
      in_fence=1; buf=(); fence_len=${#ticks}
      # strip all whitespace so ```mermaid and ``` mermaid both classify
      if [[ "${rest//[[:space:]]/}" == mermaid* ]]; then this_mermaid=1; else this_mermaid=0; fi
      continue
    fi
    # else: a fence-looking line inside a fence that is not a valid close
    # (shorter run, or carrying an info string) — fall through, treat as content.
  fi
  if (( in_fence == 1 && this_mermaid == 1 )); then
    buf+=("$line")
  fi
done

# An unterminated trailing mermaid fence never reached its close, so its buffered
# block was not processed. CommonMark runs it to EOF (GitHub still renders it), so
# distinguish it from a genuinely blockless page — the fence is the defect, not a
# missing block. Still exit 3 (non-conformant), but name the real cause.
if (( in_fence == 1 && this_mermaid == 1 )); then
  for b in "${buf[@]}"; do
    if [[ "$b" =~ '^[[:space:]]*C4Container([[:space:]]|$)' ]]; then
      print -r -u2 -- "extract-declared-containers.zsh: unterminated mermaid fence in $target"; exit 3
    fi
  done
fi

# A present-but-blockless page is non-conformant, not an empty set: the contract
# REQUIRES a C4Container block. Name the page (exit 3), never a silent skip.
if (( found_block == 0 )); then
  print -r -u2 -- "extract-declared-containers.zsh: no C4Container block found in $target"; exit 3
fi

if (( ${#entries} == 0 )); then
  print -r -- "[]"
else
  printf '%s\n' "${entries[@]}" | jq -cs '.' || {
    print -r -u2 -- "extract-declared-containers.zsh: jq failed assembling output for $target"; exit 3; }
fi
exit 0
