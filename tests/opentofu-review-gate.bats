#!/usr/bin/env bats
#
# tofu-review-gate.zsh — the pre-dispatch gate of /development-opentofu:review
# (issue #1161).
#
# The gate's three outcomes are the contract the review skill builds on, and
# they must stay distinct: a tree that does not validate FAILS the round (exit
# 10), a registry that cannot be reached DEGRADES it to a source-only review
# (exit 0, verdict "degraded"), and a tree that passes gets the full review.
# tflint never changes the verdict.
#
# `tofu` and `tflint` are STUBS here, never the host's: the default suite has no
# OpenTofu toolchain (tests/iac-tools.zsh pins none), and a host copy would make
# the "absent" cases depend on the machine. So every run gets a CURATED PATH —
# a directory of symlinks to exactly the tools the script needs, plus whichever
# stubs the test installs — and never /usr/bin. A HIDE_BIN stub would not do
# for the absent cases: the script asks `command -v`, which finds a stub that
# exits 127 just as it finds the real tool.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO_ROOT/development-opentofu/skills/review/scripts/tofu-review-gate.zsh"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-opentofu-findings.zsh"
  [ -x "$GATE" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  local t p
  # every external the script (and the /bin/sh stubs) call. A missing one fails
  # LOUDLY here rather than letting a case pass on a script that never ran.
  for t in zsh jq rsync find awk grep sed mktemp tail mkdir rm; do
    p="$(command -v "$t")" || { echo "test prerequisite missing: $t" >&2; return 1; }
    ln -s "$p" "$BIN/$t"
  done
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : >"$STUB_LOG"
  # the scratch work dirs land here, so the per-test cleanup removes them
  export TMPDIR="$BATS_TEST_TMPDIR/"

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/modules/network"
  cat >"$REPO/main.tf" <<'EOF'
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.3" }
  }
}
module "network" {
  source = "./modules/network"
  cidr   = "10.20.0.0/16"
}
EOF
  printf 'variable "cidr" {}\n' >"$REPO/modules/network/variables.tf"
}

# A tofu stub. TOFU_INIT_OUT / TOFU_VALIDATE_OUT, when set, make that step fail
# with that output; every call is logged with its arguments, the directory it
# ran in and the plugin cache it was handed.
stub_tofu() {
  cat >"$BIN/tofu" <<'EOF'
#!/bin/sh
echo "tofu $* $(pwd) cache=${TF_PLUGIN_CACHE_DIR:-}" >>"$STUB_LOG"
case "$1" in
  init)     if [ -n "${TOFU_INIT_OUT:-}" ]; then echo "$TOFU_INIT_OUT"; exit 1; fi ;;
  validate) if [ -n "${TOFU_VALIDATE_OUT:-}" ]; then echo "$TOFU_VALIDATE_OUT"; exit 1; fi
            echo "Success! The configuration is valid." ;;
esac
exit 0
EOF
  chmod +x "$BIN/tofu"
}

# A tflint stub exiting $1 (0 = clean, 3 = issues found, else = could not run).
stub_tflint() {
  cat >"$BIN/tflint" <<EOF
#!/bin/sh
echo "tflint \$* \$(pwd)" >>"\$STUB_LOG"
echo "1 issue(s) found: terraform_typed_variables"
exit $1
EOF
  chmod +x "$BIN/tflint"
}

gate() {
  run --separate-stderr env PATH="$BIN" "$GATE" "$@"
}

@test "both passing runs the FULL review (#1161)" {
  stub_tofu
  stub_tflint 0
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "full" ]
  [ "$(jq -c .validated <<<"$output")" = '["."]' ]
  [ "$(jq -c .source_only <<<"$output")" = '[]' ]
  [ "$(jq -c .failures <<<"$output")" = '[]' ]
  [ "$(jq -r .tflint.status <<<"$output")" = "ran" ]
  grep -qF 'tofu init -backend=false -input=false' "$STUB_LOG"
  [ "$(jq -r .tflint.exit <<<"$output")" -eq 0 ]
}

@test "a called module is validated THROUGH its root, never on its own (#1161)" {
  # modules/network is sourced by the root, so it is not a root of its own: a
  # called module validated standalone can fail on provider configuration only
  # its caller supplies, which would fail a good tree
  stub_tofu
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '["."]' ]
  run -1 grep -F '/modules/network' "$STUB_LOG"
}

