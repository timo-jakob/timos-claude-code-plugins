#!/usr/bin/env bats
#
# The development-react review panel (#959) — the first TOPIC panel, which the
# review loop runs beside /development-javascript:review on a React repo.
#
# The loop duties every panel shares (the empty-scope and carry rules, the
# confirmation-count report, the prompt lines) are swept by
# review-loop-budget-consistency.bats, and the reviewer's evidence rule by
# reviewer-evidence-rule.bats. What is pinned here is this panel's own contract:
# the one dimension it emits and how it is spelled, the fixed severity per check
# that lets the loop converge, the #982 enumerate-every-instance rule, and the
# two topic-panel rules — a round with nothing React in it is NOT APPLICABLE,
# and a failed dimension writes no findings file.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PANEL="$REPO_ROOT/development-react/skills/review/SKILL.md"
  AGENT="$REPO_ROOT/development-react/agents/react-idioms-reviewer.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
}

# section <file> <start-ere> <end-ere> — a sed-scoped slice, whitespace flattened
# (the prose is hard-wrapped, so a line-oriented needle is blind to a phrase the
# wrap splits). ERE, because BSD sed's BRE has no alternation.
# An end pattern that matches nothing would widen the slice to end of file and
# turn every `lacks` into a whole-tail check, so it prints nothing instead (every
# caller asserts a non-empty slice). `EOF` is the one deliberate to-the-end slice.
section() {
  if [ "$3" != "EOF" ]; then grep -qE -- "$3" "$1" || return 0; fi
  sed -nE "/$2/,/$3/p" "$1" | tr -s '[:space:]' ' '
}

# The panel's Step 1 table rows, one `agent|model|dimension` per line.
panel_rows() {
  awk -F'|' '
    /^## Step 1/ { on = 1; next }
    on && /^## / { exit }
    on && /^\|/ {
      a = $2; m = $3; d = $4
      gsub(/^[ \t]+|[ \t]+$/, "", a); gsub(/^[ \t]+|[ \t]+$/, "", m); gsub(/^[ \t]+|[ \t]+$/, "", d)
      if (a == "Agent" || a ~ /^-+$/) next
      print a "|" m "|" d
    }
  ' "$PANEL"
}

@test "the panel dispatches exactly one agent, react-idioms-reviewer, under react_idioms" {
  run panel_rows
  [ "$status" -eq 0 ]
  [ "$output" = "react-idioms-reviewer|opus|react_idioms" ]
}

@test "the dimension carries the topic prefix, so it can never collide with a language panel's" {
  local dim
  dim="$(panel_rows | cut -d'|' -f3)"
  [ -n "$dim" ]
  case "$dim" in react_*) : ;; *) printf 'unprefixed topic dimension: %s\n' "$dim" >&2; return 1 ;; esac
  # and it is none of the JavaScript panel's six
  run -1 grep -qE "\| *${dim} *\|" "$REPO_ROOT/development-javascript/skills/review/SKILL.md"
}

@test "every finding is stamped with the panel's dimension and reviewer through the injected prompt" {
  local s1
  s1="$(section "$PANEL" '^## Step 1' '^## Step 2')"
  [ -n "$s1" ]
  contains "$s1" 'dimension ("{DIMENSION}")'
  contains "$s1" 'reviewer ("{AGENT NAME}")'
  contains "$s1" 'round ({ROUND})'
  contains "$s1" 'per the Review finding schema in ARCHITECTURE.md'
  contains "$s1" 'Analyze all React code in scope'
}

@test "the named agent exists, is read-only, and its frontmatter name matches the table" {
  [ -f "$AGENT" ]
  [ "$(awk -F': *' '/^name:/{print $2; exit}' "$AGENT")" = "react-idioms-reviewer" ]
  [ "$(awk -F': *' '/^model:/{print $2; exit}' "$AGENT")" = "opus" ]
  [ "$(awk -F': *' '/^tools:/{print $2; exit}' "$AGENT")" = "Read, Grep, Glob" ]
}

@test "the agent's severity table fixes one severity per check (hooks CRITICAL, server state WARNING, shape SUGGESTION)" {
  local mission
  mission="$(section "$AGENT" '^## Your Mission' '^## What You Look For')"
  [ -n "$mission" ]
  # each row pinned WITH its severity: swapping two severities keeps every bare
  # phrase present while changing what blocks the loop
  contains "$mission" '| A Rules of Hooks violation | **CRITICAL** |'
  contains "$mission" '| Server state fetched outside TanStack Query | **WARNING** |'
  contains "$mission" '| A Vite SPA shape or component-structure deviation | **SUGGESTION** |'
  contains "$mission" 'Never raise a finding above its row.'
  # ...and the other half of the ceiling: lower ONLY under the two named rules,
  # never at the reviewer's discretion — a loosened clause would let a Rules of
  # Hooks CRITICAL be demoted and the loop converge over it
  contains "$mission" 'You may file one lower only under the scope-bounded rule in *Reviewing thoroughness* or the evidence rule below.'
  # the three check sections carry the same severities in their headings
  grep -qx '### Rules of Hooks — CRITICAL' "$AGENT"
  grep -qx '### Server state outside TanStack Query — WARNING' "$AGENT"
  grep -qx '### Vite SPA shape and component structure — SUGGESTION' "$AGENT"
}

