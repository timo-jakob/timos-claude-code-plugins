#!/usr/bin/env zsh
# gather-opentofu-findings.zsh — the opentofu topic's finding gatherer
# (epic #1158, child #1160). Emits the v2 gather payload the
# `development-opentofu` dispatcher consumes:
# `tooling_configured` / `findings_by_tool` / `coverage` / `notes`.
#
# Tools (the SEVEN keys, and the whole vocabulary — an eighth key is routing
# drift, which the dispatcher escalates rather than guesses at):
#   format           — `tofu fmt` territory. PRESENCE-DETECTED here; the tool
#                      itself runs in the CI pipeline (#1162), never in this
#                      gather.
#   validate         — `tofu validate` territory. Presence-detected, same rule.
#   lint             — tflint territory. Presence-detected, same rule. The
#                      unpinned-provider opinion (ARCHITECTURE.md) is tflint's
#                      `terraform_required_providers` rule, NOT a check of this
#                      script's own — the plugin's contribution is refusing to
#                      treat its output as a style note, which is a severity
#                      decision made downstream.
#   misconfiguration — `trivy config` territory. Presence-detected, same rule.
#   state_encryption — the plugin's ONE built-in opinion, and the only one of
#                      the five HCL-keyed tools that genuinely EVALUATES rather
#                      than being presence-detected (the two policy keys
#                      evaluate too — the 4/3 split docs/reference/plugins.md
#                      states): state must be encrypted at rest. Dialect-aware, and binding only where the repo owns
#                      state. The classifier is this script's to own
#                      (ARCHITECTURE.md, `development-opentofu` owns) and the
#                      decisions it takes are recorded there, because #1162's
#                      rendered job embeds its own copy and cannot call this.
#   policy           — the repo's OWN Conftest policies, matched by the GLOB
#                      policies/conftest/**/*.rego rather than by the
#                      directory's existence, so an empty (or non-.rego)
#                      directory skips exactly like an absent one.
#                      No match => tooling_configured.policy=false + a note.
#                      NEVER a finding: a public plugin must work in a repo with
#                      no opinions yet.
#                      A declared set Conftest CANNOT EVALUATE never skips
#                      (ARCHITECTURE.md). All FOUR such states are FINDINGS
#                      here — there is no step to fail in a gather: a .rego that
#                      fails to compile, a policy in a package the step never
#                      invokes, a failing `conftest verify` run, and a Conftest
#                      that is not available to evaluate them at all (absent, or
#                      present but unexecutable — see A MISSING CONFTEST below).
#                      That is why this script pins a Conftest version and runs
#                      it, rather than presence-detecting like the four above.
#   policy_tests     — this topic's coverage-gate analogue. A declared policy
#                      set with no `conftest verify` tests passes everything
#                      silently, which is the failure mode hardest to notice.
#
# `coverage` is always null — a topic has no application test suite.
#
# THE CONFTEST PIN. #1162's rendered template hard-codes the same version as a
# job-level env var; it cannot read this constant, because a consumer repo's
# workflow cannot call this plugin's scripts at all. They are two INDEPENDENT
# constants that must be bumped together, and asserting that is #1162's to own.
# Nothing shares them automatically.
#
# Usage: gather-opentofu-findings.zsh [<repo_path>]   (default: current dir)
# Output: JSON on stdout (always exit 0 on a well-formed run).
#
# Exit codes (a real contract — tests/gather-opentofu.bats pins the messages):
#   0  the payload is on stdout
#   2  no payload is emitted and stdout is empty, for one of THREE classes:
#      (a) the tree could not be SEARCHED — the argument is not a directory /
#          not readable; the repo could not be entered; the .tf search did not
#          complete; policies/conftest exists but is not readable; the policy or
#          fixture listing failed;
#      (a2) the declared sources could not be READ or SCANNED — every .tf is
#          unreadable; the .tf sources could not be concatenated; conftest.toml
#          exists but could not be read; the package or test_-rule scan over the
#          declared .rego files failed, or the filter over its captured output
#          did. These are read failures rather than search failures, and they
#          refuse rather than guess: an unreadable policy would otherwise
#          FABRICATE the untested-policies finding, and an unreadable module
#          would clear the state-encryption check.
#      (b) the payload could not be ENCODED or EMITTED — a jq that is on PATH
#          but failed (an absent jq is 3, below). Folded into 2 deliberately, so
#          jq's own status 5 never escapes this documented set.
#      Either way the orchestrator records `gather failed: <stderr>` and puts the
#      topic in `unsupported_topics` — never a clean, tool-ran verdict. Read the
#      message, not the code, to tell the classes apart.
#   3  jq is not on PATH (nothing can be emitted at all).
#
# A MISSING CONFTEST IS NOT AN EXIT CODE. It is a `policy` finding, and only
# when policies are actually declared — see the policy section. Exiting non-zero
# would put the whole topic in `unsupported_topics` over a tool that only one of
# seven keys needs, and skipping green would be the green-over-unenforced state
# the charter forbids.

emulate -L zsh
set -euo pipefail

# The pinned Conftest this gather evaluates against. Bump together with
# #1162's template env var; see THE CONFTEST PIN above.
local CONFTEST_VERSION="0.69.0"

# jq FIRST, before the path gates: it has no dependency on `$repo`, and exit 3
# ("nothing can be emitted at all") is the environment error the caller can
# actually fix. Checked after the gates it would be masked by a stale path's
# exit 2 — collapsing the two classes the exit contract asks the reader to
# distinguish.
command -v jq >/dev/null 2>&1 || { print -r -u2 -- "gather-opentofu-findings.zsh: jq not found on PATH"; exit 3; }

