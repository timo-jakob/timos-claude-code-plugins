#!/usr/bin/env zsh
# check-c4-currency.zsh — resolve-issue's same-PR C4 currency check (epic #746
# child (c), #792).
#
# At step 3 (validate), resolve-issue asks: did the change I just made actually
# alter the system's STRUCTURE — and if so, is docs/architecture/c4-container.md
# still true? This comparator answers it by comparing the containers the diagram
# DECLARES against the containers detection FINDS in the working tree:
#
#   declared  ← ../bootstrap/scripts/extract-declared-containers.zsh (#790, the
#               canonical parser — this script implements no parse of its own).
#   detected  ← detect-stack.sh's `containers` + `detection_confidence` (#799),
#               passed in as --detect-json (this script runs no detection).
#
# The comparison is the SAME rule #793's c4_drift will use: join on the container
# identifier, folding case and -/_ (so a declared `web_app` matches a detected
# `web-app`). When the sets differ under a `complete` detection, the change was
# structural and the PR must revisit the Container diagram. This is a WORKING-TREE
# trigger, not the `elevated` risk gate — `elevated` means
# security/auth/public-API/migrations/concurrency, which is orthogonal to
# structure (an auth fix is elevated but structurally neutral; a new service can
# score normal). The design spec's § Epic C is amended to say so.
#
# Output (stdout, exit 0): a JSON array — the "plan", in plan-user-docs.zsh's
# shape:
#   [{"page":"docs/architecture/c4-container.md","reason":"..."}]  → revisit it.
#   []                                                             → no-op.
# The no-op REASON is reported on stderr (neutral change, or inconclusive
# detection). Honest about detection: an `inconclusive` detection NEVER demands a
# revisit, even when the sets differ — absence of detection is not evidence the
# diagram is wrong (mirrors #799's contract, so #793 and this agree).
#
# Exit codes (plan-user-docs.zsh idiom):
#   0 — the plan is on stdout ([] for a no-op).
#   1 — precondition absent: no docs/architecture/c4-container.md (the repo hasn't
#       adopted the Container diagram) — a reported no-op, not an error.
#   2 — usage error.
#   3 — the declared block is unparseable per #790's shape (propagated from the
#       parser), naming the page — a hard error, never a silent skip.
#
# Usage:
#   check-c4-currency.zsh --detect-json <detect-stack.json> [--repo <dir>]

emulate -L zsh
set -euo pipefail

