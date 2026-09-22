#!/usr/bin/env bats
#
# development-composition plugin skeleton + the claude-workspace/v1 contract
# (issue #1744, child 1 of epic #687).
#
# Two halves, deliberately in one file because they are one contract:
#
#   * the REGISTRY half asserts against the REAL repo root — plugin.json, the
#     marketplace entry, and the ARCHITECTURE/README/plugins.md/C4 registries a
#     new plugin must appear in. It follows tests/kubernetes-plugin-skeleton.bats
#     (#1151) and tests/opentofu-plugin-skeleton.bats (#1159): at this stage the
#     plugin ships no skills or agents, so the PROSE is what the later children
#     build on and the load-bearing clauses are pinned where they are stated.
#   * the VALIDATOR half runs development-composition/scripts/validate-workspace.zsh
#     over generated fixtures. Every case the story names is here — valid,
#     :latest, untagged, an undeclared promotes_from, malformed YAML, and a
#     missing file — plus the exits its two callers (#1745 bootstrap, #1747
#     gather) will branch on.
#
# Conventions carried over from the two sibling skeleton suites:
#   * needles are chosen so a NEGATED clause cannot satisfy them;
#   * every prose haystack is SCOPED to the section that must carry the clause,
#     so a coincidental occurrence elsewhere in a 6000-line document cannot
#     satisfy it and a MOVED clause is distinguishable from a present one;
#   * error-message assertions pin what the message NAMES (the member, the
#     environment), never its full wording — the contract is that a caller can
#     quote the offender, not that the sentence never gets reworded.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/development-composition"
  PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
  MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  VALIDATOR="$PLUGIN_DIR/scripts/validate-workspace.zsh"
  ENTRY='.plugins[] | select(.name == "development-composition")'

  # the two sections this story writes, each terminated by a generic `^##` so it
  # stops at the next heading of ANY level — an H2-only terminator would swallow
  # the sibling H3 that follows and silently widen every needle below.
  OWNS_SECTION="$(sed -n '/^### `development-composition` owns/,/^##/p' "$ARCH")"
  CONTRACT_SECTION="$(sed -n '/^### The `claude-workspace\/v1` contract/,/^##/p' "$ARCH")"

  # leverage-stack item 3 — the placement rule this story wrote, which sits
  # OUTSIDE both `###` sections above and would otherwise be pinned nowhere
  LEVERAGE_ITEM="$(sed -n '/^3\. \*\*Workspace manifest/,/^4\./p' "$ARCH")"

  # the user-facing narrative, scoped so a needle cannot be satisfied by a
  # sibling plugin's section
  PLUGINS_SECTION="$(sed -n '/^## development-composition$/,/^## /p' \
                       "$REPO_ROOT/docs/reference/plugins.md")"

  MANIFEST="$BATS_TEST_TMPDIR/.claude-workspace.yaml"
}

# A one-member manifest whose image ref is $1 — for the tag-pinning branches,
# which need shapes the block fixture below cannot express (an empty tag is not
# valid YAML unquoted, so the ref is always quoted here).
write_image_manifest() {
  cat > "$MANIFEST" <<YAML
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: "$1"
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
}

