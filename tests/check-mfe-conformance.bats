#!/usr/bin/env bats
#
# Behavioural tests for the MFE conformance checker (#1126, epic #1122) —
# templates/languages/javascript/mfe-conformance/scripts/check-mfe-conformance.zsh
# — plus its workflow template and bootstrap SKILL.md §3k.10.
#
# The checker evaluates a built remote entry under REAL node (a declared test
# dependency, see script-tests.yml), so each case writes a tiny ES-module entry
# and a package.json into a fixture remote. curl is stubbed through $MFE_CURL,
# the stub-on-PATH convention check-ops-conformance.bats uses, so the served
# check is exercised without a live container. Every check has a negative case,
# so the gate cannot pass vacuously.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` (#1189).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TREE="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript/mfe-conformance"
  CHECK="$TREE/scripts/check-mfe-conformance.zsh"
  WORKFLOW="$TREE/.github/workflows/mfe-conformance.yml.tmpl"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  MAINT="$REPO_ROOT/MAINTAINING.md"
  README="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript/mfe-contract/README.md"

  APP="$BATS_TEST_TMPDIR/remote"
  mkdir -p "$APP/dist"
  ENTRY="$APP/dist/remote.js"
  PKG="$APP/package.json"
  page_entry
  package '"dependencies": { "@acme/mfe-contract": "^1.0.0" }'

  # Stub curl: honours -o <file> and -w, answering from $STUB_DIR/{code,ct,body,rc}
  # and logging each URL it was asked for to $STUB_DIR/calls.
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR" "$BATS_TEST_TMPDIR/bin"
  export MFE_STUB_DIR="$STUB_DIR"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOS'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-m) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
d="$MFE_STUB_DIR"
printf '%s\n' "$url" >> "$d/calls"
rc="$(cat "$d/rc" 2>/dev/null || echo 0)"
if [ "$rc" != "0" ]; then exit "$rc"; fi
if [ -n "$out" ] && [ -f "$d/body" ]; then cp "$d/body" "$out"; fi
printf '%s\t%s' "$(cat "$d/code" 2>/dev/null || echo 000)" "$(cat "$d/ct" 2>/dev/null || echo text/javascript)"
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export MFE_CURL="$BATS_TEST_TMPDIR/bin/curl"
}

# page_entry [mount-params] [unmount-params] — a conforming page entry by default.
page_entry() {
  printf 'export const mount = async (%s) => {};\nexport const unmount = (%s) => {};\n' \
    "${1-el, ctx}" "${2-el}" > "$ENTRY"
}

# package <json-members> — the fixture remote's package.json.
package() { printf '{ "name": "remote", %s }\n' "$1" > "$PKG"; }

# widget <contractMajor> — turn the fixture into a widget remote.
widget() {
  mkdir -p "$APP/src/remote"
  : > "$APP/src/remote/manifest.ts"
  page_entry
  printf 'export const manifest = { id: "w", contractMajor: %s };\n' "$1" >> "$ENTRY"
}

# serve <code> <content-type> [body-file] — what the stub curl answers.
serve() {
  printf '%s' "$1" > "$STUB_DIR/code"
  printf '%s' "$2" > "$STUB_DIR/ct"
  cp "${3:-$ENTRY}" "$STUB_DIR/body"
}

check() { run zsh "$CHECK" --entry "$ENTRY" --package "$PKG" --shell-major 1 "$@"; }

# --- conforming remotes ---------------------------------------------------------

@test "mfe conformance: a conforming page remote passes with exit 0 and never fetches without --base-url" {
  check
  [ "$status" -eq 0 ]
  contains "$output" "mfe conformance PASSED for $ENTRY (contract major 1)"
  contains "$output" "  major     PASS"
  contains "$output" "  exports   PASS"
  lacks "$output" "manifest  PASS"
  lacks "$output" "::error::"
  [ ! -e "$STUB_DIR/calls" ]
}

@test "mfe conformance: a conforming widget remote passes, its manifest checked" {
  widget 1
  check
  [ "$status" -eq 0 ]
  contains "$output" "  manifest  PASS"
}

