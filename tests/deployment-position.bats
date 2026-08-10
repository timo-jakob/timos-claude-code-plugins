#!/usr/bin/env bats
#
# The family's deployment position (#1189, epic #1058).
#
# ARCHITECTURE.md's "Deployment" section is the authoritative record: Argo CD /
# Helm / Kustomize recorded as audited-aligned, the promotion contract (the
# infrastructure repo is the only path to the cluster), the deployable-reference
# rule (an immutable `<image>:<semver>` tag or a digest, mutable tags never), the
# status note that the shipped ko and Docker paths do not satisfy that rule yet,
# the plane-per-namespace and configuration/secrets positions, and the
# deliberate deferral of the direct-to-cluster gate to #1206.
#
# WHY THIS FILE EXISTS: the defect #1189 repairs is an ABSENCE. The family used
# GitOps tooling while stating no rule about how an image is allowed to reach a
# cluster, so a bootstrapped repo could grow a direct-to-cluster deploy step and
# nothing in the family would find it surprising. A position nobody asserts can
# be softened, reversed, or quietly reacquire an escape hatch with the suite
# green. So each clause is pinned individually: a section-level "mentions
# deployment" check would survive deleting any one of them.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` — this story's
# standing rule. Line numbers rot across unrelated merges; the tokens pinned here
# do not.
#
# ON THE NEGATIVE PIN (the `latest` escape hatch): tests/messaging-position.bats
# can use single robust product-name TOKENS as its negatives because those words
# have no legitimate use anywhere in the repo. (They are deliberately NOT spelled
# out here: that file sweeps every TRACKED file for them and allows exactly three
# paths, one being itself, since it necessarily transcribes what it searches for.
# This file has no such need, and widening that allowlist to accommodate a mere
# example would weaken a guard to pay for a comment.) That trick is unavailable
# here in any case — this
# section must discuss `latest` at length in order to forbid it, so the bare token
# appears many times legitimately. Instead the guard greps the section for the
# VOCABULARY a softening would introduce (carve-outs, preview/non-production
# exemptions), case-folded so a capitalised reintroduction is caught too. And
# because a negative needle that has never matched anything is indistinguishable
# from a typo, tests/fixtures/deployment/softened-position.md commits a softened
# variant and a companion test asserts the detector FIRES on it — the same
# discrimination proof tests/webui-positions.bats builds for its transcribed
# needles. Without that control the whole negative test is a permanent pass.
#
# ON THE END ADDRESS: the extractor's end address is the GENERIC `^### `, not the
# specific heading that follows today. A specific end address catches a renamed or
# deleted anchor but NOT an inserted one — a new section slipped between this one
# and the next is swallowed into the range while the haystack still ends with the
# pinned heading, so every assertion here would silently start covering two
# sections. That is the exact defect this PR repairs by hand in
# tests/webui-positions.bats; reproducing it in a new file would be careless. The
# `ends_with` pin then names the heading that follows TODAY, so a reorder or
# insertion reds loudly instead of widening quietly.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  KO_TMPL="$REPO_ROOT/development/skills/bootstrap/templates/languages/go/.github/workflows/ko-image.yml.tmpl"
  QUALITY_PUBLIC="$REPO_ROOT/development/skills/bootstrap/templates/public/.github/workflows/quality-public.yml.tmpl"
  QUALITY_PRIVATE="$REPO_ROOT/development/skills/bootstrap/templates/private/.github/workflows/quality-private.yml.tmpl"
  SETUP_TMPL="$REPO_ROOT/development/skills/bootstrap/templates/common/SETUP.md.tmpl"
  SOFTENED="$BATS_TEST_DIRNAME/fixtures/deployment/softened-position.md"
}

