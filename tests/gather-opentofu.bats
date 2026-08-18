#!/usr/bin/env bats
#
# Behavioral tests for gather-opentofu-findings.zsh (epic #1158, child #1160),
# mirroring tests/gather-kubernetes.bats.
#
# These pin the payload contract the `development-opentofu` maintenance
# dispatcher consumes, so the two cannot drift.
#
# The load-bearing distinction throughout: an UNCONFIGURED tool is ABSENT from
# `findings_by_tool` (the v2 contract in ARCHITECTURE.md), which is why the
# absence assertions use `has()` rather than a length check — `[] | length` is
# also 0, so a length assertion would make "not configured" and "configured and
# clean" indistinguishable, which is precisely the confusion this gather's
# policy skip must never create. `tooling_configured`, by contrast, carries all
# SEVEN keys always: that vocabulary IS the contract, and a key going missing is
# indistinguishable from a key that was renamed.
#
# CONFTEST IS STUBBED, never assumed. The gather EVALUATES declared policies
# (ARCHITECTURE.md: a declared set Conftest cannot evaluate never skips), so a
# test that let the host's real conftest — present or absent — decide would
# assert a different thing on the maintainer's Mac than in the container. Every
# policy-evaluation test puts a purpose-built stub first on PATH; the one test
# that pins the tool-absent behaviour empties PATH deliberately.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-opentofu-findings.zsh"
  W="$BATS_TEST_TMPDIR/repo"
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$W" "$STUB"
}

# --- fixture helpers ---------------------------------------------------------

# a ROOT module: declares a provider, so it owns state (the classifier's first
# question). Unencrypted unless a helper below says otherwise.
root_module() {
  printf 'provider "aws" {\n  region = "eu-central-1"\n}\n\nterraform {\n  backend "s3" {\n    bucket = "state"\n  }\n}\n' \
    > "$W/main.tf"
}

# a MODULE LIBRARY: `required_providers` but no provider/backend/cloud block, so
# it owns no state and the encryption check must report nothing.
module_library() {
  mkdir -p "$W/modules/network"
  printf 'terraform {\n  required_version = ">= 1.6"\n  required_providers {\n    aws = {\n      source = "hashicorp/aws"\n    }\n  }\n}\n' \
    > "$W/modules/network/versions.tf"
  printf 'variable "cidr" {\n  type = string\n}\n' > "$W/modules/network/vpc.tf"
}

encrypted_root_tofu() {
  printf 'provider "aws" {}\n\nterraform {\n  encryption {\n    key_provider "pbkdf2" "k" {\n      passphrase = "fixture-value-not-a-secret"\n    }\n  }\n  backend "s3" {\n    bucket = "state"\n  }\n}\n' \
    > "$W/main.tf"
}

encrypted_root_backend() {
  printf 'provider "aws" {}\n\nterraform {\n  backend "s3" {\n    bucket     = "state"\n    encrypt    = true\n    kms_key_id = "arn:aws:kms:eu-central-1:1:key/x"\n  }\n}\n' \
    > "$W/main.tf"
}

policy() {
  mkdir -p "$W/policies/conftest"
  printf 'package main\n\ndeny contains msg if {\n  input.resource.aws_s3_bucket\n  msg := "no public buckets"\n}\n' \
    > "$W/policies/conftest/deny_public_buckets.rego"
}

policy_test() {
  mkdir -p "$W/policies/conftest"
  printf 'package main\n\ntest_denies_public_bucket if {\n  count(deny) == 1 with input as {"resource": {"aws_s3_bucket": {}}}\n}\n' \
    > "$W/policies/conftest/deny_public_buckets_test.rego"
}

# `conftest` stub. $1 is the exit status `verify` reports, $2 its output, $3 the
# version it reports, $4 the stream verify writes to (`out` or `err`).
#
# THE STUB MUST BE HONEST ABOUT THE REAL TOOL, or it silently proves the wrong
# thing. Two shapes matter and both are reproduced:
#   * `--version` prints TWO lines (`Conftest: vX.Y.Z` / `OPA: vA.B.C`), with a
#     `v` prefix. The LOAD-BEARING filter is the script's
#     `grep -m1 -E '^[[:space:]]*Conftest:'`, which is what stops OPA's version
#     being compared against the Conftest pin; `head -1` after it is
#     defence-in-depth, not the mechanism. A one-line, prefix-free stub leaves
#     both inert, and a `Conftest:` filter deleted under it would make a
#     `Conftest: vdev` build fall through to OPA's version and emit a spurious
#     pin note naming two versions that were never meant to be compared.
#   * `verify` reports compile errors and failures on STDERR, which is why the
#     script captures with `2>&1`. A stdout-only stub keeps every test green
#     while production `verify_out` would be empty — so every compile error
#     would be misclassified and the finding's "conftest said:" tail empty.
# It also RECORDS ITS ARGV, so a test can assert the tool was invoked at all and
# invoked with `--policy`: dropping that flag makes the real tool default to its
# own `policy/` directory, find nothing, exit 0, and report a repo's declared
# Rego clean — the green-over-unenforced state the charter forbids.
stub_conftest() {
  local rc="${1:-0}" out="${2:-}" ver="${3:-0.69.0}" stream="${4:-out}"
  local redirect=""
  [ "$stream" = "err" ] && redirect=">&2"
  cat > "$STUB/conftest" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/conftest.argv"
# the CWD too: the argv alone is identical whether or not the script cd'd into
# the repo, so without this the "runs INSIDE the repo" test cannot fail
printf '%s\n' "\$PWD" >> "$BATS_TEST_TMPDIR/conftest.pwd"
if [ "\$1" = "--version" ]; then printf 'Conftest: v%s\nOPA: v1.4.2\n' "$ver"; exit 0; fi
if [ "\$1" = "verify" ]; then printf '%s\n' "$out" $redirect; exit $rc; fi
exit 0
EOF
  chmod +x "$STUB/conftest"
}

# a PATH carrying the stub but NOT jq, for the documented exit 3
jq_free_path() {
  local d="$BATS_TEST_TMPDIR/nojq" t src
  mkdir -p "$d"
  for t in find grep xargs cat awk sed sort tr head tail uname; do
    src="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$src" "$d/$t"
  done
  printf '%s' "$d"
}

gather() { PATH="$STUB:$PATH" zsh "$GATHER" "$W"; }

# the orchestrator partitions on `test -x` and then EXECUTES the file, so the
# shebang is part of the contract; `zsh "$GATHER"` bypasses it
gather_directly() { PATH="$STUB:$PATH" "$GATHER" "$W"; }

# Capture the payload ONCE into $PAYLOAD, then assert against it. bats' `run`
# overwrites `$output` on every call, so a second `run … jq …` in the same test
# would be reading the FIRST assertion's result — which is how a `jq -e` that
# printed `true` ends up being indexed as the payload.
capture() {
  PAYLOAD="$(gather)"
}

# `jqe <filter>` — the filter must be TRUE of the captured payload. A simple
# command, so errexit catches it wherever it appears (the assertions.bash rule).
jqe() {
  printf '%s' "$PAYLOAD" | jq -e "$1" >/dev/null
}

# `jqr <filter>` — print a scalar from the captured payload, for `contains`.
jqr() {
  printf '%s' "$PAYLOAD" | jq -r "$1"
}

# A PATH built from symlinks to exactly the tools the gather needs, and
# deliberately WITHOUT conftest — so the tool-absent branch is exercised on a
# machine that has conftest installed just as it is on one that does not.
# Assuming the host simply lacks it would make this test assert one thing on the
# maintainer's Mac and another in CI, which is the divergence the stub exists to
# prevent everywhere else.
conftest_free_path() {
  local d="$BATS_TEST_TMPDIR/nc" t src
  mkdir -p "$d"
  for t in jq find grep xargs cat awk sed sort tr head tail uname; do
    src="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$src" "$d/$t"
  done
  printf '%s' "$d"
}

# --- the payload envelope ----------------------------------------------------

@test "a .tf repo emits the v2 payload with exactly the seven tool keys (#1381)" {
  root_module
  stub_conftest
  capture
  # EQUALITY, not `contains`. A substring check is satisfied by any superset
  # whose extra key sorts outside the run — `drift,format,…` or
  # `…,validate,workspaces` both contain the needle — and an added key is
  # precisely the routing drift the dispatcher halts on, i.e. the one regression
  # this test exists for.
  jqe '(.tooling_configured | keys | sort) ==
       ["format","lint","misconfiguration","policy","policy_tests","state_encryption","validate"]'
}

@test "coverage is always null — a topic has no application test suite (#1381)" {
  root_module
  stub_conftest
  capture
  jqe '.coverage == null'
}

@test "the script is executable with its own shebang (the orchestrator execs it)" {
  root_module
  stub_conftest
  run -0 gather_directly
  contains "$output" '"tooling_configured"'
}

@test "the four presence-detected tools are configured and carry empty arrays" {
  root_module
  stub_conftest
  capture
  # one jqe per conjunct: jq's `and` short-circuits, so a bundled filter fails
  # with a bare non-zero status and no indication of WHICH conjunct was false
  jqe '.tooling_configured.format == true'
  jqe '.tooling_configured.validate == true'
  jqe '.tooling_configured.lint == true'
  jqe '.tooling_configured.misconfiguration == true'
  jqe '.findings_by_tool.format == []'
  jqe '.findings_by_tool.validate == []'
  jqe '.findings_by_tool.lint == []'
  jqe '.findings_by_tool.misconfiguration == []'
  # state_encryption's VALUE was pinned nowhere — the key appeared only as a name
  # in the seven-key list. Rewiring it to `$policies` (a plausible copy-paste
  # beside the policy keys) would emit `state_encryption: false`, which the
  # dispatcher's Response contract calls a payload-contract break that halts the
  # whole dispatch.
  jqe '.tooling_configured.state_encryption == true'
}

