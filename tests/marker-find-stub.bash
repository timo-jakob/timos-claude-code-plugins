# shellcheck shell=bash
#
# Shared fixture for the kubernetes marker's find-half tests (#1177, reshaped by
# #1393; loaded by kubernetes-topic-marker, gather-kubernetes and detect-stack):
# a `find` that fails ONLY the invocation carrying the kubernetes marker
# operands, keeps that invocation's real output, and proves it fired.
#
# WHY A STUB. The marker's "did not complete" ladder has two disjuncts — the
# find's status and the argoproj grep's — and a test that pins the FIND one
# needs a fixture where find fails alone. Before #1393 an unreadable
# `node_modules` was that fixture: the argoproj grep skipped it
# (`--exclude-dir`) while find descended it and filtered the paths afterwards.
# Since #1393 both halves skip exactly the same trees, so every unreadable
# directory trips both and no directory can trip find alone; a locked FILE
# trips only the grep. There is no natural discriminator left — and that
# absence is itself the property #1393 delivers, pinned separately by the
# "never entered" tests. So the find disjunct is isolated by a seam: this stub.
#
# It fails the way a real interrupted walk fails — the paths it had reached ARE
# printed, the status is 1 — so the "hit stands" and "truncated list refused"
# branches see the same shape a mid-walk `git gc` produces. It keys on
# `kustomization.yml`, an operand only the four marker copies carry, and
# delegates every other invocation to the real find, so a script that finds
# throughout (detect-stack) is not derailed elsewhere. NOT `Chart.yaml`:
# detect-stack.sh runs a second find carrying that name — the
# `detection_confidence` probe, ahead of the marker block — which a
# `Chart.yaml` key would intercept first, writing `fired` from the wrong find
# (so the proof below would prove nothing there) and failing that probe's
# pipeline into a wrong `detection_confidence`.
#
# It also has to PROVE it intercepted something. The tolerant tests assert
# status 0 and silence, which is exactly what an un-stubbed run produces — so a
# stub that silently stopped matching (an operand respelled in the recipes but
# not here) would pass them while testing nothing. The failing branch therefore
# touches `<dir>/fired`, and every caller asserts that file exists after the run.
# It writes a line to stderr too, so a `[ -z "$stderr" ]` on the tolerant path
# is falsifiable: it holds only because the recipes suppress find's stderr.

# failing_marker_find_stub DIR — build the stub under DIR (created); prepend DIR
# to PATH to activate it AFTERWARDS, never before. The fired marker is DIR/fired,
# and a rebuild clears it, so each run has to earn its proof again.
#
# It REFUSES, non-zero and naming the cause on stderr, rather than build a stub
# that cannot delegate: exit 2 with no DIR; exit 1 when no executable `find` is
# on PATH, or when the one found lives under DIR itself — i.e. the caller
# activated an earlier build before rebuilding. Covered by
# tests/marker-find-stub.bats.
failing_marker_find_stub() {
  local dir="$1" real
  [ -n "$dir" ] || { printf 'failing_marker_find_stub: DIR required\n' >&2; return 2; }
  # `type -P`, not `command -v`: only an executable on PATH, never a function or
  # alias whose name the generated `exec` would then resolve back to this stub
  real="$(type -P find)" || { printf 'failing_marker_find_stub: no executable find on PATH\n' >&2; return 1; }
  # and never the stub itself — a caller that activated an earlier build in its
  # own PATH before rebuilding would otherwise hand the stub its own path, and
  # every delegated find would exec in a loop instead of failing visibly
  case "$real" in
    "$dir"/*) printf 'failing_marker_find_stub: PATH already resolves find to %s — activate the stub AFTER building it\n' "$real" >&2; return 1 ;;
  esac
  mkdir -p "$dir" || return 1
  # a rebuild starts with no proof: a marker left by an earlier run would let a
  # stub that stopped matching pass the callers' `[ -f DIR/fired ]` for free
  rm -f "$dir/fired" || return 1
  # all three paths through %q: the real find's location (twice) and the marker
  # path are interpolated into a script, so a space or glob character in any of
  # them would otherwise word-split at exec time and fail every delegated find.
  # The intercepted branch runs the REAL find first so its output is preserved
  # — the shape of a walk that died after printing — and only then fails.
  printf '#!/usr/bin/env bash\ncase "$*" in *kustomization.yml*) %q "$@"; echo "stub: marker find failed" >&2; : > %q; exit 1 ;; esac\nexec %q "$@"\n' \
    "$real" "$dir/fired" "$real" > "$dir/find" || return 1
  chmod +x "$dir/find"
}