local repo="${1:-.}"
[[ -d "$repo" ]] || { print -r -u2 -- "gather-opentofu-findings.zsh: not a directory: $repo"; exit 2; }
# and TRAVERSABLE, before any search runs. Each search below also captures its
# OWN exit status rather than blanket-`|| true`-ing a chain, so a directory that
# exists but cannot be entered — or a find killed mid-run — exits 2 with a named
# message instead of yielding an all-false payload with exit 0: "could not look"
# rendered as "looked and found nothing", the outcome the sibling's comments
# repeatedly refuse to produce.
[[ -r "$repo" && -x "$repo" ]] || { print -r -u2 -- "gather-opentofu-findings.zsh: not a readable directory: $repo"; exit 2; }
# normalise a relative path to an explicit ./ prefix: a repo path beginning with
# `-` clears the `[[ -d ]]` gate (test operators parse no options) but is then
# read as an OPTION by `cd` and as a PRIMARY by `find`. `.` and `./…` are
# excluded so the documented default does not become `./.`, which would render a
# doubled prefix in every message the exit contract emits. An `if`, not a `&&`
# list: this script runs under `set -e`, and a false trailing `&&` test in final
# position becomes the script's own status.
if [[ "$repo" != /* && "$repo" != ./* && "$repo" != . ]]; then repo="./$repo"; fi

local -a notes=()

# --- the .tf tree: is there anything to check? --------------------------------
# The marker is `*.tf`, pruning `.terraform/` and vendored trees — byte-identical
# in intent to the SKILL.md `opentofu-marker` recipe and detect-stack.sh's
# `is-opentofu-marker` block, and tests/opentofu-topic-marker.bats derives the
# glob, the prune set and the `! -type d` guard from all three and requires them
# to agree (the 3-way
# parity this story owns).
#
# `.tf.json` is deliberately NOT matched. The charter owns it
# (ARCHITECTURE.md, `development-opentofu` owns), and that section records the
# decision this script took: the JSON syntax is a machine-generation target
# rather than a hand-authored one, every tool in the pipeline reads it only
# after `tofu init` has already resolved the module, and no consumer in this
# family emits it — so widening the marker would add a detection surface with
# no fixture, no consumer and no way to keep #1162's inline copy honest. A
# `.tf.json`-only tree is therefore owned but not DETECTED, which is recorded
# rather than silently resolved.
#
# Capture BEFORE filtering. `find … | grep -q` looks equivalent but inverts under
# `set -o pipefail`: grep -q exits at its first match, find — still writing —
# dies of SIGPIPE, and the whole condition goes FALSE even though a module WAS
# found. It misfires only once find's output outruns the pipe buffer, which is
# the worst possible failure mode.
#
# `cd` into the repo so the prune substrings test repo-RELATIVE paths: with an
# absolute "$repo" they would also test the checkout's own prefix, and a repo
# living under ~/vendor/ (or a workspace directory named .terraform) would filter
# every hit and be reported module-free.
local tf_hits
local tf_rc=0 policy_rc=0 test_rc=0 test_hits=""
# gather-opentofu-marker:begin
# THE PRUNED TREES, NAMED ONCE. `PRUNE_NAMES` is the single declaration; both
# forms below are DERIVED from it, so the `.tf.json` probe cannot drift into
# searching a different tree than the marker. That drift would be invisible: the
# probe must prune during its walk, so its expression sits OUTSIDE these
# sentinels where the 3-way parity oracle cannot reach it. Deriving both removes
# the second copy rather than documenting it.
#
#   PRUNE       — `grep -v` operands, for filtering a CAPTURED list. Correct for
#                 the `.tf` search, whose status only ever softens a NEGATIVE
#                 verdict, so post-filtering costs nothing.
#   PRUNE_FIND  — `find` primaries, for pruning DURING a walk. Required by the
#                 `.tf.json` probe, whose status SUPPRESSES a finding and so must
#                 describe only the region actually searched.
#
# The closing paren sits on its own line deliberately, and at column 0: the
# parity oracle reads this declaration with a `sed` range anchored on `^)`
# (`prunes_of`'s PRUNE_NAMES branch in tests/opentofu-topic-marker.bats), so a
# paren glued to the last name leaves that range unterminated and the extraction
# runs away to the end of the block. Relatedly, no comment in this block may
# spell the OTHER form's pattern flag followed by a placeholder word — that
# branch's regex would match it, and the oracle cannot tell prose from code.
local -a PRUNE_NAMES=(
  .terraform node_modules vendor .git
)
local -a PRUNE=() PRUNE_FIND=()
local _pn
for _pn in "${PRUNE_NAMES[@]}"; do
  PRUNE+=(-e "/${_pn}/")
  if (( ${#PRUNE_FIND[@]} )); then PRUNE_FIND+=(-o); fi
  PRUNE_FIND+=(-name "$_pn")
done
tf_hits="$(cd -- "$repo" 2>/dev/null || exit 125
           find . -name '*.tf' ! -type d 2>/dev/null)" && tf_rc=0 || tf_rc=$?
# 125 is the subshell's sentinel for a failed `cd`, which no find returns.
# Deliberately UNTESTED: the `[[ -r && -x ]]` gate above pre-empts it with its
# own exit 2 and a different message, so no seam reaches this branch — it is
# defence-in-depth for a path that becomes unenterable between the gate and the
# search. A test that could not tell its presence from its absence would be
# inert, which is worse than none.
(( tf_rc != 125 )) || { print -r -u2 -- "gather-opentofu-findings.zsh: cannot enter $repo"; exit 2 }
# the filter carries its OWN status — see the guard just past the sentinel
# `-F` is load-bearing, not decoration. The derived operands are plain path
# fragments (`/.terraform/`), so as a REGEX the `.` is a wildcard and this would
# prune `_terraform/`, `1terraform/`, `agit/` — strictly more than the marker,
# whose two copies spell the same tokens `'/\.terraform/'`. A repo whose only
# HCL lived under such a directory would then fire the marker and be answered
# all-false by the gather: the divergence the 3-way parity claim exists to
# prevent. Fixed-string matching is exactly equivalent to the escaped regex,
# without the derivation having to re-escape anything.
tf_hits="$(printf '%s\n' "$tf_hits" | grep -vF "${PRUNE[@]}")" && tf_filter_rc=0 || tf_filter_rc=$?
# gather-opentofu-marker:end
# The filter reads the captured string, not the filesystem — but that does NOT
# make it infallible, and `|| true` could not tell the difference if it were:
# `||` absorbs a status, it does not inspect one, so grep's OPERATIONAL error
# (exit 2 — a bad locale, an odd input line, ENOMEM) and a missing grep (127)
# were absorbed exactly like the intended no-match 1. `tf_hits` then went empty
# with `tf_rc` still 0, the refusal below did not fire, and the script emitted
# an all-false payload with exit 0 for a repo that ships HCL — "could not look"
# rendered as "looked and found nothing", the one outcome this script exists to
# refuse. Only 0 and 1 are a verdict; 1 is the genuine "everything was pruned"
# answer and must stay accepted. This guard sits OUTSIDE the marker sentinels
# deliberately: the parity oracles compare the detection rule, never the error
# handling, and the block has a line bound the prose would push it past.
(( tf_filter_rc == 0 || tf_filter_rc == 1 )) || {
  print -r -u2 -- "gather-opentofu-findings.zsh: the .tf prune filter did not complete (grep exit $tf_filter_rc) — refusing to emit an all-false payload"
  exit 2
}
# An unfinished search taints only the NEGATIVE verdict — the rule the sibling
# states and this one inherits: a hit is a hit whatever else failed, so a repo
# with modules AND one unreadable subdirectory is still detected. Only a
# came-up-empty answer from a search that did not finish refuses to answer,
# because there `find`'s exit 1 (an unreadable directory) and its exit 0 (a tree
# with no HCL) would otherwise be the same all-false payload.
#
# This ordering is load-bearing for the policy gate below: an unreadable
# `policies/conftest` makes THIS find exit 1 too, and refusing here would report
# it as ".tf search did not complete" — sending the reader at the module tree
# when the unreadable directory is the policy one, which has its own message.
# `tf_rc` is consulted twice: here, to refuse an EMPTY result, and — via this
# flag — to keep the ownership verdict from resting on a search that did not
# finish. With hits present but the walk incomplete, files never enumerated are
# indistinguishable from files that do not exist, so if the un-enumerated region
# held the only provider/backend/cloud block the classifier would assert "this
# is a reusable module library, which owns no state" from absence of evidence —
# invariant (2) inverted. In practice a non-pruned unreadable directory fails
# BOTH finds, so the `.tf.json` probe's own flag usually catches it; relying on
# that is relying on a coincidence between two independently-run searches, and
# it leaves the window where a directory becomes readable between them.
tf_search_incomplete="false"
(( tf_rc == 0 )) || tf_search_incomplete="true"
if [[ -z "$tf_hits" ]] && (( tf_rc != 0 )); then
  print -r -u2 -- "gather-opentofu-findings.zsh: the .tf search did not complete (find exit $tf_rc) — refusing to emit an all-false payload"
  exit 2
fi

# The four presence-detected tools are configured exactly when there is HCL to
# run them over. They are reported per-topic, not per-tool-binary: whether the
# maintainer has `tofu` on PATH says nothing about the repo under test, and the
# CI pipeline (#1162) is where they actually execute.
local has_tf="false"
if [[ -n "$tf_hits" ]]; then has_tf="true"; fi

# `probe <what> <regex> <text>` — a here-string grep whose status is INSPECTED
# rather than absorbed. `if grep -q …; then` cannot tell "searched, no match"
# (exit 1) from "the search did not run" (exit >=2, or a here-string zsh could
# not materialise because $TMPPREFIX is unwritable or full — a real hardened-CI
# shape): both render as FALSE, and every probe below has a direction in which
# a fabricated FALSE is a defect the maintainer cannot clear. `owns_state`
# false clears a repo holding plaintext state (invariant 2); `encrypted` false
# accuses one whose state IS encrypted (invariant 1). This is the same doctrine
# the file already applies to every grep over files and to the prune filter —
# "`||` absorbs a status, it does not inspect one" — and the here-string probes
# were the last sites that had not been converted.
# Returns 0 on a match, 1 on a clean no-match; refuses the whole run otherwise.
probe() {
  local what="$1" re="$2" text="$3" rc=0
  grep -Eq -- "$re" <<<"$text" || rc=$?
  (( rc == 0 || rc == 1 )) || {
    print -r -u2 -- "gather-opentofu-findings.zsh: could not scan the .tf sources for $what (grep exit $rc)"
    exit 2
  }
  return $rc
}

# --- state_encryption: the one built-in opinion, evaluated here ---------------
# Three invariants bind this classifier AND #1162's inline copy of it
# (ARCHITECTURE.md): (1) never emit a finding NO EDIT THE MAINTAINER CAN MAKE
# would clear — in particular, never report a repo whose state IS encrypted at
# rest in any accepted form VISIBLE IN THE SOURCES THE CHECK COULD READ. Read it
# in that unfixable sense, never absolutely: an unreadable `.tf` still yields a
# finding (with a caveat note), because repairing the permission clears it; (2) never clear a repo that owns unencrypted
# state, INCLUDING a root on the implicit local backend; (3) resolve every shape
# the same way in both consumers.
#
# OWNS-STATE is the gate, and it keys on ROOT-MODULE shape, never on backend
# absence alone. A reusable module library has nothing to encrypt — it is
# `source`d by someone else's root, whose backend covers the state — so the
# check reports nothing there. The discriminator is a `provider "…"` or
# `backend "…"` BLOCK: configuring a provider is a root-module concern (a
# consumed module inherits its caller's), while `required_providers` inside
# `terraform {}` is what a module library declares and is deliberately NOT
# matched. A root that declares a provider but no backend runs on the implicit
# LOCAL backend and owns a plaintext terraform.tfstate — invariant (2) — so it
# is not exempt.
local owns_state="false" encrypted="false"
local state_encryption_findings="[]"
# THE `.tf.json` BLIND SPOT (ARCHITECTURE.md records it). The charter owns the
# JSON syntax; this classifier reads only HCL. So a repo whose backend or
# encryption lives in `backend.tf.json` would be answered from the HCL alone —
# and BOTH questions are affected, which is why this is probed once, up front,
# rather than inside the encryption branch: a `.tf.json` can carry the root
# block as easily as the encryption block.
#
# `$PRUNE_FIND` is DERIVED from the same `PRUNE_NAMES` as the marker's `$PRUNE`,
# so this probe and the `.tf` search always cover the same trees — there is no
# second copy to keep in step.
# PRUNED INSIDE THE WALK, unlike the `.tf` search above. That search applies the
# prune set to the captured string, which is safe there because its status only
# ever softens a NEGATIVE verdict. Here the status softens a POSITIVE one — it
# suppresses the plugin's single built-in finding — so a `find` that tripped over
# a permission error inside `.terraform/` or `node_modules/` (trees this marker
# ignores by design) must not count as "could not rule out". Pruning in the walk
# makes the status describe only the region actually searched.
local tfjson_hits="" tfjson_rc=0 tfjson_incomplete="false"
tfjson_hits="$(cd -- "$repo" 2>/dev/null || exit 125
               find . \( "${PRUNE_FIND[@]}" \) -prune \
                 -o -name '*.tf.json' ! -type d -print 2>/dev/null)" && tfjson_rc=0 || tfjson_rc=$?
(( tfjson_rc != 125 )) || { print -r -u2 -- "gather-opentofu-findings.zsh: cannot enter $repo"; exit 2 }
# TWO flags, never one. Collapsing "a .tf.json exists" and "the search could not
# finish" into a single present/absent made every note claim the repo ships JSON
# sources it may not ship — and the notes are rendered verbatim to a human, so a
# wrong cause sends them hunting for files that are not there. Both still
# suppress the finding (invariant 1 is the unfixable direction), but they are
# REPORTED apart.
if (( tfjson_rc != 0 )); then tfjson_incomplete="true"; fi
if [[ "$has_tf" == "true" ]]; then
  local tf_text=""
  # Read the non-pruned files ONLY, from the filtered list — never a fresh
  # recursive grep, which would re-admit .terraform/ and vendored trees and
  # clear a repo on a cached provider's own HCL.
  # `-type f` on the read, though the MARKER deliberately uses `! -type d`: the
  # marker counts a symlinked module (correct — it is HCL the repo ships), but
  # `cat` over that same list dies on a dangling symlink and BLOCKS FOREVER on a
  # FIFO, and one broken link must not put the whole topic in
  # `unsupported_topics`.
  #
  # THE SKIP IS SAFE FOR ONE QUESTION AND NOT THE OTHER, and conflating them was
  # a real defect. For "is it encrypted?" an unreadable module can only fail to
  # satisfy the check, never clear it — conservative. For "does it own state?"
  # the opposite holds: if the only file declaring `provider`/`backend`/`cloud`
  # is the unreadable one, `owns_state` stays false and the repo is reported a
  # module library that owns no state — a positive claim about a search that did
  # not happen, clearing a repo that may own PLAINTEXT state (invariant 2). So
  # the count is kept and the verdict is softened below rather than asserted.
  local -a tf_readable=()
  local -i tf_skipped=0
  local f
  for f in ${(f)tf_hits}; do
    if [[ -f "$repo/$f" && -r "$repo/$f" ]]; then
      # an `if`, not a trailing `&&`: the doctrine this script states twice, and
      # this is the loop-body's final command, so the AND form makes a false
      # test the `for` compound's own status
      tf_readable+=("$repo/$f")
    else
      (( ++tf_skipped ))
    fi
  done
  # EVERY .tf unreadable is not a softenable verdict — there is nothing to
  # classify at all, and reporting "module library" would be pure fabrication
  (( ${#tf_readable[@]} > 0 )) || {
    print -r -u2 -- "gather-opentofu-findings.zsh: every .tf source under $repo is unreadable — refusing to classify the tree"
    exit 2
  }
  # streamed rather than one `cat` exec: a large monorepo's hit list exceeds
  # ARG_MAX, and that would exit 2 over a tree the script could in fact read
  # `awk 1`, not `cat`. `cat` concatenates byte-for-byte, so a `.tf` with no
  # trailing newline glues its last line onto the NEXT file's first line — and
  # every probe below is `^`-anchored, so that first line becomes invisible. A
  # `provider "aws" {` swallowed that way makes a root module read as a library
  # (invariant 2); a swallowed `encryption {` accuses an encrypted repo
  # (invariant 1). Unformatted repos are exactly this topic's audience, since
  # `tofu fmt` is only presence-detected here. `awk 1` terminates every output
  # record with ORS, repairing the join, and the xargs chunk boundary — another
  # place the last/first pair meets — is repaired with it.
  local read_rc=0
  tf_text="$(printf '%s\0' "${tf_readable[@]}" | xargs -0 awk 1 2>/dev/null)" && read_rc=0 || read_rc=$?
  (( read_rc == 0 )) || {
    print -r -u2 -- "gather-opentofu-findings.zsh: could not read the .tf sources under $repo (xargs/awk exit $read_rc)"
    exit 2
  }
  # EVERY probe below is a here-string, never `print … | grep -q`. Under
  # `set -o pipefail` the piped form INVERTS: `grep -q` exits at its first match,
  # the writer dies of SIGPIPE (141), and the pipeline's status becomes 141 — so
  # a genuine match reads as FALSE once the text outruns the pipe buffer (~64 KiB,
  # i.e. any real module tree). That is the same hazard the marker's
  # capture-before-filter comment describes, and it is fatal here in both
  # directions: a missed `provider` block downgrades a root to a module library
  # and skips the whole opinion (invariant 2), while a missed `encryption` block
  # accuses an encrypted repo (invariant 1). A here-string is not a pipeline, so
  # there is no writer whose status pipefail can observe.
  if probe "a root-module provider or backend block" '^[[:space:]]*(provider|backend)[[:space:]]+"' "$tf_text"; then
    owns_state="true"
  fi
  # ...and a `cloud {}` block is a root too: HCP Terraform holds the state.
  if probe "a cloud block" '^[[:space:]]*cloud[[:space:]]*\{' "$tf_text"; then
    owns_state="true"
  fi

  if [[ "$owns_state" == "true" ]]; then
    # ENCRYPTED-AT-REST, in whichever form the repo's dialect provides. The
    # OpenTofu-native `encryption` block is only one of them; demanding it
    # unconditionally would fire permanently and unfixably on every
    # Terraform-dialect repo, including repos whose state IS encrypted, which
    # is invariant (1). The accepted forms, and why each clears:
    #   - `encryption { … }` inside `terraform {}` — OpenTofu state encryption.
    #   - S3 backend `encrypt = true`, `kms_key_id`, `sse_customer_key`.
    #   - GCS backend `encryption_key` / `kms_encryption_key`.
    #   - `azurerm` backend — Azure Storage encrypts at rest unconditionally and
    #     offers no flag to scan for. This is the "platform encrypts
    #     unconditionally" shape ARCHITECTURE.md leaves to this classifier;
    #     requiring a flag that does not exist would be invariant (1) again.
    #   - a `cloud {}` block — HCP Terraform encrypts state at rest.
    # A `local` backend, or no backend at all, clears NOTHING: that is exactly
    # invariant (2).
    # A TEXTUAL scan over the concatenated sources, deliberately NOT scoped to
    # the enclosing backend block — this gather does not parse HCL, and a
    # half-parser that guessed block boundaries would be wrong in the direction
    # that matters (invariant 1). ARCHITECTURE.md records the same rule so
    # #1162's inline copy scans identically; the known cost is that an unrelated
    # `kms_key_id` elsewhere in the tree clears the check, which is the
    # conservative direction for a check whose false positives are unfixable.
    # Here-strings throughout, for the pipefail reason given above.
    if probe "an OpenTofu encryption block" '^[[:space:]]*encryption[[:space:]]*\{' "$tf_text"; then
      encrypted="true"
    elif probe "a backend-level encryption flag" '^[[:space:]]*(encrypt[[:space:]]*=[[:space:]]*true|kms_key_id[[:space:]]*=|sse_customer_key[[:space:]]*=|encryption_key[[:space:]]*=|kms_encryption_key[[:space:]]*=)' "$tf_text"; then
      encrypted="true"
    elif probe "a platform-encrypted backend" '^[[:space:]]*(backend[[:space:]]+"azurerm"|cloud[[:space:]]*\{)' "$tf_text"; then
      encrypted="true"
    fi
    if [[ "$encrypted" != "true" ]] && { [[ -n "$tfjson_hits" ]] || [[ "$tfjson_incomplete" == "true" ]] }; then
      # the CAUSE is named from what actually held, never as a fixed sentence:
      # a note claiming .tf.json files on a repo that ships none sends the
      # reader hunting for files that are not there, and Phase 9 renders this
      # verbatim
      # an ARRAY, like the ownership note below: both conditions can hold at once
      # (a repo that ships backend.tf.json AND has one locked subdirectory), and
      # an if/else would report only the first — telling the reader the blind
      # spot is bounded by files they can go look at when more may never have
      # been enumerated
      local -a why=()
      [[ -z "$tfjson_hits" ]] || why+=("it also ships .tf.json sources this check cannot parse")
      [[ "$tfjson_incomplete" != "true" ]] || why+=("the .tf.json search could not complete, so their presence cannot be ruled out")
      # `tf_skipped` belongs here too — this branch is reachable with unreadable
      # `.tf` files, and naming only the JSON sends the reader to inspect those
      # while the permission problem goes unfixed and the check stays blind on
      # re-run. The other two branches already disclose it.
      (( tf_skipped == 0 )) || why+=("$tf_skipped .tf file(s) it could not read")
      [[ "$tf_search_incomplete" != "true" ]] || why+=("a .tf search that could not complete, so a file it never enumerated may configure encryption")
      notes+=("state_encryption: this repo owns state and no encryption is configured in the .tf sources this check could read, but ${(j:, and :)why} — reporting nothing rather than a finding that editing the HCL could not clear")
    elif [[ "$encrypted" != "true" ]]; then
      # EXACTLY ONE finding, repo-wide — the defect is the repo's state
      # configuration, not each file that fails to mention encryption.
      state_encryption_findings="$(jq -n '[{
        id: "state_encryption:unencrypted-state",
        tool: "state_encryption",
        type: "unencrypted_state",
        severity: "high",
        message: "This repo owns OpenTofu/Terraform state but nothing configures encryption at rest. State holds provider credentials, generated passwords and connection strings in plaintext.",
        fix: "Configure state encryption in whichever form your tool provides: an OpenTofu `terraform { encryption { … } }` block, or backend-level encryption (S3 `encrypt = true` plus a `kms_key_id`, GCS `encryption_key`, and the like).",
        files: ["*.tf"]
      }]')" || { print -r -u2 -- "gather-opentofu-findings.zsh: could not encode the state_encryption finding"; exit 2; }
      # The finding STANDS on an incomplete read — an unreadable `.tf` is a
      # defect the maintainer can clear (fix the permission and re-run), unlike
      # a `.tf.json` this check can never parse, which is why only the latter
      # suppresses. But the payload must SAY the read was partial: without this
      # the reader gets a high-severity accusation with no hint that a file
      # which may configure encryption went unread.
      [[ "$tf_search_incomplete" != "true" ]] || notes+=("state_encryption: this finding was reached over a .tf search that did not complete — a file it never enumerated may configure encryption")
      (( tf_skipped == 0 )) || notes+=("state_encryption: this finding was reached over $tf_skipped .tf file(s) the check could not read — if one of them configures encryption, fix the permissions and re-run before acting on it")
    fi
  elif (( tf_skipped > 0 )) || [[ -n "$tfjson_hits" ]] || [[ "$tfjson_incomplete" == "true" ]] \
       || [[ "$tf_search_incomplete" == "true" ]]; then
    # NOT the module-library claim. `owns_state` is false only over what could
    # be READ, and something in this tree could not be: an unreadable `.tf`, or
    # a `.tf.json` this classifier does not parse. Asserting "owns no state"
    # from that would be an absence of evidence stated as a verified fact —
    # exactly what clears a repo running on the implicit local backend
    # (invariant 2). Report what is actually known instead.
    # the reason list is BUILT from the conditions that held, for the same
    # reason as the note above: stating all three unconditionally renders
    # "0 unreadable .tf" and asserts .tf.json files on a repo that ships none
    local -a why=()
    (( tf_skipped == 0 )) || why+=("$tf_skipped .tf file(s) it could not read")
    [[ -z "$tfjson_hits" ]] || why+=(".tf.json sources it cannot parse")
    [[ "$tfjson_incomplete" != "true" ]] || why+=("a .tf.json search that could not complete")
    [[ "$tf_search_incomplete" != "true" ]] || why+=("a .tf search that could not complete")
    notes+=("state_encryption: no root-module block (provider, backend or cloud) was found in the .tf sources this check could read, but the tree has ${(j:, and :)why} — the ownership question is UNRESOLVED, so nothing is reported either way")
  else
    notes+=("state_encryption: no root module declares a provider, backend or cloud block — this is a reusable module library, which owns no state, so the check reports nothing here")
  fi
fi

# --- policy: the repo's own rules, matched as a GLOB --------------------------
# `-L` (not `-H`) on both finds below. `-H` follows only the COMMAND-LINE
# symlink, so a symlinked policies/conftest is searched but a symlinked policy
# FILE inside a real one is type `l` and `-type f` drops it — reporting a
# symlink-shared policy set as undeclared, and a symlinked *_test.rego as
# missing coverage (a false untested-policies accusation).
local policy_dir="$repo/policies/conftest"
local has_policies="false"
local policy_hits=""
if [[ -d "$policy_dir" ]]; then
  # the same rule as the repo gate, one level deeper: an unreadable policy
  # directory would fail into `2>/dev/null || true` and emit "no policies
  # declared" for a repo that declared several — the silent skip the glob
  # contract exists to prevent
  [[ -r "$policy_dir" && -x "$policy_dir" ]] || { print -r -u2 -- "gather-opentofu-findings.zsh: policies/conftest exists but is not readable"; exit 2; }
  # and the same rule one level deeper still: the gate above proves the TOP
  # directory readable, not every subdirectory beneath it. Unlike a marker with
  # two halves there is no fallback here, so ANY non-zero find is fatal.
  policy_hits="$(find -L "$policy_dir" -type f -name '*.rego' 2>/dev/null)" \
    && policy_rc=0 || policy_rc=$?
  (( policy_rc == 0 )) || { print -r -u2 -- "gather-opentofu-findings.zsh: could not list $policy_dir (find exit $policy_rc)"; exit 2; }
  if [[ -n "$policy_hits" ]]; then has_policies="true"; fi
fi
if [[ "$has_policies" != "true" ]]; then
  notes+=("policy: no policies declared at policies/conftest/**/*.rego — step skipped, not failed")
fi

# --- policy evaluation: a declared set that cannot be evaluated NEVER skips ----
# The FOUR states ARCHITECTURE.md enumerates, as FINDINGS rather than step
# failures, because a gather has no step to fail. The fourth — a conftest that
# is not available to evaluate them at all — is scoped in ARCHITECTURE.md to
# this gather, which unlike the rendered job cannot assume its toolchain.
# Reporting an empty `policy` list for any of them would be the
# green-over-unenforced state.
local policy_findings="[]"
local policy_tests_findings="[]"
if [[ "$has_policies" == "true" ]]; then
  local -a pf=()
  # Resolved to an ABSOLUTE path, not left as a bare name. It is executed inside
  # a `cd -- "$repo"` subshell, so a bare name would be re-resolved from the
  # repo's directory — and any relative PATH entry (`.`, `bin`,
  # `node_modules/.bin`, common under direnv/nvm) would then select a different
  # binary, or none. Resolving once here also closes the window where conftest
  # is removed between this probe and the run.
  # `command -v` alone is NOT enough: it prints the path AS FOUND VIA PATH, so a
  # relative PATH entry yields a relative path — precisely the direnv/nvm shape
  # this comment cites. Re-resolved from the repo's directory that would either
  # fail to exec or, far worse, run a `bin/conftest` belonging to the repo under
  # test: executing an untrusted binary out of a third-party checkout during a
  # read-only gather. `:A` absolutises while still in the original CWD, and the
  # `-x` test sends a non-executable resolution down the unavailable path rather
  # than into an exec failure.
  local conftest_bin=""
  conftest_bin="$(command -v conftest 2>/dev/null || true)"
  if [[ -n "$conftest_bin" ]]; then conftest_bin="${conftest_bin:A}"; fi
  if [[ -n "$conftest_bin" && ! -x "$conftest_bin" ]]; then conftest_bin=""; fi

  if [[ -z "$conftest_bin" ]]; then
    pf+=("$(jq -n --arg v "$CONFTEST_VERSION" '{
      id: "policy:conftest-unavailable",
      tool: "policy",
      type: "policy_not_evaluated",
      severity: "high",
      message: ("policies/conftest/ declares policies but conftest is not on PATH, so they were not evaluated. A declared policy set that cannot be evaluated never skips — reporting it clean would be a green check over unenforced policies."),
      fix: ("Install conftest " + $v + " (the version this gather and the rendered pipeline both pin) and re-run maintenance."),
      files: ["policies/conftest/"]
    }')") || { print -r -u2 -- "gather-opentofu-findings.zsh: could not encode the conftest-unavailable finding"; exit 2; }
  else
    # A version MISMATCH is a note, never a finding: the consumer repo has done
    # nothing wrong, and the drift is in the maintainer's local toolchain. It
    # still has to be said, because Rego evaluation and the built-in function
    # set move between releases, so a verdict from another version is not the
    # verdict the pipeline will reach.
    # Read the CONFTEST line specifically, not the first version-looking token in
    # the whole output. `conftest --version` prints two lines —
    # `Conftest: v0.69.0` then `OPA: v1.4.2` — so a scan over both would fall
    # through to OPA's version whenever Conftest's own is unparseable (a dev
    # build prints `Conftest: vdev`), and then compare OPA's version against
    # this gather's conftest pin: a spurious mismatch note on every run, naming
    # two versions that were never meant to be compared.
    local conftest_ver=""
    conftest_ver="$("$conftest_bin" --version 2>/dev/null \
      | grep -m1 -E '^[[:space:]]*Conftest:' \
      | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -n "$conftest_ver" && "$conftest_ver" != "$CONFTEST_VERSION" ]]; then
      notes+=("policy: evaluated with conftest $conftest_ver, but this gather pins $CONFTEST_VERSION — Rego evaluation moves between releases, so re-run pinned before acting on a policy verdict")
    fi

    # (1) A policy in a package the step never invokes. Conftest's default
    #     namespace is `main`; a rule in another package is silently matched by
    #     nothing, so it passes everything — the untested-policy defect one
    #     level up. A repo that names its namespaces in conftest.toml has said
    #     which ones it invokes, so it is not accused.
    # STATUS-CHECKED like its two siblings below. `[[ -f ]]` passes for a
    # conftest.toml that exists but cannot be READ, and a blanket `|| true` then
    # erases grep's exit 2 — so a repo that DID declare its namespaces gets
    # accused of shipping unevaluated packages, a high-severity false positive
    # produced by a read that never happened.
    local declared_ns="" ns_toml_rc=0
    if [[ -f "$repo/conftest.toml" ]]; then
      declared_ns="$(grep -E '^[[:space:]]*namespaces[[:space:]]*=' -- "$repo/conftest.toml" 2>/dev/null)" \
        && ns_toml_rc=0 || ns_toml_rc=$?
      (( ns_toml_rc == 0 || ns_toml_rc == 1 )) || {
        print -r -u2 -- "gather-opentofu-findings.zsh: could not read $repo/conftest.toml (grep exit $ns_toml_rc)"
        exit 2
      }
    fi
    if [[ -z "$declared_ns" ]]; then
      local stray_pkgs="" pkg_lines="" ns_rc=0 filt_rc=0
      # NO `xargs`. It maps EVERY grep exit in 1..125 to a single status, so
      # grep's no-match (1) and grep's operational error (2 — an unreadable
      # `.rego`, the case this check exists to refuse) arrive indistinguishable.
      # Measured on this platform both come back as 1; GNU xargs reports 123 for
      # both. Either way accepting that status re-admits the failure, which made
      # the first attempt at this guard cosmetic. Calling grep DIRECTLY on the
      # file array keeps 1 and 2 distinct, which is the whole point.
      #
      # THE COST IS ARG_MAX, and it is accepted rather than overlooked: a policy
      # set large enough to overflow the exec argument list makes this grep fail
      # to exec, which the guard below turns into exit 2 (refuse) rather than a
      # fabricated verdict. Refusing on an implausibly large policy set beats
      # losing the 1-vs-2 distinction on every ordinary one.
      local -a policy_files=(${(f)policy_hits})
      pkg_lines="$(grep -hE '^[[:space:]]*package[[:space:]]+' -- "${policy_files[@]}" 2>/dev/null)" \
        && ns_rc=0 || ns_rc=$?
      (( ns_rc == 0 || ns_rc == 1 )) || {
        print -r -u2 -- "gather-opentofu-findings.zsh: could not scan the declared policies for their package (grep exit $ns_rc)"
        exit 2
      }
      # `main` is matched EXACTLY, with no `main.*` carve-out: conftest's default
      # namespace is the exact document `data.main`, as its own --trace output
      # shows verbatim (`query: data.main.deny`, docs/options.md), so a rule at
      # `data.main.buckets.deny` is a different document that query never
      # reaches. An earlier revision exempted `main.*` and its own fix text then
      # recommended that shape — a green check over rules nothing evaluates,
      # which is the exact state ARCHITECTURE.md's "a declared set Conftest
      # CANNOT EVALUATE never skips" rule forbids.
      # the FILTER half gets its own status too: it reads the captured string, so
      # a failure here is a missing/behaving-badly awk or sort rather than an
      # unreadable file — but collapsing it to "" would under-report exactly as
      # the read half would.
      #
      # ONE awk stage, not sed|grep|grep: zsh's pipefail reports the RIGHTMOST
      # non-zero status, and both greps return 1 on an emptied stream. So a sed
      # that FAILED (exit 2) was masked by the downstream grep's no-match 1,
      # which the guard accepts — a repo whose entire Rego set sits outside
      # `main` was then reported with an empty `policy` array, the
      # green-over-unenforced state ARCHITECTURE.md's "a declared set Conftest
      # CANNOT EVALUATE never skips" rule forbids. Verified empirically: with
      # sed exiting 2 the old pipeline reported 1. awk and sort both exit 0 on
      # an empty result, so there is no no-match status left to shadow an error
      # and the guard can be STRICT.
      stray_pkgs="$(printf '%s\n' "$pkg_lines" | awk '
        { sub(/^[[:space:]]*package[[:space:]]+/, "") }
        $0 != "" && $0 !~ /^main([[:space:]]|$)/ { print }
      ' | sort -u)" && filt_rc=0 || filt_rc=$?
      (( filt_rc == 0 )) || {
        print -r -u2 -- "gather-opentofu-findings.zsh: could not filter the declared policies' packages (exit $filt_rc)"
        exit 2
      }
      if [[ -n "$stray_pkgs" ]]; then
        # compute the flattened list BEFORE the jq call: a substitution nested in
        # an `--arg` is not covered by the `|| { … exit 2 }` that guards jq, so a
        # failing `tr` would ship a high-severity accusation naming no packages
        # at all ("…they pass everything silently: .")
        local pkgs_flat
        pkgs_flat="$(printf '%s' "$stray_pkgs" | tr '\n' ' ')" || {
          print -r -u2 -- "gather-opentofu-findings.zsh: could not format the stray-package list"; exit 2; }
        pf+=("$(jq -n --arg pkgs "$pkgs_flat" '{
          id: "policy:package-outside-invoked-namespace",
          tool: "policy",
          type: "policy_not_evaluated",
          severity: "high",
          message: ("These Rego packages sit outside the namespace conftest invokes by default (`main`), so nothing evaluates them and they pass everything silently: " + ($pkgs | rtrimstr(" ")) + "."),
          fix: "Move the rules into `main` itself — a `main.*` subpackage is NOT invoked by the default query — or declare the namespaces in a conftest.toml so the step invokes them explicitly.",
          files: ["policies/conftest/"]
        }')") || { print -r -u2 -- "gather-opentofu-findings.zsh: could not encode the stray-namespace finding"; exit 2; }
      fi
    fi

    # (2) A .rego that fails to compile, and (3) a failing `conftest verify`
    #     run. Both surface through `verify`, which compiles the modules before
    #     running their tests — so the two are told apart by what it SAID, not
    #     by a separate parse pass conftest does not offer.
    # Run conftest INSIDE the repo, with a repo-relative policy path. conftest
    # resolves its own conftest.toml (and any relative defaults in it) from the
    # CWD, so running it here would ignore the repo's config — the same config
    # the namespace check above reads from `$repo/conftest.toml`, keying the two
    # halves of one decision off different directories — and would apply a
    # conftest.toml sitting in the maintainer's CWD to a foreign repo's policies.
    # `2>&1` because conftest reports compile errors and verify failures on
    # STDERR; without it the classifier below sees an empty string and every
    # compile error is misreported as a failing test.
    local verify_out="" verify_rc=0
    verify_out="$(cd -- "$repo" 2>/dev/null || exit 125
                  "$conftest_bin" verify --policy policies/conftest 2>&1)" || verify_rc=$?
    # 125 is the `cd` subshell's sentinel, and for the two `find` subshells it is
    # unambiguous because no find returns it. conftest is NOT a bare binary in
    # the same way: it is routinely a shim or wrapper (mise/asdf, `docker run` —
    # which returns 125 when it cannot start a container — a `direnv exec`
    # forwarding a child status), so a bare `== 125` would print "cannot enter
    # <repo>" and exit 2 for a broken WRAPPER, pointing the reader at a
    # directory-permission problem that does not exist while discarding the
    # other six tool keys and the whole state_encryption verdict. Confirm the
    # repo really is unenterable before claiming so; otherwise let the status
    # fall through to the 126/127 and generic finding arms below.
    if (( verify_rc == 125 )) && ! [[ -d "$repo" && -r "$repo" && -x "$repo" ]]; then
      print -r -u2 -- "gather-opentofu-findings.zsh: cannot enter $repo"
      exit 2
    fi
    # 127 is "could not execute", not "the tests failed". It needs its own arm —
    # otherwise it renders as a high-severity policy_tests_failing finding whose
    # evidence reads "command not found", sending the reader at the repo's Rego
    # over a toolchain problem. But the arm is a FINDING, never an exit: the
    # header rule is that a missing conftest is not an exit code, because
    # exiting would discard the other six tool keys and the whole
    # state_encryption verdict over one unexecutable binary. This is the same
    # "declared set could not be evaluated" state as an absent conftest, so it
    # takes the same carrier.
    if (( verify_rc == 126 || verify_rc == 127 )); then
      # report the code that ACTUALLY occurred, not the literal "126/127": they
      # are different repairs (a noexec mount or wrong-architecture build vs a
      # dead shim), and the shell's own diagnostic — captured by the 2>&1 on the
      # verify call — is the only thing that distinguishes them, so it is
      # forwarded rather than dropped. A dangling symlink is deliberately NOT
      # listed: PATH lookup tests X_OK through the link, so `command -v` never
      # returns one and the -x gate above would route it to the not-on-PATH
      # branch anyway. For the same reason the message says conftest RESOLVED
      # rather than "is on PATH" — by this point that is no longer a claim this
      # script can still stand behind.
      # same rule as the stray-package list: nest nothing fallible in `--arg`.
      # The fallback is the FULL text rather than nothing — this branch's whole
      # value is the forwarded diagnostic, so losing it defeats the finding.
      local verify_tail
      verify_tail="$(tail -5 <<<"$verify_out")" || verify_tail="$verify_out"
      pf+=("$(jq -n --arg rc "$verify_rc" --arg out "$verify_tail" '{
        id: "policy:conftest-unavailable",
        tool: "policy",
        type: "policy_not_evaluated",
        severity: "high",
        message: ("policies/conftest/ declares policies but conftest resolved to a binary that could not be executed (exit " + $rc + "), so they were not evaluated. A declared policy set that cannot be evaluated never skips — reporting it clean would be a green check over unenforced policies." + (if $out == "" then "" else " The system said: " + $out end)),
        fix: "Repair the conftest installation — a shim whose interpreter is gone or a binary removed between resolution and the run (exit 127), or a binary this machine cannot execute such as a wrong-architecture build or one on a noexec mount (exit 126) — and re-run maintenance.",
        files: ["policies/conftest/"]
      }')") || { print -r -u2 -- "gather-opentofu-findings.zsh: could not encode the conftest-unexecutable finding"; exit 2; }
    elif (( verify_rc != 0 )); then
      # single quotes throughout: these strings carry literal backticks for the
      # markdown the finding renders as, and a double-quoted backtick in zsh is
      # command substitution — the message would run `conftest verify` a second
      # time and splice its output into its own text.
      local kind='policy_tests_failing'
      local msg='`conftest verify` failed over policies/conftest/, so the declared policy set is not known-good.'
      local fixmsg='Run `conftest verify --policy policies/conftest` and fix the failing tests.'
      # here-string, for the pipefail/SIGPIPE reason given at the classifier
      # above: a compile error is reported near the TOP of verify's output, so
      # the piped form would match, take SIGPIPE, and read false — merging the
      # two states ARCHITECTURE.md deliberately separates.
      if probe "a Rego compile error in conftest's output" 'rego_parse_error|rego_compile_error|parse error|compile error' "${verify_out:l}"; then
        kind='policy_does_not_compile'
        msg='A Rego file under policies/conftest/ does not compile, so the declared policy set cannot be evaluated at all.'
        fixmsg='Fix the Rego compile error reported by `conftest verify --policy policies/conftest`.'
      fi
      # the EVIDENCE is selected per branch. A compile error is reported near the
      # TOP of verify's output (which is why the classifier greps the whole of
      # it), so `tail -20` would quote 20 unrelated trailing lines and omit the
      # error the reader is asked to fix. The failing-test summary, by contrast,
      # IS at the bottom.
      # NEITHER arm may pipe INTO a reader that exits early: `head -20` closes the
      # pipe on its 20th line, the writer takes SIGPIPE, and `pipefail` makes 141
      # the assignment's status, which `set -e` turns into an exit code this
      # script's header does not document — no payload, no message, and the
      # orchestrator records a nameless `gather failed:` for a topic whose verdict
      # was fully computed. Reproduced: 5000 matching lines exits 141. So grep
      # does its own limiting with `-m20` (BSD and GNU both), and tail reads a
      # here-string. `|| true` is then load-bearing on the grep: with no `head`
      # to mask it, a no-match exit 1 would trip `set -e` on its own.
      local evidence
      if [[ "$kind" == "policy_does_not_compile" ]]; then
        # NOT `|| true`: this branch is entered only because the classifier
        # already matched the same alternation over the same text, so a no-match
        # is impossible here and the only status `|| true` could absorb is a real
        # failure — leaving a does-not-compile accusation whose entire
        # evidentiary value is gone ("conftest said: "). Fall back to the full
        # text, as the 126/127 arm does, for the same reason.
        evidence="$(grep -m20 -iE 'rego_parse_error|rego_compile_error|parse error|compile error' <<<"$verify_out")" || evidence="$verify_out"
      else
        evidence="$(tail -20 <<<"$verify_out")" || evidence="$verify_out"
      fi
      pf+=("$(jq -n --arg t "$kind" --arg m "$msg" --arg f "$fixmsg" \
                    --arg out "$evidence" '{
        id: ("policy:" + $t),
        tool: "policy",
        type: $t,
        severity: "high",
        message: ($m + " conftest said: " + $out),
        fix: $f,
        files: ["policies/conftest/"]
      }')") || { print -r -u2 -- "gather-opentofu-findings.zsh: could not encode the verify finding"; exit 2; }
    fi
  fi

  if (( ${#pf[@]} > 0 )); then
    policy_findings="$(printf '%s\n' "${pf[@]}" | jq -s '.')" \
      || { print -r -u2 -- "gather-opentofu-findings.zsh: could not encode the policy findings"; exit 2; }
  fi

  # --- policy_tests: fixtures for those policies ------------------------------
  # Recursive, and BOTH the file-name and rule-name conventions: `conftest
  # verify` runs rules whose name begins `test_`, and repos group them either in
  # *_test.rego files or beside the policy. Missing either would report a tested
  # policy set as untested, which is a false accusation rather than a missed one
  # and trains users to ignore this finding.
  #
  # The unchecked find here would be the costliest of the three: its empty result
  # does not merely skip a step, it FABRICATES a high-severity finding accusing
  # the repo of shipping untested policies.
  test_hits="$(find -L "$policy_dir" -type f -name '*_test.rego' 2>/dev/null)" \
    && test_rc=0 || test_rc=$?
  # Deliberately UNREACHABLE, and recorded rather than left to be re-filed as an
  # untested branch: this is the SAME `find -L "$policy_dir"` traversal as the
  # `*.rego` listing above, differing only in `-name`, and that one already exits
  # 2 on any non-zero status. Every seam that could fail this find (an unreadable
  # subdirectory, a symlink loop, a vanished directory) fails the first one
  # first. It is defence-in-depth for a permission change BETWEEN the two finds,
  # and a test that could not tell its presence from its absence would be inert
  # — the same call the 125 `cd` sentinel above records.
  (( test_rc == 0 )) || { print -r -u2 -- "gather-opentofu-findings.zsh: could not list policy test fixtures under $policy_dir (find exit $test_rc)"; exit 2; }
  if [[ -z "$test_hits" ]]; then
    # second convention: a `test_` rule in any declared .rego.
    # STATUS-CHECKED for the same reason the `find` above it is, and with more at
    # stake: a blanket `|| true` makes an unreadable `.rego` (grep 2; historically xargs 123, before this scan called grep directly)
    # indistinguishable from "no test_ rule anywhere", and the gather then
    # FABRICATES the high-severity untested-policies finding against a repo whose
    # tests it simply could not read. 1 and 123 are genuine no-match statuses
    # here; anything else is a failed scan and refuses rather than accuses.
    # grep DIRECTLY, never through xargs — same reason as the namespace scan
    # above: xargs collapses grep's no-match and grep's read error to one status,
    # and accepting it would let an unreadable `*_test.rego` fabricate this very
    # finding, which is the outcome the comment above calls the costliest.
    # Same ARG_MAX trade-off as the package scan above, and accepted for the same
    # reason: a failed exec refuses with a named message, it does not fabricate.
    local trule_rc=0
    local -a trule_files=(${(f)policy_hits})
    test_hits="$(grep -lE '^[[:space:]]*test_[A-Za-z0-9_]*([[:space:]]*(\{|:?=)|[[:space:]]+if([[:space:]]|$))' -- "${trule_files[@]}" 2>/dev/null)" \
      && trule_rc=0 || trule_rc=$?
    (( trule_rc == 0 || trule_rc == 1 )) || {
      print -r -u2 -- "gather-opentofu-findings.zsh: could not scan the declared policies for test_ rules (grep exit $trule_rc)"
      exit 2
    }
  fi
  if [[ -z "$test_hits" ]]; then
    policy_tests_findings="$(jq -n '[{
      id: "policy_tests:untested-policies",
      tool: "policy_tests",
      type: "untested_policies",
      severity: "high",
      message: "policies/conftest/ declares policies but has no conftest verify tests. An untested policy usually matches nothing, so it passes everything silently — and `conftest verify` exits green over a test-less directory, so the pipeline is silent on it too.",
      fix: "Add *_test.rego files beside the policies with `test_` rules asserting at least one input each policy must DENY and one it must ALLOW, and run `conftest verify --policy policies/conftest`.",
      files: ["policies/conftest/"]
    }]')" || { print -r -u2 -- "gather-opentofu-findings.zsh: could not encode the policy_tests finding"; exit 2; }
  fi
fi

# --- emit ---------------------------------------------------------------------
# ALWAYS carry the presence-detection note. The orchestrator reads an empty topic
# plan with a NON-empty tooling_configured as "this topic is clean — its tools ran
# and found nothing", which for the four presence-detected keys would be a lie:
# nothing ran. The note is the only thing that reaches the Phase 9 summary and can
# contradict that rendering. It names the four deliberately, so the reader is not
# left assuming state_encryption and the two policy keys are presence-detected
# too: the tail names those THREE individually as the EVALUATING keys, which is
# the 4/3 split docs/reference/plugins.md states.
# The tail states WHICH KEYS ARE EVALUATING KEYS — a static property of this
# gather — and deliberately NOT what each concluded on this run. An earlier
# version reported per-run outcomes and needed a flag per branch; every review
# round then found another branch where it over- or under-claimed (a suppressed
# verdict, an unresolved one, a policy set that failed to compile, a conftest
# that could not run, `policy_tests` which evaluates without conftest at all).
# The per-run story is already told, precisely, by the findings and the notes
# above; duplicating it here in one sentence could only ever be an approximation
# of it. So this half answers the question the first half poses — "which tools
# did NOT run here?" — and points at the rest.
notes+=("format/validate/lint/misconfiguration: presence-detected only — tofu fmt, tofu validate, tflint and trivy config run in the CI pipeline (#1162), not in this gather. state_encryption, policy and policy_tests are EVALUATED in this gather rather than presence-detected; where tooling_configured reports them true, read their findings and the notes above for what each concluded.")

local notes_json
notes_json="$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.')" || {
  print -r -u2 -- "gather-opentofu-findings.zsh: could not encode the notes list"; exit 2;
}

# `tooling_configured` carries all SEVEN keys always — that vocabulary IS the
# contract, and a key going missing is indistinguishable from a key that was
# renamed. `findings_by_tool` carries keys ONLY for configured tools (the v2
# contract in ARCHITECTURE.md): emitting an empty array for an unconfigured tool
# would make "not configured" indistinguishable from "configured and clean" —
# which for the policy skip is exactly the confusion the charter must never
# create.
# BUFFERED, then printed — never streamed straight to stdout. The exit contract
# promises that on exit 2 "no payload is emitted and stdout is empty", and a jq
# that fails PART-WAY through (a write error, an OOM on a large findings array)
# would otherwise leave a truncated document on stdout together with exit 2 —
# handing the orchestrator exactly the partial payload it was told cannot exist.
local payload
payload="$(jq -n \
  --argjson tf "$has_tf" \
  --argjson policies "$has_policies" \
  --argjson policy_findings "$policy_findings" \
  --argjson policy_tests "$policy_tests_findings" \
  --argjson state_encryption "$state_encryption_findings" \
  --argjson notes "$notes_json" '
{
  tooling_configured: {
    format: $tf,
    validate: $tf,
    lint: $tf,
    misconfiguration: $tf,
    state_encryption: $tf,
    policy: $policies,
    policy_tests: $policies
  },
  findings_by_tool: (
    (if $tf then {
       format: [],
       validate: [],
       lint: [],
       misconfiguration: [],
       state_encryption: $state_encryption
     } else {} end)
    + (if $policies then { policy: $policy_findings, policy_tests: $policy_tests } else {} end)
  ),
  coverage: null,
  notes: $notes
}
')" || { print -r -u2 -- "gather-opentofu-findings.zsh: could not emit the payload"; exit 2; }
print -r -- "$payload" || {
  # the last unguarded command in the script: a failed write (a full disk on the
  # orchestrator's redirect target, EPIPE from a caller that closed the pipe)
  # would otherwise exit 1 under errexit — a status the contract above does not
  # list, with no message, so the orchestrator records a nameless failure for a
  # payload that was fully computed
  print -r -u2 -- "gather-opentofu-findings.zsh: could not write the payload to stdout"
  exit 2
}
