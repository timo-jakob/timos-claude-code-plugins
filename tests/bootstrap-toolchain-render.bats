#!/usr/bin/env bats
#
# The quality workflows composed from the RESOLVED toolchain (#1670) instead of
# two whole visibility paths. Every one of the 8 renderable combinations (the
# D4 table below — public + sonarqube and private + codeql are rejected at the
# plan, resolve-tools.zsh step 4) is rendered for a python + Dockerfile repo,
# through the same selector bootstrap uses (toolchain-templates.zsh), and pinned
# against FIXED oracles written out here, never read back from a render:
#
#   D1/D4  the required-context set per row (AC1)
#   D5     the tool-scoped artifacts per row, files and jobs (AC2)
#   AC3    rows 1 and 5 against golden fixtures captured from the pre-#1670
#          templates (tests/fixtures/bootstrap-toolchain-golden/)
#   D6     SETUP.md's composition per row (AC4)
#   D3     the runner rule per row, the Swift leg included (AC5)

bats_require_minimum_version 1.5.0
load assertions

# row: number visibility static_analysis vulnerabilities code_scanning
ROWS=(
  "1 public sonarcloud snyk codeql"
  "2 public sonarcloud snyk none"
  "3 public sonarcloud trivy codeql"
  "4 public sonarcloud trivy none"
  "5 private sonarqube trivy none"
  "6 private sonarqube snyk none"
  "7 private sonarcloud trivy none"
  "8 private sonarcloud snyk none"
)

# D4: each row's context set is B plus these (| separated). B is fixed by D1:
# the always-contexts, plus `image` because the fixture has a Dockerfile.
B="test-and-coverage|semgrep|pre-commit|license-fs|image"
D4=(""
  "sonarcloud|analyze (python)"
  "sonarcloud"
  "sonarcloud|trivy-fs|analyze (python)"
  "sonarcloud|trivy-fs"
  "sonarqube|trivy-fs"
  "sonarqube"
  "sonarcloud|trivy-fs"
  "sonarcloud"
)

# D5, file level: the tool-scoped files each row renders (render-out relative;
# everything under common/ renders for every row and is checked separately)
PUBW=public/.github/workflows
PRIW=private/.github/workflows
D5=(""
  "$PUBW/quality-public.yml $PUBW/quality-public-noop.yml $PUBW/scorecard.yml $PUBW/codeql.yml $PUBW/codeql-noop.yml public/sonar-project.properties public/.snyk"
  "$PUBW/quality-public.yml $PUBW/quality-public-noop.yml $PUBW/scorecard.yml public/sonar-project.properties public/.snyk"
  "$PUBW/quality-public.yml $PUBW/quality-public-noop.yml $PUBW/scorecard.yml $PUBW/codeql.yml $PUBW/codeql-noop.yml public/sonar-project.properties"
  "$PUBW/quality-public.yml $PUBW/quality-public-noop.yml $PUBW/scorecard.yml public/sonar-project.properties"
  "$PRIW/quality-private.yml $PRIW/quality-private-noop.yml private/sonar-project.properties private/infra/sonarqube/docker-compose.yml private/infra/sonarqube/README.md private/infra/github-runner/README.md"
  "$PRIW/quality-private.yml $PRIW/quality-private-noop.yml private/sonar-project.properties private/infra/sonarqube/docker-compose.yml private/infra/sonarqube/README.md private/infra/github-runner/README.md public/.snyk"
  "$PRIW/quality-private.yml $PRIW/quality-private-noop.yml public/sonar-project.properties"
  "$PRIW/quality-private.yml $PRIW/quality-private-noop.yml public/sonar-project.properties public/.snyk"
)

COMMON=(common/trivy.yaml.tmpl common/.pre-commit-config.yaml.tmpl common/SETUP.md.tmpl)

