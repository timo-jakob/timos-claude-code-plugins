#!/usr/bin/env zsh
# validate-workspace.zsh — check a `.claude-workspace.yaml` constellation
# manifest against the `claude-workspace/v1` contract (issue #1744, child 1 of
# epic #687).
#
# The contract itself is specified once, in ARCHITECTURE.md ("The
# `claude-workspace/v1` contract"). This script is its executable half; it
# restates no rationale, only the checks.
#
# It has exactly two callers, both outside this child: bootstrap runs it on the
# repo it has just scaffolded (#1745), and the composition maintenance gather
# turns a failure into a finding (#1747). Which failure, though, decides which
# finding — the exit codes below are typed precisely so a caller never reports
# one defect as another:
#
#   1 -> a contract finding, quoting the named member or environment (or, for a
#        violation attributable to neither — a parse failure, a missing or
#        mistyped top-level key, an unusable environment name — the
#        document-level defect);
#   4 -> a missing-OR-UNREADABLE-manifest finding, never "your manifest is
#        invalid" — the stderr line says which: `manifest not found` blames
#        whatever should have written it, `manifest not readable` blames the
#        file's own mode;
#   3 -> a tool-availability escalation about the RUNNER, never a manifest
#        finding — whether or not the manifest had already been read when the
#        tool failed;
#   2 -> a bug in the caller's own invocation, not a repo defect at all;
#   anything else -> treated as 3. The script exits only with 0, 1, 2, 3 and 4,
#        so another status means a tool died under `err_exit` and the manifest
#        was never judged; it is never a contract finding.
#
# No validator CI job is ever rendered into a composition repo — that is #687's
# stated scope boundary, not an oversight.
#
# Usage:
#   validate-workspace.zsh [--manifest <path>] [--repo <dir>]
#
#   --manifest  the manifest to check (default: <repo>/.claude-workspace.yaml)
#   --repo      the repo root the default manifest path is resolved against
#               (default: the current directory)
#
# Output: on failure, ONE line on stderr — the first violation only (see below)
# — NAMING the offending member or environment where the violation is
# attributable to one, and otherwise describing the document-level defect, so
# the caller can quote it verbatim into a finding. On success a single line on stdout:
# `claude-workspace/v1: <path> is valid (N members, M environments)`.
#
# It stops at the FIRST violation (the contract's "named error on the first
# violation"), so a manifest with several problems is fixed one round-trip at a
# time rather than reported as a wall of cascading noise from one root cause.
#
# Exit:
#   0  the manifest satisfies claude-workspace/v1
#   1  the manifest violates it — a named error is on stderr
#   2  usage error (bad flag, missing value)
#   3  a required tool (yq/jq) is missing or unusable, `yq` is not
#      mikefarah's, or the runner otherwise cannot provide what the script
#      needs (a temporary file, a working jq/yq mid-run)
#   4  the manifest file does not exist, or cannot be read
emulate -L zsh
setopt err_exit nounset pipefail

readonly SELF="validate-workspace.zsh"

repo="."
manifest=""

# A flag's value is INSPECTED, not merely counted. `--manifest ""` would
# otherwise fall through to the default path below and validate a file in the
# current directory that the caller never named — returning a verdict, possibly
# a green one, about the wrong repo. Both intended callers interpolate a shell
# variable here, so an unset one is the likely shape. A dropped value that
# swallows the NEXT flag (`--manifest --repo /tmp/x`) is caught by the same
# test, and is reported as the usage error it is rather than as exit 4.
need_value() {   # $1 = flag name, $2 = the candidate value (may be absent)
    [[ $# -eq 2 && -n "$2" && "$2" != -* ]] || {
        print -r -u2 -- "$SELF: $1 needs a value"
        exit 2
    }
}

while (( $# > 0 )); do
    case "$1" in
    --manifest)
        need_value --manifest "${@:2:1}"
        manifest="$2"; shift 2 ;;
    --repo)
        need_value --repo "${@:2:1}"
        repo="$2"; shift 2 ;;
    -h|--help)
        print -r -- "usage: $SELF [--manifest <path>] [--repo <dir>]"; exit 0 ;;
    *)
        print -r -u2 -- "$SELF: unknown flag: $1"; exit 2 ;;
    esac
done

[[ -n "$manifest" ]] || manifest="$repo/.claude-workspace.yaml"

for tool in yq jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        print -r -u2 -- "$SELF: required tool not found: $tool"
        exit 3
    }
done

