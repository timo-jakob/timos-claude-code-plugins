#!/usr/bin/env bats
#
# In-page anchors that have to survive BOTH renderers (#1542).
#
# The site and manual.pdf slugify a heading differently, so a link written for
# one can dangle in the other — `mkdocs build --strict` passes (the site's
# anchor is right) and pandoc exits 0 with a warning nobody reads. The rule and
# its remedy are stated canonically in docs/how-to/authoring-guide.md ("Every
# heading an in-page (`#…`) link targets needs an explicit id"); this file guards what
# makes the remedy work: `attr_list` so the site reads the explicit id, the
# styleguide page's own id/link pair, the PR-gate step that fails on an
# unresolved reference so the next one cannot ship silently, that step's own
# positive control, and the redirection that puts pandoc's diagnostics where
# both log gates read them.
#
# These tests do NOT build a PDF — that needs docker and a 1.6 GB image. They
# assert the WIRING, and they assert it structurally: a needle that a comment
# or a neighbouring step could satisfy would keep passing while the gate it
# stands for was deleted.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO_ROOT/.github/workflows/docs.yml"
  PAGE="$REPO_ROOT/docs/how-to/adopt-the-api-styleguide.md"
  GATE_STEP="Fail on references the PDF cannot resolve"
  BUILD_STEP="Build manual.pdf + manual.epub with pandoc"
}

# The `run:` body of one named step of the pdf-epub job. `select` matches
# nothing when no step carries that name, so a renamed, commented-out or
# deleted step yields an EMPTY body and every assertion on it reds — where a
# grep over the whole file would still be satisfied by the step's own leftover
# text, or by a neighbouring step that happens to name the same log.
step_run() {
  yq -r ".jobs.pdf-epub.steps[] | select(.name == \"$1\") | .run" "$GATE"
}

# The explicit {#id} on the styleguide page's contracts-lint.yml heading.
# grep into a variable, not a `grep | sed` pipeline: a pipeline's status is
# sed's, which is always 0, so a vanished heading would yield "" rather than a
# failure at the point of the mistake.
heading_id() {
  local line
  line="$(grep -m1 '^### Check your own `contracts-lint\.yml` first [{]#' "$PAGE")" || return 1
  line="${line#*[{]#}"
  printf '%s' "${line%\}}"
}

# The target of that heading's in-page link, further down the same page.
link_id() {
  local line
  line="$(grep -m1 '\[Check your own `contracts-lint\.yml` first\](#' "$PAGE")" || return 1
  line="${line#*\](#}"
  printf '%s' "${line%%)*}"
}

@test "pdf anchors: the PR gate fails on a reference the PDF cannot resolve" {
  # pandoc reports the dangling link and still exits 0, so the gate is the only
  # thing standing between a dead in-page link and a published manual. Assert
  # the whole trip — trigger, log, and the exit that makes it a gate — INSIDE
  # the step, since `pandoc-pdf.log` also appears in two steps that predate it.
  local body verdict
  body="$(step_run "$GATE_STEP")"
  contains "$body" 'grep -q "There were undefined references" pandoc-pdf.log; then'
  # The verdict's OWN exit, not any exit in the body: the probe and the log
  # precondition carry one each, so a whole-body needle is satisfied by a guard
  # that fires on toolchain trouble while the verdict prints its error and
  # returns 0 — a gate degraded to a log-printer, green, shipping the link.
  verdict="${body##*'pandoc-pdf.log; then'}"
  [ "$verdict" != "$body" ]   # ${x##…} yields x unchanged when it cannot slice
  contains "$verdict" "exit 1"
}

