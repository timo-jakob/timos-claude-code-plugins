#!/usr/bin/env zsh
# review-dispatch.zsh — the review-panel invocation contract for the autonomous
# review loop (epic #557, issue #560).
#
# Why: the review loop's orchestrator (#562) must invoke the right language
# review panel WITHOUT knowing language specifics — mirroring the
# /development:maintenance dispatch contract, where adding a language needs zero
# orchestrator edits. This helper is the seam that maps a repo to its panel and
# scopes review to the STORY'S DIFF, so:
#   - repo-type detection reuses the maintenance detection logic (detect-stack.sh),
#   - the panel is invoked on the changed files (+ their blast radius), never the
#     whole repo — pre-existing findings in untouched code belong to
#     /development:maintenance, not the loop; without diff-scoping round 2
#     re-litigates legacy code and the loop never converges,
#   - an unsupported/ambiguous repo type is a TYPED error the orchestrator
#     surfaces as an escalation instead of crashing.
#
# Round 1 reviews the whole story diff; every round after it is an ITERATION on
# the previous one (#1434), not an independent repeat. `--prior-tree` names the
# working-tree identity the PREVIOUS round's reviewers saw (git-tree-id.zsh), so
# an intermediate round's scope is exactly what that round's fix pass changed —
# and `--final` marks the run's CLOSING FULL SWEEP, the one round after round 1
# that is scoped to the whole story diff again, so a defect only visible in the
# interaction between rounds can never ride out unseen. The loop owns WHEN a
# closing sweep happens (that rule moves with each human grant); this script owns
# only the one descriptor value that decides the scope.
#
# `--repo` NAMES THE REPOSITORY (#1587) — one anchoring rule, all three
# subcommands. Each anchors it via `_repo_anchor`, once, to `git rev-parse
# --show-toplevel`, before anything that DERIVES from it: detection, the
# `.maintenance.yml` primary lookup, both roots, the listings and the default
# `findings_path` then all describe the same tree. (The usability gates and
# `_verify_base` run BEFORE the anchoring and read the raw value — deliberately:
# they judge only whether the path is usable and own the diagnostics that name
# it, and both spellings name the same repository.) "Once" is about the
# ANCHORING, not about the rev-parse count: `plan` re-derives that same toplevel
# later, deliberately — see the two-roots block in `cmd_plan`. A `--repo` naming a
# SUBDIRECTORY is therefore a spelling of its repository, never a scope filter —
# `plan --repo <root>/pkg` and `plan --repo <root>` emit the same descriptor.
# A directory outside any git repository has no toplevel and is its own anchor —
# recognised by git's DISCOVERY fatal specifically, under a pinned C locale.
# Any OTHER failure to anchor — a git fault, a `--repo` with no work tree, or an
# anchored root that is not itself readable and traversable — is refused, exit 1;
# `_repo_anchor`'s header and body carry the reasoning for all three.
#
# Subcommands:
#   detect --repo PATH
#       Emit ONLY the repo type: { repo_type }. No diff, no --base, no
#       changed_files — the resolve-issue conductor calls this at its §1b step
#       to load `development-<repo_type>:resolve-profile`, where the branch is
#       empty and a diff would be wasted work (#1504). It shares `plan`'s
#       detector (`_repo_type`) and its exit codes exactly, so the two can
#       never disagree about a repo.
#
#   plan --repo PATH [--base REF] [--round N] [--findings-path PATH]
#        [--final] [--prior-tree TREE_ID] [--fix-verification PATH]
#        [--adjudicated PATH]
#       Emit the dispatch descriptor JSON on stdout:
#         { repo_type, review_skill, round, base, findings_path, changed_files[],
#           worktree_root, original_root, scope_abs[],
#           scope_mode, scope_empty, prior_tree, delta_files,
#           fix_verification_path, adjudicated_path }
#       worktree_root / original_root / scope_abs are the #1582 path rail. A
#       reviewer that resolves a repo-relative path against its own cwd reads the
#       ORIGINAL checkout whenever the run is in a linked worktree — which is how
#       a repo-root `.claude-plugin/marketplace.json` read from `main` produced a
#       CRITICAL false positive on the #1558 session. Naming both roots in the
#       descriptor is what lets the dispatch tell each reviewer which tree it is
#       reading.
#       worktree_root is the toplevel of the tree under review
#       (`rev-parse --show-toplevel`) — deliberately NOT the RAW `--repo`, which
#       may name a SUBDIRECTORY while changed_files is always repo-root-relative,
#       so prefixing with it would emit paths naming no file. Since #1587 the two
#       coincide by construction (`--repo` is anchored to that same toplevel
#       before anything that DERIVES from it); the derivation is kept because it is what
#       makes the field true of the tree rather than of the caller's spelling.
#       original_root is the main checkout's toplevel (the FIRST entry of
#       `git worktree list --porcelain`) when it differs from worktree_root, and
#       `null` otherwise. `null` asserts only that there is no second checkout to
#       warn a reviewer about — either the --repo IS the main checkout, or the
#       main worktree is BARE (a git directory, not a tree anyone can read). Do
#       not read it as "this is the main checkout".
#       `null` rather than absent, matching prior_tree / fix_verification_path /
#       adjudicated_path, so a consumer can read the key unconditionally.
#       scope_abs is changed_files with worktree_root joined onto each entry:
#       same order, same length, `[]` exactly when changed_files is `[]`. It
#       ACCOMPANIES changed_files and never replaces it — a finding's `.file`
#       stays repo-relative, because that is the spelling `scope-findings`
#       filters on.
#       scope_mode is "full" when `round <= 1 || --final`, else "delta" — `<= 1`
#       because `--round` is contracted as any NON-NEGATIVE integer, and there is
#       no round 0 to iterate on.
#       changed_files keeps its meaning as THE REVIEW SCOPE: the full diff
#       against --base on a full round, and exactly delta_files on a delta one.
#       delta_files is everything differing from --prior-tree — computed whenever
#       the flag is given, INCLUDING on a full round, because the loop needs it to
#       invalidate adjudications whose file the last fix pass touched.
#       scope_empty is `changed_files == []`; it is always present, and it exists
#       for CALLERS — the driving session plans its own panel and must know a
#       delta came back empty BEFORE it spawns reviewers. The loop deliberately
#       does NOT read it: it judges emptiness on the scope file it has already
#       written, after the .review/ + work-dir filtering, which is a strict
#       superset (a repo-internal --work-dir puts the loop's own state inside
#       every delta, so this field would say non-empty while the panel is handed
#       nothing). Round 1's existing "a scope that is ONLY artifacts yields empty
#       changed_files, not an error" behaviour stands either way.
#       --fix-verification / --adjudicated are echoed through as
#       fix_verification_path / adjudicated_path (null when absent) — this script
#       never reads either file; the loop writes them and the reviewers consume
#       them. `--max-rounds` is deliberately NOT a flag here: finality is the
#       loop's rule, and duplicating the ceiling would mean two places to change.
#       repo_type ∈ {swift, python, java, go, claude-plugin, kubernetes};
#       review_skill is the
#       review skill the orchestrator invokes (development-<repo_type>:review),
#       passing changed_files as the review scope. claude-plugin (#809) and
#       kubernetes (#1153) are FALLBACK repo_types: selected only when no
#       supported language matched and detect-stack reports is_claude_plugin /
#       is_kubernetes — a language always wins, and neither fallback
#       participates in the ambiguity tiebreak. They are ORDERED, claude-plugin
#       first: both markers fire on a plugin repo that ALSO carries Kubernetes
#       content, and plugin prose is what such a repo is actually made of.
#       kubernetes additionally requires NO detected language at all (not merely
#       no supported one), so a JS/TS service shipping a Helm chart keeps the
#       typed escalation instead of being reviewed by the manifest panel.
#       The panel writes its aggregate findings JSON (issue #558 schema) to
#       findings_path, which defaults to
#       `<worktree_root>/.review/findings-round-<N>.json` — ABSOLUTE, and the
#       same for every spelling of `--repo`, because `--repo` is anchored
#       (#1587). It is a real default rather than a placeholder:
#       resolve-story-loop.zsh passes no `--findings-path` and consumes it
#       directly, resolving it against the LOOP's cwd, so a relative spelling was
#       correct only when the loop ran from the repo root. Anchoring it also puts
#       the sink at the repo root, where `_normalise_paths`' start-anchored
#       `.review/` exclusion already drops it from every scope.
#       On an unsupported or ambiguous repo type, print a typed
#       error object and exit 3 (see Exit codes).
#
#   scope-findings --repo PATH [--base REF] --findings FILE
#       Read the panel's aggregate findings array (FILE) and print only the
#       findings whose `file` is inside the story's diff — dropping anything in
#       untouched code. Once `--repo` anchors and `--base` resolves, a
#       missing/empty FILE prints []; an unusable or un-anchorable `--repo` is
#       exit 1 even when FILE is absent, since the shortcut sits deliberately
#       BELOW those checks. This enforces the
#       "findings outside the story's diff do not appear" contract downstream of
#       whatever the panel reported.
#
# Seams (for tests / non-PATH installs):
#   DETECT_STACK_BIN  overrides the detect-stack.sh binary (must emit the same
#                     JSON, at least the `.languages` array; `.is_claude_plugin`
#                     and `.is_kubernetes` are read with a false default when
#                     absent).
#   GIT_BIN           overrides the `git` binary. It is also handed to
#                     git-tree-id.zsh (as its own GIT_TREE_ID_BIN seam) when the
#                     delta is computed, so ONE override covers every git call.
#
# Exit codes:
#   0  success — the repo type (detect), the descriptor (plan) or the
#      filtered array (scope-findings) on stdout; or, for -h/--help, the
#      usage string, which is the one exit-0 stdout that is NOT a document
#   2  usage error — an unknown flag or subcommand, a value-taking flag with no
#      value, a `--round` that is not a non-negative integer, or a `--round > 1`
#      carrying neither `--final` nor `--prior-tree` (there is no silent fallback
#      to the full diff: a round that cannot say what it is iterating on has no
#      scope). Every one of these is checked at PARSE time, so the message names
#      the flag rather than surfacing later as a zsh nounset abort or a jq
#      --argjson parse error.
#   3  typed escalation — unsupported or ambiguous repo type; a JSON error object
#      { error, ... } is printed on stdout for the orchestrator to relay
#   1  internal error — detect-stack / git / jq failed, a `--prior-tree` that
#      does not resolve to a tree-ish in the repo, an unreadable
#      `.maintenance.yml` primary key (#1588 — the repo itself is fine, a file
#      inside it is not; reaches `detect` as well as `plan`, since both go
#      through `_repo_type`), or `--repo` names
#      something unusable (absent, not a directory, not readable/traversable),
#      or a `--repo` that cannot be ANCHORED (#1587) — a git fault, a path with
#      no work tree (a bare repository, or inside `.git/`), or an anchored root
#      that is not itself readable and traversable. The one anchoring failure
#      that is NOT an error is git's DISCOVERY fatal, `not a git repository
#      (or any …)`: that directory is its own root. The `not a git repository:
#      <path>` GITFILE fatal is a broken repository and IS refused — the two
#      share a prefix and mean opposite things.
#      Note the split from 2: a MISSING `--repo` is a usage error (2), a `--repo`
#      that is present but unusable is this one, because the invocation was
#      well-formed and the environment is what failed.

