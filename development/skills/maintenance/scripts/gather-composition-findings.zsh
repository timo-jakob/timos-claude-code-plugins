#!/usr/bin/env zsh
# gather-composition-findings.zsh — the composition topic's finding gatherer
# (#1747, child 4 of epic #687). Emits the v2 gather payload the
# `development-composition` dispatcher consumes: `tooling_configured` /
# `findings_by_tool` / `coverage` / `notes`. A composition repo has no test
# suite of its own, so `coverage` is always null.
#
# Two tool keys, both in the topic-gather finding shape
# ({id, tool, type, severity, message, fix, files} plus tool-specific fields):
#
#   workspace_validation — runs development-composition's validate-workspace.zsh
#       over the repo's `.claude-workspace.yaml` and maps its TYPED exit, never
#       "non-zero" (ARCHITECTURE.md, `development-composition` owns):
#         0 -> no finding;
#         1 -> a `contract` finding naming the member or environment the
#              validator named (or the document-level defect), carrying its
#              error line;
#         4 -> a `manifest_missing` / `manifest_unreadable` finding — the
#              validator's stderr says which;
#         2, 3, anything else -> NOT a manifest finding. The manifest was never
#              judged, so `tooling_configured.workspace_validation` is false and
#              the validator's stderr goes into `notes`, which the dispatcher
#              escalates via human_action_required.
#   tag_bump — lists open Renovate PRs (`gh pr list --author app/renovate
#       --state open --json number,title,body,headRefName,files`) and keeps those
#       touching the root `.claude-workspace.yaml`. Each bump becomes a finding
#       naming the PR, the member and its from->to tag — one finding per member
#       when several members pin the same image. The listing is bounded
#       (`--limit`, since gh's own default is 30); a listing that fills the
#       bound says so in a note, since a truncated list must not read as whole. The PR body and title are
#       carried VERBATIM, untrimmed (the maintenance no-trim contract), and are
#       DATA: nothing here acts on them. The only values read out of the body are
#       matched against a strict image/tag charset, so a crafted body cannot put
#       arbitrary text into the finding's own message. The member is resolved
#       from the repo's OWN manifest, never from the PR; when the manifest's
#       members cannot be read, `member_resolved` is false so no one reads an
#       unattributed bump as "no member pins it". When `gh` is absent or
#       the listing fails, `tooling_configured.tag_bump` is false with a note —
#       a listing that never ran must not read as "no open bumps".
#
# The marker is `.claude-workspace.yaml` at the repo root, byte-identical in
# intent to SKILL.md's `composition-marker` recipe and detect-stack.sh's
# `is-composition-marker` block; tests/composition-topic-marker.bats derives
# the test operator and the path from all three and requires them to agree.
# Run on a repo without the marker, every tool is unconfigured and a note says
# so — the orchestrator only dispatches this gather when the marker fired.
#
# THE VALIDATOR lives in another plugin (development-composition), so it is
# located rather than assumed:
#   1. --validator <path>, when given (the test seam; also a manual override);
#   2. the repo layout — this file is development/skills/maintenance/scripts/,
#      the validator development-composition/scripts/, four levels up then over;
#   3. the installed plugin cache — this file is
#      <cache>/<marketplace>/development/<version>/skills/maintenance/scripts/,
#      so the validator is the highest-versioned (`sort -V`)
#      <cache>/<marketplace>/development-composition/<version>/scripts/, five up.
# None found is the runner-problem branch above: a note, never a finding.
#
# Usage: gather-composition-findings.zsh [--validator <path>] [<repo_path>]
#        (repo_path defaults to the current directory)
#
# Exit codes:
#   0  the payload is on stdout
#   2  usage error, or the repo argument is not a readable directory
#   3  jq is not on PATH (nothing can be emitted at all)
#   4  an internal failure — mktemp failed, or jq could not build a finding or
#      the payload; nothing is on stdout, and the invocation was not at fault

emulate -L zsh
set -euo pipefail

readonly SELF="gather-composition-findings.zsh"
readonly MANIFEST_NAME=".claude-workspace.yaml"
readonly TRIAGE_ISSUE="timo-jakob/timos-claude-code-plugins#1748"
# the most open Renovate PRs one listing reads; reaching it adds a note
readonly PR_LIMIT=1000
# the contract, by absolute URL: every finding is read inside the PRODUCT repo,
# where a relative `ARCHITECTURE.md` names that repo's own file (or none)
readonly CONTRACT_URL="https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md"

