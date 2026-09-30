#!/usr/bin/env zsh
# gather-react-findings.zsh — the React topic's finding gatherer (epic #686, #956,
# #1947). Emits the v2 gather payload the `development-react` dispatcher consumes:
# `tooling_configured` / `findings_by_tool` / `coverage` / `notes`. Topics aren't
# code with tests of their own, so `coverage` is always null.
#
# Two tools, both CONFIGURATION audits: the gather never runs npm, a browser or
# Lighthouse. They report, as ADVISORY findings, an existing React repo that lacks
# the WebUI quality gates the bootstrap React overlay renders into a new app
# (#1946), whose own CI is where those gates BLOCK. The audit accepts exactly that
# rendered layout. Every finding is {id, tool, type, severity, message, fix, files},
# with `id` = `<tool>:<type>[:<assertion-id>]`, and `findings_by_tool` always
# carries both keys (`[]` when compliant). All paths are relative to the repo root,
# and only root files are read: a monorepo whose React app lives below the root is
# a known gap, judged against the root.
#
#   a11y — an axe package is a `devDependencies` key of root package.json that is
#       `axe-core`, `vitest-axe` or `jest-axe`, or starts with `@axe-core/`. None
#       → `a11y:no_axe_package` (MAJOR). With one present, the matcher must be
#       registered: the config is the first existing root
#       `vitest.config.{ts,mts,cts,js,mjs,cjs}`, else `vite.config.{…}`, and the
#       string literals of its `setupFiles` value (a string or an array; a leading
#       `./` stripped) name the setup files. Registered = at least one listed file
#       exists and contains `toHaveNoViolations`, or imports
#       `vitest-axe/extend-expect` / `jest-axe/extend-expect`. Otherwise — no config,
#       no `setupFiles`, or no listed file registering — `a11y:matcher_not_registered`
#       (MAJOR). A `setupFiles` with an entry that has no extractable literal (a
#       variable, a computed expression) — unless a listed literal registers — and a
#       missing or invalid package.json are NOTES, never findings: the audit could
#       not judge them. `tooling_configured.a11y` is true only when an axe package is
#       present.
#   lighthouse_budget — only root `lighthouserc.json` is read (never
#       `.lighthouserc.*`, `lighthouserc.{js,cjs,yml,yaml}` or a package.json `lhci`
#       key). Missing → `missing_config`, not valid JSON → `invalid_config` (both
#       MAJOR, exit 0, no per-assertion checks). Each byte budget in
#       `.ci.assert.assertions` — `resource-summary:script:size` ≤ 307200 and
#       `resource-summary:total:size` ≤ 512000 bytes — is checked on its own:
#       absent → `budget_missing` (MAJOR); level not `error` or no numeric
#       `maxNumericValue` → `budget_not_blocking` (MINOR); over the limit →
#       `budget_too_loose` (MINOR); exactly the limit passes. The flapping timing
#       gates #960 rules out — LCP, TBT, CLS, `categories:performance` — at `error`
#       → `timing_assertion_blocking` (MINOR), and a non-empty `.ci.assert.preset`
#       → `preset_present` (MINOR); `warn`/`off` is never a finding.
#       `tooling_configured.lighthouse_budget` is true only when the file exists
#       and parses.
#
# Usage: gather-react-findings.zsh [<repo_path>]   (default: current directory)
# Output: JSON on stdout (always exit 0 on a well-formed run).
#
# Exit codes:
#   0 — well-formed run (payload on stdout)
#   2 — usage error (no such directory, or extra/empty arguments)
#   3 — runtime error (jq missing, a jq invocation failing, or the repo path
#       could not be entered)
#
# Runtime jq failures are mapped onto 3 explicitly rather than being allowed to
# abort under `set -e` with jq's OWN status — jq exits 2 for a usage/system error,
# which would be indistinguishable from this script's documented "not a directory".
# jq is also asked to parse the target's own files, where a failure is a FINDING
# (invalid lighthouserc.json) or a note (invalid package.json); the self-check
# below is what lets those branches read a failed parse as the file's fault rather
# than a broken jq's.

emulate -L zsh
set -euo pipefail