@test "mfe conformance: every range that resolves to one major is accepted, from dependencies or devDependencies" {
  local r
  for r in '^1' '^1.0.0' '~1.2' '1.x' '1.0.0' '1' '1.2.*' 'v1.0.0' '=1.0.0' '^1.0.0-rc.1'; do
    package "\"dependencies\": { \"@acme/mfe-contract\": \"$r\" }"
    check
    [ "$status" -eq 0 ] || { echo "range $r: $output"; return 1; }
  done
  package '"devDependencies": { "@other-org/mfe-contract": "^1.4.0" }'
  check
  [ "$status" -eq 0 ]
}

# --- exports ----------------------------------------------------------------

@test "mfe conformance: a remote missing mount or unmount fails, naming the absent export" {
  printf 'export const unmount = (el) => {};\n' > "$ENTRY"
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: exports: $ENTRY has no 'mount' export"
  printf 'export const mount = (el, ctx) => {};\n' > "$ENTRY"
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: exports: $ENTRY has no 'unmount' export"
}

@test "mfe conformance: a mount or unmount of the wrong arity fails, naming the expected and observed arity" {
  page_entry 'el' 'el'
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: arity: 'mount' takes 1 parameter(s), expected 2"
  page_entry 'el, ctx' ''
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: arity: 'unmount' takes 0 parameter(s), expected 1"
}

@test "mfe conformance: an entry that keeps a timer alive gets the normal verdict, not a hang" {
  printf 'setTimeout(() => {}, 60000);\n' >> "$ENTRY"
  local start=$SECONDS
  check
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 30 ]
}

@test "mfe conformance: an entry that logs at evaluation gets the normal verdict, not a tooling error" {
  printf 'console.log("hello from the remote");\nconsole.log("{}");\n' >> "$ENTRY"
  check
  [ "$status" -eq 0 ]
  page_entry 'el' 'el'
  printf 'console.log("hello from the remote");\n' >> "$ENTRY"
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: arity: 'mount' takes 1 parameter(s), expected 2"
}

@test "mfe conformance: an export that is not a function fails, naming its type" {
  printf 'export const mount = "mount";\nexport const unmount = (el) => {};\n' > "$ENTRY"
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: exports: 'mount' is a string, not a function"
}

@test "mfe conformance: an entry that throws on evaluation fails, naming the error, and skips the export checks" {
  printf 'throw new Error("the remote exploded");\n' > "$ENTRY"
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: evaluate: $ENTRY throws on evaluation: the remote exploded"
  lacks "$output" "exports:"
  lacks "$output" "arity:"
}