@test "the presence-detection note names the four, and the three that evaluate" {
  root_module
  stub_conftest
  capture
  run -0 jqr '.notes | join(" ")'
  # the FIRST half is the load-bearing one — it is why the note exists at all —
  # so pin the names and the tools, not merely the phrase. Dropping
  # `misconfiguration`, renaming a key the dispatcher routes on, or swapping in
  # a tool that never runs would otherwise ship green into a summary a human
  # reads verbatim.
  contains "$output" "format/validate/lint/misconfiguration: presence-detected only"
  contains "$output" "tofu fmt, tofu validate, tflint and trivy config run in the CI pipeline (#1162)"
  # the tail names WHICH KEYS EVALUATE — a static property of the gather — and
  # deliberately NOT what each concluded on this run. An earlier version reported
  # per-run outcomes and needed a flag per branch; every review round then found
  # another branch where it over- or under-claimed (a suppressed verdict, an
  # unresolved one, a policy set that would not compile, a conftest that could
  # not run, policy_tests which evaluates without conftest at all). The per-run
  # story is told by the findings and the other notes, which is where this
  # sentence now points.
  contains "$output" "state_encryption, policy and policy_tests are EVALUATED in this gather"
  contains "$output" "read their findings and the notes above"
  lacks "$output" "evaluated here"
}

@test "the tail is IDENTICAL whether or not policies are declared" {
  # the whole point of the static wording: it describes the gather's design, so
  # it cannot drift out of step with what a particular branch concluded. This
  # COMPARES the two renderings rather than re-asserting one needle on each —
  # otherwise any drift the needles do not cover (the leading half, punctuation,
  # an appended per-run clause) satisfies both branches and the test's name
  # promises more than it checks.
  root_module
  stub_conftest
  capture
  run -0 jqr '[.notes[] | select(test("presence-detected only"))] | length'
  [ "$output" = "1" ]
  run -0 jqr '[.notes[] | select(test("presence-detected only"))] | .[0]'
  local without="$output"

  rm -rf "$W"; mkdir -p "$W"
  root_module
  policy
  policy_test
  stub_conftest
  capture
  run -0 jqr '[.notes[] | select(test("presence-detected only"))] | .[0]'
  [ "$output" = "$without" ]
  contains "$output" "state_encryption, policy and policy_tests are EVALUATED in this gather"
  lacks "$output" "evaluated here"
}

# --- pruning -----------------------------------------------------------------

@test "a repo whose only .tf sit under .terraform/ and vendored trees is not detected (#1382)" {
  mkdir -p "$W/.terraform" "$W/vendor/modules" "$W/node_modules/x"
  printf 'provider "aws" {}\n' > "$W/.terraform/cached.tf"
  printf 'provider "aws" {}\n' > "$W/vendor/modules/v.tf"
  printf 'provider "aws" {}\n' > "$W/node_modules/x/n.tf"
  stub_conftest
  capture
  # every presence-detected key false, and findings_by_tool carries none of them
  jqe '.tooling_configured.format == false'
  jqe '.tooling_configured.validate == false'
  jqe '.tooling_configured.lint == false'
  jqe '.tooling_configured.misconfiguration == false'
  jqe '.tooling_configured.state_encryption == false'
  jqe '.findings_by_tool | has("format") | not'
  jqe '.findings_by_tool | has("state_encryption") | not'
}

@test "a .tf outside the pruned trees still counts when pruned copies exist" {
  root_module
  mkdir -p "$W/.terraform"
  printf 'provider "aws" {}\n' > "$W/.terraform/cached.tf"
  stub_conftest
  capture
  jqe '.tooling_configured.format == true'
}

# --- state_encryption: the one built-in opinion ------------------------------

@test "a root owning unencrypted state yields exactly one state_encryption finding (#1385)" {
  root_module
  stub_conftest
  capture
  jqe '(.findings_by_tool.state_encryption | length) == 1'
  run -0 jqr '.findings_by_tool.state_encryption[0].id'
  contains "$output" "state_encryption:unencrypted-state"
}

