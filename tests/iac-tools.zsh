#!/usr/bin/env zsh
# iac-tools.zsh — resolve the PINNED toolchain tests/kubernetes-ci-fixtures.bats
# executes the bootstrapped `kubernetes-ci` pipeline with (#1199).
#
# WHY PINNED, AND WHY NOT $PATH. The three fixture repositories under
# tests/fixtures/kubernetes-repo* assert tool VERDICTS, not just exit codes: the
# clean variant is "zero kube-linter findings", the broken one is "exactly four,
# each attributable to one file and one check id" (four findings across THREE
# files — no-limits.yaml deliberately carries two ids). kube-linter's default
# check set changes between releases — checks are added, renamed and retired —
# and kyverno's counters move too, so a newer binary does not reproduce those
# counts and would red this suite on a PR that changed nothing. Measured, not
# assumed: one minor ahead of the pin reports three findings on the broken
# fixture where the pin reports four. Each fixture README carries the same rule:
# at the pinned versions a red is a regression, on any other version re-run
# pinned before concluding anything. A harness reading whatever `brew install`
# last put on PATH cannot make that promise, so this script puts the pinned
# binaries in front of it instead.
#
# THE PINS ARE READ FROM THE WORKFLOW TEMPLATE, not restated here — the template
# is what a consumer repo actually runs, so a bump there must move the harness
# with it rather than leaving the two silently describing different toolchains.
# The two exceptions are helm and kustomize: the template installs NEITHER
# (ubuntu-latest ships both), so there is no pin upstream to read. They are
# pinned below to the versions of the runner image the workflow targets, which is
# as close as this harness can get to "what the consumer's CI actually renders
# with" while still being reproducible on a developer machine and on the macOS CI
# leg, where the runner image ships neither tool at all.
#
# Usage:
#   iac-tools.zsh [--bin-dir DIR] [--template PATH] [--print-pins] [-h|--help]
#
#     --print-pins     print the resolved pins as `<tool> <version>` lines and
#                      exit, installing nothing. This is the ONE place the six
#                      versions are named, so the harness asserts what the
#                      binaries report against THIS rather than restating them —
#                      including helm and kustomize, whose pins live nowhere
#                      else and would otherwise be the two the suite never
#                      checks.
#
#     --bin-dir DIR    the EXACT directory the binaries live in. Without it they
#                      go to <cache-root>/<os>-<arch>, where <cache-root> is
#                      $IAC_TOOLS_CACHE, else
#                      ${XDG_CACHE_HOME:-$HOME/.cache}/timos-claude-code-plugins/iac-tools.
#                      The per-platform leaf is what lets ONE cache root be
#                      shared by the host and the debian test container
#                      (tests/run-script-tests.zsh mounts it): darwin binaries
#                      and linux binaries never collide, so each platform
#                      downloads once instead of once per container run.
#                      Deliberately OUTSIDE the repository: the review loop's
#                      gate attestation (#981) hashes tracked AND untracked
#                      non-ignored files, so a ~100 MB toolchain unpacked into
#                      the worktree would change the tree identity on every run
#                      and defeat every match — quite apart from being one `git
#                      add .` away from being committed.
#     --template PATH  the kubernetes-ci workflow template to read pins from
#                      (default: the one shipped in this repo).
#
# Output: the resolved bin directory on stdout, one line. Diagnostics on stderr.
#
# Exit codes: 0 resolved · 1 a tool could not be resolved · 2 usage error.
#
# IDEMPOTENT AND OFFLINE-FRIENDLY: a binary already present at the pinned version
# is left alone, so only the first run needs the network. That is what makes it
# safe to call from `setup_file` in the bats file AND as an explicit install step
# in CI — the CI step pre-warms the cache, and the suite then finds it populated.

emulate -L zsh
setopt err_exit nounset pipefail

die_usage() { print -u2 -- "iac-tools: $1"; exit 2 }

local self_dir="${0:A:h}"
local repo_root="${self_dir:h}"
local bin_dir="" template="" print_pins=0 template_given=0