@test "mfe conformance: an entry whose top-level await never settles fails evaluate, not a tooling error" {
  printf 'await new Promise(() => {});\n' >> "$ENTRY"
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: evaluate: $ENTRY did not finish evaluating (node exit "
}

@test "mfe conformance: an entry whose never-settling await keeps a handle alive fails evaluate within --timeout" {
  printf 'setInterval(() => {}, 1000);\nawait new Promise(() => {});\n' >> "$ENTRY"
  SECONDS=0
  check --timeout 1
  [ "$status" -eq 1 ]
  contains "$output" "::error:: evaluate: $ENTRY did not finish evaluating within 1s"
  lacks "$output" "exports:"
  [ "$SECONDS" -lt 8 ]
}

@test "mfe conformance: an entry that calls process.exit during evaluation fails evaluate, not a tooling error" {
  printf 'process.exit(3);\n' >> "$ENTRY"
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: evaluate: $ENTRY did not finish evaluating (node exit 3)"
}

# --- major --------------------------------------------------------------------

@test "mfe conformance: a contract-major mismatch fails, naming both majors" {
  package '"dependencies": { "@acme/mfe-contract": "^2.1.0" }'
  check
  [ "$status" -eq 1 ]
  contains "$output" \
    "::error:: major: the remote declares @acme/mfe-contract major 2 ('^2.1.0'), the shell implements major 1"
}

@test "mfe conformance: a multi-digit major is read whole" {
  package '"dependencies": { "@acme/mfe-contract": "^12.3.0" }'
  run zsh "$CHECK" --entry "$ENTRY" --package "$PKG" --shell-major 12
  [ "$status" -eq 0 ]
  check
  [ "$status" -eq 1 ]
  contains "$output" "the remote declares @acme/mfe-contract major 12 ('^12.3.0'), the shell implements major 1"
}

@test "mfe conformance: a missing dependency fails, naming the package file" {
  package '"dependencies": { "react": "^19.0.0" }'
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: major: $PKG declares no @*/mfe-contract dependency"
}

@test "mfe conformance: a range that does not resolve to exactly one major fails, naming the range" {
  local r
  for r in '>=1.0.0' '^1 || ^2' '1 - 2' '*' 'latest' 'workspace:*'; do
    package "\"dependencies\": { \"@acme/mfe-contract\": \"$r\" }"
    check
    [ "$status" -eq 1 ] || { echo "range $r passed"; return 1; }
    contains "$output" "::error:: major: @acme/mfe-contract range '$r' does not resolve to exactly one major"
  done
}

@test "mfe conformance: two different mfe-contract packages fail as ambiguous" {
  package '"dependencies": { "@a/mfe-contract": "^1" }, "devDependencies": { "@b/mfe-contract": "^1" }'
  check
  [ "$status" -eq 1 ]
  contains "$output" "declares more than one mfe-contract package: @a/mfe-contract, @b/mfe-contract"
}

@test "mfe conformance: every failure is reported, not only the first" {
  printf 'export const mount = (el) => {};\n' > "$ENTRY"
  package '"dependencies": { "@acme/mfe-contract": "^3" }'
  check
  [ "$status" -eq 1 ]
  contains "$output" "major: the remote declares @acme/mfe-contract major 3"
  contains "$output" "arity: 'mount' takes 1 parameter(s), expected 2"
  contains "$output" "has no 'unmount' export"
  contains "$output" "mfe conformance FAILED: 3 problem(s) in $ENTRY"
}

# --- widget -------------------------------------------------------------------

@test "mfe conformance: a widget whose contractMajor differs from the package or the shell fails, naming the majors" {
  widget 2
  check
  [ "$status" -eq 1 ]
  contains "$output" \
    "::error:: manifest: manifest.contractMajor is 2, the package declares major 1 and the host implements major 1"
  widget 1
  package '"dependencies": { "@acme/mfe-contract": "^2" }'
  check
  [ "$status" -eq 1 ]
  contains "$output" "manifest: manifest.contractMajor is 1, the package declares major 2 and the host implements major 1"
}

@test "mfe conformance: a widget entry with no manifest export, or no numeric contractMajor, fails" {
  widget 1
  page_entry
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: manifest: $ENTRY is a widget entry with no 'manifest' export"
  widget '"1"'
  check
  [ "$status" -eq 1 ]
  contains "$output" "::error:: manifest: manifest.contractMajor is missing or not a number"
}

@test "mfe conformance: a page entry needs no manifest; the widget marker is what makes it a widget" {
  page_entry
  check
  [ "$status" -eq 0 ]
  mkdir -p "$APP/src/remote"
  : > "$APP/src/remote/manifest.ts"
  check
  [ "$status" -eq 1 ]
  contains "$output" "no 'manifest' export"
}

# --- served -------------------------------------------------------------------

@test "mfe conformance: with --base-url, the same entry served at /remote.js as JavaScript passes" {
  serve 200 'text/javascript; charset=utf-8'
  check --base-url http://localhost:8080/
  [ "$status" -eq 0 ]
  contains "$output" "  served    PASS"
  [ "$(cat "$STUB_DIR/calls")" = "http://localhost:8080/remote.js" ]
  serve 200 'application/javascript'
  check --base-url http://localhost:8080
  [ "$status" -eq 0 ]
}

@test "mfe conformance: a container that does not serve the entry fails, naming the path and HTTP status" {
  serve 404 'text/html'
  check --base-url http://localhost:8080
  [ "$status" -eq 1 ]
  contains "$output" "::error:: served: /remote.js answered HTTP 404, expected 200"
}

@test "mfe conformance: a served entry with a non-JavaScript content type or different bytes fails" {
  serve 200 'text/html'
  check --base-url http://localhost:8080
  [ "$status" -eq 1 ]
  contains "$output" "::error:: served: /remote.js (HTTP 200) has content type 'text/html', expected JavaScript"
  printf 'export const stale = 1;\n' > "$BATS_TEST_TMPDIR/stale.js"
  serve 200 'text/javascript' "$BATS_TEST_TMPDIR/stale.js"
  check --base-url http://localhost:8080
  [ "$status" -eq 1 ]
  contains "$output" "::error:: served: /remote.js (HTTP 200) differs from $ENTRY"
}

@test "mfe conformance: an unreachable container fails; a request curl cannot use is a tooling error" {
  printf '7' > "$STUB_DIR/rc"
  check --base-url http://localhost:8080
  [ "$status" -eq 1 ]
  contains "$output" "::error:: served: /remote.js unreachable at http://localhost:8080/remote.js"
  printf '3' > "$STUB_DIR/rc"
  check --base-url 'not a url'
  [ "$status" -eq 2 ]
}

# --- usage and tooling --------------------------------------------------------

@test "mfe conformance: a missing flag, a missing file or a non-integer --shell-major exits 2" {
  run zsh "$CHECK" --package "$PKG" --shell-major 1
  [ "$status" -eq 2 ]
  contains "$output" "missing --entry"
  run zsh "$CHECK" --entry "$ENTRY" --shell-major 1
  [ "$status" -eq 2 ]
  contains "$output" "missing --package"
  run zsh "$CHECK" --entry "$ENTRY" --package "$PKG"
  [ "$status" -eq 2 ]
  contains "$output" "missing --shell-major"
  run zsh "$CHECK" --entry "$ENTRY" --package "$PKG" --shell-major one
  [ "$status" -eq 2 ]
  contains "$output" "invalid --shell-major: 'one'"
  run zsh "$CHECK" --entry "$APP/dist/none.js" --package "$PKG" --shell-major 1
  [ "$status" -eq 2 ]
  contains "$output" "--entry file not found"
  run zsh "$CHECK" --entry "$ENTRY" --package "$APP/none.json" --shell-major 1
  [ "$status" -eq 2 ]
  contains "$output" "--package file not found"
}

@test "mfe conformance: a bad --timeout, an unknown argument or a non-object package exits 2" {
  check --timeout soon
  [ "$status" -eq 2 ]
  contains "$output" "invalid --timeout: 'soon'"
  check --verbose
  [ "$status" -eq 2 ]
  contains "$output" "unexpected argument: --verbose"
  printf '[1, 2]\n' > "$PKG"
  check
  [ "$status" -eq 2 ]
  contains "$output" "--package is not a JSON object"
}

@test "mfe conformance: node not found exits 2; curl is required only for --base-url" {
  MFE_NODE="$BATS_TEST_TMPDIR/no-such-node" check
  [ "$status" -eq 2 ]
  contains "$output" "::error:: '$BATS_TEST_TMPDIR/no-such-node' not found on PATH"
  MFE_CURL="$BATS_TEST_TMPDIR/no-such-curl" check
  [ "$status" -eq 0 ]
  MFE_CURL="$BATS_TEST_TMPDIR/no-such-curl" check --base-url http://localhost:8080
  [ "$status" -eq 2 ]
  contains "$output" "::error:: '$BATS_TEST_TMPDIR/no-such-curl' not found on PATH"
}

# --- the templates ------------------------------------------------------------

@test "mfe conformance: the tree holds exactly the checker and the workflow, every line within 120 characters" {
  local listed f long
  listed="$(cd "$TREE" && find . -type f ! -name .DS_Store | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$listed" = ".github/workflows/mfe-conformance.yml.tmpl scripts/check-mfe-conformance.zsh " ]
  for f in "$CHECK" "$WORKFLOW"; do
    long="$(awk 'length > 120 { print FNR ": " length }' "$f")"
    [ -z "$long" ] || { echo "$f over 120: $long"; return 1; }
  done
}