@test "the hooks check covers the conditional, early-return, loop and outside-a-React-function shapes" {
  local hooks
  hooks="$(section "$AGENT" '^### Rules of Hooks' '^### Server state')"
  [ -n "$hooks" ]
  contains "$hooks" 'called **conditionally**'
  contains "$hooks" '**after an early `return`**'
  contains "$hooks" '**inside a loop**'
  contains "$hooks" 'or inside a callback: an event handler, an effect body, a `.map` callback, a `useMemo` or `useCallback` factory'
  contains "$hooks" '**outside a React function**'
  # ...whose definition covers the unnamed components, so correct hooks inside a
  # forwardRef/memo callback or an anonymous default export are never a CRITICAL
  contains "$hooks" '**or an unnamed function that is still a component**'
  contains "$hooks" 'one passed straight to `forwardRef` or `memo`'
  contains "$hooks" 'an anonymous `export default` function that renders'
  contains "$hooks" 'whether or not the function has a name'
  # ...and a component is recognised by its NAME, never by what it returns: a
  # gate or provider returning children or null is correct code, not a CRITICAL
  contains "$hooks" '**What a component returns never decides it**'
  contains "$hooks" 'one that returns `children`, `null`, `createElement(...)` or another component'"'"'s result'
  lacks "$hooks" 'uppercase letter and that returns JSX'
  # lazy() takes a loader, not a component — a hook there IS a violation
  lacks "$hooks" '`lazy`'
  contains "$hooks" '**stale closure you can show**'
  # the stable-by-contract exemptions that keep the stale-closure check from
  # blocking every effect that omits a setter
  contains "$hooks" 'A value that is stable by contract is **not** a finding'
  # React 19's use() may be conditional — without this every conditional use()
  # would be a loop-blocking CRITICAL
  contains "$hooks" 'is the one documented exception: it may be called conditionally'
  contains "$hooks" 'Do not report it.'
}

@test "the server-state check names TanStack Query as the one default and the alternatives it flags" {
  local ss
  ss="$(section "$AGENT" '^### Server state' '^### Vite SPA')"
  [ -n "$ss" ]
  contains "$ss" "**TanStack Query (\`@tanstack/react-query\`) is the family's one blessed server-state default.**"
  contains "$ss" '**Ad-hoc fetching in an effect**'
  contains "$ss" '**Server data copied into a client store**'
  local lib
  for lib in '`swr`' '`@apollo/client`' '`urql`' '`react-relay`' '`@reduxjs/toolkit/query`'; do
    contains "$ss" "$lib"
  done
  # the exemptions that keep a WebSocket or browser-API effect from being a
  # blocking WARNING
  contains "$ss" 'Not a finding: an effect that talks to a non-server system'
  contains "$ss" 'client state kept in `useState` or a store'
}

@test "the Vite SPA / component-structure check names each shape it reports" {
  local v
  v="$(section "$AGENT" '^### Vite SPA' '^### What is in scope')"
  [ -n "$v" ]
  contains "$v" '`react-scripts` (Create React App)'
  contains "$v" 'webpack or Parcel configured to build it'
  contains "$v" 'Next.js or Remix'
  contains "$v" 'no root `index.html` loading the entry module'
  contains "$v" 'mounting more than one React root'
  contains "$v" 'a new class component'
  contains "$v" "**defined inside another component's body**"
  contains "$v" '`react-refresh/only-export-components`'
  contains "$v" 'PascalCase'
  # aligned with the bootstrap overlay's allowConstantExport: a constant export
  # beside a component is exempt, so the reviewer and a bootstrapped repo agree
  contains "$v" 'A **constant** exported beside a component'
  contains "$v" 'is not a finding'
  contains "$v" '`allowConstantExport: true`'
}

@test "the reviewer's exemption for constant exports matches the bootstrap overlay's ESLint configs" {
  # the claim above is only true while both templates keep the option; derive it
  # from them rather than trusting the prose
  local t
  for t in \
    "$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript/react/eslint.config.js" \
    "$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript/react/contract-consumer/eslint.config.js"; do
    [ -f "$t" ]
    grep -qF '"react-refresh/only-export-components": ["warn", { allowConstantExport: true }]' "$t"
  done
}

