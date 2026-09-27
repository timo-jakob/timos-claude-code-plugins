#!/usr/bin/env zsh
# promote.zsh — promote ONE environment of this constellation (scaffolded by
# development-composition, #1745; contract: claude-workspace/v1).
#
# A promotion records exactly which image every member runs in an environment:
# each member's pinned `image:tag` is resolved to its registry digest and the
# result is published as `promotion-<env>.json`. The deploy itself is handed to
# the `deploy/` socket, keyed on the environment's `deploy_target` — and in this
# release `none` is the only target there is, so nothing is ever deployed. The
# rule every branch below keeps: no run reports a deploy that did not happen.
#
# Usage:
#   scripts/promote.zsh --env <name> --mode push|dispatch
#                       [--manifest <path>] [--out-dir <dir>] [--sha <commit>]
#
#   --env       the environment to promote; it must be declared in the manifest
#   --mode      how the run was triggered: `push` (a merge to main) or
#               `dispatch` (a manual workflow_dispatch). It decides only what a
#               `deploy_target: none` hand-off means — see the end of the file
#   --manifest  default: .claude-workspace.yaml
#   --out-dir   where promotion-<env>.json is written (default: .)
#   --sha       the commit being promoted (default: $GITHUB_SHA, else HEAD)
#
# The digest of an image is read with
#   docker buildx imagetools inspect <image:tag> --format '{{.Manifest.Digest}}'
# — the multi-arch index digest, the one an `@sha256:` pin names.
#
# `promotes_from` is not read in this release: each environment's promotion
# resolves its members' tags afresh, so a production record is not checked
# against the digests staging recorded. A member pinned by digest is the way to
# hold an image fixed across environments until that check exists.
#
# Output: promotion-<env>.json, and — when $GITHUB_STEP_SUMMARY is set — the
# same record as a table in the job summary.
#
# Exit:
#   0  promoted, and the hand-off completed (with `deploy_target: none` in push
#      mode: recorded, nothing deployed, and the log says so)
#   1  the promotion was refused: the manifest is missing, unreadable, not a
#      single YAML document, or has no well-formed members; the environment is
#      undeclared; a member is untagged or on a floating tag; a pinned digest no
#      longer matches its tag; or the hand-off has no renderer —
#      `deploy_target: none` in dispatch mode, or any other deploy_target in
#      either mode (the record is written first in both cases)
#   2  usage error
#   3  the runner failed: a tool is missing or is not mikefarah's yq, a digest
#      could not be resolved, or the record could not be written
emulate -L zsh
setopt err_exit nounset pipefail

readonly SELF="promote.zsh"

die()   { print -r -u2 -- "$SELF: $1"; exit "${2:-1}"; }
usage() { die "$1 — usage: $SELF --env <name> --mode push|dispatch [--manifest <path>] [--out-dir <dir>] [--sha <commit>]" 2; }

env_name="" mode="" manifest=".claude-workspace.yaml" out_dir="." sha="${GITHUB_SHA:-}"
while (( $# > 0 )); do
    case "$1" in
    --env|--mode|--manifest|--out-dir|--sha)
        [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || usage "$1 needs a value"
        case "$1" in
        --env)      env_name="$2" ;;
        --mode)     mode="$2" ;;
        --manifest) manifest="$2" ;;
        --out-dir)  out_dir="$2" ;;
        --sha)      sha="$2" ;;
        esac
        shift 2 ;;
    *) usage "unknown argument: $1" ;;
    esac
done
[[ -n "$env_name" ]] || usage "--env is required"
[[ "$mode" == push || "$mode" == dispatch ]] || usage "--mode must be push or dispatch"

for tool in yq jq docker; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool" 3
done
# Debian/Ubuntu's `yq` is kislyuk's python-yq, which rejects `-o=json`; without
# this probe that runner fault would be reported as an unparsable manifest.
yq_version="$(yq --version 2>&1)" || yq_version=""
[[ "$yq_version" == *[Mm]ikefarah* || "$yq_version" == "yq version 4."* ]] \
    || die "yq is not mikefarah's Go yq (v4) — required tool unusable" 3