@test "mfe conformance: the set renders with --default-branch and no placeholder survives" {
  local out="$BATS_TEST_TMPDIR/out"
  run zsh "$RENDER" --templates "$TREE" --out "$out" --default-branch trunk \
    scripts/check-mfe-conformance.zsh .github/workflows/mfe-conformance.yml.tmpl
  [ "$status" -eq 0 ]
  [ -f "$out/scripts/check-mfe-conformance.zsh" ]
  [ -f "$out/.github/workflows/mfe-conformance.yml" ]
  run grep -rlE '\{\{[A-Z_]+\}\}' "$out"
  [ "$status" -eq 1 ]
  contains "$(cat "$out/.github/workflows/mfe-conformance.yml")" 'branches: ["trunk"]'
  cmp -s "$CHECK" "$out/scripts/check-mfe-conformance.zsh"
}

@test "mfe conformance: the workflow runs on the remote's paths, builds the remote and passes the shell major" {
  local wf p
  wf="$(cat "$WORKFLOW")"
  for p in 'src/remote/**' 'vite.remote.config.ts' 'package.json' 'package-lock.json' 'Dockerfile' \
    'scripts/check-mfe-conformance.zsh' '.github/workflows/mfe-conformance.yml'; do
    contains "$wf" "      - \"$p\""
  done
  contains "$wf" '  workflow_dispatch: {}'
  contains "$wf" 'run: npm ci'
  contains "$wf" 'run: npm run build:remote'
  contains "$wf" "MFE_SHELL_MAJOR: \${{ vars.MFE_SHELL_MAJOR || '1' }}"
  contains "$wf" '--shell-major "${MFE_SHELL_MAJOR}"'
  contains "$wf" 'node-version-file: ".nvmrc"'
}