# Collapse a document region to one line: strip blockquote markers, collapse
# whitespace, trim the trailing space `tr` leaves behind. Same helper shape as
# tests/messaging-position.bats and tests/webui-positions.bats, and the trim is
# what makes `ends_with` usable as the end-anchor pin.
collapse() {
  sed 's/^>[[:space:]]\{0,1\}//' | tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

# Extract FILE's section from START to END (both sed BRE addresses, neither
# containing a `/`), collapsed. sed prints the END line itself, which is what the
# `ends_with` pins below rely on.
extract() {
  sed -n "/$2/,/$3/p" "$1" | collapse
}

# FILE contains the literal (single-line) string. Used to prove every evidence
# pointer the section cites still resolves in the file it names — the property
# that replaces `path:line` citations. `_assert_args` guards the dropped-second-
# argument case, since `grep -qF ''` matches every non-empty file and would turn
# these into unconditional passes.
file_has() {
  _assert_args "$#" "${2-}" || return 2
  grep -qF -e "$2" -- "$1"
}

# The string `$1` has a line that IS the literal `$2`, ignoring indentation.
#
# Needed because `file_has`/`contains` are unanchored substring matches, and
# `type=semver,pattern={{major}}` is a proper PREFIX of
# `type=semver,pattern={{major}}.{{minor}}` — so an unanchored assertion for the
# bare `<major>` tag is satisfied by the `<major>.<minor>` line alone, and
# dropping the bare one (a plausible partial #1208 fix) would leave the guard
# green. Verified by mutation: with the bare lines deleted, the unanchored form
# still matches and this one does not.
#
# `$2` is interpolated into a BRE, where `{` and `}` are literal — but `.` is
# NOT, so a needle containing one matches any character there. Keep the argument
# to literal tag text and do not rely on it to discriminate a `.`.
#
# It takes a STRING rather than a file because every call site here asserts
# against an already-extracted job slice; a file-scoped variant would re-open the
# scoping hole that slice exists to close.
text_has_line() {
  _assert_args "$#" "${2-}" || return 2
  printf '%s\n' "$1" | grep -q -e "^[[:space:]]*$2[[:space:]]*\$"
}

# The `push-and-sign` job of a quality template — the ONLY job that publishes
# (its sibling `image` job builds with `push: false`, for scanning). Both jobs
# carry an identical `tags:` list, so a file-scoped assertion cannot tell them
# apart, and the natural #1208 fix — dropping the floating patterns from the
# publishing job only — would leave a file-scoped guard satisfied by the
# scan-only block. Job keys are the only `^  <name>:` lines (step keys are
# indented deeper), so the generic end address lands on the next job.
# The end address is `^  [A-Za-z0-9_-]` rather than `^  [a-z]`: a GitHub Actions
# job id may legally begin with an uppercase letter or `_`, and an end address
# that misses the next job silently runs the slice to EOF.
#
# TERMINATION IS CHECKED HERE, not at the call sites. sed prints the end line, so
# a correctly terminated slice ENDS on the next job key; a range that never
# matched its end address ends on whatever the file ends with. Returning non-zero
# in that case makes the widening loud at every call site instead of once.
#
# An earlier attempt pinned this with `lacks … 'push: false'` at one call site,
# reasoning that the scan-only `image` job must not be inside the slice. That was
# INERT: `image` sits BEFORE `push-and-sign` in both templates and sed only scans
# forward, so the needle could never match and the assertion could never fail —
# a permanent pass wearing the clothes of a guard.
publishing_job() {
  local slice
  slice="$(sed -n '/^  push-and-sign:/,/^  [A-Za-z0-9_-]/p' "$1")"
  [ -n "$slice" ] || return 1
  printf '%s\n' "$slice" | tail -n 1 | grep -qE '^  [A-Za-z0-9_-]+:' || return 1
  printf '%s\n' "$slice"
}

# The escape-hatch vocabulary, as ONE array so the detector and its
# discrimination control cannot drift apart. Every needle here must be proven to
# match the fixture by the control test below — adding a needle without adding
# fixture coverage reds, which is the property a hand-written list of `contains`
# calls could not give (four of seven were unproven before this was hoisted).
#
# These are HEURISTIC tripwires, not a proof: they catch the vocabulary a
# softening tends to use, not the idea. A rephrasing that avoids all seven slips
# through, and an innocent future sentence containing one of them reds. The
# second failure mode is loud and self-correcting, which is the trade accepted
# here; the positive clause pins above are what actually carry the contract.
ESCAPE_HATCH_NEEDLES=(
  'except in'
  'except for'
  'preview environment'
  'non-production'
  'may be deployed'
  'may reference'
  'temporarily acceptable'
)

# Every case-insensitive escape-hatch phrase in FILE, as `<line>:<text>` records
# — empty when the file is clean, so `[ -z ]` on the CAPTURED value is the
# assertion and the records are the diagnostic.
#
# `|| [ "$?" -eq 1 ]` rather than `|| true`, for the reason
# tests/messaging-position.bats documents at length: grep exits 1 on a clean
# no-match and 2 on a REAL error (missing/unreadable file, empty `$1`). `|| true`
# would fold the error into the clean case and pass on a file that was never read.
# The explicit argument guards ahead of it are what make that distinction
# reachable at all — grep's own exit 2 arrives too late to tell an unset `$1`
# from a clean file, and every caller must capture into a variable FIRST rather
# than inlining `$(…)` into `[ -z … ]`, which would discard the status entirely.
escape_hatch_mentions() {
  [ -n "${1-}" ] || return 2
  [ -r "$1" ] || return 2
  local args=() n
  for n in "${ESCAPE_HATCH_NEEDLES[@]}"; do args+=(-e "$n"); done
  grep -inF "${args[@]}" -- "$1" || [ "$?" -eq 1 ]
}

# --- the authoritative record ------------------------------------------------

ARCH_END='### Cross-repo Claude: the big-picture problem'

deployment_section() {
  extract "$ARCH" '^### Deployment' '^### '
}

# The section as raw lines rather than collapsed, for the grep-based negative
# above (which reports line numbers, and would lose them to the collapse).
raw_deployment_section() {
  sed -n '/^### Deployment/,/^### /p' "$ARCH"
}

@test "ARCHITECTURE records Argo CD / Helm / Kustomize as AUDITED-ALIGNED, not merely used (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Argo CD, with Helm charts and Kustomize overlays, is the GitOps mechanism —'
  contains "$section" 'recorded here as audited-aligned.**'
  # the reason recording it matters at all — a bare "we use Argo CD" sentence
  # would survive deleting the audited-aligned claim this criterion is about
  contains "$section" 'an unexamined agreement and an examined one look identical from the outside'
  # the ownership boundary that keeps this section from colliding with the
  # development-kubernetes responsibilities block under a different heading
  contains "$section" 'this section adds no new mechanism to them'
  # an audit marker with no scope is an absence of evidence recorded as evidence
  contains "$section" '**The marker is scoped, not open-ended:**'
  contains "$section" 'the #1061 position audit (2026-08)'
  # a condition with no actor is not a rule anyone executes — the marker would
  # outlive the audit it records
  contains "$section" 'must strike this marker in the same pull request.**'
  # striking must be the DEFAULT: an unconditioned "strike or re-date" makes
  # re-dating the cheaper edit, which silently converts an unexamined agreement
  # back into an examined one — the precise failure the marker exists to prevent
  contains "$section" 'only where that same pull request actually'
  contains "$section" 'the next position audit re-derives'
}

