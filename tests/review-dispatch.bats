#!/usr/bin/env bats
#
# Behavioral tests for review-dispatch.zsh (#560): the review-panel invocation
# contract for the autonomous review loop (epic #557). The orchestrator must
# pick the right language panel WITHOUT language-specific knowledge (mirroring
# /development:maintenance dispatch), scope review to the STORY'S DIFF (so the
# loop never re-litigates untouched legacy code), and turn an unsupported repo
# type into a TYPED escalation rather than a crash.
#
# Detection is stubbed via the DETECT_STACK_BIN seam so language selection is
# deterministic and needs no git/gh probing; git itself runs against real temp
# repos so the diff-scoping is exercised for real.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"

  # Fake detect-stack.sh: echoes the languages JSON from $DETECT_LANGS_JSON.
  STUB="$BATS_TEST_TMPDIR/detect-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$DETECT_LANGS_JSON"
EOF
  chmod +x "$STUB"

  # A real temp git repo with a committed base on `main`.
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/README.md"
  echo old > "$R/legacy.py"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
}

plan() {  # $1 = languages json ; rest = extra flags
  local langs="$1"; shift
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON="$langs" \
    zsh "$S" plan --repo "$R" --base main "$@"
}

# ---- repo-type → panel mapping (adding a language needs no orchestrator edit)

@test "plan: python repo maps to development-python:review" {
  plan '{"languages":["python"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "python" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-python:review" ]
}

@test "plan: swift repo maps to development-swift:review (same invocation)" {
  plan '{"languages":["swift"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-swift:review" ]
}

@test "plan: java repo maps to development-java:review" {
  plan '{"languages":["java"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-java:review" ]
}

@test "plan: go repo maps to development-go:review (#872)" {
  # Slice C gave Go a conforming panel; without `go` in the supported set the
  # review loop would escalate a Go repo as unsupported_repo_type instead.
  plan '{"languages":["go"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-go:review" ]
}

@test "plan: the unsupported-repo-type error advertises go among the supported panels (#872)" {
  plan '{"languages":["rust"]}'
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.supported | index("go") != null' >/dev/null
}

@test "plan: findings_path is a well-known per-round path in the worktree" {
  plan '{"languages":["python"]}' --round 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .round)" = "2" ]
  [ "$(echo "$output" | jq -r .findings_path)" = "$R/.review/findings-round-2.json" ]
}

# ---- diff-scoping: only the story's changed files are the review scope

@test "plan: changed_files are the story's diff, not the whole repo" {
  echo "print(1)" > "$R/app.py"        # new (untracked) file = the story
  plan '{"languages":["python"]}'
  [ "$status" -eq 0 ]
  # app.py is in scope; the untouched committed legacy.py is not
  echo "$output" | jq -e '.changed_files | index("app.py")' >/dev/null
  echo "$output" | jq -e '.changed_files | index("legacy.py") | not' >/dev/null
}

# ---- unsupported / ambiguous repo type is a TYPED escalation, not a crash

@test "plan: unsupported repo type (rust/ts) exits 3 with a typed error" {
  # Was go/typescript until #872 gave Go a panel; the case still needs a pair
  # with no panel on either side, so it moved to rust/javascript.
  plan '{"languages":["rust","javascript"]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: a supported language alongside an unsupported one still dispatches (#872)" {
  # go+javascript is no longer the unsupported case: go has a panel, javascript
  # does not, so the single supported language wins rather than escalating.
  plan '{"languages":["go","javascript"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-go:review" ]
}

@test "plan: no detected languages exits 3 with a typed error" {
  plan '{"languages":[]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: multiple panels with no primary is an ambiguous typed error (exit 3)" {
  plan '{"languages":["python","java"]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
  echo "$output" | jq -e '.candidates | index("python") and index("java")' >/dev/null
}

@test "plan: .maintenance.yml primary disambiguates multiple panels" {
  printf 'primary: java\n' > "$R/.maintenance.yml"
  plan '{"languages":["python","java"]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "java" ]
}

# ---- claude-plugin fallback repo_type (#809): a plugin repo detects no
# language, so is_claude_plugin selects the plugin panel — but ONLY as a
# fallback: a language always wins, and ambiguity is never defused by it.

@test "plan: #809 no language + is_claude_plugin maps to the plugin panel" {
  plan '{"languages":[],"is_claude_plugin":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-claude-plugin:review" ]
}

@test "plan: #809 a language always wins over the plugin fallback (no regression)" {
  plan '{"languages":["python"],"is_claude_plugin":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "python" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-python:review" ]
}