# render one row with the given languages/docker into <out>, through the selector
render_row() { # <out> <languages> <docker> <vis> <sa> <v> <cs> [extra templates...]
  local out="$1" langs="$2" docker="$3" vis="$4" sa="$5" v="$6" cs="$7"
  shift 7
  local -a sel=()
  local t sel_out
  sel_out="$(zsh "$SEL" --visibility "$vis" --static-analysis "$sa" --vulnerabilities "$v" \
    --code-scanning "$cs")"
  while IFS= read -r t; do sel+=("$t"); done <<<"$sel_out"
  zsh "$RENDER" --templates "$TEMPLATES" --out "$out" --project-name demo \
    --project-slug acme/demo --project-key acme_demo --org-key acme --languages "$langs" \
    --docker "$docker" --visibility "$vis" --static-analysis "$sa" --vulnerabilities "$v" \
    --code-scanning "$cs" "${sel[@]}" "$@" >/dev/null
}

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  SEL="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  local row n vis sa v cs
  for row in "${ROWS[@]}"; do
    read -r n vis sa v cs <<<"$row"
    render_row "$BATS_FILE_TMPDIR/row$n" python true "$vis" "$sa" "$v" "$cs" "${COMMON[@]}"
    # the Swift leg only renders for a Swift repo
    render_row "$BATS_FILE_TMPDIR/swift$n" swift false "$vis" "$sa" "$v" "$cs"
  done
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GOLDEN="$REPO_ROOT/tests/fixtures/bootstrap-toolchain-golden"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
}