@test "the OpenTofu encryption block clears the check (invariant 1)" {
  encrypted_root_tofu
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

@test "backend-level encryption clears the check too — the rule is dialect-aware" {
  encrypted_root_backend
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

@test "an azurerm backend clears the check — the platform encrypts unconditionally" {
  printf 'provider "azurerm" {}\n\nterraform {\n  backend "azurerm" {\n    container_name = "state"\n  }\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

@test "a cloud block clears the check — HCP Terraform holds the state" {
  printf 'terraform {\n  cloud {\n    organization = "acme"\n  }\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

@test "a module library owns no state, so the check reports nothing and says why" {
  module_library
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
  run -0 jqr '.notes | join(" ")'
  contains "$output" "reusable module library"
}

@test "required_providers alone never makes a repo a root — the discriminator is a provider block" {
  module_library
  stub_conftest
  capture
  # the note is the positive evidence that the LIBRARY branch ran, not merely
  # that no finding was emitted (which an encrypted root would also produce)
  jqe '[.notes[] | select(test("module library"))] | length == 1'
}

@test "a root with a provider and NO backend is not exempt — implicit local state (invariant 2)" {
  printf 'provider "aws" {\n  region = "eu-central-1"\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '(.findings_by_tool.state_encryption | length) == 1'
}

@test "encryption configured in the PRUNED provider cache never clears a real root" {
  root_module
  mkdir -p "$W/.terraform"
  printf 'terraform {\n  encryption {\n    key_provider "pbkdf2" "k" {}\n  }\n}\n' > "$W/.terraform/cached.tf"
  stub_conftest
  capture
  jqe '(.findings_by_tool.state_encryption | length) == 1'
}

# --- policy: the glob, and the skip that is never a finding -------------------

@test "no policies/conftest directory at all: policy false, a note, and no policy key" {
  root_module
  stub_conftest
  capture
  jqe '.tooling_configured.policy == false'
  jqe '.tooling_configured.policy_tests == false'
  jqe '.findings_by_tool | has("policy") | not'
  jqe '.findings_by_tool | has("policy_tests") | not'
  run -0 jqr '.notes | join(" ")'
  contains "$output" "no policies declared at policies/conftest"
}

@test "an EMPTY policies/conftest is identical to an absent one (#1383)" {
  root_module
  mkdir -p "$W/policies/conftest"
  stub_conftest
  capture
  jqe '.tooling_configured.policy == false'
  jqe '.findings_by_tool | has("policy") | not'
  run -0 jqr '.notes | join(" ")'
  contains "$output" "step skipped, not failed"
}

@test "a non-.rego file in policies/conftest does not declare policies (#1383)" {
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'not rego\n' > "$W/policies/conftest/README.md"
  stub_conftest
  capture
  jqe '.tooling_configured.policy == false'
}

@test "a declared policy set makes policy and policy_tests configured" {
  root_module
  policy
  policy_test
  stub_conftest
  capture
  jqe '.tooling_configured.policy == true'
  jqe '.tooling_configured.policy_tests == true'
  jqe '.findings_by_tool | has("policy")'
  jqe '.findings_by_tool | has("policy_tests")'
}

@test "a clean, tested policy set yields no policy findings at all" {
  root_module
  policy
  policy_test
  stub_conftest 0 ""
  capture
  jqe '.findings_by_tool.policy == []'
  jqe '.findings_by_tool.policy_tests == []'
}

# --- policy_tests -------------------------------------------------------------

@test "a policy set with no conftest verify tests yields exactly one policy_tests finding (#1384)" {
  root_module
  policy
  stub_conftest
  capture
  jqe '(.findings_by_tool.policy_tests | length) == 1'
  run -0 jqr '.findings_by_tool.policy_tests[0].id'
  contains "$output" "policy_tests:untested-policies"
}

@test "a test_ rule beside the policy counts as coverage, without a _test.rego filename" {
  root_module
  policy
  printf 'package main\n\ntest_something if {\n  true\n}\n' > "$W/policies/conftest/inline.rego"
  stub_conftest
  capture
  jqe '.findings_by_tool.policy_tests == []'
}

# --- policy evaluation: a declared set that cannot be evaluated never skips ----

@test "conftest absent is a policy finding, not a silent skip and not an exit code" {
  root_module
  policy
  policy_test
  local nc
  nc="$(conftest_free_path)"
  run -0 env "PATH=$nc" "$(command -v zsh)" "$GATHER" "$W"
  PAYLOAD="$output"
  run -0 jqr '[.findings_by_tool.policy[].id] | join(",")'
  contains "$output" "policy:conftest-unavailable"
}

@test "a failing conftest verify is a policy finding" {
  root_module
  policy
  policy_test
  stub_conftest 1 "FAIL - deny_public_buckets_test.rego - test_denies_public_bucket"
  capture
  run -0 jqr '[.findings_by_tool.policy[].type] | join(",")'
  contains "$output" "policy_tests_failing"
}

@test "a Rego file that does not compile is reported as its own type, not as a failing test" {
  root_module
  policy
  policy_test
  stub_conftest 1 "rego_parse_error: unexpected eof token"
  capture
  run -0 jqr '[.findings_by_tool.policy[].type] | join(",")'
  contains "$output" "policy_does_not_compile"
  lacks "$output" "policy_tests_failing"
}

@test "a policy outside the invoked namespace is a finding — it passes everything silently" {
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package terraform.security\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/stray.rego"
  policy_test
  stub_conftest
  capture
  run -0 jqr '[.findings_by_tool.policy[].id] | join(",")'
  contains "$output" "policy:package-outside-invoked-namespace"
}

@test "a conftest.toml declaring namespaces suppresses the stray-namespace accusation" {
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package terraform.security\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/stray.rego"
  policy_test
  printf 'namespaces = ["terraform.security"]\n' > "$W/conftest.toml"
  stub_conftest
  capture
  run -0 jqr '[.findings_by_tool.policy[].id] | join(",")'
  lacks "$output" "policy:package-outside-invoked-namespace"
}

@test "a main.* subpackage is OUTSIDE the invoked namespace and IS accused" {
  # conftest's default namespace is the exact document `data.main` — its own
  # --trace output prints `query: data.main.deny` verbatim (docs/options.md) —
  # so `data.main.buckets.deny` is a different document that query never
  # reaches, and rules there pass everything silently. An earlier revision
  # exempted `main.*` AND recommended that shape in the finding's own fix text,
  # which is the green-over-unenforced state ARCHITECTURE.md forbids.
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package main.buckets\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/sub.rego"
  policy_test
  stub_conftest
  capture
  run -0 jqr '[.findings_by_tool.policy[].id] | join(",")'
  contains "$output" "policy:package-outside-invoked-namespace"
  # and the fix must not send the reader back into the shape just flagged
  run -0 jqr '[.findings_by_tool.policy[] | select(.id == "policy:package-outside-invoked-namespace") | .fix] | .[0]'
  lacks "$output" "(or a \`main.*\` subpackage)"
}

@test "package main itself is inside the invoked namespace and is not accused" {
  # the other side of the exact match: tightening to `^main([[:space:]]|$)`
  # must not start accusing the namespace conftest actually queries
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package main\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/ok.rego"
  policy_test
  stub_conftest
  capture
  run -0 jqr '[.findings_by_tool.policy[].id] | join(",")'
  lacks "$output" "policy:package-outside-invoked-namespace"
}

@test "a conftest whose version differs from the pin is a NOTE, never a finding" {
  root_module
  policy
  policy_test
  stub_conftest 0 "" "0.60.0"
  capture
  run -0 jqr '.notes | join(" ")'
  contains "$output" "but this gather pins"
  jqe '.findings_by_tool.policy == []'
}

@test "policy findings are absent entirely when no policies are declared, whatever conftest says" {
  root_module
  stub_conftest 1 "rego_parse_error: unexpected eof token"
  capture
  jqe '(.findings_by_tool | has("policy") | not)'
}

# --- the exit contract --------------------------------------------------------

@test "a nonexistent repo path exits 2 with a stderr diagnostic and no stdout (#1386)" {
  run -2 zsh "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  contains "$output" "not a directory"
}

@test "the exit-2 path writes nothing to stdout (#1386)" {
  run -0 bash -c "zsh '$GATHER' '$BATS_TEST_TMPDIR/does-not-exist' 2>/dev/null; true"
  [ -z "$output" ]
}

@test "a directory that exists but cannot be entered exits 2, not an all-false payload" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  local locked="$BATS_TEST_TMPDIR/locked"
  mkdir -p "$locked"
  chmod 000 "$locked"
  run -2 zsh "$GATHER" "$locked"
  chmod 755 "$locked"
  contains "$output" "not a readable directory"
}

@test "an unreadable policies/conftest exits 2 rather than reporting no policies declared" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  root_module
  policy
  chmod 000 "$W/policies/conftest"
  run -2 env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  chmod 755 "$W/policies/conftest"
  contains "$output" "policies/conftest exists but is not readable"
}

@test "a hit stands even when the search did not finish — only an EMPTY answer refuses" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  # the .tf tree is readable and non-empty; an unreadable SIBLING makes find
  # exit 1, which must not turn a detected repo into a refusal
  root_module
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  stub_conftest
  capture
  chmod 755 "$W/locked"
  jqe '.tooling_configured.format == true'
}

@test "the default repo path is the current directory, and does not become ./." {
  root_module
  stub_conftest
  run -0 env "PATH=$STUB:$PATH" bash -c "cd '$W' && zsh '$GATHER'"
  PAYLOAD="$output"
  jqe '.tooling_configured.format == true'
}

# --- the conftest invocation itself ------------------------------------------

@test "conftest is actually invoked, with --policy pointing at the declared set" {
  # without this, dropping `--policy` ships green here while the real tool
  # defaults to its own policy/ directory, finds nothing, exits 0, and reports a
  # repo's declared Rego clean — green over unenforced policies
  root_module
  policy
  policy_test
  stub_conftest
  capture
  run -0 cat "$BATS_TEST_TMPDIR/conftest.argv"
  contains "$output" 'verify --policy policies/conftest'
}

@test "conftest is NOT invoked when no policies are declared" {
  # the skip must be a real skip: an invocation here would mean the glob
  # contract is being decided by the tool rather than by the file match
  root_module
  stub_conftest
  capture
  [ ! -e "$BATS_TEST_TMPDIR/conftest.argv" ]
}

@test "conftest runs INSIDE the repo, so the repo's own conftest.toml is in effect" {
  # the namespace check reads $repo/conftest.toml while conftest resolves its
  # config from the CWD — keyed off different directories, the two halves of one
  # decision disagree, and a conftest.toml in the maintainer's CWD would be
  # applied to a foreign repo. A repo-relative --policy path is only correct if
  # the tool was cd'd into the repo, so asserting the relative path pins both.
  root_module
  policy
  policy_test
  stub_conftest
  capture
  run -0 cat "$BATS_TEST_TMPDIR/conftest.argv"
  contains "$output" '--policy policies/conftest'
  lacks "$output" "$W"
  # the ARGUMENT alone proves nothing about the working directory — deleting the
  # `cd` leaves it byte-identical. The recorded PWD is what actually pins it.
  # `pwd -P` on both sides, since $TMPDIR is a symlink on macOS.
  local want got
  want="$(cd "$W" && pwd -P)"
  got="$(cd "$(tail -1 "$BATS_TEST_TMPDIR/conftest.pwd")" && pwd -P)"
  [ "$got" = "$want" ]
}

@test "a compile error reported on STDERR is still classified (the 2>&1 capture)" {
  # real conftest writes compile errors to stderr; without the script's `2>&1`
  # verify_out would be empty here and the error would be misreported as a
  # failing test with an empty "conftest said:" tail
  root_module
  policy
  policy_test
  stub_conftest 1 "rego_parse_error: unexpected eof token" 0.69.0 err
  capture
  run -0 jqr '[.findings_by_tool.policy[].type] | join(",")'
  contains "$output" "policy_does_not_compile"
}

@test "a matching conftest version emits NO pin note" {
  # the mismatch test alone leaves an always-appending regression green, and it
  # would reach the Phase 9 summary on every clean run
  root_module
  policy
  policy_test
  stub_conftest
  capture
  run -0 jqr '.notes | join(" ")'
  lacks "$output" "but this gather pins"
}

@test "an unparseable conftest version emits no pin note and still evaluates" {
  root_module
  policy
  policy_test
  stub_conftest 0 "" "dev"
  capture
  run -0 jqr '.notes | join(" ")'
  lacks "$output" "but this gather pins"
  jqe '.findings_by_tool | has("policy")'
}

@test "two independent policy defects both surface, so the array aggregation works" {
  # pf can hold more than one entry; every other test produces at most one, so
  # the multi-element jq -s path is otherwise never taken
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package terraform.security\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/stray.rego"
  policy_test
  stub_conftest 1 "rego_parse_error: unexpected eof token"
  capture
  jqe '(.findings_by_tool.policy | length) == 2'
  run -0 jqr '[.findings_by_tool.policy[].id] | sort | join(",")'
  contains "$output" "policy:package-outside-invoked-namespace"
  contains "$output" "policy:policy_does_not_compile"
}

# --- the finding SHAPE, not just its id --------------------------------------

@test "the state_encryption finding carries its whole contract, not just an id" {
  # the dispatcher routes on the findings_by_tool key and the family's
  # severity_gate reads .severity; Phase 8 builds the work agent's prompt from
  # the whole object. Asserting only .id leaves all of that unpinned.
  root_module
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption[0].tool == "state_encryption"'
  jqe '.findings_by_tool.state_encryption[0].severity == "high"'
  jqe '.findings_by_tool.state_encryption[0].type == "unencrypted_state"'
  jqe '(.findings_by_tool.state_encryption[0].message | length) > 0'
  jqe '(.findings_by_tool.state_encryption[0].fix | length) > 0'
  jqe '.findings_by_tool.state_encryption[0].files | index("*.tf")'
}

@test "every emitted finding's tool matches its findings_by_tool key" {
  # a payload-wide invariant, so it covers all six emitters at once and cannot
  # go stale as findings are added — a renamed `tool` would silently stop
  # matching the key the dispatcher routes on
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package terraform.security\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/stray.rego"
  stub_conftest
  capture
  # ANCHOR first: both this invariant and its severity twin below are trivially
  # true of an empty findings set, so without a non-emptiness check a
  # co-regression that stopped emitting findings entirely would leave them
  # reporting ok while inspecting nothing.
  jqe '[.findings_by_tool[][]] | length == 3'
  jqe '[.findings_by_tool | to_entries[] | .key as $k | .value[] | select(.tool != $k)] | length == 0'
}

@test "every emitted finding carries a known severity" {
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package terraform.security\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/stray.rego"
  stub_conftest
  capture
  jqe '[.findings_by_tool[][]] | length == 3'
  jqe '[.findings_by_tool[][] | select((.severity | IN("high","medium","low")) | not)] | length == 0'
}

# --- the .tf.json blind spot --------------------------------------------------

@test "a mixed .tf/.tf.json tree emits a NOTE, never an unclearable finding" {
  # the classifier reads HCL only, so a repo whose backend and encryption live
  # in backend.tf.json would otherwise be handed a finding no edit to its .tf
  # files could clear — invariant (1), the unfixable direction
  printf 'provider "aws" {}\n' > "$W/main.tf"
  printf '{"terraform": {"backend": {"s3": {"encrypt": true}}}}\n' > "$W/backend.tf.json"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
  run -0 jqr '.notes | join(" ")'
  contains "$output" "it also ships .tf.json sources this check cannot parse"
}

@test "a .tf.json under a pruned tree does NOT suppress the finding" {
  # the carve-out must use the same prune set as everything else, or a cached
  # provider's own JSON silences a real defect
  root_module
  mkdir -p "$W/.terraform"
  printf '{"terraform": {}}\n' > "$W/.terraform/cached.tf.json"
  stub_conftest
  capture
  jqe '(.findings_by_tool.state_encryption | length) == 1'
}

# --- the type guard, as behaviour rather than as an oracle -------------------

@test "a DIRECTORY named main.tf does not make the gather see HCL" {
  # the parity oracle pins the `! -type d` guard TEXTUALLY across the three
  # copies (`type_guards_of` in tests/opentofu-topic-marker.bats); this pins its
  # BEHAVIOUR in the gather. The pair is deliberate, not a gap — without it the
  # gather could report format:true where
  # the orchestrator's marker rejects the same repo
  mkdir -p "$W/main.tf"
  stub_conftest
  capture
  jqe '.tooling_configured.format == false'
  jqe '.findings_by_tool | has("format") | not'
}

# --- the remaining exit-2 branches -------------------------------------------

@test "an unreadable SUBdirectory under policies/conftest exits 2, not 'no policies'" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  root_module
  policy
  mkdir -p "$W/policies/conftest/sub"
  chmod 000 "$W/policies/conftest/sub"
  run -2 env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  chmod 755 "$W/policies/conftest/sub"
  contains "$output" "could not list $W/policies/conftest (find exit"
}

