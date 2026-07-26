#!/usr/bin/env zsh
# emit-telemetry.zsh — the ONE shared telemetry emitter for every pipeline in
# this plugin family (epic #740, child (a) — issue #1003).
#
# Why this exists: the two streams that predate it — review-loop (#566) and
# refine-issue (#579/#735) — were built by copy-adaptation. Same sink
# convention, near-identical envelope fields, duplicated zsh/jq scaffolding, no
# shared contract. Every future stream would have copied again and drifted
# further. This script owns the `telemetry/v1` envelope so no pipeline ever
# hand-rolls one; a pipeline supplies only its own `payload`.
#
# The envelope is CLOSED (exactly 14 keys, validated by validate-telemetry.zsh);
# `payload` is OPEN and belongs to the pipeline. See ARCHITECTURE.md
# ("The telemetry/v1 contract") for the normative definition.
#
# Usage:
#   emit-telemetry.zsh --pipeline NAME --outcome OUTCOME --wall-s N [OPTIONS]
#   emit-telemetry.zsh --pipeline NAME --outcome OUTCOME --kind enrichment \
#     --run-id ID [OPTIONS]
#   OPTIONS: [--repo OWNER/NAME] [--repo-dir DIR] [--repo-type T] [--issue N]
#     [--pr N] [--run-id ID] [--parent-run-id ID] [--ts EPOCH] [--tokens N]
#     [--payload FILE|-] [--telemetry-file PATH]
#
#     --pipeline  An OPEN identifier matching [A-Za-z0-9._-]+ — not a closed
#                 enum. Conventional values: review-loop | refine-issue |
#                 resolve-issue | maintenance | approve | bootstrap |
#                 acceptance | … Adding a new pipeline needs no schema change.
#     --kind      run (default) | enrichment
#     --outcome   success | parked | escalated | failed. On --kind enrichment
#                 this is the outcome of the ENRICHMENT event (were the
#                 downstream facts settled?), never a restatement of the
#                 enriched run's outcome — consumers computing run outcomes
#                 filter kind:"run".
#     --wall-s    REQUIRED for --kind run, and REJECTED for --kind enrichment
#                 (an enrichment always carries wall_s: null — it is a run
#                 measure, and a non-null one would double-count run time).
#     --run-id    REQUIRED for --kind enrichment: an enrichment record MUST
#                 carry the `run_id` of the run it enriches, because `run_id` is
#                 the join key (a minted id would be unjoinable — the record
#                 would validate cleanly and still be orphaned). For --kind run
#                 it is optional and minted when omitted.
#     --repo      the `owner/name` identity. Derived from the git remote when
#                 omitted, falling back to the repo directory basename.
#     --repo-dir  where to derive `repo` from and where the local default sink
#                 lives (default: the current directory). NOTE: this is a
#                 filesystem path — `--repo` is the owner/name identity. The two
#                 are deliberately separate flags because callers such as
#                 resolve-story-loop.zsh already use "repo" to mean a path.
#     --ts        unix seconds to stamp (default: now). Pinning it keeps tests
#                 deterministic; a caller passes its own start time.
#     --tokens    best-effort token count. Omitted → null. NEVER estimated:
#                 a withheld number beats a confidently wrong one.
#     --payload   FILE (or `-` for stdin) holding a JSON OBJECT, embedded
#                 unmodified as `payload`. Omitted → {}.
#                 On --kind enrichment the payload MUST carry a non-empty
#                 `event` naming WHICH enrichment this is (conventionally
#                 `suggestion_promotion` (#995) or `pr_outcome`). `kind` says
#                 THAT a record is an enrichment; `event` says which one, and
#                 consuming passes find their work by looking for runs that lack
#                 a success enrichment OF THEIR OWN event — so an eventless
#                 enrichment is unfindable by its own pass and reads to every
#                 other pass as "already enriched". This script does NOT enforce
#                 it and neither does the validator (`payload` is open by
#                 design, and closing it for one key would make every pipeline's
#                 payload the contract's business); it is a rule each emitting
#                 pass keeps. See ARCHITECTURE.md, "The telemetry/v1 contract".
#
# Sink precedence: --telemetry-file > <repo-dir>/.claude/telemetry/telemetry.jsonl
# (child (d) inserts --telemetry-dir between the two.) The record is printed to
# stdout BEFORE it is appended to the sink, so a downstream pipe that closes
# early (EPIPE) can never leave a record in the sink behind a non-zero exit.
#
# Exit codes (shared taxonomy with validate-telemetry.zsh, so the same class of
# failure means the same number in both):
#   0  ok
#   2  usage — caller error: unknown/missing flag, a value flag with no value,
#      an unexpected positional argument, a bad --kind/--outcome enum, a
#      --pipeline outside [A-Za-z0-9._-]+, a non-numeric/negative/out-of-range
#      numeric, --repo-dir not a directory, --wall-s on an enrichment, a
#      --payload that is a directory, missing, unreadable, or not a single JSON
#      object
#   3  internal — environment/tool failure: jq missing, a failed --payload read
#      (stdin or file) after the operand checks passed, record build failure,
#      a failed stdout write (closed pipe), an uncreatable or unappendable sink,
#      and — defensively, since the basename fallback all but guarantees an
#      identity — an underivable repo
# (1 is unused here; the validator reserves it for "contract violation".)
# On ANY non-zero exit nothing is appended to the sink — a rejected record
# never lands.