# A PATH holding only the tools named in $@ — the repo's stub convention, used
# to reach the tool-availability guard without uninstalling anything. Prints the
# directory; the caller passes it as PATH.
stub_path_without() {   # $@ = tools to PROVIDE beyond the base set below
  local dir tool src
  dir="$BATS_TEST_TMPDIR/stub-bin"
  rm -rf "$dir"
  mkdir -p "$dir"
  # the base set the script needs for reasons unrelated to what a case is
  # hiding — its EXIT trap runs `rm`, its parse-error message runs `tr`, and
  # every path needs `mktemp`. Leaving them out makes a stub PATH test the
  # harness rather than the script (a missing `rm` adds a second stderr line).
  for tool in "$@" rm tr mktemp; do
    src="$(command -v "$tool")"
    [ -n "$src" ]
    ln -s "$src" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# A conforming manifest — the story's own constellation, written to $1.
write_valid_manifest() {
  cat > "$1" <<'YAML'
members:
  - name: orders-ui
    repo: acme/orders-ui
    role: web-ui
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-ui:2.3.1
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
  production:
    github_environment: production
    promotes_from: staging
    deploy_target: none
YAML
}

# ---------------------------------------------------------------------------
# Registry: the plugin is registered everywhere a new plugin must appear
# ---------------------------------------------------------------------------

@test "the plugin manifest exists at the conventional path (#1744)" {
  [ -d "$PLUGIN_DIR" ]
  [ -f "$PLUGIN_JSON" ]
  jq -e . "$PLUGIN_JSON" >/dev/null
}

@test "plugin.json's name, the marketplace source and the on-disk directory all agree (#1744)" {
  # derived from the DATA, not from a constant repeated three times: this
  # genuinely couples the three artifacts rather than re-asserting one literal
  local name source_dir
  name="$(jq -er '.name' "$PLUGIN_JSON")"
  source_dir="$(basename "$(jq -er "$ENTRY | .source" "$MARKETPLACE")")"
  [ "$name" = "development-composition" ]
  [ "$name" = "$source_dir" ]
  [ -d "$REPO_ROOT/$name" ]
}

@test "the marketplace lists development-composition exactly once (#1744)" {
  run jq '[.plugins[] | select(.name == "development-composition")] | length' "$MARKETPLACE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "marketplace version and description are DERIVED from plugin.json, not restated (#1744)" {
  # the lockstep rule: an edit to one file that misses the other must red here.
  # jq -er (not -r alone) so a MISSING key fails the assignment — plain `jq -r`
  # prints the string "null", which is non-empty and would pass a [ -n ] guard
  local v_plugin v_market d_plugin d_market
  v_plugin="$(jq -er '.version' "$PLUGIN_JSON")"
  v_market="$(jq -er "$ENTRY | .version" "$MARKETPLACE")"
  d_plugin="$(jq -er '.description' "$PLUGIN_JSON")"
  d_market="$(jq -er "$ENTRY | .description" "$MARKETPLACE")"
  # anchored — an unanchored pattern accepts v0.1.0-SNAPSHOT and 0.1.0.9
  matches "$v_plugin" '^[0-9]+\.[0-9]+\.[0-9]+$'
  [ "$v_market" = "$v_plugin" ]
  [ "$d_market" = "$d_plugin" ]
  # the shipped-slice label is stated by VALUE in the user-facing prose ("only
  # in v0.1" in README, "What's built (v0.1)" in plugins.md), so the manifests
  # must agree — otherwise a later child could land its capability and prose
  # while leaving both manifests at 0.1.0, staying green while installs never
  # see the change
  starts_with "$v_plugin" "0.1."
  # …and the label is asserted where it is stated, DERIVED from the manifest
  # rather than restated: without this the prose could move to v0.2 while both
  # manifests stayed at 0.1.0, which is the drift the prefix pin exists to stop
  local label section
  label="v${v_plugin%.*}"
  contains "$(grep -E '^\| \*\*development-composition\*\*' "$REPO_ROOT/README.md")" "only in $label"
  section="$(sed -n '/^## development-composition/,/^## /p' "$REPO_ROOT/docs/reference/plugins.md")"
  [ -n "$section" ]
  contains "$section" "What's built ($label)"
}

@test "plugin.json carries the marketplace surface an installer reads (#1744)" {
  # the sibling skeletons pin this by value: a wrong licence and a plugin that
  # cannot be found by the words a user types are both invisible to a lockstep
  # check, which only proves the two files AGREE
  local license author_plugin author_market
  license="$(jq -er '.license' "$PLUGIN_JSON")"
  [ "$license" = "MIT" ]
  jq -e '.keywords | index("composition")' "$PLUGIN_JSON" >/dev/null
  jq -e '.keywords | index("claude-workspace")' "$PLUGIN_JSON" >/dev/null
  jq -e '.keywords | index("topic-plugin")' "$PLUGIN_JSON" >/dev/null
  author_plugin="$(jq -er '.author.name' "$PLUGIN_JSON")"
  author_market="$(jq -er "$ENTRY | .author.name" "$MARKETPLACE")"
  [ "$author_plugin" = "$author_market" ]
}

@test "the marketplace entry carries the development category and a resolvable source (#1744)" {
  local source
  run jq -r "$ENTRY | .category" "$MARKETPLACE"
  [ "$status" -eq 0 ]
  [ "$output" = "development" ]
  source="$(jq -er "$ENTRY | .source" "$MARKETPLACE")"
  [ "$source" = "./development-composition" ]
  [ -f "$REPO_ROOT/$source/.claude-plugin/plugin.json" ]
}

@test "the plugin is registered in every family registry a reader consults (#1744)" {
  # the CLASS of defect the two sibling skeletons each paid for: a plugin that
  # ships but is missing from one registry is invisible exactly where a reader
  # was sent to look. Each registry is read with its own whole-token match.
  local tree_line topic_row readme_table gen_block
  tree_line="$(grep -F 'development-composition ' "$ARCH" | head -n1)"
  [ -n "$tree_line" ]
  matches "$tree_line" 'development-composition[[:space:]]+← topic: composition.*'

  topic_row="$(grep -E '^\| \*\*Topic\*\* \|' "$ARCH")"
  [ -n "$topic_row" ]
  # scoped to the segment BEFORE `future:` — a mention in the future list must
  # not satisfy the registration of a plugin that has shipped
  contains "${topic_row%%future:*}" '`development-composition`'

  readme_table="$(grep -E '^\| \*\*development' "$REPO_ROOT/README.md")"
  [ -n "$readme_table" ]
  contains "$readme_table" '**development-composition**'

  # whole-line, not substring: "## development" is satisfied by any sibling
  grep -qx "## development-composition" "$REPO_ROOT/docs/reference/plugins.md"

  # the README row's HONESTY clause, not just its name: dropping the marker
  # caveat would send a repo author to write a declaration that selects nothing
  readme_table="$(grep -E '^\| \*\*development' "$REPO_ROOT/README.md")"
  contains "$readme_table" 'once #1747 registers the marker'
  contains "$readme_table" 'nothing calls the validator until the bootstrap scaffold lands'
  contains "$readme_table" 'accepts only `none`'

  # the docs-reference generator hardcodes its plugin list, so an unregistered
  # plugin is SILENTLY skipped — --check then compares two equally incomplete
  # files and the drift gate passes over a plugin the pages omit entirely
  gen_block="$(sed -n '/^PLUGINS = \[/,/^\]/p' "$REPO_ROOT/scripts/generate-docs-reference.py")"
  [ -n "$gen_block" ]
  contains "$gen_block" '"development-composition"'
}

@test "the user-facing narrative restates the contract without contradicting it (#1744)" {
  # plugins.md is where README sends a reader, so a clause that drifts there
  # misinstructs exactly the audience the page exists for
  local flat
  [ -n "$PLUGINS_SECTION" ]
  flat="$(printf '%s' "$PLUGINS_SECTION" | tr -s '[:space:]' ' ')"
  contains "$flat" 'never a manifest verdict'
  contains "$flat" 'is read like `3`'
  contains "$flat" 'two intended callers'
  contains "$flat" 'no validator CI job is ever rendered into a composition repo'
  contains "$flat" 'no skills and no agents yet'
  # …and the clauses a reader IMPLEMENTS against, each with a needle of its
  # own: the framing sentences above would survive any rewrite of these
  contains "$flat" '`1` a contract violation'
  contains "$flat" '`2` its own bad invocation'
  contains "$flat" '`4` a manifest file that is missing'
  contains "$flat" '`:latest`, `:stable`, `:edge`, `:main`, `:master`'
  contains "$flat" 'accepts only `none`'
  contains "$flat" 'named error on the first violation'
  contains "$flat" '`3` a missing'
  contains "$flat" 'exit `0` is simply no finding'
  contains "$flat" 'is not mikefarah'
  contains "$flat" 'or unreadable'
  contains "$flat" 'otherwise cannot provide what the script needs'
  contains "$flat" 'the stderr line tells those two apart'
}

@test "the manifest's PLACEMENT rule is stated where the leverage stack defines it (#1744)" {
  # outside both `###` sections, so neither of the section tests covers it —
  # and it is what stops a member repo being scaffolded with a manifest and
  # then detected as a composition repo once #1747 lands
  local flat
  [ -n "$LEVERAGE_ITEM" ]
  flat="$(printf '%s' "$LEVERAGE_ITEM" | tr -s '[:space:]' ' ')"
  contains "$flat" 'Realized as `.claude-workspace.yaml`'
  contains "$flat" 'never in a member repo'
  contains "$flat" 'registered with #1747'
}

@test "the version-bump rosters name this plugin's pinned prefix (#1744)" {
  # the suite pins `0.1.` on the manifest; the two rosters a maintainer reads
  # before bumping must name the same prefix, or a resolve run cuts a minor and
  # reds this very file
  local v_plugin prefix
  v_plugin="$(jq -er '.version' "$PLUGIN_JSON")"
  prefix="${v_plugin%.*}."
  contains "$(grep -F 'development-composition' "$REPO_ROOT/MAINTAINING.md")" "(\`$prefix\`)"
  contains "$(grep -F 'development-composition' \
               "$REPO_ROOT/development-claude-plugin/skills/resolve-profile/SKILL.md")" "(\`$prefix\`)"
}

@test "the C4 Container diagram declares the plugin and the orchestrator's edge to it (#1744)" {
  # a new plugin is a new deployable unit, so the diagram is part of the change
  # rather than a follow-up (CLAUDE.md's structural-change rule). dogfood-c4.bats
  # derives the declared set from the marketplace, so a missing entry reds there
  # too — this asserts the SHAPE that suite only counts.
  local c4
  c4="$REPO_ROOT/docs/architecture/c4-container.md"
  [ -f "$c4" ]
  contains "$(cat "$c4")" 'Container(development-composition, "development-composition"'
  contains "$(cat "$c4")" 'Rel(development, development-composition, "dispatches")'
}

# ---------------------------------------------------------------------------
# Registry: the charter's load-bearing clauses, pinned where they are stated
# ---------------------------------------------------------------------------

@test "ARCHITECTURE names the composition repo type and what the plugin owns (#1744)" {
  [ -n "$OWNS_SECTION" ]
  local flat
  flat="$(printf '%s' "$OWNS_SECTION" | tr -s '[:space:]' ' ')"
  contains "$flat" 'composition repo type'
  contains "$flat" '`.claude-workspace.yaml` constellation manifest'
  contains "$flat" '`claude-workspace/v1`'
  # the ownership NEGATIVE, in a form a deletion cannot satisfy: what it does
  # not own, and the reason the boundary holds
  contains "$flat" 'does **not** own the member repos'
  contains "$flat" 'depends on **no repository**'
  # may be primary — the clause the maintenance child (#1747) builds on
  contains "$flat" '**can be primary**'
  contains "$flat" '`primary: composition`'
  # the promise every later child inherits, stated positively so removing the
  # sentence reds rather than merely unpinning it
  contains "$flat" 'no run ever reports a deploy that did not happen'
  # and the boundary #687 states: a validator CI job is never rendered
  contains "$flat" 'No validator CI job is ever rendered into a'
}

@test "ARCHITECTURE specifies every claude-workspace/v1 field (#1744)" {
  [ -n "$CONTRACT_SECTION" ]
  local flat key
  flat="$(printf '%s' "$CONTRACT_SECTION" | tr -s '[:space:]' ' ')"
  # every members[] field the contract requires, and every environments field —
  # asserted as the TABLE keys they are documented as, so dropping a row reds
  for key in name repo role contract image; do
    contains "$flat" "| \`$key\` |"
  done
  for key in github_environment promotes_from deploy_target; do
    contains "$flat" "| \`$key\` |"
  done
  # the tag-pinning rule, both halves
  contains "$flat" 'must be `name:tag`'
  contains "$flat" '`@sha256:<64 lowercase hex digits>`'
  # the closed floating set, so contract and validator cannot drift apart
  contains "$flat" '`latest`, `stable`, `edge`, `main`, `master`'
  # the allowed deploy_target values in THIS release, and what widens them
  contains "$flat" '**`none` is the only accepted value in this release**'
  contains "$flat" '`compose` (#719)'
  contains "$flat" '`kubernetes` (#720)'
  # promotes_from is validated against the DECLARED set, and null is an answer
  contains "$flat" 'validated against the **declared** environment names'
}

@test "the contract section documents the validator's typed exit codes (#1744)" {
  # its two callers (#1745 bootstrap, #1747 gather) branch on these, and the
  # script's own header states them — so the specification must agree with it
  local flat
  flat="$(printf '%s' "$CONTRACT_SECTION" | tr -s '[:space:]' ' ')"
  contains "$flat" 'named error on the first violation'
  contains "$flat" '`1` a contract violation'
  contains "$flat" '`2` a usage error'
  contains "$flat" '`3` a required tool'
  contains "$flat" 'otherwise cannot provide what the script needs'
  contains "$flat" '`4` the manifest file does not exist'
}

@test "the charter says what the GATHER does with each exit code (#1744)" {
  # "turns a failure into a finding" would collapse exactly the distinctions the
  # typing exists for — #1747 must not file a manifest finding for a runner that
  # lacks yq (3) or a repo that has no manifest at all (4)
  local flat
  flat="$(printf '%s' "$OWNS_SECTION" | tr -s '[:space:]' ' ')"
  contains "$flat" 'keyed on WHICH failure, never on "non-zero"'
  contains "$flat" '| `1` | a `claude-workspace/v1` **contract** finding'
  contains "$flat" '| `4` | a **missing-manifest** finding'
  contains "$flat" '| `3` | a **tool-availability** escalation'
  contains "$flat" '| `2` | a **bug in the gather'
  # …and the table is CLOSED only with an otherwise arm: the script exits with
  # five codes, so a sixth means a tool died before the manifest was judged and
  # must never become a contract finding
  contains "$flat" '| `0` | **no finding**'
  contains "$flat" '| *any other non-zero status* |'
  # the qualifiers, each pinned where it is stated: they are what #1745 and
  # #1747 branch on, and a later child must retire them deliberately
  contains "$flat" 'whether or not the manifest had already been read'
  contains "$flat" '`manifest not readable` blames the file'
  contains "$flat" 'quoting the document-level error line as it stands'
  # the OTHER named caller is specified too — a bootstrap that printed the error
  # and still reported success would report green a repo it just proved invalid
  contains "$flat" "**Bootstrap's branch is the mirror image**"
  contains "$flat" '**fails the bootstrap run**'
}

@test "the charter states primary-capability as PENDING the marker, not as current (#1744)" {
  # a `.maintenance.yml` declaring `primary: composition` today is a stale
  # declaration under the dispatch_mode contract — it selects nothing. Claiming
  # otherwise would send a repo author to write a declaration that silently does
  # nothing, the same sequence kubernetes and opentofu each passed through.
  local flat
  flat="$(printf '%s' "$OWNS_SECTION" | tr -s '[:space:]' ' ')"
  contains "$flat" 'It is not primary-capable yet'
  contains "$flat" '**stale declaration**'
  contains "$flat" 'Once #1747 registers the marker'
}

@test "the contract states the chain, empty-value and uniqueness rules (#1744)" {
  # each is a rule the validator enforces, so a spec that omitted it would let a
  # later reader call the check an over-reach — and a spec that kept it while
  # the check was deleted is what the validator cases above pin from the other
  # side
  local flat
  flat="$(printf '%s' "$CONTRACT_SECTION" | tr -s '[:space:]' ' ')"
  contains "$flat" 'The chain must be acyclic, with at least one `null` head'
  contains "$flat" 'a cycle of any length is reported'
  contains "$flat" '**empty string** is neither'
  contains "$flat" '**unique** among its members'
  # the untagged shape swallows the empty tag rather than being a fourth shape
  contains "$flat" 'covers both `ghcr.io/acme/orders-ui` and the empty tag'
  # the whitespace rule and the single-line member name are rules the validator
  # enforces, so the contract has to license them or a later reader will read
  # them as an over-reach and delete them
  contains "$flat" 'carrying **whitespace** anywhere'
  contains "$flat" 'a **single-line** string'
  # an environment is declared once, under a usable name — both are checks the
  # validator makes, so the specification has to license them
  contains "$flat" '**declared exactly once, under a non-empty single-line name**'
  # …and the version question is answered rather than left to a later child
  contains "$flat" '**v1 defines no schema-version key**'
  # …and it is IGNORED rather than rejected, which the forward-compatibility
  # rule two lines down would otherwise contradict
  contains "$flat" 'is an undeclared key like any other and is *ignored*'
  # the contract path is resolved in the IMAGE: "or repo" would license the one
  # dependency the charter says a composition repo never takes
  contains "$flat" 'never by fetching the member repo'
  contains "$flat" 'non-empty, non-whitespace string'
  # …with the one exception the chain's head needs
  contains "$flat" 'whose `null` is an *answer* rather'
  contains "$flat" 'then the promotion-chain walk'
}

# ---------------------------------------------------------------------------
# Validator: the script ships in a runnable shape
# ---------------------------------------------------------------------------

@test "the validator ships executable, with a zsh shebang, and parses (#1744)" {
  [ -f "$VALIDATOR" ]
  [ -x "$VALIDATOR" ]
  run head -n1 "$VALIDATOR"
  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env zsh" ]
  # syntax-only: catches a broken edit without executing anything
  run zsh -n "$VALIDATOR"
  [ "$status" -eq 0 ]
}


@test "the validator prints usage on --help and on -h (#1744)" {
  run zsh "$VALIDATOR" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: validate-workspace.zsh"
  # the alias is asserted separately: removing `-h|` from the case arm turns it
  # into an unknown flag (exit 2), which only its own case can see
  run zsh "$VALIDATOR" -h
  [ "$status" -eq 0 ]
  contains "$output" "usage: validate-workspace.zsh"
}

@test "an unknown flag is exit 2, never a manifest verdict (#1744)" {
  # a usage error is distinct from a contract violation, so a caller never
  # reports its own bad invocation as a bad manifest
  run zsh "$VALIDATOR" --nonsense
  [ "$status" -eq 2 ]
  contains "$output" "unknown flag"
}

@test "a flag with no value is exit 2, for BOTH flags (#1744)" {
  run zsh "$VALIDATOR" --manifest
  [ "$status" -eq 2 ]
  contains "$output" "--manifest needs a value"
  run zsh "$VALIDATOR" --repo
  [ "$status" -eq 2 ]
  contains "$output" "--repo needs a value"
}

@test "an EMPTY flag value is exit 2, not a silent fallback to another file (#1744)" {
  # the shape both callers will actually produce: an unset shell variable
  # interpolated into `--manifest "$M"`. Counting arguments rather than
  # inspecting them would fall through to ./.claude-workspace.yaml and return a
  # verdict — possibly a green one — about a file the caller never named.
  run zsh "$VALIDATOR" --manifest ""
  [ "$status" -eq 2 ]
  contains "$output" "--manifest needs a value"
  run zsh "$VALIDATOR" --repo ""
  [ "$status" -eq 2 ]
  contains "$output" "--repo needs a value"
}

@test "a dropped value that swallows the NEXT flag is exit 2, not exit 4 (#1744)" {
  # `--manifest --repo /tmp` must not read "--repo" as a path: reporting it as
  # "manifest not found" would spend the one distinction exit 4 exists for
  run zsh "$VALIDATOR" --manifest --repo /tmp
  [ "$status" -eq 2 ]
  contains "$output" "--manifest needs a value"
  lacks "$output" "manifest not found"
}

@test "a missing required tool is exit 3 — a runner verdict, never a manifest one (#1744)" {
  # the contract its callers branch on: #1747 must not file a manifest finding
  # on a runner that simply lacks yq. Reached with a PATH stub rather than by
  # uninstalling anything; zsh is invoked by absolute path so the stub does not
  # have to carry the shell itself.
  local stub
  write_valid_manifest "$MANIFEST"
  stub="$(stub_path_without jq)"       # jq present, yq unreachable
  run env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  contains "$output" "required tool not found: yq"

  stub="$(stub_path_without yq)"       # and the loop's second iteration
  run env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  contains "$output" "required tool not found: jq"
}

@test "a yq that is not mikefarah's is exit 3, not a malformed-YAML verdict (#1744)" {
  # Debian/Ubuntu's `yq` is kislyuk's python-yq, which rejects the JSON output
  # this validator reads. Without the probe the parse fails and the MANIFEST is
  # blamed (exit 1) for a runner problem — the finding #1747 must never file.
  local stub
  write_valid_manifest "$MANIFEST"
  stub="$(stub_path_without jq)"
  cat > "$stub/yq" <<'SH'
#!/bin/sh
case "$1" in --version) echo "yq 2.12.0" ;; *) echo "usage: yq [options]" >&2; exit 2 ;; esac
SH
  chmod +x "$stub/yq"
  run env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  contains "$output" "not mikefarah"
  lacks "$output" "malformed YAML"
}