(( $# <= 1 )) || { print -r -u2 -- "gather-react-findings.zsh: too many arguments (expected at most one repo path)"; exit 2; }
# ${1-.} (not ${1:-.}): an explicitly EMPTY argument is a usage error, not a
# silent fallback to the current directory.
local repo="${1-.}"
[[ -n "$repo" ]] || { print -r -u2 -- "gather-react-findings.zsh: empty repo path"; exit 2; }
[[ -d "$repo" ]] || { print -r -u2 -- "gather-react-findings.zsh: not a directory: $repo"; exit 2; }
command -v jq >/dev/null 2>&1 || { print -r -u2 -- "gather-react-findings.zsh: jq not found on PATH"; exit 3; }
jq -n 'true' >/dev/null 2>&1 || { print -r -u2 -- "gather-react-findings.zsh: jq failed its self-check"; exit 3; }

# Enter the target repo, so every relative path below is the TARGET's, not the
# orchestrator's cwd.
cd -- "$repo" || { print -r -u2 -- "gather-react-findings.zsh: cannot enter: $repo"; exit 3; }

local -a notes=()

# --- a11y -----------------------------------------------------------------------

# Scans the text after `setupFiles:` in $rest. Sets setup_state to `literals`
# (setup_literals holds them), `empty` (an array with no elements) or
# `nonliteral` (an element with no extractable literal; setup_literals still holds
# any literals beside it). Callers' locals are visible here by zsh's
# dynamic scoping; read_literal advances $i past the closing quote.
read_literal() {
  local q="${rest[i]}" ch
  lit=""
  (( i++ ))
  while (( i <= n )); do
    ch="${rest[i]}"
    if [[ "$ch" == '\' ]]; then
      (( i++ )); lit+="${rest[i]}"; (( i++ )); continue
    fi
    if [[ "$ch" == "$q" ]]; then (( i++ )); return 0; fi
    # a template literal with a substitution is computed, not literal
    if [[ "$q" == '`' && "$ch" == '$' && "${rest[i+1]}" == '{' ]]; then return 1; fi
    lit+="$ch"; (( i++ ))
  done
  return 1   # unterminated
}

scan_setup_files() {
  local rest="$1" lit c
  local -i i=1 n=${#1} depth nonlit=0
  setup_literals=()
  while (( i <= n )) && [[ "${rest[i]}" == [[:space:]] ]]; do (( i++ )); done
  c="${rest[i]:-}"
  if [[ "$c" == [\"\'\`] ]]; then
    if read_literal; then setup_literals=("$lit"); setup_state="literals"; else setup_state="nonliteral"; fi
    return 0
  fi
  if [[ "$c" != "[" ]]; then setup_state="nonliteral"; return 0; fi
  (( i++ ))
  while (( i <= n )); do
    c="${rest[i]}"
    if [[ "$c" == [[:space:],] ]]; then (( i++ )); continue; fi
    [[ "$c" == "]" ]] && break
    if [[ "$c" == "/" && "${rest[i+1]}" == "/" ]]; then
      while (( i <= n )) && [[ "${rest[i]}" != $'\n' ]]; do (( i++ )); done; continue
    fi
    if [[ "$c" == "/" && "${rest[i+1]}" == "*" ]]; then
      (( i += 2 ))
      while (( i <= n )) && [[ "${rest[i]}${rest[i+1]}" != "*/" ]]; do (( i++ )); done
      (( i += 2 )); continue
    fi
    if [[ "$c" == [\"\'\`] ]]; then
      local -i start=$i
      if read_literal; then setup_literals+=("$lit"); continue; fi
      i=$start
    fi
    # anything else (an identifier, a spread, a call) is a non-literal element:
    # skip it to the next top-level `,` or `]`
    nonlit=1; depth=0
    while (( i <= n )); do
      c="${rest[i]}"
      if (( depth == 0 )) && [[ "$c" == [,\]] ]]; then break; fi
      # assignments, not (( depth++ )): an arithmetic command evaluating to 0
      # returns 1, which set -e would take for a failure
      if [[ "$c" == [\(\[\{] ]]; then depth=$(( depth + 1 )); fi
      if [[ "$c" == [\)\]\}] ]]; then depth=$(( depth - 1 )); fi
      (( i++ ))
    done
  done
  # a skipped element may be the registering one, so any non-literal element
  # makes the value unjudgeable unless a literal alongside it registers
  if (( nonlit )); then setup_state="nonliteral"
  elif (( ${#setup_literals} > 0 )); then setup_state="literals"
  else setup_state="empty"; fi
}

local a11y_cfg="false" a11y_findings="[]" has_axe=""
if [[ -f package.json ]] \
   && has_axe="$(jq -r 'if type != "object" then error("not an object") else
        (.devDependencies | if type == "object" then keys else [] end)
        | any(. == "axe-core" or . == "vitest-axe" or . == "jest-axe" or startswith("@axe-core/"))
      end' package.json 2>/dev/null)"; then
  if [[ "$has_axe" != "true" ]]; then
    a11y_findings="$(jq -n '[{
        id: "a11y:no_axe_package", tool: "a11y", type: "no_axe_package", severity: "MAJOR",
        message: "No axe package in package.json devDependencies (axe-core, vitest-axe, jest-axe or @axe-core/*), so no test can assert that a render is free of accessibility violations.",
        fix: "Add axe-core to devDependencies and register a toHaveNoViolations matcher in a Vitest setupFiles entry, as the bootstrap React overlay renders it (src/test/setup.ts).",
        files: ["package.json"]
      }]')" || { print -r -u2 -- "gather-react-findings.zsh: jq failed building an a11y finding"; exit 3; }
  else
    a11y_cfg="true"
    local cfg="" cand ext
    for cand in vitest vite; do
      for ext in ts mts cts js mjs cjs; do
        if [[ -z "$cfg" && -f "$cand.config.$ext" ]]; then cfg="$cand.config.$ext"; fi
      done
    done
    local registered="false" judged="true" src=""
    local setup_state="absent"
    local -a setup_literals=()
    if [[ -n "$cfg" ]]; then
      if src="$(cat -- "$cfg" 2>/dev/null)"; then
        local re='(^|[^A-Za-z0-9_$])["'\'']?setupFiles["'\'']?[[:space:]]*:(.*)$'
        local bare_re='(^|[^A-Za-z0-9_$])setupFiles([^A-Za-z0-9_$:]|$)'
        if [[ "$src" =~ $re ]]; then
          scan_setup_files "${match[2]}"
        elif [[ "$src" =~ $bare_re ]]; then
          # present but not as `setupFiles: <value>` (shorthand `{ setupFiles }`)
          setup_state="nonliteral"
        fi
      else
        judged="false"
        notes+=("a11y: $cfg could not be read — the axe matcher registration was not judged.")
      fi
    fi
    local f
    for f in "${setup_literals[@]}"; do
      f="${f#./}"
      if [[ -f "$f" ]] && grep -qF -e 'toHaveNoViolations' -e 'vitest-axe/extend-expect' -e 'jest-axe/extend-expect' -- "$f" 2>/dev/null; then
        registered="true"
      fi
    done
    if [[ "$setup_state" == "nonliteral" && "$registered" != "true" ]]; then
      judged="false"
      notes+=("a11y: the setupFiles value in $cfg has an entry with no string literal to read statically (a variable or computed expression) — the axe matcher registration was not judged.")
    fi
    if [[ "$judged" == "true" && "$registered" != "true" ]]; then
      a11y_findings="$(jq -n --arg cfg "$cfg" '[{
          id: "a11y:matcher_not_registered", tool: "a11y", type: "matcher_not_registered", severity: "MAJOR",
          message: (if $cfg == "" then "An axe package is installed, but there is no root vitest.config.* or vite.config.* whose setupFiles could register an axe matcher."
                    else "An axe package is installed, but no setupFiles entry in " + $cfg + " registers an axe matcher (toHaveNoViolations, or a vitest-axe / jest-axe extend-expect import)." end),
          fix: "List a setup file in the Vitest config setupFiles that defines the toHaveNoViolations matcher over axe-core, as the bootstrap React overlay renders it (src/test/setup.ts).",
          files: (if $cfg == "" then ["package.json"] else [$cfg] end)
        }]')" || { print -r -u2 -- "gather-react-findings.zsh: jq failed building an a11y finding"; exit 3; }
    fi
  fi
else
  notes+=("a11y: root package.json is missing or is not a valid JSON object — the axe package was not judged.")
fi

# --- lighthouse_budget ------------------------------------------------------------

local lh_cfg="false" lh_findings="[]" lh_doc=""
if [[ ! -f lighthouserc.json ]]; then
  lh_findings="$(jq -n '[{
      id: "lighthouse_budget:missing_config", tool: "lighthouse_budget", type: "missing_config", severity: "MAJOR",
      message: "No root lighthouserc.json, so no Lighthouse CI byte budget guards the page weight.",
      fix: "Add a root lighthouserc.json asserting resource-summary:script:size ≤ 307200 and resource-summary:total:size ≤ 512000 at error, as the bootstrap React overlay renders it.",
      files: ["lighthouserc.json"]
    }]')" || { print -r -u2 -- "gather-react-findings.zsh: jq failed building a lighthouse_budget finding"; exit 3; }
elif ! lh_doc="$(jq -c -s 'if length == 1 then .[0] else error("not exactly one JSON document") end' lighthouserc.json 2>/dev/null)"; then
  lh_findings="$(jq -n '[{
      id: "lighthouse_budget:invalid_config", tool: "lighthouse_budget", type: "invalid_config", severity: "MAJOR",
      message: "Root lighthouserc.json is not valid JSON (exactly one document), so Lighthouse CI cannot read its budgets.",
      fix: "Repair lighthouserc.json so it parses as a single JSON document.",
      files: ["lighthouserc.json"]
    }]')" || { print -r -u2 -- "gather-react-findings.zsh: jq failed building a lighthouse_budget finding"; exit 3; }
else
  lh_cfg="true"
  lh_findings="$(print -r -- "$lh_doc" | jq -c '
    def obj: if type == "object" then . else {} end;
    def level: if type == "string" then . elif type == "array" then (.[0] // null) else null end;
    def opts: if type == "array" then ((.[1] // {}) | obj) else {} end;
    def f($type; $sev; $aid; $msg; $fix):
      { id: ("lighthouse_budget:" + $type + (if $aid then ":" + $aid else "" end)),
        tool: "lighthouse_budget", type: $type, severity: $sev,
        message: $msg, fix: $fix, files: ["lighthouserc.json"] };
    (obj | .ci | obj | .assert | obj) as $assert
    | ($assert.assertions | obj) as $as
    | [ ( ( {key: "resource-summary:script:size", limit: 307200, label: "300 KiB of script"},
            {key: "resource-summary:total:size", limit: 512000, label: "500 KiB in total"} )
        | . as $b
        | if ($as | has($b.key) | not) then
            f("budget_missing"; "MAJOR"; $b.key;
              "lighthouserc.json asserts no " + $b.key + " budget, so page weight can grow past " + $b.label + " unnoticed.";
              "Add \"" + $b.key + "\": [\"error\", {\"maxNumericValue\": " + ($b.limit | tostring) + "}] to ci.assert.assertions.")
          else
            ($as[$b.key]) as $e | ($e | level) as $lvl | ($e | opts | .maxNumericValue) as $max
            | if $lvl != "error" or ($max | type) != "number" then
                f("budget_not_blocking"; "MINOR"; $b.key;
                  "The " + $b.key + " budget does not block: it needs level error and a numeric maxNumericValue.";
                  "Set \"" + $b.key + "\" to [\"error\", {\"maxNumericValue\": " + ($b.limit | tostring) + "}].")
              elif $max > $b.limit then
                f("budget_too_loose"; "MINOR"; $b.key;
                  "The " + $b.key + " budget allows " + ($max | tostring) + " bytes, above the family limit of " + ($b.limit | tostring) + " (" + $b.label + ").";
                  "Lower maxNumericValue for " + $b.key + " to at most " + ($b.limit | tostring) + ".")
              else empty end
          end ),
      ( ("largest-contentful-paint", "total-blocking-time", "cumulative-layout-shift", "categories:performance")
        | . as $k
        | select(($as | has($k)) and (($as[$k] | level) == "error"))
        | f("timing_assertion_blocking"; "MINOR"; $k;
            "lighthouserc.json blocks on the timing assertion " + $k + ", which flaps with runner load.";
            "Drop " + $k + " to warn or off; gate on the byte budgets instead.") ),
      ( select(($assert.preset | type) == "string" and ($assert.preset | length) > 0)
        | f("preset_present"; "MINOR"; null;
            "lighthouserc.json extends the preset " + ($assert.preset | tojson) + ", which asserts timing metrics that flap with runner load.";
            "Remove ci.assert.preset and assert the two byte budgets explicitly.") )
    ]')" || { print -r -u2 -- "gather-react-findings.zsh: jq failed auditing lighthouserc.json"; exit 3; }
fi

# `jq -R -s` with a length filter, so an EMPTY notes array yields `[]` rather than
# the [""] that `printf '%s\n' "${empty[@]}" | jq -R . | jq -s .` would invent —
# on a compliant repo `notes` is empty.
local notes_json
notes_json="$(printf '%s\n' "${notes[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')" \
  || { print -r -u2 -- "gather-react-findings.zsh: jq failed building notes"; exit 3; }

jq -n --argjson notes "$notes_json" \
  --argjson a11y_cfg "$a11y_cfg" --argjson a11y "$a11y_findings" \
  --argjson lh_cfg "$lh_cfg" --argjson lh "$lh_findings" '
{
  tooling_configured: {a11y: $a11y_cfg, lighthouse_budget: $lh_cfg},
  findings_by_tool: {a11y: $a11y, lighthouse_budget: $lh},
  coverage: null,
  notes: $notes
}
' || { print -r -u2 -- "gather-react-findings.zsh: jq failed emitting the payload"; exit 3; }