# the reported check names (D2) of a workflow's PR-triggered jobs: `name:` else
# the job key, one `<name> (<lang>)` per matrix language; a job gated to
# push/release (push-and-sign) never reports on a pull request
reported() { # <workflow file>
  yq -o=json . "$1" | jq -r '.jobs | to_entries[]
    | select(((.value.if // "") | test("event_name == .push.")) and
             (((.value.if // "") | test("pull_request")) | not) | not)
    | (.value.name // .key) as $n
    | if ((.value.strategy.matrix.language // null) | type) == "array"
      then (.value.strategy.matrix.language[] | "\($n) (\(.))") else $n end' | LC_ALL=C sort
}

expected_set() { # <row> [minus-analyze]
  local s="$B|${D4[$1]}"
  if [ "${2:-}" = minus-analyze ]; then
    printf '%s\n' "$s" | tr '|' '\n' | grep -v '^analyze (' | LC_ALL=C sort
  else
    printf '%s\n' "$s" | tr '|' '\n' | LC_ALL=C sort
  fi
}

row_fields() { # <row> -> sets vis sa v cs
  read -r _ vis sa v cs <<<"${ROWS[$(($1 - 1))]}"
}

quality() { # <out> <vis> [noop]
  if [ "${3:-}" = noop ]; then
    printf '%s' "$1/$2/.github/workflows/quality-$2-noop.yml"
  else
    printf '%s' "$1/$2/.github/workflows/quality-$2.yml"
  fi
}

# --- AC1: reported names = the D4 context set ---------------------------------------

@test "toolchain render: AC1 — every row's PR jobs report exactly its D4 context set" {
  local n out actual
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    out="$BATS_FILE_TMPDIR/row$n"
    actual="$(
      reported "$(quality "$out" "$vis")"
      [ ! -f "$out/public/.github/workflows/codeql.yml" ] || reported "$out/public/.github/workflows/codeql.yml"
    )"
    actual="$(printf '%s\n' "$actual" | LC_ALL=C sort)"
    [ "$actual" = "$(expected_set "$n")" ] || {
      echo "row $n: got [$actual] want [$(expected_set "$n")]"
      return 1
    }
  done
}

@test "toolchain render: AC1 — every noop reports the D4 set minus the analyze legs; codeql-noop mirrors codeql's matrix" {
  local n out actual
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    out="$BATS_FILE_TMPDIR/row$n"
    actual="$(reported "$(quality "$out" "$vis" noop)")"
    [ "$actual" = "$(expected_set "$n" minus-analyze)" ] || {
      echo "row $n noop: got [$actual]"
      return 1
    }
    if [ -f "$out/public/.github/workflows/codeql.yml" ]; then
      [ "$(yq -o=json -I=0 '.jobs.analyze.strategy.matrix.language' "$out/public/.github/workflows/codeql-noop.yml")" = \
        "$(yq -o=json -I=0 '.jobs.analyze.strategy.matrix.language' "$out/public/.github/workflows/codeql.yml")" ]
      [ "$(yq -o=json -I=0 '.jobs.analyze.strategy.matrix.language' "$out/public/.github/workflows/codeql.yml")" = '["python"]' ]
    fi
  done
}

# --- AC2: the D5 artifact map --------------------------------------------------------

@test "toolchain render: AC2 — each row renders exactly its D5 tool-scoped files, no more and no fewer" {
  local n out actual want
  for n in 1 2 3 4 5 6 7 8; do
    out="$BATS_FILE_TMPDIR/row$n"
    actual="$(cd "$out" && find . -type f ! -path './common/*' | sed 's#^\./##' | LC_ALL=C sort)"
    want="$(printf '%s\n' ${D5[$n]} | LC_ALL=C sort)"
    [ "$actual" = "$want" ] || {
      echo "row $n: got [$actual]"
      return 1
    }
    # every row renders the three common files too
    [ -f "$out/common/trivy.yaml" ]
    [ -f "$out/common/.pre-commit-config.yaml" ]
    [ -f "$out/common/SETUP.md" ]
  done
  # the example the story names: row 8 has no infra/**, no codeql*.yml, no
  # scorecard.yml and no trivy-fs job
  [ -z "$(cd "$BATS_FILE_TMPDIR/row8" && find . -path '*infra*' -o -name 'codeql*' -o -name 'scorecard.yml')" ]
  run ! grep -q 'trivy-fs:' "$BATS_FILE_TMPDIR/row8/$PRIW/quality-private.yml"
}

@test "toolchain render: AC2 — the job-level artifacts follow the tools: image scanner, pre-commit hook, Sonar config" {
  local n out q steps hook
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    out="$BATS_FILE_TMPDIR/row$n"
    q="$(quality "$out" "$vis")"
    steps="$(yq -o=json '.jobs.image.steps' "$q" | jq -r '.[].name // empty')"
    hook="$(yq -o=json '.repos' "$out/common/.pre-commit-config.yaml" | jq -r '.[].hooks[].id' | grep -cx trivy-fs || true)"
    if [ "$v" = snyk ]; then
      contains "$steps" "Snyk container scan"
      contains "$steps" "Upload Snyk container scan (for maintenance ingestion)"
      lacks "$steps" "Trivy image vulnerability scan"
      [ "$hook" -eq 0 ]
    else
      contains "$steps" "Trivy image vulnerability scan"
      lacks "$steps" "Snyk container scan"
      [ "$hook" -eq 1 ]
    fi
    # the container-change regex watches the resolved scanner's policy file only
    if [ "$v" = snyk ]; then
      grep -q "(\^|/)\\\\.snyk\\$'" "$q"
      run ! grep -q 'trivy\\.ya?ml' "$q"
    else
      grep -q 'trivy\\.ya?ml\$' "$q"
      run ! grep -qF '\.snyk$' "$q"
    fi
    # the Sonar config is the resolved analyser's own
    if [ "$sa" = sonarcloud ]; then
      grep -q '^sonar.organization=' "$out/public/sonar-project.properties"
    else
      grep -qx 'sonar.projectKey=acme_demo' "$out/private/sonar-project.properties"
      run ! grep -q '^sonar.organization=' "$out/private/sonar-project.properties"
    fi
  done
}

# a job's body with its runner removed — the runner is AC5's, the rest is pinned here
job_body() { # <workflow> <job>
  yq -o=json -I=0 ".jobs[\"$2\"] | del(.[\"runs-on\"])" "$1"
}

@test "toolchain render: AC2 — the jobs only non-golden rows render match their golden-pinned twins" {
  local r1="$BATS_FILE_TMPDIR/row1/$PUBW/quality-public.yml" r5="$BATS_FILE_TMPDIR/row5/$PRIW/quality-private.yml"
  local n f
  # trivy-fs on the public workflow (rows 3/4) and on a hosted private one (row 7)
  # is row 5's job, runner aside
  for f in "$BATS_FILE_TMPDIR/row3/$PUBW/quality-public.yml" "$BATS_FILE_TMPDIR/row4/$PUBW/quality-public.yml" \
    "$BATS_FILE_TMPDIR/row7/$PRIW/quality-private.yml"; do
    [ "$(job_body "$f" trivy-fs)" = "$(job_body "$r5" trivy-fs)" ] || { echo "trivy-fs differs in $f"; return 1; }
  done
  # the private workflow's sonarcloud and hosted semgrep jobs (rows 7/8) are row 1's
  for n in 7 8; do
    f="$BATS_FILE_TMPDIR/row$n/$PRIW/quality-private.yml"
    [ "$(yq -o=json -I=0 '.jobs.sonarcloud' "$f")" = "$(yq -o=json -I=0 '.jobs.sonarcloud' "$r1")" ] ||
      { echo "row $n sonarcloud differs"; return 1; }
    [ "$(yq -o=json -I=0 '.jobs.semgrep' "$f")" = "$(yq -o=json -I=0 '.jobs.semgrep' "$r1")" ] ||
      { echo "row $n semgrep differs"; return 1; }
  done
  # the image job's scanner steps and its container-change regex, on the rows no
  # golden renders: Trivy on the public workflow (rows 3/4) is row 5's, Snyk on
  # the private one (rows 6/8) is row 1's
  local trivy_step='.jobs.image.steps[] | select(.name == "Trivy image vulnerability scan")'
  local snyk_steps='[.jobs.image.steps[] | select(((.name // "") | test("Snyk")) or ((.run // "") | test("snyk container test")))]'
  container_re() { yq -r '.jobs.image.steps[] | select(.id == "scan_decision") | .run' "$1" | grep '^container_re='; }
  for n in 3 4; do
    f="$BATS_FILE_TMPDIR/row$n/$PUBW/quality-public.yml"
    [ "$(yq -o=json -I=0 "$trivy_step" "$f")" = "$(yq -o=json -I=0 "$trivy_step" "$r5")" ] ||
      { echo "row $n Trivy image step differs"; return 1; }
    [ "$(container_re "$f")" = "$(container_re "$r5")" ] || { echo "row $n container_re differs"; return 1; }
  done
  [ "$(yq -o=json -I=0 "$snyk_steps" "$r1" | jq length)" -eq 3 ]
  for n in 6 8; do
    f="$BATS_FILE_TMPDIR/row$n/$PRIW/quality-private.yml"
    [ "$(yq -o=json -I=0 "$snyk_steps" "$f")" = "$(yq -o=json -I=0 "$snyk_steps" "$r1")" ] ||
      { echo "row $n Snyk image steps differ"; return 1; }
    [ "$(container_re "$f")" = "$(container_re "$r1")" ] || { echo "row $n container_re differs"; return 1; }
  done
  # the self-hosted semgrep (row 6) is row 5's: no container
  [ "$(yq -o=json -I=0 '.jobs.semgrep' "$BATS_FILE_TMPDIR/row6/$PRIW/quality-private.yml")" = \
    "$(yq -o=json -I=0 '.jobs.semgrep' "$r5")" ]
  [ "$(yq -r '.jobs.semgrep.container' "$r5")" = null ]
  # every row's Sonar scan keeps the semgrep suppression its SHA pin needs
  # (the AC3 normaliser deletes full-line comments, so it is checked here)
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    grep -qF '# nosemgrep: generic.secrets.security.detected-sonarqube-docs-api-key' \
      "$(quality "$BATS_FILE_TMPDIR/row$n" "$vis")" || { echo "row $n lost the nosemgrep line"; return 1; }
    # the local trivy-fs hook is skipped in CI exactly where no trivy binary exists:
    # a GitHub-hosted runner on a trivy toolchain
    f="$(yq -r '.jobs["pre-commit"].steps[-1].env.SKIP // ""' "$(quality "$BATS_FILE_TMPDIR/row$n" "$vis")")"
    if [ "$v" = trivy ] && [ "$sa" = sonarcloud ]; then
      [ "$f" = trivy-fs ] || { echo "row $n: pre-commit SKIP is '$f'"; return 1; }
    else
      [ -z "$f" ] || { echo "row $n: unexpected pre-commit SKIP '$f'"; return 1; }
    fi
  done
}

# --- the selector's own contract ----------------------------------------------------------

@test "toolchain render: toolchain-templates.zsh prints each row's set exactly — one per line, sorted, no repeats" {
  local sel="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  run --separate-stderr zsh "$sel" --visibility public --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    public/.github/workflows/codeql-noop.yml.tmpl \
    public/.github/workflows/codeql.yml.tmpl \
    public/.github/workflows/quality-public-noop.yml.tmpl \
    public/.github/workflows/quality-public.yml.tmpl \
    public/.github/workflows/scorecard.yml.tmpl \
    public/.snyk.tmpl \
    public/sonar-project.properties.tmpl)" ]
  run --separate-stderr zsh "$sel" --visibility private --static-analysis sonarqube --vulnerabilities trivy --code-scanning none
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    private/.github/workflows/quality-private-noop.yml.tmpl \
    private/.github/workflows/quality-private.yml.tmpl \
    private/infra/github-runner/README.md \
    private/infra/sonarqube/README.md \
    private/infra/sonarqube/docker-compose.yml.tmpl \
    private/sonar-project.properties.tmpl)" ]
}

@test "toolchain render: across the 8 rows the selector covers every template under public/ and private/" {
  local sel="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  local row n vis sa v cs union
  union="$(for row in "${ROWS[@]}"; do
    read -r n vis sa v cs <<<"$row"
    zsh "$sel" --visibility "$vis" --static-analysis "$sa" --vulnerabilities "$v" --code-scanning "$cs"
  done | LC_ALL=C sort -u)"
  [ -n "$union" ]
  [ "$union" = "$(cd "$TEMPLATES" && find public private -type f | LC_ALL=C sort)" ]
}


@test "toolchain render: toolchain-templates.zsh refuses the two rejected combinations (exit 1, no set)" {
  local sel="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  run --separate-stderr zsh "$sel" --visibility public --static-analysis sonarqube --vulnerabilities trivy --code-scanning none
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "public + sonarqube is never rendered"
  run --separate-stderr zsh "$sel" --visibility private --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "private + codeql is never rendered"
}

@test "toolchain render: toolchain-templates.zsh usage errors exit 2 with nothing on stdout" {
  local sel="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  local -a ok=(--visibility public --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql)
  local i flag bad set
  for i in 0 2 4 6; do
    flag="${ok[i]}"
    run --separate-stderr zsh "$sel" "${ok[@]:0:i}" "${ok[@]:i+2}"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    contains "$stderr" "$flag is required"
    case "$flag" in
    --visibility) bad=internal set="public | private" ;;
    --static-analysis) bad=sonarcube set="sonarcloud | sonarqube" ;;
    --vulnerabilities) bad=snik set="snyk | trivy" ;;
    --code-scanning) bad=cdoeql set="codeql | none" ;;
    esac
    run --separate-stderr zsh "$sel" "${ok[@]}" "$flag" "$bad"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    contains "$stderr" "$flag: $bad is not one of: $set"
  done
  run --separate-stderr zsh "$sel" "${ok[@]}" --frobnicate
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown argument: --frobnicate"
  run --separate-stderr zsh "$sel" "${ok[@]}" --code-scanning
  [ "$status" -eq 2 ]
  contains "$stderr" "--code-scanning needs a value"
  run --separate-stderr zsh "$sel" --help
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: toolchain-templates.zsh"
}

# --- AC3: rows 1 and 5 against the pre-change golden fixtures -------------------------

# The one normaliser, applied identically to both sides: it deletes block-marker
# lines, full-line `#` comments in non-.md files (a shebang included), and
# blank lines — and changes nothing else. Trailing inline comments stay.
normalise() { # <file>
  case "$1" in
  *.md) grep -Ev '^[[:space:]]*(#|<!--) --- [A-Z_-]+-(START|END)' "$1" | grep -Ev '^[[:space:]]*$' || true ;;
  *) grep -Ev '^[[:space:]]*(#|<!--) --- [A-Z_-]+-(START|END)' "$1" | grep -Ev '^[[:space:]]*#' |
    grep -Ev '^[[:space:]]*$' || true ;;
  esac
}

