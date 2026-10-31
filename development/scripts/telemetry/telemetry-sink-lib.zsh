# telemetry-sink-lib.zsh — the ONE definition of a repo's telemetry identity, of
# where its records land by default, and of how a record is appended (#1972).
# SOURCED (never executed) by every script that writes a sink or reads the
# default one: emit-telemetry.zsh (every record), collect-telemetry.zsh (the
# salvage copy) and rollup-telemetry.zsh (the no-operand view).
#
# Why a shared file: emit decides which file a record lands in, and the rollup
# decides which records "this repo" means. Two derivations that disagreed on one
# remote URL shape would file a record under one identity and filter it out
# under another — and nothing downstream would notice. One derivation cannot
# disagree with itself.
#
# THE DEFAULT SINK is `$HOME/.claude/telemetry/<repo-slug>.jsonl`: one
# user-level directory beside Claude Code's own transcripts, OUTSIDE every
# checkout, so removing a worktree or deleting a clone can never take a record
# with it, and every worktree and clone of one repo converges on one file
# (ARCHITECTURE.md, "The telemetry/v1 contract").
#
# THE LOCK: several sessions append at once, and a review-loop record (3–5 KB)
# is larger than an O_APPEND write is guaranteed to stay whole, so every append
# holds an EXCLUSIVE `zsystem flock` on the sink file itself (zsh/system — macOS
# ships no flock(1)), waiting at most TELEMETRY_LOCK_TIMEOUT_S seconds. A reader
# that must see whole files (#1980's backup) takes a SHARED lock on the same file.
#
# THE TOKENS OBJECT (#2720): the one definition of a well-formed `tokens` value,
# shared by emit-telemetry.zsh (which refuses a malformed --tokens, exit 2) and
# validate-telemetry.zsh (which sources this file for it, exit 1), so the
# emitter never writes a record the validator rejects.

zmodload zsh/system 2>/dev/null || {
  print -ru2 -- "telemetry-sink-lib: the zsh/system module is unavailable (needed for zsystem flock)"
  return 3 }

typeset -gr TELEMETRY_LOCK_TIMEOUT_S=10
# How often a waiter retries the lock (#2949). Without -i, zsystem flock -t
# retries once a second, and waiters started together retry on the same tick,
# so only one acquires per second and 16 concurrent writers outlast the timeout.
typeset -gr TELEMETRY_LOCK_INTERVAL_S=0.05

# TLM_TOKENS_JQ_DEF — a jq definition, prepended to a jq program. `tokens_problem`
# takes a non-null `tokens` value and yields nothing when it is well-formed, else
# one diagnostic naming `tokens`. Well-formed: an object with exactly the keys
# source, coverage, by_model and total; source and coverage non-empty strings;
# by_model an object (possibly empty) whose every value has exactly the keys
# input, cache_write_5m, cache_write_1h, cache_read, output and thinking, each a
# non-negative integer; total a non-negative integer equal to input +
# cache_write_5m + cache_write_1h + cache_read + output over every model —
# thinking is part of output and never added again. Free of apostrophes: it is
# spliced into single-quoted jq programs.
typeset -gr TLM_TOKENS_JQ_DEF='
  def tokens_problem:
    def tcount: (type == "number") and (. == floor) and (. >= 0);
    def tstr: (type == "string") and (length > 0);
    if type != "object" then "tokens must be null or an object (got: " + type + ")"
    else
      (["by_model","coverage","source","total"]) as $want
      | ($want - keys) as $miss | (keys - $want) as $extra
      | if ($miss | length) > 0 then "tokens is missing key(s): " + ($miss | join(", "))
        elif ($extra | length) > 0 then "tokens has unknown key(s): " + ($extra | join(", "))
        elif (.source | tstr) | not then "tokens.source must be a non-empty string"
        elif (.coverage | tstr) | not then "tokens.coverage must be a non-empty string"
        elif (.by_model | type) != "object" then "tokens.by_model must be an object"
        else
          ([ .by_model | to_entries[] | .key as $m | .value
             | if type != "object" then "tokens.by_model.\($m) must be an object"
               elif keys != ["cache_read","cache_write_1h","cache_write_5m","input","output","thinking"]
               then "tokens.by_model.\($m) must have exactly the keys input, cache_write_5m, cache_write_1h, cache_read, output, thinking"
               elif ([.[] | tcount] | all) | not
               then "tokens.by_model.\($m) counts must be non-negative integers"
               else empty end ] | .[0])
          // (if (.total | tcount) | not then "tokens.total must be a non-negative integer"
              elif .total != ([.by_model[] | .input + .cache_write_5m + .cache_write_1h + .cache_read + .output] | add // 0)
              then "tokens.total must equal input + cache_write_5m + cache_write_1h + cache_read + output over every model (thinking is not added)"
              else empty end)
        end
    end;
