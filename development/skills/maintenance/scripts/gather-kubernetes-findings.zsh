#!/usr/bin/env zsh
# gather-kubernetes-findings.zsh — the kubernetes topic's finding gatherer
# (epic #1150, child #1152). Emits the v2 gather payload the
# `development-kubernetes` dispatcher consumes:
# `tooling_configured` / `findings_by_tool` / `coverage` / `notes`.
#
# Tools:
#   manifest_validation — rendered-output checks (kubeconform, kube-linter).
#                         PRESENCE-DETECTED here; the tools themselves run in
#                         the CI pipeline (#1154), never in this gather.
#   policy              — the repo's OWN Kyverno policies, matched by the GLOB
#                         policies/kyverno/**/*.{yaml,yml} rather than by the
#                         directory's existence, so an empty (or .json-only)
#                         directory skips exactly like an absent one and a repo
#                         writing .yml policies is enforced rather than silently
#                         ignored (the ARCHITECTURE.md contract).
#                         No match ⇒ tooling_configured.policy=false + a note.
#                         NEVER a finding: a public plugin must work in a repo
#                         with no opinions yet.
#   policy_tests        — this topic's coverage-gate analogue. A declared policy
#                         set with no `kyverno test` fixtures passes everything
#                         silently, which is the failure mode hardest to notice.
#
# `coverage` is always null — a topic has no application test suite.
#
# Usage: gather-kubernetes-findings.zsh [<repo_path>]   (default: current dir)
# Output: JSON on stdout (always exit 0 on a well-formed run).
#
# Exit codes (a real contract — tests/gather-kubernetes.bats pins the messages):
#   0  the payload is on stdout
#   2  no payload is emitted and stdout is empty, for one of TWO classes:
#      (a) the tree could not be SEARCHED — the argument is not a directory /
#          not readable; the repo could not be entered; the manifest search did
#          not complete; policies/kyverno exists but is not readable; the policy
#          or fixture listing failed;
#      (b) the payload could not be ENCODED or EMITTED — a jq that is on PATH
#          but failed (an absent jq is 3, below). Folded into 2 deliberately, so
#          jq's own status 5 never escapes this documented set.
#      Either way the orchestrator records `gather failed: <stderr>` and puts the
#      topic in `unsupported_topics` — never a clean, tool-ran verdict. Read the
#      message, not the code, to tell the classes apart.
#   3  jq is not on PATH (nothing can be emitted at all).

emulate -L zsh
set -euo pipefail

