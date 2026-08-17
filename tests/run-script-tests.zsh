#!/usr/bin/env zsh
# `emulate -L zsh` FIRST, then `setopt`. emulate resets every option in its
# emulation set — errexit and nounset included, even without -R — so the
# original order (setopt on line 2, emulate further down) silently discarded
# both, and this script had been running with neither. Verify with:
#   zsh -c 'setopt errexit nounset; emulate -L zsh; setopt' | grep -c errexit
# which prints 0 — errexit is gone by the time the script body runs.
# FOUR other scripts still have the identical defect — gather-claude-plugin-
# findings.zsh, gather-spring-findings.zsh, run-headless.zsh, and the shipped
# template derive-release-scope.zsh. They are pre-existing and untouched by
# #1199, so they are tracked in #1223 rather than widening that story's diff.
emulate -L zsh
setopt err_exit nounset pipefail

# run-script-tests.zsh — run the shell-script behavioral tests (bats).
#
# Default: build the disposable Docker image (tests/Dockerfile) and run the suite
# inside it, so the scripts under test — which touch the filesystem, run other
# tools, and exercise error paths — can't affect the host. This is the isolation
# #263 asked for.
#
# Flags:
#   --local   run `bats` directly on the host instead (requires bats on PATH) —
#             the same host-bats mode CI runs in, the runner there being
#             disposable already. CI does NOT invoke this script: its entry point
#             is `run-gate.zsh --tests-dir tests` (see tests/README.md).
#
# Usage:
#   tests/run-script-tests.zsh            # Docker (isolated)
#   tests/run-script-tests.zsh --local    # host bats

local repo_root="${0:A:h:h}"
local mode="docker"
[[ "${1:-}" == "--local" ]] && mode="local"

if [[ "$mode" == "local" ]]; then
  command -v bats >/dev/null 2>&1 \
    || { print -u2 -- "bats not on PATH — install it (brew install bats-core) or drop --local to use Docker."; exit 127 }
  exec bats "$repo_root/tests"
fi

command -v docker >/dev/null 2>&1 \
  || { print -u2 -- "docker not on PATH — install Docker or pass --local to use host bats."; exit 127 }

# The git store the suite READS (#1360). Mounting only the repo root is enough
# for a plain clone, where `.git` is a directory inside it — and silently wrong
# in a linked WORKTREE, where the root's `.git` is a FILE holding
# `gitdir: <absolute host path>`. That path does not exist in the container, so
# every `git` call against the mounted tree died with
# `fatal: not a git repository`, which is what reddened the four
# tests/build-golden-798-target.bats tests. This repo's own
# /development:resolve-issue flow works in `.claude/worktrees/*`, so that is the
# common case, not an edge one.
#
# BOTH dirs, each at its own HOST-ABSOLUTE path. The per-worktree gitdir carries
# only HEAD, index and a `commondir` pointer; objects, refs and packed-refs live
# in the main `.git` — which is where `git show <sha>:<path>` reads from. Mounting
# them at the very paths the host uses is what lets git's own `gitdir:` and
# `commondir` pointers resolve verbatim, with no metadata rewriting.
#
# Resolved BEFORE the image build so an unresolvable git dir costs no build, and
# typed like every other failure here rather than surfacing as git's own fatal
# from inside the container.
# SCRUBBED environment. `git rev-parse` honours an inherited GIT_DIR /
# GIT_COMMON_DIR / GIT_WORK_TREE — git exports them inside hooks and
# `git rebase --exec` — and with GIT_WORK_TREE pointing here while GIT_DIR points
# elsewhere the toplevel cross-check below PASSES while the two dirs name another
# repository's store, which is then mounted into the container. That is the
# silently-wrong outcome this whole pre-flight exists to rule out.
local git_meta
if ! git_meta="$(env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      git -C "$repo_root" rev-parse --git-dir --git-common-dir --show-toplevel 2>/dev/null)"; then
  print -u2 -- "git could not resolve the git dir for $repo_root — is git installed, and is this a git checkout?"
  exit 1
