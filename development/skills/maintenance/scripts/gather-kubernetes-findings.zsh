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

emulate -L zsh
set -euo pipefail

local repo="${1:-.}"
[[ -d "$repo" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: not a directory: $repo"; exit 2; }
# and TRAVERSABLE. Every search below is wrapped in `|| true` / `2>/dev/null`, so
# a directory that exists but cannot be entered would yield an all-false payload
# with exit 0 — "could not look" rendered as "looked and found nothing", the one
# outcome this script's comments repeatedly refuse to produce.
[[ -r "$repo" && -x "$repo" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: not a readable directory: $repo"; exit 2; }
# normalise a relative path to an explicit ./ prefix: a repo path beginning with
# `-` clears the `[[ -d ]]` gate (test operators parse no options) but is then
# read as an OPTION by `cd` and as a PRIMARY by `find` — and every such failure is
# absorbed by the `|| true` below, yielding a confident all-false payload instead
# of an error. Absolute paths are already unambiguous.
[[ "$repo" == /* ]] || repo="./$repo"
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
#
# `! -type d` for the same reason the react marker carries it: a DIRECTORY named
# `Kustomization` is not a manifest, while a symlinked one still counts. Kept
# identical to the SKILL.md marker recipe — tests/kubernetes-topic-marker.bats
# derives the comparison, so the two cannot drift into detecting different repos.
manifest_hits="$(cd -- "$repo" && find . \
                   \( -name Chart.yaml -o -name kustomization.yaml \
                      -o -name kustomization.yml -o -name Kustomization \) \
                   ! -type d 2>/dev/null \
                   | grep -v -e /node_modules/ -e '/\.git/' -e /vendor/ -e /templates/ || true)"
if [[ -n "$manifest_hits" ]]; then
  has_manifests="true"
elif ( cd -- "$repo" && grep -rqlF 'argoproj.io' \
         --include='*.yaml' --include='*.yml' \
         --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git \
         --exclude-dir=templates . 2>/dev/null ); then
  # `cd` first, and grep the literal `.` — for the SAME reason the find branch
  # does it, but a sharper failure: GNU grep documents --exclude-dir as skipping
  # any COMMAND-LINE directory whose name matches, so passing "$repo" would skip
  # a repo literally named `templates`/`vendor`/`node_modules` in its ENTIRETY
  # and report it manifest-free with exit 0. `.` can never match a pattern.
  has_manifests="true"
fi

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
# three manifest copies share (SKILL.md's marker recipe, SKILL.md's manifests
# lister, and the manifest find ABOVE in this file — not the two policy finds
# below, which are the `-L` ones this block declares), and the parity oracles in
# tests/kubernetes-topic-marker.bats hold
# them identical — so do not "fix" the policy side down to match, and do not
# raise the manifest side to `-L` without changing all three copies together.
local policy_dir="$repo/policies/kyverno"
local has_policies="false"
local policy_hits=""
if [[ -d "$policy_dir" ]]; then
  # the same rule as the repo gate, one level deeper: an unreadable policy
  # directory would fail into `2>/dev/null || true` and emit "no policies
  # declared" for a repo that declared several — the silent skip the glob
  # contract exists to prevent
  [[ -r "$policy_dir" && -x "$policy_dir" ]] || { print -r -u2 -- "gather-kubernetes-findings.zsh: policies/kyverno exists but is not readable"; exit 2; }
  policy_hits="$(find -L "$policy_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null || true)"
  [[ -n "$policy_hits" ]] && has_policies="true"
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
  local test_hits
  test_hits="$(find -L "$policy_dir" -type f \
                 \( -name 'kyverno-test.yaml' -o -name 'kyverno-test.yml' \) 2>/dev/null || true)"
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

local notes_json
notes_json="$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.')"

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
'