@test "ARCHITECTURE states the promotion contract with BOTH its rationale and its cost (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**The infrastructure repo is the only path to the cluster.**'
  contains "$section" 'a version change reaches the cluster as a **pull request against the infrastructure repo**'
  # the prohibition #1206's gate will enforce — deletable today without this pin
  contains "$section" 'never writes to a cluster itself'
  # the rationale is half the deliverable: a position without it cannot be argued with
  contains "$section" 'every change running in a cluster has a review, an author, and a revert'
  # the cost is the other half — an honest position states what it charges
  contains "$section" 'a second pull request in a second repository'
  contains "$section" 'that slowness is the point'
}

@test "ARCHITECTURE states the deployable reference as an immutable semver tag or a digest (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**An infrastructure-repo manifest references a service image by an immutable `<image>:<semver>` tag.**'
  contains "$section" '`ghcr.io/<owner>/<repo>`, one per repo'
  contains "$section" 'this family states no per-service naming rule'
  # the enumeration must be CLOSED — a digest pin is the strictly more precise
  # reference and standard practice, so leaving it unclassified reads as a ban
  contains "$section" '**The digest of a released image — `<image>@sha256:…` — is equally admitted,'
  contains "$section" 'are the two admitted forms'
  # both admitted forms are scoped to a RELEASE — an unqualified digest
  # admission would license pinning a default-branch build, defeating the
  # minting rule and the promotion contract's release-review property
  contains "$section" 'Both are scoped to a *release*'
  # the ONE obligation on a publisher: without it the ko "defect" below is
  # measured against a rule this section never states
  contains "$section" '**A release publishes its `<semver>` tag.**'
  contains "$section" 'has minted no promotion unit'
  # what makes a tag immutable is the contract, not the registry — a tag is
  # re-pushable, so asserting immutability without saying why is hand-waving
  contains "$section" 'a released version is built once and never re-pushed'
  contains "$section" 'two clusters syncing the same commit can end up running different code'
  # the base-image digest rule and this one must not read as a contradiction
  contains "$section" 'different objects for the same reason'
}

