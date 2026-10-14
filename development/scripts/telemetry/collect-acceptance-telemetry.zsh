#!/usr/bin/env zsh
# collect-acceptance-telemetry.zsh — collect one `telemetry/v1` record per
# settled `acceptance (<interface>)` check run of a repo, from GitHub, through
# the shared emitter (epic #741, child (e) — issue #1230).
#
# Why a collector: the acceptance stage is a GitHub Actions workflow bootstrap
# renders into the TARGET repo, not a skill on the operator's machine — when it
# runs, the emitter is absent, the runner's filesystem is ephemeral and the sink
# directory unreachable. The facts are durable in GitHub instead: each job (its
# id IS the check-run id) carries the conclusion and timing, and the
# `acceptance-report-<interface>` artifact carries the JUnit XML. This script
# reads them with `gh` and emits from the machine that has the emitter — no
# CI-side change, no vendored contract (ARCHITECTURE.md, *Acceptance telemetry
# (#1230)*).
#
# Usage:
#   collect-acceptance-telemetry.zsh --repo OWNER/NAME
#     [--telemetry-file PATH] [--telemetry-dir DIR]
#
# What it walks: the runs of the repo's `acceptance.yml` workflow created in the
# last 30 days (UTC dates; 30 days = the artifact's retention-days) — the request
# carries `created=>=<today-30d>` and an older run in the answer is still
# skipped. A run with no associated PR is skipped. Every job attempt of a run
# (`filter=all`) named `acceptance (<interface>)` whose status is `completed`
# becomes one `kind: "run"` record, `pipeline: "acceptance"`; one still in
# progress is skipped and picked up by a later collection. There is no range
# flag.
#
# Per check run: the payload comes from build-acceptance-telemetry-record.zsh
# (beside this script), fed the job JSON and the XML files of the
# `acceptance-report-<interface>` artifact the job uploaded (the run's artifact
# of that name created between the job's start and 60 s after its end). An
# artifact that is absent (404, or none uploaded), expired (410, or flagged
# `expired`), not a readable zip, or holding a report the builder cannot read or
# refuses as inconsistent yields a record whose counts, `harness` and
# `report_artifact` are null — withheld, never guessed. Envelope: `pr` = the
# run's PR, `ts` = the job's started_at, `wall_s` = completed_at − started_at
# (the CI job's real duration), `issue` and `tokens` null.
#
# Sink and idempotency: the sink is the ONE file the emitter's precedence
# resolves to — --telemetry-file, else DIR/<repo-slug>.jsonl, else the
# user-level default $HOME/.claude/telemetry/<repo-slug>.jsonl — computed by
# tlm_sink_path (telemetry-sink-lib.zsh), the function the emitter itself
# writes through, and passed to the emitter as --telemetry-file so the file
# checked and the file appended to are one. A check run whose id already appears
# as `payload.check_run_id` on a `pipeline: "acceptance"` record in THAT file is
# skipped; a record in any other file does not count. Safe to re-run and
# /loop-able.
#
# Secrets: nothing `gh` prints on stderr — where a token or the signed download
# URL an artifact's zip endpoint redirects to could appear — is ever echoed;
# only the HTTP status is read from it. `report_artifact.url` is the API
# artifact URL, never the signed one.
#
# Output: on completion, one stdout line —
#   collect-acceptance-telemetry: OWNER/NAME: collected N, skipped as already recorded N, recorded with withheld counts N
# (`withheld` counts the collected records whose counts are null).
#
# Exit codes (the collector has no host run to protect, so the telemetry
# never-fatal rule does not apply):
#   0  the collection completed — including nothing to collect, a repo with no
#      acceptance.yml workflow (its runs endpoint answers 404 while the repo
#      itself answers), and records with withheld counts
#   2  usage: no --repo, a --repo that is not OWNER/NAME, an unknown or dangling
#      flag, a positional, a --telemetry-dir that exists and is not a directory.
#      Judged before any `gh` call.
#   3  a `gh` call listing runs or jobs failed (other than the workflow's
#      404 on a repo that answers — a repo that does not answer is a failure),
#      the artifacts listing or an artifact download failed other than
#      404/410, the
#      builder failed, the emitter failed, or a tool (jq, gh, python3) or the
#      sink is unusable. It stops at the first failure with ONE stderr line
#      naming the repo, the failing endpoint or script, and the run and
#      check-run id it was processing. Records already appended stand; the
#      emitter appends nothing on failure, so no sink gains a partial line.
#      After a transient failure (gh, the emitter) a re-run resumes via
#      idempotency; a job the builder refuses refuses again on every re-run,
#      so it halts collection until its run leaves the 30-day window.
#
# Seam (tests only): ACCEPTANCE_TELEMETRY_EMITTER_BIN replaces the emitter path.

