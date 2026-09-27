#!/usr/bin/env zsh
# scaffold-composition.zsh — write the composition repo-type skeleton into a
# repository, judging its manifest with validate-workspace.zsh first
# (issue #1745, child 2 of epic #687). /development:bootstrap runs it on its
# composition path (§3m).
#
# It writes exactly this skeleton, and nothing else:
#
#   .claude-workspace.yaml               members + `staging` and `production`
#   .github/workflows/promote-to-prod.yml
#   scripts/promote.zsh                  the script that workflow calls
#   deploy/README.md                     documented empty socket (#719/#720)
#   e2e/README.md                        documented empty socket (#719/#720)
#   .maintenance.yml                     `primary: composition`
#
# No compose or Kubernetes manifest, no E2E harness and no validator workflow:
# those are epic #687's stated boundary, not omissions.
#
# The manifest is judged BEFORE anything is written: a new one is rendered to a
# temporary file beside its target and moved into place only once the validator
# accepts it, so a refused manifest leaves the repository untouched and a
# corrected re-run starts clean. An existing file is never overwritten — it is
# reported as kept, so a re-run is safe and bootstrap's own idempotency rules
# decide what to do about a difference. A kept manifest is judged in place.
#
# Usage:
#   scaffold-composition.zsh --repo <dir> --member <spec> [--member <spec>]...
#
#   --repo    the repository root to scaffold (must exist)
#   --member  one constellation member, as comma-separated key=value pairs with
#             every key required:
#               name=orders-api,repo=acme/orders-api,role=rest-api,
#               contract=contracts/v1/openapi.yaml,image=ghcr.io/acme/orders-api:1.5.0
#             Required when the repo has no .claude-workspace.yaml yet; refused
#             when it has one, since the kept manifest would silently ignore it.
#
# Both environments are scaffolded at `deploy_target: none` — the only value
# claude-workspace/v1 accepts until the #719/#720 renderers land — with
# `staging` promoting from nothing and `production` from `staging`.
#
# A kept manifest must also declare the chain the scaffolded workflow promotes —
# `staging` from nothing, `production` from `staging`, each with the
# github_environment of the same name — since promote-to-prod.yml binds those
# two GitHub Environments; any other valid shape is refused rather than
# scaffolded next to a workflow that cannot run, or runs ungated.
#
# Output: one `wrote <path>` or `kept <path> (exists)` line per file, then the
# validator's verdict line. A refusal names the manifest as `new` (the members
# given) or `kept` (the repository's own file) — whose manifest it is about.
#
# Exit — the validator's typed exits, mapped as ARCHITECTURE.md's
# "Bootstrap's branch" states (a caller must never report success for a
# manifest no run judged):
#   0  scaffolded, and validate-workspace.zsh exited 0 on the manifest
#   1  the manifest violates claude-workspace/v1, or a kept one does not declare
#      the staging -> production chain — the named error is quoted on stderr;
#      nothing was written
#   2  usage error in THIS script's invocation
#   3  the environment failed: a missing or non-mikefarah `yq`, a missing `jq`,
#      a file that could not be written, or the validator exiting 2, 3 or any
#      status it does not define. Before the verdict the manifest was never
#      judged; a write that fails AFTER it says so, and names what is on disk
#   4  the validator could not find or read the manifest
emulate -L zsh
setopt err_exit nounset pipefail

readonly SELF="scaffold-composition.zsh"
readonly HERE="${0:A:h}"
readonly TEMPLATES="${HERE:h}/templates"
readonly VALIDATOR="$HERE/validate-workspace.zsh"
readonly -a MEMBER_KEYS=(name repo role contract image)
readonly -a FIXED_FILES=(.github/workflows/promote-to-prod.yml scripts/promote.zsh
                         deploy/README.md e2e/README.md .maintenance.yml)

die()   { print -r -u2 -- "$SELF: $1"; exit "${2:-1}"; }
usage() { die "$1 — usage: $SELF --repo <dir> --member name=…,repo=…,role=…,contract=…,image=… [--member …]" 2; }

