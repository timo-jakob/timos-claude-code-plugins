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
  STYLE="$REPO_ROOT/development-react/agents/react-styleguide-reviewer.md"
  CHECKLIST="$REPO_ROOT/tests/fixtures/react-styleguide/CHECKLIST.md"
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

@test "the panel's table lists exactly two agents: react-idioms-reviewer and react-styleguide-reviewer (#3019)" {
  run panel_rows
  [ "$status" -eq 0 ]
  [ "$output" = "react-idioms-reviewer|opus|react_idioms
react-styleguide-reviewer|opus|react_styleguide" ]
}

@test "every dimension carries the topic prefix, so it can never collide with a language panel's" {
  local dims dim n=0
  dims="$(panel_rows | cut -d'|' -f3)"
  [ -n "$dims" ]
  while IFS= read -r dim; do
    [ -n "$dim" ] || continue
    n=$((n + 1))
    case "$dim" in react_*) : ;; *) printf 'unprefixed topic dimension: %s\n' "$dim" >&2; return 1 ;; esac
    # and it is none of the JavaScript panel's six
    run -1 grep -qE "\| *${dim} *\|" "$REPO_ROOT/development-javascript/skills/review/SKILL.md"
  done <<< "$dims"
  [ "$n" -eq 2 ]
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

@test "the agent's severity table fixes one severity per check (hooks CRITICAL, server state WARNING), and nothing else" {
  local mission
  mission="$(section "$AGENT" '^## Your Mission' '^## What You Look For')"
  [ -n "$mission" ]
  # each row pinned WITH its severity: swapping two severities keeps every bare
  # phrase present while changing what blocks the loop
  contains "$mission" '| A Rules of Hooks violation | **CRITICAL** |'
  contains "$mission" '| Server state fetched outside TanStack Query | **WARNING** |'
  # the Vite SPA / component-structure check is gone (#3166): two fixed checks,
  # and no row at SUGGESTION
  lacks "$mission" '| **SUGGESTION** |'
  lacks "$mission" 'Vite SPA'
  contains "$mission" 'Check the change against two React positions of this plugin family'
  contains "$mission" 'Never raise a finding above its row.'
  # ...and the other half of the ceiling: lower ONLY under the two named rules,
  # never at the reviewer's discretion — a loosened clause would let a Rules of
  # Hooks CRITICAL be demoted and the loop converge over it
  contains "$mission" 'You may file one lower only under the scope-bounded rule in *Reviewing thoroughness* or the evidence rule below.'
  # ...and below the bar nothing is reported: SUGGESTION is only the two lanes
  # of ARCHITECTURE.md *Terminating severity bars* (#3157, #3166)
  contains "$mission" 'An observation below the blocking bar is not reported.'
  contains "$mission" '`SUGGESTION` is reserved for the two lanes of ARCHITECTURE.md *Terminating severity bars*: a tool-verdict claim capped by the evidence rule, and a scope-bounded follow-up under *Scope-bounded severity*.'
  # the two check sections carry the same severities in their headings, and no
  # third check section survives
  grep -qx '### Rules of Hooks — CRITICAL' "$AGENT"
  grep -qx '### Server state outside TanStack Query — WARNING' "$AGENT"
  run -1 grep -q '^### Vite SPA' "$AGENT"
  run -1 grep -q -- '— SUGGESTION$' "$AGENT"
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
  ss="$(section "$AGENT" '^### Server state' '^### What is in scope')"
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
  contains "$p" 'Review React idioms and the styleguide only, and never repeat a finding a language reviewer owns'
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
  # the scope-bounded lane is the follow-up: line of ARCHITECTURE.md's
  # *Scope-bounded severity* (#3157), never a plain "spin off" SUGGESTION (#3166)
  contains "$t" 'is reported at **SUGGESTION** with a Description line `follow-up: <the defect, in one line>`, and it never blocks a round.'
  contains "$t" 'A plain out-of-diff observation below the bar is not reported.'
  lacks "$t" 'spin off a follow-up issue'
}