emulate -L zsh
setopt nounset pipefail extendedglob

local P=collect-acceptance-telemetry
local self_dir="${0:A:h}"
local BUILDER="$self_dir/build-acceptance-telemetry-record.zsh"
local EMITTER="${ACCEPTANCE_TELEMETRY_EMITTER_BIN:-$self_dir/emit-telemetry.zsh}"

local usage="usage: collect-acceptance-telemetry.zsh --repo OWNER/NAME [--telemetry-file PATH] [--telemetry-dir DIR]

Emits one telemetry/v1 record (pipeline \"acceptance\") per completed
acceptance (<interface>) check run of OWNER/NAME's acceptance.yml runs created in
the last 30 days, skipping check runs already recorded in the resolved sink.
Sink precedence: --telemetry-file > --telemetry-dir (DIR/<repo-slug>.jsonl)
  > \$HOME/.claude/telemetry/<repo-slug>.jsonl"

_usage_err() { print -ru2 -- "$P: $1"; print -ru2 -- "$usage"; exit 2 }
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || _usage_err "$1 requires a value"
  [[ -n "$3" && "$3" != --* ]] || _usage_err "$1 requires a non-empty value"
}

local repo="" telemetry_file="" telemetry_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) _need_val "$1" $# "${2:-}"; repo="$2"; shift 2 ;;
  --telemetry-file) _need_val "$1" $# "${2:-}"; telemetry_file="$2"; shift 2 ;;
  --telemetry-dir) _need_val "$1" $# "${2:-}"; telemetry_dir="$2"; shift 2 ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) _usage_err "unknown flag: $1" ;;
  *) _usage_err "unexpected argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || _usage_err "--repo OWNER/NAME is required"