@test "mfe conformance: the workflow builds the container and checks the served entry only for a root Dockerfile" {
  local wf block
  wf="$(cat "$WORKFLOW")"
  [ "$(grep -c "if: hashFiles('Dockerfile') != ''" "$WORKFLOW")" -eq 3 ]
  contains "$wf" "if: always() && hashFiles('Dockerfile') != ''"
  contains "$wf" 'run: docker build -t mfe-conformance-remote .'
  contains "$wf" '--shell-major "${MFE_SHELL_MAJOR}" --base-url "http://localhost:${MFE_PORT}"'
  contains "$wf" 'curl -fsS -m 2 -o /dev/null "http://localhost:${MFE_PORT}/remote.js"'
  lacks "$wf" 'localhost:8080'
  # the static check is present and unconditional: its whole step block, from
  # the `      - ` line that opens it to the line before the next one
  [ "$(grep -c 'name: Check the built entry' "$WORKFLOW")" -eq 1 ]
  block="$(step_block 'name: Check the built entry')"
  contains "$block" 'zsh scripts/check-mfe-conformance.zsh --entry dist/remote.js --package package.json'
  contains "$block" '--shell-major "${MFE_SHELL_MAJOR}"'
  lacks "$block" 'if:'
}

# step_block <needle> — the workflow step whose block contains <needle>.
step_block() {
  awk -v n="$1" '
    /^      - / { if (hit) exit; buf = "" }
    { buf = buf $0 "\n" }
    index($0, n) { hit = 1 }
    END { if (hit) printf "%s", buf }
  ' "$WORKFLOW"
}

# --- the bootstrap step (SKILL.md §3k.10) ---------------------------------------

conformance_step() {
  sed -n '/^### 3k\.10\. MFE conformance/,/^### /p' "$SKILL" | tr -s '[:space:]' ' '
}

STEP_END='### 3l. Infrastructure-as-code repos (no application language) — #1154 '

@test "mfe conformance: SKILL.md carries §3k.10 right after §3k.9, before §3l" {
  local section r c l
  section="$(conformance_step)"
  ends_with "$section" "$STEP_END"
  r="$(grep -n '^### 3k\.9\. ' "$SKILL" | cut -d: -f1)"
  c="$(grep -n '^### 3k\.10\. ' "$SKILL" | cut -d: -f1)"
  l="$(grep -n '^### 3l\. ' "$SKILL" | cut -d: -f1)"
  matches "$r" '^[0-9]+$'
  matches "$c" '^[0-9]+$'
  matches "$l" '^[0-9]+$'
  [ "$r" -lt "$c" ]
  [ "$c" -lt "$l" ]
}