local repo="${1:-.}"
[[ -d "$repo" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: not a directory: $repo"; exit 2; }
# and TRAVERSABLE, before any search runs. Since #1177 each search also captures
# its OWN exit status rather than blanket-`|| true`-ing the chain, so a directory
# that exists but cannot be entered — or a find killed mid-run — exits 2 with a
# named message instead of yielding an all-false payload with exit 0: "could not
# look" rendered as "looked and found nothing", the one outcome this script's
# comments repeatedly refuse to produce.
[[ -r "$repo" && -x "$repo" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: not a readable directory: $repo"; exit 2; }
# normalise a relative path to an explicit ./ prefix: a repo path beginning with
# `-` clears the `[[ -d ]]` gate (test operators parse no options) but is then
# read as an OPTION by `cd` and as a PRIMARY by `find`. Since #1177 such a failure
# surfaces as exit 2 rather than a confident all-false payload — but normalising
# still keeps a legal path from being MISREAD as a flag in the first place.
# Absolute paths are already unambiguous.
# NARROWED to the only input that needs it (and mirrored exactly in
# review-dispatch.zsh's two copies): a path beginning with `-`, which `cd` and
# `find` read as an OPTION. Every other relative spelling is already unambiguous,
# and rewriting them all doubled the prefix in exactly the messages this script's
# error contract exists to produce — including on the documented no-argument
# default `.`, which zsh's `./*` pattern does not match, so `.` became `./.`.
# an `if`, not a `&&` list: this script runs under `set -e`, and the shells
# differ on whether a false trailing `&&` test trips errexit.
#
# WIDER than review-dispatch.zsh's copy, and deliberately so — the two protect
# different consumers. There `$repo` only ever reaches `cd --`, `git -C` and a
# `grep` operand, so a leading `-` is the only hazard. Here it also becomes
# `$policy_dir` and is handed to `find -L "$policy_dir"` as a BARE start point,
# and find stops collecting start points at the first argument beginning with any
# of `-!(),` — so a relative repo named `(new)` or `,scratch` would die with
# "paths must precede expression" and be reported as an unreadable policy tree.
# `.` and `./…` are excluded so the documented default does not become `./.`,
# which would render a doubled prefix in every message the exit contract emits.
if [[ "$repo" != /* && "$repo" != ./* && "$repo" != . ]]; then repo="./$repo"; fi
command -v jq >/dev/null 2>&1 || { print -r -u2 -- "gather-kubernetes-findings.zsh: jq not found on PATH"; exit 3; }

local -a notes=()

# --- manifest_validation: is there anything to render? ------------------------
# The marker is deliberately NOT "any YAML with apiVersion", which would match a
# workflow file or an OpenAPI document in half the repos in existence. It is a
# Helm Chart.yaml, a Kustomize manifest (all three spellings kustomize accepts),
# or the literal `argoproj.io`, which nothing else carries by accident.
local has_manifests="false"

# Capture BEFORE filtering. `find … | grep -q` looks equivalent but inverts under
# `set -o pipefail`: grep -q exits at its first match, find — still writing — dies
# of SIGPIPE, and the whole condition goes FALSE even though a chart WAS found.
# It misfires only once find's output outruns the pipe buffer, which is the worst
# possible failure mode. `grep -v` reads its input to EOF, so the filter itself is
# safe; the capture keeps it that way if the filter is ever changed.
#
# `cd` into the repo so the emitted paths are repo-RELATIVE: with an absolute
# "$repo" the prune substrings would also test the checkout's own prefix, and a
# repo living under ~/templates/ (or a workspace directory named vendor) would
# filter every hit and be reported manifest-free.
local manifest_hits
# one rc per SEARCH, so a failure can be attributed to the half that failed
local manifest_rc=0 argo_rc=1 policy_rc=0 test_rc=0 test_hits=""
#
# `! -type d` for the same reason the react marker carries it: a DIRECTORY named
# `Kustomization` is not a manifest, while a symlinked one still counts. Kept
# identical to the SKILL.md marker recipe — tests/kubernetes-topic-marker.bats
# derives the comparison, so the two cannot drift into detecting different repos.
# Each search's status is captured SEPARATELY (#1177). The old single `|| true`
# spanned the whole `cd … && find … | grep -v …` chain, so a failed `cd`, an I/O
# error or a find killed mid-run were indistinguishable from a repo with no
# charts — "could not look" emitted as `manifest_validation: false`, which the
# orchestrator renders as a completed search. An unfinished search taints only
# the NEGATIVE verdict: a hit stands whatever else failed (so an argoproj-only
# repo with one unreadable sibling directory is still detected), and only a
# BOTH-halves-empty answer with an unfinished search refuses to answer at all.
# gather-kubernetes-marker:begin
manifest_hits="$(cd -- "$repo" 2>/dev/null || exit 125
                 find . \
                   \( -name Chart.yaml -o -name kustomization.yaml \
                      -o -name kustomization.yml -o -name Kustomization \) \
                   ! -type d 2>/dev/null)" && manifest_rc=0 || manifest_rc=$?
# 125 is the subshell's sentinel for a failed `cd`, which no find returns.
# Deliberately UNTESTED: the `[[ -r && -x ]]` gate above pre-empts it with its
# own exit 2 and a different message, so no seam reaches this branch — it is
# defence-in-depth for a path that becomes unenterable between the gate and the
# search. A test that could not tell its presence from its absence would be
# inert, which is worse than none (the same call tests/gather-kubernetes.bats
# records for the fixture-find check).
(( manifest_rc != 125 )) || { print -r -u2 -- "gather-kubernetes-findings.zsh: cannot enter $repo"; exit 2 }
# the filter reads the captured string, not the filesystem, so `|| true` absorbs
# only its no-match exit 1 — never a search failure
manifest_hits="$(printf '%s\n' "$manifest_hits" \
                   | grep -v -e /node_modules/ -e '/\.git/' -e /vendor/ -e /templates/ || true)"
if [[ -z "$manifest_hits" ]]; then
  # `cd` first, and grep the literal `.` — for the SAME reason the find branch
  # does it, but a sharper failure: GNU grep documents --exclude-dir as skipping
  # any COMMAND-LINE directory whose name matches, so passing "$repo" would skip
  # a repo literally named `templates`/`vendor`/`node_modules` in its ENTIRETY
  # and report it manifest-free with exit 0. `.` can never match a pattern.
  # the SAME 125 sentinel as the find half. Without it a failed `cd` returns 1 —
  # byte-identical to grep's no-match — and the ladder below would read "could
  # not enter the repo" as "searched it, no Argo". 125 needs no branch of its
  # own: it is >= 2, so the operational-error arm already refuses to answer.
  ( cd -- "$repo" 2>/dev/null || exit 125
    grep -rqlF 'argoproj.io' \
         --include='*.yaml' --include='*.yml' \
         --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git \
         --exclude-dir=templates . 2>/dev/null ) >/dev/null && argo_rc=0 || argo_rc=$?
  # stdout REDIRECTED, not merely quiet: the subshell inherits this script's
  # stdout, which carries the v2 gather payload. Only `-q` keeps it silent today,
  # and aligning this grep with the manifests lister's `grep -rlF` (which drops
  # `-q` deliberately) would print matched paths ahead of the payload — the
  # orchestrator's jq parse would then fail and the topic would be recorded as a
  # parse error rather than by its named cause. The find half is already
  # contained by its command substitution; this makes the halves symmetric.
fi
# 125 again — named, not folded into the generic arm below. That arm would render
# it as "grep exit 125", and grep only ever returns 0, 1 or 2, so an operator
# would be chasing a status no tool produces instead of reading "the repo became
# unenterable". Same condition, same message as the find half's.
(( argo_rc != 125 )) || { print -r -u2 -- "gather-kubernetes-findings.zsh: cannot enter $repo"; exit 2; }
if [[ -n "$manifest_hits" ]] || (( argo_rc == 0 )); then
  has_manifests="true"
elif (( manifest_rc != 0 || argo_rc >= 2 )); then
  # grep exit >= 2 is an OPERATIONAL error, not a no-match, and the same
  # unreadable subtree may equally have hidden a find hit — so neither half may
  # be reported as "searched, nothing there".
  print -r -u2 -- "gather-kubernetes-findings.zsh: the manifest search did not complete (find exit $manifest_rc, grep exit $argo_rc) — refusing to emit manifest_validation:false"
  exit 2
fi
# gather-kubernetes-marker:end

# --- policy: the repo's own rules, matched as a GLOB --------------------------
# `-L` (not `-H`) on both finds below. `-H` follows only the COMMAND-LINE
# symlink, so a symlinked policies/kyverno is searched but a symlinked policy
# FILE inside a real one is type `l` and `-type f` drops it — reporting a
# symlink-shared policy set as undeclared, and a symlinked kyverno-test.yaml as
# missing coverage (a false untested-policies accusation). `-L` resolves both:
# a symlink-to-file becomes type `f`, a directory named `p.yaml` stays type `d`
# so the -type f guard still holds, and a dangling symlink is still excluded.
# Note the asymmetry with the manifest half, which is deliberate and NOT parity:
# the manifest finds stay at the default `-P`, so they count a symlinked manifest
# FILE but do not descend a symlinked chart DIRECTORY. That is the boundary the
# FOUR manifest copies share (SKILL.md's marker recipe, SKILL.md's manifests
# lister, the manifest find ABOVE in this file, and detect-stack.sh's
# `is-kubernetes-marker` block, #1153 — not the two policy finds
# below, which are the `-L` ones this block declares), and the parity oracles in
# tests/kubernetes-topic-marker.bats hold
# them identical — so do not "fix" the policy side down to match, and do not
# raise the manifest side to `-L` without changing all four copies together.
local policy_dir="$repo/policies/kyverno"
local has_policies="false"
local policy_hits=""
if [[ -d "$policy_dir" ]]; then
  # the same rule as the repo gate, one level deeper: an unreadable policy
  # directory would fail into `2>/dev/null || true` and emit "no policies
  # declared" for a repo that declared several — the silent skip the glob
  # contract exists to prevent
  [[ -r "$policy_dir" && -x "$policy_dir" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: policies/kyverno exists but is not readable"; exit 2; }
  # and the same rule one level deeper still (#1177): the gate above proves the
  # TOP directory readable, not every subdirectory beneath it. `|| true` on the
  # find made an unreadable sub-tree — which may hold the very policies being
  # looked for — read as "no policies declared". Unlike the manifest marker there
  # is no second half to fall back on, so ANY non-zero find is fatal here.
  policy_hits="$(find -L "$policy_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null)" \
    && policy_rc=0 || policy_rc=$?
  (( policy_rc == 0 )) || { print -r -u2 -- "gather-kubernetes-findings.zsh: could not list $policy_dir (find exit $policy_rc)"; exit 2; }
  # an `if`, for the same reason the path normalisation above uses one: a false
  # trailing `&&` test under `set -e` is a status leak waiting for this line to
  # be moved to the end of a function
  if [[ -n "$policy_hits" ]]; then has_policies="true"; fi
fi
if [[ "$has_policies" != "true" ]]; then
  notes+=("policy: no policies declared at policies/kyverno/**/*.{yaml,yml} — step skipped, not failed")
fi

# --- policy_tests: fixtures for those policies -------------------------------
# Recursive and both extensions: fixtures are commonly grouped per policy in a
# subdirectory, and .yml is as valid as .yaml — missing either would report a
# tested policy set as untested, which is a false accusation rather than a
# missed one, and trains users to ignore this finding.
local policy_tests_findings="[]"
if [[ "$has_policies" == "true" ]]; then
  # The unchecked find here was the costliest of the three (#1177): its empty
  # result does not merely skip a step, it FABRICATES a high-severity
  # `untested_policies` finding accusing the repo of shipping untested policies.
  # A repo whose fixtures sit under an unreadable subdirectory would be told its
  # policies pass everything silently — on the strength of a search that failed.
  test_hits="$(find -L "$policy_dir" -type f \
                 \( -name 'kyverno-test.yaml' -o -name 'kyverno-test.yml' \) 2>/dev/null)" \
    && test_rc=0 || test_rc=$?
  (( test_rc == 0 )) || { print -r -u2 -- "gather-kubernetes-findings.zsh: could not list policy test fixtures under $policy_dir (find exit $test_rc)"; exit 2; }
  if [[ -z "$test_hits" ]]; then
    policy_tests_findings="$(jq -n '[{
      id: "policy_tests:untested-policies",
      tool: "policy_tests",
      type: "untested_policies",
      severity: "high",
      message: "policies/kyverno/ declares policies but has no kyverno test fixtures. An untested policy usually matches nothing, so it passes everything silently.",
      fix: "Add a kyverno-test.yaml beside the policies, declaring at least one resource each policy must PASS and one it must FAIL, and run `kyverno test policies/kyverno`.",
      files: ["policies/kyverno/"]
    }]')"
  fi
fi

# --- emit ---------------------------------------------------------------------
# ALWAYS carry the presence-detection note. The orchestrator reads an empty topic
# plan with a NON-empty tooling_configured as "this topic is clean — its tools ran
# and found nothing", which for this gather would be a lie: nothing ran. The note
# is the only thing that reaches the Phase 9 summary and can contradict that
# rendering.
notes+=("manifest_validation: presence-detected only — kubeconform/kube-linter/kyverno run in the CI pipeline (#1154), not in this gather")

# both emitters CHECK jq (#1177), for the reason review-dispatch.zsh states for
# its own: unchecked under `set -e`, a jq failure aborts with jq's status (5),
# which is outside this script's documented {0,2,3} and tells the orchestrator
# nothing about what went wrong.
local notes_json
notes_json="$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.')" || {
  print -r -u2 -- "gather-kubernetes-findings.zsh: could not encode the notes list"; exit 2;
}

jq -n \
  --argjson manifests "$has_manifests" \
  --argjson policies "$has_policies" \
  --argjson policy_tests "$policy_tests_findings" \
  --argjson notes "$notes_json" '
{
  tooling_configured: {
    manifest_validation: $manifests,
    policy: $policies,
    policy_tests: $policies
  },
  # The v2 contract in ARCHITECTURE.md: findings_by_tool carries keys ONLY for
  # configured tools. Emitting an empty array for an unconfigured tool would make
  # "not configured" indistinguishable from "configured and clean" — which for the
  # policy skip is exactly the confusion the charter must never create.
  findings_by_tool: (
    (if $manifests then { manifest_validation: [] } else {} end)
    + (if $policies then { policy: [], policy_tests: $policy_tests } else {} end)
  ),
  coverage: null,
  notes: $notes
}
' || { print -r -u2 -- "gather-kubernetes-findings.zsh: could not emit the payload"; exit 2; }