@test "the agent's Reporting Format and severity guide offer SUGGESTION only for its two lanes (#3166)" {
  local r
  r="$(section "$AGENT" '^## Reporting Format' 'EOF')"
  [ -n "$r" ]
  contains "$r" 'proposed-severity: CRITICAL|WARNING'
  contains "$r" 'for a scope-bounded follow-up (*Scope-bounded severity* above), this one line appended to the **Description** field, with the severity set to SUGGESTION: follow-up: <the defect, in one line>'
  contains "$r" 'A Rules of Hooks violation is CRITICAL and server state outside TanStack Query is WARNING.'
  contains "$r" 'An observation below the blocking bar is not reported: SUGGESTION is only the evidence-capped tool-verdict claim and the scope-bounded follow-up.'
  lacks "$r" 'a shape or structure deviation is SUGGESTION'
}

@test "no frontmatter description advertises the removed Vite SPA check (#3166)" {
  run -1 grep -Fq -e 'Vite' -- "$AGENT"
  run -1 grep -Fq -e 'Vite SPA' -- "$PANEL"
  local d
  d="$(awk '/^description:/{print; exit}' "$PANEL")"
  contains "$d" 'Rules of Hooks and TanStack Query as the one server-state default — with one specialized agent, plus a styleguide review'
}

@test "the panel carries no waived list (#3166)" {
  run -1 grep -Fq -e 'Already waived' -- "$PANEL"
  run -1 grep -Fq -e 'adjudicated_path' -- "$PANEL"
  run -1 grep -Fq -e 'REVIEW_ADJUDICATED' -- "$PANEL"
  run -1 grep -Fq -e 'what the human already waived' -- "$PANEL"
  grep -Fq -e 'also carries `fix_verification_path`, and the reviewer must be told about it.' -- "$PANEL"
}

@test "a scope with no React file is NOT APPLICABLE on a full round, never a clean []" {
  local pre
  pre="$(section "$PANEL" '^\*\*What is in scope' '^## Step 1')"
  [ -n "$pre" ]
  contains "$pre" 'A non-empty scope with no in-scope file is NOT APPLICABLE, not clean.'
  contains "$pre" 'On a **full** round whose carry holds no `react_idioms` entry, and on which the styleguide agent is not launched (*When the styleguide agent is launched*, below), report the round **not applicable** to the caller'
  contains "$pre" 'write **nothing** to the findings path'
  contains "$pre" 'On a **delta** round, apply the delta-round rules above unchanged'
  lacks "$pre" 'On a **full** round, apply the delta-round rules'
  # the carry overrides not-applicable on BOTH round kinds, and the delta [] is
  # conditional on an empty carry
  contains "$pre" 'Without launching either agent, write `[]` only when the carry is empty and the styleguide agent is not launched.'
  contains "$pre" '**On either kind of round, a carry holding a `react_idioms` entry means you launch `react-idioms-reviewer`**'
  contains "$pre" 'so that entry is accounted for even though no file in scope is React, and you write its findings as Step 4 says'
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
  contains "$pre" 'when the carry holds **no** `react_idioms` or `react_styleguide` entry, it counts as empty for this panel'
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
  contains "$s2" 'Name its missing dimension — `react_idioms` for `react-idioms-reviewer`, `react_styleguide` for `react-styleguide-reviewer` — in the Overview and in Metrics'
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
  contains "$s3" '## Warnings {every WARNING finding — normally server state outside TanStack Query, styleguide items and WCAG 2.2 AA}'
  # below WARNING only the two SUGGESTION lanes are listed (#3166)
  contains "$s3" '## Suggested follow-ups and capped claims {only the SUGGESTION findings that carry a `follow-up:` or `decides:` line}'
  contains "$s3" '(Y critical, Z warnings, W capped or follow-up suggestions)'
  lacks "$s3" '## Suggestions {'
  lacks "$s3" 'W suggestions)'
  contains "$s3" 'on a failed round, **Areas not reviewed:** the dimension whose agent failed, React idioms (`react_idioms`) or React styleguide (`react_styleguide`)'
  contains "$s3" 'React styleguide (`react_styleguide`) on a round that launched its agent'
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
  # two checks only: the Vite SPA SUGGESTION check is gone (#3166)
  contains "$enum" 'is `WARNING`; the reviewer has no other check.'
  lacks "$enum" 'Vite SPA'
}