@test "ARCHITECTURE says WHEN a deployable version is minted, so the naming rule is derivable (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # without this the Docker status note asserts a violation the position does
  # not establish, and #1208's scope becomes a guess between two fixes
  contains "$section" '**A deployable version is minted on a release, not on every default-branch'
  contains "$section" 'Merging to the default branch produces a build; a *release* produces a'
}

@test "ARCHITECTURE scopes the one-image-per-repo rule and admits the monorepo gap (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # ARCHITECTURE commits to monorepo tolerance elsewhere, so an unscoped
  # one-image rule would send a multi-deployable repo into the very failure
  # this section warns about
  contains "$section" 'In the polyrepo default this document assumes'
  contains "$section" 'more than one deployable'
  contains "$section" 'This family does not yet state that rule'
  # naming the case without an outcome would leave a model to invent a naming
  # convention and record it as the family's position
  contains "$section" 'the honest outcome is an explicit stop rather'
  contains "$section" 'a human settles it before those images are promoted'
  # and it must not read as contradicting this document's monorepo tolerance
  contains "$section" 'a monorepo still *bootstraps and maintains* identically'
}

@test "ARCHITECTURE states that mutable tags are NEVER a deployable reference (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Mutable tags — `latest`, branch tags, `sha-…` — are build conveniences and'
  contains "$section" 'are never a deployable reference.**'
}

@test "ARCHITECTURE never blesses a mutable tag through an escape hatch (#1189)" {
  local raw hits
  raw="$BATS_TEST_TMPDIR/deployment-section.md"
  raw_deployment_section > "$raw"
  # anti-vacuity: an empty extraction would make the grep below trivially clean
  [ -s "$raw" ]
  grep -qF 'Mutable tags' -- "$raw"
  # the range must still END where it is meant to, or a heading change could
  # truncate it and hide softened prose below the cut
  ends_with "$(collapse < "$raw")" "$ARCH_END"
  # CAPTURE first: `[ -z "$(escape_hatch_mentions …)" ]` would discard the
  # helper's status, so an errored grep (exit 2) would produce empty output and
  # PASS on a file that was never read — the exact hole the helper's `|| [ $? -eq
  # 1 ]` idiom exists to close.
  hits="$(escape_hatch_mentions "$raw")"
  printf 'escape-hatch mentions in the Deployment section:\n%s\n' "$hits" >&2
  [ -z "$hits" ]
}

@test "EVERY escape-hatch needle is proven to discriminate against the fixture (#1189)" {
  # Without this control the test above is a permanent pass: a mis-transcribed
  # needle would match nothing forever and nothing would say so.
  #
  # Proven PER NEEDLE, not per hit-record: `escape_hatch_mentions` greps LINES,
  # so one fixture line matching two needles makes a whole-output `contains`
  # check pass even when one of the two is broken. Each needle therefore gets its
  # own single-needle grep.
  [ -f "$SOFTENED" ]
  local n
  for n in "${ESCAPE_HATCH_NEEDLES[@]}"; do
    grep -qiF -e "$n" -- "$SOFTENED" || {
      printf 'needle matches nothing in the fixture (typo, or missing coverage): %s\n' "$n" >&2
      return 1
    }
  done
  # and the detector as a whole fires on that fixture
  local hits
  hits="$(escape_hatch_mentions "$SOFTENED")"
  [ -n "$hits" ]
}