@test "an UNCALLED module directory is a root of its own (#1161)" {
  stub_tofu
  sed -i.bak '/module "network"/,/^}/d' "$REPO/main.tf"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '[".","modules/network"]' ]
  [ "$(jq -c .validated <<<"$output")" = '[".","modules/network"]' ]
}

@test "a ../ local source marks the called module, from any depth (#1161)" {
  stub_tofu
  rm "$REPO/main.tf"
  mkdir -p "$REPO/envs/prod"
  printf 'module "network" {\n  source = "../../modules/network"\n}\n' >"$REPO/envs/prod/main.tf"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '["envs/prod"]' ]
}

@test "a caller of the repo-ROOT module (source = \"../..\") makes the root a callee (#1161)" {
  stub_tofu
  mkdir -p "$REPO/examples/basic"
  printf 'module "root" {\n  source = "../.."\n}\n' >"$REPO/examples/basic/main.tf"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '["examples/basic"]' ]
}

@test "a .tf.json caller's ../ and repo-root sources mark their callees too (#1161)" {
  stub_tofu
  rm "$REPO/main.tf"
  mkdir -p "$REPO/envs/prod"
  printf '{"module":{"network":{"source":"../../modules/network"}}}\n' >"$REPO/envs/prod/main.tf.json"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '["envs/prod"]' ]
  printf 'variable "a" {}\n' >"$REPO/main.tf"
  mkdir -p "$REPO/examples/basic"
  printf '{"module":{"root":{"source":"../.."}}}\n' >"$REPO/examples/basic/main.tf.json"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '["envs/prod","examples/basic"]' ]
}

@test "a commented-out source line is not a call (#1161)" {
  stub_tofu
  mkdir -p "$REPO/examples/basic"
  printf '# source = "../.."\n// source = "../.."\n/* source = "../.." */\n/*\nmodule "r" {\n  source = "../.."\n}\n*/\nvariable "a" {}\n' >"$REPO/examples/basic/main.tf"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '[".","examples/basic"]' ]
}

@test "a call still counts past a /* in a string, a heredoc glob, an interpolation, a closed block or a trailing note (#1161)" {
  # a call is a line BEGINNING with `source =`, and a block comment only one a
  # line begins with `/*`: nothing mid-line — an ARN, a heredoc's shell glob, a
  # nested-quote interpolation, a trailing note — hides a call
  stub_tofu
  mkdir -p "$REPO/examples/basic"
  cat >"$REPO/examples/basic/main.tf" <<'EOF'
locals {
  bucket_objects = "arn:aws:s3:::timos-platform-logs/*"
  bucket_arns    = ["${format("%s/*", "arn:aws:s3:::timos-platform-logs")}"]
}
resource "null_resource" "boot" {
  user_data = <<-EOT
    rm -rf /tmp/*
  EOT
}
module "root" {
  source = "../.." /* the module under test */
}
EOF
  # a separate file, so no `*/` above can close a block the ARN wrongly opened
  mkdir -p "$REPO/examples/wrapper"
  cat >"$REPO/examples/wrapper/main.tf" <<'EOF'
/*
  wraps the basic example
*/
/* a one-line block closes on its own line */
module "basic" {
  source = "../basic" # the example it wraps
}
module "other" {
  source = "../other" // a trailing slash-slash note
}
EOF
  # a second callee, so the `#` and `//` notes each decide a root of their own
  mkdir -p "$REPO/examples/other"
  printf 'variable "a" {}\n' >"$REPO/examples/other/main.tf"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '["examples/wrapper"]' ]
}

@test "a one-line module block is a call too (#1161)" {
  stub_tofu
  mkdir -p "$REPO/examples/basic"
  printf 'module "root" { source = "../.." }\n' >"$REPO/examples/basic/main.tf"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '["examples/basic"]' ]
}

@test "a tree whose every directory is called is validated, never verdict EMPTY (#1161)" {
  stub_tofu
  printf 'module "self" {\n  source = "./"\n}\n' >>"$REPO/main.tf"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "full" ]
  [ "$(jq -c .roots <<<"$output")" = '[".","modules/network"]' ]
}

@test "a local source in a .tf.json caller is honoured too (#1161)" {
  stub_tofu
  rm "$REPO/main.tf"
  printf '{"module":{"network":{"source":"./modules/network"}}}\n' >"$REPO/main.tf.json"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '["."]' ]
}