# `yq` must be mikefarah's Go yq (the family's declared one). Debian/Ubuntu's
# `yq` package is kislyuk's python-yq, which REJECTS `-o=json` — so without this
# probe the parse below fails and the manifest is blamed for a runner problem,
# reporting exit 1 "malformed YAML" where the contract says exit 3.
#
# BOTH spellings are accepted, as tests/iac-tools.zsh does: the `mikefarah` URL
# only appears in ~v4.24 and later, and an older 4.x prints a bare
# `yq version 4.20.2` while speaking exactly the dialect this script needs —
# keying on the URL alone would escalate a perfectly usable binary and tell the
# maintainer to install the yq they already have. python-yq (`yq 3.4.3`) and
# mikefarah v3 are still refused.
yq_version="$(yq --version 2>&1)"
[[ "$yq_version" == *[Mm]ikefarah* || "$yq_version" == "yq version 4."* ]] || {
    print -r -u2 -- "$SELF: yq is not mikefarah's Go yq (v4) — required tool unusable"
    exit 3
}

# A missing manifest is its own exit code, not a validation failure: bootstrap
# not having written the file and having written a bad one are different bugs,
# and a caller that conflates them reports the wrong one. An UNREADABLE file is
# the same class — an I/O problem, never a verdict on content the script never
# saw.
[[ -f "$manifest" ]] || {
    print -r -u2 -- "$SELF: manifest not found: $manifest"
    exit 4
}
[[ -r "$manifest" ]] || {
    print -r -u2 -- "$SELF: manifest not readable: $manifest"
    exit 4
}

fail() {
    # Flattened: the header promises ONE line, and the caller quotes it into a
    # finding. Values read back out of the manifest reach these messages, and a
    # YAML scalar may carry literal newlines — which would both break that
    # promise and let a manifest forge extra lines in whatever reads the
    # finding.
    print -r -u2 -- "$SELF: $manifest: ${1//[$'\n'$'\r']/ }"
    exit 1
}

# Every scalar field is read as a string, so a non-string value must be refused
# BEFORE it is parsed as one: `jq -r` prints an object or array as its JSON
# text, and `// empty` treats that as present — so an `image:` written as a
# block mapping would flow into the tag rules as a JSON blob, find a `:` in it,
# and pass. That is a green verdict on a manifest pinning no image at all.
# A value read out of the manifest is NEVER pasted into a jq program: an
# environment name carrying a quote or a backslash would make the filter
# uncompilable — reported, with jq's error swallowed, as "must be a non-empty
# string" about a field that is one — and a crafted name could close the
# subscript early and make the filter truthy, reopening the very hole this
# check closes. Both helpers pass the path through `--arg`.
#
# Whitespace-only counts as empty: `role: " "` is what a template renders from
# a variable that expanded to a space, and it is the same defect as `role: ""`.
_string_filter='type == "string" and (sub("^[[:space:]]+";"") | sub("[[:space:]]+$";"") | length) > 0'
# A value read through `$( )` loses its TRAILING newlines, so any check written
# in the shell judges a value the document does not carry: `promotes_from: >`
# with an indented `staging` is `"staging\n"`, which the shell sees as
# `staging` and would match a declared environment that the manifest does not
# actually name. Anything that has to judge the raw value is therefore asked in
# jq, not in zsh.
_single_line_filter='type == "string" and (test("[\n\r]") | not)'

require_member_string() {   # $1 = index, $2 = key, $3 = the member's name
    jq -e --argjson i "$1" --arg k "$2" ".members[\$i][\$k] | $_string_filter" \
        >/dev/null 2>&1 <<< "$doc" \
        || fail "member '$3': $2 must be a non-empty string"
}

require_env_string() {      # $1 = environment name, $2 = key
    jq -e --arg e "$1" --arg k "$2" ".environments[\$e][\$k] | $_string_filter" \
        >/dev/null 2>&1 <<< "$doc" \
        || fail "environment '$1': $2 must be a non-empty string"
}