@test "ARCHITECTURE.md's seam section names react as the review-topic table's one row" {
  local seam
  seam="$(section "$ARCH" '^- \*\*Topic panels compose beside the language panel' '^  \*\*Registering a review topic\*\*')"
  [ -n "$seam" ]
  contains "$seam" "The table's one row is **\`react\`**"
  lacks "$seam" 'The table **ships empty**'
}

# --- the styleguide reviewer (#3019) -----------------------------------------

@test "#3019 the panel launches the styleguide agent on the checklist plus a UI file, or on its own carry, and is unchanged otherwise" {
  local w
  w="$(section "$PANEL" '^\*\*When the styleguide agent is launched' '^\*\*Where you write, beside another panel')"
  [ -n "$w" ]
  contains "$w" '`react-styleguide-reviewer` is launched when **either** holds:'
  # arm 1: BOTH the checklist and a UI file, with the UI file list spelled out
  contains "$w" 'the reviewed tree has `styleguide/CHECKLIST.md` at its root **and** the round'"'"'s scope holds a UI file'
  contains "$w" 'The reviewed tree of condition 1 is the dispatch descriptor'"'"'s `worktree_root` (in hook mode, `$REVIEW_REPO`), never your cwd, and the project root on a standalone run.'
  contains "$w" 'a `.jsx` or `.tsx` source, a stylesheet (`.css`, `.scss`) or `index.html`; or'
  # arm 2: its own carry, on either kind of round, whatever the checklist
  contains "$w" 'the round'"'"'s carry holds a `react_styleguide` entry — on either kind of round, whatever the checklist and the scope'
  contains "$w" 'exactly as a carried `react_idioms` entry launches `react-idioms-reviewer`'
  # otherwise the panel is what it is today
  contains "$w" 'In every other case it is not launched, and the panel is unchanged: its report, its findings array and its carry accounting are what `react-idioms-reviewer` alone makes them'
  contains "$w" 'the `react_styleguide` dimension adds no finding'
  # a stylesheet-only scope is the styleguide agent's alone
  contains "$w" 'A stylesheet counts as in scope for this agent only: a round whose scope holds only stylesheets is not NOT APPLICABLE when this agent is launched'
  contains "$w" '`react-idioms-reviewer` then runs only when the scope holds a file of its own in-scope list above or the carry holds a `react_idioms` entry'
  # a standalone run: the effective scope, and an uninitialised submodule is not an absent checklist
  contains "$w" 'On a standalone run the scope of condition 1 is the effective one: the whole project when `$ARGUMENTS` is empty, and every file under a directory or area it names.'
  contains "$w" 'A `styleguide` submodule that the reviewed tree'"'"'s `.gitmodules` declares but whose directory is missing or empty is not an absent checklist.'
  contains "$w" 'your report says that the styleguide submodule is not initialised (`git submodule update --init`) and that `react_styleguide` was not reviewed'
  contains "$w" 'A full round on which neither agent is launched is NOT APPLICABLE, as above.'
  contains "$w" 'Beside a language panel that verdict is this panel'"'"'s own: on a full round that the language panel reports NOT APPLICABLE (a stylesheet or `index.html` with no JavaScript or TypeScript file)'
  contains "$w" 'its verdict decides the round and the driving session joins none of this panel'"'"'s findings (#3372)'
}

@test "#3019 launched by its carry alone without the checklist, the agent accounts for the carry and raises nothing new" {
  local w s1
  w="$(section "$PANEL" '^\*\*When the styleguide agent is launched' '^\*\*Where you write, beside another panel')"
  [ -n "$w" ]
  contains "$w" 'Launched by its carry alone without the checklist (a fix pass removed the submodule, say), the agent accounts for its carried entries — confirmed, re-raised or unconfirmed — and raises no new finding'
  s1="$(section "$PANEL" '^## Step 1' '^## Step 2')"
  [ -n "$s1" ]
  contains "$s1" '`checklist: <worktree_root>/styleguide/CHECKLIST.md`'
  contains "$s1" '`checklist: absent — account for the carry only, raise no new finding`'
  # each agent gets only its own dimension's carry
  contains "$s1" 'hands each agent only its own dimension'"'"'s entries'
  contains "$s1" 'is added only when the map holds that agent'"'"'s dimension (#2010)'
  # ...and the agent says the same from its side
  local c
  c="$(section "$STYLE" '^### The checklist' '^### WCAG')"
  [ -n "$c" ]
  contains "$c" '**With no checklist, raise no checklist finding.**'
  contains "$c" 'report each one as confirmed, re-raised or unconfirmed, and nothing else'
}