@test "an unreadable .tf source is SKIPPED and cannot CLEAR the encryption check" {
  # the title used to promise exit 2, which is the opposite of what the body
  # asserts and of what the script does: the `[[ -f && -r ]]` filter skips the
  # file, so the encryption it might have declared cannot satisfy the check. The
  # script's `could not read the .tf sources` exit is defence-in-depth behind
  # that filter — the same "deliberately unreachable" shape as the 125 sentinel,
  # recorded here so the next reader does not add a branch to "fix" it.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  root_module
  printf 'terraform {\n  encryption {}\n}\n' > "$W/secret.tf"
  chmod 000 "$W/secret.tf"
  stub_conftest
  capture
  chmod 644 "$W/secret.tf"
  jqe '(.findings_by_tool.state_encryption | length) == 1'
}

# --- jq: the two documented failure classes ----------------------------------

@test "jq absent is exit 3, its own documented class (#1386)" {
  root_module
  local nojq
  nojq="$(jq_free_path)"
  run -3 env "PATH=$nojq" "$(command -v zsh)" "$GATHER" "$W"
  contains "$output" "jq not found on PATH"
}

@test "jq absent reports 3 even when the repo path is ALSO bad" {
  # the environment error the caller can fix must not be masked by an argument
  # error — the contract asks the reader to distinguish the two classes
  local nojq
  nojq="$(jq_free_path)"
  run -3 env "PATH=$nojq" "$(command -v zsh)" "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  contains "$output" "jq not found on PATH"
}

@test "a jq that is on PATH but FAILS is folded into exit 2, never jq's own status 5" {
  # jq's own status 5 must never escape the documented {0,2,3} set, or the
  # orchestrator records a code that means nothing to it
  root_module
  printf '#!/usr/bin/env bash\nexit 5\n' > "$STUB/jq"
  chmod +x "$STUB/jq"
  run -2 env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  rm -f "$STUB/jq"
}

# --- path handling ------------------------------------------------------------

@test "a relative repo path beginning with - is normalised, not read as a flag" {
  # `[[ -d ]]` parses no options so the gate passes, but `cd` and `find` both
  # read a leading dash as an option; the normalisation is what stops a legal
  # path being misread
  local dash="$BATS_TEST_TMPDIR/-infra"
  mkdir -p "$dash"
  printf 'provider "aws" {}\n' > "$dash/main.tf"
  run -0 env "PATH=$STUB:$PATH" bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$GATHER' -infra"
  PAYLOAD="$output"
  jqe '.tooling_configured.format == true'
}

@test "an absolute repo path is taken as given" {
  root_module
  run -0 env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  PAYLOAD="$output"
  jqe '.tooling_configured.format == true'
}

@test "a .tf whose name contains a space is read, not word-split" {
  # the gather splits hit lists in three places; a spaced filename exercises all
  # of them at once
  printf 'provider "aws" {\n  region = "eu-central-1"\n}\n' > "$W/main module.tf"
  stub_conftest
  capture
  jqe '.tooling_configured.format == true'
  jqe '(.findings_by_tool.state_encryption | length) == 1'
}

# --- the pipefail regression this round fixed --------------------------------
#
# `print … | grep -q` inverts under pipefail once the writer outruns the pipe
# buffer: grep exits at its first match, the writer dies of SIGPIPE, and the
# pipeline reports 141 — so a genuine match reads as FALSE. Reproducing it needs
# TWO properties at once, and getting either wrong makes the test pass against
# the broken form:
#   1. the concatenated text must exceed the pipe buffer (16 KiB on macOS,
#      64 KiB on Linux) — asserted below, so the fixture cannot silently shrink;
#   2. the match must occur EARLY in the stream, whichever file `cat` reads
#      first. `find` returns readdir order, which is neither creation order nor
#      sorted, so putting the discriminating line in one file only makes the
#      reproducer a coin flip per filesystem. Every filler file therefore starts
#      with the line under test.

# writes N filler modules whose FIRST line is "$1", so a match is guaranteed
# within the first bytes of the concatenated stream regardless of traversal
# order, while the bulk keeps the stream above the pipe buffer
big_tree() {
  local head_line="$1" i
  local filler
  filler="$(printf 'x%.0s' {1..400})"
  mkdir -p "$W/big"
  for i in $(seq 1 400); do
    printf '%s\nresource "null_resource" "r%s" {\n  triggers = {\n    a = "%s"\n  }\n}\n' \
      "$head_line" "$i" "$filler" > "$W/big/m$i.tf"
  done
}

# the fixture is only a reproducer above the pipe buffer — pin that, so a later
# trim cannot quietly turn these two tests green-by-construction
assert_above_pipe_buffer() {
  local bytes
  bytes="$(cat "$W"/big/*.tf | wc -c | tr -d ' ')"
  [ "$bytes" -gt 65536 ]
}

@test "a LARGE .tf tree still classifies correctly (the SIGPIPE inversion)" {
  root_module
  big_tree 'provider "aws" {}'
  assert_above_pipe_buffer
  stub_conftest
  capture
  # owns_state must still be TRUE (the provider block is found), so the
  # unencrypted root still yields its finding rather than the library note
  jqe '(.findings_by_tool.state_encryption | length) == 1'
  run -0 jqr '.notes | join(" ")'
  lacks "$output" "reusable module library"
}

@test "a LARGE encrypted tree is still cleared (the same inversion, other direction)" {
  encrypted_root_tofu
  # the encryption probe is the one under test here, so THAT is the line every
  # filler file leads with
  big_tree 'encryption {'
  assert_above_pipe_buffer
  stub_conftest
  capture
  # a POSITIVE anchor first: `length == 0` is equally true of the module-library
  # and UNRESOLVED branches, so without this the test passes when the OWNS-STATE
  # probe regresses — reporting nothing about the encryption check it is named
  # for. In this fixture only main.tf carries the provider block, and readdir
  # order can place it last, so that is the likely branch under a partial
  # regression.
  run -0 jqr '.notes | join(" ")'
  lacks "$output" "reusable module library"
  lacks "$output" "UNRESOLVED"
  jqe '.findings_by_tool.state_encryption == []'
}

# --- the refusal that protects every other verdict ---------------------------

@test "an EMPTY .tf result from an unfinished search exits 2, not an all-false payload" {
  # the script's most consequential refusal, and it had no test: 'a hit stands
  # even when the search did not finish' covers only the tolerant half. Delete
  # the refusal and a repo whose tree could not be searched is reported as having
  # no HCL at all — "could not look" rendered as "looked and found nothing".
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run -2 env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  chmod 755 "$W/locked"
  contains "$output" "the .tf search did not complete"
}

@test "that refusal writes nothing to stdout" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  run --separate-stderr env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  chmod 755 "$W/locked"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# --- the -L decision on the two policy finds ---------------------------------

@test "a SYMLINKED policy file still declares policies (the -L on the policy find)" {
  # without -L a symlink-shared policy set is reported UNDECLARED, i.e. the
  # charter's skip applied to a repo that emphatically did declare opinions
  root_module
  mkdir -p "$W/rules" "$W/policies/conftest"
  # NO policy_test() here: that helper writes a REAL .rego, which `find` matches
  # with or without -L — which made the first version of this test vacuous, and
  # was round 3's CRITICAL. The symlink must be the ONLY *.rego under
  # policies/conftest/ for the flag to be the thing under test.
  printf 'package main\n\ndeny contains msg if {\n  msg := "x"\n}\n' > "$W/rules/deny.rego"
  ln -s "$W/rules/deny.rego" "$W/policies/conftest/deny.rego"
  stub_conftest
  capture
  jqe '.tooling_configured.policy == true'
  jqe '.findings_by_tool | has("policy")'
}

@test "a SYMLINKED *_test.rego counts as coverage (the -L on the fixture find)" {
  # without -L this fabricates the high-severity untested-policies finding
  # against a repo whose tests are simply shared by symlink
  root_module
  policy
  mkdir -p "$W/rules"
  # the symlinked fixture's rules must NOT match the FALLBACK regex, or dropping
  # -L from the fixture find is rescued by the second convention (grep follows
  # symlinks) and this test proves nothing about the flag it names. `assert_`
  # rules are invisible to the `test_` fallback, so the *_test.rego FILENAME —
  # reachable only via -L — is the sole possible source of coverage here.
  printf 'package main\n\nassert_denies_public_bucket if {\n  true\n}\n' > "$W/rules/deny_test.rego"
  ln -s "$W/rules/deny_test.rego" "$W/policies/conftest/deny_test.rego"
  stub_conftest
  capture
  jqe '.findings_by_tool.policy_tests == []'
}

# --- the payload-emit half of exit-2 class (b) -------------------------------

@test "a jq failing at the PAYLOAD EMIT exits 2 with empty stdout and its own message" {
  # the earlier class-(b) test reaches the state_encryption encoder, not the
  # final emit — so the BUFFERED-then-printed guarantee (the whole reason the
  # payload is not streamed) was untested. This stub lets every earlier jq call
  # through and fails only the emit.
  root_module
  local realjq
  realjq="$(command -v jq)"
  cat > "$STUB/jq" <<EOF
#!/usr/bin/env bash
case "\$*" in *tooling_configured*) exit 5;; esac
exec "$realjq" "\$@"
EOF
  chmod +x "$STUB/jq"
  run --separate-stderr env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  rm -f "$STUB/jq"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "could not emit the payload"
}

@test "the earlier jq failure class names its own encoder and leaves stdout empty" {
  root_module
  printf '#!/usr/bin/env bash\nexit 5\n' > "$STUB/jq"
  chmod +x "$STUB/jq"
  run --separate-stderr env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  rm -f "$STUB/jq"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "could not encode the state_encryption finding"
}

# --- the unresolved-ownership branch -----------------------------------------

@test "an unreadable .tf makes the ownership question UNRESOLVED, not a module library" {
  # owns_state is false only over what could be READ. Asserting "owns no state"
  # from that clears a repo that may run on the implicit local backend — an
  # absence of evidence stated as a verified fact (invariant 2).
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  module_library
  printf 'provider "aws" {}\n' > "$W/secret.tf"
  chmod 000 "$W/secret.tf"
  stub_conftest
  capture
  chmod 644 "$W/secret.tf"
  run -0 jqr '.notes | join(" ")'
  contains "$output" "UNRESOLVED"
  lacks "$output" "this is a reusable module library"
}