while (( $# > 0 )); do
  case "$1" in
  --bin-dir)  { (( $# >= 2 )) && [[ -n "$2" ]] } || die_usage "--bin-dir needs a non-empty value"; bin_dir="$2"; shift 2 ;;
  --template) { (( $# >= 2 )) && [[ -n "$2" ]] } || die_usage "--template needs a non-empty value"; template="$2"; template_given=1; shift 2 ;;
  --print-pins) print_pins=1; shift ;;
  -h|--help)  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done

: "${template:=$repo_root/development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl}"

# Exit 2 is "the CALLER passed something wrong", so it belongs to a --template
# the caller supplied. A missing DEFAULT template is a broken checkout — the
# repo not being what the script expects — which is a resolution failure (1).
# Flattening the two would leave a wrapper unable to tell "I called it wrong"
# from "this tree is not the one I was written against".
if [[ ! -f "$template" ]]; then
  # an `if`, not `(( … )) && die_usage`. Not because the AND form would abort:
  # zsh (like bash) exempts every member of an `&&` list EXCEPT the one after
  # the final operator, so a false non-final test is harmless — the real
  # errexit hazard is a FINAL-position and-list, whose false status becomes the
  # enclosing function's or script's own. The `if` is chosen for legibility, and
  # because it keeps the false case from silently becoming this block's status.
  if (( template_given )); then
    die_usage "workflow template not found: $template"
  fi
  print -u2 -- "iac-tools: workflow template not found at its default path: $template"
  exit 1
fi
# yq stays HERE — reading the template genuinely needs it, `--print-pins`
# included. The FLAVOUR is probed, not just presence: Debian/Ubuntu's `yq` is
# kislyuk's python-yq, a different query language, and it would sail past a bare
# `command -v` only to fail four lines later as "could not read
# KUBECONFORM_VERSION" — sending the reader at a template whose key is present.
command -v yq >/dev/null 2>&1 \
  || { print -u2 -- "iac-tools: mikefarah yq is required to read the template's pins"; exit 1 }
# Assigned first, then matched: piping into `grep -qi` folds three different
# failures into one message — an older mikefarah build, a grep that is missing,
# and a yq that exits non-zero after printing.
local yq_ver
yq_ver="$(yq --version 2>/dev/null)" \
  || { print -u2 -- "iac-tools: could not run 'yq --version'"; exit 1 }
# BOTH accepted spellings. The `mikefarah` URL only appears in ~v4.24 and later;
# older 4.x prints a bare `yq version 4.20.2` and speaks exactly the dialect this
# script needs, so keying on the URL alone would reject a perfectly usable
# binary and tell the developer to replace it. kislyuk's python-yq prints
# `yq 3.4.3` — no `version` word — and mikefarah v3 prints `yq version 3.x`, so
# both are still rejected.
if [[ "$yq_ver" != *[Mm]ikefarah* && "$yq_ver" != "yq version 4."* ]]; then
  print -u2 -- "iac-tools: the yq on PATH is not mikefarah's yq v4 (python-yq speaks a different query language): $yq_ver"
  exit 1
fi
# curl is checked LATER, just before the first download — see the --print-pins
# block below, which must answer on a machine that has no curl at all.

# --- the pins ---------------------------------------------------------------
# Read by STEP NAME / job key, never by index: an inserted step would otherwise
# shift the lookup onto a different `env:` block and the harness would silently
# pin a version nothing installs.
tmpl_env() {
  local got
  got="$(yq -r "$1" "$template")" || return 1
  # `yq -r` prints the string "null" for an absent key, which is non-empty and
  # would sail straight into a download URL as a literal "null" version.
  [[ -n "$got" && "$got" != "null" ]] || return 1
  # ...and a selector matching TWO steps (a copy-pasted install step) returns
  # two LINES, which passes the guard above and then splices a newline into the
  # download URL and the version regex. The point of reading by step name is a
  # loud disagreement between template and harness, not a mangled URL.
  if [[ "$got" == *$'\n'* ]]; then
    print -u2 -- "iac-tools: '$1' matched more than one value in $template"
    return 1
  fi
  print -r -- "$got"
}

local kubeconform_v kube_linter_v kyverno_v yq_v
kubeconform_v="$(tmpl_env '.jobs.schema.steps[] | select(.name == "install kubeconform") | .env.KUBECONFORM_VERSION')" \
  || { print -u2 -- "iac-tools: could not read KUBECONFORM_VERSION from $template"; exit 1 }
kube_linter_v="$(tmpl_env '.jobs.lint.steps[] | select(.name == "install kube-linter") | .env.KUBE_LINTER_VERSION')" \
  || { print -u2 -- "iac-tools: could not read KUBE_LINTER_VERSION from $template"; exit 1 }
kyverno_v="$(tmpl_env '.jobs.policy.env.KYVERNO_VERSION')" \
  || { print -u2 -- "iac-tools: could not read KYVERNO_VERSION from $template"; exit 1 }
yq_v="$(tmpl_env '.jobs.argocd.steps[] | select(.name == "install yq") | .env.YQ_VERSION')" \
  || { print -u2 -- "iac-tools: could not read YQ_VERSION from $template"; exit 1 }

# Not readable from the template — see the header. Bumping these is a deliberate
# act: they say which runner image the harness claims to mirror.
#
# PROVENANCE, so the claim is checkable rather than asserted: both were read on
# 2026-08-05 from the runner image `ubuntu-latest` resolved to then (Ubuntu
# 24.04). The versions are NOT restated in this comment — the constants below are
# the only place they are written, the same no-restatement rule the IaC docs now
# follow. To re-read them, FIRST confirm which image `ubuntu-latest` resolves to
# today (it moves on GitHub's schedule), then read that manifest from the
# runner-images repo. MAINTAINING.md's Step 1 inventory names this file for the
# quarterly sweep; its Step 2 carries the full re-read procedure.
local helm_v=3.21.3 kustomize_v=5.8.1

# `--print-pins` answers BEFORE the platform is resolved and before anything is
# installed: it is a pure question about the template, so it must work on a
# machine whose OS the toolchain does not publish for, and offline.
if (( print_pins )); then
  print -r -- "helm $helm_v"
  print -r -- "kustomize $kustomize_v"
  print -r -- "kubeconform $kubeconform_v"
  print -r -- "kube-linter $kube_linter_v"
  print -r -- "kyverno $kyverno_v"
  print -r -- "yq $yq_v"
  exit 0
fi

# Everything past here downloads, so this is where curl becomes a requirement —
# below --print-pins, which is a pure question about the template.
command -v curl >/dev/null 2>&1 \
  || { print -u2 -- "iac-tools: curl is required to download the pinned binaries"; exit 1 }
# tar too, and for the same reason the other preconditions are named: five of the
# six tools arrive as `curl … | tar -xz`, so without it all five report
# "download or extraction failed: <url>" — pointing the reader at the release
# hosts and their network when the cause is a missing local tool
command -v tar >/dev/null 2>&1 \
  || { print -u2 -- "iac-tools: tar is required to unpack the pinned binaries"; exit 1 }

# --- platform ---------------------------------------------------------------
local uname_s uname_m os arch
# typed, like every other precondition here: unguarded, a missing `uname` aborts
# under err_exit with status 127 and no diagnostic — outside this script's
# documented 0/1/2 taxonomy, and right above the branch that exists to report an
# unsupported platform legibly
uname_s="$(uname -s)" \
  || { print -u2 -- "iac-tools: cannot determine the OS ('uname -s' failed)"; exit 1 }
uname_m="$(uname -m)" \
  || { print -u2 -- "iac-tools: cannot determine the architecture ('uname -m' failed)"; exit 1 }
case "$uname_s" in
  Darwin) os=darwin ;;
  Linux)  os=linux ;;
  *) print -u2 -- "iac-tools: unsupported OS '$uname_s' — the pinned toolchain publishes darwin and linux builds only"; exit 1 ;;
esac
case "$uname_m" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64)  arch=amd64 ;;
  *) print -u2 -- "iac-tools: unsupported architecture '$uname_m'"; exit 1 ;;