@test "tofu validate FAILS -> the round FAILS, naming the root and the file (#1161)" {
  stub_tofu
  export TOFU_VALIDATE_OUT='Error: Invalid default value for variable
  on modules/network/variables.tf line 3:
   3:   default = "a number is required"'
  gate --repo "$REPO"
  [ "$status" -eq 10 ]
  [ "$(jq -r .verdict <<<"$output")" = "failed" ]
  [ "$(jq -r '.failures[0].root' <<<"$output")" = "." ]
  [ "$(jq -r '.failures[0].step' <<<"$output")" = "validate" ]
  contains "$(jq -r '.failures[0].output' <<<"$output")" 'Error: Invalid default value for variable'
  contains "$(jq -r '.failures[0].output' <<<"$output")" 'modules/network/variables.tf'
  [ "$(jq -c .validated <<<"$output")" = '[]' ]
}

@test "tofu init that cannot reach the registry DEGRADES, and the round proceeds (#1161)" {
  stub_tofu
  export TOFU_INIT_OUT='Error: Failed to query available provider packages
Could not retrieve the list of available versions for provider hashicorp/aws:
could not connect to registry.opentofu.org: dial tcp: lookup registry.opentofu.org: no such host'
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "degraded" ]
  [ "$(jq -c .source_only <<<"$output")" = '["."]' ]
  [ "$(jq -c .failures <<<"$output")" = '[]' ]
  contains "$(jq -r '.notes | join("\n")' <<<"$output")" 'could not reach the provider registry'
  # validate never ran: there are no providers to validate against
  run -1 grep -F 'tofu validate' "$STUB_LOG"
}

@test "every network signature degrades rather than fails (#1161)" {
  # each sample carries EXACTLY ONE signature, so dropping any one of them from
  # the script reds here — a sample matching two would keep passing on the other
  stub_tofu
  local sig
  for sig in 'dial tcp 1.2.3.4:443' 'lookup registry.opentofu.org: no such host' \
             'read: i/o timeout' 'connect: connection refused' \
             'connect: network is unreachable' 'net/http: TLS handshake timeout' \
             'Client.Timeout exceeded while awaiting headers' \
             'could not connect to registry.opentofu.org' \
             'failed to request discovery document' 'server misbehaving' \
             'Temporary failure in name resolution' 'connection reset by peer' \
             'fatal: unable to access: Could not resolve host: github.com' \
             'Failed to connect to github.com port 443'; do
    TOFU_INIT_OUT="Error: $sig" run --separate-stderr env PATH="$BIN" "$GATE" --repo "$REPO"
    [ "$status" -eq 0 ] || { echo "signature failed the round: $sig" >&2; return 1; }
    [ "$(jq -r .verdict <<<"$output")" = "degraded" ]
  done
}

@test "an init failure that is NOT the network is the tree's own, and FAILS (#1161)" {
  stub_tofu
  export TOFU_INIT_OUT='Error: Unreadable module directory

Unable to evaluate directory symlink: modules/networking does not exist'
  gate --repo "$REPO"
  [ "$status" -eq 10 ]
  [ "$(jq -r .verdict <<<"$output")" = "failed" ]
  [ "$(jq -r '.failures[0].step' <<<"$output")" = "init" ]
  [ "$(jq -r '.failures[0].root' <<<"$output")" = "." ]
  contains "$(jq -r '.failures[0].output' <<<"$output")" 'Error: Unreadable module directory'
  contains "$(jq -r '.failures[0].output' <<<"$output")" 'modules/networking does not exist'
}

@test "one root's init failure does not stop the next root being validated (#1161)" {
  sed -i.bak '/module "network"/,/^}/d' "$REPO/main.tf"
  cat >"$BIN/tofu" <<'EOF'
#!/bin/sh
case "$1:$(pwd)" in
  init:*/tree) echo "Error: Unsupported block type"; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$BIN/tofu"
  gate --repo "$REPO"
  [ "$status" -eq 10 ]
  [ "$(jq -c .validated <<<"$output")" = '["modules/network"]' ]
}

@test "every offline root is listed source-only, and every failing root is a failure (#1161)" {
  stub_tofu
  sed -i.bak '/module "network"/,/^}/d' "$REPO/main.tf"
  TOFU_INIT_OUT='Error: dial tcp: lookup registry.opentofu.org: no such host' \
    run --separate-stderr env PATH="$BIN" "$GATE" --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .source_only <<<"$output")" = '[".","modules/network"]' ]
  TOFU_VALIDATE_OUT='Error: Unsupported argument' \
    run --separate-stderr env PATH="$BIN" "$GATE" --repo "$REPO"
  [ "$status" -eq 10 ]
  [ "$(jq '.failures | length' <<<"$output")" -eq 2 ]
}

