#!/usr/bin/env python3
"""Generate the per-plugin command/agent reference from skill/agent frontmatter.

Epic #744 slice (f), issue #757. Writes two pages under docs/reference/:

  commands.md  — every plugin's skills (slash commands) + descriptions
  agents.md    — every plugin's agents + model, tools, descriptions

Both are generated straight from the SKILL.md / agent .md YAML frontmatter
(name, description, tools, model), so the reference can't drift from the code.
CI regenerates and diff-checks them (the version-sync precedent applied to
docs); a human editing a generated page, or frontmatter changing without a
regenerate, turns the docs check red.

Usage:
  scripts/generate-docs-reference.py           # write the pages
  scripts/generate-docs-reference.py --check    # exit 1 if the pages are stale

Frontmatter is parsed with a small tolerant reader (not a strict YAML load):
Claude Code's own frontmatter is lenient — some agent descriptions contain
`): ` and other sequences a strict YAML loader rejects — so we extract only the
handful of top-level keys we need (name / description / model / tools), which
also keeps this script dependency-free (stdlib only).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REFERENCE = ROOT / "docs" / "reference"

# The published plugins, in a stable order (their directory == their plugin name).
PLUGINS = [
    "development",
    "development-claude-plugin",
    "development-docs",
    "development-go",
    "development-java",
    "development-kubernetes",
    "development-python",
    "development-react",
    "development-spring",
    "development-swift",
]

_FRONTMATTER = re.compile(r"^---\n(.*?)\n---", re.S)
_GENERATED_BANNER = (
    "<!-- GENERATED — do not edit. Source: skill/agent frontmatter.\n"
    "     Regenerate with scripts/generate-docs-reference.py; CI diff-checks it (#757). -->"
)


_TOP_KEY = re.compile(r"^([A-Za-z0-9_-]+):(.*)$")


def _frontmatter(path: Path) -> dict:
    """Extract top-level frontmatter fields tolerantly (see module docstring).

    Handles single-line scalars (including values containing `: `), quoted
    scalars, and folded/literal block scalars (`>` / `|`), collapsing the
    latter to a single space-joined string. Indented continuation lines belong
    to the preceding block; lines that aren't a top-level `key:` are ignored.
    """
    m = _FRONTMATTER.match(path.read_text(encoding="utf-8"))
    if not m:
        return {}
    lines = m.group(1).split("\n")
    fields: dict[str, str] = {}
    i = 0
    while i < len(lines):
        km = _TOP_KEY.match(lines[i])
        if not km:
            i += 1
            continue
        key, rest = km.group(1), km.group(2).strip()
        if rest in (">", "|", ">-", "|-", ">+", "|+"):
            block: list[str] = []
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if nxt.strip() and not nxt.startswith((" ", "\t")):
                    break  # a new top-level key ends the block
                block.append(nxt.strip())
                i += 1
            fields[key] = " ".join(block).strip()
            continue
        if len(rest) >= 2 and rest[0] == rest[-1] and rest[0] in ("'", '"'):
            rest = rest[1:-1]
        fields[key] = rest
        i += 1
    return fields


def _oneline(value) -> str:
    """Collapse a (possibly folded/multiline) scalar to one line."""
    return " ".join(str(value).split()) if value else ""


def _cell(value) -> str:
    """One-line, table-cell-safe (escape pipes)."""
    return _oneline(value).replace("|", "\\|")


def _plugin_display_name(plugin: str) -> str:
    data = json.loads((ROOT / plugin / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
    return data.get("name", plugin)


def _skills(plugin: str) -> list[dict]:
    out = []
    for skill_md in sorted((ROOT / plugin / "skills").glob("*/SKILL.md")):
        fm = _frontmatter(skill_md)
        name = fm.get("name") or skill_md.parent.name
        out.append({"name": name, "description": fm.get("description", "")})
    return sorted(out, key=lambda s: s["name"])


def _agents(plugin: str) -> list[dict]:
    out = []
    agents_dir = ROOT / plugin / "agents"
    for agent_md in sorted(agents_dir.glob("*.md")):
        fm = _frontmatter(agent_md)
        out.append(
            {
                "name": fm.get("name") or agent_md.stem,
                "model": fm.get("model", ""),
                "tools": fm.get("tools", ""),
                "description": fm.get("description", ""),
            }
        )
    return sorted(out, key=lambda a: a["name"])


def _render_commands() -> str:
    lines = [
        _GENERATED_BANNER,
        "",
        "# Commands",
        "",
        "Every plugin's skills, exposed as slash commands. Generated from each",
        "`SKILL.md`'s frontmatter, so this list always matches the installed plugins.",
        "For the narrative overview of what each plugin is for, see the",
        "[Plugin overview](plugins.md).",
        "",
    ]
    for plugin in PLUGINS:
        display = _plugin_display_name(plugin)
        skills = _skills(plugin)
        if not skills:
            continue
        lines += [f"## {display}", "", "| Command | Description |", "| --- | --- |"]
        for s in skills:
            lines.append(f"| `/{display}:{s['name']}` | {_cell(s['description'])} |")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _render_agents() -> str:
    lines = [
        _GENERATED_BANNER,
        "",
        "# Agents",
        "",
        "Every plugin's agents. Generated from each agent `.md`'s frontmatter",
        "(model, tools, description), so this list always matches the installed plugins.",
        "",
    ]
    for plugin in PLUGINS:
        display = _plugin_display_name(plugin)
        agents = _agents(plugin)
        if not agents:
            continue
        lines += [f"## {display}", "", "| Agent | Model | Tools | Description |", "| --- | --- | --- | --- |"]
        for a in agents:
            model = f"`{_cell(a['model'])}`" if a["model"] else ""
            lines.append(f"| `{_cell(a['name'])}` | {model} | {_cell(a['tools'])} | {_cell(a['description'])} |")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


TARGETS = {"commands.md": _render_commands, "agents.md": _render_agents}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="exit 1 if a generated page is stale")
    args = ap.parse_args()

    stale = []
    for filename, render in TARGETS.items():
        target = REFERENCE / filename
        new = render()
        if args.check:
            current = target.read_text(encoding="utf-8") if target.exists() else ""
            if current != new:
                stale.append(filename)
        else:
            target.write_text(new, encoding="utf-8")
            print(f"wrote {target.relative_to(ROOT)}")

    if args.check and stale:
        print(
            "generate-docs-reference: stale generated reference pages: "
            + ", ".join(stale)
            + "\nRun scripts/generate-docs-reference.py and commit the result.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
