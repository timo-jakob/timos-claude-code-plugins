#!/usr/bin/env zsh
# tofu-review-gate.zsh — the pre-dispatch gate of /development-opentofu:review (#1161).
#
# Why a script and not prose: the gate has three outcomes that must stay
# distinct — a tree that does not validate FAILS the round, a registry that
# cannot be reached DEGRADES it to a source-only review, and a tree that passes
# gets the full review. Telling the first two apart is a judgement about `tofu
# init`'s output, and a judgement made afresh by a model on every round is one
# that can drift; made here it is one rule, and tests/opentofu-review-gate.bats
# pins it.
#
# What it does:
#   1. copies the repo's tree into a scratch work dir, minus `.git`,
#      `.terraform` and `node_modules`. `tofu init` writes `.terraform/` and a
#      lock file wherever it runs, and a review must never move the tree the
#      review loop gated (the round's tree identity). Vendored trees ARE copied:
#      a module may be sourced from `./vendor/…`, and validating without it
#      would fail a tree that is fine;
#   2. enumerates the ROOT modules — every directory holding a non-pruned `*.tf`
#      or `*.tf.json`, less those another such directory calls as a local module
#      (`source = "./…"` / `"../…"`). Validating a root validates the modules it
#      calls, and a called module validated on its own can fail on provider
#      configuration only its caller supplies, so that would fail good trees;
#   3. in each root: `tofu init -backend=false`, then `tofu validate`;
#   4. runs `tflint --recursive` when tflint is installed.
#
# The prune set is #1160's detection recipe's, `PRUNE_NAMES` in
# development/skills/maintenance/scripts/gather-opentofu-findings.zsh — the test
# suite pins the two equal.
#
# Usage:
#   tofu-review-gate.zsh --repo DIR
#
# Output — ONE JSON document on stdout, for every verdict:
#   {"verdict":     "full" | "degraded" | "failed" | "empty",
#    "roots":       [root dirs, repo-relative, "." for the repo root],
#    "validated":   [roots that passed init + validate],
#    "source_only": [roots that could not be validated — registry unreachable,
#                    or tofu not installed],
#    "failures":    [{"root", "step": "init" | "validate", "output"}],
#    "notes":       [one line per degradation, for the caller to report],
#    "tflint":      {"status": "ran" | "absent" | "error",
#                    "exit": N | null, "output_file": PATH | null},
#    "work_dir":    PATH}
#
#   verdict  failed   — at least one root failed `tofu validate`, or failed
#                       `tofu init` for a reason that is NOT an unreachable
#                       registry (a missing local module, an unknown provider):
#                       the tree is broken, and that outranks everything else.
#            degraded — nothing failed, but at least one root is source-only.
#            full     — every root was validated.
#            empty    — no non-pruned `*.tf` / `*.tf.json` at all.
#   tflint never changes the verdict: absent or erroring, it adds a note.
#   Its own exit is recorded as it came: 0 no issues, 3 issues found.
#
# Exit: 0 verdict full | degraded | empty; 10 verdict failed; 2 usage error;
#       1 internal failure (a required tool missing, the copy failed).
#
# The work dir is left in place once its path is printed — the tflint output in
# it is evidence the reviewers read, and the caller removes it when the round
# ends. On an exit that prints no document it is removed here.

emulate -L zsh
setopt pipe_fail no_unset

usage() {
  print -r -u2 -- "usage: tofu-review-gate.zsh --repo DIR"
  exit 2
}