# ---------------------------------------------------------------------------
# Validator: the story's cases
# ---------------------------------------------------------------------------

@test "a valid constellation exits 0 and reports what it validated (#1744)" {
  write_valid_manifest "$MANIFEST"
  run --separate-stderr zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  # the documented success wording, on STDOUT: a bare "claude-workspace/v1"
  # needle is satisfied by several ERROR messages too, and bootstrap (#1745)
  # reads this line from stdout while the gather reads stderr
  contains "$output" "is valid"
  [ -z "$stderr" ]
  # the counts, so a validator that silently skipped the members loop cannot
  # report a green it never earned
  contains "$output" "(2 members, 2 environments)"
}

@test "a named error goes to STDERR, and nothing goes to stdout (#1744)" {
  # the stream split is the contract behind "quote it verbatim into a finding":
  # #1747 reads stderr. With a bare `run` both streams merge, so a swap would
  # pass every other case in this file.
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|orders-ui:2.3.1|orders-ui:latest|' "$MANIFEST"
  run --separate-stderr zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$stderr" "floating tag"
  # …and names the file it judged: a gather validating one manifest per repo
  # would otherwise quote a line with no file in it
  contains "$stderr" "$MANIFEST"
  [ -z "$output" ]
}

@test "--repo defaults the manifest to <repo>/.claude-workspace.yaml (#1744)" {
  # the shape bootstrap (#1745) will call it with: a repo directory, not a file
  write_valid_manifest "$BATS_TEST_TMPDIR/.claude-workspace.yaml"
  run zsh "$VALIDATOR" --repo "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  # the resolved path AND the verdict, so an error quoting the same path cannot
  # satisfy the needle
  contains "$output" "$BATS_TEST_TMPDIR/.claude-workspace.yaml is valid"
}

