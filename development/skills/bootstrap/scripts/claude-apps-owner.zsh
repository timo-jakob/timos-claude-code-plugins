#!/usr/bin/env zsh
# claude-apps-owner.zsh — resolve the Claude App pair of the repository you are
# working in (#1683).
#
# The registry (apps.json, schema 2, #1682) holds one App pair per owner — a
# personal login or an organisation. Every consumer picks the pair by the
# OWNER OF THE CURRENT REPOSITORY, so one machine mints the organisation's App
# inside an organisation repo and the personal one inside a personal repo, with
# no flag. This file is that one answer, shared by the mint scripts,
# install-claude-apps.zsh, bootstrap's --claude-approver auto-detection and its
# Step 4.5 preflight, so none of them re-implements it.
#
# Consumers are READ-ONLY: nothing here writes apps.json or the Keychain. A
# schema-1 apps.json (no `owners`) is refused with the command that migrates it
# (register-claude-apps.zsh --list) — it is never migrated from here.
#
# Two ways to use it:
#
#   source claude-apps-owner.zsh      # the claude_apps_* functions below
#   claude-apps-owner.zsh status [<app>...]
#
# `status` reports, for the current repository's owner, each App (default:
# both) as `registered` (its apps.json entry AND its Keychain key),
# `not registered` (no entry), or `key missing` (an entry whose Keychain key is
# gone — the App exists on GitHub, so registering it again cannot help):
#
#   owner: acme-corp (organization)
#   approver: not registered
#   maintenance: key missing
#   register-args: --org acme-corp --apps claude-approver
#   fix: <dir>/install-claude-apps.zsh --verify --fix
#
# `register-args:` names the arguments that make register-claude-apps.zsh
# register exactly the `not registered` Apps for this owner; its tokens never
# contain whitespace (owner slugs and App names cannot). It is omitted when no
# register run can help: a personal account other than your gh login can only
# register its own Apps, which a `note:` line says instead. `fix:` names the
# guided key regeneration for a `key missing` App.
#
# Exit codes (status):
#   0 — every named App is registered for the owner
#   3 — at least one is not, or has lost its key (the report says which)
#   4 — the owner cannot be resolved: not a GitHub repo, or gh unauthenticated
#   1 — apps.json cannot be used (schema 1, not a JSON object), the Keychain
#       cannot be read (locked, prompt denied), or jq is missing — stderr names
#       the fix
#   2 — usage error

setopt err_exit nounset pipefail

CLAUDE_APPS_LIB_DIR="${${(%):-%x}:A:h}"
CLAUDE_APPS_CONFIG="${HOME}/.config/claude-plugins/apps.json"
CLAUDE_APPS_KNOWN=(claude-approver claude-maintenance)

# Set by claude_apps_load.
CA_OWNER=""        # the owner's registry key: the login, lower-cased
CA_OWNER_LOGIN=""  # the owner's login as GitHub spells it
CA_OWNER_KIND=""   # organization | user
CA_REPO=""         # owner/name of the current repository
CA_PEM_RAW=""      # the last Keychain read (_ca_keychain_read)

_ca_err() { print -u2 -r -- "$*" }

claude_apps_display_name() {
  case "$1" in
    claude-approver)    print -- "Claude Approver" ;;
    claude-maintenance) print -- "Claude Maintenance" ;;
    *) _ca_err "Unknown app: $1 (known: ${CLAUDE_APPS_KNOWN[*]})"; return 2 ;;
  esac
}

claude_apps_config_key()        { print -r -- "${1//-/_}" }
claude_apps_keychain_service()  { print -r -- "claude-plugins.${CA_OWNER}.$1" }

# Refuse a registry this code cannot read, naming the fix. An absent apps.json
# is not an error: nothing is registered on this machine yet.
claude_apps_check_registry() {
  if ! command -v jq >/dev/null 2>&1; then
    _ca_err "jq not on PATH (brew install jq)."
    return 1
  fi
  [[ -f "$CLAUDE_APPS_CONFIG" ]] || return 0
  if ! jq -e 'type == "object"' "$CLAUDE_APPS_CONFIG" >/dev/null 2>&1; then
    _ca_err "$CLAUDE_APPS_CONFIG is not a JSON object."
    _ca_err "  Move it aside and re-register: $CLAUDE_APPS_LIB_DIR/register-claude-apps.zsh"
    return 1
  fi
  if ! jq -e 'has("owners")' "$CLAUDE_APPS_CONFIG" >/dev/null 2>&1; then
    _ca_err "$CLAUDE_APPS_CONFIG is still schema 1 (one App pair, not the per-owner registry)."
    _ca_err "  Run: $CLAUDE_APPS_LIB_DIR/register-claude-apps.zsh --list"
    _ca_err "  That migrates it in place; nothing here changes it."
    return 1
  fi
}