emulate -L zsh
setopt nounset pipefail

# These override `git -C "$repo"` and would silently make every git call here
# describe a DIFFERENT repository — exported by git hooks, filters and some CI
# wrappers. `git-tree-id.zsh` unsets exactly these for exactly this reason. It
# matters more since #1582: `worktree_root` / `original_root` are now the values
# every reviewer prompt is built from, so a wrong root sends the whole panel to
# read the wrong checkout with no visible symptom — the #1558 failure this rail
# exists to prevent.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

local self_dir="${0:A:h}"
local detect_bin="${DETECT_STACK_BIN:-${self_dir}/../../bootstrap/scripts/detect-stack.sh}"
local git_bin="${GIT_BIN:-git}"
# The delta is computed against the SAME working-tree identity the loop persists
# per round (#981/#1434), so the two must be one implementation — hence the
# sibling script rather than a second inlined `write-tree` here.
local tree_id_bin="${self_dir}/git-tree-id.zsh"

die_usage() { print -u2 -- "$1"; exit 2 }

# A value-taking flag must be followed by its value. Called as
# `need_value <subcommand> "$@"` from inside the parse loop, so $2 is the flag
# and $3 its value — present only when the caller supplied one. Without this,
# `setopt nounset` turns a trailing `--round` into a raw abort (exit 1) instead
# of the exit-2 usage path the header documents.
# Three shapes, not one — the contract both sibling scripts (`_need_val` in
# resolve-story-loop.zsh and consolidate-findings.zsh) have carried for a while,
# and which this one was missing. #1434 routed three new value flags through
# here, and the gap bites hardest on them:
#   * a FLAG-SHAPED value, the realistic unquoted `--prior-tree $VAR` with VAR
#     unset, assigns the NEXT flag as the value. `--prior-tree --final` then
#     swallows `--final`, so the round is planned as a delta and
#     `_verify_prior_tree` fails with "does not resolve to a tree: --final" —
#     exit 1 (internal error) with a confidently wrong cause, where a malformed
#     invocation is contracted as exit 2;
#   * an EXPLICITLY EMPTY value reads downstream as "flag omitted" at exit 0:
#     `--fix-verification ""` / `--adjudicated ""` emit a null path, so the
#     round's panel silently gets no carry and no waived list.
need_value() {
  (( $# >= 3 )) || die_usage "$1: $2 requires a value"
  [[ "$3" != --* ]] || die_usage "$1: $2 requires a value (got the flag $3)"
  [[ -n "$3" ]] || die_usage "$1: $2 requires a non-empty value"
}

# --- repo-relative changed files = the story's diff -------------------------
# Everything that differs from the base ref (committed + staged + unstaged for
# tracked files) plus new untracked files — the story's blast radius as seen in
# the worktree. base defaults to origin/main. The loop's OWN outputs — the
# per-round findings under .review/ and the telemetry JSONL (#566) — must never
# enter the scope (#909): on a repeat/resumed run they are untracked files in
# the repo, and without this exclusion the panel would be directed to review
# prior rounds' findings as story code. The exclusion covers the DEFAULT
# artifact locations only (a caller-overridden --findings-path elsewhere in the
# repo is not followed), and it applies to tracked changes under these prefixes
# too — runtime JSONL is never review scope. sed (not grep -v) so an
# all-artifact scope yields empty output with exit 0 under pipefail, not a
# pipeline failure.
#
# The normalisation + exclusion half is factored out because the DELTA scope
# (#1434) must go through the very same rules: one file-listing path, so a
# `.review/` artifact excluded from a full round can never sneak into a delta
# round, and a `./`-prefixed spelling can never make the two disagree.
# The artifact exclusions stay START-ANCHORED. That is a deliberate contract, not
# an oversight: a nested `src/.review/` inside story code is story code, and
# `plan: the exclusion is start-anchored — nested/lookalike paths stay in scope`
# pins it. Matching at any depth would silently drop those files from every
# review scope.
#
# The start-anchored patterns are ENOUGH because `--repo` is anchored (#1587):
# every subcommand resolves it to the git toplevel before anything that DERIVES from it, so
# the DEFAULT sink is always `<worktree_root>/.review/…` and these listings —
# repo-root-relative since #1582 — always spell it `.review/…`, which the first
# pattern deletes. The gap this comment used to document (a subdirectory
# `--repo` putting the sink at `pkg/.review/…`, which no start-anchored pattern
# can match without also dropping the nested story file above) is closed at the
# anchoring site, so nothing here needs to widen.
_normalise_paths() {
  sed -E 's#^\./##' | sort -u \
    | sed -e '/^$/d' -e '\#^\.review/#d' -e '\#^\.claude/telemetry/#d'
}

_changed_files() {
  local repo="$1" base="$2"
  # A failed diff or ls-files must FAIL the scope computation (#910) — the old
  # 2>/dev/null swallow let an unresolvable base degrade to an empty/garbage
  # scope on which the loop happily CONVERGED. Base resolvability is validated
  # up front by _verify_base, so a failure here is a genuine git error.
  # `-c core.quotePath=false` on both listings (#1435): the default TRUE emits a
  # non-ASCII path as `"src/caf\303\251.zsh"`, quotes and octal escapes included,
  # so such a file could never match the plain UTF-8 `.file` a reviewer reports —
  # it would be silently absent from the scope, and absent from the fix-touched
  # set that shares this normalisation.
  # BOTH listings are repo-root-relative and repo-WIDE regardless of where
  # `--repo` points — and since #1587 that comes from the ANCHORING: both callers
  # resolve `repo` to the toplevel first, so this function only ever runs AT the
  # repo root, where there is no subdirectory for a listing to be relative to or
  # scoped by.
  #
  # ALL THREE flags — `:/`, `--full-name`, `--no-relative` — are therefore
  # DEFENCE IN DEPTH since #1587: the anchoring above already delivers the
  # property they were added for. They are kept because they kill the class
  # outright rather than the one route to it that anchoring closed — but no
  # fixture can discriminate any of them any more, so do not read their
  # rationales, or the #1582 cases that drive them, as live guards.
  #
  # Historically (pre-#1587) `--no-relative` was the load-bearing one: a
  # user-level `diff.relative=true` made `git diff` emit cwd-relative paths and
  # drop everything outside the cwd, which a pathspec does not countermand, so
  # without it the two halves disagreed and `scope_abs` prefixed a
  # subdirectory-relative entry with the repo root, naming a file that did not
  # exist.
  {
    "$git_bin" -C "$repo" -c core.quotePath=false diff --name-only --no-relative "$base" -- ':/' \
      || return 1
    "$git_bin" -C "$repo" -c core.quotePath=false ls-files --others --exclude-standard \
      --full-name ':/' || return 1
  } | _normalise_paths
}

# --- the two tree roots the reviewers must be told about (#1582) ------------
# The tree under review. From the git TOPLEVEL, never from the RAW `--repo`:
# this script accepts any readable directory there, while `changed_files` is
# always repo-root-relative, so a `--repo` naming a subdirectory would produce
# `scope_abs[]` entries that name no file at all. Since #1587 this is also the
# function the anchoring rule itself is built on (`_repo_anchor`, below), so by
# the time a subcommand calls it the two agree — it stays the derivation rather
# than a re-read of the flag, which is what keeps that agreement a fact about
# the tree instead of an assumption about the caller.
_worktree_root() {
  local repo="$1" root=""
  root=$("$git_bin" -C "$repo" rev-parse --show-toplevel) || return 1
  [[ -n "$root" ]] || return 1
  print -r -- "$root"
}

# THE anchoring rule for `--repo` (#1587). `--repo` names the REPOSITORY, not a
# subdirectory of it: every subcommand resolves it here, ONCE, before anything
# that DERIVES from it — detection (`_detect_json`'s `cd`), the `.maintenance.yml` primary
# lookup, both roots, the listings and the default `findings_path` all describe
# the SAME tree. Before this, the listings were repo-wide (#1582) while
# detection and the sink tracked whatever directory `--repo` happened to name —
# so `plan --repo <root>/pkg` picked a panel from one subtree's stack and handed
# it the whole repo's diff, and put the sink at `pkg/.review/…`, which no
# start-anchored exclusion can drop without also dropping the nested story file
# `_normalise_paths` is contracted to keep.
#
# The fallback is keyed on the CAUSE, never on the status. Exactly one failure
# means "there is no repository here": git's DISCOVERY fatal, `not a git
# repository (or any …)`, read under a pinned C locale — two disciplines the body
# below explains, and the enum is only closed because of them. That
# directory IS its own root — the only answer available, and the one that keeps
# `detect: #1504 a --repo beginning with a dash is detected, not misattributed`
# true, whose fixture is a bare `mkdir` with a `.maintenance.yml` and no
# `git init`. `detect` is the subcommand that reaches it in the ordinary course,
# having no `_verify_base` in front of it.
#
# EVERY OTHER non-zero exit is a fact about the MACHINE, and is refused with a
# named line and git's own stderr. Falling back on those instead would silently
# anchor at a SUBDIRECTORY — reproducing on the error path the exact
# misattribution this rule exists to remove, at exit 0 with nothing on either
# stream. The realistic causes are not exotic: a `detected dubious ownership`
# refusal (routine wherever the checkout is owned by another uid — containers,
# CI), and a `GIT_BIN` seam naming a missing binary. The dubious-ownership
# refusal has a fixture; a missing `GIT_BIN` reaches the same arm by the same
# route (its command-not-found text cannot match the discovery needle) and is
# unfixtured. The list is deliberately short: the previous cut of it named an
# unreadable `.git`, which takes the FALLBACK, and a corrupt object store, which
# does not fail the probe at all — see the KNOWN LIMIT below.
# It is the same rule `_primary` and every jq read here already
# follow (#1177/#1588): a dead tool is never a verdict about the repo.
#
# KNOWN LIMIT, stated rather than assumed away, and it is NOT uniformly benign.
# Two shapes are indistinguishable from "no repository here" AT THIS SEAM:
#   * a repository whose `.git` cannot be VALIDATED — `is_git_directory()` opens
#     `HEAD` and stats `objects`/`refs`, so a `.git` at mode 000 fails validation
#     and discovery simply continues UPWARD. (An earlier cut of this comment
#     listed an unreadable `.git`, and a corrupt object store, among the REFUSED
#     faults. Both were wrong: the first lands here, and the second does not fail
#     the probe at all — discovery succeeds and `--show-toplevel` answers.)
#   * a root that lies across a filesystem boundary from `--repo`, where git
#     stops at the mount point and says `(or any parent up to mount point …)` —
#     which means "discovery stopped", not "there is no repository".
#
# What follows depends on TWO things — what lies above `--repo`, and whether
# `--repo` is the root or a subdirectory. Both matter, and an earlier cut of
# this block tracked only the first:
#   - AN ENCLOSING repository — discovery SUCCEEDS at it. `_repo_anchor` takes
#     its success branch and the anchor is a DIFFERENT tree, at exit 0, with no
#     diagnostic anywhere; `_verify_base` does not catch it either, since
#     `rev-parse --git-dir` discovers that same enclosing repo. This is not
#     hypothetical here: linked worktrees live under `<main>/.claude/worktrees/`,
#     inside the main checkout's tree, and a vendored plain clone is the general
#     shape.
#   - NO enclosing repository — discovery ends in the discovery fatal and the
#     fallback anchors at `--repo` ITSELF. Benign only when `--repo` is the
#     repository ROOT: anchoring there is the right answer. With a SUBDIRECTORY
#     `--repo` it is not — the anchor is that subdirectory, and while `plan` and
#     `scope-findings` still refuse upstream at `_verify_base`, `detect` does
#     not: `_detect_json` cds into it and `_primary` reads its own
#     `.maintenance.yml`, so a repo_type computed from ONE SUBTREE is emitted at
#     exit 0 with nothing on stderr — the subdirectory misattribution this rule
#     exists to remove, reached by the fallback. The MOUNT-BOUNDARY shape lands
#     in exactly this arm for the same reason (git refuses to cross to the real
#     root, so its wording matches and the fallback fires); it is not exempt.
# None of it is guarded, and cannot be at this seam: git answered, and the
# answer is indistinguishable from a correct one. It is recorded so a reader
# triaging a wrong `detect` type has the case in front of them.
#
# `--repo` NAMING A REPOSITORY WITH NO WORK TREE — a bare repo, or a path inside
# `.git/` — lands here too, and is refused rather than anchored. It is NOT
# unreachable from `plan`/`scope-findings`, and an earlier draft of this comment
# wrongly said it was: `_verify_base` probes `rev-parse --git-dir`, which
# SUCCEEDS for both of those while `--show-toplevel` fails with `this operation
# must be run in a work tree`. Left to the old blanket fallback, `plan --repo
# <some.git>` anchored on the raw path and surfaced as an exit-3
# `unsupported_repo_type` — a verdict about the repo when the truth is that the
# path has no tree to review.
#
# The happy path is ONE git call. The second probe runs only after a failure,
# to recover the stderr the first discarded — no temp file, and no cost on the
# path every real invocation takes.
_repo_anchor() {
  local repo="$1" root="" err="" rc=0
  root=$(_worktree_root "$repo" 2>/dev/null); rc=$?
  if (( rc == 0 )) && [[ -n "$root" ]]; then
    # Gate the ROOT, not just the caller's `--repo`. The subcommands' own
    # `-d`/`-r`/`-x` gates ran on the raw value, and with a subdirectory `--repo`
    # that is a DIFFERENT directory from the one every reader below now uses: a
    # root at mode 0711 owned by ANOTHER uid — or 0311 for the running user, the
    # shape the bats fixture needs, since 0711 grants its owner rwx — is
    # reachable through a readable `pkg/`, and `_detect_json`
    # would then report no languages and the run would exit 3 with an
    # `unsupported_repo_type` verdict about a repo it simply could not read.
    # One site here covers all three subcommands.
    [[ -r "$root" && -x "$root" ]] || {
      print -u2 -- "review-dispatch: the repository root is not a readable directory: $root"
      return 1
    }
    print -r -- "$root"; return 0
  fi
  # `LC_ALL=C LANGUAGE=C` is what makes the substring test below LEGITIMATE.
  # git marks these fatals for translation, so under a non-English locale the
  # no-repository message is localised, the match fails, and the one documented
  # success path — `detect` on a plain directory — would refuse. CI runs in the
  # C locale, so nothing here could have caught that. `LANGUAGE` is set as
  # belt-and-braces, NOT as an independent necessity: gettext ignores `LANGUAGE`
  # under a C locale, so `LC_ALL=C` is the load-bearing half. Do not drop
  # `LC_ALL` and keep `LANGUAGE` on the assumption that either alone suffices.
  err=$(LC_ALL=C LANGUAGE=C "$git_bin" -C "$repo" rev-parse --show-toplevel 2>&1 >/dev/null)
  # Match the DISCOVERY form only. git emits two distinct fatals carrying
  # `not a git repository`, and they mean opposite things:
  #   `not a git repository (or any of the parent directories): .git`
  #     — and the `(or any parent up to mount point …)` variant — is the genuine
  #     "there is no repository here", the case that anchors to itself;
  #   `not a git repository: <path>` is a BROKEN repository: a `.git` FILE
  #     pointing at a gitdir that is gone, which is exactly what `git worktree
  #     prune` or a moved/copied linked worktree leaves behind. This repo runs
  #     everything in worktrees, so it is reachable here.
  # A bare `not a git repository` test matches both, so the broken-worktree case
  # would anchor on the raw path at exit 0 with nothing on either stream — the
  # silent misattribution this whole function exists to refuse. `(or any` is the
  # shortest prefix that separates them and covers both discovery wordings.
  # CASE-FOLDED and ANCHORED at git's own `fatal: ` at a line start. Folded
  # because git emitted `Not a git repository (or any …)` before the message
  # lowercasing, so an older git would otherwise refuse the one documented
  # success path — the same class the C pin closes. Anchored because `$err`
  # interpolates caller-supplied paths on other fatals, and an unanchored
  # substring lets a path impersonate the cause; the whole point of keying on
  # the cause is that the enum stays closed.
  if [[ $'\n'"${err:l}" == *$'\n'"fatal: not a git repository (or any"* ]]; then
    print -r -- "$repo"; return 0
  fi
  # Always name a cause. The re-probe can legitimately come back empty — a git
  # that exits 0 printing nothing (the #1582 blank-toplevel shape), or a race in
  # which the second call succeeds where the first failed — and a bare refusal
  # naming no reason is hardest to act on in exactly the case hardest to
  # reproduce.
  # `$rc` is `_worktree_root`'s status, NOT git's, and the wording says so. On
  # the #1582 blank-toplevel shape — the very case this arm exists for — git
  # exits 0 and the wrapper returns 1 because the root came back empty, so
  # calling it "git's exit" would send a reader hunting for a git fault that
  # never happened.
  [[ -n "$err" ]] || \
    err="the first probe returned no usable root and no error (wrapper status $rc)"
  print -u2 -- "review-dispatch: could not resolve the repository root for ${repo}: $err"
  return 1
}

# The ORIGINAL checkout's toplevel. `git worktree list --porcelain` lists the
# main worktree FIRST — the documented shape, and it needs no special-casing for
# an unusual common dir the way `dirname $(rev-parse --git-common-dir)` would.
#
# Read the listing into a variable rather than piping it into awk. An `awk … exit`
# on the first match SIGPIPEs the producer once its output exceeds one buffer —
# roughly 20 linked worktrees at ~190 porcelain bytes each — git re-raises the
# signal (141), and `pipefail` promotes that to the pipeline status, so the
# `|| return 1` below would fire for a perfectly healthy repo and abort every
# plan. Measured, not reasoned: the same pipeline returns 0 on a short listing
# and 141 on a long one. `verify-reference-move.zsh` documents this exact hazard
# for its own awk, which is why this reads the whole listing instead.
#
# A BARE main worktree is reported as no original checkout at all. Its porcelain
# block carries a lone `bare` line, and its path names a git directory rather
# than a tree — rendering it into the reviewer sentence would point the panel at
# something it cannot read. Empty here means `null` in the descriptor, which is
# the truthful answer: there is no original checkout to confuse a reviewer with.
# Written without a `for … in` loop deliberately: a `^  for l in <…>; do` line in
# this file is parsed by the suites as THE repo-type enumeration site, so such a
# loop here yields a bogus type. Stated as the invariant rather than as a roster
# of the suites that rely on it (#1588) — there are two today,
# `resolve-profile-contract.bats` and `review-dispatch.bats`, and a named list
# goes stale as sites are added. Parameter expansion keeps the two apart.
_main_root() {
  local repo="$1" listing="" block="" root=""
  listing=$("$git_bin" -C "$repo" worktree list --porcelain) || return 1
  # porcelain separates entries with a blank line, so the FIRST block is the
  # main worktree's
  block="${listing%%$'\n\n'*}"
  # a lone `bare` line in that block: the main worktree is a bare repo, which is
  # a git directory rather than a checkout — report no original root at all
  [[ $'\n'"$block"$'\n' == *$'\nbare\n'* ]] && return 0
  local -a hits
  hits=("${(@M)${(@f)block}:#worktree *}")
  (( ${#hits} )) || return 1
  root="${hits[1]#worktree }"
  [[ -n "$root" ]] || return 1
  print -r -- "$root"
}

# --- the delta since the previous round's tree (#1434) ----------------------
# Everything differing between --prior-tree and the CURRENT working tree. Both
# sides are `git add -A` trees (git-tree-id.zsh), so tracked edits, deletions and
# untracked additions are compared by one uniform rule — where `git diff <tree>`
# would see only what the index knows and mis-report a file that was untracked at
# the prior identity. Prior-tree resolvability is validated up front by
# _verify_prior_tree, so a failure here is a genuine git/identity error and must
# FAIL the scope rather than degrade to an empty delta (the #910 rule: an empty
# scope the loop would happily converge on is the worst possible fallback).
_delta_files() {
  local repo="$1" prior="$2" cur=""
  [[ -x "$tree_id_bin" ]] || {
    print -u2 -- "review-dispatch: cannot compute the delta — $tree_id_bin is missing or not executable"
    return 1
  }
  cur=$(GIT_TREE_ID_BIN="$git_bin" "$tree_id_bin" "$repo") || {
    print -u2 -- "review-dispatch: could not compute the current working-tree identity for $repo"
    return 1
  }
  [[ -n "$cur" ]] || {
    print -u2 -- "review-dispatch: the current working-tree identity for $repo came back empty"
    return 1
  }
  # same normalisation + #909 exclusions as the full scope — `pipefail` is set,
  # so a failing diff-tree still fails the function rather than yielding an
  # empty delta
  # same `core.quotePath=false` rule as _changed_files above (#1435)
  "$git_bin" -C "$repo" -c core.quotePath=false diff-tree -r --name-only "$prior" "$cur" \
    | _normalise_paths
}

# --- base ref must resolve before it scopes anything (#910) -----------------
# An unresolvable --base (a typo, an unfetched remote, a worktree before its
# first fetch) must be a fast, named failure — not a silently empty scope that
# lets the loop exit CONVERGED on code no panel ever saw.
_verify_base() {
  local repo="$1" base="$2"
  # name the actual culprit: a non-repo path must not read as a bad ref
  "$git_bin" -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
    print -u2 -- "review-dispatch: --repo is not a git repository: $repo"
    return 1
  }
  "$git_bin" -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || {
    print -u2 -- "review-dispatch: --base does not resolve to a commit in $repo: $base"
    return 1
  }
}

# --- prior tree must resolve before it scopes anything (#1434) --------------
# Exactly _verify_base's argument, one round later: an unresolvable --prior-tree
# (a truncated id, a tree gc'd out of a foreign object DB, a work-dir carried to
# another clone) must be a fast, NAMED failure. Degrading to the full diff would
# silently turn every intermediate round back into an independent repeat, and
# degrading to an empty delta would let the loop converge on code no panel saw.
# `^{tree}` deliberately, not `^{commit}`: the identity the loop persists is a
# tree, and a commit-ish is accepted only because it peels to one.
_verify_prior_tree() {
  local repo="$1" prior="$2"
  "$git_bin" -C "$repo" rev-parse --verify --quiet "${prior}^{tree}" >/dev/null 2>&1 || {
    print -u2 -- "review-dispatch: --prior-tree does not resolve to a tree in $repo: $prior"
    return 1
  }
}

# --- full detection JSON via the reused detection logic ---------------------
_detect_json() {
  local repo="$1" out rc err_file
  # RELAY detect-stack's stderr rather than dropping it (#1177). Since detect-
  # stack grew an error contract, its non-zero exit carries its whole meaning
  # there ("the kubernetes marker search did not complete (find exit N, grep
  # exit M)"). Swallowing it leaves the operator with a bare "detect-stack
  # failed" and no way to tell a permissions problem from a missing binary — and
  # that named message is the deliverable the hardening exists to produce.
  # A temp FILE, not `2>&1` around the assignment: `out=$( … )` inside a command
  # substitution runs in a subshell, so the captured JSON would be discarded
  # with it. `cd --`, because `[[ -d ]]` passes for a path starting with `-`
  # that `cd` would read as an option and blame on the wrong culprit.
  # DEGRADE, never fail, when the buffer cannot be made: it exists only to
  # forward a diagnostic and is not needed on the success path, so an unwritable
  # TMPDIR must not fail a repo this could otherwise plan.
  err_file=$(mktemp) || {
    print -u2 -- "review-dispatch: no temp file — detect-stack's stderr will not be relayed"
    err_file=""
  }
  if [[ -n "$err_file" ]]; then
    out=$( cd -- "$repo" && "$detect_bin" 2>"$err_file" ); rc=$?
  else
    out=$( cd -- "$repo" && "$detect_bin" ); rc=$?
  fi
  if (( rc != 0 )); then
    print -u2 -- "review-dispatch: detect-stack failed for $repo (exit $rc)"
    [[ -n "$err_file" && -s "$err_file" ]] && print -u2 -r -- "$(<"$err_file")"
    [[ -z "$err_file" ]] || rm -f "$err_file"
    return 1
  fi
  [[ -z "$err_file" ]] || rm -f "$err_file"
  # jq's own parse error is RELAYED, not suppressed — same argument as above: it
  # names WHERE the document went wrong, which the message below cannot.
  print -r -- "$out" | jq -c . || {
    print -u2 -- "review-dispatch: could not parse detect-stack output"; return 1
  }
}

# --- .maintenance.yml primary (dependency-free, mirrors maintenance SKILL) --
# No early-exiting pipeline consumer here (#1582's sweep). `… | head -1` closes
# the pipe after one line, SIGPIPEs the producer, and `setopt pipefail` promotes
# that 141 to the pipeline's status — the shape that made `_main_root` abort
# every plan on a repo with enough worktrees. Nothing misbehaves here today (the
# caller discards the status, and a `.maintenance.yml`'s handful of matching
# lines never fills a pipe buffer), but leaving the last instance of a swept
# pattern in place is how it comes back. One `sed` that quits after the first
# match does the whole job with no pipe at all.
_primary() {
  local repo="$1"
  # The absent file is the ordinary case and yields "no primary" — but only that
  # case. Left to a blanket `2>/dev/null`, an UNREADABLE or unparseable
  # `.maintenance.yml` produced the same empty answer, and the ambiguity
  # escalation then told a human to "set .maintenance.yml primary to one of the
  # candidates" for a repo that has already recorded one: the confidently-wrong
  # cause `_detect_json`'s stderr relay exists to avoid.
  [[ -f "$repo/.maintenance.yml" ]] || return 0
  sed -nE '/^[[:space:]]*primary:/{
             s/^[[:space:]]*primary:[[:space:]]*//
             s/[[:space:]]*(#.*)?$//
             s/^["'\'']//
             s/["'\'']$//
             p; q
           }' "$repo/.maintenance.yml"
}

# --- THE repo-type detector, shared by `plan` and `detect` (#1504) ---------
# Sets the global REPO_TYPE. Deliberately NOT a command substitution: an
# unsupported/ambiguous repo emits its TYPED object on stdout and exits 3, and
# an internal failure exits 1 — inside `$( … )` both the document and the exit
# would be captured by a subshell, so the caller would read an empty repo_type
# at exit 0 and dispatch a panel for a repo whose type was never determined.
# $2 is the caller's subcommand name, so every diagnostic RAISED HERE still says
# which invocation failed — the one thing lifting this out of cmd_plan could
# lose. `_detect_json`'s own three messages keep the script-wide
# `review-dispatch:` prefix, deliberately: they name a failure of the detector
# itself rather than of either subcommand's invocation.
typeset -g +x _RD_REPO_TYPE=""
_repo_type() {
  local repo="$1" ctx="$2"
  local detect_json; detect_json=$(_detect_json "$repo") || exit 1
  # All three reads CHECK jq's status (#1177), like the `lang_count` read below.
  # They already failed closed — an empty value matches neither "true" nor a
  # language — so no misroute was reachable; what was wrong is the STATUS. The
  # header contract promises exit 1 (internal error) for a jq failure, and an
  # unchecked read delivered exit 3 instead, telling the orchestrator to escalate
  # an "unsupported repo type" it never determined. A typed escalation is a
  # verdict about the repo; a dead jq is a verdict about the machine.
  local langs_json; langs_json=$(print -r -- "$detect_json" | jq -c '.languages // []') || {
    print -u2 -- "${ctx}: could not read .languages from the detect-stack output"; exit 1
  }
  # `// false` default: an older detect-stack without the key falls through to
  # the clean typed error below rather than crashing (#809).
  local is_plugin; is_plugin=$(print -r -- "$detect_json" | jq -r '.is_claude_plugin // false') || {
    print -u2 -- "${ctx}: could not read .is_claude_plugin from the detect-stack output"; exit 1
  }
  # same `// false` default, same reason (#1153): an older detect-stack without
  # the key falls through to the typed error rather than crashing.
  local is_k8s; is_k8s=$(print -r -- "$detect_json" | jq -r '.is_kubernetes // false') || {
    print -u2 -- "${ctx}: could not read .is_kubernetes from the detect-stack output"; exit 1
  }

  # supported review languages present, preserving nothing but membership
  local -a supported
  local l
  # the last jq whose failure was read as a VERDICT (#1177): `jq -e` exits 1 for
  # false/null but 5 for a program error, and treating both as "this language is
  # absent" turns four jq errors into an `unsupported_repo_type` claim about the
  # repo. Same rule as every other read here — a dead jq is a fact about the
  # machine, not about the repo.
  local probe_rc
  for l in swift python java go; do
    print -r -- "$langs_json" | jq -e --arg l "$l" 'index($l) != null' >/dev/null 2>&1
    probe_rc=$?
    (( probe_rc <= 1 )) || {
      print -u2 -- "${ctx}: could not test the detected-language set for $l"; exit 1
    }
    (( probe_rc == 0 )) && supported+=("$l")
  done

  local repo_type=""
  if (( ${#supported} == 0 )); then
    # Fallbacks ONLY (#809, #1153): these repos detect no language — a plugin
    # repo's content is prose, agent definitions, zsh scripts and JSON
    # manifests; a GitOps repo's is charts, overlays and Argo CD resources.
    # A detected language always wins, and neither joins the `.maintenance.yml`
    # primary tiebreak (which lives in the multi-language `else` branch below).
    #
    # ORDER IS LOAD-BEARING: both markers fire on a plugin repo that ALSO
    # carries Kubernetes content, and such a repo's content is plugin prose, so
    # it must be reviewed by the plugin panel. This repo becomes exactly that
    # case once #1155 lands its Kubernetes fixtures under tests/fixtures/ —
    # reversing these two would then point its own review loop at a manifest
    # panel. (Today is_kubernetes is false here, so only one marker fires.)
    # The kubernetes fallback additionally requires NO detected language at all,
    # not merely no SUPPORTED one. `supported` is the intersection with the four
    # panel languages, so it is empty both for a language-less GitOps repo and
    # for, say, a JavaScript service — and `is_kubernetes` is a topic marker that
    # composes with any language, so a JS/TS service that ships its own Helm
    # chart (a very ordinary shape) would otherwise be handed to the manifest
    # panel for a story whose diff is JS. That panel has no competence there: it
    # would converge finding-free and the loop would record a clean review that
    # never happened. Such a repo keeps the typed `unsupported_repo_type`
    # escalation, which names the languages so a human can route it.
    #
    # claude-plugin deliberately does NOT carry that extra condition (#809): a
    # `.claude-plugin/plugin.json` is definitional for what the repo *is*, and
    # a plugin repo carrying one unsupported-language file is still a plugin
    # repo. A `Chart.yaml` is routinely incidental to an application repo.
    # NOT `local -i`, and the status IS checked — both deliberate. zsh
    # arithmetic-evaluates an empty string assigned to an integer-attributed
    # parameter to **0**, and 0 is precisely the value that OPENS this gate. So
    # an unchecked `-i` read would fail OPEN: a jq that died, or an empty
    # `$langs_json` from a failed earlier read, would hand a language-bearing
    # repo to the manifest panel — reproducing on the error path the exact
    # misrouting this guard exists to prevent. Fail closed instead, with the
    # exit-1 internal-error status the header contract promises.
    local lang_count
    lang_count=$(print -r -- "$langs_json" | jq 'length') || {
      print -u2 -- "${ctx}: could not compute the detected-language count"; exit 1
    }
    [[ "$lang_count" == <-> ]] || {
      print -u2 -- "${ctx}: non-numeric language count: ${lang_count:-<empty>}"; exit 1
    }
    if [[ "$is_plugin" == "true" ]]; then
      repo_type="claude-plugin"
    elif [[ "$is_k8s" == "true" ]] && (( lang_count == 0 )); then
      repo_type="kubernetes"
    else
      jq -nc --argjson langs "$langs_json" \
        '{error:"unsupported_repo_type", languages:$langs, supported:["swift","python","java","go"],
          detail:"no review panel exists for the detected languages"}'
      exit 3
    fi
  elif (( ${#supported} == 1 )); then
    repo_type="${supported[1]}"
  else
    # The status IS read (#1588), for the same reason every jq read above is: an
    # UNREADABLE (not absent) `.maintenance.yml` leaves `primary` empty, and an
    # unchecked read then falls into the `ambiguous_repo_type` branch below —
    # telling a human to "set .maintenance.yml primary to one of the candidates"
    # for a repo that may already carry one. That is a verdict about the REPO
    # where the truth is a fact about the MACHINE, the confidently-wrong cause
    # `_primary`'s own comment says it exists to avoid. The absent file is not
    # this case: `_primary` returns 0 for it, so the ordinary "no primary" path
    # still reaches the escalation.
    local primary
    primary=$(_primary "$repo") || {
      print -u2 -- "${ctx}: could not read the .maintenance.yml primary key for $repo"; exit 1
    }
    if [[ -n "$primary" ]] && (( ${supported[(Ie)$primary]} )); then
      repo_type="$primary"
    else
      # the candidate list is CHECKED before it is passed (#1177): an unchecked
      # inner substitution that failed would leave `--argjson cand ''`, jq would
      # reject it, and the `exit 3` below would still run — telling the
      # orchestrator to escalate while handing it nothing to relay.
      local cand_json
      cand_json=$(printf '%s\n' "${supported[@]}" | jq -R . | jq -sc .) || {
        print -u2 -- "${ctx}: could not encode the candidate list"; exit 1
      }
      jq -nc --argjson cand "$cand_json" \
             --arg primary "$primary" \
        '{error:"ambiguous_repo_type", candidates:$cand,
          primary:(if $primary=="" then null else $primary end),
          detail:"multiple review panels apply; set .maintenance.yml primary to one of the candidates"}' || {
        print -u2 -- "${ctx}: could not emit the ambiguous-repo-type error"; exit 1
      }
      exit 3
    fi
  fi
  _RD_REPO_TYPE="$repo_type"
}

cmd_plan() {
  local repo="" base="origin/main" round=1 findings_path=""
  # `prior_tree_given` tracks PRESENCE, separately from the value. The blank
  # check below cannot be written against the value alone: `--prior-tree ""` —
  # the realistic `--prior-tree "$(<tree-1.txt)"` with the file absent — is
  # indistinguishable from "flag omitted" once assigned, and would be waved
  # through, which is precisely the shape the check exists to catch.
  local final=0 prior_tree="" prior_tree_given=0 fix_verification="" adjudicated=""
  while [[ $# -gt 0 ]]; do
    # `need_value` BEFORE the assignment (#1177): this script runs under
    # `setopt nounset`, so a value-taking flag in last position made `"$2"` a raw
    # parameter-not-set abort — exit 1 with a zsh diagnostic, where the header
    # contract documents exit 2 and a usage message for a malformed invocation.
    # A caller distinguishing "you called me wrong" (2) from "something broke"
    # (1) was told the wrong one, and the message named zsh's internals instead
    # of the missing flag.
    case "$1" in
    --repo) need_value "plan" "$@"; repo="$2"; shift 2 ;;
    --base) need_value "plan" "$@"; base="$2"; shift 2 ;;
    # …and validate the ROUND at parse time. It reaches jq as `--argjson round`,
    # where a non-numeric value is a jq parse error — an exit 5 from jq
    # surfacing as an unexplained failure at the very END of a successful plan,
    # long after the typo that caused it.
    --round) need_value "plan" "$@"
             # WIDTH too, not just the character class — the sibling value
             # flags all carry the cap (`--issue`, `--max-rounds`,
             # consolidate's own `--round`). zsh arithmetic is 64-bit, so a
             # 20-digit value WRAPS to a negative round in the normalisation
             # below: `scope_mode` is then forced "full" by the `round <= 1`
             # test — a caller asking for a delta silently gets the whole
             # story diff — and the default sink becomes
             # `findings-round--7766279631452241920.json`.
             [[ "$2" == <-> ]] && [[ ${#2} -le 18 ]] || \
               die_usage "plan: --round must be a non-negative integer of at most 18 digits: $2"
             # NORMALISE, don't just accept: `007` is a non-negative integer and
             # passes the pattern, but it is not valid JSON, so `--argjson round
             # 007` below would fail with jq's exit 5 at the very end of an
             # otherwise successful plan — the late failure this parse-time check
             # exists to prevent, and a status outside the documented set.
             # `emulate -L zsh` leaves OCTAL_ZEROES off, so $(( 007 )) is 7 — it
             # also keeps findings-round-007.json from becoming a second,
             # colliding artifact path for round 7.
             round=$(( $2 )); shift 2 ;;
    --findings-path) need_value "plan" "$@"; findings_path="$2"; shift 2 ;;
    # --final is a BOOLEAN — the loop's "this is the closing full sweep" signal.
    # No value, so it never goes through need_value.
    --final) final=1; shift ;;
    --prior-tree) need_value "plan" "$@"; prior_tree="$2"; prior_tree_given=1; shift 2 ;;
    # Echoed through, never read here: the loop writes both files and the
    # reviewers consume them. Keeping them in the descriptor is what lets one
    # value (the plan) carry everything a round's panel needs.
    --fix-verification) need_value "plan" "$@"; fix_verification="$2"; shift 2 ;;
    --adjudicated) need_value "plan" "$@"; adjudicated="$2"; shift 2 ;;
    -*) die_usage "plan: unknown flag: $1" ;;
    *) die_usage "plan: unexpected argument: $1" ;;
    esac
  done
  [[ -n "$repo" ]] || die_usage "plan: --repo is required"
  [[ -d "$repo" ]] || { print -u2 -- "plan: --repo not a directory: $repo"; exit 1 }
  # and TRAVERSABLE, the sibling gather script's gate. Without it a directory
  # that exists but cannot be entered makes `cd` fail inside _detect_json, and
  # the failure is reported as "detect-stack failed" — naming a script that never
  # ran, with no stderr to relay, which is exactly the case the relay exists for.
  [[ -r "$repo" && -x "$repo" ]] || {
    print -u2 -- "plan: --repo is not a readable directory: $repo"; exit 1
  }
  # normalise ONLY a path that could be misread as a flag, exactly as
  # gather-kubernetes-findings.zsh does: `[[ -d ]]` is true for `-fixtures/repo`
  # (test operators parse no options) but `cd` reads it as an option, and the
  # failure would then be blamed on detect-stack. Every other relative spelling
  # is already unambiguous, so nothing else is touched. The doubled-prefix
  # argument that used to carry this — rewriting them all put `././` into the
  # emitted `findings_path` for the ordinary `--repo .` — is now HISTORICAL
  # (pre-#1587): that field is derived from the anchored toplevel, so no
  # normalisation of `--repo` can reach it. The rule stands on the reason above,
  # which anchoring does not touch: `cd` and `git -C` still read a leading dash
  # as an option, and both run on this value.
  # An EXPLICIT empty value is the one shape `need_value`'s arg-count check
  # cannot see, and it is the realistic `--prior-tree "$(<tree-1.txt)"` with the
  # file absent. Left alone it reads downstream as "flag omitted": harmless on a
  # --final round (the scope is the full diff either way) but it would silently
  # drop delta_files, and the loop's adjudication invalidation reads exactly that
  # field — so an adjudicated suggestion whose file the last fix pass touched
  # would stay suppressed. Name it instead.
  #
  # Keyed on PRESENCE, not on the value: a `[[ -z "$prior_tree" || … ]]` test
  # short-circuits on its first operand for the empty string, so it would accept
  # the very shape the paragraph above says it exists to catch and refuse only a
  # whitespace-ONLY value — the one spelling no caller produces.
  (( ! prior_tree_given )) || [[ -n "${prior_tree//[[:space:]]/}" ]] || \
    die_usage "plan: --prior-tree requires a non-blank value"
  # A round after the first is an ITERATION (#1434): it must say what it is
  # iterating on, or declare itself the closing full sweep. There is deliberately
  # no fallback to the full diff — that fallback IS the defect this story fixes,
  # and it would be invisible (a full-diff round emitting scope_mode "delta").
  if (( round > 1 && ! final )) && [[ -z "$prior_tree" ]]; then
    die_usage "plan: --round $round needs --prior-tree (the previous round's tree identity), or --final for the closing full sweep"
  fi
  if [[ "$repo" == -* ]]; then repo="./$repo"; fi
  _verify_base "$repo" "$base" || exit 1
  # THE anchoring site for `plan` (#1587). Immediately after `_verify_base`,
  # which has just established that `--repo` is inside a git repository — though
  # NOT that it has a work tree, so `_repo_anchor` can still refuse here (a bare
  # repo or a `.git/` path; its header says why) — and BEFORE every reader below,
  # so `_repo_type`, `_primary`, the default `findings_path`, both roots and the
  # listings all read one value. Reassigning `repo` rather than introducing a
  # second name is what makes that true by construction: there is no un-anchored
  # spelling left for a later reader to pick up. The status IS checked: an
  # un-anchorable repo must fail as itself, not continue against the raw path.
  repo=$(_repo_anchor "$repo") || exit 1
  # next to _verify_base, and BEFORE anything is scoped — the whole point is that
  # an unresolvable identity never reaches a scope computation
  [[ -z "$prior_tree" ]] || _verify_prior_tree "$repo" "$prior_tree" || exit 1

  _repo_type "$repo" plan || exit $?
  # The value now crosses a function boundary in a global rather than being
  # produced inline three lines above its use, so assert it landed. Every
  # branch of `_repo_type` today either assigns or exits; this is what keeps
  # a future branch that falls through from emitting `development-:review`
  # at exit 0 — a panel dispatched for a repo whose type was never determined.
  [[ -n "$_RD_REPO_TYPE" ]] || {
    print -u2 -- "plan: internal error: the repo type was not determined"; exit 1
  }
  local repo_type="$_RD_REPO_TYPE"

  # ABSOLUTE, because `repo` is now the anchored root (#1587) — so the default is
  # `<worktree_root>/.review/findings-round-<N>.json` for EVERY spelling of
  # `--repo`, and the descriptor is self-contained the way `scope_abs` is. That
  # is not cosmetic: `resolve-story-loop.zsh` passes no `--findings-path` at
  # either of its `plan` calls and consumes this default directly — `mkdir -p` of
  # its dirname, truncate, the #974 `:A` alias refusal, `REVIEW_FINDINGS`, and
  # `scope-findings --findings` — resolving it against the LOOP's cwd, not
  # against `--repo`. A relative spelling was therefore correct only when the
  # loop happened to run from the repo root.
  [[ -n "$findings_path" ]] || findings_path="${repo%/}/.review/findings-round-${round}.json"

  # The two roots (#1582), resolved BEFORE the scope so a repo whose roots
  # cannot be read fails as itself rather than as a scope computation.
  #
  # `_worktree_root` here is DEFENCE IN DEPTH since #1587, not the primary catch:
  # `_repo_anchor` already resolved this same value at the anchoring site above
  # and refused if it could not, so on any ordinary run this call re-derives a
  # value already known good, and the two #1582 cases that drive a git which
  # cannot answer `--show-toplevel` now fail at the anchor instead (their
  # comments say so). It is KEPT for two reasons: it keeps the field a fact about
  # the TREE rather than about the caller's spelling (the file header and
  # `_worktree_root`'s own header both say so), and it FAILS if `--show-toplevel`
  # becomes unanswerable mid-run.
  #
  # Two things it does NOT do, both previously claimed here. It does not stop an
  # empty prefix — `_repo_anchor` already refuses an empty root and its fallback
  # prints a non-empty `$repo`, so `worktree_root="$repo"` could not produce one.
  # And it does not notice a root that MOVES: there is no comparison between the
  # two, so a toplevel that changes to a different resolvable value passes, and
  # the descriptor then carries `findings_path` from the anchor beside
  # `worktree_root`/`scope_abs` from the second derivation. That window is
  # essentially unreachable inside one plan, which is why it is documented rather
  # than guarded — but it is documented, not implied away.
  #
  # The two are NOT checked alike, and the difference is deliberate:
  #   - `_worktree_root` must produce a non-empty value or the plan aborts. An
  #     empty one would make every `scope_abs[]` entry start at `/`, naming no
  #     file, in a descriptor that otherwise looks well-formed.
  #   - `_main_root` FAILS (exit 1) only when the listing cannot be read or
  #     holds no worktree entry. It succeeds with an EMPTY root for a BARE main
  #     worktree, which the emitter renders as `original_root: null` — the
  #     truthful answer, since a bare repo is a git directory and not a second
  #     checkout a reviewer could read. Do NOT add a non-empty check here: it
  #     would abort every plan run from a worktree of a bare clone.
  local worktree_root=""
  worktree_root=$(_worktree_root "$repo") || {
    print -u2 -- "plan: could not resolve the worktree root (git rev-parse --show-toplevel) for $repo"; exit 1
  }
  local main_root=""
  main_root=$(_main_root "$repo") || {
    print -u2 -- "plan: could not resolve the original checkout root (git worktree list) for $repo"; exit 1
  }
  # Empty means "no original checkout to name", which the emitter renders as
  # `null` — and that covers TWO cases, not one (#1588). The obvious one is a
  # main checkout, whose two roots are equal. The other is a BARE main worktree:
  # `_main_root` succeeds with an EMPTY root there (its own comment says so, and
  # the contrast block above this function repeats it), so the comparison below
  # is false and `original_root` is assigned that empty value. Glossing this as
  # "not a linked worktree" alone would contradict both of those statements —
  # a plan run FROM a linked worktree of a bare clone lands here too.
  # Keyed on the two roots DIFFERING, not on any worktree-detection flag: the
  # main checkout is its own first `worktree list` entry, so the comparison is
  # the whole test.
  local original_root=""
  [[ "$main_root" == "$worktree_root" ]] || original_root="$main_root"

  local full_json
  full_json=$(_changed_files "$repo" "$base" | jq -R . | jq -sc .) || {
    print -u2 -- "plan: could not compute changed files"; exit 1
  }

  # The delta is computed whenever --prior-tree is given, INCLUDING on a full
  # round: `changed_files` is then still the whole story diff, but the loop reads
  # delta_files to decide which adjudications the last fix pass invalidated, and
  # the closing sweep is exactly a full round that must still do that.
  local delta_json='null'
  if [[ -n "$prior_tree" ]]; then
    delta_json=$(_delta_files "$repo" "$prior_tree" | jq -R . | jq -sc .) || {
      print -u2 -- "plan: could not compute the delta against --prior-tree: $prior_tree"; exit 1
    }
  fi

  # ONE descriptor value decides the scope, so it is testable on its own and the
  # loop's finality rule (which moves with every human grant) stays in the loop.
  # `round <= 1`, not `round == 1`: `--round` is contracted as any NON-NEGATIVE
  # integer, so 0 is legal, and it satisfies neither `== 1` nor `--final`. It
  # would then be scoped "delta" with no `--prior-tree` required (that guard
  # fires only for `round > 1`), and `changed_files` would take delta_json's
  # `null` default — an emitted descriptor whose review scope is not an array,
  # which the contract says it always is. There is no round 0 to iterate on, so
  # the full scope is the only meaning it can have.
  local scope_mode="delta"
  (( round <= 1 || final )) && scope_mode="full"
  local changed_json="$full_json"
  [[ "$scope_mode" == "delta" ]] && changed_json="$delta_json"

  # the descriptor emitter is checked like every other jq call (#1177). It is the
  # last command of the last function, so an unchecked failure would leave jq's
  # own status (5) as the script's — a code outside the documented set, which the
  # orchestrator cannot map to internal-error vs typed-escalation.
  jq -nc \
    --arg repo_type "$repo_type" \
    --arg review_skill "development-${repo_type}:review" \
    --argjson round "$round" \
    --arg base "$base" \
    --arg findings_path "$findings_path" \
    --argjson changed "$changed_json" \
    --arg worktree_root "$worktree_root" \
    --arg original_root "$original_root" \
    --arg scope_mode "$scope_mode" \
    --arg prior_tree "$prior_tree" \
    --argjson delta "$delta_json" \
    --arg fixver "$fix_verification" \
    --arg adjud "$adjudicated" \
    '{repo_type:$repo_type, review_skill:$review_skill, round:$round, base:$base,
      findings_path:$findings_path, changed_files:$changed,
      worktree_root:$worktree_root,
      original_root:(if $original_root=="" then null else $original_root end),
      scope_abs:[ $changed[] | $worktree_root + "/" + . ],
      scope_mode:$scope_mode,
      scope_empty:(($changed | length) == 0),
      prior_tree:(if $prior_tree=="" then null else $prior_tree end),
      delta_files:$delta,
      fix_verification_path:(if $fixver=="" then null else $fixver end),
      adjudicated_path:(if $adjud=="" then null else $adjud end)}' || {
    print -u2 -- "plan: could not emit the dispatch descriptor"; exit 1
  }
}

cmd_detect() {
  # `plan`'s repo-type half with the diff work removed (#1504). The conductor
  # calls this at §1b, where the branch is still empty and a diff would be pure
  # waste. No --base, no changed_files, no findings path: one key, one document.
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --repo) need_value "detect" "$@"; repo="$2"; shift 2 ;;
    -*) die_usage "detect: unknown flag: $1" ;;
    *) die_usage "detect: unexpected argument: $1" ;;
    esac
  done
  [[ -n "$repo" ]] || die_usage "detect: --repo is required"
  # Same split plan draws between 2 and 1: a MISSING --repo is your invocation
  # (2), a --repo naming nothing is a fact about the machine (1).
  [[ -d "$repo" ]] || { print -u2 -- "detect: --repo not a directory: $repo"; exit 1 }
  # The SECOND gate, and it is not decoration (#1177): without it an existing
  # but untraversable --repo falls into `_detect_json`, whose `cd` fails, and
  # the operator is told "detect-stack failed" — naming a script that never
  # ran, with no stderr to relay. Both siblings carry it; so does this one.
  [[ -r "$repo" && -x "$repo" ]] || {
    print -u2 -- "detect: --repo is not a readable directory: $repo"; exit 1
  }
  if [[ "$repo" == -* ]]; then repo="./$repo"; fi
  # THE anchoring site for `detect` (#1587) — the same rule as `plan`'s, which is
  # what keeps the two AGREEING on a repo, the property this subcommand exists to
  # guarantee. `detect` runs no `_verify_base`, so it is the subcommand that
  # reaches `_repo_anchor`'s fallback in the ordinary course: a `--repo` outside
  # any git repository stays itself, and its own `.maintenance.yml` is still
  # read. A git FAULT is still refused here, exit 1 — anchoring at a
  # subdirectory because git was unwell is what would break that agreement.
  repo=$(_repo_anchor "$repo") || exit 1
  _repo_type "$repo" detect || exit $?
  [[ -n "$_RD_REPO_TYPE" ]] || {
    print -u2 -- "detect: internal error: the repo type was not determined"; exit 1
  }
  # `--arg`, so a repo_type is emitted as a JSON string whatever it holds, and
  # the status is CHECKED — an unwritable stdout must not read as a detection.
  jq -nc --arg t "$_RD_REPO_TYPE" '{repo_type:$t}' || {
    print -u2 -- "detect: could not emit the repo-type document"; exit 1
  }
}