@test "every .tf being unreadable refuses outright rather than classifying" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  printf 'provider "aws" {}\n' > "$W/main.tf"
  chmod 000 "$W/main.tf"
  run -2 env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  chmod 644 "$W/main.tf"
  contains "$output" "every .tf source under"
}

@test "an unreadable conftest.toml refuses rather than accusing the repo" {
  # [[ -f ]] passes for a file that cannot be read; a blanket `|| true` would
  # then let the stray-namespace check accuse a repo that DID declare its
  # namespaces
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package terraform.security\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/stray.rego"
  policy_test
  printf 'namespaces = ["terraform.security"]\n' > "$W/conftest.toml"
  # the stub is REQUIRED: the namespace scan lives in the conftest-present
  # branch, so without it the run takes the conftest-unavailable path and this
  # guard is never reached
  stub_conftest
  chmod 000 "$W/conftest.toml"
  run -2 env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  chmod 644 "$W/conftest.toml"
  contains "$output" "could not read $W/conftest.toml (grep exit"
}

@test "an unreadable .rego refuses rather than reporting the package set clean" {
  # xargs collapses grep's no-match and grep's read error to one status, which is
  # why the scan calls grep directly — this is the case that distinction buys
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  root_module
  policy
  policy_test
  stub_conftest
  chmod 000 "$W/policies/conftest/deny_public_buckets.rego"
  run -2 env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  chmod 644 "$W/policies/conftest/deny_public_buckets.rego"
  contains "$output" "could not scan the declared policies for their package"
}

# --- the branches round 3 found unpinned -------------------------------------

@test "an unreadable .rego reaches the TEST_-RULE scan's own refusal, not just the package one" {
  # the two guards share a message prefix, so a `contains "could not scan the
  # declared policies"` needle cannot tell them apart — and this one, whose
  # comment calls it the costliest, had no test at all. A conftest.toml naming
  # the namespace skips the package scan, leaving the test_-rule scan as the
  # only one that can fire.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package main\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/x.rego"
  printf 'namespaces = ["main"]\n' > "$W/conftest.toml"
  stub_conftest
  chmod 000 "$W/policies/conftest/x.rego"
  run -2 env "PATH=$STUB:$PATH" zsh "$GATHER" "$W"
  chmod 644 "$W/policies/conftest/x.rego"
  contains "$output" "could not scan the declared policies for test_ rules"
}

@test "a conftest that cannot be EXECUTED is a policy finding, never a whole-topic exit" {
  # exit 127 is a toolchain problem, and the header rule is that a conftest
  # problem is never an exit code — exiting would discard the other six tool
  # keys and the state_encryption verdict over one unexecutable binary. It must
  # also not render as policy_tests_failing, which would blame the repo's Rego.
  root_module
  policy
  policy_test
  printf '#!/nonexistent/bin/sh\n' > "$STUB/conftest"
  chmod +x "$STUB/conftest"
  capture
  run -0 jqr '[.findings_by_tool.policy[].id] | join(",")'
  contains "$output" "policy:conftest-unavailable"
  run -0 jqr '[.findings_by_tool.policy[].type] | join(",")'
  lacks "$output" "policy_tests_failing"
  # the ACTUAL code, not the literal "126/127": a dead shim (127) and a noexec
  # mount or wrong-architecture build (126) need different repairs, and the
  # reader cannot tell them apart from a message that reports both
  run -0 jqr '[.findings_by_tool.policy[] | select(.id == "policy:conftest-unavailable") | .message] | .[0]'
  contains "$output" "exit 127"
  lacks "$output" "exit 126/127"
  # and the fix must not name a cause this arm cannot reach: PATH lookup tests
  # X_OK through a symlink, so `command -v` never returns a dangling one, and
  # the -x gate would route it to the not-on-PATH branch regardless
  run -0 jqr '[.findings_by_tool.policy[] | select(.id == "policy:conftest-unavailable") | .fix] | .[0]'
  lacks "$output" "a dangling symlink"
}

@test "an incomplete .tf.json search suppresses the finding AND says so accurately" {
  # a locked sibling makes the .tf.json walk exit non-zero with no hits. The
  # finding is suppressed (invariant 1 is the unfixable direction), but the note
  # must name the REAL cause — an unfinished search — rather than claiming the
  # repo ships .tf.json files it does not ship. Phase 9 renders this verbatim.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  root_module
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  stub_conftest
  capture
  chmod 755 "$W/locked"
  jqe '.findings_by_tool.state_encryption == []'
  run -0 jqr '.notes | join(" ")'
  contains "$output" "the .tf.json search could not complete"
  lacks "$output" "it also ships .tf.json sources"
}

@test "an unreadable directory inside a PRUNED tree does not suppress the finding" {
  # the .tf.json probe prunes inside the walk, so a permission error in a tree
  # the marker ignores by design must not read as "cannot rule out" — otherwise
  # any repo with a locked .terraform/ cache silently loses the plugin's one
  # built-in check
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  root_module
  mkdir -p "$W/.terraform/locked"
  chmod 000 "$W/.terraform/locked"
  stub_conftest
  capture
  chmod 755 "$W/.terraform/locked"
  jqe '(.findings_by_tool.state_encryption | length) == 1'
}

@test "a .tf with no trailing newline does not swallow the next file's first line" {
  # `cat` concatenates byte-for-byte, so an unterminated file glues its last
  # line onto the next file's first — and every classifier probe is ^-anchored,
  # so that first line becomes invisible and the root reads as a module library.
  #
  # ORDER IS AN INPUT HERE, NOT A HOPE. `tf_hits` is find's readdir order, which
  # is neither creation order nor sorted — the same hazard `big_tree` documents.
  # Writing the unterminated file as "a.tf" and hoping it is read first makes
  # the reproducer a coin flip per filesystem, so the two files are created
  # empty, the ACTUAL order is read back, and the roles are assigned from it.
  : > "$W/one.tf"
  : > "$W/two.tf"
  local first last
  first="$(cd "$W" && find . -name '*.tf' ! -type d | head -1)"
  last="$(cd "$W" && find . -name '*.tf' ! -type d | tail -1)"
  [ "$first" != "$last" ]
  # the UNTERMINATED file goes first; the provider block is the first line of
  # whichever file find reads last, so only the repair can keep it visible
  printf 'variable "x" {\n  type = string\n}' > "$W/${first#./}"
  printf 'provider "aws" {\n  region = "eu-central-1"\n}\n' > "$W/${last#./}"
  stub_conftest
  capture
  jqe '(.findings_by_tool.state_encryption | length) == 1'
  run -0 jqr '.notes | join(" ")'
  lacks "$output" "reusable module library"
}

@test "a Rego v1 'test_x if { … }' rule counts as coverage (no \\b in the regex)" {
  # `\b` is a GNU extension: a stock BSD grep treats it as a literal `b`, so an
  # `if\b` alternative would match only `…ifb` and a v1-syntax policy set whose
  # tests live beside the policies would FABRICATE the untested-policies
  # finding. This repo is macOS-only, so that is the likely host.
  root_module
  policy
  printf 'package main\n\ntest_denies_it if {\n  true\n}\n' \
    > "$W/policies/conftest/inline_v1.rego"
  stub_conftest
  capture
  jqe '.findings_by_tool.policy_tests == []'
}

@test "a Rego v0 'test_y { … }' rule counts as coverage too" {
  root_module
  policy
  printf 'package main\n\ntest_denies_it {\n  true\n}\n' \
    > "$W/policies/conftest/inline_v0.rego"
  stub_conftest
  capture
  jqe '.findings_by_tool.policy_tests == []'
}

@test "an assert_-prefixed rule is NOT coverage — the regex still discriminates" {
  # the negative control for the two above: without it a regex widened to match
  # any rule at all would pass both and the convention would stop meaning
  # anything
  root_module
  policy
  printf 'package main\n\nassert_denies_it if {\n  true\n}\n' \
    > "$W/policies/conftest/inline_assert.rego"
  stub_conftest
  capture
  jqe '(.findings_by_tool.policy_tests | length) == 1'
}

@test "both prune forms are DERIVED from one declaration, so no copy can drift" {
  # The `.tf.json` probe must prune during its walk (its status suppresses a
  # finding, so it has to describe only the searched region), while the `.tf`
  # search filters a captured list. Two syntaxes, one source: `PRUNE_NAMES`.
  # Deriving both is what removes the second copy — the probe's expression sits
  # outside the `gather-opentofu-marker` sentinels, where the 3-way oracle in
  # tests/opentofu-topic-marker.bats cannot see it, so a literal restatement
  # there could drift silently.
  local names
  names="$(sed -n '/^local -a PRUNE_NAMES=(/,/^)/p' "$GATHER" | sed '1d;$d' \
    | tr -s '[:space:]' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$names" = ".git .terraform node_modules vendor " ]
  # and both consumers are built from it, never restated
  run -0 grep -c 'PRUNE+=(-e "/${_pn}/")' "$GATHER"
  [ "$output" = "1" ]
  run -0 grep -c 'PRUNE_FIND+=(-name "\$_pn")' "$GATHER"
  [ "$output" = "1" ]
  # the probe uses the derived array rather than literal -name primaries
  run -0 grep -c 'find \. \\( "\${PRUNE_FIND\[@\]}" \\) -prune' "$GATHER"
  [ "$output" = "1" ]
}



# --- findings_by_tool's key set, by EQUALITY --------------------------------

@test "findings_by_tool carries exactly the five presence keys when no policies are declared" {
  # `tooling_configured` is pinned by equality; this object — the one the
  # dispatcher actually ROUTES on — was pinned only by has()/length, which any
  # superset satisfies. Per the dispatcher's own contract an unknown key here
  # "halts on its mere presence, empty array or not", so a spurious key added to
  # the jq object would halt EVERY dispatch of this topic with the suite green.
  root_module
  stub_conftest
  capture
  jqe '(.findings_by_tool | keys | sort) ==
       ["format","lint","misconfiguration","state_encryption","validate"]'
}

@test "findings_by_tool carries exactly the seven keys when policies ARE declared" {
  root_module
  policy
  policy_test
  stub_conftest
  capture
  jqe '(.findings_by_tool | keys | sort) ==
       ["format","lint","misconfiguration","policy","policy_tests","state_encryption","validate"]'
}