@test "a failure outranks a degradation in another root (#1161)" {
  # two roots, one offline and one broken: the round FAILS, because a broken
  # tree is the one most worth reviewing and must not read as merely degraded
  sed -i.bak '/module "network"/,/^}/d' "$REPO/main.tf"
  cat >"$BIN/tofu" <<'EOF'
#!/bin/sh
case "$1:$(pwd)" in
  init:*/modules/network) echo "Error: dial tcp: no such host"; exit 1 ;;
  validate:*) echo "Error: Unsupported argument"; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$BIN/tofu"
  gate --repo "$REPO"
  [ "$status" -eq 10 ]
  [ "$(jq -r .verdict <<<"$output")" = "failed" ]
  [ "$(jq -c .source_only <<<"$output")" = '["modules/network"]' ]
}

@test "tofu not installed DEGRADES with a note naming it (#1161)" {
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "degraded" ]
  [ "$(jq -c .source_only <<<"$output")" = '["."]' ]
  contains "$(jq -r '.notes | join("\n")' <<<"$output")" 'tofu is not installed'
}

@test "tflint absent adds a note and leaves a FULL verdict alone (#1161)" {
  stub_tofu
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "full" ]
  [ "$(jq -r .tflint.status <<<"$output")" = "absent" ]
  contains "$(jq -r '.notes | join("\n")' <<<"$output")" 'tflint is not installed'
}

@test "tflint finding issues (exit 3) ran, and its output is kept for the reviewers (#1161)" {
  stub_tofu
  stub_tflint 3
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "full" ]
  [ "$(jq -r .tflint.status <<<"$output")" = "ran" ]
  [ "$(jq -r .tflint.exit <<<"$output")" -eq 3 ]
  grep -qF 'tflint --recursive' "$STUB_LOG"
  contains "$(cat "$(jq -r .tflint.output_file <<<"$output")")" 'terraform_typed_variables'
}

@test "tflint failing to run (exit 2) is a note, never a failed round (#1161)" {
  stub_tofu
  stub_tflint 2
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "full" ]
  [ "$(jq -r .tflint.status <<<"$output")" = "error" ]
  [ "$(jq -r .tflint.exit <<<"$output")" -eq 2 ]
  [ "$(jq -r .tflint.output_file <<<"$output")" = "$(jq -r .work_dir <<<"$output")/tflint.txt" ]
  contains "$(jq -r '.notes | join("\n")' <<<"$output")" 'tflint could not run (exit 2)'
}

@test "the reviewed tree is never written — init runs in a scratch copy (#1161)" {
  # a tofu that writes what the real one writes, wherever it runs
  cat >"$BIN/tofu" <<'EOF'
#!/bin/sh
echo "tofu $1 $(pwd)" >>"$STUB_LOG"
[ "$1" = init ] && { mkdir -p .terraform; : > .terraform.lock.hcl; }
exit 0
EOF
  chmod +x "$BIN/tofu"
  local before after
  before="$(cd "$REPO" && find . | LC_ALL=C sort)"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  after="$(cd "$REPO" && find . | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  # and it did run somewhere: in the work dir the document names
  contains "$(cat "$STUB_LOG")" "$(jq -r .work_dir <<<"$output")/tree"
}

@test "pruned trees are never roots, but vendored modules are still copied (#1161)" {
  stub_tofu
  mkdir -p "$REPO/vendor/modules/x" "$REPO/.terraform/modules/y" "$REPO/node_modules/z"
  printf 'variable "a" {}\n' | tee "$REPO/vendor/modules/x/main.tf" \
    "$REPO/.terraform/modules/y/main.tf" "$REPO/node_modules/z/main.tf" >/dev/null
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '["."]' ]
  # a module may be sourced from ./vendor/…, so validation needs it in the copy
  local tree
  tree="$(jq -r .work_dir <<<"$output")/tree"
  [ -f "$tree/vendor/modules/x/main.tf" ]
  # …while a stale .terraform/, node_modules/ and .git/ are never copied
  [ ! -e "$tree/.terraform" ]
  [ ! -e "$tree/node_modules" ]
}

