#!/usr/bin/env zsh
# tokens-for-window.zsh — the real token usage of one Claude Code session over
# one time window, per model, read from the session's own transcripts (#2719,
# part 1 of #1974).
#
# A pure reader: nothing here writes a record, and nothing calls it yet —
# handing its output to the telemetry/v1 emitter is a later part of #1974.
#
# Usage:
#   tokens-for-window.zsh --start EPOCH --end EPOCH [--session-id ID] [--root DIR]
#
#   --start, --end  the half-open window [start, end), in epoch seconds.
#   --session-id    the session to read; defaults to $CLAUDE_CODE_SESSION_ID.
#   --root          the transcripts root; defaults to
#                   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}.
#
# The transcript is found by globbing <root>/projects/*/<session-id>.jsonl and
# exactly one match is required — the session's project directory is named
# after the directory it was launched from, which is the main checkout when
# this script runs in a worktree. Its subagent transcripts,
# <project-dir>/<session-id>/subagents/agent-*.jsonl, are read with it.
#
# Counting rules:
#   - Only assistant lines count, and a line whose message.model is
#     `<synthetic>` is skipped.
#   - A line's ISO-8601 timestamp is converted to epoch seconds (floored, which
#     is exact against integer bounds). A message.id belongs to the window
#     holding its FIRST line, so adjacent windows never count one message
#     twice.
#   - One message.id streams over several lines with growing usage: its count
#     is the per-field maximum over all its lines, taken once, including lines
#     at or after `end`.
#   - Field mapping (output <- message.usage.*):
#       input          <- input_tokens
#       cache_write_5m <- cache_creation.ephemeral_5m_input_tokens
#       cache_write_1h <- cache_creation.ephemeral_1h_input_tokens
#       cache_read     <- cache_read_input_tokens
#       output         <- output_tokens
#       thinking       <- output_tokens_details.thinking_tokens (0 when absent)
#   - total = input + cache_write_5m + cache_write_1h + cache_read + output over
#     every model; thinking is part of output and is never added again.
#
# Output, on stdout, is one object:
#   {"source":"transcript","coverage":"session+subagents",
#    "by_model":{"<model>":{"input":N,"cache_write_5m":N,"cache_write_1h":N,
#                           "cache_read":N,"output":N,"thinking":N}},
#    "total":N}
# or `null`. Never an estimate and never a partial sum: no session id, no
# matching transcript, more than one match, an unreadable transcript, a line
# that is not JSON anywhere but at the end of a file (a live session may be
# mid-write there), an assistant line whose timestamp cannot be read, or an
# in-window line of an unrecognised shape — a non-thinking field missing, not
# an integer or negative, or a missing message.id or model — prints `null`
# plus ONE advisory line on stderr.
#
# Privacy: only message.id, message.model, message.usage and the timestamp are
# read, and no transcript content is ever printed — the advisory lines name
# the condition, never a line.
#
# Exit codes:
#   0  a result was printed — the object or `null`
#   2  usage — an unknown flag, a missing or non-integer --start/--end, or an
#      end before the start

emulate -L zsh
setopt nounset pipefail extendedglob

local usage="usage: tokens-for-window.zsh --start EPOCH --end EPOCH [--session-id ID] [--root DIR]"
local start="" end="" sid="${CLAUDE_CODE_SESSION_ID:-}" root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h|--help) print -r -- "$usage"; exit 0 ;;
  --start|--end|--session-id|--root)
    [[ $# -ge 2 ]] || { print -u2 -- "tokens-for-window: $1 needs a value
$usage"; exit 2 }
    case "$1" in
    --start) start="$2" ;;
    --end) end="$2" ;;
    --session-id) sid="$2" ;;
    --root) root="$2" ;;
    esac
    shift 2 ;;
  *) print -u2 -- "tokens-for-window: unknown argument: $1
$usage"; exit 2 ;;
  esac
done