command -v jq >/dev/null 2>&1 || { print -r -u2 -- "$SELF: jq not found on PATH"; exit 3; }

local validator="" repo=""
while (( $# > 0 )); do
  case "$1" in
    --validator)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { print -r -u2 -- "$SELF: --validator needs a value"; exit 2; }
      validator="$2"; shift 2 ;;
    -*) print -r -u2 -- "$SELF: unknown flag: $1"; exit 2 ;;
    *)
      [[ -z "$repo" ]] || { print -r -u2 -- "$SELF: more than one repo path given"; exit 2; }
      repo="$1"; shift ;;
  esac
done
[[ -n "$repo" ]] || repo="."
[[ -d "$repo" && -r "$repo" && -x "$repo" ]] || { print -r -u2 -- "$SELF: not a readable directory: $repo"; exit 2; }

local -a notes=()
local wv_cfg="false" tb_cfg="false"
local wv_findings="[]" tb_findings="[]"

# --- the marker ---------------------------------------------------------------
local is_composition="false"
# gather-composition-marker:begin
if test -f "$repo/.claude-workspace.yaml"; then is_composition="true"; fi
# gather-composition-marker:end

local errf
errf="$(mktemp)" || { print -r -u2 -- "$SELF: mktemp failed"; exit 4; }
# EXIT only: a handler on INT/TERM that does not exit would let an interrupted
# gather carry on and report success
trap 'rm -f "$errf"' EXIT

# first line of the captured stderr, flattened — every note quotes one line
first_err() { head -n1 "$errf" 2>/dev/null | tr -d '\r' || true; }

if [[ "$is_composition" != "true" ]]; then
  notes+=("composition: no $MANIFEST_NAME at the repo root — not a composition repo, nothing gathered.")
