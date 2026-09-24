#!/usr/bin/env bats
#
# Acceptance cases for "the four agents and the review skill" of
# development-opentofu (#1161) — the `cli`-tooled test_cases[] of its
# story-spec, one test per `tc-*` id:
#
#   tc-happy-full-review              #1388
#   tc-error-validate-fails           #1389
#   tc-corner-registry-unreachable    #1390
#   tc-corner-tflint-absent           #1391
#   tc-happy-frontmatter-and-routing  #1392
#
# The use case: timo-platform-builder runs /development-opentofu:review against
# a timos-platform infra repo — main.tf pinning hashicorp/aws ~> 6.3, a
# modules/network/ module with untyped, unvalidated variables, an S3 state
# backend with no encryption block, and a Conftest policy with no tests — and
# gets a grounded two-dimension review that still works offline.
#
# What runs for real: the review skill's pre-dispatch gate
# (tofu-review-gate.zsh) over that repo, against a stubbed `tofu` / `tflint` —
# the default suite pins no OpenTofu toolchain, and the registry-unreachable
# case needs a network outage no real run can promise. The two reviewers are
# model-driven, so the cases assert what the SKILL dispatches (its panel table
# and prompt contract), never a model's output. The default gate's
# tests/opentofu-review-gate.bats and tests/opentofu-review-panel.bats cover the
# same criteria clause by clause.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN="$REPO_ROOT/development-opentofu"
  GATE="$PLUGIN/skills/review/scripts/tofu-review-gate.zsh"
  SKILL="$PLUGIN/skills/review/SKILL.md"
  DISPATCHER="$PLUGIN/skills/maintenance/SKILL.md"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  local t p
  for t in zsh jq rsync find awk grep sed mktemp tail mkdir rm cat; do
    p="$(command -v "$t")" || { echo "acceptance prerequisite missing: $t" >&2; return 1; }
    ln -s "$p" "$BIN/$t"
  done
  export TMPDIR="$BATS_TEST_TMPDIR/"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : >"$STUB_LOG"

  INFRA="$BATS_TEST_TMPDIR/timos-platform-infra"
  mkdir -p "$INFRA/modules/network" "$INFRA/policies/conftest"
  cat >"$INFRA/main.tf" <<'EOF'
terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.3"
    }
  }
  backend "s3" {
    bucket = "timos-platform-tfstate"
    key    = "platform/eu-central-1.tfstate"
    region = "eu-central-1"
  }
}

provider "aws" {
  region = "eu-central-1"
}

module "network" {
  source     = "./modules/network"
  vpc_cidr   = "10.42.0.0/16"
  az_count   = 3
  env_name   = "platform-prod"
}
EOF
  cat >"$INFRA/modules/network/variables.tf" <<'EOF'
variable "vpc_cidr" {}
variable "az_count" {}
variable "env_name" {}
EOF
  cat >"$INFRA/modules/network/outputs.tf" <<'EOF'
output "vpc_id" {
  value = aws_vpc.this.id
}
EOF
  cat >"$INFRA/modules/network/main.tf" <<'EOF'
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  tags       = { Name = var.env_name }
}
EOF
  cat >"$INFRA/policies/conftest/deny_public_bucket.rego" <<'EOF'
package main

deny contains msg if {
  some name
  input.resource.aws_s3_bucket_acl[name].acl == "public-read"
  msg := sprintf("bucket ACL %s is public", [name])
}
EOF
}

stub_tofu() {
  cat >"$BIN/tofu" <<'EOF'
#!/bin/sh
echo "tofu $1 $(pwd)" >>"$STUB_LOG"
case "$1" in
  init)     if [ -n "${TOFU_INIT_OUT:-}" ]; then echo "$TOFU_INIT_OUT"; exit 1; fi
            echo "OpenTofu has been successfully initialized!" ;;
  validate) if [ -n "${TOFU_VALIDATE_OUT:-}" ]; then echo "$TOFU_VALIDATE_OUT"; exit 1; fi
            echo "Success! The configuration is valid." ;;
esac
exit 0
EOF
  chmod +x "$BIN/tofu"
}

stub_tflint() {
  cat >"$BIN/tflint" <<'EOF'
#!/bin/sh
echo "tflint $* $(pwd)" >>"$STUB_LOG"
cat <<'OUT'
3 issue(s) found:

Warning: `vpc_cidr` variable has no type (terraform_typed_variables)
  on modules/network/variables.tf line 1:
Warning: `az_count` variable has no type (terraform_typed_variables)
  on modules/network/variables.tf line 2:
Warning: `env_name` variable has no type (terraform_typed_variables)
  on modules/network/variables.tf line 3:
OUT
exit 3
EOF
  chmod +x "$BIN/tflint"
}

gate() {
  run --separate-stderr env PATH="$BIN" "$GATE" --repo "$INFRA"
}

# the Step 2 panel table's agent column, in order
panel() {
  sed -n '/^## Step 2/,/^## /p' "$SKILL" | sed -n 's/^| [a-z]* | `\([a-z-]*\)` |$/\1/p' | tr '\n' ' '
}