repo=""
typeset -a member_specs=()
while (( $# > 0 )); do
    case "$1" in
    --repo|--member)
        [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || usage "$1 needs a value"
        if [[ "$1" == --repo ]]; then repo="$2"; else member_specs+=("$2"); fi
        shift 2 ;;
    *) usage "unknown argument: $1" ;;
    esac
done
[[ -n "$repo" ]] || usage "--repo is required"
[[ -d "$repo" ]] || usage "--repo is not a directory: $repo"

for tool in yq jq; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool" 3
done
# The same probe the validator makes, for the same reason: Debian/Ubuntu's `yq`
# is kislyuk's python-yq, which rejects the `-p=json` rendering below — and its
# exit status would otherwise read as one of this script's typed codes.
yq_version="$(yq --version 2>&1)" || yq_version=""
[[ "$yq_version" == *[Mm]ikefarah* || "$yq_version" == "yq version 4."* ]] \
    || die "yq is not mikefarah's Go yq (v4) — required tool unusable" 3

manifest="$repo/.claude-workspace.yaml"
if [[ -e "$manifest" ]]; then
    (( ${#member_specs} == 0 )) \
        || usage "$manifest already exists — --member would be ignored; edit the manifest instead"
else
    (( ${#member_specs} > 0 )) || usage "at least one --member is required to write $manifest"
fi

# --- parse the members ------------------------------------------------------
# In the shell, not a jq call per pair: every value then reaches jq exactly once,
# as NUL-separated input rather than as an argument, so no value is ever read
# as one of jq's own options.
typeset -a member_args=()
for spec in "${member_specs[@]}"; do
    typeset -A member=()
    for pair in "${(@s:,:)spec}"; do
        [[ "$pair" == *=* ]] || usage "member '$spec': '$pair' is not key=value"
        key="${pair%%=*}"
        (( ${MEMBER_KEYS[(Ie)$key]} > 0 )) \
            || usage "member '$spec': unknown key '$key' (expected: ${(j:, :)MEMBER_KEYS})"
        (( ${+member[$key]} == 0 )) || usage "member '$spec': key '$key' given twice"
        member[$key]="${pair#*=}"
    done
    for key in $MEMBER_KEYS; do
        (( ${+member[$key]} )) || usage "member '$spec': missing key '$key'"
    done
    # in the contract's field order, whatever order the spec gave
    for key in $MEMBER_KEYS; do
        member_args+=("${member[$key]}")
    done
done

# --- the manifest: render, then judge, then place ---------------------------
origin="kept"
tmp=""
trap 'if [[ -n "$tmp" ]]; then rm -f "$tmp"; fi' EXIT
if [[ ! -e "$manifest" ]]; then
    origin="new"
    tmp="$(mktemp "$repo/.claude-workspace.yaml.scaffold.XXXXXX" 2>/dev/null)" \
        || die "could not create a temporary file in $repo" 3
    # Built as JSON and converted with yq, so a value is always quoted as YAML
    # needs it — never pasted into a YAML string by hand.
    {
        print -r -- "# The constellation manifest — contract: claude-workspace/v1 (development-composition)."
        print -r -- "# Every member is pinned by tag; promotion resolves each to its digest (scripts/promote.zsh)."
        printf '%s\0' "${member_args[@]}" \
        | jq -Rs 'split("\u0000")[:-1] as $v
               | { members: [range(0; $v | length; 5) as $i
                             | {name: $v[$i], repo: $v[$i+1], role: $v[$i+2],
                                contract: $v[$i+3], image: $v[$i+4]}],
                   environments: {
                     staging:    {github_environment: "staging",    promotes_from: null,      deploy_target: "none"},
                     production: {github_environment: "production", promotes_from: "staging", deploy_target: "none"}
                   } }' \
            | yq -p=json -o=yaml -P '.'
    } > "$tmp" || die "could not render the manifest into $tmp" 3
fi

# err_exit must not end the run on the validator's non-zero exit: that status
# IS the verdict, and each one means something different to bootstrap.
set +e
verdict="$(zsh "$VALIDATOR" --manifest "${tmp:-$manifest}" 2>&1)"
rc=$?
set -e
# the verdict names the file it judged; name the one the user will see
[[ -n "$tmp" ]] && verdict="${verdict//$tmp/$manifest}"
case $rc in
0) : ;;
1) die "the manifest violates claude-workspace/v1 ($origin .claude-workspace.yaml; nothing was written): $verdict" 1 ;;
4) die "validate-workspace.zsh could not read the manifest ($origin .claude-workspace.yaml): $verdict" 4 ;;
2) die "validate-workspace.zsh rejected its invocation (exit 2) — the manifest was never judged: $verdict" 3 ;;
*) die "validate-workspace.zsh could not run (exit $rc) — the manifest was never judged; escalate the environment: $verdict" 3 ;;
esac

if [[ "$origin" == kept ]]; then
    jq -e '.environments.staging.github_environment == "staging"
           and .environments.staging.promotes_from == null
           and .environments.production.github_environment == "production"
           and .environments.production.promotes_from == "staging"' \
        >/dev/null 2>&1 <<< "$(yq -o=json '.' "$manifest")" \
        || die "the kept .claude-workspace.yaml does not declare staging (github_environment: staging, promotes_from: null) and production (github_environment: production, promotes_from: staging), which promote-to-prod.yml binds and promotes; nothing was written" 1
fi

if [[ -n "$tmp" ]]; then
    # mktemp creates the file 0600; the manifest is read by other users and tools
    chmod 0644 "$tmp" || die "could not set the manifest's mode" 3
    mv "$tmp" "$manifest" || die "could not move the manifest into place at $manifest" 3
    tmp=""
fi
if [[ "$origin" == new ]]; then
    print -r -- "$SELF: wrote .claude-workspace.yaml"
else
    print -r -- "$SELF: kept .claude-workspace.yaml (exists)"
fi

# --- the fixed files --------------------------------------------------------
for rel in $FIXED_FILES; do
    target="$repo/$rel"
    if [[ -e "$target" ]]; then
        print -r -- "$SELF: kept $rel (exists)"
        continue
    fi
    after="the manifest was judged valid and is on disk; the files before this one were written"
    mkdir -p "${target:h}" 2>/dev/null || die "could not create ${rel:h}/ in $repo — $after" 3
    cp "$TEMPLATES/$rel" "$target" 2>/dev/null || die "could not write $rel from $TEMPLATES — $after" 3
    if [[ "$rel" == *.zsh ]]; then
        chmod +x "$target" || die "could not make $rel executable — $after" 3
    fi
    print -r -- "$SELF: wrote $rel"
done

print -r -- "$SELF: $verdict"