# Resolve the current repository's owner. Never falls back to another owner:
# without an owner there is no pair to choose. Returns 4 when it cannot.
claude_apps_resolve_owner() {
  local resp name in_org errf gh_err=""
  if ! command -v gh >/dev/null 2>&1; then
    _ca_err "Cannot resolve the repository owner: gh CLI not on PATH."
    return 4
  fi
  errf=$(mktemp -t claude-apps-owner.XXXXXX)
  if ! resp=$(gh repo view --json owner,name,isInOrganization 2>"$errf"); then
    resp=""
  fi
  gh_err=$(<"$errf")
  rm -f "$errf"
  CA_OWNER_LOGIN=$(print -r -- "$resp" | jq -r '.owner.login // empty' 2>/dev/null || true)
  name=$(print -r -- "$resp" | jq -r '.name // empty' 2>/dev/null || true)
  if [[ -z "$CA_OWNER_LOGIN" || -z "$name" ]]; then
    _ca_err "Cannot resolve the repository owner (gh repo view failed): not in a GitHub-tracked repo, or gh not authenticated."
    [[ -z "$gh_err" ]] || _ca_err "  gh said: ${gh_err//$'\n'/ }"
    _ca_err "  The Claude Apps are chosen by the repository's owner, so none is used without one."
    return 4
  fi
  in_org=$(print -r -- "$resp" | jq -r '.isInOrganization // false')
  CA_OWNER="${CA_OWNER_LOGIN:l}"
  CA_REPO="${CA_OWNER_LOGIN}/${name}"
  CA_OWNER_KIND="user"
  [[ "$in_org" == "true" ]] && CA_OWNER_KIND="organization"
  return 0
}

# The registry check, then the owner. Sets CA_OWNER, CA_OWNER_LOGIN,
# CA_OWNER_KIND and CA_REPO. A registered owner's recorded scope wins over the
# live lookup. Returns 1 for an unusable registry, 4 for an unresolvable owner.
claude_apps_load() {
  claude_apps_check_registry || return 1
  local rc=0
  claude_apps_resolve_owner || rc=$?
  (( rc == 0 )) || return $rc
  local recorded=""
  if [[ -f "$CLAUDE_APPS_CONFIG" ]]; then
    recorded=$(jq -r --arg o "$CA_OWNER" '.owners[$o].owner_scope // ""' "$CLAUDE_APPS_CONFIG")
  fi
  [[ -z "$recorded" ]] || CA_OWNER_KIND="$recorded"
  return 0
}

# 0 when a register run on this machine can register Apps for the loaded
# owner: an organisation (with --org), or a personal owner that is the gh
# login register-claude-apps.zsh registers for. A personal account other than
# yours can register only its own Apps. When the login cannot be looked up the
# answer is yes — register itself then says what is wrong with gh.
claude_apps_can_register() {
  [[ "$CA_OWNER_KIND" == "organization" ]] && return 0
  local login
  login=$(gh api user --jq .login 2>/dev/null) || return 0
  [[ -z "$login" || "${login:l}" == "$CA_OWNER" ]]
}

# The arguments that register <app>... for the loaded owner.
claude_apps_register_args() {
  local -a args=()
  [[ "$CA_OWNER_KIND" == "organization" ]] && args+=(--org "$CA_OWNER")
  args+=(--apps "${(j:,:)@}")
  print -r -- "${args[*]}"
}

claude_apps_register_command() {
  print -r -- "$CLAUDE_APPS_LIB_DIR/register-claude-apps.zsh $(claude_apps_register_args "$@")"
}

# What to do about <app>... not being registered for the loaded owner: the
# register command, or — for someone else's personal account — who can.
claude_apps_register_advice() {
  if claude_apps_can_register; then
    print -r -- "Run: $(claude_apps_register_command "$@")"
  else
    print -r -- "$CA_OWNER is a personal account other than yours; only $CA_OWNER can register its Apps (and install them on $CA_REPO)."
  fi
}

# Print <app>'s App ID for the loaded owner. Reads owners[<owner>] only —
# never a top-level key, whatever else the file holds.
claude_apps_app_id() {
  local app="$1" id=""
  if [[ -f "$CLAUDE_APPS_CONFIG" ]]; then
    id=$(jq -r --arg o "$CA_OWNER" --arg k "$(claude_apps_config_key "$app")" \
      '.owners[$o][$k].app_id // empty' "$CLAUDE_APPS_CONFIG")
  fi
  if [[ -z "$id" ]]; then
    _ca_err "$(claude_apps_display_name "$app") is not registered for $CA_OWNER ($CA_OWNER_KIND), the owner of $CA_REPO."
    _ca_err "  $(claude_apps_register_advice "$app")"
    return 1
  fi
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    _ca_err "owners[\"$CA_OWNER\"].$(claude_apps_config_key "$app").app_id in $CLAUDE_APPS_CONFIG is not numeric: $id"
    return 1
  fi
  print -r -- "$id"
}

# Read <app>'s key for the loaded owner, from the owner-qualified Keychain
# service only, into the global CA_PEM_RAW. Returns 0 (read), 44 (no such item
# — `security`'s "not found") or security's own non-zero exit (the Keychain
# could not be read: locked, prompt denied). Quiet.
_ca_keychain_read() {
  local rc=0
  CA_PEM_RAW=$(security find-generic-password -s "$(claude_apps_keychain_service "$1")" \
    -a "private-key" -w 2>/dev/null) || rc=$?
  (( rc != 0 )) && return $rc
  [[ -n "$CA_PEM_RAW" ]] || return 44
  return 0
}