local repo="." detect_json=""
while (( $# > 0 )); do
  case "$1" in
    --detect-json)
      (( $# >= 2 )) && [[ -n "$2" ]] || { print -r -u2 -- "check-c4-currency.zsh: --detect-json needs a value"; exit 2; }
      detect_json="$2"; shift 2 ;;
    --repo)
      (( $# >= 2 )) && [[ -n "$2" ]] || { print -r -u2 -- "check-c4-currency.zsh: --repo needs a non-empty value"; exit 2; }
      repo="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: check-c4-currency.zsh --detect-json <detect-stack.json> [--repo <dir>]"
      print -r -- "prints the same-PR C4 revisit plan; [] for a no-op; exit 1 when no c4-container.md."
      exit 0 ;;
    *) print -r -u2 -- "check-c4-currency.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { print -r -u2 -- "check-c4-currency.zsh: jq not found on PATH"; exit 3; }
[[ -n "$detect_json" && -f "$detect_json" && -r "$detect_json" ]] \
  || { print -r -u2 -- "check-c4-currency.zsh: --detect-json is required and must be a readable file"; exit 2; }
jq -e . "$detect_json" >/dev/null 2>&1 || { print -r -u2 -- "check-c4-currency.zsh: --detect-json is not valid JSON"; exit 3; }
# Shape gate: syntactically-valid JSON of the WRONG shape (a string .containers, or
# entries without a string .name) would make the jq extraction below abort with
# jq's own exit 5. Map any shape mismatch to the documented exit 3.
jq -e '
  ((.containers // []) | type == "array") and
  all((.containers // [])[]; type == "object" and (.name | type == "string"))
' "$detect_json" >/dev/null 2>&1 \
  || { print -r -u2 -- "check-c4-currency.zsh: --detect-json containers are not the #799 shape"; exit 3; }

# The canonical declared-container parser (#790), called cross-skill — this
# script never re-implements the parse (a second quote-aware parser would diverge
# from #793 on comma-bearing technology strings).
local extract="${0:A:h}/../../bootstrap/scripts/extract-declared-containers.zsh"
[[ -x "$extract" || -f "$extract" ]] || { print -r -u2 -- "check-c4-currency.zsh: parser not found at $extract"; exit 3; }

# Declared half. Map the parser's exit codes 1:1 (they share the idiom). Capture
# the parser's stderr and re-emit it on failure — its exit-3 message names the
# offending page/line/alias (the actionable cause), which a 2>/dev/null would drop.
local declared rc errf
errf="$(mktemp)" || { print -r -u2 -- "check-c4-currency.zsh: mktemp failed"; exit 3; }
trap 'rm -f "$errf"' EXIT
declared="$(zsh "$extract" --repo "$repo" 2>"$errf")" && rc=0 || rc=$?
case $rc in
  0) : ;;
  1) exit 1 ;;
  3) cat "$errf" >&2 || true
     print -r -u2 -- "check-c4-currency.zsh: declared C4 block is unparseable — fix docs/architecture/c4-container.md"; exit 3 ;;
  *) cat "$errf" >&2 || true
     print -r -u2 -- "check-c4-currency.zsh: extract-declared-containers.zsh failed (exit $rc)"; exit 3 ;;
esac

# Detected half + confidence. A detect JSON with NO detection_confidence key is
# not evidence of a complete detection — default to inconclusive (safe no-op),
# never to an optimistic "complete" that would demand a revisit from zero evidence.
local confidence
confidence="$(jq -r '.detection_confidence // "inconclusive"' "$detect_json")"

# A revisit is demanded ONLY on a positively `complete` detection. `inconclusive`
# (or any non-complete/unknown value — an unknown token is not evidence of a
# complete detection either) NEVER demands one: absence of detection is not
# evidence the diagram is wrong. Report and no-op (mirrors #799 / #793).
if [[ "$confidence" != "complete" ]]; then
  print -r -u2 -- "check-c4-currency.zsh: detection is '$confidence' (not 'complete') — no C4 revisit demanded."
  print -r -- "[]"
  exit 0
fi

# Fold both sides to the alias character class and compare as sets. The fold must
# match #791's seeder (c4_alias: lowercase, every char outside [a-z0-9_-] → _), or
# a detected name with a space/dot (e.g. "My Web App" → seeded `my_web_app`) would
# fold to a different token than its own seeded alias and report a FALSE structural
# change on a repo the pipeline just seeded. gsub("[^a-z0-9_]";"_") subsumes the
# case + -/_ rule and folds spaces/dots too. #793's c4_drift uses the identical fold.
local declared_set detected_set
declared_set="$(print -r -- "$declared" | jq -c '[.[].alias | ascii_downcase | gsub("[^a-z0-9_]";"_")] | unique')"
detected_set="$(jq -c '[(.containers // [])[].name | ascii_downcase | gsub("[^a-z0-9_]";"_")] | unique' "$detect_json")"

if [[ "$declared_set" == "$detected_set" ]]; then
  print -r -u2 -- "check-c4-currency.zsh: no structural change — declared containers match detected."
  print -r -- "[]"
  exit 0
fi

# Structural change under a complete detection → revisit the Container diagram.
local reason
reason="declared containers (${declared_set}) differ from detected (${detected_set}) — the change was structural; update the Container diagram."
jq -cn --arg r "$reason" '[{page:"docs/architecture/c4-container.md", reason:$r}]'
exit 0