@test "the escape-hatch helper reports a bad path as an ERROR, not as a clean file (#1189)" {
  # The guard that makes the capture-then-assert discipline above meaningful.
  run escape_hatch_mentions "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 2 ]
  run escape_hatch_mentions ""
  [ "$status" -eq 2 ]
}

@test "ARCHITECTURE records the ko gap as OPEN, naming #1208 (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Status: the two shipped publish paths fall short in different ways'
  contains "$section" 'The **Go/ko path publishes an admitted reference but no promotion unit.**'
  contains "$section" 'no `--tags` alongside `--bare`'
  # the ko path DOES publish a digest, and the section admits digests — so the
  # gap must be stated as the missing promotion unit, not as "publishes nothing",
  # which would contradict the enumeration two paragraphs above
  contains "$section" 'a digest *is* one of the two admitted forms above'
  # ko applies its OWN default tag when --tags is absent, so "no --tags" must not
  # be read as "publishes no tag" — #1208's body confirms the implicit `latest`
  contains "$section" 'ko applies its own'
  contains "$section" 'a signed digest plus a mutable `latest`'
  # the ko gap must cite the clause it actually fails, not an unwritten one
  contains "$section" 'That is a failure of the publishing clause above'
  # ko's --tags REPLACES the default, so the fix withdraws today's `latest` —
  # the opposite of the Docker decision, and stated so it reads as deliberate
  contains "$section" 'ko'"'"'s `--tags` **replaces** the'
  contains "$section" 'the asymmetry is deliberate'
  # and it must be LEG-scoped, or #1208 could "fix" it by minting a version on
  # every default-branch merge — the one thing the minting rule forbids
  contains "$section" '**The defect is on the release leg**'
  contains "$section" 'minting a version on every merge would violate'
  # the issue number pinned to ITS clause, not merely present somewhere in the
  # section — a bare '#1208' needle would survive the pairing being broken
  contains "$section" '**#1208** is the follow-up that closes them'
  # the note must not read as already-fixed
  contains "$section" 'recorded here rather than implied closed'
}

@test "ARCHITECTURE records the Docker gap, locating the defect on the RELEASE leg (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Docker path mints only mutable references on a default-branch merge**'
  contains "$section" '`type=raw,value=latest,enable={{is_default_branch}}`'
  # the default-branch half follows from the minting rule and is NOT the defect
  contains "$section" 'no name a manifest may use'
  # the Docker leg DOES mint the immutable name, so the gap is labelling, not a
  # missing promotion unit — conflating the two would send #1208 at the wrong fix
  contains "$section" '**Docker release leg publishes the right name among several unlabelled'
  contains "$section" 'floating `latest`, `<major>`'
  contains "$section" '`sha-<short>` as well'
  # publishing a mutable tag violates nothing the position states — it constrains
  # what a MANIFEST may reference — so #1208 labels rather than withdraws, which
  # is also what #1208's own recorded decisions say
  contains "$section" '**This is a labelling gap, not a rule violation'
  contains "$section" 'changes no Docker tag on either leg'
  # the mechanism is still named, and the derived doc still labelled as derived
  contains "$section" '`type=semver,pattern={{major}}`'
  contains "$section" 'default `latest=auto`'
  contains "$section" 'a derived document rather than the mechanism'
}

@test "ARCHITECTURE STATES plane-per-namespace with NetworkPolicy-enforced direction (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Each plane gets its own namespace, and traffic direction is enforced by'
  contains "$section" 'reaches a control-plane service only through that service'\''s published API'
  contains "$section" 'into a packet that does not arrive'
}

@test "ARCHITECTURE STATES the configuration and secrets position (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Configuration arrives as environment variables; secrets are never baked into'
  contains "$section" 'an operator that syncs them from the secrets store'
  contains "$section" 'several images sharing one name'
  contains "$section" 'unrevocable by the mechanism that put it there'
}