'

# tlm_derive_repo DIR — print the `owner/name` identity of the repo at DIR.
# Derived from the git remote; falls back to the MAIN checkout's basename (the
# #593 rule, amended by #1972) so a record is never anonymous.
tlm_derive_repo() {
  # NB: never name a local `path` in zsh — it is tied to PATH, so declaring it
  # local blanks PATH for the whole function and every external command
  # (git included) silently vanishes.
  local dir="$1" url slug owner name root common
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || url=""

  # Only a HOST-based remote can yield an owner/name. A local-path or file://
  # origin has no owner, and splitting one on `/` fabricates an identity —
  # `/Users/timo/mirrors/widget.git` would become "mirrors/widget", poisoning
  # the very cross-repo grouping key this field exists to be.
  # git's own rule: a colon means scp syntax only when it PRECEDES any slash,
  # so `/Users/x/backup-10:30/widget.git` stays a local path (and falls back to
  # the basename) instead of being split into a fabricated `30/widget`.
  if [[ -n "$url" && ( "$url" == *"://"* || "${url%%/*}" == *:* ) && "$url" != file://* ]]; then
    slug="${url%/}"              # trailing slash first: ".../name.git/" would
    slug="${slug%.git}"          # otherwise keep its .git and become name.git
    local host_ok=1
    if [[ "$slug" == *"://"* ]]; then
      slug="${slug#*://}"          # strip scheme
      slug="${slug#*@}"            # strip any userinfo
      # A leading slash HERE means the authority was empty (https:///owner/name)
      # — check before stripping the host, because the host-strip below would
      # otherwise consume that slash and leave a fabricated owner/name behind.
      [[ "$slug" == /* ]] && host_ok=0
      slug="${slug#*/}"            # strip host
    elif [[ "$slug" == *\]:* ]]; then
      slug="${slug#*\]:}"          # scp-like, bracketed IPv6 host: git@[::1]:owner/name
    else
      slug="${slug#*:}"            # scp-like: git@host:owner/name
    fi
    if [[ $host_ok -eq 1 && "$slug" == */* && "$slug" != /* ]]; then
      # Deliberately the LAST TWO segments: the contract's `repo` is
      # `owner/name`, so a nested namespace (GitLab `group/subgroup/widget`)
      # is truncated to `subgroup/widget` rather than widening the field's
      # shape. GitHub — this family's norm — has no nested namespaces.
      name="${slug##*/}"
      owner="${slug%/*}"; owner="${owner##*/}"
      if [[ -n "$owner" && -n "$name" ]]; then
        print -r -- "$owner/$name"; return 0
      fi
    fi
  fi

  # The basename of the MAIN checkout, never a linked worktree's top level:
  # every worktree of a remote-less repo would otherwise get an identity — and
  # so a file — of its own. The main checkout is the parent of the common git
  # dir when that dir is a `.git`; anything else (a bare repo, an unusual
  # layout) keeps the work tree's own top level, as before #1972.
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  if [[ -n "$common" && "${common:t}" == ".git" ]]; then
    root="${common:h}"
  else
    root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || root=""
  fi
  [[ -n "$root" ]] || root="${dir:A}"
  print -r -- "${root:t}"
}

# tlm_repo_slug REPO — the filename stem a resolved identity is stored under.
# The normal case is `owner/name` → `owner-name`, but `repo` is not guaranteed
# to be a GitHub slug: the basename fallback yields whatever a directory is
# called, and --repo is caller-supplied. So sanitize rather than trust — an
# unusable or invisible filename would silently strand a repo's whole stream:
#   * `/` → `-`  — the contract's rule, and what keeps a slug from ever being a
#     path (so no record can escape the directory into a parent or a subdirectory);
#   * anything outside [A-Za-z0-9._-] → `-` — spaces, colons, newlines and the
#     like are legal in a filename but hostile to every consumer of one. The
#     surviving set is a SUPERSET of what GitHub allows in an owner or a repo
#     name, so a real slug passes through untouched;
#   * a leading `.` or `-` → `_` — a dotfile is invisible to the `*.jsonl` glob
#     every reader of the directory uses, and a leading dash reads as an option
#     to every CLI that later touches the file. Both hazards are positional — a
#     `.` or `-` anywhere else is ordinary — so only the leading character is
#     rewritten.
#   * finally the whole slug is LOWERCASED. GitHub identities are
#     case-insensitive but case-preserving, so the same repo can reach us as
#     `Foo/Bar` from one remote URL and `foo/bar` from a caller's `--repo`;
#     without folding, a case-sensitive filesystem would split one repo's
#     stream across two files — exactly the failure the stable-slug promise
#     exists to prevent. Consumers grouping by the `repo` FIELD should compare
#     case-insensitively for the same reason.
# The mapping is PURE but deliberately MANY-TO-ONE: `a/b-c` and `a-b/c` both
# slug to `a-b-c`, and case-folding adds one more collision class. (For
# NON-ASCII input the character substitution is LC_CTYPE-dependent — one `-` per
# character under a multibyte locale, one per byte otherwise — so it is pure
# *within* a locale, which is one more reason to group by the `repo` field.) So
# the same repo always resolves to the same file, but two repos can share one —
# harmlessly, since the sink is append-only and every record carries its `repo`
# verbatim. A consumer therefore groups by the `repo` FIELD, never by filename;
# the filename only partitions the directory enough that no repo's stream is
# lost.
tlm_repo_slug() {
  local s="${1//\//-}"
  s="${s//[^A-Za-z0-9._-]/-}"
  [[ "$s" == [.-]* ]] && s="_${s#?}"
  print -r -- "${s:l}"
}

# tlm_user_dir — print the user-level telemetry directory. Status 1, with
# nothing printed, when HOME is unset or empty: there is then no user-level
# directory to name, and the caller reports that rather than writing to
# `/.claude/telemetry`.
tlm_user_dir() {
  [[ -n "${HOME:-}" ]] || return 1
  print -r -- "${HOME%/}/.claude/telemetry"
}

# tlm_sink_path TELEMETRY_FILE TELEMETRY_DIR REPO — print the ONE sink file a
# record of REPO lands in, by the emitter's precedence: TELEMETRY_FILE when
# non-empty, else TELEMETRY_DIR/<repo-slug>.jsonl when TELEMETRY_DIR is
# non-empty, else the user-level default <tlm_user_dir>/<repo-slug>.jsonl.
# Status 1, with nothing printed, when the default is the sink and HOME is unset.
# emit-telemetry.zsh writes through it and collect-acceptance-telemetry.zsh
# (#1230) and collect-approver-telemetry.zsh (#1231) read their idempotency
# keys through it, so the file one checks is always the file the other appends
# to.
tlm_sink_path() {
  local file="$1" dir="$2" repo="$3" user_dir=""
  if [[ -n "$file" ]]; then
    print -r -- "$file"
  elif [[ -n "$dir" ]]; then
    print -r -- "${dir%/}/$(tlm_repo_slug "$repo").jsonl"
  else
    user_dir=$(tlm_user_dir) || return 1
    print -r -- "$user_dir/$(tlm_repo_slug "$repo").jsonl"
  fi
}

# tlm_locked_append SINK — append stdin to SINK while holding an EXCLUSIVE
# `zsystem flock` on it. The caller has already created SINK's directory. On
# failure prints the reason (carrying the OS error where there is one) to
# stdout for the caller to wrap in its own diagnostic, and returns:
#   1  the sink could not be created, opened or appended to
#   2  the lock was not acquired within TELEMETRY_LOCK_TIMEOUT_S seconds
# Nothing is appended on either failure. stdin is read only once the lock is
# held, so a writer that times out leaves its record unread and unwritten.
tlm_locked_append() {
  local sink="$1" err="" lock_fd="" rc=0
  # A caller-controlled RELATIVE path may begin with `-` (`--telemetry-dir
  # -drop`), which zsystem would parse as an option; `./` keeps it an operand.
  [[ "$sink" == -* ]] && sink="./$sink"
  # zsystem flock opens an EXISTING file only, so make sure there is one — and
  # this is also where an unwritable sink is found, WITH its OS error: once it
  # succeeds, the flock below opens the same file for writing. `>>` never
  # truncates a file another writer is appending to.
  err=$({ : >> "$sink" } 2>&1) || { print -r -- "${err:-cannot create $sink}"; return 1 }
  # Taken in THIS shell (never inside a substitution, whose subshell would close
  # the descriptor — and release the lock — the moment it returned).
  zsystem flock -t $TELEMETRY_LOCK_TIMEOUT_S -i $TELEMETRY_LOCK_INTERVAL_S -f lock_fd "$sink" 2>/dev/null
  rc=$?
  if (( rc == 2 )); then
    print -r -- "timed out after ${TELEMETRY_LOCK_TIMEOUT_S}s waiting for the lock on $sink"
    return 2
  elif (( rc != 0 )); then
    print -r -- "cannot lock $sink"
    return 1
  fi
  err=$({ cat >> "$sink" } 2>&1)
  rc=$?
  zsystem flock -u $lock_fd 2>/dev/null
  (( rc == 0 )) || { print -r -- "${err:-cannot append to $sink}"; return 1 }
  return 0
}