esac

# The default is resolved HERE, after the platform is known, so the cache root
# can be shared across platforms (see --bin-dir in the header). An explicit
# --bin-dir is taken exactly as given — a caller naming a directory means that
# directory, not a parent to hang a leaf off.
# typed, because the expansion below dereferences $HOME under `nounset`: with
# none of the three set (env -i, a container user with no passwd entry) zsh
# would abort with a raw "HOME: parameter not set" and a status outside this
# script's documented 0/1/2 taxonomy — the only precondition here that is not
# reported like the others.
if [[ -z "${bin_dir}" && -z "${IAC_TOOLS_CACHE:-}" && -z "${XDG_CACHE_HOME:-}" && -z "${HOME:-}" ]]; then
  print -u2 -- "iac-tools: no cache root — set --bin-dir, IAC_TOOLS_CACHE, XDG_CACHE_HOME or HOME"
  exit 1
fi
: "${bin_dir:=${IAC_TOOLS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/timos-claude-code-plugins/iac-tools}/${os}-${arch}}"
# ABSOLUTE, always. The harness puts this directory on PATH and then `cd`s into
# the fixture copy, where a relative entry resolves against THAT directory and
# matches nothing — so every tool call would silently fall through to the host's
# brew/apt binaries, which is exactly the version drift this script exists to
# prevent (and it would look like a pass, not an error). `:A` also normalises a
# path whose directory does not exist yet.
bin_dir="${bin_dir:A}"