@test "toolchain render: AC3 — rows 1 and 5 render the golden file set, byte-identical after normalisation (SETUP.md exempt)" {
  local n f checked=0
  for n in 1 5; do
    [ "$(cd "$GOLDEN/row$n" && find . -type f | LC_ALL=C sort)" = \
      "$(cd "$BATS_FILE_TMPDIR/row$n" && find . -type f | LC_ALL=C sort)" ]
    while IFS= read -r f; do
      [ "${f##*/}" = SETUP.md ] && continue
      cmp <(normalise "$GOLDEN/row$n/$f") <(normalise "$BATS_FILE_TMPDIR/row$n/$f") || {
        echo "row $n: $f differs"
        diff <(normalise "$GOLDEN/row$n/$f") <(normalise "$BATS_FILE_TMPDIR/row$n/$f") | head -20
        return 1
      }
      checked=$((checked + 1))
    done < <(cd "$GOLDEN/row$n" && find . -type f | sed 's#^\./##' | LC_ALL=C sort)
  done
  # 9 + 8 files beside the two SETUP.md: a comparison that matched nothing fails
  [ "$checked" -eq 17 ]
}

@test "toolchain render: AC3 — the normaliser deletes only markers, full-line comments (not in .md) and blank lines" {
  local d="$BATS_TEST_TMPDIR"
  printf '#!/bin/sh\n  # --- TRIVY-START ---\n  key: v # inline\n\n   \n  # full\n<!-- --- PUBLIC-END --- -->\n' > "$d/a.yml"
  [ "$(normalise "$d/a.yml")" = "  key: v # inline" ]
  printf '# Heading\n<!-- --- SNYK-START --- -->\n\ntext\n' > "$d/b.md"
  [ "$(normalise "$d/b.md")" = "$(printf '# Heading\ntext')" ]
}

