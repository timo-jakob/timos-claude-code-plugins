#!/usr/bin/env zsh
setopt err_exit nounset pipefail

# gather-claude-plugin-findings.zsh — findings gather for the
# `development-claude-plugin` TOPIC plugin. Emits the same v2 gather contract
# as the language gathers (tooling_configured / findings_by_tool / coverage /
# notes), so the orchestrator constructs a payload and dispatches identically.
#
# Topics aren't code with tests, so `coverage` is always null. v1 ships ONE
# tool — `plugin_version_check` — which folds in scripts/check-marketplace-sync.zsh's
# logic (plugin.json <-> marketplace.json version sync, both directions) and
# emits it as structured findings instead of a pass/fail exit. Future slices add
# skill_validation, reference_checking, structure_validation.
#
# Usage: gather-claude-plugin-findings.zsh <repo_path>
# Output: JSON on stdout.

emulate -L zsh

local repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || { print -u2 -- "usage: $0 <repo_path>"; exit 2 }
command -v jq >/dev/null 2>&1 || { print -u2 -- "jq required, not on PATH."; exit 2 }
cd "$repo"

local -a notes=()
local marketplace=".claude-plugin/marketplace.json"

# --- tooling_configured ------------------------------------------------------
# plugin_version_check is "configured" when a marketplace manifest exists — that
# is the artifact whose drift we police.
local has_version_check="false"
[[ -f "$marketplace" ]] && has_version_check="true"

# --- findings: plugin_version_check -----------------------------------------
# Build a JSON array of finding objects. Three finding types:
#   version_mismatch        — plugin.json version != marketplace.json version
#   missing_from_marketplace — plugin.json exists but no marketplace entry
#   missing_plugin_json      — marketplace lists a plugin with no plugin.json
local version_findings="[]"

if [[ "$has_version_check" == "true" ]]; then
  local findings_file="$(mktemp)"
  print -- "[]" > "$findings_file"

  add_finding() {  # add_finding <json-object>
    jq --argjson f "$1" '. + [$f]' "$findings_file" > "$findings_file.tmp" \
      && mv "$findings_file.tmp" "$findings_file"
  }

  # forward: every <plugin>/.claude-plugin/plugin.json vs its marketplace entry
  local plugin_json plugin_name plugin_version marketplace_version
  for plugin_json in */.claude-plugin/plugin.json(N); do
    plugin_name=$(jq -r '.name'    "$plugin_json")
    plugin_version=$(jq -r '.version' "$plugin_json")
    marketplace_version=$(jq -r --arg name "$plugin_name" \
      '.plugins[] | select(.name == $name) | .version' "$marketplace")

    if [[ -z "$marketplace_version" || "$marketplace_version" == "null" ]]; then
      add_finding "$(jq -n \
        --arg plugin "$plugin_name" \
        --arg pjson "$plugin_json" \
        --arg pver "$plugin_version" \
        '{
          id: ("version:" + $plugin),
          tool: "plugin_version_check",
          type: "missing_from_marketplace",
          severity: "high",
          plugin: $plugin,
          plugin_json: $pjson,
          plugin_json_version: $pver,
          marketplace_version: null,
          message: ("\($plugin) (\($pver)) has a plugin.json but no entry in marketplace.json"),
          fix: ("add a marketplace.json entry for \($plugin) at version \($pver)"),
          files: [$pjson, ".claude-plugin/marketplace.json"]
        }')"
    elif [[ "$plugin_version" != "$marketplace_version" ]]; then
      add_finding "$(jq -n \
        --arg plugin "$plugin_name" \
        --arg pjson "$plugin_json" \
        --arg pver "$plugin_version" \
        --arg mver "$marketplace_version" \
        '{
          id: ("version:" + $plugin),
          tool: "plugin_version_check",
          type: "version_mismatch",
          severity: "high",
          plugin: $plugin,
          plugin_json: $pjson,
          plugin_json_version: $pver,
          marketplace_version: $mver,
          message: ("\($plugin) version mismatch: plugin.json=\($pver) marketplace.json=\($mver)"),
          fix: ("set marketplace.json entry for \($plugin) to \($pver) (plugin.json is the source of truth)"),
          files: [$pjson, ".claude-plugin/marketplace.json"]
        }')"
    fi
  done

  # reverse: every marketplace entry must have a plugin.json on disk
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ ! -f "${name}/.claude-plugin/plugin.json" ]]; then
      add_finding "$(jq -n \
        --arg plugin "$name" \
        '{
          id: ("version:" + $plugin),
          tool: "plugin_version_check",
          type: "missing_plugin_json",
          severity: "high",
          plugin: $plugin,
          plugin_json: null,
          plugin_json_version: null,
          marketplace_version: null,
          message: ("marketplace.json lists \($plugin) but \($plugin)/.claude-plugin/plugin.json does not exist"),
          fix: ("remove the stale \($plugin) entry from marketplace.json, or restore its plugin.json"),
          files: [".claude-plugin/marketplace.json"]
        }')"
    fi
  done < <(jq -r '.plugins[].name' "$marketplace")

  version_findings="$(cat "$findings_file")"
  rm -f "$findings_file" "$findings_file.tmp"

  local n
  n=$(jq 'length' <<< "$version_findings")
  notes+=("plugin_version_check: $n version-sync finding(s) across plugin.json <-> marketplace.json.")
else
  notes+=("plugin_version_check: no .claude-plugin/marketplace.json found; skipped.")
fi