[[ -r "$manifest" ]] || die "manifest not found or not readable: $manifest"
[[ -d "$out_dir" ]] || die "--out-dir is not a directory: $out_dir" 2
[[ -w "$out_dir" ]] || die "--out-dir is not writable: $out_dir" 3

if [[ -z "$sha" ]]; then
    sha="$(git rev-parse HEAD 2>/dev/null)" || die "no commit to record: pass --sha, or run inside a git checkout" 2
fi
[[ "$sha" =~ '^[0-9a-f]{40}$' ]] || die "--sha must be a full 40-character commit SHA, got '$sha'" 2

# One scratch file for every tool's stderr, kept apart from what the tool prints:
# a warning on a successful run must never be read as part of the document or
# the digest.
errf="$(mktemp -t promote.XXXXXX 2>/dev/null)" || die "could not create a temporary file" 3
trap 'rm -f "$errf"' EXIT

doc="$(yq -o=json '.' "$manifest" 2>"$errf")" \
    || die "could not parse $manifest: $(tr '\n' ' ' < "$errf")"

# --- 1. every check that needs no registry, BEFORE any digest lookup ---------
# No validator runs in this repository, so the shapes the rest of the script
# relies on are checked here, each as a named refusal. An undeclared environment
# and an untagged or floating member are refusals the manifest alone decides, so
# a registry is never contacted for a run that cannot promote anything.
[[ "$(jq -s 'length' <<< "$doc")" == 1 ]] || die "$manifest must hold exactly one YAML document"
jq -e --arg e "$env_name" '.environments[$e] | type == "object" and (.deploy_target | type == "string")' \
    >/dev/null 2>&1 <<< "$doc" \
    || die "environment '$env_name' is not declared, as a mapping with a deploy_target, in $manifest — declared: $(jq -r '[.environments // {} | objects | keys_unsorted[]] | join(", ")' <<< "$doc")"

jq -e '.members | type == "array"' >/dev/null 2>&1 <<< "$doc" \
    || die "$manifest declares no members list — nothing to promote"
member_count="$(jq '.members | length' <<< "$doc")"
(( member_count > 0 )) || die "$manifest declares no members — nothing to promote"
jq -e '.members | all(type == "object" and (.name | type == "string") and (.image | type == "string"))' \
    >/dev/null 2>&1 <<< "$doc" \
    || die "$manifest: every member must be a mapping with a string name and image"

typeset -a names=() refs=() pins=()
for (( i = 0; i < member_count; i++ )); do
    name="$(jq -r --argjson i "$i" '.members[$i].name' <<< "$doc")"
    # trimmed as claude-workspace/v1 reads it: a padded tag is still that tag
    image="$(jq -r --argjson i "$i" '.members[$i].image | sub("^[[:space:]]+";"") | sub("[[:space:]]+$";"")' <<< "$doc")"
    ref="${image%%@*}"
    pin=""
    [[ "$image" == *@* ]] && pin="${image#*@}"
    # a tag is what follows the last `:` of the LAST path segment — a registry
    # port (`localhost:5000/api`) is not one
    last_segment="${ref##*/}"
    tag=""
    [[ "$last_segment" == *:* ]] && tag="${last_segment##*:}"
    [[ -n "$tag" ]] || die "member '$name': image '$image' carries no tag — every member must be pinned as image:tag"
    # the rest of the contract's image shape, as one refusal: no interior
    # whitespace, a name before the tag, and a digest suffix that is a digest
    [[ "$image" != *[[:space:]]* && -n "${last_segment%%:*}" \
       && ( "$image" != *@* || "$pin" =~ '^sha256:[0-9a-f]{64}$' ) ]] \
        || die "member '$name': image '$image' is not image:tag with an optional @sha256:<64 hex> digest"
    # the same floating tags claude-workspace/v1 refuses: a promotion of one would
    # record whatever the tag pointed at that day
    case "$tag" in
    latest|stable|edge|main|master)
        die "member '$name': image '$image' is pinned to the floating tag ':$tag' — pin an immutable tag" ;;
    esac
    names+=("$name"); refs+=("$ref"); pins+=("$pin")