@test "plan: #809 no language and is_claude_plugin false stays a typed error" {
  plan '{"languages":[],"is_claude_plugin":false}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #809 absent is_claude_plugin key defaults to false, no crash" {
  # an older detect-stack that omits the key must fall through cleanly
  plan '{"languages":[]}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #809 the plugin fallback does not defuse language ambiguity" {
  plan '{"languages":["python","java"],"is_claude_plugin":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
}

# ---- kubernetes fallback repo_type (#1153): a GitOps repo detects no language
# either — its content is charts, overlays and Argo CD resources. Same fallback
# rules as claude-plugin, plus an ORDERING rule between the two.

@test "plan: #1153 no language + is_kubernetes maps to the kubernetes panel" {
  plan '{"languages":[],"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "kubernetes" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-kubernetes:review" ]
}

@test "plan: #1153 a language always wins over the kubernetes fallback" {
  # the language-first principle: a Go service whose repo also carries a Helm
  # chart is reviewed by the Go panel, not the manifest panel
  plan '{"languages":["go"],"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "go" ]
  # .review_skill too, not just .repo_type: it is the field the orchestrator
  # actually invokes, and the #809 twin above asserts both
  [ "$(echo "$output" | jq -r .review_skill)" = "development-go:review" ]
}

@test "plan: #1153 an UNSUPPORTED language DOES block the kubernetes fallback" {
  # the asymmetry that keeps the manifest panel from reviewing application code.
  # `supported` is empty both for a language-less GitOps repo AND for a
  # JavaScript service, and `is_kubernetes` composes with any language — so a
  # JS/TS service shipping its own Helm chart (an ordinary shape) would be
  # handed to the manifest panel for a story whose diff is JS. That panel has no
  # competence there: it converges finding-free and the loop records a clean
  # review that never happened. Such a repo must keep the typed escalation,
  # which names the languages so a human can route it.
  plan '{"languages":["javascript"],"is_kubernetes":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
  [ "$(echo "$output" | jq -e '.languages | index("javascript") != null')" = "true" ]
}

@test "plan: #1153 an UNSUPPORTED language does NOT block the claude-plugin fallback" {
  # the deliberate asymmetry with the case above, pinned so the two cannot be
  # "harmonised" by mistake: a `.claude-plugin/plugin.json` is definitional for
  # what the repo IS, and a plugin repo carrying one unsupported-language file
  # is still a plugin repo. A Chart.yaml is routinely incidental to an
  # application repo, which is why kubernetes needs the stricter gate.
  plan '{"languages":["rust"],"is_claude_plugin":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
}

@test "plan: #1153 claude-plugin still wins when a language is detected AND both markers fire" {
  # the ordering rule survives the stricter kubernetes gate: with a language
  # present, kubernetes is excluded outright and claude-plugin still applies
  plan '{"languages":["rust"],"is_claude_plugin":true,"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
}

@test "plan: #1153 a fallback primary does NOT defuse language ambiguity" {
  # both the script and ARCHITECTURE state "neither fallback ever joins the
  # ambiguity tiebreak", but every other fallback test here runs with no
  # .maintenance.yml — so the branch where _primary actually returns a value is
  # exercised only for LANGUAGE primaries. The tempting "improvement" (teach
  # _primary to accept the fallback tokens so a GitOps repo can declare its
  # panel) passes every other test in this file while silently pointing an
  # ambiguous polyglot repo at the manifest panel.
  printf 'primary: kubernetes\n' > "$R/.maintenance.yml"
  plan '{"languages":["python","java"],"is_kubernetes":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
  [ "$(echo "$output" | jq -r .primary)" = "kubernetes" ]
}

@test "plan: #1153 a claude-plugin primary does not defuse ambiguity either" {
  # mirrored so the two fallbacks cannot drift apart — the precedent this file
  # already sets for every other fallback rule
  printf 'primary: claude-plugin\n' > "$R/.maintenance.yml"
  plan '{"languages":["python","java"],"is_claude_plugin":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
}

@test "plan: #1153 a single supported language wins before primary is consulted" {
  # the single-supported-language branch precedes _primary entirely, so a
  # declared kubernetes primary cannot override a detected Go service
  printf 'primary: kubernetes\n' > "$R/.maintenance.yml"
  plan '{"languages":["go"],"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "go" ]
}

@test "plan: #1153 the REAL detect-stack drives the kubernetes fallback end-to-end" {
  # every other case here stubs detect-stack via DETECT_STACK_BIN, so the
  # producer's key name and the consumer's jq path are pinned INDEPENDENTLY —
  # rename `.is_kubernetes` in both the script and this file's stub fixtures and
  # both suites stay green while every real GitOps repo escalates as
  # unsupported_repo_type (silently: the `// false` default degrades, it does not
  # crash). This one un-stubbed case is what joins the two halves.
  mkdir -p "$R/charts/app"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$R/charts/app/Chart.yaml"
  run env -u DETECT_STACK_BIN zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "kubernetes" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-kubernetes:review" ]
}