@test "findings_by_tool is EMPTY on a pruned-only repo" {
  mkdir -p "$W/.terraform"
  printf 'provider "aws" {}\n' > "$W/.terraform/cached.tf"
  stub_conftest
  capture
  jqe '(.findings_by_tool | keys) == []'
  # the note is documented as ALWAYS carried, and this is the branch where a
  # plausible edit would lose it — moving the `notes+=` inside the `-n $tf_hits`
  # block, since the sentence is about the four HCL-keyed tools. A no-HCL
  # payload arriving with only the policy-skip note is exactly the "this topic
  # is clean" misreading the note exists to contradict.
  run -0 jqr '.notes | join(" ")'
  contains "$output" "format/validate/lint/misconfiguration: presence-detected only"
  contains "$output" "state_encryption, policy and policy_tests are EVALUATED in this gather"
}

# --- the conftest resolution decision, which has a security consequence -------

@test "conftest is resolved ABSOLUTELY, so the repo under test cannot supply the binary" {
  # `command -v` prints the path AS FOUND VIA PATH, so a relative PATH entry
  # yields a relative path — which, re-resolved inside the `cd -- "$repo"`
  # subshell, would execute a `bin/conftest` belonging to the REPO UNDER TEST:
  # arbitrary code from a third-party checkout, run during a read-only gather.
  # `${conftest_bin:A}` is what prevents it, and nothing else in the suite pins
  # that — deleting it reads like removing a redundant absolutisation.
  root_module
  policy
  policy_test
  local outer="$BATS_TEST_TMPDIR/outer/bin"
  mkdir -p "$outer" "$W/bin"
  # the LEGITIMATE conftest, on the caller's PATH
  # ABSOLUTE shebangs, and `: >` rather than `touch`: the synthetic PATH
  # carries neither `env` nor `touch`, so a `#!/usr/bin/env bash` stub would not
  # run at all and a `touch` marker would silently fail inside one that did
  printf '#!%s\n: > "%s/outer.ran"\nif [ "$1" = "--version" ]; then printf "Conftest: v0.69.0\\nOPA: v1.4.2\\n"; fi\nexit 0\n' \
    "$(command -v bash)" "$BATS_TEST_TMPDIR" > "$outer/conftest"
  chmod +x "$outer/conftest"
  # the HOSTILE one, shipped by the repo under test at the same relative path
  printf '#!%s\n: > "%s/hostile.ran"\nexit 0\n' \
    "$(command -v bash)" "$BATS_TEST_TMPDIR" > "$W/bin/conftest"
  chmod +x "$W/bin/conftest"
  local nc
  nc="$(conftest_free_path)"
  # PATH carries the RELATIVE entry `bin` first — the direnv/nvm shape the
  # script's comment names — resolved from the caller's directory
  # absolute interpreters: the synthetic PATH deliberately carries only the
  # tools the gather itself needs, so `bash`/`zsh` must be named outright
  run -0 env "PATH=bin:$nc" "$(command -v bash)" -c \
    "cd '$BATS_TEST_TMPDIR/outer' && '$(command -v zsh)' '$GATHER' '$W'"
  [ -f "$BATS_TEST_TMPDIR/outer.ran" ]
  [ ! -f "$BATS_TEST_TMPDIR/hostile.ran" ]
}

@test "a mode-644 file named conftest is not a command at all, so the finding stands" {
  # NOT a test of the script's `-x` guard, and the title says so deliberately.
  # `command -v` resolves through access(X_OK), so a non-executable file on PATH
  # is never returned: `conftest_bin` is empty and this takes the same branch as
  # "conftest absent". The `-x` guard is UNREACHABLE defence-in-depth (for a
  # binary that loses its bit between the probe and the run), recorded here the
  # way the script records its 125 sentinel — rather than left as a test whose
  # title claims coverage its body cannot deliver.
  root_module
  policy
  policy_test
  local nc
  nc="$(conftest_free_path)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$nc/conftest"
  chmod 644 "$nc/conftest"
  run -0 env "PATH=$nc" "$(command -v zsh)" "$GATHER" "$W"
  PAYLOAD="$output"
  run -0 jqr '[.findings_by_tool.policy[].id] | join(",")'
  contains "$output" "policy:conftest-unavailable"
}

# --- the UNRESOLVED note's cause, pinned like the suppression note's ---------

@test "the UNRESOLVED note names the unreadable .tf and NOT .tf.json when only the former holds" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  module_library
  printf 'provider "aws" {}\n' > "$W/secret.tf"
  chmod 000 "$W/secret.tf"
  stub_conftest
  capture
  chmod 644 "$W/secret.tf"
  run -0 jqr '.notes | join(" ")'
  contains "$output" ".tf file(s) it could not read"
  lacks "$output" ".tf.json sources it cannot parse"
  lacks "$output" "a .tf.json search that could not complete"
}

@test "the UNRESOLVED note JOINS both causes when both hold" {
  # the ${(j:, and :)why} path is otherwise never exercised — every other
  # fixture trips exactly one condition
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  module_library
  printf 'provider "aws" {}\n' > "$W/secret.tf"
  chmod 000 "$W/secret.tf"
  printf '{"terraform": {}}\n' > "$W/backend.tf.json"
  stub_conftest
  capture
  chmod 644 "$W/secret.tf"
  run -0 jqr '.notes | join(" ")'
  contains "$output" ".tf file(s) it could not read"
  contains "$output" ".tf.json sources it cannot parse"
  contains "$output" ", and "
}

# --- the finding emitted over a partial read says so -------------------------

@test "a finding reached over an unreadable .tf carries the partial-read caveat" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  root_module
  printf 'terraform {\n  encryption {}\n}\n' > "$W/secret.tf"
  chmod 000 "$W/secret.tf"
  stub_conftest
  capture
  chmod 644 "$W/secret.tf"
  jqe '(.findings_by_tool.state_encryption | length) == 1'
  run -0 jqr '.notes | join(" ")'
  contains "$output" "this finding was reached over"
  contains "$output" "fix the permissions and re-run before acting on it"
}

@test "a directory named _terraform is NOT pruned — the prune tokens are literal" {
  # The derived operands are plain path fragments, so as a REGEX the `.` in
  # `/.terraform/` is a wildcard and would prune `_terraform/`, `1terraform/`,
  # `agit/` — strictly MORE than the marker, whose copies spell the same tokens
  # `'/\.terraform/'`. A repo whose only HCL lived under such a directory would
  # fire the topic marker and be answered all-false here: exactly the divergence
  # the 3-way parity claim exists to prevent.
  #
  # The parity ORACLE cannot catch this — it strips backslashes before comparing
  # names, so escaped and unescaped forms normalise identically. This is the
  # behavioural test that can.
  mkdir -p "$W/_terraform"
  printf 'provider "aws" {\n  region = "eu-central-1"\n}\n' > "$W/_terraform/main.tf"
  stub_conftest
  capture
  jqe '.tooling_configured.format == true'
  jqe '(.findings_by_tool.state_encryption | length) == 1'
}

@test "a directory named agit is NOT pruned either (the .git token, same hazard)" {
  mkdir -p "$W/agit"
  printf 'provider "aws" {\n  region = "eu-central-1"\n}\n' > "$W/agit/main.tf"
  stub_conftest
  capture
  jqe '.tooling_configured.format == true'
}

@test "the REAL .terraform and .git trees are still pruned" {
  # the negative control for the two above: making the tokens literal must not
  # stop them pruning what they are for
  mkdir -p "$W/.terraform" "$W/.git"
  printf 'provider "aws" {}\n' > "$W/.terraform/cached.tf"
  printf 'provider "aws" {}\n' > "$W/.git/hook.tf"
  stub_conftest
  capture
  jqe '.tooling_configured.format == false'
}

# --- the evidence each policy finding QUOTES, which is branch-selected -------

@test "a compile error's evidence survives >20 matching lines and leads with the error" {
  # TWO regressions in one fixture. (1) The evidence line must not pipe grep
  # into `head`: `head` closes the pipe on its 20th line, grep takes SIGPIPE,
  # and `pipefail` makes 141 the assignment's status, which errexit turns into
  # an exit this script's header does not document — no payload at all.
  # Reproduced at 5000 matching lines; 31 here is already past `head`'s cutoff.
  # (2) A compile error is reported near the TOP of verify's output, so
  # swapping the branch for an unconditional `tail -20` would quote 20 lines of
  # filler and omit the very error the reader is asked to fix. Every other
  # conftest fixture stubs a SINGLE line, which cannot tell those apart.
  root_module
  policy
  policy_test
  local out
  # the filler must EXCEED THE PIPE BUFFER (64KiB), not merely pass head's
  # 20-line cutoff: with a small output grep writes everything and exits before
  # head closes the pipe, so no SIGPIPE ever fires and the piped form passes.
  # Verified — at 30 filler lines this test stayed green against the defect.
  out="$(printf 'rego_parse_error: unexpected eof token\n'; printf 'parse error: filler %d\n' {1..5000})"
  [ "${#out}" -gt 65536 ]
  stub_conftest 1 "$out"
  capture
  run -0 jqr '[.findings_by_tool.policy[] | select(.type == "policy_does_not_compile") | .message] | .[0]'
  contains "$output" "conftest said:"
  contains "$output" "rego_parse_error: unexpected eof token"
  lacks "$output" "parse error: filler 30"
}

@test "a failing test run's evidence is the TAIL, so the summary survives the noise" {
  # the mirror of the branch above: the failing-test summary IS at the bottom,
  # which is why that arm keeps `tail` rather than grepping
  root_module
  policy
  policy_test
  local out
  out="$(printf 'noise line %d\n' {1..25}; printf 'FAIL - 3 tests, 1 failure\n')"
  stub_conftest 1 "$out"
  capture
  run -0 jqr '[.findings_by_tool.policy[] | select(.type == "policy_tests_failing") | .message] | .[0]'
  contains "$output" "conftest said:"
  contains "$output" "FAIL - 3 tests, 1 failure"
  lacks "$output" "noise line 6"
}

# --- the remaining causes of the two multi-cause notes ------------------------