# Parse once, into JSON, so every check below reads the same document.
#
# err_exit does NOT fire on a failed command substitution in an assignment, so
# the status is captured and tested explicitly; otherwise malformed YAML would
# fall through to the checks below with an empty document and be reported as a
# missing `members` key instead of as a parse error.
#
# The two streams are captured SEPARATELY: folding stderr into the document
# would corrupt it whenever yq writes a warning while exiting 0, and the
# corruption would then be reported as a defect of the manifest.
doc=""
# `XXXXXX` is REQUIRED: BSD/macOS mktemp appends its own suffix to a bare
# prefix, but GNU coreutils refuses a template with fewer than three X's — so
# without it every run on a Linux runner fails to create the file and reports
# the manifest as unparseable. And the status is checked, because a command
# substitution's failure does not trip `err_exit`: an unwritable TMPDIR is a
# runner fact (exit 3), not a verdict on the manifest.
# `2>/dev/null`: mktemp writes its own diagnostic, which would make this
# failure two stderr lines where the header promises one.
yq_err="$(mktemp -t validate-workspace.XXXXXX 2>/dev/null)" || {
    print -r -u2 -- "$SELF: could not create a temporary file — required tool unusable"
    exit 3
}
# EXIT alone: a fall-through INT/TERM handler would clean up and then let the
# run continue to its success line, which bootstrap reads as a valid scaffold.
trap 'rm -f "$yq_err"' EXIT
if ! doc="$(yq -o=json '.' "$manifest" 2>"$yq_err")"; then
    # A failed read is not a parse failure. The `-r` test above and this read
    # are a check-then-use pair, so the file may have been removed or had its
    # mode changed in between (a gather running while bootstrap rewrites it) —
    # which is exit 4's fact about the FILE, not exit 1's about its content.
    [[ -r "$manifest" ]] || {
        print -r -u2 -- "$SELF: manifest not readable: $manifest"
        exit 4
    }
    fail "malformed YAML — could not be parsed: $(tr '\n' ' ' < "$yq_err")"
fi
# `yq -o=json` emits one JSON value PER DOCUMENT, and every check below assumes
# exactly one. Two documents would make `jq '.members | length'` a two-line
# string, which turns the members loop's arithmetic into a raw zsh math error —
# an unnamed failure where the contract owes a named one. Zero documents is a
# different defect with a different fix (a truncated file — a comment-only one
# parses to `null` and is caught as a non-mapping below), so it gets its own
# message rather than being told it has too many.
# The `0` and non-numeric arms below are DEFENSIVE: with mikefarah yq an empty
# or comment-only file yields `null` — one document — which the not-a-mapping
# guard catches, so no input reaches them today. They are kept rather than
# folded in so a yq that ever emits nothing is named rather than mis-told it
# declared too many documents.
doc_count="$(jq -s 'length' <<< "$doc" 2>/dev/null)" || {
    print -r -u2 -- "$SELF: required tool unusable: jq"
    exit 3
}
case "$doc_count" in
0)  fail "malformed YAML — the manifest declares no YAML document" ;;
1)  : ;;
[0-9]*) fail "malformed YAML — expected a single YAML document, found $doc_count" ;;
*)  fail "malformed YAML — could not be read as JSON" ;;
esac
# A YAML document can be valid and still not be a mapping (an empty file parses
# to `null`, a list to an array); `.members` on either is not a usable error.
jq -e 'type == "object"' >/dev/null 2>&1 <<< "$doc" \
    || fail "malformed YAML — the document is not a mapping"

jq -e 'has("members")' >/dev/null 2>&1 <<< "$doc" \
    || fail "missing required key: members"
jq -e '.members | type == "array"' >/dev/null 2>&1 <<< "$doc" \
    || fail "members must be a list"
jq -e '.members | length > 0' >/dev/null 2>&1 <<< "$doc" \
    || fail "members is empty — a constellation declares at least one member"
# Every ELEMENT must be a mapping before anything indexes into one: `.name` on
# the scalar in `members:\n  - orders-api` is a jq ERROR, not a false value, so
# without this guard the loop below either leaks jq's stderr under a misleading
# "missing required key: name" or dies with jq's own exit code — one this
# script's callers cannot type.
jq -e '.members | all(type == "object")' >/dev/null 2>&1 \
    <<< "$doc" || fail "every entry of members must be a mapping (member #$(jq '[.members | to_entries[] | select(.value | type != "object") | .key + 1] | first' <<< "$doc") is not)"

jq -e 'has("environments")' >/dev/null 2>&1 <<< "$doc" \
    || fail "missing required key: environments"
jq -e '.environments | type == "object"' >/dev/null 2>&1 <<< "$doc" \
    || fail "environments must be a mapping of name -> environment"
jq -e '.environments | length > 0' >/dev/null 2>&1 <<< "$doc" \
    || fail "environments is empty — declare at least one environment"
