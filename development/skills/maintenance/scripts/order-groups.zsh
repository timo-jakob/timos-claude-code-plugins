#!/usr/bin/env zsh
# Put a maintenance run's planner groups into the concern order (#3211).
#
# Usage:
#   order-groups.zsh < groups.json
#
# stdin:  the merged plan's groups — every dispatcher's `plan` entries — as one
#         JSON array of objects, each with a string `tool`. Stage 0 (the
#         coverage pre-flight) is never passed in: it runs ahead of everything.
# stdout: the same array, stably sorted by concern rank
#           security < dependencies < bugs < codequality < topic
#         with each element gaining `"concern"` (concern-of.zsh's answer for its
#         tool). Groups of one concern keep the order they came in, so each
#         planner's ranking holds inside a concern. Every other field is kept.
#
# Exit codes:
#   0  ordered array printed
#   1  internal failure (jq missing or failing)
#   2  usage: an argument was given, stdin is not one JSON array of objects
#      each with a non-empty string `tool`, or a tool concern-of.zsh does not
#      know (named on stderr)

set -uo pipefail

if (( $# != 0 )); then
  print -u2 "usage: order-groups.zsh < groups.json"
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  print -u2 "order-groups.zsh: jq not found"
  exit 1
fi

here="${0:A:h}"
input="$(cat)"

if ! jq -e -s 'length == 1 and (.[0] | type == "array"
      and all(type == "object" and (.tool | type == "string" and length > 0)))' \
      >/dev/null 2>&1 <<<"$input"; then
  print -u2 "order-groups.zsh: stdin must be one JSON array of objects, each with a non-empty string \"tool\""
  exit 2
fi

tools="$(jq -r '[.[].tool] | unique | .[]' <<<"$input")" || {
  print -u2 "order-groups.zsh: jq failed reading the tools"
  exit 1
}

# tool -> concern, one concern-of.zsh call per distinct tool
concerns='{}'
for tool in ${(f)tools}; do
  concern="$("$here/concern-of.zsh" "$tool" 2>/dev/null)" || {
    print -u2 "order-groups.zsh: unknown tool '$tool' (concern-of.zsh knows no concern for it)"
    exit 2
  }
  concerns="$(jq -c --arg t "$tool" --arg c "$concern" '. + {($t): $c}' <<<"$concerns")" || exit 1
done

# Sort on [rank, input index] so the order is stable whatever jq's sort does.
jq --argjson concerns "$concerns" '
  {security: 0, dependencies: 1, bugs: 2, codequality: 3, topic: 4} as $rank
  | to_entries
  | map(.value.concern = $concerns[.value.tool] | {i: .key, g: .value})
  | sort_by([$rank[.g.concern], .i])
  | map(.g)
' <<<"$input" || {
  print -u2 "order-groups.zsh: jq failed ordering the groups"
  exit 1
}
