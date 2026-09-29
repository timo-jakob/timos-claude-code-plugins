#!/usr/bin/env zsh
# Resolve and record a repo's approval model for /development:bootstrap (#1684).
#
# Who approves a repository's PRs used to follow from the machine running
# bootstrap: --claude-approver defaulted to true wherever both Claude Apps were
# registered, so two developers bootstrapping the same repo got different
# results. The approval model is now a DECLARATION in .maintenance.yml, next to
# `primary:`, `gate:` and `tools:`:
#
#   approval: human      # the writer App opens the PR, a human approves,
#                        # armed auto-merge then merges
#   approval: approver   # the Claude Approver approves (Step 4f)
#
# Resolution: a RECORDED value wins on every re-run, else the CHOSEN value (the
# --claude-approver flag: true → approver, false → human), else the DEFAULT,
# which depends on --kind:
#   language       approver when both Claude Apps are registered for the repo's
#                  owner (claude-apps-owner.zsh status, #1683), else human
#   claude-plugin  human, always: a plugin repo is human-only (no AI
#   iac            auto-approval), and the §3l IaC path has no Approver-capable
#                  language to wire. On both, a recorded `approval: approver` is
#                  refused and --claude-approver true is ignored.
# The probe runs only for a language repo with nothing recorded and no flag,
# from the maintenance file's directory, so it asks about that repo's
# owner. An absent key, `null`, `~` or a blank value records nothing, like
# `gate:`. Reading a file needs yq (mikefarah, v4); a repo with no
# .maintenance.yml needs no yq at all.
#
# Usage:
#   resolve-approval.zsh --kind language|claude-plugin|iac
#                        [--maintenance-file <path>]   (default: ./.maintenance.yml)
#                        [--claude-approver true|false]
#                        [--record [--expect human|approver]]
#
# On success (exit 0) stdout carries, one per line:
#   approval=human|approver
#   approval_source=recorded|chosen|default
#   probe=registered|not-registered|no-owner   (only when the probe ran)
#   ignored_flag=--claude-approver <v>         (only when the flag was passed and
#                                               does not decide: a human-only kind
#                                               given true, or a recorded value
#                                               that differs from the flag's)
# When the probe ran, its own report (owner, each App's state, any fix: or
# register-args: line) is copied to stderr, for the caller to relay.
#
# --record (only on a resolution that exits 0) writes the resolved value into an
# EXISTING --maintenance-file, touching no other line (§3a's `gate:` idempotency
# rule): no `approval:` key → the template's comment and key are appended; a key
# present with no value on the same line → that line is filled in, keeping a
# trailing comment (a null written on the NEXT line is refused unchanged, for the
# user to edit); a recorded value → no write at all. --expect names the value the
# caller showed and had confirmed; a resolution that now differs (a probe that
# now reports no owner, a file edited meanwhile) is refused rather than recorded.
#
# Exit codes: 0 resolved; 1 a recorded value is malformed or unsupported, the
# maintenance file could not be read or recorded into, yq (mikefarah) is
# missing, the probe could not read the registry (its stderr is relayed), or
# --expect disagrees with the resolution; 2 usage error.

set -euo pipefail

usage() {
	print -u2 -- "usage: resolve-approval.zsh --kind language|claude-plugin|iac [--maintenance-file <path>]"
	print -u2 -- "       [--claude-approver true|false] [--record [--expect human|approver]]"
	exit 2
}

fail() {
	print -u2 -- "resolve-approval: $1"
	exit 1
}

script_dir="${0:A:h}"
kind=""
maintenance_file="./.maintenance.yml"
flag=""
flag_set=0
record=0
expect=""

while (($# > 0)); do
	case "$1" in
	--kind | --maintenance-file | --claude-approver | --expect)
		(($# >= 2)) || { print -u2 -- "resolve-approval: $1 needs a value" && usage; }
		case "$1" in
		--kind) kind="$2" ;;
		--maintenance-file)
			# a blank path would silently read nothing and probe the working directory
			[[ -n "$2" ]] || { print -u2 -- "resolve-approval: --maintenance-file needs a non-empty path" && usage; }
			maintenance_file="$2"
			;;
		--claude-approver) flag="$2" && flag_set=1 ;;
		--expect) expect="$2" ;;
		esac
		shift 2
		;;
	--record) record=1 && shift ;;
	--help | -h) usage ;;
	*) print -u2 -- "resolve-approval: unknown argument: $1" && usage ;;
	esac
