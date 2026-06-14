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

# --- findings: reference_checking --------------------------------------------
# Detect family skill/command and agent references that don't resolve to a
# definition in this repo (you renamed/removed a skill or agent and a caller
# still points at the old name). Precision-first: only LITERAL slash-command
# references to OUR plugins are checked, and only agent references in structured
# contexts (subagent_type / agentType / "agent":). Templated refs (`<lang>`) and
# Claude Code built-in subagent types are skipped. The regex/set work is done in
# python3 (far cleaner than shell for this), emitting the findings array.
local has_reference_checking="false"
local reference_findings="[]"

local -a _plugin_dirs
_plugin_dirs=( */.claude-plugin/plugin.json(N) )

if (( ${#_plugin_dirs} )); then
  has_reference_checking="true"
  reference_findings=$(python3 <<'PY'
import os, re, json, glob
plugins = {d for d in os.listdir(".")
           if os.path.isfile(os.path.join(d, ".claude-plugin", "plugin.json"))}
commands = set()
for skill in glob.glob("*/skills/*/SKILL.md"):
    p = skill.split(os.sep)            # [plugin, skills, name, SKILL.md]
    commands.add("/%s:%s" % (p[0], p[2]))
agents = {os.path.splitext(os.path.basename(a))[0] for a in glob.glob("*/agents/*.md")}
# Claude Code built-in subagent types — never flagged as orphans.
builtins = {"general-purpose", "Explore", "Plan", "claude",
            "statusline-setup", "output-style-setup", "code-reviewer",
            "claude-code-guide"}

cmd_re   = re.compile(r'/(development[a-z-]*):([a-z][a-z0-9-]*)')
agent_re = re.compile(r'(?:subagent_type|agentType|"agent")\s*[:=]\s*[\'"]([a-z][a-z0-9-]+)[\'"]')

cmd_refs, agent_refs = {}, {}
for md in glob.glob("**/*.md", recursive=True):
    try:
        text = open(md, encoding="utf-8").read()
    except Exception:
        continue
    for m in cmd_re.finditer(text):
        cmd_refs.setdefault("/%s:%s" % (m.group(1), m.group(2)), set()).add(md)
    for m in agent_re.finditer(text):
        agent_refs.setdefault(m.group(1), set()).add(md)

findings = []
for ref, files in sorted(cmd_refs.items()):
    plug = ref[1:].split(":")[0]
    # only check references to OUR plugins; external/future plugins are skipped
    if plug in plugins and ref not in commands:
        findings.append({
            "id": "ref:cmd:" + ref, "tool": "reference_checking",
            "type": "orphan_command", "severity": "medium",
            "reference": ref, "kind": "command",
            "message": "reference to %s but plugin '%s' defines no such skill" % (ref, plug),
            "fix": "create the skill, correct the reference, or remove it (if it points at planned work, say so explicitly)",
            "files": sorted(files)})
for name, files in sorted(agent_refs.items()):
    if name not in agents and name not in builtins:
        findings.append({
            "id": "ref:agent:" + name, "tool": "reference_checking",
            "type": "orphan_agent", "severity": "high",
            "reference": name, "kind": "agent",
            "message": "reference to agent '%s' but no agents/%s.md defines it" % (name, name),
            "fix": "create the agent, correct the reference, or remove it",
            "files": sorted(files)})
print(json.dumps(findings))
PY
)
  # Guard: if python failed, fall back to empty rather than break the payload.
  if ! jq -e . >/dev/null 2>&1 <<< "$reference_findings"; then
    reference_findings="[]"
    notes+=("reference_checking: scan failed (python3 error); reported no findings.")
  else
    local rn
    rn=$(jq 'length' <<< "$reference_findings")
    notes+=("reference_checking: $rn orphan reference(s) (family commands/agents that don't resolve).")
  fi
else
  notes+=("reference_checking: not a plugin repo; skipped.")
fi

# --- findings: structure_validation ------------------------------------------
# Validate the universal plugin DIRECTORY LAYOUT (not frontmatter — that's
# skill_validation's job): every plugin dir has .claude-plugin/plugin.json with
# the required fields and a name matching the dir; skills live at
# skills/<name>/SKILL.md and agents at flat agents/<name>.md; the marketplace
# entry's source points at the dir. python3 walks the tree and emits findings.
local has_structure_validation="false"
local structure_findings="[]"

if (( ${#_plugin_dirs} )); then
  has_structure_validation="true"
  structure_findings=$(python3 <<'PY'
import os, json, glob
findings = []
mp = {}
mp_path = ".claude-plugin/marketplace.json"
if os.path.isfile(mp_path):
    try:
        for p in json.load(open(mp_path)).get("plugins", []):
            mp[p.get("name")] = p
    except Exception:
        pass

def add(t, path, sev, msg, fix, files):
    findings.append({
        "id": "structure:" + t + ":" + path, "tool": "structure_validation",
        "type": t, "severity": sev, "path": path,
        "message": msg, "fix": fix, "files": files})

tops = [d for d in os.listdir(".") if os.path.isdir(d) and not d.startswith(".")]
for d in sorted(tops):
    pj = os.path.join(d, ".claude-plugin", "plugin.json")
    has_skills = os.path.isdir(os.path.join(d, "skills"))
    has_agents = os.path.isdir(os.path.join(d, "agents"))
    if not os.path.isfile(pj):
        if has_skills or has_agents:
            add("missing_plugin_json", d, "high",
                "%s/ has skills/ or agents/ but no .claude-plugin/plugin.json" % d,
                "add %s/.claude-plugin/plugin.json, or move the skills/agents if this isn't a plugin" % d,
                [d])
        continue
    try:
        data = json.load(open(pj))
    except Exception as e:
        add("malformed_plugin_json", pj, "blocker",
            "%s is not valid JSON: %s" % (pj, e), "fix the JSON syntax", [pj])
        continue
    for f in ("name", "description", "version"):
        if not data.get(f):
            add("missing_plugin_field", pj, "high",
                "%s is missing required field '%s'" % (pj, f),
                "add '%s' to %s" % (f, pj), [pj])
    name = data.get("name")
    if name and name != d:
        add("plugin_name_mismatch", pj, "high",
            "%s name '%s' does not match its directory '%s'" % (pj, name, d),
            "set name to '%s' (or rename the directory) — note this is the published plugin identity" % d,
            [pj])
    if mp and name in mp:
        src = mp[name].get("source")
        if src != "./%s" % d:
            add("marketplace_source_mismatch", mp_path, "high",
                "marketplace.json source for '%s' is '%s', expected './%s'" % (name, src, d),
                "set the '%s' entry source to './%s'" % (name, d), [mp_path])
    for s in sorted(glob.glob("%s/skills/*" % d)):
        if os.path.isfile(s):
            add("skill_layout", s, "high",
                "%s is a file; a skill must be skills/<name>/SKILL.md" % s,
                "move it to %s/SKILL.md" % os.path.splitext(s)[0], [s])
        elif os.path.isdir(s) and not os.path.isfile(os.path.join(s, "SKILL.md")):
            add("skill_layout", s, "high",
                "%s/ has no SKILL.md" % s, "add %s/SKILL.md" % s, [s])
    for a in sorted(glob.glob("%s/agents/*" % d)):
        if os.path.isdir(a):
            add("agent_layout", a, "medium",
                "%s is a directory; agents must be flat agents/<name>.md files" % a,
                "flatten it to a single agents/<name>.md", [a])
        elif not a.endswith(".md"):
            add("agent_layout", a, "medium",
                "%s is not a .md file" % a, "agents/ should contain only <name>.md files", [a])

print(json.dumps(findings))
PY
)
  if ! jq -e . >/dev/null 2>&1 <<< "$structure_findings"; then
    structure_findings="[]"
    notes+=("structure_validation: scan failed (python3 error); reported no findings.")
  else
    local stn
    stn=$(jq 'length' <<< "$structure_findings")
    notes+=("structure_validation: $stn directory-layout finding(s).")
  fi
else
  notes+=("structure_validation: not a plugin repo; skipped.")
fi

# --- emit --------------------------------------------------------------------
local notes_json
notes_json=$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s .)

jq -n \
  --argjson version_check_cfg "$has_version_check" \
  --argjson version_findings  "$version_findings" \
  --argjson skill_val_cfg     "$has_skill_validation" \
  --argjson skill_findings    "$skill_findings" \
  --argjson ref_check_cfg     "$has_reference_checking" \
  --argjson ref_findings      "$reference_findings" \
  --argjson struct_cfg        "$has_structure_validation" \
  --argjson struct_findings   "$structure_findings" \
  --argjson notes             "$notes_json" '
{
  tooling_configured: {
    plugin_version_check: $version_check_cfg,
    skill_validation:     $skill_val_cfg,
    reference_checking:   $ref_check_cfg,
    structure_validation: $struct_cfg
  },
  findings_by_tool: (
    {} +
    (if $version_check_cfg then {plugin_version_check: $version_findings} else {} end) +
    (if $skill_val_cfg     then {skill_validation:     $skill_findings}  else {} end) +
    (if $ref_check_cfg     then {reference_checking:   $ref_findings}    else {} end) +
    (if $struct_cfg        then {structure_validation: $struct_findings} else {} end)
  ),
  coverage: null,
  notes: $notes
}
'