[[ "$start" == <-> && "$end" == <-> ]] || {
  print -u2 -- "tokens-for-window: --start and --end must be epoch seconds
$usage"; exit 2 }
(( end >= start )) || {
  print -u2 -- "tokens-for-window: --end ($end) is before --start ($start)"; exit 2 }

# not_measured <reason> — the one way out without a measurement.
not_measured() {
  print -r -- null
  print -u2 -- "tokens-for-window: $1 — tokens not measured"
  exit 0
}

command -v jq >/dev/null 2>&1 || not_measured "jq not found on PATH"
[[ -n "$sid" ]] || not_measured "no session id (CLAUDE_CODE_SESSION_ID is unset)"
# The id is spliced into a glob, so only a plain id shape is accepted.
[[ "$sid" == [A-Za-z0-9._-]## ]] || not_measured "the session id is not a plain id"

local -a matches
matches=( "$root"/projects/*/"$sid".jsonl(N.) )
(( ${#matches} > 0 )) || not_measured "no transcript for session $sid under $root/projects"
(( ${#matches} == 1 )) || not_measured "${#matches} transcripts match session $sid under $root/projects"

local -a files
files=( "$matches[1]" "${matches[1]:h}/$sid"/subagents/agent-*.jsonl(N.) )

# Per file, project each line down to the fields read, before anything else is
# kept: {t, id, model, u} for an assistant line, a `bad` marker for a line that
# is not JSON (with whether it is the file's last line), nothing otherwise.
local project='
  def ts: if type == "string"
          then (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | floor) catch null)
          else null end;
  [inputs] as $raw
  | ($raw | length) as $len
  | [ $raw | to_entries[] | .key as $i | .value as $l
      | ($l | try fromjson catch "\u0000bad") as $j
      | if $j == "\u0000bad" then
          if ($l | test("^\\s*$")) then empty else {bad: true, last: ($i == $len - 1)} end
        elif ($j | type) == "object" and $j.type == "assistant"
             and (($j.message | type) == "object")
             and $j.message.model != "<synthetic>" then
          {t: ($j.timestamp | ts), id: $j.message.id, model: $j.message.model,
           u: $j.message.usage}
        else empty end ]'

local -a projected
local f out
for f in "${files[@]}"; do
  out="$(jq -nRc "$project" < "$f" 2>/dev/null)" || not_measured "a transcript could not be read"
  projected+=( "$out" )
done

local result
result="$(print -r -- "${projected[@]}" | jq -sc --argjson s "$start" --argjson e "$end" '
  def nn: type == "number" and . >= 0 and . == floor;
  def counts: {input: .input_tokens,
               cache_write_5m: (.cache_creation | if type == "object" then .ephemeral_5m_input_tokens else null end),
               cache_write_1h: (.cache_creation | if type == "object" then .ephemeral_1h_input_tokens else null end),
               cache_read: .cache_read_input_tokens,
               output: .output_tokens,
               thinking: (.output_tokens_details | if type == "object" then (.thinking_tokens // 0) else 0 end)};
  def shape_ok: (.id | type) == "string" and (.id | length) > 0
                and (.model | type) == "string" and (.model | length) > 0
                and (.u | type) == "object"
                and (.u | counts | [.[]] | all(nn));
  (add // []) as $lines
  | if any($lines[]; .bad == true and .last == false) then {error: "a transcript line is not JSON"}
    elif any($lines[]; .bad != true and .t == null) then {error: "an assistant line has no readable timestamp"}
    else
      [$lines[] | select(.bad != true)] as $a
      # A line with no usable id cannot be grouped: unrecognised when it is in the window.
      | if any($a[]; (.id | type) != "string" and .t >= $s and .t < $e)
        then {error: "an assistant line in the window has an unrecognised shape"}
        else
          [$a[] | select((.id | type) == "string")] | group_by(.id)
          | map(sort_by(.t)) | map(select(.[0].t >= $s and .[0].t < $e)) as $groups
          | if any($groups[][]; shape_ok | not)
            then {error: "an assistant line in the window has an unrecognised shape"}
            else
              ($groups | map({model: .[0].model,
                              c: (map(.u | counts) as $cs
                                  | reduce ($cs[0] | keys_unsorted[]) as $k ({}; .[$k] = ([$cs[][$k]] | max)))})) as $msgs
              | ($msgs | group_by(.model)
                 | map({key: .[0].model,
                        value: (reduce .[].c as $c ({input: 0, cache_write_5m: 0, cache_write_1h: 0,
                                                     cache_read: 0, output: 0, thinking: 0};
                                  with_entries(.value += $c[.key])))})
                 | from_entries) as $by
              | {source: "transcript", coverage: "session+subagents", by_model: $by,
                 total: ([$by[] | .input + .cache_write_5m + .cache_write_1h + .cache_read + .output] | add // 0)}
            end
        end
    end' 2>/dev/null)" || not_measured "the transcripts could not be summed"

if [[ "$(print -r -- "$result" | jq -r 'has("error")')" == true ]]; then
  not_measured "$(print -r -- "$result" | jq -r '.error')"
fi
print -r -- "$result"