jq -e '.environments | all(type == "object")' >/dev/null 2>&1 \
    <<< "$doc" || fail "every environment must be a mapping of its declaration (environment '$(jq -r '[.environments | to_entries[] | select(.value | type != "object") | .key] | first' <<< "$doc")' is not)"

# ---------------------------------------------------------------------------
# members[]
# ---------------------------------------------------------------------------

# The required set, named ONCE: every field ARCHITECTURE.md's members[] table
# declares required. `name` is checked first and separately, because it is what
# every other message about this member quotes.
readonly -a REQUIRED_MEMBER_KEYS=(repo role contract image)

member_count="$(jq '.members | length' <<< "$doc")"
typeset -a seen_names=()
idx=0
while (( idx < member_count )); do
    # `// empty` rather than `// ""`: an absent key and a key explicitly set to
    # the empty string are both "not declared" here, and both must be named.
    name="$(jq -r --argjson i "$idx" '.members[$i].name // empty' <<< "$doc")"
    # the member's own name is what every error below quotes, so a member
    # missing one is reported by position — "member #2" is still actionable,
    # whereas an empty name in the message reads as a truncated error.
    label="$name"
    [[ -n "$label" ]] || label="member #$((idx + 1)) (no name)"

    [[ -n "$name" ]] || fail "$label: missing required key: name"
    require_member_string "$idx" name "$name"
    # single-line for the same reason an environment name is: this value is
    # what every error about the member quotes, and `fail()` flattens newlines,
    # so a multi-line name would be quoted as a name the manifest never carried.
    # Asked in jq, because `$name` has already lost a TRAILING newline.
    jq -e --argjson i "$idx" ".members[\$i].name | $_single_line_filter" \
        >/dev/null 2>&1 <<< "$doc" \
        || fail "member #$((idx + 1)): name must be a single-line string"
    # Every error keys on the name, so two members sharing one leave the reader
    # unable to tell which was meant — and #1745's promotion record keys on it too.
    (( ${seen_names[(Ie)$name]} == 0 )) \
        || fail "member '$name': duplicate member name — names are unique within a constellation"
    seen_names+=("$name")

    for key in $REQUIRED_MEMBER_KEYS; do
        value="$(jq -r --argjson i "$idx" --arg k "$key" '.members[$i][$k] // empty' <<< "$doc")"
        [[ -n "$value" ]] || fail "member '$name': missing required key: $key"
        # …and it must be a STRING: an object or array is printed by `jq -r` as
        # its JSON text, which `// empty` reads as present and the rules below
        # would then parse as if it were a ref.
        require_member_string "$idx" "$key" "$name"
    done

    # trimmed BEFORE the rules below read it: `…:latest ` would otherwise match
    # none of the closed floating arms and validate clean, so one invisible
    # character would bypass the pinning rule entirely. Trimmed in jq, with the
    # same expression the string guard uses, rather than through a zsh pattern
    # that would need `extended_glob` to mean what it looks like.
    image="$(jq -r --argjson i "$idx" \
               '.members[$i].image | sub("^[[:space:]]+";"") | sub("[[:space:]]+$";"")' \
               <<< "$doc")"

    # The tag-pinning rule. Split the optional `@sha256:<digest>` suffix off
    # first, so the tag checks below judge the same `name:tag` substring whether
    # or not the member is additionally digest-pinned.
    # An image reference carries no whitespace at all, so one rule covers the
    # interior space, the tab and the embedded newline — each of which would
    # otherwise survive into `$tag` and match none of the closed floating arms.
    [[ "$image" != *[[:space:]]* ]] \
        || fail "member '$name': image '$image' contains whitespace — claude-workspace/v1 requires image:tag"

    ref="${image%%@*}"
    digest=""
    if [[ "$image" == *@* ]]; then
        digest="${image#*@}"
        # A bare `@` declares a digest suffix and then supplies none — treated
        # as the malformed suffix it is, rather than silently skipping both
        # digest checks as an absent suffix would.
        [[ -n "$digest" ]] \
            || fail "member '$name': image '$image' has an empty digest suffix — drop the '@' or give a full @sha256: digest"
    fi

    if [[ -n "$digest" ]]; then
        [[ "$digest" == sha256:* ]] \
            || fail "member '$name': image '$image' has a digest suffix that is not a sha256 digest"
        # anchored: `sha256:abc…xyz!` must not pass on a prefix match alone
        [[ "$digest" =~ '^sha256:[0-9a-f]{64}$' ]] \
            || fail "member '$name': image '$image' has a malformed sha256 digest"
    fi

    # A tag is the part after the LAST colon, but only when that colon comes
    # after the last `/` — `localhost:5000/acme/api` is a registry port, not a
    # tag, and reading it as one would accept an untagged ref. An EMPTY tag
    # (`…/api:`) is the same defect as an absent one, and is reported as such
    # rather than as a shape of its own.
    last_segment="${ref##*/}"
    tag=""
    [[ "$last_segment" == *:* ]] && tag="${last_segment##*:}"
    [[ -n "$tag" ]] \
        || fail "member '$name': image '$image' is not pinned to a tag — claude-workspace/v1 requires image:tag (an optional @sha256: digest may follow)"
    # …and a NAME: `/:1.0` is what a template renders with the image name unset,
    # and it satisfies every tag rule while pinning nothing at all
    [[ -n "${${last_segment%%:*}//[[:space:]]/}" ]] \
        || fail "member '$name': image '$image' has no image name — claude-workspace/v1 requires image:tag"

    # Floating tags defeat the whole point of pinning a constellation: the same
    # manifest would compose different software on two different days.
    case "$tag" in
    latest|stable|edge|main|master)
        fail "member '$name': image '$image' is pinned to the floating tag ':$tag' — claude-workspace/v1 requires an immutable tag" ;;
    esac

    idx=$(( idx + 1 ))