@test "EVERY floating tag in the closed set is a named error (#1744)" {
  # the set is closed in ARCHITECTURE "so the validator and this specification
  # cannot drift apart" — testing `latest` alone would let the case arm be
  # narrowed to it while `:main` validated clean
  local tag
  for tag in latest stable edge main master; do
    write_image_manifest "ghcr.io/acme/orders-api:$tag"
    run zsh "$VALIDATOR" --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    # the PREFIX, not a bare name: 'orders-api' also occurs inside the image ref,
    # so the naming guarantee the contract makes would be unconstrained
    contains "$output" "member 'orders-api':"
    contains "$output" "floating tag ':$tag'"
  done
}

@test "an untagged member ref is a named error (#1744)" {
  write_image_manifest "ghcr.io/acme/orders-ui"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api':"
  contains "$output" "not pinned to a tag"
}

@test "an EMPTY tag is the untagged shape, not a green (#1744)" {
  write_image_manifest "ghcr.io/acme/orders-api:"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "not pinned to a tag"
}

@test "a registry PORT is not read as a tag (#1744)" {
  # `localhost:5000/acme/api` is untagged: the tag is the part after the last
  # colon only when that colon follows the last `/`. Reading it the other way
  # would accept an untagged ref — and the Renovate child (#1746) pins against
  # a local registry, so this shape is one the family actually writes.
  write_image_manifest "localhost:5000/acme/orders-api"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api':"
  contains "$output" "not pinned to a tag"
}

@test "a tag-pinned member MAY carry an @sha256 digest suffix (#1744)" {
  # the contract allows it, and #1745's promote script must record such a member
  # with exactly one suffix — so rejecting it here would block that child
  write_image_manifest "ghcr.io/acme/orders-api:1.5.0@sha256:$(printf 'a%.0s' $(seq 64))"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  contains "$output" "is valid"
}

@test "a digest suffix that is not sha256 is its OWN named error (#1744)" {
  # distinct from the malformed-sha256 message below: a needle matching both
  # cannot tell which branch fired, so deleting one would go unnoticed
  write_image_manifest "ghcr.io/acme/orders-api:1.5.0@md5:$(printf 'a%.0s' $(seq 32))"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api':"
  contains "$output" "not a sha256 digest"
}

@test "a malformed @sha256 digest suffix is a named error (#1744)" {
  # "allowed" is not "unchecked": a truncated digest would otherwise ride into
  # the promotion record as if it pinned something
  write_image_manifest "ghcr.io/acme/orders-api:1.5.0@sha256:abc123"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api':"
  contains "$output" "malformed sha256 digest"
}

@test "the sha256 pattern is ANCHORED — 64 hex plus trailing junk is rejected (#1744)" {
  # drops the trailing `$` and this passes, which is why the anchoring has its
  # own case rather than riding on the truncated-digest one
  write_image_manifest "ghcr.io/acme/orders-api:1.5.0@sha256:$(printf 'a%.0s' $(seq 64))junk"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "malformed sha256 digest"
}