@test "#3019 the styleguide agent exists, is read-only, and its frontmatter name matches the table" {
  [ -f "$STYLE" ]
  [ "$(awk -F': *' '/^name:/{print $2; exit}' "$STYLE")" = "react-styleguide-reviewer" ]
  [ "$(awk -F': *' '/^model:/{print $2; exit}' "$STYLE")" = "opus" ]
  [ "$(awk -F': *' '/^tools:/{print $2; exit}' "$STYLE")" = "Read, Grep, Glob" ]
  [ "$(panel_rows | grep -c '^react-styleguide-reviewer|opus|react_styleguide$')" -eq 1 ]
}

@test "#3019 the agent pins the [review] item format under ## Review, and every such v0.1.1 fixture line matches it (ten)" {
  local c
  c="$(section "$STYLE" '^### The checklist' '^### WCAG')"
  [ -n "$c" ]
  contains "$c" '**Read `styleguide/CHECKLIST.md` at the root of the reviewed tree on every run.**'
  contains "$c" 'that path is the file: read it and no other, and judge its absence there, never at a path relative to your cwd'
  contains "$c" 'Take your items from the lines under its `## Review` heading, up to the next level-two heading'
  contains "$c" '- [ ] [review] <text> ([rule](STYLEGUIDE.md#<anchor>))'
  contains "$c" '**Hard-code no item.**'
  contains "$c" 'a bump of the submodule changes what you check'
  # the fixture: every item line under ## Review is a [review] line of the full form
  local review all full
  review="$(awk '/^## Review$/ { on = 1; next } on && /^## / { exit } on && /^- \[ \] / { print }' "$CHECKLIST")"
  [ -n "$review" ]
  all="$(printf '%s\n' "$review" | grep -c '^- \[ \] ')"
  full="$(printf '%s\n' "$review" | grep -cE '^- \[ \] \[review\] .+ \(\[rule\]\(STYLEGUIDE\.md#[a-z0-9-]+\)\)$')"
  [ "$all" -eq 10 ]
  [ "$full" -eq 10 ]
  # and no [review] item lives outside that section
  [ "$(grep -c '^- \[ \] \[review\] ' "$CHECKLIST")" -eq 10 ]
}

@test "#3019 the verbatim-quote rule applied to the fixture yields the AC's item and anchor" {
  local c line text anchor
  c="$(section "$STYLE" '^### The checklist' '^### WCAG')"
  [ -n "$c" ]
  contains "$c" 'quotes the item'"'"'s text **verbatim** — the words between the `[review]` tag and the `([rule](` link that ends it, without the spaces around them — and names its rule link'"'"'s `STYLEGUIDE.md#<anchor>` target'
  contains "$c" '"There is at most one primary action per view.", whose rule is `STYLEGUIDE.md#buttons-and-actions`'
  # apply the rule as the agent states it to the fixture's line
  line="$(grep -F '[review] There is at most one primary action per view.' "$CHECKLIST")"
  [ -n "$line" ]
  text="$(printf '%s\n' "$line" | sed -E 's/^- \[ \] \[review\] //; s/ \(\[rule\]\(.*$//')"
  anchor="$(printf '%s\n' "$line" | sed -E 's/.*\(\[rule\]\((STYLEGUIDE\.md#[a-z0-9-]+)\)\)$/\1/')"
  [ "$text" = "There is at most one primary action per view." ]
  [ "$anchor" = "STYLEGUIDE.md#buttons-and-actions" ]
}