@test "pdf anchors: the gate proves it can fire before trusting a clean log" {
  # The verdict is a negative test, so "no dangling link" and "the warning never
  # reached the log" are indistinguishable. The probe builds a document whose
  # only link dangles and requires the warning to appear; without it, a pandoc
  # image that stopped relaying the LaTeX log would leave the gate permanently,
  # silently green.
  local body infra probe guard open cond
  body="$(step_run "$GATE_STEP")"
  contains "$body" "no-such-anchor"
  # Each branch's OWN exit, sliced out of the body: the message text alone
  # survives deleting the exit, and a whole-body needle is satisfied by whichever
  # exit is left. Assert each slice's start needle FIRST — a cut that cannot
  # match returns the whole body, and the closing cut then lands on a
  # neighbouring branch's terminator, so the exit assertion would pass on that
  # branch's exit and deleting a whole branch would go unnoticed.
  #
  # the probe's status is KEPT, not discarded: a container that could not run is
  # infrastructure and must not be reported as "pandoc stopped relaying"
  open='2>&1)" || {'
  contains "$body" "$open"
  infra="${body#*"$open"}"
  infra="${infra%%$'\n'\}*}"
  [ "$infra" != "$body" ]
  contains "$infra" "exit 1"
  cond='if ! printf '\''%s\n'\'' "$probe_log" | grep -q "There were undefined references"; then'
  contains "$body" "$cond"
  probe="${body#*"$cond"}"
  probe="${probe%%$'\n'fi*}"
  [ "$probe" != "$body" ]
  contains "$probe" "exit 1"
  # a missing or empty log is its own failure, never a quiet pass (grep's exit 2
  # is indistinguishable from "no match" inside an `if`)
  contains "$body" 'test -s pandoc-pdf.log || {'
  guard="${body#*test -s pandoc-pdf.log}"
  guard="${guard%%$'\n'\}*}"
  [ "$guard" != "$body" ]
  contains "$guard" "exit 1"
}

@test "pdf anchors: the build step captures pandoc's diagnostics into that log" {
  # Both log-reading gates are only as good as this redirection: drop the 2>&1
  # and pandoc-pdf.log holds stdout alone, so every warning goes to the console
  # and neither gate can ever fire.
  local body
  body="$(step_run "$BUILD_STEP")"
  contains "$body" '2>&1 | tee pandoc-pdf.log'
}

@test "pdf anchors: mkdocs reads explicit heading ids" {
  # Without attr_list the `{#id}` is not markup on the site — it renders as
  # literal text in the heading and the site anchor reverts to the slug.
  # Asserted as a member of markdown_extensions, so the comment block that
  # explains attr_list by name cannot satisfy it.
  local found
  found="$(yq -r '.markdown_extensions[] | select(. == "attr_list")' "$REPO_ROOT/mkdocs.yml")"
  [ "$found" = "attr_list" ]
}

@test "pdf anchors: the rule mkdocs.yml cites is the rule the guide states" {
  # The gate's remediation message tells a fixer to paste the id the heading
  # already publishes; WHY that matters, and how to read it without moving the
  # anchor, is stated once — in the authoring guide. mkdocs.yml and this file's
  # header both point there by quoting the rule, and a citation cannot notice
  # the loss of what it cites: deleting the bullet leaves the whole suite and
  # `mkdocs build --strict` green while the guessed-id regression returns.
  local guide quoted
  guide="$(cat "$REPO_ROOT/docs/how-to/authoring-guide.md")"
  quoted='heading an in-page (`#…`) link targets needs an explicit id'
  contains "$guide" "$quoted"
  contains "$(cat "$REPO_ROOT/mkdocs.yml")" "$quoted"
  # the clause the gate's own message echoes, and the reason it can be obeyed
  contains "$guide" "never guess it"
}

@test "pdf anchors: the styleguide's in-page link and its heading share one id" {
  local heading link
  heading="$(heading_id)"
  link="$(link_id)"
  [ -n "$heading" ]
  [ -n "$link" ]
  [ "$heading" = "$link" ]
}

@test "pdf anchors: the explicit id keeps the anchor MkDocs already published" {
  # Preferring pandoc's spelling (which keeps the `.`) would fix the PDF by
  # breaking every bookmark and inbound link to the site's heading.
  local heading
  heading="$(heading_id)"
  [ -n "$heading" ]
  [ "$heading" = "check-your-own-contracts-lintyml-first" ]
}