# --- findings: skill_validation ----------------------------------------------
# Validate the YAML frontmatter contract of every SKILL.md and agent .md across
# all plugins. SKILL.md (skills/<name>/SKILL.md) requires name + description and
# `name` must match <name>. Agent files (agents/<name>.md) additionally require
# model (haiku|sonnet|opus) + tools, and `name` must match the filename.
local has_skill_validation="false"
local skill_findings="[]"

local -a md_targets
md_targets=( */skills/*/SKILL.md(N) */agents/*.md(N) )

if (( ${#md_targets} )); then
  has_skill_validation="true"
  local sf="$(mktemp)"
  print -- "[]" > "$sf"
  add_skill_finding() {
    jq --argjson f "$1" '. + [$f]' "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"
  }

  local file kind expected fm body name_val model_val key
  for file in "${md_targets[@]}"; do
    if [[ "$file" == */agents/*.md ]]; then
      kind="agent"; expected="${file:t:r}"      # filename without .md
    else
      kind="skill"; expected="${file:h:t}"      # skills/<name>/SKILL.md -> <name>
    fi

    # frontmatter must be present (file starts with ---)
    if [[ "$(head -1 "$file")" != "---" ]]; then
      add_skill_finding "$(jq -n --arg file "$file" --arg kind "$kind" '{
        id: ("skill:" + $file), tool: "skill_validation", type: "missing_frontmatter",
        severity: "blocker", file: $file, kind: $kind, field: null,
        message: ("\($kind) file \($file) has no YAML frontmatter (must start with ---)"),
        fix: "add a --- frontmatter block with the required keys",
        files: [$file] }')"
      continue
    fi

    fm=$(awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f{print}' "$file")
    body=$(awk '$0=="---"{c++; next} c>=2{print}' "$file")

    local -a required=(name description)
    [[ "$kind" == "agent" ]] && required+=(model tools)
    for key in "${required[@]}"; do
      if ! grep -qE "^${key}:" <<< "$fm"; then
        add_skill_finding "$(jq -n --arg file "$file" --arg kind "$kind" --arg key "$key" '{
          id: ("skill:" + $file + ":" + $key), tool: "skill_validation", type: "missing_field",
          severity: "high", file: $file, kind: $kind, field: $key,
          message: ("\($kind) \($file) is missing required frontmatter key “\($key)”"),
          fix: ("add “\($key):” to the frontmatter"),
          files: [$file] }')"
      fi
    done

    name_val=$(grep -E '^name:' <<< "$fm" | head -1 | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//')
    if [[ -n "$name_val" && "$name_val" != "$expected" ]]; then
      add_skill_finding "$(jq -n --arg file "$file" --arg kind "$kind" --arg got "$name_val" --arg want "$expected" '{
        id: ("skill:" + $file + ":name"), tool: "skill_validation", type: "name_mismatch",
        severity: "high", file: $file, kind: $kind, field: "name",
        message: ("\($kind) \($file): frontmatter name “\($got)” does not match its location (“\($want)” expected)"),
        fix: ("set name: \($want) (or move the file to match the name)"),
        files: [$file] }')"
    fi

    if [[ "$kind" == "agent" ]]; then
      model_val=$(grep -E '^model:' <<< "$fm" | head -1 | sed -E 's/^model:[[:space:]]*//; s/[[:space:]]*$//')
      case "$model_val" in
        ""|haiku|sonnet|opus) ;;   # empty already reported as missing_field
        *)
          add_skill_finding "$(jq -n --arg file "$file" --arg got "$model_val" '{
            id: ("skill:" + $file + ":model"), tool: "skill_validation", type: "invalid_model",
            severity: "medium", file: $file, kind: "agent", field: "model",
            message: ("agent \($file): model “\($got)” is not one of haiku|sonnet|opus"),
            fix: "set model to haiku, sonnet, or opus",
            files: [$file] }')"
          ;;
      esac
    fi

    if [[ -z "${body//[[:space:]]/}" ]]; then
      add_skill_finding "$(jq -n --arg file "$file" --arg kind "$kind" '{
        id: ("skill:" + $file + ":body"), tool: "skill_validation", type: "empty_body",
        severity: "high", file: $file, kind: $kind, field: null,
        message: ("\($kind) \($file) has frontmatter but an empty body"),
        fix: "add the instruction/agent body after the frontmatter",
        files: [$file] }')"
    fi
  done

  skill_findings="$(cat "$sf")"
  rm -f "$sf" "$sf.tmp"
  local sn
  sn=$(jq 'length' <<< "$skill_findings")
  notes+=("skill_validation: $sn finding(s) across ${#md_targets} SKILL.md/agent file(s).")
else
  notes+=("skill_validation: no SKILL.md or agent files found; skipped.")
fi

# --- emit --------------------------------------------------------------------
local notes_json
notes_json=$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s .)

jq -n \
  --argjson version_check_cfg "$has_version_check" \
  --argjson version_findings  "$version_findings" \
  --argjson skill_val_cfg     "$has_skill_validation" \
  --argjson skill_findings    "$skill_findings" \
  --argjson notes             "$notes_json" '
{
  tooling_configured: {
    plugin_version_check: $version_check_cfg,
    skill_validation:     $skill_val_cfg
  },
  findings_by_tool: (
    {} +
    (if $version_check_cfg then {plugin_version_check: $version_findings} else {} end) +
    (if $skill_val_cfg     then {skill_validation:     $skill_findings}  else {} end)
  ),
  coverage: null,
  notes: $notes
}
'