@test "the copy leaves out .git (#1161)" {
  stub_tofu
  mkdir -p "$REPO/.git"
  : >"$REPO/.git/HEAD"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$(jq -r .work_dir <<<"$output")/tree/.git" ]
}

@test "the prune matches fixed strings — a _terraform directory is still a root (#1161)" {
  stub_tofu
  mkdir -p "$REPO/_terraform"
  printf 'variable "a" {}\n' >"$REPO/_terraform/main.tf"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -c .roots <<<"$output")" = '[".","_terraform"]' ]
}

@test "a repo whose only .tf is pruned is verdict EMPTY, not an error (#1161)" {
  stub_tofu
  rm -rf "$REPO"/*.tf "$REPO/modules"
  mkdir -p "$REPO/vendor/modules/x"
  printf 'variable "a" {}\n' >"$REPO/vendor/modules/x/main.tf"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "empty" ]
}

@test "a repo with no .tf is verdict EMPTY, and tofu is never called (#1161)" {
  stub_tofu
  rm -rf "$REPO"/*.tf "$REPO/modules"
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "empty" ]
  [ "$(jq -c .roots <<<"$output")" = '[]' ]
  [ ! -s "$STUB_LOG" ]
}

@test "usage errors exit 2 and print nothing on stdout (#1161)" {
  gate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  gate --repo
  [ "$status" -eq 2 ]
  gate --repo "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  gate --repo "$REPO" --bogus
  [ "$status" -eq 2 ]
}

@test "a missing required tool is an internal failure (exit 1), never a verdict (#1161)" {
  rm "$BIN/rsync"
  gate --repo "$REPO"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'rsync not found'
}

# no scratch copy survives an exit that printed no document naming it
no_work_dir_left() {
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'tofu-review-gate.*')" ]
}

@test "a failing copy is an internal failure, and its work dir is removed (#1161)" {
  rm "$BIN/rsync"
  printf '#!/bin/sh\nexit 23\n' >"$BIN/rsync"
  chmod +x "$BIN/rsync"
  gate --repo "$REPO"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'copying'
  no_work_dir_left
}

@test "an incomplete module search is an internal failure, never verdict EMPTY (#1161)" {
  rm "$BIN/find"
  printf '#!/bin/sh\necho ./main.tf\nexit 1\n' >"$BIN/find"
  chmod +x "$BIN/find"
  gate --repo "$REPO"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" 'module search did not complete'
  no_work_dir_left
}

@test "a failing prune filter is an internal failure (#1161)" {
  local real
  real="$(readlink "$BIN/grep")"
  rm "$BIN/grep"
  printf '#!/bin/sh\ncase "$*" in *-vF*) exit 2 ;; esac\nexec %s "$@"\n' "$real" >"$BIN/grep"
  chmod +x "$BIN/grep"
  gate --repo "$REPO"
  [ "$status" -eq 1 ]
  contains "$stderr" 'prune filter did not complete'
}

@test "a plugin cache the user configured is kept; otherwise one is made per run (#1161)" {
  stub_tofu
  gate --repo "$REPO"
  [ "$status" -eq 0 ]
  grep -qF "cache=$(jq -r .work_dir <<<"$output")/plugin-cache" "$STUB_LOG"
  : >"$STUB_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/my-cache"
  TF_PLUGIN_CACHE_DIR="$BATS_TEST_TMPDIR/my-cache" \
    run --separate-stderr env PATH="$BIN" "$GATE" --repo "$REPO"
  [ "$status" -eq 0 ]
  grep -qF "cache=$BATS_TEST_TMPDIR/my-cache" "$STUB_LOG"
}

@test "the prune set is #1160's detection recipe's, verbatim (#1161)" {
  # the review reads "the same prune set as #1160's detection recipe"; two
  # copies of a list drift unless something compares them
  [ -f "$GATHER" ]
  local ours theirs
  ours="$(sed -n '/^local -a PRUNE_NAMES=(/,/^)/p' "$GATE" | sed '1d;$d' | tr -s '[:space:]' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
  theirs="$(sed -n '/^local -a PRUNE_NAMES=(/,/^)/p' "$GATHER" | sed '1d;$d' | tr -s '[:space:]' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
  [ -n "$ours" ]
  [ "$ours" = "$theirs" ]
  [ "$ours" = ".git .terraform node_modules vendor " ]
}