@test "mfe conformance: §3k.10 renders only for the remote marker and nothing after a failed contract install" {
  local section
  section="$(conformance_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'Run this step after §3k.9, and only for a repo carrying the remote marker, `src/remote/entry.tsx`'
  contains "$section" 'A shell exports nothing to check, so a repo without the marker gets nothing'
  contains "$section" '**When §3k.9 rendered nothing because `@<scope>/mfe-contract` could not be installed (#1899), this step renders nothing either**'
  contains "$section" '--templates "<skill-base-dir>/templates/languages/javascript/mfe-conformance"'
  contains "$section" 'scripts/check-mfe-conformance.zsh .github/workflows/mfe-conformance.yml.tmpl'
  contains "$section" 'so no `{{PLACEHOLDER}}` survives'
  contains "$section" 'Record every file this step writes under the `react_overlay` telemetry step key'
  contains "$section" 'In State D the step is an **adoption gap** when the remote marker is present and a conformance file is missing: offer the missing files in the plan.'
  contains "$section" '**Render the workflow only when `package.json` has a `build:remote` script** (§3k.9'"'"'s confirmed edit was made, or skipped as already present); otherwise render only the checker and record a Step 5 TODO naming the `build:remote` script'
}

@test "mfe conformance: §3k.10 wires the served check only for a root Dockerfile, else a Step 5 TODO naming #1062" {
  local section
  section="$(conformance_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'passes `--base-url` **only when the repo has a root `Dockerfile`**; without one it runs the static checks alone.'
  contains "$section" 'record a Step 5 TODO: *wire the served check once the static-asset container (#1062) exists*'
  contains "$section" 'is **never a required context**'
  contains "$section" "\`--shell-major \${{ vars.MFE_SHELL_MAJOR || '1' }}\`"
  contains "$section" '§3d → §3k → §3k.5 → §3k.6 → §3k.9 → **this step**'
  contains "$(cat "$SKILL")" '3k.9. Remote overlay, and 3k.10. MFE conformance |'
}

@test "mfe conformance: §3k.10 states the checker's contract, its render-failure branch and the root-Dockerfile key" {
  local section
  section="$(conformance_step)"
  ends_with "$section" "$STEP_END"
  contains "$section" 'A non-zero `render.zsh` exit renders nothing, records a Step 5 item, and the run carries on.'
  contains "$section" 'It evaluates the built entry under node and requires `mount` (2 parameters) and `unmount` (1)'
  contains "$section" 'which a default value or a rest parameter lowers, so an entry must declare `mount(el, ctx)` and `unmount(el)` as plain parameters'
  contains "$(tr -s '[:space:]#' ' ' < "$CHECK")" 'which a default value or a rest parameter lowers, so an entry must declare `mount(el, ctx)` and `unmount(el)` as plain parameters'
  contains "$section" 'it requires the declared `@*/mfe-contract` range to resolve to exactly one major, equal to `--shell-major`'
  contains "$section" 'requires 200, a JavaScript content type and a body byte-identical to `--entry`.'
  contains "$section" '`--timeout` (default 10) bounds both the entry'"'"'s evaluation and that fetch,'
  contains "$section" 'Exit 0 when the remote conforms, 1 when it does not (every failure an `::error::` line naming its check), 2 for a usage or tooling error.'
  contains "$section" 'Key this on a `Dockerfile` at the repo root, not on `has_dockerfile`, exactly as the `ops-conformance` workflow does.'
}

@test "mfe conformance: --help prints the usage and exits 2" {
  run zsh "$CHECK" --help
  [ "$status" -eq 2 ]
  contains "$output" 'usage: check-mfe-conformance.zsh --entry <dist/remote.js> --package <package.json>'
}

# --- the record ---------------------------------------------------------------

@test "mfe conformance: the contract README and ARCHITECTURE.md no longer say nothing compares the majors" {
  local readme arch maint
  readme="$(tr -s '[:space:]' ' ' < "$README")"
  arch="$(tr -s '[:space:]' ' ' < "$ARCH")"
  maint="$(tr -s '[:space:]' ' ' < "$MAINT")"
  lacks "$readme" 'nothing compares them'
  lacks "$arch" 'Until #1126 lands, nothing checks a shell or remote'
  contains "$readme" 'each remote'"'"'s conformance check (#1126, `check-mfe-conformance.zsh`) compares its declared major'
  contains "$arch" '**The MFE conformance check (#1126).**'
  contains "$arch" '`development/skills/bootstrap/templates/languages/javascript/mfe-conformance/`'
  contains "$arch" '§3d → §3k → §3k.5 → §3k.6 → §3k.9 → §3k.10'
  contains "$maint" '**The MFE conformance check** (#1126, SKILL.md §3k.10) is a sibling tree'
}