else
  # --- workspace_validation ---------------------------------------------------
  if [[ -z "$validator" ]]; then
    local here="${0:A:h}" cand
    cand="$here/../../../../development-composition/scripts/validate-workspace.zsh"
    if [[ -f "$cand" ]]; then
      validator="$cand"
    else
      cand="$(print -rl -- "$here"/../../../../../development-composition/*/scripts/validate-workspace.zsh(N) \
               | sort -V | tail -n1)"
      if [[ -n "$cand" ]]; then validator="$cand"; fi
    fi
  fi

  if [[ -z "$validator" || ! -f "$validator" ]]; then
    notes+=("workspace_validation: validate-workspace.zsh not found${validator:+ at $validator} — install or update the development-composition plugin; the manifest was not judged.")
  else
    local vrc=0 line
    zsh "$validator" --repo "$repo" >/dev/null 2>"$errf" && vrc=0 || vrc=$?
    line="$(first_err)"
    line="${line#validate-workspace.zsh: }"
    case $vrc in
      0) wv_cfg="true" ;;
      1)
        wv_cfg="true"
        # the validator prints `<manifest>: <error>`; the manifest path is ours,
        # so strip it and keep the error as the validator worded it
        local err="${line#"$repo/$MANIFEST_NAME": }"
        wv_findings="$(jq -n --arg err "$err" --arg file "$MANIFEST_NAME" --arg url "$CONTRACT_URL" '
          ($err | capture("^member '\''(?<m>[^'\'']*)'\''") // {}) as $mm
          | ($err | capture("^environment '\''(?<e>[^'\'']*)'\''") // {}) as $ee
          | ($mm.m // null) as $member | ($ee.e // null) as $env
          | [{
              id: ("workspace_validation:contract:"
                   + (if $member then "member:" + $member
                      elif $env then "environment:" + $env
                      else "document" end)),
              tool: "workspace_validation", type: "contract", severity: "MAJOR",
              member: $member, environment: $env, error: $err,
              # the error already names the member or environment, as the
              # validator worded it — quoted, not re-prefixed
              message: ("`" + $file + "` violates claude-workspace/v1: " + $err),
              fix: ("Fix the manifest so validate-workspace.zsh accepts it; the contract is " + $url
                    + " (section: The `claude-workspace/v1` contract)."),
              files: [$file]
            }]')" || { print -r -u2 -- "$SELF: could not encode the workspace_validation finding"; exit 4; }
        ;;
      4)
        wv_cfg="true"
        local kind="manifest_missing"
        if [[ "$line" == "manifest not readable"* ]]; then kind="manifest_unreadable"; fi
        wv_findings="$(jq -n --arg err "$line" --arg kind "$kind" --arg file "$MANIFEST_NAME" '[{
            id: ("workspace_validation:" + $kind), tool: "workspace_validation",
            type: $kind, severity: "MAJOR", member: null, environment: null, error: $err,
            message: (if $kind == "manifest_unreadable"
                      then "`" + $file + "` exists but cannot be read — its own mode is at fault: " + $err
                      else "`" + $file + "` is missing — whatever should have written it is at fault: " + $err end),
            fix: (if $kind == "manifest_unreadable"
                  then "Make the manifest readable (check its mode and ownership)."
                  else "Restore the manifest (bootstrap writes it on the composition path)." end),
            files: [$file]
          }]')" || { print -r -u2 -- "$SELF: could not encode the workspace_validation finding"; exit 4; }
        ;;
      *)
        # 2 = the gather's own invocation, 3 = the runner's tools, anything else
        # = a tool died before the manifest was judged. None is a manifest verdict.
        notes+=("workspace_validation: the validator could not judge the manifest (exit $vrc)${line:+: $line} — a runner or invocation problem, not a manifest finding.")
        ;;
    esac
  fi

  # --- tag_bump -----------------------------------------------------------------
  if ! command -v gh >/dev/null 2>&1; then
    notes+=("tag_bump: gh not on PATH — open Renovate bump PRs were not listed.")
  else
    local prs grc=0
    prs="$(cd -- "$repo" && gh pr list --author app/renovate --state open --limit "$PR_LIMIT" \
             --json number,title,body,headRefName,files 2>"$errf")" && grc=0 || grc=$?
    if (( grc != 0 )); then
      local gline; gline="$(first_err)"
      notes+=("tag_bump: gh pr list failed (exit $grc)${gline:+: $gline} — open Renovate bump PRs were not listed.")
    elif ! print -r -- "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
      notes+=("tag_bump: gh pr list returned something other than a JSON array — open Renovate bump PRs were not listed.")
    else
      tb_cfg="true"
      if [[ "$(print -r -- "$prs" | jq 'length')" -ge "$PR_LIMIT" ]]; then
        notes+=("tag_bump: gh pr list returned $PR_LIMIT PRs, its limit — the listing may be truncated, so open bumps beyond it were not seen.")
      fi
      # the manifest's own members, image repo (tag and digest stripped) -> name.
      # Best effort: an unreadable manifest leaves bumps unattributed
      # (member_resolved false), never dropped. Only well-typed members are
      # kept — a non-string name or image is the validator's finding to report,
      # and must not crash the listing of bumps.
      local members='[]' resolved="true" yrc=0
      if command -v yq >/dev/null 2>&1; then
        members="$(yq -o=json '[.members[]]' "$repo/$MANIFEST_NAME" 2>/dev/null)" && yrc=0 || yrc=$?
        # exactly ONE document: yq prints one array per YAML document, and a
        # multi-document manifest (the validator's own contract finding) would
        # otherwise hand --argjson two JSON texts and crash the whole gather
        if (( yrc == 0 )) && print -r -- "$members" | jq -se 'length == 1 and (.[0] | type == "array")' >/dev/null 2>&1; then
          members="$(print -r -- "$members" | jq -sc '.[0] | [.[] | objects
            | select((.name | type) == "string" and (.image | type) == "string")
            | {name, image}]')" || { print -r -u2 -- "$SELF: could not read the manifest's members"; exit 4; }
        else
          members='[]'; resolved="false"
          notes+=("tag_bump: could not read the manifest's members — bumps are listed without a member.")
        fi
      else
        resolved="false"
        notes+=("tag_bump: yq not on PATH — bumps are listed without a member.")
      fi
      tb_findings="$(print -r -- "$prs" | jq --argjson members "$members" --argjson resolved "$resolved" \
          --arg file "$MANIFEST_NAME" --arg triage "$TRIAGE_ISSUE" '
        # image repo of a pinned ref: drop an @digest, then a trailing :tag
        # (a colon followed by no further slash, so a registry port survives)
        def image_repo: sub("@.*$"; "") | sub(":[^:/]*$"; "");
        def image_tag: sub("@.*$"; "") | (capture(":(?<t>[^:/]*)$").t // null);
        # every member pinning the image — several may (an api and a worker
        # built from one image), and each moves with the bump
        def members_for($dep): [ $members[] | select((.image | image_repo) == $dep) ];
        # the bumps this PR makes: Renovate table rows `| dep | … | `from` -> `to` |`,
        # else its title `Update <dep> Docker tag to v<to>`. Every captured value
        # is held to an image/tag charset — the body is untrusted text.
        def bumps:
          ( [ (.body // "") | split("\n")[]
              | capture("^\\|\\s*\\[?`?(?<dep>[A-Za-z0-9][A-Za-z0-9._/:-]*)`?\\]?[^|]*\\|.*`(?<from>[A-Za-z0-9_][A-Za-z0-9._-]*)`\\s*(->|→)\\s*`(?<to>[A-Za-z0-9_][A-Za-z0-9._-]*)`") ]
            | unique_by(.dep) ) as $rows
          | if ($rows | length) > 0 then $rows
            else [ (.title // "")
                   | capture("(?i)update (?<dep>[A-Za-z0-9][A-Za-z0-9._/:-]*) docker tag to v?(?<to>[A-Za-z0-9_][A-Za-z0-9._-]*)")
                   | . + {from: null} ]
            end;
        [ .[]
          | select(any(.files[]?; .path == $file))
          | . as $pr
          | (bumps) as $bs
          | (if ($bs | length) > 0 then $bs[] else {dep: null, from: null, to: null} end)
          | . as $b
          | (if $b.dep then members_for($b.dep) else [] end) as $ms
          | (if ($ms | length) > 0 then $ms[] else null end) as $m
          | ($b.from // (if $m then ($m.image | image_tag) else null end)) as $from
          | {
              id: ("tag_bump:pr-" + ($pr.number | tostring) + ":" + ($m.name // $b.dep // "unparsed")),
              tool: "tag_bump", type: "tag_bump", severity: "MINOR",
              pr: $pr.number, member: ($m.name // null), member_resolved: $resolved, image: $b.dep,
              from: $from, to: $b.to,
              title: $pr.title, head_ref: $pr.headRefName, body: $pr.body,
              message: (if $b.dep
                        then "Renovate PR #" + ($pr.number | tostring) + " bumps "
                             + (if $m then "member `" + $m.name + "` (" + $b.dep + ")"
                                elif $resolved then "`" + $b.dep + "` (no member of the manifest pins it)"
                                else "`" + $b.dep + "` (member not resolved — the manifest members could not be read)" end)
                             + " from " + ($from // "?") + " to " + ($b.to // "?")
                             + " in `" + $file + "`."
                        else "Renovate PR #" + ($pr.number | tostring) + " touches `" + $file
                             + "`, but its bump could not be read from its title or body." end),
              fix: ("Review PR #" + ($pr.number | tostring) + " by hand — the bump-triage agent ("
                    + $triage + ") is not built yet."),
              files: [$file]
            }
        ]')" || { print -r -u2 -- "$SELF: could not encode the tag_bump findings"; exit 4; }
    fi
  fi
fi

local notes_json='[]'
if (( ${#notes[@]} > 0 )); then
  notes_json="$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.')"
fi

jq -n \
  --argjson wv_cfg "$wv_cfg" --argjson wv "$wv_findings" \
  --argjson tb_cfg "$tb_cfg" --argjson tb "$tb_findings" \
  --argjson notes "$notes_json" '
{
  tooling_configured: { workspace_validation: $wv_cfg, tag_bump: $tb_cfg },
  findings_by_tool: ( {}
    + (if $wv_cfg then {workspace_validation: $wv} else {} end)
    + (if $tb_cfg then {tag_bump: $tb} else {} end) ),
  coverage: null,
  notes: $notes
}' || { print -r -u2 -- "$SELF: could not emit the payload"; exit 4; }