# --- AC4: SETUP.md composed per D6 ------------------------------------------------------

# the part a row must (1) or must not (0) contain, by its tools and visibility
setup_parts() { # <vis> <sa> <v> <cs> -> "needle<TAB>0|1" lines
  local pub=0 cloud=0 qube=0 snyk=0 trivy=0
  [ "$1" = public ] && pub=1
  [ "$2" = sonarcloud ] && cloud=1
  [ "$2" = sonarqube ] && qube=1
  [ "$3" = snyk ] && snyk=1
  [ "$3" = trivy ] && trivy=1
  printf '%s\t%s\n' \
    'brew install trivy           # for local container scanning' "$trivy" \
    '## 2. SonarCloud setup' "$cloud" \
    '### 2.3 Create the Zero Tolerance Quality Gate' "$cloud" \
    '| `SNYK_TOKEN` | Yes | from step 2b.1 below |' "$((cloud && snyk))" \
    '`scripts/automate-public.sh` runs most of' "$((cloud && pub))" \
    '## 2a. OpenSSF Scorecard — supply-chain health badge' "$pub" \
    '## 2b. Snyk setup' "$snyk" \
    '### 2b.1 Sign up for Snyk, import the repo, configure PR checks' "$snyk" \
    '### 2b.2 Enable Snyk auto-Fix-PRs (manual UI step)' "$snyk" \
    'Import while the repo is **public**' "$((snyk && pub))" \
    '## 3. SonarQube setup (self-hosted)' "$qube" \
    '### 3.5 Create the Zero Tolerance Quality Gate' "$qube" \
    '### 3.3 Register a self-hosted runner' "$qube" \
    '| `SONAR_TOKEN` | Yes | from step 2.1 |' "$cloud" \
    "**Not required either — Snyk's checks:**" "$snyk" \
    'SonarCloud needs to index the project.' "$cloud" \
    'SonarQube needs to index the project.' "$qube" \
    "Snyk also pulls the imported project's dependency graphs" "$snyk"
}