@test "#3019 the agent fixes WARNING for a [review] violation and excludes [design] and [mechanical] items" {
  local mission c rf
  mission="$(section "$STYLE" '^## Your Mission' '^## What You Look For')"
  [ -n "$mission" ]
  contains "$mission" '| A violated `[review]` item of `styleguide/CHECKLIST.md` | **WARNING** |'
  contains "$mission" '| A WCAG 2.2 AA violation you can show in the source | **WARNING** |'
  lacks "$mission" '| **CRITICAL** |'
  lacks "$mission" '| **SUGGESTION** |'
  contains "$mission" 'Never raise a finding above its row.'
  grep -qx '### The checklist'"'"'s `\[review\]` items — WARNING' "$STYLE"
  c="$(section "$STYLE" '^### The checklist' '^### WCAG')"
  contains "$c" '**Ignore `[design]` and `[mechanical]` items, wherever they appear.**'
  contains "$c" 'Report nothing against either, even when the change plainly breaks one.'
  contains "$c" 'That bars citing either kind of item, not the WCAG row below: a WCAG 2.2 AA violation you can show in the source is still a WARNING under its success criterion when one of those items covers the same ground.'
  contains "$c" 'Never paraphrase the text and never invent an identifier'
  # the Reporting Format gives the item and the rule their own lines
  rf="$(section "$STYLE" '^## Reporting Format' 'EOF')"
  [ -n "$rf" ]
  contains "$rf" 'item: "<the item'"'"'s text, verbatim>"'
  contains "$rf" 'rule: STYLEGUIDE.md#<anchor>'
  contains "$rf" '(the pair repeats when one location breaks several items)'
  contains "$rf" 'A violated `[review]` item is WARNING and a WCAG 2.2 AA violation you can show in the source is WARNING.'
}

@test "#3019 a WCAG 2.2 AA violation is WARNING and the agent never reads the a11y switch" {
  local w
  w="$(section "$STYLE" '^### WCAG 2.2 AA' '^### Only what the source shows')"
  [ -n "$w" ]
  grep -qx '### WCAG 2.2 AA — WARNING' "$STYLE"
  contains "$w" '**A WCAG 2.2 AA violation you can show in the source is a WARNING, whatever the repo'"'"'s accessibility gate does.**'
  contains "$w" 'You never read the repo'"'"'s `a11y: warn | block` switch'
  contains "$w" 'a positive `tabIndex`'
  contains "$w" 'a fixed pixel width above 320 px on a layout container'
}

@test "#3019 the agent reports only source-observable violations, with file and line, and caps a tool verdict" {
  local o e
  o="$(section "$STYLE" '^### Only what the source shows' '^### What is in scope')"
  [ -n "$o" ]
  contains "$o" 'Report only what you can show in the source, with **file and line**.'
  contains "$o" 'you never claim a rendered result'
  contains "$o" '"axe would flag this"'
  contains "$o" 'the evidence rule below applies to it'
  e="$(section "$STYLE" '^## The evidence rule' '^## Reporting Format')"
  [ -n "$e" ]
  contains "$e" 'decides: <the exact command that settles it'
  contains "$e" 'proposed-severity: CRITICAL|WARNING'
  # the agent's in-scope list is the panel's UI file list
  local s
  s="$(section "$STYLE" '^### What is in scope' '^## Reviewing thoroughness')"
  contains "$s" '`.jsx` and `.tsx` sources, stylesheets (`.css`, `.scss`) and `index.html`'
}

@test "#3019 the styleguide agent's Reviewing thoroughness keeps the enumerate rule and both fail-closed carve-outs" {
  local t
  t="$(section "$STYLE" '^## Reviewing thoroughness \(#982\)' '^## The evidence rule')"
  [ -n "$t" ]
  contains "$t" 'Three buttons with title-case labels are three WARNING findings.'
  contains "$t" '**(1) A defect the change under review *introduces* is always in-scope**'
  contains "$t" 'treat it as introduced and keep full severity (fail closed)'
  contains "$t" '**(2) When the issue'"'"'s stated scope is not provided in your prompt**'
  contains "$t" 'is reported at **SUGGESTION** with a Description line `follow-up: <the defect, in one line>`, and it never blocks a round.'
  lacks "$t" 'treat it as pre-existing'
  lacks "$t" 'spin off a follow-up issue'
}