# Print <app>'s private key for the loaded owner. `security -w` returns a value
# containing newlines — every PEM — hex-encoded; decode a pure-hex retrieval
# back to the PEM (#208). A missing key and an unreadable Keychain are told
# apart: the first needs the key regenerated, the second only an unlock.
claude_apps_read_pem() {
  local app="$1" service rc=0
  service=$(claude_apps_keychain_service "$app")
  _ca_keychain_read "$app" || rc=$?
  if (( rc == 44 )); then
    _ca_err "Private key for $(claude_apps_display_name "$app") ($CA_OWNER) not in the Keychain (service $service)."
    _ca_err "  The App is registered, so re-registering cannot help: regenerate its key with"
    _ca_err "  $CLAUDE_APPS_LIB_DIR/install-claude-apps.zsh --verify --fix   (run inside $CA_REPO)"
    return 1
  elif (( rc != 0 )); then
    _ca_err "Could not read the Keychain item $service (security exit $rc) — unlock the Keychain and re-run."
    return 1
  fi
  if [[ "$CA_PEM_RAW" =~ ^[0-9a-fA-F]+$ ]]; then
    printf '%s' "$CA_PEM_RAW" | xxd -r -p
  else
    printf '%s' "$CA_PEM_RAW"
  fi
}

# <app>'s state for the loaded owner, the three words --list agrees with:
# prints `registered`, `not registered` or `key missing`. Returns 1, with a
# message, when the Keychain cannot be read — that is not "not registered".
claude_apps_state() {
  local app="$1" rc=0 id=""
  if [[ -f "$CLAUDE_APPS_CONFIG" ]]; then
    id=$(jq -r --arg o "$CA_OWNER" --arg k "$(claude_apps_config_key "$app")" \
      '.owners[$o][$k].app_id // empty' "$CLAUDE_APPS_CONFIG")
  fi
  if [[ -z "$id" ]]; then
    print -r -- "not registered"
    return 0
  fi
  # The same check the mint scripts make: an entry they would refuse is not
  # "registered", whatever its key.
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    _ca_err "owners[\"$CA_OWNER\"].$(claude_apps_config_key "$app").app_id in $CLAUDE_APPS_CONFIG is not numeric: $id"
    return 1
  fi
  _ca_keychain_read "$app" || rc=$?
  case "$rc" in
    0)  print -r -- "registered" ;;
    44) print -r -- "key missing" ;;
    *)  _ca_err "Could not read the Keychain item $(claude_apps_keychain_service "$app") (security exit $rc) — unlock the Keychain and re-run."
        return 1 ;;
  esac
}

# --- CLI ----------------------------------------------------------------------

_ca_usage() {
  cat <<EOF
claude-apps-owner.zsh status [<app>...]
  Report whether each App (default: ${CLAUDE_APPS_KNOWN[*]}) is registered
  for the owner of the current repository. Exit 0 all registered, 3 some not
  (or a key missing), 4 owner unresolvable, 1 apps.json or the Keychain
  unreadable (schema 1: run register-claude-apps.zsh --list), 2 usage.
EOF
}

_ca_status() {
  local -a apps=("$@") unregistered=() keyless=()
  (( ${#apps} )) || apps=("${CLAUDE_APPS_KNOWN[@]}")
  local app state rc=0
  for app in "${apps[@]}"; do
    (( ${CLAUDE_APPS_KNOWN[(Ie)$app]} )) || { _ca_err "Unknown app: $app (known: ${CLAUDE_APPS_KNOWN[*]})"; return 2 }
  done
  claude_apps_load || rc=$?
  (( rc == 0 )) || return $rc
  local -a lines=("owner: $CA_OWNER ($CA_OWNER_KIND)")
  for app in "${apps[@]}"; do
    state=$(claude_apps_state "$app") || return 1
    lines+=("${app#claude-}: $state")
    case "$state" in
      "not registered") unregistered+=("$app") ;;
      "key missing")    keyless+=("$app") ;;
    esac
  done
  if (( ${#unregistered} )); then
    if claude_apps_can_register; then
      lines+=("register-args: $(claude_apps_register_args "${unregistered[@]}")")
    else
      lines+=("note: $(claude_apps_register_advice "${unregistered[@]}")")
    fi
  fi
  (( ${#keyless} == 0 )) || lines+=("fix: $CLAUDE_APPS_LIB_DIR/install-claude-apps.zsh --verify --fix")
  print -rl -- "${lines[@]}"
  (( ${#unregistered} + ${#keyless} == 0 )) && return 0
  return 3
}

claude_apps_main() {
  case "${1:-}" in
    status)    shift; _ca_status "$@" ;;
    --help|-h) _ca_usage ;;
    *)         _ca_usage >&2; return 2 ;;
  esac
}

# Run only when executed directly; sourcing defines the functions and nothing
# else.
if [[ "${ZSH_EVAL_CONTEXT:-}" != *:file* ]]; then
  claude_apps_main "$@"
fi