emulate -L zsh
setopt nounset pipefail

# Ignore SIGPIPE so a closed stdout (`emit … | head -1`) surfaces as a failed
# `print` this script can report, rather than killing the shell with 141 —
# without this the documented exit-3 path and its diagnostic never run.
trap '' PIPE

local SCHEMA='telemetry/v1'

local pipeline="" kind="run" outcome="" wall="" repo="" repo_dir="." repo_type=""
local issue="" pr="" run_id="" parent_run_id="" ts="" tokens="" payload_src=""
local telemetry_file=""

local usage="usage (run, the default kind):
  emit-telemetry.zsh --pipeline NAME --outcome OUTCOME --wall-s N [OPTIONS]
usage (enrichment):
  emit-telemetry.zsh --pipeline NAME --outcome OUTCOME --kind enrichment --run-id ID [OPTIONS]

  --wall-s is REQUIRED for --kind run and REJECTED for --kind enrichment;
  --run-id is REQUIRED for --kind enrichment (it is the join key).

OPTIONS: [--repo OWNER/NAME] [--repo-dir DIR] [--repo-type T] [--issue N] [--pr N]
  [--run-id ID] [--parent-run-id ID] [--ts EPOCH] [--tokens N] [--payload FILE|-]
  [--telemetry-file PATH]"

# A value flag with no value must be a usage error, not a silent "omitted".
# Coercing it to empty is worse than it looks: a dangling --telemetry-file would
# append to the DEFAULT sink and exit 0 (the record lands in the wrong file),
# and a dangling --ts would stamp "now" instead of the caller's pinned start
# time. Rejecting a `--flag`-shaped value also catches `--repo --tokens`, while
# still allowing the legitimate single-dash `--payload -`.
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || {
    print -u2 -- "emit-telemetry: $1 requires a value"; exit 2 }
  [[ "$3" != --* ]] || {
    print -u2 -- "emit-telemetry: $1 requires a value (got the flag $3)"; exit 2 }
}

# An EXPLICIT empty value is the same mistake wearing a different hat: the
# realistic shape is `--flag "$VAR"` with VAR unset in a caller's glue script.
# Left alone it reads downstream as "flag omitted", and the damage varies by
# flag — `--telemetry-file ""` writes to the DEFAULT sink, `--payload ""` drops
# the payload, `--ts ""` stamps NOW instead of the caller's pinned start time,
# `--run-id ""` mints a fresh id that can never be joined, `--parent-run-id ""`
# severs the nested-run link — every one of them exiting 0, so nothing ever
# surfaces the loss. Applied to EVERY value flag: a half-applied rule is the
# inconsistency the next caller trips on.
_need_nonempty() {  # $1 = flag, $2 = value
  [[ -n "$2" ]] || {
    print -u2 -- "emit-telemetry: $1 requires a non-empty value"; exit 2 }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --pipeline) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; pipeline="$2"; shift 2 ;;
  --kind) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; kind="$2"; shift 2 ;;
  --outcome) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; outcome="$2"; shift 2 ;;
  --wall-s) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; wall="$2"; shift 2 ;;
  --repo) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; repo="$2"; shift 2 ;;
  --repo-dir) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; repo_dir="$2"; shift 2 ;;
  --repo-type) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; repo_type="$2"; shift 2 ;;
  --issue) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; issue="$2"; shift 2 ;;
  --pr) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; pr="$2"; shift 2 ;;
  --run-id) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; run_id="$2"; shift 2 ;;
  --parent-run-id) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; parent_run_id="$2"; shift 2 ;;
  --ts) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; ts="$2"; shift 2 ;;
  --tokens) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; tokens="$2"; shift 2 ;;
  --payload) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; payload_src="$2"; shift 2 ;;
  --telemetry-file) _need_val "$1" $# "${2:-}"; _need_nonempty "$1" "$2"; telemetry_file="$2"; shift 2 ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -u2 -- "emit-telemetry: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "emit-telemetry: unexpected argument: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  print -u2 -- "emit-telemetry: jq not found on PATH"; exit 3 }