mkdir -p "$bin_dir" || { print -u2 -- "iac-tools: cannot create $bin_dir"; exit 1 }

# Shared curl options. `--retry` matters because this script became a hard step
# of the repo-wide `script-tests` workflow, whose path filter is a `**`
# catch-all: without it a single transient 5xx from either release host
# (get.helm.sh, GitHub Releases) reds a check on a PR that touched nothing
# IaC-related. `--max-time`
# bounds a hung connection so the job fails fast instead of burning its whole
# timeout. (`--retry-all-errors` is deliberately absent — it is curl >= 7.71 and
# the macOS system curl on older runners rejects an unknown option outright,
# which would turn a resilience feature into a hard failure.)
local -a CURL_OPTS=(-sSfL --retry 3 --retry-delay 2 --max-time 300)

# --- one tool ---------------------------------------------------------------
# `have <tool> <version>` — is the binary ALREADY at the pinned version? Each
# tool prints its version differently, so the probe is per-tool rather than a
# shared `--version | grep`. A tool whose probe fails (missing, or a build that
# does not answer) is simply "not have" and gets downloaded.
have() {
  local tool="$1" want="$2" bin="$bin_dir/$1" out
  [[ -x "$bin" ]] || return 1
  case "$tool" in
    helm)        out="$("$bin" version --short 2>/dev/null)" ;;
    kustomize)   out="$("$bin" version 2>/dev/null)" ;;
    kubeconform) out="$("$bin" -v 2>/dev/null)" ;;
    kube-linter) out="$("$bin" version 2>/dev/null)" ;;
    kyverno)     out="$("$bin" version 2>/dev/null)" ;;
    yq)          out="$("$bin" --version 2>/dev/null)" ;;
  esac || return 1
  # Anchored on a non-version character on BOTH sides, so 1.13.4 does not match
  # a hypothetical 1.13.40 and 0.7.2 does not match 10.7.2.
  [[ "$out" =~ "(^|[^0-9.])${want//./\\.}([^0-9.]|$)" ]]
}

# `fetch_tar <url> <member> <dest>` — download a .tar.gz and extract ONE member
# to <dest>. Extraction goes through a scratch directory rather than
# `tar -xzO > dest`: the helm archive nests its binary under a platform
# directory, so the member name is a path, and `-O` on a multi-entry archive
# would concatenate whatever else matched.
fetch_tar() {
  local url="$1" member="$2" dest="$3" tmp rc=0
  # staged INSIDE $bin_dir, not in $TMPDIR: the final `mv` is then a
  # same-filesystem rename and therefore atomic. Across filesystems — which
  # $TMPDIR always is on macOS (/var/folders vs ~/.cache) and in the container
  # (overlay vs the bind mount) — `mv` degrades to copy+unlink, so a concurrent
  # reader can observe a half-written binary that `[[ -x ]]` accepts.
  # typed, like every other failure in this script: an unwritable or full cache
  # root (a bad actions/cache restore, a bind mount the container user cannot
  # write) would otherwise be the one path that exits with only mktemp's raw
  # stderr, and it skips install_tool's post-install message on the way out
  tmp="$(mktemp -d "$bin_dir/.stage.XXXXXX")" \
    || { print -u2 -- "iac-tools: cannot create a staging directory in $bin_dir"; return 1 }
  # `always` (zsh's TRY/ALWAYS) rather than a bare cleanup line: an interrupt
  # during the ~100 MB cold fetch is the most likely interruption there is, and
  # without it the partial download is simply left behind.
  {
    if ! curl "${CURL_OPTS[@]}" "$url" | tar -xz -C "$tmp" "$member"; then
      print -u2 -- "iac-tools: download or extraction failed: $url"
      rc=1
    # chmod BEFORE the rename, so the rename publishes a ready-to-run binary.
    # The other order leaves a window in which $dest exists but is not
    # executable — the very window staging inside $bin_dir exists to close — and
    # a chmod that fails after the mv leaves a permanently non-executable binary
    # installed, which every later run re-downloads and re-fails on identically.
    elif ! chmod +x "$tmp/$member"; then
      print -u2 -- "iac-tools: could not make the staged $dest executable"
      rc=1
    elif ! mv "$tmp/$member" "$dest"; then
      print -u2 -- "iac-tools: could not install $dest (mv from $tmp/$member failed)"
      rc=1
    fi
  } always {
    rm -rf "$tmp"
  }
  # an explicit status, never the cleanup's: a $TMPDIR reaper or a read-only
  # mount would otherwise report a correctly-installed binary as unresolvable,
  # skipping the post-install verification on the way out
  return $rc
}