@test "ARCHITECTURE defers the direct-to-cluster gate to #1206 as a CHOICE, not an oversight (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**The direct-to-cluster gate is deliberately not part of this section.**'
  contains "$section" 'it **will**, but that gate is unbuilt and ships as'
  contains "$section" 'a sequencing choice, not an oversight'
}

@test "ARCHITECTURE does not let ONE named gap imply the other positions are realized (#1189)" {
  local section
  section="$(deployment_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # the sibling position sections both close with this disclaimer; without it,
  # attaching a status note to exactly one position reads as a clean bill for
  # the rest — none of which is scaffolded anywhere today
  contains "$section" 'is a separate and currently unscheduled concern'
  contains "$section" 'has **no** automated enforcer'
  contains "$section" 'stated positions awaiting mechanism, not shipped guarantees'
  # #1206 is ALSO a filed follow-up, so claiming the publish-path gap is the
  # only one contradicts the paragraph above it
  contains "$section" '**Two** gaps are called out by name here'
  contains "$section" 'the direct-to-cluster gate (#1206)'
  # and an unshipped gate must not be described in the present tense inside the
  # very paragraph warning that "a gate exists" is easy to over-read
  contains "$section" 'No gate in this family enforces the promotion contract today'
  contains "$section" '#1206, once it ships, **will**'
}

# --- the evidence pointers resolve -------------------------------------------
#
# This is what replaces `path:line` citations: the section cites files by path
# and quotes a token from each, so the citation is checkable. Both halves are
# pinned — the path as the section actually spells it, AND the token in the file
# — because checking only the token lets the prose's path rot (or be renamed)
# while the hard-coded path here still resolves, and the suite stays green while
# ARCHITECTURE cites a file that does not exist.

@test "every file the status note cites is spelled in the prose AND still contains its quoted token (#1189)" {
  local section ko_cmd setup_row
  section="$(deployment_section)"
  [ -n "$section" ]
  # without this, a demoted end heading widens $section to the rest of the file
  # and the path assertions below could be satisfied by mentions elsewhere
  ends_with "$section" "$ARCH_END"

  # BOTH halves of each citation, from ONE needle each, so the prose and the
  # file cannot drift apart: checking only the file lets the prose misquote it,
  # and checking only the prose lets the file rot out from under the quote.
  ko_cmd='ko build --sbom=spdx --platform=linux/amd64,linux/arm64 --bare ./...'
  contains "$section" "${KO_TMPL#"$REPO_ROOT/"}"
  [ -f "$KO_TMPL" ]
  contains "$section" "$ko_cmd"
  file_has "$KO_TMPL" "$ko_cmd"

  contains "$section" "${QUALITY_PUBLIC#"$REPO_ROOT/"}"
  [ -f "$QUALITY_PUBLIC" ]
  file_has "$QUALITY_PUBLIC" 'type=ref,event=branch'
  file_has "$QUALITY_PUBLIC" 'type=sha,format=short,prefix=sha-'
  file_has "$QUALITY_PUBLIC" 'type=raw,value=latest,enable={{is_default_branch}}'

  # the private counterpart is cited by PATH now, not by paraphrase, so it is
  # checkable — and it carries the identical tag list, so #1208 fixing one leg
  # and not the other must not pass unnoticed
  contains "$section" "${QUALITY_PRIVATE#"$REPO_ROOT/"}"
  [ -f "$QUALITY_PRIVATE" ]
  file_has "$QUALITY_PRIVATE" 'type=ref,event=branch'
  file_has "$QUALITY_PRIVATE" 'type=sha,format=short,prefix=sha-'
  file_has "$QUALITY_PRIVATE" 'type=raw,value=latest,enable={{is_default_branch}}'

  setup_row='`1.2.3`, `1.2`, `1`, `latest` (if not prerelease)'
  contains "$section" "${SETUP_TMPL#"$REPO_ROOT/"}"
  [ -f "$SETUP_TMPL" ]
  contains "$section" "$setup_row"
  file_has "$SETUP_TMPL" "$setup_row"
}