# --- envelope validation, BEFORE anything is written ------------------------

[[ -n "$pipeline" ]] || { print -u2 -- "emit-telemetry: --pipeline is required
$usage"; exit 2 }
# `pipeline` is an open identifier, but it seeds the run_id whose format IS
# contractual — so keep it to characters that format can round-trip.
[[ "$pipeline" =~ '^[A-Za-z0-9._-]+$' ]] || {
  print -u2 -- "emit-telemetry: --pipeline must match [A-Za-z0-9._-]+ (got: $pipeline)"; exit 2 }

case "$kind" in
  run|enrichment) ;;
  *) print -u2 -- "emit-telemetry: --kind must be run|enrichment (got: $kind)"; exit 2 ;;
esac

case "$outcome" in
  success|parked|escalated|failed) ;;
  "") print -u2 -- "emit-telemetry: --outcome is required (success|parked|escalated|failed)"; exit 2 ;;
  *) print -u2 -- "emit-telemetry: --outcome must be success|parked|escalated|failed (got: $outcome)"; exit 2 ;;
esac

if [[ "$kind" == "run" ]]; then
  # wall_s is REQUIRED on run records — the contract's one hard numeric promise.
  [[ -n "$wall" ]] || {
    print -u2 -- "emit-telemetry: --wall-s is required for --kind run"; exit 2 }
else
  # An enrichment joins a run by run_id; minting a fresh one would orphan it.
  [[ -n "$run_id" ]] || {
    print -u2 -- "emit-telemetry: --run-id is required for --kind enrichment (it is the join key)"; exit 2 }
  # wall_s is a RUN measure. Letting an enrichment carry one would make
  # `sum(wall_s)` double-count every enriched run unless the consumer filtered
  # `kind`, which is exactly the trap the contract's "null on enrichments" rule
  # exists to close — so enforce it rather than merely documenting it.
  [[ -z "$wall" ]] || {
    print -u2 -- "emit-telemetry: --wall-s is a run measure; it cannot be set on --kind enrichment"; exit 2 }
fi