@test "the agent's own in-scope list covers plain .js/.ts modules and the SPA entry files" {
  local s
  s="$(section "$AGENT" '^### What is in scope' '^## Reviewing thoroughness')"
  [ -n "$s" ]
  contains "$s" '`.jsx`, `.tsx`, `.js` and `.ts` sources — hooks live in plain `.ts` files too'
  contains "$s" '`vite.config.*` and `index.html`'
  # ...and the exclusion that keeps build output and generated code out of scope
  contains "$s" 'Build output, installed dependencies and generated code'
  contains "$s" 'are not in scope: nobody edits them by hand'
}

@test "the agent leaves JavaScript-generic findings to the language panel beside it" {
  local intro
  intro="$(section "$AGENT" '^You are a React specialist' '^## Your Mission')"
  [ -n "$intro" ]
  contains "$intro" "belongs to that panel's six reviewers, so leave it to them"
  contains "$intro" 'a duplicate the loop has to consolidate, not extra coverage'
}

@test "the panel's topic-boundary duties: stay out of language dimensions, disclose a non-JS language panel" {
  local p
  p="$(section "$PANEL" '^\*\*You are a topic panel' '^\*\*Scope:')"
  [ -n "$p" ]
  # the duties themselves, with their trigger — not only their consequence phrases
  contains "$p" 'Review React idioms only, and never repeat a finding a language reviewer owns'
  contains "$p" 'When the language panel beside you is **not** the JavaScript one'
  contains "$p" 'say so in your report: no reviewer covers the JavaScript-generic dimensions of that change'
}

@test "the reviewer enumerates EVERY instance of a pattern in one round (#982)" {
  local t
  t="$(section "$AGENT" '^## Reviewing thoroughness \(#982\)' '^## The evidence rule')"
  [ -n "$t" ]
  contains "$t" '**Enumerate every instance of a pattern — never one exemplar.**'
  contains "$t" 'report **every** occurrence in the diff'
  contains "$t" 'Three conditional hook calls are three CRITICAL findings.'
}

@test "the reviewer's scope-bounded severity rule keeps both fail-closed carve-outs" {
  # the Mission section lets a finding go below its row only under this rule, so
  # losing a carve-out would let the reviewer demote real introduced blockers
  local t
  t="$(section "$AGENT" '^## Reviewing thoroughness \(#982\)' '^## The evidence rule')"
  [ -n "$t" ]
  contains "$t" '**Scope-bounded severity.**'
  contains "$t" '**(1) A defect the change under review *introduces* is always in-scope**'
  contains "$t" 'treat it as introduced and keep full severity (fail closed)'
  contains "$t" '**(2) When the issue'"'"'s stated scope is not provided in your prompt**'
  contains "$t" 'never demote on a scope you inferred from the diff or branch name'
  lacks "$t" 'treat it as pre-existing'
}

@test "a scope with no React file is NOT APPLICABLE on a full round, never a clean []" {
  local pre
  pre="$(section "$PANEL" '^\*\*What is in scope' '^## Step 1')"
  [ -n "$pre" ]
  contains "$pre" 'A non-empty scope with no in-scope file is NOT APPLICABLE, not clean.'
  contains "$pre" 'On a **full** round whose carry holds no `react_idioms` entry, report the round **not applicable** to the caller'
  contains "$pre" 'write **nothing** to the findings path'
  contains "$pre" 'On a **delta** round, apply the delta-round rules above unchanged'
  lacks "$pre" 'On a **full** round, apply the delta-round rules'
  # the carry overrides not-applicable on BOTH round kinds, and the delta [] is
  # conditional on an empty carry
  contains "$pre" 'write `[]` only when the carry is empty'
  contains "$pre" '**On either kind of round, a carry holding a `react_idioms` entry means you launch the agent**'
  # the in-scope file set the not-applicable verdict is judged against — hooks
  # live in plain .js/.ts modules, so dropping them would skip real React code
  contains "$pre" '`.jsx` and `.tsx`, and `.js` and `.ts` files, because hooks live in plain modules too'
  contains "$pre" '`package.json`, `vite.config.*` and `index.html`'
  # ...and the exclusion, which decides which scopes are NOT APPLICABLE too
  contains "$pre" 'Build output, installed dependencies and generated code'
  contains "$pre" '(`node_modules/`, `dist/`, `build/`, `coverage/`, and a client generated from an OpenAPI or proto contract) are not'
  # the React version rides on the scope line, since React 19 changed the hook rules
  contains "$pre" '**Tell the agent the runtime.**'
  contains "$pre" 'or `react version unknown` when none declares'
  # as a topic panel, its not-applicable never decides the round
  contains "$pre" "the language panel's verdict alone decides the round"
  # and the shared carry is scoped to this panel's own dimension
  contains "$pre" 'when the carry holds **no** `react_idioms` entry, it counts as empty for this panel'
}