@test "the ko gap the status note describes is REAL — the publish step still passes no --tags (#1189)" {
  [ -f "$KO_TMPL" ]
  # Anti-staleness in the other direction: when #1208 adds `--tags` to the
  # publish step, this reds and the status note above must be rewritten rather
  # than left claiming a gap that has since closed.
  #
  # Scoped to the whole publish STEP, not to the line matching `--bare`: the step
  # is a `run: |` block, so the natural way to add tagging is a backslash
  # continuation, which would land `--tags` on a line a `--bare`-matching grep
  # never sees — and the guard would pass in exactly the PR it exists to catch.
  local publish
  publish="$(sed -n '/name: Publish image (ko/,/name: Sign the/p' "$KO_TMPL" | collapse)"
  [ -n "$publish" ]
  # positive anchor: prove the range really is the publish step before trusting
  # a negative assertion about its contents
  contains "$publish" '--bare ./...'
  lacks "$publish" '--tags'
}

@test "the Docker release-leg gap is REAL — the PUBLISHING job still mints the floating tags (#1189)" {
  # The counterpart of the ko guard. Scoped to `push-and-sign`, because the
  # sibling `image` job carries an identical tag list and pushes nothing: a
  # file-scoped assertion would be satisfied by the scan-only block, so the
  # obvious #1208 fix (drop the floating patterns where they have registry
  # consequences) would leave this green in exactly the PR it exists to catch.
  #
  # The tag list is ONE `tags:` block per job carrying both the mutable entries
  # and the three `type=semver` patterns — each `type=` only FIRES on its
  # matching event — so there is no separate "branch block" to assert against.
  local job
  for job in "$QUALITY_PUBLIC" "$QUALITY_PRIVATE"; do
    [ -f "$job" ]
    local pub
    pub="$(publishing_job "$job")"
    [ -n "$pub" ]
    # positive anchors: prove the range really is the publishing job before
    # trusting any assertion about its contents
    printf '%s' "$pub" | grep -qF 'docker/metadata-action'
    printf '%s' "$pub" | grep -qF 'push: true'
    # the immutable tag stays; it is the floating siblings #1208 removes
    printf '%s' "$pub" | grep -qF 'type=semver,pattern={{version}}'
    printf '%s' "$pub" | grep -qF 'type=semver,pattern={{major}}.{{minor}}'
    # line-anchored: the bare `<major>` needle is a PREFIX of the line above, so
    # an unanchored check could never fail on its own
    text_has_line "$pub" 'type=semver,pattern={{major}}'
    # every assertion above is POSITIVE, so widening is the unsafe direction: a
    # later job's tag list would satisfy them after #1208 edited this one.
    # publishing_job() already refuses an unterminated slice; this pins the
    # consequence directly — exactly ONE metadata block is in scope, so a
    # widened range carrying a second job's tags reds here.
    [ "$(printf '%s\n' "$pub" | grep -cF 'docker/metadata-action')" -eq 1 ]
  done
}

@test "the release-leg 'latest' really is minted by the ABSENT flavor key, as the note claims (#1189)" {
  # The note's most easily-mis-fixed claim: `latest` on a release comes from
  # docker/metadata-action's default `latest=auto`, NOT from any present line —
  # the `type=raw,value=latest,...` entry is gated on `is_default_branch`, which
  # is false on a release. So #1208 must ADD `flavor: latest=false` rather than
  # only delete patterns. This pins both halves of that reasoning, and reds the
  # moment a `flavor:` key appears (at which point the note must be rewritten).
  local job pub
  for job in "$QUALITY_PUBLIC" "$QUALITY_PRIVATE"; do
    [ -f "$job" ]
    # scoped to the PUBLISHING job: the same entry also sits in the scan-only
    # `image` job, so a file-scoped anchor would be satisfied by a block that
    # never reaches a registry — the defect this suite already fixed once
    pub="$(publishing_job "$job")"
    [ -n "$pub" ]
    text_has_line "$pub" 'type=raw,value=latest,enable={{is_default_branch}}'
    # the flavor check stays FILE-scoped deliberately: the prose claims neither
    # template sets the key anywhere, and a `flavor:` added to either job should
    # red (over-strict is the safe direction for this one)
    run grep -n 'flavor:' -- "$job"
    [ "$status" -eq 1 ]
  done
}