fi
local -a git_meta_lines
git_meta_lines=("${(@f)git_meta}")
if (( ${#git_meta_lines} != 3 )); then
  print -u2 -- "git returned ${#git_meta_lines} path(s) for --git-dir --git-common-dir --show-toplevel, expected 3"
  exit 1
fi
local git_dir="${git_meta_lines[1]}" git_common_dir="${git_meta_lines[2]}"
# `rev-parse` discovers UPWARDS, so a tests/ tree that is not itself a checkout
# but sits inside one resolves that OTHER repository — and would bind-mount its
# store into the container while /work is a different tree. Silently wrong is
# the one outcome this typed pre-flight exists to rule out, so cross-check that
# the checkout git found is the one being mounted.
local git_top="${git_meta_lines[3]:A}"
if [[ "$git_top" != "${repo_root:A}" ]]; then
  print -u2 -- "$repo_root is not the root of a git checkout — git resolved $git_top instead"
  exit 1
fi
# `git -C` makes a relative answer (a plain clone answers a bare `.git`) relative
# to the repo root, and `:A` absolutises + resolves symlinks — the same treatment
# the cache root gets below, and for the same reason: `docker run -v` rejects a
# relative mount source outright.
[[ "$git_dir" == /* ]] || git_dir="$repo_root/$git_dir"
[[ "$git_common_dir" == /* ]] || git_common_dir="$repo_root/$git_common_dir"
#
# PRECONDITION, stated because `:A` resolves symlinks: the mounts land at the
# RESOLVED spelling, so a checkout whose recorded gitdir traverses a symlink
# (a worktree under a symlinked /tmp, say) would have the container looking for
# the unresolved one. The blessed `.claude/worktrees/*` layout has no symlinked
# component, so this is a precondition rather than a live case — if it ever
# bites, mount both spellings rather than dropping the `:A`.
git_dir="${git_dir:A}"
git_common_dir="${git_common_dir:A}"
local d
for d in "$git_dir" "$git_common_dir"; do
  [[ -d "$d" ]] \
    || { print -u2 -- "git named $d as a git dir, but it is not a directory"; exit 1 }
done
# `:ro`, with no flag and no environment variable to relax it. Every call the
# suite makes against the mounted tree is a read (`rev-parse`, `show`,
# `ls-files`), so read-only suffices. If a future test genuinely needs to write
# to the git store, change this script's contract deliberately — do NOT add a
# flag or environment variable that relaxes `:ro`; tests/run-script-tests.bats
# pins that no such toggle exists.
#
# BE PRECISE ABOUT WHAT THIS BUYS, because the obvious stronger claim is false.
# It denies writes THROUGH THESE MOUNTS, which is the whole store only in a
# linked WORKTREE, where the gitdir and the common dir both sit outside
# `$repo_root`. In a plain clone `.git` lives INSIDE the repo root, which is
# mounted read-WRITE at /work — and `/work/.git` is the copy the container's git
# actually resolves, so these mounts are then a second, unused view and grant no
# protection at all. The rule tests must follow is therefore the same in both
# shapes: never run a mutating git command against the mounted tree.
#
# BRACED — `"$git_dir:ro"` does NOT produce what it reads as: zsh applies the
# history-style modifier `:r` (strip extension) to an unbraced `$name:`, so that
# spelling silently mounted `…/timos-claude-code-plugins/o`. Caught only because
# the argv is asserted per line in tests/run-script-tests.bats.
local -a git_mounts
git_mounts=(-v "${git_dir}:${git_dir}:ro")
# In a plain clone the two ARE the same path, and `docker run` rejects a
# duplicate mount destination outright — so one mount is both mounts there.
[[ "$git_common_dir" == "$git_dir" ]] \
  || git_mounts+=(-v "${git_common_dir}:${git_common_dir}:ro")

print -u2 -- "==> building test image (tests/Dockerfile) ..."
# Explicitly guarded rather than left to errexit: for as long as the option was
# being discarded (above), a failed build fell straight through to `docker run`
# against whatever STALE image the last successful build left behind — and a
# stale image is precisely the state that produces a confusing red inside the
# harness's setup_file instead of "your image failed to build".
docker build -q -t claude-plugin-script-tests "$repo_root/tests" >/dev/null \
  || { print -u2 -- "test image build failed (tests/Dockerfile)"; exit 1 }

# The pinned IaC toolchain (#1199) is NOT baked into the image. Four of the six
# pins (kubeconform, kube-linter, kyverno, yq) are read from the workflow
# template, which lives outside this build context; helm and kustomize are pinned
# in tests/iac-tools.zsh, because the template installs neither. And baking any
# of them in would re-download ~100 MB on every image rebuild — the reason that
# covers all six. Mount the host's cache root instead. It is safe to share because iac-tools.zsh keys its leaf directory by
# os-arch — the host's darwin binaries and the container's linux ones sit side by
# side — so each platform downloads once, ever, rather than once per run.
# typed for the same reason as iac-tools.zsh's copy: the expansion dereferences
# $HOME under `nounset`, so with none of the three set this would die with a raw
# "HOME: parameter not set" — after the image was already built, and naming
# nothing about the cache. Every other failure in this script is typed.
if [[ -z "${IAC_TOOLS_CACHE:-}" && -z "${XDG_CACHE_HOME:-}" && -z "${HOME:-}" ]]; then
  print -u2 -- "no cache root — set IAC_TOOLS_CACHE, XDG_CACHE_HOME or HOME"
  exit 1
fi
local cache_root="${IAC_TOOLS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/timos-claude-code-plugins/iac-tools}"
# ABSOLUTE: `docker run -v` rejects a relative mount source outright, so a
# relative IAC_TOOLS_CACHE would fail the run with Docker's own error rather
# than anything naming this variable.
cache_root="${cache_root:A}"
mkdir -p "$cache_root" \
  || { print -u2 -- "cannot create the IaC toolchain cache at $cache_root"; exit 1 }

print -u2 -- "==> running bats in the container ..."
# BOTH mount sources on this line are BRACED, for the reason the git mounts
# document above (they are braced where they are built): zsh applies a
# history-style modifier to an unbraced `$name:`. These two are safe today only
# because `/` is not a modifier letter — a property of the destination path, not
# of this code — so a future destination starting with `r`/`h`/`a`/`t`/`q` would
# silently repeat the #1360 bug.
exec docker run --rm -v "${repo_root}:/work" "${git_mounts[@]}" -v "${cache_root}:/iac-tools" \
  -e IAC_TOOLS_CACHE=/iac-tools -w /work claude-plugin-script-tests tests