@test "toolchain render: AC4 — every row's SETUP.md holds exactly the D6 parts of its tools and visibility" {
  local n s needle want have
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    s="$BATS_FILE_TMPDIR/row$n/common/SETUP.md"
    while IFS=$'\t' read -r needle want; do
      have=0
      grep -qF -- "$needle" "$s" && have=1
      [ "$have" = "$want" ] || {
        echo "row $n: '$needle' present=$have want=$want"
        return 1
      }
    done < <(setup_parts "$vis" "$sa" "$v" "$cs")
    # no heading carries a visibility marker, and no tool choice is pinned on one
    run ! grep -nE '\*\*PUBLIC\*\*|\*\*PRIVATE\*\*|PRIVATE only|Sections marked|Snyk container for public repos' "$s"
    run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$s"
  done
  # the story's examples: row 7 has §2 but no §2a/§2b/§3; row 6 has §2b and §3 but no §2
  grep -q '^## 2\. SonarCloud setup' "$BATS_FILE_TMPDIR/row7/common/SETUP.md"
  run ! grep -qE '^## (2a|2b|3)\. ' "$BATS_FILE_TMPDIR/row7/common/SETUP.md"
  grep -q '^## 2b\. Snyk setup' "$BATS_FILE_TMPDIR/row6/common/SETUP.md"
  grep -q '^## 3\. SonarQube setup' "$BATS_FILE_TMPDIR/row6/common/SETUP.md"
  run ! grep -q '^## 2\. ' "$BATS_FILE_TMPDIR/row6/common/SETUP.md"
}