[[ "$repo" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || _usage_err "--repo must be OWNER/NAME (got: $repo)"
[[ -z "$telemetry_dir" || ! -e "$telemetry_dir" || -d "$telemetry_dir" ]] || \
  _usage_err "--telemetry-dir is not a directory: $telemetry_dir"

# --- the one stderr line every exit 3 prints ---------------------------------

local cur_run="" cur_check=""
_fail() {  # $1 = the failing endpoint or script, $2 = what happened
  print -ru2 -- "$P: $repo: $1 failed ($2) — run ${cur_run:-none}, check run ${cur_check:-none}"
  exit 3
}

local tool=""
for tool in jq gh python3; do
  command -v "$tool" >/dev/null 2>&1 || _fail "$tool" "not found on PATH"
done
[[ -x "$EMITTER" ]] || _fail "${EMITTER:t}" "missing or not executable"

source "$self_dir/telemetry-sink-lib.zsh" || _fail "telemetry-sink-lib.zsh" "cannot be loaded"

local sink=""
sink=$(tlm_sink_path "$telemetry_file" "$telemetry_dir" "$repo") || \
  _fail "sink resolution" "HOME is not set; pass --telemetry-file or --telemetry-dir"

local tmp=""
tmp=$(mktemp -d) || _fail "mktemp" "cannot create a scratch directory"
trap 'rm -rf -- "$tmp"' EXIT

# --- check runs already recorded in THE resolved sink -------------------------

typeset -A recorded=()
local id=""
if [[ -e "$sink" ]]; then
  [[ -r "$sink" && ! -d "$sink" ]] || _fail "sink $sink" "not a readable file"
  jq -R -r 'fromjson? | objects | select(.pipeline == "acceptance")
            | (.payload | objects | .check_run_id) // empty | tostring' < "$sink" > "$tmp/ids" \
    || _fail "sink $sink" "cannot be read"
  while IFS= read -r id; do recorded[$id]=1; done < "$tmp/ids"
fi

# --- gh -----------------------------------------------------------------------
# stdout to a file; stderr to a file that is NEVER printed (a signed URL or a
# token may be in it) — only its HTTP status is read back, into gh_code.

local gh_code=""
_gh() {  # $1 = output file, rest = the gh arguments
  local out="$1"; shift
  gh_code=""
  gh "$@" > "$out" 2> "$tmp/gh.err" && return 0
  [[ "$(<"$tmp/gh.err")" =~ 'HTTP ([0-9][0-9][0-9])' ]] && gh_code="${match[1]}"
  return 1
}
_gh_detail() { if [[ -n "$gh_code" ]]; then print -r -- "HTTP $gh_code"; else print -r -- "gh exited non-zero"; fi }

local cutoff=""
cutoff=$(jq -n -r 'now - 30 * 86400 | strftime("%Y-%m-%d")') || _fail "jq" "cannot read the clock"

local -i collected=0 already=0 withheld=0
_summary() {
  print -r -- "$P: $repo: collected $collected, skipped as already recorded $already, recorded with withheld counts $withheld"
}

local ep="repos/$repo/actions/workflows/acceptance.yml/runs"
if ! _gh "$tmp/runs.json" api --paginate "$ep?created=>=$cutoff&per_page=100"; then
  [[ "$gh_code" == 404 ]] || _fail "gh api $ep" "$(_gh_detail)"
  # GitHub answers the same 404 for a missing workflow and for a repo that does
  # not exist or the token cannot see; only the first is nothing to collect
  # (AC 7). A --repo typo must not read as success on an unattended run (#2560).
  _gh "$tmp/repo.json" api "repos/$repo" || _fail "gh api repos/$repo" "$(_gh_detail)"
  _summary; exit 0
fi
jq -s -r --arg c "$cutoff" '
  [ .[] | .workflow_runs[]? | select((.created_at // "")[0:10] >= $c) ]
  | sort_by(.created_at, .id) | .[]
  | [.id, ((.pull_requests // [])[0].number // "")] | @tsv' < "$tmp/runs.json" > "$tmp/runs.tsv" \
  || _fail "gh api $ep" "unreadable response"

local row="" run="" pr="" job="" why="" f="" jstatus="" iface="" art="" aid="" an="" payload="" outcome="" ts="" wall=""
local -i rc=0
typeset -a runs_rows=() job_rows=() jargs=() xmls=()
runs_rows=("${(@f)$(cat -- "$tmp/runs.tsv")}")
for row in "${runs_rows[@]}"; do
  [[ -n "$row" ]] || continue
  run="${row%%$'\t'*}"; pr="${row#*$'\t'}"
  cur_run="$run"; cur_check=""
  [[ -n "$pr" ]] || continue   # a run with no associated PR

  ep="repos/$repo/actions/runs/$run/jobs"
  _gh "$tmp/jobs.json" api --paginate "$ep?filter=all&per_page=100" || _fail "gh api $ep" "$(_gh_detail)"
  jq -s -c '[ .[] | .jobs[]? | select((.name | type) == "string" and (.name | test("^acceptance \\(.+\\)$"))) ]
            | sort_by(.id) | .[]' < "$tmp/jobs.json" > "$tmp/jobs.lines" \
    || _fail "gh api $ep" "unreadable response"
  job_rows=("${(@f)$(cat -- "$tmp/jobs.lines")}")

  for job in "${job_rows[@]}"; do
    [[ -n "$job" ]] || continue
    id="$(print -r -- "$job" | jq -r '.id')"; cur_check="$id"
    jstatus="$(print -r -- "$job" | jq -r '.status')"
    [[ "$jstatus" == completed ]] || continue    # in progress: a later run records it
    if (( ${+recorded[$id]} )); then (( already++ )); continue; fi
    print -r -- "$job" > "$tmp/job.json"
    iface="$(print -r -- "$job" | jq -r '.name | capture("^acceptance \\((?<i>.+)\\)$").i')"
    an="acceptance-report-$iface"
    jargs=()

    # The artifact this job uploaded: listed on the run, matched by name and by
    # a creation time inside the job's own window (a re-run attempt uploads its
    # own). None, 404, 410 or expired → withheld.
    ep="repos/$repo/actions/runs/$run/artifacts"
    art=""
    if _gh "$tmp/arts.json" api --paginate "$ep?name=$(jq -n -r --arg n "$an" '$n | @uri')&per_page=100"; then
      art="$(jq -s -c --arg n "$an" --slurpfile j "$tmp/job.json" '
        def t: if type == "string" then (try fromdateiso8601 catch null) else null end;
        ($j[0].started_at | t) as $s | ($j[0].completed_at | t) as $e
        | if $s == null or $e == null then empty else
            [ .[] | .artifacts[]? | select(.name == $n)
              | select((.created_at | t) as $c | $c != null and $c >= $s and $c <= $e + 60) ]
            | sort_by(.created_at, .id) | last // empty
          end' < "$tmp/arts.json")" || _fail "gh api $ep" "unreadable response"
    else
      [[ "$gh_code" == (404|410) ]] || _fail "gh api $ep" "$(_gh_detail)"
    fi

    if [[ -n "$art" && "$(print -r -- "$art" | jq -r '.expired == true')" == false ]]; then
      aid="$(print -r -- "$art" | jq -r '.id')"
      ep="repos/$repo/actions/artifacts/$aid/zip"
      if _gh "$tmp/report.zip" api "$ep"; then
        rm -rf -- "$tmp/report"; mkdir -p -- "$tmp/report"
        # python3's zipfile refuses absolute and `..` member paths on extract.
        if python3 -I -m zipfile -e "$tmp/report.zip" "$tmp/report" >/dev/null 2>&1; then
          xmls=("$tmp"/report/**/*.xml(N.))
          if (( ${#xmls} )); then
            for f in "${xmls[@]}"; do jargs+=(--junit "$f"); done
            jargs+=(--artifact-name "$an" --artifact-url "https://api.github.com/repos/$repo/actions/artifacts/$aid")
          fi
        fi
      else
        [[ "$gh_code" == (404|410) ]] || _fail "gh api $ep" "$(_gh_detail)"
      fi
    fi

    # The payload. A report the builder refuses as inconsistent is a report
    # that could not be read: rebuilt without it, its counts are withheld.
    rc=0
    payload="$(zsh "$BUILDER" --job "$tmp/job.json" "${jargs[@]}" 2>/dev/null)" || rc=$?
    if (( rc == 1 && ${#jargs} )); then
      jargs=(); rc=0
      payload="$(zsh "$BUILDER" --job "$tmp/job.json" 2>/dev/null)" || rc=$?
    fi
    (( rc == 0 )) || _fail "${BUILDER:t}" "exit $rc"
    outcome="$(zsh "$BUILDER" --job "$tmp/job.json" "${jargs[@]}" --print-outcome 2>/dev/null)" \
      || _fail "${BUILDER:t}" "--print-outcome failed"
    print -r -- "$payload" > "$tmp/payload.json"
    ts="$(jq -r '.started_at | fromdateiso8601' < "$tmp/job.json")" || _fail "jq" "unreadable started_at"
    wall="$(jq -r '(.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)' < "$tmp/job.json")" \
      || _fail "jq" "unreadable completed_at"

    rc=0
    "$EMITTER" --pipeline acceptance --kind run --outcome "$outcome" --wall-s "$wall" --ts "$ts" \
      --repo "$repo" --pr "$pr" --payload "$tmp/payload.json" --telemetry-file "$sink" \
      > /dev/null 2> "$tmp/emit.err" || rc=$?
    if (( rc )); then
      why="$(sed -n 1p "$tmp/emit.err")"
      _fail "${EMITTER:t}" "exit $rc${why:+: $why}"
    fi
    recorded[$id]=1
    (( collected++ ))
    [[ "$(jq -r '.tests.total == null' < "$tmp/payload.json")" == true ]] && (( withheld++ ))
  done
done

cur_run=""; cur_check=""
_summary
exit 0
