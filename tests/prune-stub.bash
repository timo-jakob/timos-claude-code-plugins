# shellcheck shell=bash
#
# Shared fixture for the #1428 prune-filter tests (kubernetes-topic-marker,
# gather-kubernetes, detect-stack): a `grep` that fails ONLY the invocation
# carrying the kubernetes prune operands, and proves it fired.
#
# A blanket failing grep cannot isolate the prune-filter arm — the argoproj half
# greps too, and detect-stack greps throughout — so the stub keys on `/templates/`
# with its slashes, which appears in no other grep: the argoproj half spells it
# `--exclude-dir=templates`. Every other invocation is delegated to the real grep.
#
# It also has to PROVE it intercepted something. The tolerant tests assert
# status 0 and silence, which is exactly what an un-stubbed run produces — so a
# stub that silently stopped matching (an operand respelled in the recipes but
# not here) would pass them while testing nothing. The failing branch therefore
# touches `<dir>/fired`, and every caller asserts that file exists after the run.
# It writes a line to stderr too, so a `[ -z "$stderr" ]` on the tolerant path
# is falsifiable: it holds only because the recipes suppress the filter's stderr.

# failing_prune_grep_stub DIR — build the stub under DIR (created); prepend DIR
# to PATH to activate it AFTERWARDS, never before. The fired marker is DIR/fired,
# and a rebuild clears it, so each run has to earn its proof again.
#
# It REFUSES, non-zero and naming the cause on stderr, rather than build a stub
# that cannot delegate: exit 2 with no DIR; exit 1 when no executable `grep` is
# on PATH, or when the one found lives under DIR itself — i.e. the caller
# activated an earlier build before rebuilding. Covered by tests/prune-stub.bats.
failing_prune_grep_stub() {
  local dir="$1" real
  [ -n "$dir" ] || { printf 'failing_prune_grep_stub: DIR required\n' >&2; return 2; }
  # `type -P`, not `command -v`: only an executable on PATH, never a function or
  # alias whose name the generated `exec` would then resolve back to this stub
  real="$(type -P grep)" || { printf 'failing_prune_grep_stub: no executable grep on PATH\n' >&2; return 1; }
  # and never the stub itself — a caller that activated an earlier build in its
  # own PATH before rebuilding would otherwise hand the stub its own path, and
  # every delegated grep would exec in a loop instead of failing visibly
  case "$real" in
    "$dir"/*) printf 'failing_prune_grep_stub: PATH already resolves grep to %s — activate the stub AFTER building it\n' "$real" >&2; return 1 ;;
  esac
  mkdir -p "$dir" || return 1
  # a rebuild starts with no proof: a marker left by an earlier run would let a
  # stub that stopped matching pass the callers' `[ -f DIR/fired ]` for free
  rm -f "$dir/fired" || return 1
  # both paths through %q: the real grep's location and the marker path are
  # interpolated into a script, so a space or glob character in either would
  # otherwise word-split at exec time and fail every delegated grep in the run
  printf '#!/usr/bin/env bash\ncase "$*" in *"/templates/"*) echo "stub: prune filter failed" >&2; : > %q; exit 2 ;; esac\nexec %q "$@"\n' \
    "$dir/fired" "$real" > "$dir/grep" || return 1
  chmod +x "$dir/grep"
}