@test "tc-happy-full-review: registry reachable -> full gate, both reviewers dispatched in parallel, one JSON array" {
  stub_tofu
  stub_tflint
  gate
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "full" ]
  [ "$(jq -c .validated <<<"$output")" = '["."]' ]
  # the tflint evidence the module advisor reads names the unvalidated variables
  contains "$(cat "$(jq -r .tflint.output_file <<<"$output")")" 'modules/network/variables.tf'
  # what the skill then dispatches: exactly the two reviewers, in parallel, each
  # emitting one fenced JSON array that Step 4 concatenates into one
  [ "$(panel)" = "opentofu-security-reviewer opentofu-module-advisor " ]
  contains "$(cat "$SKILL")" 'Dispatch two agents **in parallel**'
  contains "$(cat "$SKILL")" 'concatenate their two JSON arrays into one array'
  # the module advisor's own brief covers the unvalidated variables
  contains "$(cat "$PLUGIN/agents/opentofu-module-advisor.md")" 'a variable with no `type`'
  # the review never wrote into the infra repo
  [ ! -e "$INFRA/.terraform" ]
  [ ! -e "$INFRA/.terraform.lock.hcl" ]
}

@test "tc-error-validate-fails: a number default on a string variable -> round FAILS, file named, findings path never written" {
  stub_tofu
  cat >"$INFRA/modules/network/variables.tf" <<'EOF'
variable "vpc_cidr" { type = string }
variable "az_count" { type = number }
variable "env_name" {
  type    = string
  default = 42
}
EOF
  export TOFU_VALIDATE_OUT='Error: Invalid default value for variable

  on modules/network/variables.tf line 5, in variable "env_name":
   5:   default = 42

This default value is not compatible with the variable'"'"'s type constraint: string required.'
  gate
  [ "$status" -eq 10 ]
  [ "$(jq -r .verdict <<<"$output")" = "failed" ]
  contains "$(jq -r '.failures[0].output' <<<"$output")" 'modules/network/variables.tf line 5'
  # the skill's handling of that exit: the document goes to the .failed.json
  # sibling of review-findings-round-1.json, and the findings path is untouched
  local findings="$BATS_TEST_TMPDIR/review-findings-round-1.json"
  printf '%s\n' "$output" >"$findings.failed.json"
  jq -e '.verdict == "failed"' "$findings.failed.json" >/dev/null
  [ ! -e "$findings" ]
  contains "$(tr -s '[:space:]' ' ' <"$SKILL")" 'write the gate'"'"'s document to the sibling `<findings-path>.failed.json`, and write **nothing** to the findings path'
}

@test "tc-corner-registry-unreachable: offline init -> DEGRADED source-only review, both agents still dispatched, round succeeds" {
  stub_tofu
  export TOFU_INIT_OUT='Error: Failed to query available provider packages

Could not retrieve the list of available versions for provider hashicorp/aws:
could not connect to registry.opentofu.org: failed to request discovery
document: Get "https://registry.opentofu.org/.well-known/terraform.json": dial
tcp: lookup registry.opentofu.org: no such host'
  gate
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "degraded" ]
  [ "$(jq -c .source_only <<<"$output")" = '["."]' ]
  [ "$(jq -c .failures <<<"$output")" = '[]' ]
  contains "$(jq -r '.notes | join("\n")' <<<"$output")" 'could not reach the provider registry'
  # the skill proceeds: same two-agent panel, and the note travels in the prompt
  [ "$(panel)" = "opentofu-security-reviewer opentofu-module-advisor " ]
  contains "$(tr -s '[:space:]' ' ' <"$SKILL")" 'the round proceeds as a **source-only review** and can succeed'
  contains "$(cat "$SKILL")" 'a "degraded" verdict means the roots listed as source-only were NOT validated'
}

@test "tc-corner-tflint-absent: no tflint on PATH -> lint skipped with a note, round proceeds to the FULL review" {
  stub_tofu
  [ ! -e "$BIN/tflint" ]
  gate
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<<"$output")" = "full" ]
  [ "$(jq -r .tflint.status <<<"$output")" = "absent" ]
  contains "$(jq -r '.notes | join("\n")' <<<"$output")" 'tflint is not installed — lint skipped'
}

@test "tc-happy-frontmatter-and-routing: four agents parse, names match files, routing targets match #1160, no approver" {
  local f stem
  [ "$(cd "$PLUGIN/agents" && LC_ALL=C ls | tr '\n' ' ')" = "opentofu-format-fixer.md opentofu-module-advisor.md opentofu-policy-triage.md opentofu-security-reviewer.md " ]
  for f in "$PLUGIN"/agents/*.md; do
    stem="$(basename "$f" .md)"
    [ "$(awk '/^---$/ { n++; next } n == 1 && /^name: / { print $2; exit }' "$f")" = "$stem" ]
  done
  local routed
  routed="$(sed -n 's/^| `[a-z_]*` | .* | `\([a-z-]*\)` |$/\1/p' "$DISPATCHER" | LC_ALL=C sort -u | tr '\n' ' ')"
  contains "$routed" 'opentofu-format-fixer'
  contains "$routed" 'opentofu-policy-triage'
  for f in $routed; do [ -f "$PLUGIN/agents/$f.md" ]; done
  [ -z "$(find "$PLUGIN/agents" -iname '*approver*')" ]
}