@test "promotes_from naming an undeclared environment is a named error listing the declared ones (#1744)" {
  # tc-error-undeclared-promotes-from (#1733)
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|promotes_from: staging|promotes_from: qa|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  # the PREFIX names the offending environment: every bare name below also
  # occurs in the message's trailing "declared: …" list, so without it the
  # environment could be dropped from the message unnoticed
  contains "$output" "environment 'production':"
  contains "$output" 'promotes_from "qa"'
  contains "$output" "declared: staging, production"
  contains "$output" "not a declared environment"
}

@test "promotes_from naming ITSELF is a named error (#1744)" {
  # it IS a declared environment, so the has() check accepts it: only the
  # self-reference branch rejects it, and only this case covers that branch
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|promotes_from: staging|promotes_from: production|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment 'production':"
  contains "$output" "names itself"
}

@test "a LONGER promotion cycle is a named error too (#1744)" {
  # staging <- production <- staging: every target is declared and none names
  # itself, yet the chain has no null head, so promotion (#1745) would have
  # nowhere to start
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|promotes_from: null|promotes_from: production|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  # the chain IN ORDER, as the contract states it, and named against an
  # environment that is actually in the cycle
  contains "$output" "environment 'staging':"
  contains "$output" "cycle (staging -> production -> staging)"
}

@test "promotes_from: null is an accepted answer (#1744)" {
  # the head of a promotion chain promotes from nothing, so null must pass
  write_valid_manifest "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  contains "$output" "is valid"
}

@test "a MISSING promotes_from key is a named error (#1744)" {
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment 'staging':"
  contains "$output" "promotes_from"
}

@test "an EMPTY promotes_from is a named error, not a silent head of the chain (#1744)" {
  # what a template renders from an unset variable (#1745 will render one). Read
  # as "promotes from nothing" it would skip every check below it and green-light
  # a chain with a broken rung.
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|promotes_from: staging|promotes_from: ""|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment 'production':"
  contains "$output" "promotes_from is empty"
}

@test "EVERY deploy_target this release cannot honour is a named error (#1744)" {
  # `compose` and `kubernetes` are real values of the contract — they just have
  # no renderer yet (#719/#720). Accepting either now would let a repo declare a
  # deploy it has no mechanism to perform, which is the one thing the epic's
  # deploy_target: none discipline exists to prevent — and testing only one of
  # them would let the allow-list be widened to the other unnoticed.
  local target
  for target in compose kubernetes; do
    write_valid_manifest "$MANIFEST"
    sed -i.bak "s|deploy_target: none|deploy_target: $target|" "$MANIFEST"
    run zsh "$VALIDATOR" --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    contains "$output" "environment 'staging':"
    contains "$output" "deploy_target '$target'"
    # names BOTH issues that will widen it, so the error is actionable for
    # whichever value was written rather than a flat refusal
    contains "$output" "#719"
    contains "$output" "#720"
  done
}

@test "EVERY required member key is enforced, and each names the member (#1744)" {
  # derived from ARCHITECTURE's own table rather than restated here, so a field
  # documented as required but never checked — which `contract` was — reds. The
  # table is the specification; this couples it to the executable half.
  local keys key
  keys="$(printf '%s' "$CONTRACT_SECTION" \
            | sed -n '/^| `name` |/,/^| `image` |/p' \
            | sed -E 's/^\| `([a-z_]+)` \|.*/\1/')"
  [ -n "$keys" ]
  # the set the table declares, so a NEW required row must also be enforced
  contains "$keys" "contract"
  for key in $keys; do
    if [ "$key" = "name" ]; then continue; fi
    write_valid_manifest "$MANIFEST"
    sed -i.bak "/^    $key: /d" "$MANIFEST"
    run zsh "$VALIDATOR" --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    contains "$output" "orders-ui"
    contains "$output" "missing required key: $key"
  done
}

@test "a member with no name is reported BY POSITION, not as an empty name (#1744)" {
  # "member '': missing required key: repo" reads as a truncated error; the
  # positional label is what keeps a nameless member actionable
  cat > "$MANIFEST" <<'YAML'
members:
  - repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member #1 (no name)"
  contains "$output" "missing required key: name"
}

@test "two members sharing a name is a named error (#1744)" {
  # every message keys on the name, and #1745's promotion record will too, so a
  # duplicate leaves an error naming an offender the reader cannot locate
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|name: orders-api|name: orders-ui|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "duplicate member name"
  contains "$output" "orders-ui"
}

@test "each document-shape violation gets its OWN named error (#1744)" {
  # four distinct branches, each with a needle the others cannot satisfy: a
  # missing key and a mistyped one are different defects, and #1747 quotes
  # whichever fired
  cat > "$MANIFEST" <<'YAML'
environments:
  staging: {github_environment: staging, promotes_from: null, deploy_target: none}
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "missing required key: members"

  printf 'members: a-string\nenvironments:\n  s: {github_environment: s, promotes_from: null, deploy_target: none}\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "members must be a list"

  printf 'members:\n  - {name: a, repo: r, role: x, contract: c, image: "ghcr.io/a/b:1"}\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "missing required key: environments"

  printf 'members:\n  - {name: a, repo: r, role: x, contract: c, image: "ghcr.io/a/b:1"}\nenvironments: []\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environments must be a mapping"
}

@test "a member that is not a mapping is a named error, not a jq crash (#1744)" {
  # `.name` on the scalar in `members:\n  - orders-api` is a jq ERROR, so
  # without the type guard the script either leaks jq's stderr under a
  # misleading message or dies with an exit code no caller can type
  printf 'members:\n  - orders-api\nenvironments:\n  s: {github_environment: s, promotes_from: null, deploy_target: none}\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "every entry of members must be a mapping"
  contains "$output" "member #1"
  lacks "$output" "Cannot index"
}

@test "an environment that is not a mapping is a named error, not a jq crash (#1744)" {
  printf 'members:\n  - {name: a, repo: r, role: x, contract: c, image: "ghcr.io/a/b:1"}\nenvironments:\n  staging: none\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "every environment must be a mapping"
  contains "$output" "staging"
  lacks "$output" "Cannot index"
}

@test "malformed YAML is reported AS a parse failure, not as a missing key (#1744)" {
  # the distinction matters to the gather (#1747): "your manifest does not parse"
  # and "your manifest omits members" are different findings with different fixes
  printf 'members: [\n  - broken\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "malformed YAML"
  lacks "$output" "missing required key"
}

@test "a YAML document that is not a mapping is reported as malformed (#1744)" {
  # an empty file parses to `null` and a list to an array: both are valid YAML
  # and neither can answer `.members`, so a key-shaped error would misdescribe it
  : > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  # the ARM, not just the shared prefix: five distinct messages start with
  # "malformed YAML", so the bare prefix cannot tell which one fired
  contains "$output" "the document is not a mapping"
  lacks "$output" "expected a single YAML document"
}

@test "a MULTI-document manifest is a named error, not a math crash (#1744)" {
  # yq emits one JSON value per document, which makes the member count a
  # two-line string: the members loop is then skipped on a raw zsh math error
  # and the success line can still print
  printf -- '---\nmembers:\n  - {name: a, repo: r, role: x, contract: c, image: "ghcr.io/a/b:1"}\nenvironments:\n  s: {github_environment: s, promotes_from: null, deploy_target: none}\n---\nmembers: []\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "expected a single YAML document"
  lacks "$output" "is valid"
}

