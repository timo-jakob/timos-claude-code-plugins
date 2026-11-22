#!/usr/bin/env zsh
# The bug-spec/v1 block on a bug issue's body (#3212): the one place it is
# written and read. ARCHITECTURE.md (*Bug spec contract (`bug-spec/v1`)*) states
# the contract; this script is its implementation.
#
# Usage:
#   bug-spec.zsh render --analysis <file> [--body-file <file>] [--generated-at <iso-8601>]
#       Print the issue body with the bug spec written into it. <analysis> is
#       the bug-analyst agent's JSON object; --body-file is the current body
#       (absent: an empty body). An existing spec region is replaced, so a
#       re-analysis never stacks two specs; every byte outside it is kept,
#       a sentinel the reporter merely quotes included (see locate below).
#   bug-spec.zsh read [--body-file <file>]
#       Read a body (--body-file, else stdin) and print one JSON object:
#       {"block": <the bug-spec/v1 JSON mirror>, "prose_sha256": <the hash of
#       the prose region as it reads now>, "prose": <that region's text>}. A
#       caller compares the two hashes to tell whether the prose was edited
#       since the block was generated.
#
# The region, in this order, each sentinel on a line of its own — render
# appends it at the body's end; text added below it later is kept as text:
#   <!-- bug-spec:prose:start -->
#   ### Observed / ### Expected / ### Verdict / ### Fixed when   (the prose,
#   ending, when the analysis names a falsifying test, with the line
#   Falsifying test: `<its command>`)
#   <!-- bug-spec:prose:end -->
#   <details> … one ```json block, the mirror … </details>
#   <!-- bug-spec:end -->
# The hash is refine-issue's story-spec-prose-hash.zsh over the bytes between
# the two prose sentinels — the same recipe the story-spec uses.
#
# Exit codes:
#   0  printed
#   1  render: the analysis is not a usable bug-analyst object (a key missing,
#      a verdict or reclassify_as outside its enum, draft_prose lacking one of
#      the four headings), or the body's own text would hide the region it
#      gets (an unclosed code fence above it);
#      read: no spec, stderr `bug-spec: no bug spec`, or a spec region whose
#      block is missing, unparseable or not bug-spec/v1 — either way there is
#      no usable spec
#   2  usage
#   3  runtime: jq missing, an unreadable file, the prose hash failed, the
#      region could not be located or the result could not be printed

emulate -L zsh
set -uo pipefail
setopt extendedglob

me="bug-spec"
hash_script="${0:A:h}/../../refine-issue/scripts/story-spec-prose-hash.zsh"
START='<!-- bug-spec:prose:start -->'
PEND='<!-- bug-spec:prose:end -->'
END='<!-- bug-spec:end -->'
HEADINGS=('### Observed' '### Expected' '### Verdict' '### Fixed when')

usage() {
  print -u2 "usage: bug-spec.zsh render --analysis <file> [--body-file <file>] [--generated-at <iso-8601>]"
  print -u2 "       bug-spec.zsh read [--body-file <file>]"
  exit 2
}