@test "a failed dimension writes NO findings file, and Step 4 writes only a completed agent's array" {
  local s2 s4
  s2="$(section "$PANEL" '^## Step 2' '^## Step 3')"
  s4="$(section "$PANEL" '^## Step 4' 'EOF')"
  [ -n "$s2" ]
  [ -n "$s4" ]
  # one retry before failing, as every sibling panel pins: a single transient
  # timeout must not fail the whole loop round
  contains "$s2" 're-launch it once. If it fails again:'
  contains "$s2" 'Name the missing `react_idioms` dimension in the Overview and in Metrics'
  contains "$s2" 'Do not write the findings file at all.'
  contains "$s2" 'Report the round as **failed** to the caller'
  contains "$s2" 'a failed round fails the whole loop round'
  contains "$s4" '**only when the agent completed**'
  contains "$s4" "**never** the round's shared \`findings_path\`"
  # the heading a stdout caller and the joiner pick the array up by
  contains "$s4" 'under a `## Findings (JSON)` heading'
  # the standalone default path and round
  contains "$s4" '`review-findings-round-<round>.json` when none is given'
  contains "$s4" '(default `round` 1)'
  # the empty-delta limit on the failed-round gate (the JS panel's suite pins its twin)
  contains "$s2" 'an empty-delta round that carries nothing launches none'
  # ...and that empty-delta [] is routed by the write rule, never onto the shared file
  contains "$s2" "never to the round's shared \`findings_path\`, where a \`[]\` would replace the language panel's findings"
}

@test "Step 3's report groups findings by the severity they CARRY, and names an unreviewed dimension" {
  local s3
  s3="$(section "$PANEL" '^## Step 3' '^## Step 4')"
  [ -n "$s3" ]
  # grouped by carried severity, so a finding filed below its row is not listed
  # under Critical Issues
  # each placeholder pinned WITH the heading above it (section() collapses the
  # blank line), so swapping two placeholders between headings reds here
  contains "$s3" '## Critical Issues {every CRITICAL finding — normally Rules of Hooks violations}'
  contains "$s3" '## Warnings {every WARNING finding — normally server state outside TanStack Query}'
  contains "$s3" '## Suggestions {every SUGGESTION finding'
  contains "$s3" 'component-structure deviations, plus any finding the agent filed below its row}'
  contains "$s3" 'on a failed round, **Areas not reviewed:** React idioms'
}

@test "beside a language panel the panel writes only to its OWN paths, never the round's shared file or sidecar" {
  local w
  w="$(section "$PANEL" '^\*\*Where you write, beside another panel' '^\*\*Tell the agent the runtime')"
  [ -n "$w" ]
  contains "$w" '**only to paths the driving session or the hook gave this panel specifically**'
  # the rule reaches every write in the skill, the later Steps included
  contains "$w" '**Every** rule in this skill that tells you to write "the findings file", a `[]` or the carry sidecar'
  contains "$w" 'Steps 2 and 4 included'
  contains "$w" 'Given only the round'"'"'s shared paths, write **neither** file'
  contains "$w" 'return the array under `## Findings (JSON)` and the per-entry lines in your report'
  contains "$w" '`$REVIEW_FINDINGS.carry.json` sidecar'
  contains "$w" 'Run standalone, as the only panel, write both as the rules above say.'
}

@test "ARCHITECTURE.md registers react_idioms in the dimension enum section, with its severity bar" {
  local enum
  # the enum's own subsection, not a whole-file grep that the dispatch section
  # would also satisfy
  enum="$(section "$ARCH" '^\*\*Dimension enum\.\*\*' '^### Scope-bounded severity')"
  [ -n "$enum" ]
  contains "$enum" '**`react_idioms`** (`react-idioms-reviewer`)'
  contains "$enum" '`development-react` (#959) is the first **topic** panel'
  contains "$enum" 'a Rules of Hooks violation'
  contains "$enum" 'is `CRITICAL`, server state fetched outside TanStack Query'
}

@test "ARCHITECTURE.md's seam section names react as the review-topic table's one row" {
  local seam
  seam="$(section "$ARCH" '^- \*\*Topic panels compose beside the language panel' '^  \*\*Registering a review topic\*\*')"
  [ -n "$seam" ]
  contains "$seam" "The table's one row is **\`react\`**"
  lacks "$seam" 'The table **ships empty**'
}