@test "the suppression note names the unreadable .tf ALONGSIDE the .tf.json cause" {
  # the branch has THREE causes and only two were pinned. Deleting the
  # tf_skipped element kept the whole suite green while a high-severity check
  # reported a bounded, inspectable blind spot for a tree it could not fully
  # read — sending the reader to inspect the JSON while the permission problem
  # goes unfixed and the check stays blind on re-run.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  root_module
  printf '{"terraform": {}}\n' > "$W/backend.tf.json"
  printf 'provider "aws" {}\n' > "$W/secret.tf"
  chmod 000 "$W/secret.tf"
  stub_conftest
  capture
  chmod 644 "$W/secret.tf"
  jqe '.findings_by_tool.state_encryption == []'
  run -0 jqr '.notes | join(" ")'
  contains "$output" "it also ships .tf.json sources this check cannot parse"
  contains "$output" ".tf file(s) it could not read"
  contains "$output" ", and "
}

@test "the UNRESOLVED note names an INCOMPLETE .tf.json search as its cause" {
  # the third cause of the UNRESOLVED note was asserted only negatively — one
  # test checked it was absent and none ever produced it. Deleting the element
  # left every test green while a repo whose ownership question is unresolved
  # BECAUSE the JSON walk aborted got an empty `why` list, rendering a
  # cause-less accusation Phase 9 shows verbatim.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  module_library
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  stub_conftest
  capture
  chmod 755 "$W/locked"
  run -0 jqr '.notes | join(" ")'
  contains "$output" "a .tf.json search that could not complete"
  contains "$output" "UNRESOLVED"
  lacks "$output" ".tf file(s) it could not read"
}

# --- a filter that DID NOT COMPLETE must never read as "found nothing" -------

@test "a prune filter that fails REFUSES rather than emitting an all-false payload" {
  # `|| true` absorbs a status without inspecting it, so grep's operational
  # error (exit 2) and a missing grep (127) were absorbed exactly like the
  # intended no-match 1 — tf_hits went empty with tf_rc still 0, the
  # search-did-not-complete refusal did not fire, and a repo full of HCL was
  # answered all-false with exit 0. The prune filter is the FIRST grep the
  # script runs, so a blanket failing stub lands on it.
  root_module
  printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/grep"
  chmod +x "$STUB/grep"
  run env "PATH=$STUB:$PATH" "$(command -v zsh)" "$GATHER" "$W"
  [ "$status" -eq 2 ]
  contains "$output" "prune filter did not complete"
}

@test "the stray-namespace filter REFUSES on a failing awk, rather than reporting no strays" {
  # zsh's pipefail reports the RIGHTMOST non-zero status, so in the old
  # sed|grep|grep|sort form a FAILING sed was masked by the downstream grep's
  # no-match 1 — which the guard accepted — and a policy set living entirely
  # outside `main` was reported with an empty findings array. The single awk
  # stage removes the shadowing status, so the guard can be strict. The stub
  # fails ONLY the filter program (matched by its `sub(` text) and delegates
  # every other awk call, so the source read above still works and this test
  # cannot pass for the wrong reason.
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package terraform.security\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/stray.rego"
  policy_test
  stub_conftest
  local real_awk
  real_awk="$(command -v awk)"
  printf '#!/usr/bin/env bash\ncase "$*" in *"sub("*) exit 2 ;; esac\nexec %s "$@"\n' \
    "$real_awk" > "$STUB/awk"
  chmod +x "$STUB/awk"
  run env "PATH=$STUB:$PATH" "$(command -v zsh)" "$GATHER" "$W"
  [ "$status" -eq 2 ]
  contains "$output" "could not filter the declared policies' packages"
}

# --- the OWNS-STATE probe's `backend` alternative ----------------------------

@test "a backend block with NO provider anywhere still OWNS state (invariant 2)" {
  # every other fixture that reaches the owns-state probe declares a `provider`,
  # so the `backend` half of `^[[:space:]]*(provider|backend)[[:space:]]+"` was
  # dead weight: delete it and the whole suite stayed green while a root driving
  # only null/random/tls resources — real, and common for bootstrap state — was
  # classified a reusable module library and its plaintext state never flagged.
  printf 'terraform {\n  backend "s3" {\n    bucket = "state"\n  }\n}\n\nresource "null_resource" "r" {}\n' \
    > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption | length == 1'
  jqe '.findings_by_tool.state_encryption[0].type == "unencrypted_state"'
  run -0 jqr '.notes | join(" ")'
  lacks "$output" "reusable module library"
}