@test "#3019 a twice-failed styleguide agent writes no findings file and the report names react_styleguide as not reviewed" {
  local s2 s3
  s2="$(section "$PANEL" '^## Step 2' '^## Step 3')"
  s3="$(section "$PANEL" '^## Step 3' '^## Step 4')"
  [ -n "$s2" ]
  [ -n "$s3" ]
  contains "$s2" 'Wait for every launched agent to complete'
  contains "$s2" 're-launch it once. If it fails again:'
  contains "$s2" '`react_styleguide` for `react-styleguide-reviewer` — in the Overview and in Metrics'
  contains "$s2" 'Do not write the findings file at all.'
  contains "$s3" '**Areas not reviewed:** the dimension whose agent failed'
  contains "$s3" 'React styleguide (`react_styleguide`)'
}

@test "#3019 ARCHITECTURE.md registers react_styleguide in the dimension enum section, with its severity bar" {
  local enum
  enum="$(section "$ARCH" '^\*\*Dimension enum\.\*\*' '^### Scope-bounded severity')"
  [ -n "$enum" ]
  contains "$enum" 'two dimensions, **`react_idioms`** (`react-idioms-reviewer`) and **`react_styleguide`** (`react-styleguide-reviewer`, #3019)'
  contains "$enum" '`react_styleguide` runs only when the reviewed repo has `styleguide/CHECKLIST.md` at its root'
  contains "$enum" 'a WCAG 2.2 AA violation the reviewer can show in the source, are each `WARNING`, whatever the repo'"'"'s accessibility gate does'
  contains "$enum" '`[design]` and `[mechanical]` items are never checked'
  lacks "$enum" 'exactly one dimension, **`react_idioms`**'
}

@test "#3019 the agent leaves hooks and JS-generic findings to its neighbours and checks only the file's current items" {
  local intro c w s1 s4
  intro="$(section "$STYLE" '^You are a UI styleguide specialist' '^## Your Mission')"
  [ -n "$intro" ]
  contains "$intro" 'the items its checklist tags `[review]`, which no linter can decide, and WCAG 2.2 AA'
  contains "$intro" 'Rules of Hooks and server state belong to `react-idioms-reviewer` beside you'
  c="$(section "$STYLE" '^### The checklist' '^### WCAG')"
  contains "$c" 'Never check an item from memory, and never check an item the file no longer holds.'
  contains "$c" 'A `[design]` item is checked on the design spec before anything is built, and a `[mechanical]` item by a tool in CI.'
  contains "$c" 'A line under `## Review` that does not have the form above is not an item for you either.'
  contains "$c" 'When `styleguide/CHECKLIST.md` is absent, or your scope line says `checklist: absent`, say so in your report and raise no new finding, under either row.'
  contains "$c" 'When the file is present but its `## Review` section holds no line of the form above, say so in your report and still check the WCAG row below.'
  contains "$c" 'Name in your report every line under `## Review` you dropped for its form.'
  # one location that breaks several items is one finding with a pair per item
  contains "$c" 'file one finding there that gives every one of them as its own `item:` and `rule:` pair, never one finding per item'
  contains "$c" 'several WCAG success criteria: file one finding there that names every one of them'
  w="$(section "$STYLE" '^### WCAG 2.2 AA' '^### Only what the source shows')"
  contains "$w" 'Name the success criterion in the finding (for example `2.1.1`).'
  contains "$w" 'When `[review]` items also cover the violation, cite each of them as above in the same finding rather than filing a second one'
  # the panel launches the round's agents in parallel and joins their arrays
  s1="$(section "$PANEL" '^## Step 1' '^## Step 2')"
  contains "$s1" 'spawn the agents below that this round launches, in parallel'
  contains "$s1" '`react-idioms-reviewer` runs as the scope and carry rules above say, and `react-styleguide-reviewer` only as *When the styleguide agent is launched* (above) says.'
  contains "$s1" 'Each is defined in this plugin'"'"'s `agents/` directory and already knows what to look for'
  s4="$(section "$PANEL" '^## Step 4' 'EOF')"
  contains "$s4" 'take each launched agent'"'"'s fenced `json` block'
  contains "$s4" 'and concatenate them as this round'"'"'s findings array'
  contains "$s4" 'every launched agent (Step 2 owns the failed case'
}