@test "a missing manifest exits 4, distinct from a contract violation (#1744)" {
  # bootstrap never writing the file and bootstrap writing a bad one are
  # different defects; a caller that collapses them reports the wrong one
  run zsh "$VALIDATOR" --manifest "$BATS_TEST_TMPDIR/absent.yaml"
  [ "$status" -eq 4 ]
  contains "$output" "manifest not found"
}

@test "an UNREADABLE manifest exits 4 too — an I/O fact, not a verdict (#1744)" {
  write_valid_manifest "$MANIFEST"
  chmod 000 "$MANIFEST"
  # root bypasses the permission bits, so the denial path never runs there —
  # tests/Dockerfile runs this suite as uid 0. Gated on the OBSERVED effect
  # rather than on `id -u`, the form tests/build-refine-telemetry-record.bats
  # uses, so any other permission-bypassing identity is covered too.
  if [ -r "$MANIFEST" ]; then
    chmod 644 "$MANIFEST"
    skip "running as a user that bypasses file permissions"
  fi
  run --separate-stderr zsh "$VALIDATOR" --manifest "$MANIFEST"
  chmod 644 "$MANIFEST"
  [ "$status" -eq 4 ]
  contains "$stderr" "not readable"
  [ -z "$output" ]
}

@test "an empty members list is a named error (#1744)" {
  # a syntactically-present but empty constellation composes nothing; accepting
  # it would let bootstrap's post-scaffold run (#1745) pass on a skeleton that
  # scaffolded no members at all
  cat > "$MANIFEST" <<'YAML'
members: []
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "members is empty"
}

@test "an empty environments mapping is a named error (#1744)" {
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments: {}
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environments is empty"
}

@test "a FOLDED promotes_from is judged as the document carries it (#1744)" {
  # `promotes_from: >` with an indented value resolves to "staging\n". The
  # shell strips that trailing newline, so a membership test written in zsh
  # would match the declared `staging` — and #1745, walking the manifest
  # itself, would then find no rung on a manifest called valid.
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
  production:
    github_environment: production
    promotes_from: >
      staging
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment 'production':"
  contains "$output" "is not a declared environment"
}

@test "a TRAILING newline in a member name is a named error (#1744)" {
  # same stripping, on the value every error about the member quotes: accepted,
  # the member would be validated and reported under a name the document does
  # not carry
  cat > "$MANIFEST" <<'YAML'
members:
  - name: >
      orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "name must be a single-line string"
}

@test "whitespace ANYWHERE in an image ref is a named error (#1744)" {
  # trimming the ends is not enough: a space after the colon leaves `tag` as
  # " latest", which matches none of the closed floating arms
  local ref
  for ref in "ghcr.io/acme/orders-api: latest" "ghcr.io/acme/orders-api:1.0 rubbish"; do
    write_image_manifest "$ref"
    run zsh "$VALIDATOR" --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    contains "$output" "member 'orders-api':"
    contains "$output" "contains whitespace"
  done
}

@test "a DIGEST-ONLY ref is untagged, not a substitute for a tag (#1744)" {
  # the digest suffix is optional ON a tag, never instead of one: a promotion
  # record pinned by digest alone carries no human-readable version
  write_image_manifest "ghcr.io/acme/orders-api@sha256:$(printf 'a%.0s' $(seq 64))"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api':"
  contains "$output" "not pinned to a tag"
  lacks "$output" "is valid"
}

@test "the digest is LOWERCASE hex, and the algorithm prefix is matched literally (#1744)" {
  # the contract says 64 lowercase hex digits with `sha256:` matched literally;
  # widening either would let the validator drift past the spec it implements
  write_image_manifest "ghcr.io/acme/orders-api:1.5.0@sha256:$(printf 'A%.0s' $(seq 64))"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "malformed sha256 digest"

  write_image_manifest "ghcr.io/acme/orders-api:1.5.0@SHA256:$(printf 'a%.0s' $(seq 64))"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "not a sha256 digest"
}

@test "an environment key with a TRAILING newline is a named error (#1744)" {
  # `$( )` strips it, so a check written in the shell would validate the
  # environment under a name the document does not carry and then report a
  # missing key on it — the name itself is the defect
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  ? >
    staging
  : {github_environment: staging, promotes_from: null, deploy_target: none}
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment names must be non-empty, single-line strings"
  lacks "$output" "missing required key"
}

@test "an image with no NAME portion is a named error (#1744)" {
  # `/:1.0` is what a template renders with the image name unset: it satisfies
  # every tag rule while pinning nothing at all
  write_image_manifest "/:1.0"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api':"
  contains "$output" "has no image name"
  lacks "$output" "is valid"
}

@test "a PADDED tag is judged trimmed, so the floating set cannot be evaded (#1744)" {
  # one invisible character would otherwise match none of the closed arms
  write_image_manifest "ghcr.io/acme/orders-api:latest "
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "floating tag ':latest'"

  # …and a padded IMMUTABLE tag still validates: trimming is not rejection
  write_image_manifest "ghcr.io/acme/orders-api:1.5.0 "
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  contains "$output" "is valid"
}

@test "a WHITESPACE-ONLY environment name is as unusable as an empty one (#1744)" {
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  " ":
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment names must be non-empty, single-line strings"
}

@test "a MULTI-LINE member name is a named error (#1744)" {
  # fail() flattens newlines, so an accepted multi-line name would be quoted
  # back as a name the manifest never carried
  cat > "$MANIFEST" <<'YAML'
members:
  - name: "orders\napi"
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "name must be a single-line string"
}

@test "an older mikefarah yq is ACCEPTED, python-yq is not (#1744)" {
  # the URL only appears in ~v4.24 and later, so keying on it alone would
  # escalate a usable binary and tell the maintainer to install the yq they
  # already have — while python-yq, which cannot answer -o=json, stays refused
  local stub real_yq
  stub="$(stub_path_without jq)"
  real_yq="$(command -v yq)"
  cat > "$stub/yq" <<SH
#!/bin/sh
case "\$1" in --version) echo "yq version 4.20.2" ;; *) exec "$real_yq" "\$@" ;; esac
SH
  chmod +x "$stub/yq"
  write_valid_manifest "$MANIFEST"
  run env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  contains "$output" "is valid"

  cat > "$stub/yq" <<'SH'
#!/bin/sh
case "$1" in --version) echo "yq 3.4.3" ;; *) echo "usage: yq" >&2; exit 2 ;; esac
SH
  chmod +x "$stub/yq"
  run env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  contains "$output" "not mikefarah"

  # …and mikefarah v3, whose banner carries the word "version" but the wrong
  # major: it speaks the `yq r` dialect and cannot answer -o=json, so widening
  # the arm to any "yq version" would admit it and blame the manifest
  cat > "$stub/yq" <<'SH'
#!/bin/sh
case "$1" in --version) echo "yq version 3.4.1" ;; *) echo "usage: yq" >&2; exit 2 ;; esac
SH
  chmod +x "$stub/yq"
  run env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  contains "$output" "not mikefarah"
  lacks "$output" "malformed YAML"
}