done

case "$kind" in
language | claude-plugin | iac) ;;
*) print -u2 -- "resolve-approval: --kind must be language, claude-plugin or iac" && usage ;;
esac
if ((flag_set)) && [[ "$flag" != true && "$flag" != false ]]; then
	print -u2 -- "resolve-approval: --claude-approver must be true or false, got: $flag"
	usage
fi
if [[ -n "$expect" ]]; then
	((record)) || { print -u2 -- "resolve-approval: --expect only applies with --record" && usage; }
	[[ "$expect" == human || "$expect" == approver ]] ||
		{ print -u2 -- "resolve-approval: --expect must be human or approver, got: $expect" && usage; }
fi
human_only=0
[[ "$kind" == language ]] || human_only=1

# --- the recorded value -----------------------------------------------------------

recorded=""
if [[ -e "$maintenance_file" && ! -f "$maintenance_file" ]]; then
	fail "$maintenance_file is not a regular file"
fi
if [[ -f "$maintenance_file" ]]; then
	[[ -r "$maintenance_file" ]] || fail "cannot read $maintenance_file"
	# Only a file to read needs yq, and only mikefarah's (see resolve-tools.zsh).
	[[ "$(yq --version 2>&1)" == *mikefarah* ]] ||
		fail "yq (mikefarah, v4) is required to read $maintenance_file — install it with: brew install yq"
	approval_type="$(yq -r '.approval | type' "$maintenance_file" 2>/dev/null)" ||
		fail "cannot parse $maintenance_file as YAML"
	# one line per YAML document: a record split across documents is ambiguous
	[[ "$approval_type" != *$'\n'* ]] ||
		fail "$maintenance_file holds more than one YAML document — keep it to one"
	case "$approval_type" in
	'!!null') ;;
	'!!map' | '!!seq') fail "approval: must be human or approver — got a ${${approval_type#!!}/seq/list}" ;;
	*)
		recorded="$(yq -r '.approval' "$maintenance_file")"
		if [[ -n "${recorded//[[:space:]]/}" ]]; then
			[[ "$recorded" == human || "$recorded" == approver ]] ||
				fail "approval: $recorded is not supported — allowed: human | approver"
		else
			recorded=""
		fi
		;;
	esac
fi

if [[ "$kind" == claude-plugin && "$recorded" == approver ]]; then
	fail "approval: approver is not supported on a Claude plugin repository — a plugin repo is human-only (no AI auto-approval). Declare approval: human."
fi
if [[ "$kind" == iac && "$recorded" == approver ]]; then
	fail "approval: approver is not supported on the IaC path — it has no Approver-capable language, so no Approver could ever be wired. Declare approval: human."
fi

# --- resolve recorded → chosen → default --------------------------------------------

typeset -a extra
flag_model=""
if ((flag_set)); then
	if [[ "$flag" == true ]]; then flag_model=approver; else flag_model=human; fi
fi
if [[ -n "$recorded" ]]; then
	approval="$recorded" source=recorded
elif [[ "$flag_model" == human ]] || { [[ "$flag_model" == approver ]] && ((!human_only)); }; then
	approval="$flag_model" source=chosen
else
	source=default approval=human
	if [[ "$kind" == language ]]; then
		# From the maintenance file's directory: the probe asks gh for the owner of
		# the repo it runs in, and that must be the repo being bootstrapped.
		[[ -d "${maintenance_file:h}" ]] || fail "${maintenance_file:h} is not a directory — cannot ask for its repository's owner"
		probe_rc=0
		probe_out="$(cd -- "${maintenance_file:h}" &&
			zsh "$script_dir/claude-apps-owner.zsh" status claude-approver claude-maintenance)" || probe_rc=$?
		case "$probe_rc" in
		0) approval=approver && extra+=(probe=registered) ;;
		3) extra+=(probe=not-registered) ;;
		4) extra+=(probe=no-owner) ;;
		*) fail "the Claude Apps probe (claude-apps-owner.zsh status) exited $probe_rc — relay its message above" ;;
		esac
		[[ -z "$probe_out" ]] || print -u2 -r -- "$probe_out"
	fi