fetch_bin() {
  local url="$1" dest="$2" tmp rc=0
  tmp="$(mktemp "$bin_dir/.dl.XXXXXX")" \
    || { print -u2 -- "iac-tools: cannot create a staging file in $bin_dir"; return 1 }
  # the same `always` shape as fetch_tar, and for the same reason: an interrupt
  # during the cold fetch would otherwise leave a .dl.* file inside $bin_dir —
  # a bind-mounted, actions/cache-persisted directory, so the debris would be
  # saved and restored indefinitely
  {
    if ! curl "${CURL_OPTS[@]}" -o "$tmp" "$url"; then
      print -u2 -- "iac-tools: download failed: $url"
      rc=1
    # chmod before the rename, same reason as fetch_tar — and it matters more
    # here: mktemp creates the staging file 0600, so the post-mv order would
    # briefly publish a non-executable binary every single time
    elif ! chmod +x "$tmp"; then
      print -u2 -- "iac-tools: could not make the staged $dest executable"
      rc=1
    elif ! mv "$tmp" "$dest"; then
      print -u2 -- "iac-tools: could not install $dest (mv from $tmp failed)"
      rc=1
    fi
  } always {
    # a no-op after a successful mv; the point is the interrupt path
    rm -f "$tmp"
  }
  return $rc
}

install_tool() {
  local tool="$1" want="$2"
  if have "$tool" "$want"; then return 0; fi
  print -u2 -- "iac-tools: fetching $tool $want ($os/$arch)"
  case "$tool" in
    helm)
      fetch_tar "https://get.helm.sh/helm-v${want}-${os}-${arch}.tar.gz" \
                "${os}-${arch}/helm" "$bin_dir/helm" ;;
    kustomize)
      fetch_tar "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${want}/kustomize_v${want}_${os}_${arch}.tar.gz" \
                kustomize "$bin_dir/kustomize" ;;
    kubeconform)
      fetch_tar "https://github.com/yannh/kubeconform/releases/download/v${want}/kubeconform-${os}-${arch}.tar.gz" \
                kubeconform "$bin_dir/kubeconform" ;;
    kube-linter)
      # kube-linter's asset names carry the architecture as a SUFFIX and omit it
      # entirely for amd64 (kube-linter-linux.tar.gz), unlike every other tool
      # here — an amd64 URL built to the common `-${arch}` shape 404s.
      # an `if` for the same reason as the template guard above: legibility, and
      # keeping a false test from becoming the branch's own status (a non-final
      # `&&` member is errexit-exempt, so the AND form would also have worked)
      local suffix=""
      if [[ "$arch" == arm64 ]]; then suffix="_arm64"; fi
      fetch_tar "https://github.com/stackrox/kube-linter/releases/download/v${want}/kube-linter-${os}${suffix}.tar.gz" \
                kube-linter "$bin_dir/kube-linter" ;;
    kyverno)
      # ...and kyverno spells amd64 `x86_64`.
      local karch="$arch"
      if [[ "$arch" == amd64 ]]; then karch=x86_64; fi
      fetch_tar "https://github.com/kyverno/kyverno/releases/download/v${want}/kyverno-cli_v${want}_${os}_${karch}.tar.gz" \
                kyverno "$bin_dir/kyverno" ;;
    yq)
      fetch_bin "https://github.com/mikefarah/yq/releases/download/v${want}/yq_${os}_${arch}" \
                "$bin_dir/yq" ;;
  esac || return 1
  # Verify AFTER installing, not just that the download succeeded: a release
  # whose asset was re-cut, or a redirect serving an error page, would otherwise
  # leave a binary the suite then runs while believing it is pinned.
  if ! have "$tool" "$want"; then
    print -u2 -- "iac-tools: $tool at $bin_dir/$tool does not report version $want after install"
    return 1
  fi
}

local -a tools=(helm "$helm_v" kustomize "$kustomize_v" kubeconform "$kubeconform_v"
                kube-linter "$kube_linter_v" kyverno "$kyverno_v" yq "$yq_v")
local i rc=0
for (( i = 1; i <= $#tools; i += 2 )); do
  # Keep going on a failure rather than dying at the first one: a cold run with
  # no network should report every tool it could not get, not just the first.
  install_tool "$tools[i]" "$tools[i+1]" || rc=1
done
(( rc == 0 )) || exit 1

print -r -- "$bin_dir"