@test "a backend-only root that IS encrypted clears the check" {
  # the same alternative pinned in the other direction, so a regex widened to
  # match anything cannot satisfy both this and the test above
  printf 'terraform {\n  backend "s3" {\n    bucket  = "state"\n    encrypt = true\n  }\n}\n\nresource "null_resource" "r" {}\n' \
    > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

# --- each accepted encryption spelling, one fixture per form -----------------
# The five were previously reachable only through ONE fixture carrying two of
# them together, so three spellings were produced by no test at all. Dropping
# `encryption_key` would make every GCS repo whose state IS encrypted receive
# the finding — whose own fix text names `encryption_key` as the remedy, so the
# user configures exactly the form the check no longer recognises and the
# accusation never clears. That is invariant (1) in its most visible shape.

@test "S3 encrypt = true alone clears the check" {
  printf 'provider "aws" {}\n\nterraform {\n  backend "s3" {\n    encrypt = true\n  }\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

@test "S3 kms_key_id alone clears the check" {
  printf 'provider "aws" {}\n\nterraform {\n  backend "s3" {\n    kms_key_id = "arn:aws:kms:eu-central-1:1:key/x"\n  }\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

@test "S3 sse_customer_key alone clears the check" {
  printf 'provider "aws" {}\n\nterraform {\n  backend "s3" {\n    sse_customer_key = "abc123"\n  }\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

@test "GCS encryption_key alone clears the check" {
  printf 'provider "google" {}\n\nterraform {\n  backend "gcs" {\n    encryption_key = "abc123"\n  }\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

@test "GCS kms_encryption_key alone clears the check" {
  printf 'provider "google" {}\n\nterraform {\n  backend "gcs" {\n    kms_encryption_key = "projects/p/locations/l/keyRings/r/cryptoKeys/k"\n  }\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

@test "a backend carrying NONE of the five accepted forms is still flagged" {
  # the negative control: without it, a regex widened to match any assignment
  # would satisfy all five tests above
  printf 'provider "aws" {}\n\nterraform {\n  backend "local" {\n    path = "terraform.tfstate"\n  }\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption | length == 1'
}

# --- the compile-vs-failing-test classifier's other keywords -----------------

@test "rego_compile_error is a COMPILE failure, not a failing test run" {
  # the classifier keys on four alternatives and every fixture drove the first.
  # Dropping `rego_compile_error` — OPA's code for a redeclared rule, the most
  # common non-parse compile break — would report a set that cannot be evaluated
  # AT ALL as `policy_tests_failing`, blaming the repo's fixtures and telling
  # the reader to "fix the failing tests", the two states ARCHITECTURE.md
  # requires to stay separate.
  root_module
  policy
  policy_test
  stub_conftest 1 "rego_compile_error: rule named deny redeclared"
  capture
  run -0 jqr '[.findings_by_tool.policy[].type] | join(",")'
  contains "$output" "policy_does_not_compile"
  lacks "$output" "policy_tests_failing"
}

@test "a bare 'compile error' is a COMPILE failure too" {
  root_module
  policy
  policy_test
  stub_conftest 1 "1 error occurred: policy.rego:3: compile error: var msg is unsafe"
  capture
  run -0 jqr '[.findings_by_tool.policy[].type] | join(",")'
  contains "$output" "policy_does_not_compile"
  lacks "$output" "policy_tests_failing"
}

@test "a bare 'parse error' — without the rego_ prefix — is a COMPILE failure too" {
  # this alternative was only ever matched as a SUBSTRING of rego_parse_error,
  # so it could be deleted with the suite green
  root_module
  policy
  policy_test
  stub_conftest 1 "policy.rego:2: parse error: unexpected assign token"
  capture
  run -0 jqr '[.findings_by_tool.policy[].type] | join(",")'
  contains "$output" "policy_does_not_compile"
  lacks "$output" "policy_tests_failing"
}

@test "the stray-namespace finding NAMES the offending packages" {
  # the id was pinned three times and the message — whose entire actionable
  # content is the interpolated package list — nowhere, so a regression that
  # emptied $pkgs would ship "…they pass everything silently: ." and Phase 8
  # would build the work agent's prompt from that
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package terraform.security\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/stray.rego"
  policy_test
  stub_conftest
  capture
  run -0 jqr '[.findings_by_tool.policy[] | select(.id == "policy:package-outside-invoked-namespace") | .message] | .[0]'
  contains "$output" "terraform.security"
  lacks "$output" "silently: ."
}

# --- the THIRD source of blindness: a .tf search that did not finish ---------

@test "an INCOMPLETE .tf search leaves the ownership question UNRESOLVED" {
  # with hits present but the walk unfinished, files never enumerated are
  # indistinguishable from files that do not exist — so a tree whose only
  # provider block sat in the un-enumerated region would be called "a reusable
  # module library, which owns no state" from absence of evidence, inverting
  # invariant (2). The .tf.json probe walks the same tree and so trips too;
  # asserting BOTH causes is what pins the .tf one's presence, since dropping it
  # would leave only the JSON cause and send the reader at the wrong search.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  module_library
  mkdir -p "$W/locked"
  chmod 000 "$W/locked"
  stub_conftest
  capture
  chmod 755 "$W/locked"
  run -0 jqr '.notes | join(" ")'
  contains "$output" "a .tf search that could not complete"
  contains "$output" "UNRESOLVED"
  lacks "$output" "reusable module library"
}

# --- the `-f` half of the source-read filter (the anti-hang guard) -----------

@test "a FIFO named like a module is SKIPPED, not read — and the payload says so" {
  # the marker deliberately uses `! -type d` so a symlinked module counts, but
  # the READ must test `-f`: relaxing it to `-e` (a plausible simplification,
  # since `-e` reads as "exists") makes the concatenation block FOREVER on a
  # FIFO. Only the `-r` half was ever exercised, so that regression shipped
  # green — and under it this test hangs rather than silently passing, which is
  # the intended signal.
  root_module
  mkfifo "$W/hang.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption | length == 1'
  run -0 jqr '.notes | join(" ")'
  contains "$output" ".tf file(s) the check could not read"
}

@test "a SYMLINKED real .tf IS read — the -f follow semantics the marker relies on" {
  # the other direction: `-f` follows symlinks, so a module reached through one
  # must still be classified. Tightening the read to `! -h` or `-type f` on the
  # link itself would silently stop reading it.
  printf 'provider "aws" {}\n' > "$W/real.tf"
  mkdir -p "$W/mod"
  printf 'terraform {\n  encryption {\n    key_provider "pbkdf2" "k" {}\n  }\n}\n' \
    > "$BATS_TEST_TMPDIR/enc.tf"
  ln -s "$BATS_TEST_TMPDIR/enc.tf" "$W/mod/enc.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
}

# --- the remaining accepted `test_` rule shapes ------------------------------

@test "a Rego 'test_x := true if { … }' complete rule counts as coverage" {
  # the `:?=` alternative was produced by no fixture, so it could be deleted
  # with the suite green — and a repo whose fixtures use that shape would then
  # FABRICATE the untested-policies finding, a false accusation rather than a
  # missed one
  root_module
  policy
  mkdir -p "$W/policies/conftest"
  printf 'package main\n\ntest_denies_it := true if {\n  count(deny) == 1\n}\n' \
    > "$W/policies/conftest/x_test.rego"
  stub_conftest
  capture
  jqe '.findings_by_tool.policy_tests == []'
}

@test "a Rego v0 'test_x = true { … }' complete rule counts as coverage too" {
  root_module
  policy
  mkdir -p "$W/policies/conftest"
  printf 'package main\n\ntest_denies_it = true {\n  count(deny) == 1\n}\n' \
    > "$W/policies/conftest/x_test.rego"
  stub_conftest
  capture
  jqe '.findings_by_tool.policy_tests == []'
}

@test "the default repo path renders as '.' in diagnostics, never './.'" {
  # the sibling test proves the default `.` WORKS; it cannot prove the
  # normalisation, because `./.` is a perfectly good path for cd and find. The
  # exit-2 refusal is the one message that interpolates $repo, so it is the only
  # place the doubled prefix is observable.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses file permissions"; fi
  printf 'provider "aws" {}\n' > "$W/main.tf"
  chmod 000 "$W/main.tf"
  run env "PATH=$STUB:$PATH" bash -c "cd '$W' && '$(command -v zsh)' '$GATHER'"
  chmod 644 "$W/main.tf"
  [ "$status" -eq 2 ]
  contains "$output" "under . "
  lacks "$output" "under ./."
}

# --- the branches round 8 and 9 ADDED, each pinned to its own cause ----------

@test "a here-string probe that FAILS refuses, rather than fabricating a verdict" {
  # `if grep -q …; then` cannot tell "searched, no provider block" (1) from "the
  # search did not run" (>=2): both render FALSE, and FALSE here clears a repo
  # holding plaintext state as a reusable module library — invariant (2)
  # inverted, exit 0, no message. The probe helper inspects the status instead.
  # The stub fails ONLY the owns-state pattern and delegates every other grep,
  # so this cannot pass because some unrelated grep broke.
  root_module
  local real
  real="$(command -v grep)"
  printf '#!/usr/bin/env bash\ncase "$*" in *"provider|backend"*) exit 2 ;; esac\nexec %s "$@"\n' \
    "$real" > "$STUB/grep"
  chmod +x "$STUB/grep"
  run env "PATH=$STUB:$PATH" "$(command -v zsh)" "$GATHER" "$W"
  [ "$status" -eq 2 ]
  contains "$output" "could not scan the .tf sources for a root-module provider or backend block"
  lacks "$output" "reusable module library"
}

@test "an encryption probe that FAILS refuses, rather than accusing an encrypted repo" {
  # the other direction: a fabricated FALSE here emits a high-severity
  # unencrypted-state finding against a repo whose state IS encrypted, and if
  # the cause is environmental no edit to the HCL clears it (invariant 1)
  root_module
  local real
  real="$(command -v grep)"
  printf '#!/usr/bin/env bash\ncase "$*" in *"encrypt"*) exit 2 ;; esac\nexec %s "$@"\n' \
    "$real" > "$STUB/grep"
  chmod +x "$STUB/grep"
  run env "PATH=$STUB:$PATH" "$(command -v zsh)" "$GATHER" "$W"
  [ "$status" -eq 2 ]
  contains "$output" "could not scan the .tf sources for"
}

@test "an emitted finding DISCLOSES a .tf search that did not complete" {
  # the caveat added alongside tf_search_incomplete. Its needle must be unique
  # to this note — "this finding was reached over" is shared with the
  # unreadable-file caveat, so it cannot discriminate.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  root_module
  mkdir -p "$W/.terraform/locked"
  chmod 000 "$W/.terraform/locked"
  stub_conftest
  capture
  chmod 755 "$W/.terraform/locked"
  jqe '.findings_by_tool.state_encryption | length == 1'
  run -0 jqr '.notes | join(" ")'
  contains "$output" "a file it never enumerated may configure encryption"
  lacks "$output" ".tf file(s) the check could not read"
}

@test "the UNRESOLVED branch is reachable through tf_search_incomplete ALONE" {
  # both earlier fixtures used an UNPRUNED locked directory, which fails the
  # .tf.json walk too — so tfjson_incomplete kept the branch alive and the new
  # disjunct could be deleted with the suite green. A locked directory INSIDE a
  # pruned tree fails only the unpruned .tf walk, isolating it.
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  module_library
  mkdir -p "$W/.terraform/locked"
  chmod 000 "$W/.terraform/locked"
  stub_conftest
  capture
  chmod 755 "$W/.terraform/locked"
  run -0 jqr '.notes | join(" ")'
  contains "$output" "a .tf search that could not complete"
  contains "$output" "UNRESOLVED"
  lacks "$output" "reusable module library"
  lacks "$output" "a .tf.json search that could not complete"
  lacks "$output" ".tf file(s) it could not read"
}

@test "the UNRESOLVED branch is reachable through .tf.json presence ALONE" {
  # permission-free, so unlike every chmod-based UNRESOLVED test this one also
  # runs in the Docker (uid 0) lane
  module_library
  printf '{"terraform": {}}\n' > "$W/backend.tf.json"
  stub_conftest
  capture
  run -0 jqr '.notes | join(" ")'
  contains "$output" "UNRESOLVED"
  contains "$output" ".tf.json sources it cannot parse"
  lacks "$output" ".tf file(s) it could not read"
  lacks "$output" "reusable module library"
}

@test "a conftest that exits 126 is unavailable, not a failing test run" {
  # the 126 half of `verify_rc == 126 || verify_rc == 127` was produced by no
  # fixture: delete it and a noexec-mount or wrong-architecture conftest falls
  # to the generic arm and renders as policy_tests_failing whose evidence reads
  # "Permission denied" — blaming the repo's Rego for a toolchain fault
  root_module
  policy
  policy_test
  printf '#!%s\nif [ "$1" = "--version" ]; then printf "Conftest: v0.69.0\\nOPA: v1.4.2\\n"; exit 0; fi\nexit 126\n' \
    "$(command -v bash)" > "$STUB/conftest"
  chmod +x "$STUB/conftest"
  capture
  run -0 jqr '[.findings_by_tool.policy[] | select(.id == "policy:conftest-unavailable") | .message] | .[0]'
  contains "$output" "exit 126"
  lacks "$output" "exit 127"
  run -0 jqr '[.findings_by_tool.policy[].type] | join(",")'
  lacks "$output" "policy_tests_failing"
}

@test "a conftest WRAPPER returning 125 is not read as 'cannot enter the repo'" {
  # 125 is the cd subshell's sentinel, unambiguous for find but NOT for conftest
  # — mise/asdf shims, a `docker run` wrapper (125 when it cannot start a
  # container), direnv. A bare `== 125` printed "cannot enter <repo>" and exit
  # 2, discarding the other six tool keys and the whole state_encryption verdict
  # over a broken wrapper, and pointing the reader at a permission problem that
  # does not exist.
  root_module
  policy
  policy_test
  printf '#!%s\nif [ "$1" = "--version" ]; then printf "Conftest: v0.69.0\\nOPA: v1.4.2\\n"; exit 0; fi\nexit 125\n' \
    "$(command -v bash)" > "$STUB/conftest"
  chmod +x "$STUB/conftest"
  run --separate-stderr env "PATH=$STUB:$PATH" "$(command -v zsh)" "$GATHER" "$W"
  [ "$status" -eq 0 ]
  lacks "$stderr" "cannot enter"
  PAYLOAD="$output"
  jqe '.findings_by_tool.state_encryption | length == 1'
  jqe '.findings_by_tool | has("policy")'
}

@test "the conftest-unavailable finding FORWARDS the system's own diagnostic" {
  root_module
  policy
  policy_test
  printf '#!/nonexistent/bin/sh\n' > "$STUB/conftest"
  chmod +x "$STUB/conftest"
  capture
  run -0 jqr '[.findings_by_tool.policy[] | select(.id == "policy:conftest-unavailable") | .message] | .[0]'
  contains "$output" "The system said:"
}

@test "a conftest.toml that declares NO namespaces neither refuses nor exempts" {
  # every conftest.toml fixture in the suite leads with `namespaces = [...]`, so
  # the accepted no-match status (1) — the ordinary repo, whose conftest.toml
  # sets only `policy = "..."` — was never produced. Tightening the guard to
  # `== 0` would exit 2 on every such repo; treating the file's existence as
  # "namespaces declared" would silently exempt them from the stray check.
  root_module
  mkdir -p "$W/policies/conftest"
  printf 'package terraform.security\n\ndeny contains msg if {\n  msg := "x"\n}\n' \
    > "$W/policies/conftest/stray.rego"
  policy_test
  printf 'policy = "policies/conftest"\n' > "$W/conftest.toml"
  stub_conftest
  capture
  run -0 jqr '[.findings_by_tool.policy[].id] | join(",")'
  contains "$output" "policy:package-outside-invoked-namespace"
}

@test "a cloud block is a ROOT, not a module library — the second owns-state probe" {
  # this fixture has no provider and no backend, so owns_state can only become
  # true via the cloud probe. Without the note anchor, deleting that probe left
  # `state_encryption == []` true and the test green, while the payload called
  # an HCP Terraform root a reusable module library.
  printf 'terraform {\n  cloud {\n    organization = "acme"\n  }\n}\n' > "$W/main.tf"
  stub_conftest
  capture
  jqe '.findings_by_tool.state_encryption == []'
  run -0 jqr '.notes | join(" ")'
  lacks "$output" "reusable module library"
  lacks "$output" "UNRESOLVED"
}