@test "plan: #1153 every repo_type the dispatcher can emit names a shipped review skill" {
  # review_skill is SYNTHESISED as development-${repo_type}:review, so a renamed
  # or typo'd panel directory is caught by no assertion in either suite — every
  # test here compares the synthesised string to another string.
  #
  # The language half is DERIVED from the script, so a seventh panel language
  # added there is swept automatically rather than leaving this test's title
  # false — the very failure mode it exists to prevent one level down. The two
  # fallbacks stay literal: they are not in that loop, and naming them here is
  # what documents them as the complete fallback set.
  local langs t
  langs="$(sed -n 's/^  for l in \(.*\); do$/\1/p' "$S")"
  [ -n "$langs" ]
  [ "$(printf '%s\n' "$langs" | wc -w | tr -d ' ')" -eq 4 ]
  for t in $langs claude-plugin kubernetes; do
    [ -f "$REPO_ROOT/development-$t/skills/review/SKILL.md" ]
    # and each panel's skill really is named `review`, or the synthesised
    # `development-<type>:review` resolves to nothing
    grep -qx 'name: review' "$REPO_ROOT/development-$t/skills/review/SKILL.md"
  done
}

@test "plan: #1153 the fallback branch never consults .maintenance.yml primary" {
  # the branch the fallbacks actually live in — zero SUPPORTED languages. The
  # tempting "let a GitOps repo declare its panel" change would teach _primary
  # to be consulted here, and every other test in this file would stay green
  # while `primary: python` on a repo with no Python routed review to
  # development-python:review.
  printf 'primary: python\n' > "$R/.maintenance.yml"
  plan '{"languages":[],"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "kubernetes" ]
}

@test "plan: #1153 claude-plugin WINS when both fallback markers fire" {
  # not hypothetical: a plugin repo that also carries Kubernetes content fires
  # both markers, and THIS repo becomes exactly that once #1155 lands its
  # fixtures under tests/fixtures/. Reversing the branch order would then point
  # this repo's own review loop at a manifest panel.
  plan '{"languages":[],"is_claude_plugin":true,"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "claude-plugin" ]
  [ "$(echo "$output" | jq -r .review_skill)" = "development-claude-plugin:review" ]
}

@test "plan: #1153 no language and is_kubernetes false stays a typed error" {
  plan '{"languages":[],"is_claude_plugin":false,"is_kubernetes":false}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #1153 absent is_kubernetes key defaults to false, no crash" {
  # an older detect-stack that omits the key must fall through cleanly, exactly
  # as #809's absent-key case does
  plan '{"languages":[],"is_claude_plugin":false}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #1153 the kubernetes fallback does not defuse language ambiguity" {
  plan '{"languages":["python","java"],"is_kubernetes":true}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "ambiguous_repo_type" ]
}

# ---- scope-findings: findings outside the story's diff do not appear