done

deploy_target="$(jq -r --arg e "$env_name" '.environments[$e].deploy_target // ""' <<< "$doc")"

# --- 2. resolve every tag to its digest -----------------------------------
typeset -a resolved=()
# docker's error is quoted when a lookup fails, since an auth failure, a missing
# tag and a missing buildx call for different fixes.
for (( i = 1; i <= ${#refs}; i++ )); do
    digest="$(docker buildx imagetools inspect "${refs[i]}" --format '{{.Manifest.Digest}}' 2>"$errf")" \
        || die "member '${names[i]}': could not resolve ${refs[i]} to a digest: $(tr '\n' ' ' < "$errf")" 3
    digest="${digest//[[:space:]]/}"
    [[ "$digest" =~ '^sha256:[0-9a-f]{64}$' ]] \
        || die "member '${names[i]}': ${refs[i]} resolved to '$digest', which is not a sha256 digest" 3
    # A member already pinned by digest is recorded with that ONE digest, never
    # a second suffix appended to the first. If its tag now resolves elsewhere
    # the tag was re-pushed under the pin: refuse rather than guess which of the
    # two images the constellation was meant to run.
    if [[ -n "${pins[i]}" && "${pins[i]}" != "$digest" ]]; then
        die "member '${names[i]}': pinned digest ${pins[i]} no longer matches ${refs[i]}, which resolves to $digest"
    fi
    resolved+=("${refs[i]}@$digest")
done

# --- 3. publish the record --------------------------------------------------
record="$out_dir/promotion-$env_name.json"
members_json="$(
    for (( i = 1; i <= ${#names}; i++ )); do
        jq -n --arg name "${names[i]}" --arg image "${resolved[i]}" '{name: $name, image: $image}'
    done | jq -s '.'
)"
jq -n --arg env "$env_name" --arg sha "$sha" --arg mode "$mode" --arg target "$deploy_target" \
      --argjson members "$members_json" \
      '{environment: $env, commit: $sha, trigger: $mode, deploy_target: $target,
        deployed: false, members: $members}' > "$record" \
    || die "could not write $record" 3
print -r -- "$SELF: wrote $record"

summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && print -r -- "$1" >> "$GITHUB_STEP_SUMMARY"; return 0; }
summary "### Promotion record — \`$env_name\` @ \`$sha\`"
summary ""
summary "| member | image |"
summary "| --- | --- |"
for (( i = 1; i <= ${#names}; i++ )); do
    summary "| ${names[i]} | \`${resolved[i]}\` |"
done
summary ""

# --- 4. hand off to the deploy/ socket, keyed on deploy_target --------------
case "$deploy_target" in
none)
    if [[ "$mode" == push ]]; then
        # A merge must not turn main red for want of a renderer — but it must
        # not look like a deploy either.
        notice="nothing deployed — deploy_target: none, no renderer (#719/#720)"
        print -r -- "$SELF: $notice"
        summary "**$notice**"
        exit 0
    fi
    # A manual dispatch is a request to deploy. Failing it is the only honest
    # answer while there is nothing to deploy with.
    msg="no deploy renderer present — deploy/ is filled by #719 (compose) / #720 (kubernetes); $env_name was recorded, not deployed"
    summary "**$msg**"
    die "$msg" ;;
*)
    msg="deploy_target '$deploy_target' has no renderer in this release (#719/#720); $env_name was recorded, not deployed"
    summary "**$msg**"
    die "$msg" ;;
esac