@test "a tool that dies MID-RUN is exit 3, never a contract verdict (#1744)" {
  # the three post-probe escalations: each would read as a manifest defect if
  # its exit were 1, which is the conflation the typed exits exist to prevent
  local stub real_yq real_jq
  stub="$(stub_path_without yq jq)"
  write_valid_manifest "$MANIFEST"

  # (a) an mktemp that FAILS silently — the runner cannot give the script a
  # temp file. A stub rather than an absent binary, so the only stderr line is
  # the script's own and the ONE-line promise can be asserted here too
  rm -f "$stub/mktemp"   # the base set links the real one; replace, never write through
  printf '#!/bin/sh\nexit 1\n' > "$stub/mktemp"
  chmod +x "$stub/mktemp"
  run --separate-stderr env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  contains "$stderr" "could not create a temporary file"
  lacks "$stderr" "malformed YAML"
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]

  # (b) a jq that dies on the document-count read only
  ln -sf "$(command -v mktemp)" "$stub/mktemp"   # restores what arm (a) replaced
  real_jq="$(command -v jq)"
  rm -f "$stub/jq"
  cat > "$stub/jq" <<SH
#!/bin/sh
[ "\$1" = "-s" ] && exit 1
exec "$real_jq" "\$@"
SH
  chmod +x "$stub/jq"
  run --separate-stderr env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  contains "$stderr" "required tool unusable: jq"
  lacks "$stderr" "malformed YAML"
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]

  # (c) a yq that answers the parse but dies on the duplicate-key re-read
  ln -sf "$real_jq" "$stub/jq"
  real_yq="$(command -v yq)"
  rm -f "$stub/yq"
  cat > "$stub/yq" <<SH
#!/bin/sh
case "\$*" in *keys*) exit 1 ;; esac
exec "$real_yq" "\$@"
SH
  chmod +x "$stub/yq"
  run --separate-stderr env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  contains "$stderr" "required tool unusable: yq"
  lacks "$stderr" "declared more than once"
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]
}

@test "the temp file the validator creates is cleaned up (#1744)" {
  # the EXIT trap is the only thing that removes it; without a test, deleting
  # the trap leaves a file behind on every bootstrap and every gather run
  local tmp
  tmp="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$tmp"
  write_valid_manifest "$MANIFEST"
  run env TMPDIR="$tmp" zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$tmp")" ]

  # …and on the branch that actually READS the captured stderr
  printf 'members: [\n  - broken\n' > "$MANIFEST"
  run env TMPDIR="$tmp" zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$tmp")" ]
}

@test "the FIRST violation follows the order the contract states (#1744)" {
  # the two phase boundaries the stop-at-first case does not cover: document
  # shape before members[], and environments before the chain walk
  printf 'members:\n  - {name: a, repo: r, role: x, contract: c, image: "ghcr.io/a/b:latest"}\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "missing required key: environments"
  lacks "$output" "floating tag"

  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|deploy_target: none|deploy_target: compose|' "$MANIFEST"
  sed -i.bak 's|promotes_from: null|promotes_from: production|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "deploy_target 'compose'"
  lacks "$output" "cycle ("

  # …and the environments SHAPE check belongs to the document-shape phase, so
  # it precedes a member violation
  printf 'members:\n  - {name: a, repo: r, role: x, contract: c, image: "ghcr.io/a/b:latest"}\nenvironments: []\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environments must be a mapping"
  lacks "$output" "floating tag"
}

@test "the validator stops at the FIRST violation (#1744)" {
  # the header calls this a deliberate decision — one round-trip per root cause
  # rather than a wall of cascading noise. Accumulating instead would keep every
  # other case in this file green, since each carries exactly one violation.
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|orders-ui:2.3.1|orders-ui:latest|' "$MANIFEST"
  sed -i.bak 's|promotes_from: staging|promotes_from: qa|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "floating tag"
  lacks "$output" "not a declared environment"
}

@test "the success line's two counts are not interchangeable (#1744)" {
  # every other green fixture has as many members as environments, so a swap of
  # the two variables in the success line would be invisible — and #1745 reads
  # this line
  write_valid_manifest "$MANIFEST"
  sed -i.bak '/^  production:/,/^    deploy_target: none/d' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  contains "$output" "(2 members, 1 environments)"
}

@test "each non-contract exit writes its ONE line to stderr, not stdout (#1744)" {
  # the gather (#1747) reads stderr for the tool escalation and the
  # missing-manifest finding as much as for a contract violation, and the header
  # promises exactly one line — both unpinned while every case merged the streams
  local stub
  run --separate-stderr zsh "$VALIDATOR" --nonsense
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown flag"
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]

  write_valid_manifest "$MANIFEST"
  stub="$(stub_path_without jq)"
  run --separate-stderr env PATH="$stub" /bin/zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  contains "$stderr" "required tool not found"
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]

  run --separate-stderr zsh "$VALIDATOR" --manifest "$BATS_TEST_TMPDIR/absent.yaml"
  [ "$status" -eq 4 ]
  contains "$stderr" "manifest not found"
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]

  # …and ONE line, so a second explanatory print cannot creep in
  sed -i.bak 's|orders-ui:2.3.1|orders-ui:latest|' "$MANIFEST"
  run --separate-stderr zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
}

@test "--help writes the usage line to stdout (#1744)" {
  run --separate-stderr zsh "$VALIDATOR" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: validate-workspace.zsh"
  [ -z "$stderr" ]
}

@test "the manifest defaults to ./.claude-workspace.yaml when NO flag is given (#1744)" {
  # the bare invocation bootstrap (#1745) makes from inside the scaffolded repo;
  # nothing else exercises `repo="."`
  write_valid_manifest "$BATS_TEST_TMPDIR/.claude-workspace.yaml"
  run bash -c "cd '$BATS_TEST_TMPDIR' && zsh '$VALIDATOR'"
  [ "$status" -eq 0 ]
  contains "$output" "./.claude-workspace.yaml is valid"
}

@test "EVERY required environment key is enforced, and each names the environment (#1744)" {
  # derived from ARCHITECTURE's environments table, exactly as the members case
  # is: a row documented as required but never checked must red here
  local keys key
  keys="$(printf '%s' "$CONTRACT_SECTION" \
            | sed -n '/^| `github_environment` |/,/^| `deploy_target` |/p' \
            | sed -E 's/^\| `([a-z_]+)` \|.*/\1/')"
  [ -n "$keys" ]
  contains "$keys" "github_environment"
  contains "$keys" "deploy_target"
  for key in $keys; do
    # promotes_from has its own cases for null vs missing
    if [ "$key" = "promotes_from" ]; then continue; fi
    write_valid_manifest "$MANIFEST"
    sed -i.bak "/^    $key: /d" "$MANIFEST"
    run zsh "$VALIDATOR" --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    contains "$output" "environment 'staging':"
    contains "$output" "missing required key: $key"
  done
}

@test "a required key present but EMPTY is the same defect as an absent one (#1744)" {
  # #1745 renders this manifest from a template, so an unset variable yields
  # `role: ""` rather than a deleted line — a presence-only check would accept it
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|^    role: rest-api|    role: ""|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api':"
  contains "$output" "role"

  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|^    github_environment: staging|    github_environment: ""|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment 'staging':"
  contains "$output" "github_environment"
}

@test "a field that is not a STRING is a named error, not a parsed JSON blob (#1744)" {
  # `image:` written as a block mapping: jq -r prints its JSON, which the tag
  # rules would happily find a colon in — a green verdict on a manifest that
  # pins no image at all
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image:
      repo: ghcr.io/acme/orders-api
      tag: 1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api':"
  contains "$output" "image must be a non-empty string"
  lacks "$output" "is valid"
}