@test "scope-findings: drops findings in untouched files, keeps in-diff ones" {
  echo "print(1)" > "$R/app.py"         # the story touches only app.py
  cat > "$R/findings.json" <<'EOF'
[
  {"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"in-diff"},
  {"severity":"WARNING","dimension":"code_quality","file":"legacy.py","line":3,"title":"out-of-diff"},
  {"severity":"SUGGESTION","dimension":"tests","file":"./app.py","line":1,"title":"in-diff-dot"}
]
EOF
  run env GIT_BIN=git zsh "$S" scope-findings --repo "$R" --base main --findings "$R/findings.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  echo "$output" | jq -e 'all(.[]; .title != "out-of-diff")' >/dev/null
}

@test "scope-findings: missing findings file yields an empty array" {
  run zsh "$S" scope-findings --repo "$R" --base main --findings "$R/absent.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

# ---- usage

@test "plan: --repo is required (usage error, exit 2)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --base main
  [ "$status" -eq 2 ]
}

@test "no subcommand is a usage error (exit 2)" {
  run zsh "$S"
  [ "$status" -eq 2 ]
}

@test "unknown subcommand is a usage error (exit 2)" {
  run zsh "$S" frobnicate
  [ "$status" -eq 2 ]
}

# ---- loop-artifact exclusion (#909): the loop's own outputs never enter scope

@test "plan: .review/ and .claude/telemetry/ artifacts are excluded from changed_files" {
  # simulate a prior run's artifacts (untracked) alongside a real story file
  mkdir -p "$R/.review" "$R/.claude/telemetry"
  echo '[]' > "$R/.review/findings-round-1.json"
  echo '{}' > "$R/.claude/telemetry/telemetry.jsonl"
  echo "print(1)" > "$R/app.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.changed_files | index("app.py")' >/dev/null
  echo "$output" | jq -e '.changed_files | map(select(startswith(".review/"))) | length == 0' >/dev/null
  echo "$output" | jq -e '.changed_files | map(select(startswith(".claude/telemetry/"))) | length == 0' >/dev/null
}

@test "plan: the exclusion is start-anchored — nested/lookalike paths stay in scope" {
  # a nested .review dir inside story code, and a top-level lookalike file,
  # are legitimate story files — only the repo-root artifact dirs are excluded
  mkdir -p "$R/src/.review"
  echo "cfg" > "$R/src/.review/config.json"
  echo "notes" > "$R/.review-notes.md"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.changed_files | index("src/.review/config.json")' >/dev/null
  echo "$output" | jq -e '.changed_files | index(".review-notes.md")' >/dev/null
}

@test "plan: a scope that is ONLY artifacts yields empty changed_files, not an error" {
  mkdir -p "$R/.review"
  echo '[]' > "$R/.review/findings-round-1.json"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.changed_files == []' >/dev/null
}

@test "scope-findings: a finding filed against a loop artifact is dropped" {
  mkdir -p "$R/.review"
  echo '[]' > "$R/.review/findings-round-1.json"
  echo "print(1)" > "$R/app.py"
  F="$BATS_TEST_TMPDIR/findings.json"
  cat > "$F" <<'JSON'
[{"severity":"CRITICAL","dimension":"bugs","file":".review/findings-round-1.json","line":1,"title":"bogus","description":"d","reviewer":"r"},
 {"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"real","description":"d","reviewer":"r"}]
JSON
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" scope-findings --repo "$R" --base main --findings "$F"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[0].file')" = "app.py" ]
}

# ---- base-ref validation (#910): a bad base must fail fast, never mis-scope

@test "plan: an unresolvable --base exits 1 naming the ref, not a degraded scope" {
  echo "print(1)" > "$R/app.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$R" --base refs/heads/does-not-exist
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'does-not-exist'
}

@test "scope-findings: an unresolvable --base exits 1, not a silently-empty scope" {
  echo "print(1)" > "$R/app.py"
  F="$BATS_TEST_TMPDIR/findings-910.json"
  echo '[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"t","description":"d","reviewer":"r"}]' > "$F"
  run zsh "$S" scope-findings --repo "$R" --base refs/heads/does-not-exist --findings "$F"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'does-not-exist'
}

@test "plan: a non-git --repo exits 1 naming the repo, not the ref" {
  NR="$BATS_TEST_TMPDIR/not-a-repo"; mkdir -p "$NR"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" plan --repo "$NR" --base main
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'not a git repository'
  run ! grep -q 'does not resolve' <<< "$output"
}

@test "plan: #1153 an ABSENT .languages key still reaches the kubernetes fallback" {
  # the new lang_count read must degrade through `.languages // []` exactly as
  # the two marker reads degrade through `// false` — the same missing-key edge
  # this file already covers for is_claude_plugin and is_kubernetes
  plan '{"is_kubernetes":true}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .repo_type)" = "kubernetes" ]
}

@test "plan: #1153 an empty detect payload stays a typed escalation" {
  plan '{}'
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r .error)" = "unsupported_repo_type" ]
}

@test "plan: #1153 a malformed .languages FAILS CLOSED with the internal-error exit" {
  # the guard's own comment states the stakes: an unchecked `local -i` read would
  # fail OPEN — jq dying (or emitting nothing) would coerce to 0, exactly the
  # value that opens the kubernetes gate, handing a language-bearing repo to the
  # manifest panel. Nothing exercised that branch, so replacing the guards with
  # `local -i lang_count=$(...)` left every other test in this file green.
  # A boolean has no `length`, so jq errors here.
  plan '{"languages":true,"is_kubernetes":true}'
  [ "$status" -eq 1 ]
  # and emphatically NOT a successful kubernetes dispatch
  [ "$(echo "$output" | jq -r '.repo_type // "none"' 2>/dev/null || echo none)" != "kubernetes" ]
}

# NOTE: no companion test for the `[[ "$lang_count" == <-> ]]` half. Every
# SINGLE-DOCUMENT input reachable through this seam that jq accepts yields one
# number (an object's length is 1, a string's is its length), so an assertion
# built on one would behave identically with the guard removed — an inert test,
# which is worse than no test. The guard IS reachable via a multi-document
# payload (`{...} {...}` survives `jq -c .` and makes `jq 'length'` emit two
# lines), but that requires a detect-stack emitting a JSON stream, which nothing
# in the family does; the numeric check stands as defence-in-depth for it and
# for a jq that succeeds while emitting nothing. The case above covers the
# reachable failure.