fi
if [[ -n "$flag_model" && "$flag_model" != "$approval" ]]; then
	extra+=("ignored_flag=--claude-approver $flag")
fi

# --- --record: write the resolved value without touching another line ---------------

# Never write back a merge that YAML does not read as the resolved value: the file
# would stop parsing. The write goes through the file itself, keeping its mode and
# inode.
write_back() { # <file> <merged temp>
	[[ "$(yq -r '.approval' "$2" 2>/dev/null)" == "$approval" ]] ||
		fail "could not record the approval model into $1 — merging into its layout would not read back; left it unchanged"
	cat "$2" >"$1" || { record_tmp="" && fail "could not record the approval model into $1 — the merged text is in $2"; }
}

record_approval() {
	local file="$maintenance_file"
	[[ -f "$file" ]] || fail "--record needs an existing $file — a fresh repo gets approval: from .maintenance.yml.tmpl"
	[[ -z "$expect" || "$expect" == "$approval" ]] ||
		fail "approval now resolves $approval ($source), not the $expect that was planned — nothing recorded; re-run the resolution and re-confirm the plan"
	[[ -z "$recorded" ]] || return 0 # already recorded: no write at all

	local -a lines
	lines=("${(@f)$(<"$file")}")
	local i at=0
	for ((i = 1; i <= ${#lines}; i++)); do
		if [[ "${lines[i]}" =~ '^approval[[:space:]]*:' ]]; then
			at=$i
			break
		fi
	done

	if ((at == 0)) && [[ "$(yq -r 'has("approval")' "$file")" == true ]]; then
		fail "cannot find the top-level approval: line in $file to record into (a quoted key?) — write approval: $approval there yourself"
	fi

	record_tmp="$(mktemp "${file:h}/.resolve-approval.XXXXXX")" ||
		fail "could not record the approval model into $file — cannot create a temp file in ${file:h}"
	if ((at == 0)); then
		# No approval: key at all — append the template's lines, so a merged repo
		# and a fresh one agree. The copy is checked on its own: inside a
		# `{ … } || fail` group err_exit is off, and a failed copy would otherwise
		# write back only the appended lines.
		cat "$file" >"$record_tmp" || fail "could not read $file to record into"
		{
			# $(…) strips a trailing newline, so a non-empty last byte means it is missing
			if [[ -n "$(tail -c 1 "$file")" ]]; then print; fi
			print -r -- "# The approval model /development:bootstrap resolved (#1684). A recorded value wins on every"
			print -r -- "# re-run: human (a human approves; armed auto-merge then merges) | approver (the Claude Approver)."
			print -r -- "approval: $approval"
		} >>"$record_tmp" || fail "could not record the approval model into $file"
	else
		# The key is there with no value: fill that line in, keeping any comment.
		local rest="${lines[at]#*:}" comment=""
		[[ "$rest" == *\#* ]] && comment=" #${rest#*\#}"
		LINE="approval: $approval$comment" awk -v at="$at" '
			NR == at { print ENVIRON["LINE"]; next }
			{ print }
		' "$file" >"$record_tmp" || fail "could not record the approval model into $file"
	fi
	write_back "$file" "$record_tmp"
}

# Never leave --record's temp file in the consumer repo — except as the only good
# copy, when the write-back itself failed (record_tmp is cleared there).
record_tmp=""
trap '[[ -z "$record_tmp" ]] || rm -f "$record_tmp"' EXIT

((record)) && record_approval

print -r -- "approval=$approval"
print -r -- "approval_source=$source"
((${#extra} == 0)) || print -rl -- "${extra[@]}"