repo=""
while (( $# )); do
  case "$1" in
    --repo) (( $# >= 2 )) || usage; repo="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$repo" ]] || usage
[[ -d "$repo" ]] || { print -r -u2 -- "tofu-review-gate.zsh: not a directory: $repo"; exit 2 }

local tool
for tool in jq rsync find awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    print -r -u2 -- "tofu-review-gate.zsh: $tool not found on PATH"
    exit 1
  }
done

# The trees #1160's detection recipe prunes. Kept equal to its PRUNE_NAMES by
# tests/opentofu-review-gate.bats — the closing paren stays at column 0 so the
# test's sed range can find the end of the list.
local -a PRUNE_NAMES=(
  .terraform node_modules vendor .git
)

# An init failure carrying one of these is a registry (or module host) that
# could not be reached — the last two are git's own wording, for a `git::` or
# ssh module source fetched through the git binary — the offline / local-run case, which degrades. Any
# other init failure is the tree's own, and fails the round.
NETWORK_SIGNATURE='dial tcp|no such host|i/o timeout|connection refused|network is unreachable|tls handshake timeout|client\.timeout exceeded|could not connect to|failed to request discovery document|server misbehaving|temporary failure in name resolution|connection reset by peer|could not resolve host|failed to connect to'

work="$(mktemp -d "${TMPDIR:-/tmp}/tofu-review-gate.XXXXXX")" || {
  print -r -u2 -- "tofu-review-gate.zsh: could not create a work dir"
  exit 1
}
# Normalised, because the module-source resolution below compares `:a`-normalised
# paths against this prefix: a TMPDIR ending in `/` (macOS's does) leaves a `//`
# here that no normalised path would ever match, and every called module would
# then be validated as a root of its own.
work="${work:a}"
# Removed on every exit that does not report it: an exit-1 path prints nothing,
# so the caller could never find the copy (tfvars and all) to remove it. `emit`
# sets `reported` once the document naming the path is out. (A flag rather than
# `trap - EXIT` inside `emit`: zsh scopes an EXIT trap set in a function to it.)
reported=""
trap '[[ -n "$reported" ]] || rm -rf -- "$work"' EXIT
copy="$work/tree"
mkdir -p "$copy" || { print -r -u2 -- "tofu-review-gate.zsh: could not create $copy"; exit 1 }
rsync -a --exclude='/.git' --exclude='.terraform' --exclude='node_modules' \
  "${repo%/}/" "$copy/" || {
  print -r -u2 -- "tofu-review-gate.zsh: copying $repo into the work dir failed"
  exit 1
}

# Every directory holding a non-pruned module file, repo-relative. The prune is
# applied to the captured list with fixed strings, as the gather does, so a
# directory named `_terraform` is not pruned by a `.` read as a wildcard.
local -a prune_args=() dirs=()
local pn
for pn in "${PRUNE_NAMES[@]}"; do prune_args+=(-e "/${pn}/"); done
local hits find_rc grep_rc
hits="$(cd -- "$copy" && find . \( -name '*.tf' -o -name '*.tf.json' \) ! -type d)"
find_rc=$?
# An unfinished walk could turn "could not look" into verdict "empty" — a clean
# review of nothing. Refuse instead.
(( find_rc == 0 )) || {
  print -r -u2 -- "tofu-review-gate.zsh: the module search did not complete (find exit $find_rc)"
  exit 1
}
hits="$(printf '%s\n' "$hits" | grep -vF "${prune_args[@]}")"
grep_rc=$?
# 1 is grep's "everything was pruned", a real answer; 2+ is grep failing.
(( grep_rc <= 1 )) || {
  print -r -u2 -- "tofu-review-gate.zsh: the prune filter did not complete (grep exit $grep_rc)"
  exit 1
}
local f d
for f in "${(f)hits}"; do
  [[ -n "$f" ]] || continue
  d="${f:h}"
  d="${d#./}"
  [[ "$d" == "." || -z "$d" ]] && d="."
  dirs+=("$d")
done
dirs=("${(@u)dirs}")

# The local module sources each directory calls, resolved to repo-relative
# directories. A directory that some OTHER directory calls is not a root.
local -a called=()
# A module call is a line that BEGINS with `source =`, or with a one-line
# `module "…" { source = … }` block — so a `#` or `//` comment, a string, a
# heredoc glob or an interpolation can never make one. The one comment form that can hide a whole
# call is a block, recognised only where a line begins with `/*`; it runs to the
# first `*/`, and its lines are dropped.
STRIP_BLOCKS='
blk { if (index($0, "*/")) blk = 0; next }
/^[[:space:]]*\/\*/ { if (!index(substr($0, index($0, "/*") + 2), "*/")) blk = 1; next }
{ print }'

local src target
for d in "${dirs[@]}"; do
  for f in "$copy/$d"/*.tf(N); do
    for src in ${(f)"$(awk "$STRIP_BLOCKS" "$f" 2>/dev/null \
                     | grep -hoE '^[[:space:]]*(module[[:space:]]+"[^"]*"[[:space:]]*\{[[:space:]]*)?source[[:space:]]*=[[:space:]]*"\.\.?/[^"]*"' \
                     | sed -E 's/^.*source[[:space:]]*=[[:space:]]*"//; s/"$//')"}; do
      target="${${:-$copy/$d/$src}:a}"
      [[ "$target" == "$copy" ]] && { called+=("."); continue }
      [[ "$target" == "$copy"/* ]] || continue
      called+=("${target#$copy/}")
    done
  done
  for f in "$copy/$d"/*.tf.json(N); do
    for src in ${(f)"$(jq -r '.module? // empty | .. | objects | .source? // empty | strings' "$f" 2>/dev/null \
                     | grep -E '^\.\.?/')"}; do
      target="${${:-$copy/$d/$src}:a}"
      [[ "$target" == "$copy" ]] && { called+=("."); continue }
      [[ "$target" == "$copy"/* ]] || continue
      called+=("${target#$copy/}")
    done
  done
done

local -a roots=()
for d in "${dirs[@]}"; do
  (( ${called[(Ie)$d]} )) && continue
  roots+=("$d")
done
# every directory called by another — a module cycle, or `source = "./"` — would
# leave no root and read as verdict "empty"; validate them all instead, so
# `tofu init` reports the cycle as the failure it is
(( ${#roots} == 0 && ${#dirs} )) && roots=("${dirs[@]}")
roots=("${(@o)roots}")

local -a validated=() source_only=() notes=() failures=()
local out rc

emit() {
  local verdict="$1"
  jq -n \
    --arg verdict "$verdict" \
    --arg work "$work" \
    --argjson roots "$(printf '%s\n' "${roots[@]}" | jq -R . | jq -s 'map(select(length > 0))')" \
    --argjson validated "$(printf '%s\n' "${validated[@]}" | jq -R . | jq -s 'map(select(length > 0))')" \
    --argjson source_only "$(printf '%s\n' "${source_only[@]}" | jq -R . | jq -s 'map(select(length > 0))')" \
    --argjson failures "$(printf '%s\n' "${failures[@]}" | jq -s '.')" \
    --argjson notes "$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s 'map(select(length > 0))')" \
    --argjson tflint "$tflint_json" \
    '{verdict: $verdict, roots: $roots, validated: $validated,
      source_only: $source_only, failures: $failures, notes: $notes,
      tflint: $tflint, work_dir: $work}' || return 1
  reported=1
}

tflint_json='{"status":"absent","exit":null,"output_file":null}'

if (( ${#roots} == 0 )); then
  notes+=("no non-pruned *.tf or *.tf.json file in the repository — nothing to review")
  emit empty || exit 1
  exit 0
fi

export TF_IN_AUTOMATION=1
# Share downloaded providers across the roots of one run. A cache the user
# already configured is kept — it is theirs, and it makes a local run faster.
if [[ -z "${TF_PLUGIN_CACHE_DIR:-}" ]]; then
  export TF_PLUGIN_CACHE_DIR="$work/plugin-cache"
  mkdir -p "$TF_PLUGIN_CACHE_DIR"
fi

local root
if ! command -v tofu >/dev/null 2>&1; then
  source_only=("${roots[@]}")
  notes+=("tofu is not installed — no root was validated; source-only review (brew install opentofu)")
else
  for root in "${roots[@]}"; do
    out="$(cd -- "$copy/$root" && tofu init -backend=false -input=false -no-color 2>&1)"
    rc=$?
    if (( rc != 0 )); then
      if printf '%s\n' "$out" | grep -Eqi "$NETWORK_SIGNATURE"; then
        source_only+=("$root")
        notes+=("$root: tofu init could not reach the provider registry — source-only review for this root")
      else
        failures+=("$(jq -n --arg root "$root" --arg out "$(printf '%s\n' "$out" | tail -n 200)" \
          '{root: $root, step: "init", output: $out}')")
      fi
      continue
    fi
    out="$(cd -- "$copy/$root" && tofu validate -no-color 2>&1)"
    rc=$?
    if (( rc != 0 )); then
      failures+=("$(jq -n --arg root "$root" --arg out "$(printf '%s\n' "$out" | tail -n 200)" \
        '{root: $root, step: "validate", output: $out}')")
    else
      validated+=("$root")
    fi
  done
fi

if command -v tflint >/dev/null 2>&1; then
  (cd -- "$copy" && tflint --recursive --no-color) >"$work/tflint.txt" 2>&1
  rc=$?
  # tflint exits 0 with no issues and 3 with issues found; 2, or anything else,
  # is tflint failing to run (a config naming a plugin that is not installed).
  if (( rc == 0 || rc == 3 )); then
    tflint_json="$(jq -n --argjson exit "$rc" --arg out "$work/tflint.txt" \
      '{status: "ran", exit: $exit, output_file: $out}')"
  else
    tflint_json="$(jq -n --argjson exit "$rc" --arg out "$work/tflint.txt" \
      '{status: "error", exit: $exit, output_file: $out}')"
    notes+=("tflint could not run (exit $rc) — lint skipped; see $work/tflint.txt")
  fi
else
  notes+=("tflint is not installed — lint skipped (brew install tflint)")
fi

if (( ${#failures} )); then
  emit failed || exit 1
  exit 10
elif (( ${#source_only} )); then
  emit degraded || exit 1
else
  emit full || exit 1
fi
exit 0