local fname fval
for fval in "wall-s:$wall" "issue:$issue" "pr:$pr" "tokens:$tokens" "ts:$ts"; do
  fname="${fval%%:*}"; fval="${fval#*:}"
  [[ -z "$fval" || "$fval" == <-> ]] || {
    print -u2 -- "emit-telemetry: --$fname must be a non-negative integer (got: $fval)"; exit 2 }
  # zsh arithmetic is 64-bit signed; 19+ digits makes the `10#` normalization
  # below abort outright (or wrap negative), so cap the width here where it is
  # still a clean usage error.
  [[ -z "$fval" || ${#fval} -le 18 ]] || {
    print -u2 -- "emit-telemetry: --$fname is out of range (max 18 digits, got: $fval)"; exit 2 }
done

[[ -d "$repo_dir" ]] || {
  print -u2 -- "emit-telemetry: --repo-dir is not a directory: $repo_dir"; exit 2 }

[[ -n "$ts" ]] || ts=$(date +%s)

# `<->` accepts leading zeros but JSON forbids them, so `007` would reach
# --argjson and surface as the catch-all "failed to build the record". Normalize
# instead: these are already known to be digit-only.
[[ -n "$wall" ]]   && wall=$((   10#$wall ))
[[ -n "$issue" ]]  && issue=$((  10#$issue ))
[[ -n "$pr" ]]     && pr=$((     10#$pr ))
[[ -n "$tokens" ]] && tokens=$(( 10#$tokens ))
ts=$(( 10#$ts ))


# --- repo identity ----------------------------------------------------------

# Derive `owner/name` from the git remote; fall back to the repo directory
# basename (the #593 rule) so a record is never anonymous.
_derive_repo() {
  # NB: never name a local `path` in zsh — it is tied to PATH, so declaring it
  # local blanks PATH for the whole function and every external command
  # (git included) silently vanishes.
  local dir="$1" url slug owner name root
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || url=""

  # Only a HOST-based remote can yield an owner/name. A local-path or file://
  # origin has no owner, and splitting one on `/` fabricates an identity —
  # `/Users/timo/mirrors/widget.git` would become "mirrors/widget", poisoning
  # the very cross-repo grouping key this field exists to be.
  # git's own rule: a colon means scp syntax only when it PRECEDES any slash,
  # so `/Users/x/backup-10:30/widget.git` stays a local path (and falls back to
  # the basename) instead of being split into a fabricated `30/widget`.
  if [[ -n "$url" && ( "$url" == *"://"* || "${url%%/*}" == *:* ) && "$url" != file://* ]]; then
    slug="${url%/}"              # trailing slash first: ".../name.git/" would
    slug="${slug%.git}"          # otherwise keep its .git and become name.git
    local host_ok=1
    if [[ "$slug" == *"://"* ]]; then
      slug="${slug#*://}"          # strip scheme
      slug="${slug#*@}"            # strip any userinfo
      # A leading slash HERE means the authority was empty (https:///owner/name)
      # — check before stripping the host, because the host-strip below would
      # otherwise consume that slash and leave a fabricated owner/name behind.
      [[ "$slug" == /* ]] && host_ok=0
      slug="${slug#*/}"            # strip host
    elif [[ "$slug" == *\]:* ]]; then
      slug="${slug#*\]:}"          # scp-like, bracketed IPv6 host: git@[::1]:owner/name
    else
      slug="${slug#*:}"            # scp-like: git@host:owner/name
    fi
    if [[ $host_ok -eq 1 && "$slug" == */* && "$slug" != /* ]]; then
      # Deliberately the LAST TWO segments: the contract's `repo` is
      # `owner/name`, so a nested namespace (GitLab `group/subgroup/widget`)
      # is truncated to `subgroup/widget` rather than widening the field's
      # shape. GitHub — this family's norm — has no nested namespaces.
      name="${slug##*/}"
      owner="${slug%/*}"; owner="${owner##*/}"
      if [[ -n "$owner" && -n "$name" ]]; then
        print -r -- "$owner/$name"; return 0
      fi
    fi
  fi

  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || root=""
  [[ -n "$root" ]] || root="${dir:A}"
  print -r -- "${root:t}"
}

[[ -n "$repo" ]] || repo="$(_derive_repo "$repo_dir")"
[[ -n "$repo" ]] || {
  print -u2 -- "emit-telemetry: could not determine repo identity; pass --repo OWNER/NAME"; exit 3 }

# --- run_id -----------------------------------------------------------------

# <pipeline>-<epoch>-<4 hex rand>. The random suffix is drawn from urandom, NOT
# derived from the timestamp, so two runs stamped with the same pinned --ts
# still get distinct ids.
_rand4() {
  local h=""
  if [[ -r /dev/urandom ]]; then
    h=$(LC_ALL=C od -An -tx1 -N2 /dev/urandom 2>/dev/null | tr -d ' \n') || h=""
  fi
  [[ ${#h} -ge 4 ]] || h=$(printf '%04x' $(( RANDOM & 0xffff )))
  printf '%s' "${h:0:4}"
}

[[ -n "$run_id" ]] || run_id="${pipeline}-${ts}-$(_rand4)"

# --- payload ----------------------------------------------------------------

local payload='{}'
if [[ -n "$payload_src" ]]; then
  if [[ "$payload_src" == "-" ]]; then
    payload="$(cat)" || {
      print -u2 -- "emit-telemetry: failed to read --payload from stdin"; exit 3 }
  else
    # Reject only DIRECTORIES, matching the validator's operand policy — this
    # keeps the symmetric `--payload <(jq -c …)` idiom working, since a
    # /dev/fd FIFO is not a regular file.
    [[ ! -d "$payload_src" ]] || {
      print -u2 -- "emit-telemetry: --payload is a directory: $payload_src"; exit 2 }
    [[ -e "$payload_src" ]] || {
      print -u2 -- "emit-telemetry: --payload file does not exist: $payload_src"; exit 2 }
    [[ -r "$payload_src" ]] || {
      print -u2 -- "emit-telemetry: --payload file not readable: $payload_src"; exit 2 }
    payload="$(<"$payload_src")" || {
      print -u2 -- "emit-telemetry: failed to read --payload file: $payload_src"; exit 3 }
  fi
  # A single JSON OBJECT: the contract's `payload` is an object, and emitting
  # anything else would produce a record our own validator rejects.
  print -r -- "$payload" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || {
    print -u2 -- "emit-telemetry: --payload must be a single JSON object"; exit 2 }
fi

# --- build the record -------------------------------------------------------

# Nullable fields become JSON null (never the string "null", never omitted).
local issue_json='null' pr_json='null' tokens_json='null' wall_json='null'
local parent_json='null' repo_type_json='null'
[[ "$issue" == <-> ]] && issue_json="$issue"
[[ "$pr" == <-> ]] && pr_json="$pr"
[[ "$tokens" == <-> ]] && tokens_json="$tokens"
[[ "$wall" == <-> ]] && wall_json="$wall"
[[ -n "$parent_run_id" ]] && parent_json="$(jq -n --arg v "$parent_run_id" '$v')"
[[ -n "$repo_type" ]] && repo_type_json="$(jq -n --arg v "$repo_type" '$v')"

local record
record=$(jq -c -n \
  --arg schema "$SCHEMA" --arg kind "$kind" --arg run_id "$run_id" \
  --argjson parent_run_id "$parent_json" --argjson ts "$ts" \
  --arg repo "$repo" --argjson repo_type "$repo_type_json" \
  --arg pipeline "$pipeline" --argjson issue "$issue_json" --argjson pr "$pr_json" \
  --arg outcome "$outcome" --argjson wall_s "$wall_json" \
  --argjson tokens "$tokens_json" --argjson payload "$payload" \
  '{schema:$schema, kind:$kind, run_id:$run_id, parent_run_id:$parent_run_id,
    ts:$ts, repo:$repo, repo_type:$repo_type, pipeline:$pipeline,
    issue:$issue, pr:$pr, outcome:$outcome, wall_s:$wall_s,
    tokens:$tokens, payload:$payload}') || {
  print -u2 -- "emit-telemetry: failed to build the record"; exit 3 }

# --- emit, then append ------------------------------------------------------

# stdout FIRST. If this fails (EPIPE from `emit … | head -1`, a full device) the
# script exits non-zero with nothing appended, which is the documented promise.
# Appending first would let a stdout failure follow a successful append, so a
# caller retrying on non-zero would duplicate the record in an append-only sink.
# `print` reports EPIPE (`emit … | head -1`) but returns 0 on EBADF — a caller
# that hard-closed stdout — so probe fd 1 first. Both paths must exit BEFORE the
# append, or a caller retrying on non-zero would duplicate the record.
{ true >&1 } 2>/dev/null || {
  print -u2 -- "emit-telemetry: stdout is closed; refusing to emit"; exit 3 }
print -r -- "$record" || {
  print -u2 -- "emit-telemetry: failed to write the record to stdout"; exit 3 }

local sink="$telemetry_file"
[[ -n "$sink" ]] || sink="${repo_dir%/}/.claude/telemetry/telemetry.jsonl"

local sink_dir="${sink:h}"
mkdir -p "$sink_dir" 2>/dev/null || {
  print -u2 -- "emit-telemetry: cannot create sink directory: $sink_dir"; exit 3 }

# Append, never truncate.
print -r -- "$record" >> "$sink" 2>/dev/null || {
  print -u2 -- "emit-telemetry: cannot append to sink: $sink"; exit 3 }

exit 0