cmd_scope_findings() {
  local repo="" base="origin/main" findings=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --repo) need_value "scope-findings" "$@"; repo="$2"; shift 2 ;;
    --base) need_value "scope-findings" "$@"; base="$2"; shift 2 ;;
    --findings) need_value "scope-findings" "$@"; findings="$2"; shift 2 ;;
    -*) die_usage "scope-findings: unknown flag: $1" ;;
    *) die_usage "scope-findings: unexpected argument: $1" ;;
    esac
  done
  [[ -n "$repo" ]] || die_usage "scope-findings: --repo is required"
  [[ -n "$findings" ]] || die_usage "scope-findings: --findings is required"
  # same leading-dash normalisation as cmd_plan
  if [[ "$repo" == -* ]]; then repo="./$repo"; fi
  # and the same two directory gates, for the same reason: without them an
  # unreadable --repo is reported by _verify_base as "not a git repository" — a
  # confidently wrong claim about a directory that may be a perfectly good repo
  # this process simply cannot traverse. Every subcommand must name one cause
  # with one wording.
  [[ -d "$repo" ]] || { print -u2 -- "scope-findings: --repo not a directory: $repo"; exit 1 }
  [[ -r "$repo" && -x "$repo" ]] || {
    print -u2 -- "scope-findings: --repo is not a readable directory: $repo"; exit 1
  }
  _verify_base "$repo" "$base" || exit 1
  # THE anchoring site for `scope-findings` (#1587). BEHAVIOUR-NEUTRAL here, and
  # deliberately applied anyway: this subcommand has no sink and no detection,
  # and `_changed_files` is repo-wide from any directory since #1582, so the
  # filtered output is the same either way (a test pins that). It is anchored so
  # the script has ONE reading of `--repo` rather than two — the whole point of
  # the rule — leaving no un-anchored subcommand for a future reader to copy.
  # Status checked like its two siblings, and the refusal arms are shared, so
  # this one reaches them too: a bare `--repo` passes `_verify_base` and still
  # has no work tree.
  repo=$(_repo_anchor "$repo") || exit 1

  # missing or empty findings file → nothing in scope
  if [[ ! -s "$findings" ]]; then print -r -- '[]'; return 0; fi

  local changed_json
  changed_json=$(_changed_files "$repo" "$base" | jq -R . | jq -sc .) || {
    print -u2 -- "scope-findings: could not compute changed files"; exit 1
  }

  # keep only findings whose (./-normalized) file is in the story's diff
  # the file arrives on STDIN, never as an operand: `--findings -f.json` is a
  # value a caller can legitimately produce (plan's --findings-path is free-form),
  # and jq would parse it as options and then blame the failure on unparseable
  # JSON — a confidently wrong cause for a file that may be perfectly valid.
  jq -c --argjson changed "$changed_json" \
    '[ .[] | . as $f | ($f.file // "" | sub("^\\./";"")) as $p
       | select($changed | index($p)) ]' < "$findings" || {
    print -u2 -- "scope-findings: could not parse findings JSON: $findings"; exit 1
  }
}

[[ $# -ge 1 ]] || die_usage "usage: review-dispatch.zsh <plan|detect|scope-findings> [flags]"
local sub="$1"; shift
case "$sub" in
  plan) cmd_plan "$@" ;;
  detect) cmd_detect "$@" ;;
  scope-findings) cmd_scope_findings "$@" ;;
  -h|--help) print -r -- "usage: review-dispatch.zsh <plan|detect|scope-findings> [flags]"; exit 0 ;;
  *) die_usage "unknown subcommand: $sub (expected plan|detect|scope-findings)" ;;
esac