@test "a non-string ENVIRONMENT field is a named error too (#1744)" {
  # the member loop's guard has its own case above; these are the other call
  # sites, each of which could be deleted with the suite green
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment:
      name: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment 'staging':"
  contains "$output" "github_environment must be a non-empty string"

  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
  production:
    github_environment: production
    promotes_from:
      - staging
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment 'production':"
  contains "$output" "promotes_from must be a non-empty string"
}

@test "a non-string member NAME is a named error (#1744)" {
  cat > "$MANIFEST" <<'YAML'
members:
  - name:
      first: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "name must be a non-empty string"
}

@test "a WHITESPACE-ONLY value is as empty as an absent one (#1744)" {
  # what a template renders from a variable that expanded to a space — the
  # same defect as `role: ""`, and the one the length test alone would accept
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|^    role: rest-api|    role: " "|' "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "member 'orders-api':"
  contains "$output" "role must be a non-empty string"
}

@test "an environment name carrying a QUOTE is judged, not mis-reported (#1744)" {
  # the name reaches jq as data, never as program text: pasted in, it would
  # make the filter uncompilable and the error would blame a field that is fine
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  'say"hi':
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  contains "$output" "is valid"
}

@test "a MULTI-LINE environment name is a named error (#1744)" {
  # the roster-completeness guard's own subject: a name carrying a newline
  # splits into two roster entries, each then validated as an environment that
  # does not exist
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  "stag\ning":
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment names must be non-empty, single-line strings"
}

@test "a value carrying a NEWLINE still yields exactly one stderr line (#1744)" {
  # fail() flattens because #1747 quotes this line into a finding: unflattened,
  # a manifest could forge extra lines into whatever reads it. A member NAME
  # cannot carry one any more (its own case above), so the value used here is a
  # promotes_from, which reaches a message that quotes it verbatim.
  write_valid_manifest "$MANIFEST"
  sed -i.bak 's|promotes_from: staging|promotes_from: "stag\\ning"|' "$MANIFEST"
  run --separate-stderr zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  # the value is shown JSON-encoded, so the line break is visible as `\n`
  # rather than silently flattened into a value that looks correct
  contains "$stderr" 'stag\ning'
}

@test "--manifest wins when BOTH flags are given (#1744)" {
  # the shape #1745 may render from two template variables; nothing else
  # exercises the precedence
  write_valid_manifest "$MANIFEST"
  run zsh "$VALIDATOR" --repo "$BATS_TEST_TMPDIR/decoy" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  contains "$output" "$MANIFEST is valid"
}

@test "an environment whose KEY is empty is a named error, not a skipped check (#1744)" {
  # it would otherwise drop out of the roster, be validated by nothing, and
  # still be counted in the success line
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  "":
    github_environment: staging
    promotes_from: null
    deploy_target: none
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment names must be non-empty"
  lacks "$output" "is valid"
}

@test "a DUPLICATED environment key is a named error (#1744)" {
  # YAML resolves the duplicate before jq sees it, so one declaration silently
  # overrides the other — invisible without comparing the two parsers' counts
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
  staging:
    github_environment: staging-2
    promotes_from: null
    deploy_target: compose
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  # NAMED, like every other environment error: a caller quotes the offender
  # into a finding, and "a duplicate exists somewhere" is not quotable
  contains "$output" "environment 'staging':"
  contains "$output" "declared more than once"
  # …and the surviving declaration's OWN defect is not reported instead: the
  # whole-mapping checks run before the per-environment ones, so the author is
  # sent to the shadowed declaration rather than to a deploy target
  lacks "$output" "deploy_target"
  # yq warns on stderr for a duplicated key, so this fixture is also what pins
  # the validator's separate capture of yq's two streams: folded into the
  # document, that warning would be reported as a malformed manifest
  lacks "$output" "malformed YAML"
}

@test "a cycle is named against an environment INSIDE it, not the walk's start (#1744)" {
  # qa's own promotes_from is correct; naming qa would send the author to edit
  # the one environment that is right
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  qa:
    github_environment: qa
    promotes_from: staging
    deploy_target: none
  staging:
    github_environment: staging
    promotes_from: production
    deploy_target: none
  production:
    github_environment: production
    promotes_from: staging
    deploy_target: none
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "environment 'staging':"
  contains "$output" "cycle (staging -> production -> staging)"
  lacks "$output" "environment 'qa':"
}

@test "a BARE @ suffix is a named error, not a skipped digest check (#1744)" {
  write_image_manifest "ghcr.io/acme/orders-api:1.5.0@"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "empty digest suffix"
}

@test "a comment-only manifest is NOT told it has too many documents (#1744)" {
  # yq resolves a comment-only file to `null`, so it lands in the not-a-mapping
  # arm — a named error about what it actually is. The document-count guard must
  # not claim such a file declares several documents, which is the fix it would
  # send the author chasing.
  printf '# only a comment\n' > "$MANIFEST"
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 1 ]
  contains "$output" "the document is not a mapping"
  lacks "$output" "expected a single YAML document"
}

@test "UNDECLARED keys are ignored — the contract is not a schema registry (#1744)" {
  # ARCHITECTURE promises a later child can add a field without turning every
  # already-scaffolded repo red; a strict allow-list would keep every other case
  # in this file green while breaking exactly that
  cat > "$MANIFEST" <<'YAML'
members:
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
    scalable: true
schema_version: 1
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
    notify: slack
YAML
  run zsh "$VALIDATOR" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  contains "$output" "is valid"
}

# ---------------------------------------------------------------------------
# Shape: what this slice ships, and what it does not
# ---------------------------------------------------------------------------

@test "plugin.json's description pins the charter's load-bearing clauses (#1744)" {
  # the marketplace lockstep test above only proves the two descriptions AGREE —
  # deleting a clause from both satisfies it. This pins the content an installer
  # reads, the same way the opentofu sibling does.
  local desc
  desc="$(jq -er '.description' "$PLUGIN_JSON")"
  contains "$desc" "does NOT own the member repos"
  contains "$desc" "can be PRIMARY"
  contains "$desc" "accepts only \`none\`"
  contains "$desc" "no run ever reports a deploy that did not happen"
  contains "$desc" "#1744"
}

@test "the plugin ships exactly the skeleton this slice claims — no skills, no agents (#1744)" {
  # the charter and plugins.md both say so; without this the claim is prose only
  local entries
  # .DS_Store is filtered, not asserted against: Finder drops one into any
  # directory a macOS working copy opens, and an OS artifact must not red a
  # claim about which plugin content ships
  entries="$(ls -A "$PLUGIN_DIR" | grep -v '^\.DS_Store$' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$entries" = ".claude-plugin scripts " ]
  [ ! -d "$PLUGIN_DIR/skills" ]
  [ ! -d "$PLUGIN_DIR/agents" ]
  # …so the generated reference pages carry no section for it yet, and the
  # child that lands the first skill must retire this line deliberately
  run -1 grep -qx "## development-composition" "$REPO_ROOT/docs/reference/commands.md"
  run -1 grep -qx "## development-composition" "$REPO_ROOT/docs/reference/agents.md"
}

@test "the script-tests workflow records the composition tree (#1744)" {
  # the per-plugin path lines are kept as documentation of which tree matters to
  # which suite (the `**` catch-all is what actually triggers it), so this one
  # records that this suite reads development-composition/
  local paths
  paths="$(sed -n '/^    paths:/,/^  push:/p' "$REPO_ROOT/.github/workflows/script-tests.yml")"
  [ -n "$paths" ]
  contains "$paths" "'development-composition/**'"
}