@test "toolchain render: AC4 — §4's required-context list is the row's D4 set plus no-cluster-deploy" {
  local n s list
  for n in 1 2 3 4 5 6 7 8; do
    s="$BATS_FILE_TMPDIR/row$n/common/SETUP.md"
    # the composed bullets sit between the status-checks item and the no-cluster-deploy note
    list="$(awk '/Require status checks to pass before merging/{on=1; next}
      /\*\*`no-cluster-deploy` \(§3h\)\*\*/{on=0}
      on && /^  - `[^`]*`$/ { sub(/^  - `/, ""); sub(/`$/, ""); print }' "$s" | LC_ALL=C sort)"
    [ "$list" = "$(printf '%s\n' "$(expected_set "$n")" no-cluster-deploy | LC_ALL=C sort)" ] || {
      echo "row $n §4: [$list]"
      return 1
    }
  done
}

@test "toolchain render: AC4 — §5's image scanner and 2b.1's SAST gate follow the tools" {
  local n s sast
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    s="$BATS_FILE_TMPDIR/row$n/common/SETUP.md"
    if [ "$v" = snyk ]; then
      grep -q "^The \`image\` job's scanner is \*\*Snyk container\*\*" "$s"
      run ! grep -q "scanner is \*\*Trivy\*\*" "$s"
      # the SAST gate 2b.1 names: CodeQL iff codeql, the semgrep check otherwise
      sast="$(sed -n '/^### 2b\.1 /,/^### 2b\.2 /p' "$s" | tr -s '[:space:]' ' ')"
      if [ "$cs" = codeql ]; then
        contains "$sast" "already covered by CodeQL's required \`analyze (<lang>)\` checks"
        lacks "$sast" "semgrep"
      else
        contains "$sast" "already covered by the required \`semgrep\` check"
        lacks "$sast" "CodeQL"
      fi
    else
      grep -q "^The \`image\` job's scanner is \*\*Trivy\*\*" "$s"
      run ! grep -q "Snyk container" "$s"
    fi
  done
}

@test "toolchain render: AC4 — no tracked file outside the history dirs cites SETUP.md's renumbered Snyk and Scorecard sections by their old numbers" {
  local hits
  # positive control: the sweep has a real file list to scan
  [ "$(git -C "$REPO_ROOT" ls-files | wc -l)" -gt 100 ]
  hits="$(git -C "$REPO_ROOT" ls-files | grep -v '^docs/superpowers/' | grep -v '^tests/fixtures/' |
    (cd "$REPO_ROOT" && tr '\n' '\0' | xargs -0 grep -nE '(section|step|§) ?2\.[456]([^0-9]|$)' 2>/dev/null) || true)"
  [ -z "$hits" ] || {
    echo "$hits"
    return 1
  }
}

# --- AC5: the runner rule (D3) ---------------------------------------------------------

@test "toolchain render: AC5 — every quality and noop job follows self_hosted_runner, the Swift leg on its macOS label" {
  local n f want swift_want runners
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    if [ "$sa" = sonarqube ]; then
      want='"self-hosted"' swift_want='["self-hosted","macos"]'
    else
      want='"ubuntu-latest"' swift_want='"macos-latest"'
    fi
    for f in "$(quality "$BATS_FILE_TMPDIR/row$n" "$vis")" "$(quality "$BATS_FILE_TMPDIR/row$n" "$vis" noop)" \
      "$(quality "$BATS_FILE_TMPDIR/swift$n" "$vis" noop)"; do
      runners="$(yq -o=json '.jobs' "$f" | jq -c '[.[]."runs-on"] | unique')"
      [ "$runners" = "[$want]" ] || {
        echo "row $n $f: $runners"
        return 1
      }
    done
    f="$(quality "$BATS_FILE_TMPDIR/swift$n" "$vis")"
    [ "$(yq -o=json -I=0 '.jobs["test-and-coverage-swift"]["runs-on"]' "$f")" = "$swift_want" ]
    [ "$(yq -r '.jobs["test-and-coverage-swift"].name' "$f")" = test-and-coverage ]
    # the Swift repo's other jobs follow the Linux rule
    [ "$(yq -o=json '.jobs | del(.["test-and-coverage-swift"])' "$f" | jq -c '[.[]."runs-on"] | unique')" = "[$want]" ]
    # CodeQL keeps its hard-coded GitHub-hosted runner, public rows 1 and 3 only
    if [ "$n" = 1 ] || [ "$n" = 3 ]; then
      for f in codeql.yml codeql-noop.yml; do
        [ "$(yq -r '.jobs.analyze["runs-on"]' "$BATS_FILE_TMPDIR/row$n/$PUBW/$f")" = ubuntu-latest ]
      done
    else
      [ -z "$(find "$BATS_FILE_TMPDIR/row$n" -name 'codeql*')" ]
    fi
  done
}

# --- AC6: the tags ---------------------------------------------------------------------

@test "toolchain render: AC6 — render.zsh has the seven D5 tags and no PRIVATE; only SETUP.md.tmpl has PUBLIC markers" {
  local r="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  local skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  local tag
  run ! grep -n 'PRIVATE' "$r"
  for tag in SONARCLOUD SONARQUBE SNYK TRIVY CODEQL SELF_HOSTED PUBLIC; do
    grep -qE "^[[:space:]]*$tag\) " "$r"
    grep -qF "| \`$tag\` |" "$skill"
    # the header's --visibility line lists every one of them
    sed -n '/--visibility public|private/,/--docker/p' "$r" | grep -qw "$tag"
  done
  run ! grep -qF '| `PRIVATE` |' "$skill"
  run ! grep -rlE -- '--- PRIVATE-(START|END)' "$TEMPLATES"
  [ "$(grep -rlE -- '--- PUBLIC-(START|END)' "$TEMPLATES" | sed "s#^$TEMPLATES/##")" = common/SETUP.md.tmpl ]
}

# --- AC9 / AC10: no guard left, and the docs name both rejections ------------------------

@test "toolchain render: AC9/AC10 — no temporary-guard text survives; the docs state both rejected combinations" {
  local skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  local arch="$REPO_ROOT/ARCHITECTURE.md" ref="$REPO_ROOT/docs/reference/maintenance-yml.md"
  local f
  for f in "$skill" "$arch" "$ref" "$REPO_ROOT/development/skills/bootstrap/scripts/resolve-tools.zsh"; do
    run ! grep -niE 'temporary guard|temporary-guard|cannot be rendered yet|renders? only the visibility default' "$f"
  done
  run ! grep -q 'the one combination' "$skill"
  run ! grep -q 'a toolchain the guard' "$skill"
  # both rejections, stated where the story names them
  for f in "$skill" "$arch" "$ref"; do
    grep -q 'code_scanning: codeql' "$f" || grep -q '`code_scanning` set to `codeql`' "$f"
    grep -q 'GitHub Advanced Security' "$f"
  done
  grep -q 'on a private repo Code scan, which has only `none` there' "$skill"
  # until #1671, bootstrap stops at its plan for a non-default toolchain — in
  # Resolve the toolchain, the one place the rule lives
  sed -n '/^### Resolve the toolchain (#1651)/,/^## Step 2:/p' "$skill" |
    grep -qF -- '- **exit 0, any other toolchain** → valid'
  sed -n '/^### Resolve the toolchain (#1651)/,/^## Step 2:/p' "$skill" |
    grep -qF 'stop before rendering — write nothing'
  run ! grep -qF "skips this step, and Step" "$skill"
}