done

# ---------------------------------------------------------------------------
# environments
# ---------------------------------------------------------------------------

# Read the declared names once: they are both the set `promotes_from` must be a
# member of, and the list every such error prints so the author can see what
# they could have meant. Joined in zsh rather than through `paste`/`sed`, which
# would be undeclared dependencies and would rewrite a comma inside a name.
declared="$(jq -r '.environments | keys_unsorted[]' <<< "$doc")"
# `"${(@f)…}"` keeps empty fields, which the unquoted form drops: an
# environment whose key is empty — what a template renders from an unset
# variable — would otherwise vanish from this roster, be validated by nothing,
# and still be counted in the success line. The roster is then proved complete
# against the document's own count, so a dropped or split name is a named error
# rather than a silently skipped environment.
typeset -a declared_names=("${(@f)declared}")
env_count="$(jq '.environments | length' <<< "$doc")"
(( ${#declared_names} == env_count )) \
    || fail "environment names must be non-empty, single-line strings (the roster is incomplete)"
# Asked of the DOCUMENT's own keys, not of the shell copies: `$( )` strips a
# trailing newline, so a key spelled `"staging\n"` would pass any test written
# here and then be validated under a name the document does not carry —
# reporting a missing `github_environment` on an environment that does not
# exist, rather than the malformed name that is the actual defect.
jq -e ".environments | keys_unsorted | all($_single_line_filter and $_string_filter)" \
    >/dev/null 2>&1 <<< "$doc" \
    || fail "environment names must be non-empty, single-line strings"
# yq reports the keys AS WRITTEN while jq keeps only the last of a duplicated
# pair, so reading them from yq is what makes a duplicate visible at all: left
# alone, one `staging:` declaration silently overrides the other. The status is
# captured rather than discarded — a failure here is a re-read of the FILE, so
# it is a tool or I/O fact, and reporting it as a duplicate would send the
# author hunting for a key the manifest does not contain.
if ! yq_env_keys="$(yq -r '.environments | keys | .[]' "$manifest" 2>"$yq_err")"; then
    [[ -r "$manifest" ]] || {
        print -r -u2 -- "$SELF: manifest not readable: $manifest"
        exit 4
    }
    # yq's own reason, flattened onto the one line, exactly as the parse arm
    # does: exit 3's whole job is telling the runner what to fix.
    print -r -u2 -- "$SELF: required tool unusable: yq: $(tr '\n' ' ' < "$yq_err")"
    exit 3
fi
typeset -a seen_envs=()
for env_name in "${(@f)yq_env_keys}"; do
    (( ${seen_envs[(Ie)$env_name]} == 0 )) \
        || fail "environment '$env_name': declared more than once — each environment is declared exactly once"
    seen_envs+=("$env_name")
done
declared_list="${(j:, :)declared_names}"

readonly -a VALID_DEPLOY_TARGETS=(none)

for env_name in "${declared_names[@]}"; do   # quoted: an empty name must not vanish
    for key in github_environment deploy_target; do
        value="$(jq -r --arg e "$env_name" --arg k "$key" '.environments[$e][$k] // empty' <<< "$doc")"
        [[ -n "$value" ]] \
            || fail "environment '$env_name': missing required key: $key"
        require_env_string "$env_name" "$key"
    done

    deploy_target="$(jq -r --arg e "$env_name" '.environments[$e].deploy_target' <<< "$doc")"
    # (Ie) yields the INDEX of an exact match, 0 when there is none — unlike
    # (r), whose no-match empty value trips `nounset` before the test runs, so
    # a disallowed value died with a zsh parameter error instead of the named
    # contract error this script owes its callers.
    if (( ${VALID_DEPLOY_TARGETS[(Ie)$deploy_target]} == 0 )); then
        fail "environment '$env_name': deploy_target '$deploy_target' is not allowed — claude-workspace/v1 accepts ${(j:, :)VALID_DEPLOY_TARGETS} in this release (compose and kubernetes arrive with #719/#720)"
    fi

    # `promotes_from` must be DECLARED, and null is a legitimate declared value
    # (the first environment in a chain promotes from nothing). So the presence
    # check and the value check are separate: a missing key is an omission, an
    # explicit null is an answer.
    jq -e --arg e "$env_name" '.environments[$e] | has("promotes_from")' >/dev/null 2>&1 <<< "$doc" \
        || fail "environment '$env_name': missing required key: promotes_from (use null when it promotes from nothing)"

    # null is tested on its own, BEFORE the string read: `// empty` collapses
    # null and `""` to the same value, so an empty string — what a template
    # renders from an unset variable — would otherwise pass as "promotes from
    # nothing" and skip every check below it.
    jq -e --arg e "$env_name" '.environments[$e].promotes_from == null' >/dev/null 2>&1 <<< "$doc" \
        && continue

    promotes_from="$(jq -r --arg e "$env_name" '.environments[$e].promotes_from // empty' <<< "$doc")"
    [[ -n "$promotes_from" ]] \
        || fail "environment '$env_name': promotes_from is empty — name a declared environment, or use null when it promotes from nothing"
    require_env_string "$env_name" promotes_from

    if [[ "$promotes_from" == "$env_name" ]]; then
        fail "environment '$env_name': promotes_from names itself"
    fi
    # …and the membership test reads the value FROM THE DOCUMENT rather than
    # from `$promotes_from`, which has already lost any trailing newline: a
    # folded scalar (`promotes_from: >`) resolves to "staging\n", which names
    # no declared environment even though the stripped copy matches one.
    if ! jq -e --arg e "$env_name" '.environments as $es | $es | has($es[$e].promotes_from)' \
             >/dev/null 2>&1 <<< "$doc"; then
        # quoted as the document carries it (@json, so a folded scalar shows as
        # "staging\n"): the stripped shell copy would print `'staging'` beside
        # a `declared:` list containing `staging`, a finding that contradicts
        # itself and sends the author to edit a value that looks correct
        shown="$(jq -r --arg e "$env_name" '.environments[$e].promotes_from | @json' <<< "$doc")"
        fail "environment '$env_name': promotes_from $shown is not a declared environment — declared: $declared_list"
    fi
done

# The chain must be ACYCLIC with a null head. Self-reference is caught above;
# this catches the longer cycles, which are the same defect — a promotion order
# no run can start, since #1745 walks `promotes_from` looking for a head.
for env_name in "${declared_names[@]}"; do   # quoted: an empty name must not vanish
    typeset -a chain=("$env_name")
    cursor="$env_name"
    while true; do
        next="$(jq -r --arg e "$cursor" '.environments[$e].promotes_from // empty' <<< "$doc")"
        [[ -n "$next" ]] || break          # reached the chain's null head
        if (( ${chain[(Ie)$next]} > 0 )); then
            # The walk may have ENTERED the cycle from outside it, so the error
            # names the repeated environment and prints the cycle alone: naming
            # the environment the walk started at would send the author to edit
            # a `promotes_from` that is correct.
            typeset -a cycle=("${chain[@]:$(( ${chain[(Ie)$next]} - 1 ))}" "$next")
            fail "environment '$next': promotes_from forms a cycle (${(j: -> :)cycle}) — the chain must reach an environment that promotes from nothing"
        fi
        chain+=("$next")
        cursor="$next"
    done
done

# `env_count` is the count the roster was PROVED complete against, above — not a
# second read, which could report environments this run never validated.
print -r -- "claude-workspace/v1: $manifest is valid ($member_count members, $env_count environments)"