(( $# >= 1 )) || usage
mode="$1"; shift
[[ "$mode" == render || "$mode" == read ]] || usage

analysis="" body_file="" generated_at=""
while (( $# > 0 )); do
  case "$1" in
    --analysis) (( $# >= 2 )) && [[ -n "$2" ]] || usage; analysis="$2"; shift 2 ;;
    --body-file) (( $# >= 2 )) && [[ -n "$2" ]] || usage; body_file="$2"; shift 2 ;;
    --generated-at) (( $# >= 2 )) && [[ -n "$2" ]] || usage; generated_at="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == read && -n "$analysis$generated_at" ]] && usage
[[ "$mode" == render && -z "$analysis" ]] && usage

command -v jq >/dev/null 2>&1 || { print -u2 "$me: jq not found on PATH"; exit 3; }

read_file() {
  [[ -f "$1" && -r "$1" ]] || { print -u2 "$me: cannot read: $1"; exit 3; }
  cat -- "$1"
}

if [[ -n "$body_file" ]]; then
  body="$(read_file "$body_file")" || exit 3
elif [[ "$mode" == read ]]; then
  body="$(cat)"
else
  body=""
fi
body="${body//$'\r'/}"

# The spec region of a body: print "<start> <prose-end> <end>", the line
# numbers of its three sentinels, or nothing when the body has none. The region
# is the one render writes — each sentinel on a line of its own, outside any
# closed code fence — and it is the LAST complete one: the last start sentinel
# followed by a prose-end sentinel and then an end sentinel, each the first of
# its kind after the one before. So a sentinel a reporter merely quotes — inline,
# in a code span, in a fenced block, or on a line of its own above the region
# or after it — is never taken for the region, and render keeps it as text.
locate() {
  print -r -- "$1" | awk -v S="$START" -v P="$PEND" -v E="$END" '
    function own(l, want) { sub(/^ ? ? ?/, "", l); sub(/[ \t]+$/, "", l); return l == want }
    { L[NR] = $0 }
    END {
      # mask the lines of every closed fence; an unclosed one masks nothing
      open = 0
      for (i = 1; i <= NR; i++) {
        l = L[i]; ind = match(l, /[^ ]/) - 1
        if (ind < 0 || ind > 3) continue
        t = substr(l, ind + 1)
        if (!open) {
          c = substr(t, 1, 1)
          if (c != "`" && c != "~") continue
          n = 0; while (substr(t, n + 1, 1) == c) n++
          if (n < 3 || (c == "`" && index(substr(t, n + 1), "`"))) continue
          open = i; fc = c; fn = n
        } else {
          sub(/[ \t]+$/, "", t)
          n = 0; while (substr(t, n + 1, 1) == fc) n++
          if (n >= fn && n == length(t)) { for (k = open; k <= i; k++) M[k] = 1; open = 0 }
        }
      }
      for (s = NR; s >= 1; s--) {
        if (M[s] || !own(L[s], S)) continue
        p = 0; for (i = s + 1; i <= NR; i++) if (!M[i] && own(L[i], P)) { p = i; break }
        if (!p) continue
        e = 0; for (i = p + 1; i <= NR; i++) if (!M[i] && own(L[i], E)) { e = i; break }
        if (!e) continue
        print s, p, e
        exit
      }
    }'
}

prose_hash() {
  local h
  h="$(print -r -- "$1" | zsh "$hash_script")" && [[ "$h" == [0-9a-f](#c64) ]] 2>/dev/null || {
    print -u2 "$me: the prose hash failed"
    exit 3
  }
  print -r -- "$h"
}

# ---- read ------------------------------------------------------------------

if [[ "$mode" == read ]]; then
  region="$(locate "$body")" || { print -u2 "$me: could not locate the spec region"; exit 3; }
  [[ -n "$region" ]] || { print -u2 "$me: no bug spec"; exit 1; }
  read -r s p e <<< "$region"
  lines=("${(@f)body}")
  # the prose region: the bytes between the two sentinel lines, newlines included
  if (( p > s + 1 )); then
    prose=$'\n'"${(pj:\n:)lines[s+1,p-1]}"$'\n'
  else
    prose=$'\n'
  fi
  tail_part="${(pj:\n:)lines[p+1,e-1]}"
  # the one ```json block between the prose end and the end marker
  json="$(print -r -- "$tail_part" | awk '
    /^[[:space:]]*```json[[:space:]]*$/ && !seen { on = 1; seen = 1; next }
    on && /^[[:space:]]*```[[:space:]]*$/ { on = 0; next }
    on { print }')"
  if ! block="$(print -r -- "$json" | jq -ce 'select(type == "object" and .schema == "bug-spec/v1")' 2>/dev/null)" \
      || [[ -z "$block" ]]; then
    print -u2 "$me: the bug spec's JSON block is missing, unparseable or not bug-spec/v1"
    exit 1
  fi
  now="$(prose_hash "$prose")" || exit 3
  jq -cn --argjson block "$block" --arg h "$now" --arg prose "$prose" '{block: $block, prose_sha256: $h, prose: $prose}' \
    || { print -u2 "$me: could not print the bug spec"; exit 3; }
  exit 0
fi

# ---- render ----------------------------------------------------------------

a="$(read_file "$analysis")" || exit 3
if ! print -r -- "$a" | jq -e '
    type == "object"
    and (.verdict | IN("bug", "not-a-bug"))
    and (.reclassify_as | . == null or IN("feature", "change-request"))
    and (.falsifying_test == null or (.falsifying_test | type == "object"
      and (.path | type == "string") and (.name | type == "string") and (.command | type == "string")))
    and (.repro_steps | type == "array") and (.cites | type == "array") and (.fixed_when | type == "array")
    and (.draft_prose | type == "string")' >/dev/null 2>&1; then
  print -u2 "$me: the analysis is not a usable bug-analyst object"
  exit 1
fi
prose="$(print -r -- "$a" | jq -r '.draft_prose')"
# the four headings, each on a line of its own, in order
rest="$prose"
for h in "${HEADINGS[@]}"; do
  if [[ "$rest" != (|*$'\n')"$h"($'\n'*|) ]]; then
    print -u2 "$me: draft_prose lacks the heading '$h' (in order)"
    exit 1
  fi
  rest="${rest#*"$h"}"
done
# The falsifying test's command is run by the fix step (fail-first.zsh, #3213),
# which trusts it only as this line, the hashed prose's last, carries it.
cmd="$(print -r -- "$a" | jq -r '.falsifying_test.command? // ""')"
[[ -n "$cmd" ]] && prose="${prose%%[[:space:]]#}"$'\n\n'"Falsifying test: \`$cmd\`"

# The region a previous analysis wrote is replaced; every other byte, a sentinel
# the reporter merely quotes included, is kept.
region="$(locate "$body")" || { print -u2 "$me: could not locate the spec region"; exit 3; }
if [[ -n "$region" ]]; then
  read -r s p e <<< "$region"
  lines=("${(@f)body}")
  before="${(pj:\n:)lines[1,s-1]}"
  after="${(pj:\n:)lines[e+1,-1]}"
  body="${before%%[[:space:]]#}"
  after="${after##[[:space:]]#}"
  [[ -n "$after" ]] && body="$body"$'\n\n'"$after"
fi
body="${body%%[[:space:]]#}"

h="$(prose_hash "$prose")" || exit 3
[[ -n "$generated_at" ]] || generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mirror="$(print -r -- "$a" | jq --arg h "$h" --arg at "$generated_at" '{
  schema: "bug-spec/v1",
  provenance: {generated_by: "bug-analyst via /development:maintenance", generated_at: $at, prose_sha256: $h},
  verdict, reclassify_as, falsifying_test, repro_steps, cites, fixed_when}')" || exit 3

spec_region="$START"$'\n'"$prose"$'\n'"$PEND"$'\n\n''<details>'$'\n'
spec_region+='<summary>machine-readable bug spec (<code>bug-spec/v1</code>) — generated, do not hand-edit</summary>'$'\n\n'
spec_region+='```json'$'\n'"$mirror"$'\n''```'$'\n\n''</details>'$'\n'"$END"
if [[ -n "$body" ]]; then out="$body"$'\n\n'"$spec_region"; else out="$spec_region"; fi

# The region written must be the one read finds: reporter text that would hide
# it (an unclosed code fence opened above it, say) is refused, never stacked.
want=("${(@f)out}") own_lines=("${(@f)spec_region}")
region="$(locate "$out")" || { print -u2 "$me: could not locate the spec region"; exit 3; }
if [[ "$region" != "$(( ${#want} - ${#own_lines} + 1 )) "*" ${#want}" ]]; then
  print -u2 "$me: the body's own text hides the spec region it would get; refusing to rewrite it"
  exit 1
fi
print -r -- "$out"
