# MFE App Family Restructuring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure epic #682 and its descendants to match the micro-frontend positions settled in
`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md` — filing the new MFE-composition epic and its six
children, rewriting four issues, rescoping #682, and closing eighteen superseded ones.

**Architecture:** The deliverable is GitHub issue state, not code. Every task is a filing operation followed by a
read-back verification — the issue-filing analogue of the red/green cycle, since a write that silently no-ops (a
wrong API shape, a rejected relationship) is this domain's equivalent of an untested function. Successors are filed
before predecessors close, so every closing comment can name its replacement.

**Tech Stack:** `gh` CLI (REST + GraphQL), `jq`, and the repo's own
`development/skills/resolve-issue/scripts/backfill-sub-issues.zsh` and `read-sub-issues.zsh`.

## Global Constraints

- **Repo:** `timo-jakob/timos-claude-code-plugins`. Every command below assumes `R=timo-jakob/timos-claude-code-plugins`.
- **Issue body convention** (the de facto template across #1059/#1061/#687): `## Type`, `## Motivation`, `## Scope`,
  `## Out of scope` where useful, `## Acceptance criteria` as a `- [ ]` list, `## Dependencies`.
- **No private or confidential source is quoted, cited, linked, or paraphrased-with-attribution.** Every position is
  stated as this family's own, with its own rationale. This repo is public.
- **Native relationships are the source of truth** (#583 for dependencies, #802 for parenthood). Markdown task lists
  are the human-readable view only, and are backfilled to native sub-issues via the repo's own script.
- **One parent per issue.** Attaching a child that already has a parent fails; detach first.
- **Closed sub-issues count as `completed`** in `subIssuesSummary`. Abandoned children must be *detached* from their
  epic, not merely closed, or the epic falsely reports its work as delivered.
- **Only the epic carries the `epic` label.** Available labels: `epic`, `needs-refinement`, `test-case`, `blocked`.
- **Issues are filed as prose.** `story-spec/v1` blocks and `test-case` spin-outs are minted later by
  `/development:refine-issue`; do not hand-author them here.
- **Issue numbers are captured from the `gh issue create` URL, never by searching for the title.** GitHub's search
  index is eventually consistent, so a search run immediately after a create routinely returns nothing and would
  hand the next step an empty variable.
- **Shell state does not survive between commands.** Every captured number is appended to the ID file
  `.superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env` and re-sourced by each later command. Any
  command using `$EPIC` or `$A1`…`$A6` must source that file first, in the same invocation.

---

### Task 1: File the MFE composition epic

**Files:**

- Create: GitHub issue — "Epic: MFE composition — shell + remote shapes over the mount contract"
- Reference: `docs/superpowers/specs/2026-07-27-mfe-app-family-design.md`

**Interfaces:**

- Produces: `$EPIC` — the new epic's issue number, consumed by Tasks 2, 3, 4 and 6.

- [ ] **Step 1: File the epic and capture its number in one invocation**

The Children section deliberately lists titles rather than numbers; Task 3 replaces it with the numbered task list
once the children exist. The number is taken from the URL `gh issue create` prints — never from a title search.

```bash
R=timo-jakob/timos-claude-code-plugins
IDS=.superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
mkdir -p "$(dirname "$IDS")"
URL=$(gh issue create --repo "$R" --label epic \
  --title "Epic: MFE composition — shell + remote shapes over the mount contract" \
  --body "$(cat <<'EOF'
## Type
feat

## Motivation

The family's WebUI story was designed before the target UI shape was settled, and drifted. The earlier design
mirrored the `development-java` + `development-spring` layering onto a pair of co-equal framework topics, which
quietly assumed a browser UI is *one app built with one framework*.

That assumption no longer holds. The default UI shape is a SPA shell whose content is split across independently
deployable micro-frontends. Once that is true, the interesting question stops being "which framework does this app
use" and becomes "what contract does the shell use to load a remote".

This epic builds that contract and the two repo shapes it connects. The positions it rests on are settled in
#1059; the full reasoning, including the rejected alternatives, is in
`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md`.

## Scope

- `mfe-contract/v1` — the `mount(el, ctx)` / `unmount(el)` boundary between a shell and a remote, published as a
  types-only package.
- The **shell** repo shape: outer router, chrome, auth acquisition, the remote loader, and the import map.
- The **remote** (micro-UI) repo shape: a mount/unmount entry, a nested router beneath the delegated base path, and
  an asset container served at a gateway path.
- Mechanical conformance checking, so the contract is enforced rather than documented.
- Bootstrap's UI shape question, and the composition repo's UI-member integration.

## Children

- Contract: `mfe-contract/v1`
- Shell repo shape
- Remote repo shape
- Conformance check + CI gate
- Bootstrap UI shape question
- Composition-repo UI integration

## Acceptance criteria

- [ ] A bootstrapped shell loads a bootstrapped remote through the contract, with no build-time dependency between
      their repos.
- [ ] A remote can change and redeploy without the shell rebuilding or redeploying.
- [ ] The conformance check fails a remote that does not export the contract, and fails a shell/remote pair whose
      contract majors disagree.
- [ ] A composition E2E asserts which MFE versions are live in an environment via the `ops-api` `/info` surface.

## Dependencies

Blocked by #1059 — the positions must be recorded before the machinery encodes them.
EOF
)
echo "EPIC=${URL##*/}" | tee -a "$IDS"
```

- [ ] **Step 2: Verify the epic**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
gh issue view "$EPIC" --repo "$R" --json number,title,labels \
  -q '"\(.number) \(.title) labels=\([.labels[].name]|join(","))"'
```

Expected: the number matches `$EPIC`, the title matches, and `labels=epic`. If `$EPIC` is empty or non-numeric the
create failed — stop and read the error rather than proceeding with an unset variable.

---

### Task 2: File the six children

**Files:**

- Create: six GitHub issues, each referencing `$EPIC` from Task 1

**Interfaces:**

- Consumes: `$EPIC` (Task 1)
- Produces: `$A1`…`$A6` — child issue numbers, consumed by Tasks 3, 4 and by the closing comments in Tasks 8–10.

- [ ] **Step 1: File A1 — the contract**

```bash
R=timo-jakob/timos-claude-code-plugins
IDS=.superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
source "$IDS"
URL=$(gh issue create --repo "$R" \
  --title "feat(mfe): mfe-contract/v1 — the shell↔remote mount contract" \
  --body "$(cat <<EOF
Part of the MFE composition epic #$EPIC. Design: \`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md\` §3.

## Type
feat

## Motivation

The boundary every other child in this epic compiles against. A shell must be able to load a remote it was not
built with, and a remote must be able to redeploy without the shell changing — which requires the interface between
them to be a published, versioned artifact rather than a convention each repo re-derives.

## Scope

- The contract: a remote's entry module exports \`mount(el, ctx)\` and \`unmount(el)\`.
- The \`MfeContext\` shape: \`basePath\` (the route prefix the shell delegates), \`auth\`, \`onNavigate(path)\`, and a
  \`signal\` the shell uses to cancel an in-flight mount.
- Publication as a **types-only** npm package, \`@org/mfe-contract\`. Types-only keeps it a build-time dependency,
  so it satisfies the rule that no repo depends on another repo while still giving both sides one definition.
- **Contract versioning:** the package major is the compatibility boundary. A shell declares the major it
  implements; a remote declares the major it targets.

## Two things this issue must decide, not inherit

The design doc deliberately left these open because they need acceptance criteria rather than an assertion:

1. The exact shape of \`AuthContext\` — which identity claims are exposed, and whether the token accessor is
   synchronous or asynchronous.
2. The precise semantics when \`signal\` aborts mid-mount — specifically whether \`unmount\` is still called for a
   mount that never completed. Getting this wrong leaks DOM and subscriptions on fast route changes.

## Out of scope

- The shell and remote implementations (the next two children).
- Runtime enforcement — that is the conformance child.

## Acceptance criteria

- [ ] \`@org/mfe-contract\` publishes types only, with no runtime export.
- [ ] \`MfeContext\` is fully specified, including the two decisions above, each with a stated rationale.
- [ ] The package's major version is documented as the shell↔remote compatibility boundary.
- [ ] A worked example shows a shell calling \`mount\` and a remote implementing it, both type-checking against the
      package.

## Dependencies

Blocked by #1059 (the position this encodes).
EOF
)")
echo "A1=${URL##*/}" | tee -a "$IDS"
```

- [ ] **Step 2: File A2 — the shell repo shape**

```bash
R=timo-jakob/timos-claude-code-plugins
IDS=.superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
source "$IDS"
URL=$(gh issue create --repo "$R" \
  --title "feat(development-react): shell repo shape — outer router, chrome, auth, remote loader" \
  --body "$(cat <<EOF
Part of the MFE composition epic #$EPIC. Design: \`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md\` §4.1.

## Type
feat

## Motivation

The SPA that hosts everything else. It owns the outer route table, the application chrome, session and auth
acquisition, the import map, and the loader that resolves a matched route to a module and calls \`mount\`.

A plain standalone SPA is simply a shell with zero remotes, so this one shape covers the small-app case too. There
is deliberately no third archetype to maintain, and a small app can grow remotes without a rewrite.

## Scope

- Bootstrap template overlay for the shell shape, layered on the common React overlay (#957) per the established
  compose-don't-clobber rule.
- The **remote loader**: match route → resolve the bare specifier through the import map → dynamic-import → call
  \`mount(el, ctx)\`; call \`unmount\` on route exit; honour the \`AbortSignal\` when a route changes mid-load.
- **Import map injection** at runtime, so environment-specific resolution needs no shell rebuild.
- Auth acquisition and the construction of the \`auth\` context handed to remotes.
- \`onNavigate\` handling — a remote asking the shell to change the outer URL.

## Out of scope

- The contract definition itself (the contract child).
- The container image path — that is #1062, extended to the static-asset case.

## Acceptance criteria

- [ ] Bootstrap renders the shell overlay onto a repo carrying the React marker, preserving the contract-consumer
      and common React layers rather than overwriting them.
- [ ] The loader mounts a remote on route entry and unmounts it on exit, with no leaked DOM or subscriptions.
- [ ] A route change during an in-flight load aborts it via \`signal\` and never mounts the stale remote.
- [ ] A shell with zero remotes builds and runs as an ordinary SPA.
- [ ] bats coverage for the rendered file set, mirroring \`tests/react-templates.bats\`.

## Dependencies

Blocked by the contract child and by #957 (the common React overlay it layers onto).
EOF
)")
echo "A2=${URL##*/}" | tee -a "$IDS"
```

- [ ] **Step 3: File A3 — the remote repo shape**

```bash
R=timo-jakob/timos-claude-code-plugins
IDS=.superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
source "$IDS"
URL=$(gh issue create --repo "$R" \
  --title "feat(development-react): remote repo shape — mount/unmount entry + asset container" \
  --body "$(cat <<EOF
Part of the MFE composition epic #$EPIC. Design: \`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md\` §4.2.

## Type
feat

## Motivation

The micro-UI: a React app that owns a route subtree end-to-end, exports the contract, and ships as a container
serving its own immutable assets. This is the unit that must be independently deployable — the whole shape exists
so a team can release its slice of the UI without coordinating with anyone.

## Scope

- Bootstrap template overlay for the remote shape, layered on the common React overlay (#957).
- The **entry module** exporting \`mount(el, ctx)\` / \`unmount(el)\`.
- A **nested router** mounted beneath the \`basePath\` the shell delegates, with outward navigation routed through
  \`onNavigate\` rather than touching the outer URL directly.
- Build output as content-hashed immutable assets behind a stable entry path.

## Out of scope

- The contract definition (the contract child) and the conformance check (its own child).
- Gateway routing and import-map wiring in the composition repo (the UI-integration child).

## Acceptance criteria

- [ ] Bootstrap renders the remote overlay onto a repo carrying the React marker, composing with rather than
      clobbering the existing layers.
- [ ] The entry module exports \`mount\` and \`unmount\` conforming to the contract package's types.
- [ ] The remote's router operates entirely beneath the injected \`basePath\`, and does not assume it is mounted at
      the origin root.
- [ ] Outward navigation calls \`onNavigate\` rather than manipulating the outer URL.
- [ ] The build emits content-hashed assets reachable behind one stable entry path.
- [ ] bats coverage for the rendered file set.

## Dependencies

Blocked by the contract child and by #957.
EOF
)")
echo "A3=${URL##*/}" | tee -a "$IDS"
```

- [ ] **Step 4: File A4 — the conformance check**

```bash
R=timo-jakob/timos-claude-code-plugins
IDS=.superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
source "$IDS"
URL=$(gh issue create --repo "$R" \
  --title "feat(bootstrap): check-mfe-conformance.zsh + CI gate" \
  --body "$(cat <<EOF
Part of the MFE composition epic #$EPIC. Design: \`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md\` §6.

## Type
feat

## Motivation

A contract nothing checks is a contract that drifts. The shipped \`check-ops-conformance.zsh\` is the precedent: a
standalone checker plus a bootstrap-installed CI job, so conformance is proven per repo rather than assumed.

## Scope

- \`check-mfe-conformance.zsh\`, mirroring \`check-ops-conformance.zsh\` in shape and exit-code discipline.
- Checks: the built entry module exports \`mount\` and \`unmount\` with the expected arity; the remote declares an
  \`@org/mfe-contract\` major the shell supports; the container serves that entry at its gateway path.
- A bootstrap-installed CI workflow running it, following the \`ops-conformance.yml.tmpl\` pattern.
- bats coverage, including a **negative** case per check — a remote missing an export and a major mismatch must
  each fail the checker, so the gate cannot pass vacuously.

## Acceptance criteria

- [ ] A conforming remote passes the checker with the checker unmodified.
- [ ] A remote missing \`mount\` or \`unmount\` fails, naming which export is absent.
- [ ] A contract-major mismatch between shell and remote fails, naming both majors.
- [ ] The bootstrap-installed workflow runs the checker on a UI repo.
- [ ] bats covers each negative case, not only the happy path.

## Dependencies

Blocked by the contract, shell and remote children — there is nothing to check until they exist.
EOF
)")
echo "A4=${URL##*/}" | tee -a "$IDS"
```

- [ ] **Step 5: File A5 — the bootstrap UI shape question**

```bash
R=timo-jakob/timos-claude-code-plugins
IDS=.superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
source "$IDS"
URL=$(gh issue create --repo "$R" \
  --title "feat(bootstrap): UI shape question — browser UI? shell or remote?" \
  --body "$(cat <<EOF
Part of the MFE composition epic #$EPIC. Replaces #1043, which asked a framework question the family no longer has.

## Type
feat

## Motivation

Bootstrap must know which UI shape to scaffold. The question it used to ask — Angular or React — is dead: React is
the default and Angular is not scaffolded (#1059). The gate conditions from that design survive, but the axis
changes from *which framework* to *which shape*.

## Scope

- A non-interactive recommender script following the \`seed-orval-targets.zsh\` precedent: flags in, JSON on stdout,
  distinct exit codes for a produced recommendation, a not-applicable repo, and a usage error.
- **Gate conditions** (any one makes the question not applicable): the stack has no JavaScript; the repo is
  Node-only with no browser UI; the shape is already determined by an existing marker.
- **The question:** browser UI? If yes — shell or remote?
- The bootstrap SKILL's shared-questions table and its Step 2 plan line.

## Out of scope

- Any Angular-vs-React recommendation. That axis is gone.
- Scaffolding either shape — the shell and remote children own their templates.

## Acceptance criteria

- [ ] A non-JavaScript stack, and a Node-only JavaScript repo, are both reported not-applicable with a
      discriminating reason, and no question reaches the user.
- [ ] A browser-UI repo yields a shell-or-remote recommendation and a plan line.
- [ ] Usage errors exit distinctly from not-applicable, with a stderr diagnostic and no JSON on stdout — a
      malformed input must never be silently read as "no UI here".
- [ ] bats covers every gate branch, both shapes, and the usage-error branches.

## Dependencies

Independent of the shell and remote template children; it selects a shape rather than rendering one.
EOF
)")
echo "A5=${URL##*/}" | tee -a "$IDS"
```

- [ ] **Step 6: File A6 — composition-repo UI integration**

```bash
R=timo-jakob/timos-claude-code-plugins
IDS=.superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
source "$IDS"
URL=$(gh issue create --repo "$R" \
  --title "feat(development-composition): UI members — gateway routes, import map, cross-MFE E2E" \
  --body "$(cat <<EOF
Part of the MFE composition epic #$EPIC. Design: \`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md\` §5.

## Type
feat

## Motivation

Where the shell and its remotes actually meet. The composition repo already pins member container images and
asserts gateway-path E2E for backends; UI members join that same flow rather than getting a parallel one.

## Scope

- **Gateway routes for UI members**, so a remote's stable entry path resolves to its container.
- **The import map as the single pin.** It maps a bare specifier to a stable gateway path; *which build* sits behind
  that path is decided by the image tag already pinned in \`.claude-workspace.yaml\`. There is deliberately no second
  version pin — a CDN-style versioned URL would have to be kept in step with the image tag with nothing enforcing
  agreement.
- **Cross-MFE E2E**: drive the shell through a route owned by a remote, proving composition across two
  independently deployed containers.
- **Live-version assertion** via each UI member's \`ops-api\` \`/info\` surface, so the E2E can state which MFE
  versions are actually live.

## Acceptance criteria

- [ ] A constellation pinning a shell and at least one remote renders gateway routes for both.
- [ ] The shell's import map resolves each remote's specifier to its gateway path, with no version string duplicated
      outside the workspace manifest.
- [ ] A Renovate image-tag bump on a remote changes what the shell loads, with no shell rebuild.
- [ ] The E2E navigates the shell into a remote-owned route and asserts remote-rendered content.
- [ ] The E2E asserts each UI member's live version from \`/info\`.

## Dependencies

Blocked by #687 (the composition repo type) and by the shell and remote children.
EOF
)")
echo "A6=${URL##*/}" | tee -a "$IDS"
```

- [ ] **Step 7: Verify all six numbers**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
cat .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
for n in "$A1" "$A2" "$A3" "$A4" "$A5" "$A6"; do
  gh issue view "$n" --repo "$R" --json number,title,state -q '"#\(.number) [\(.state)] \(.title)"'
done
```

Expected: `ids.env` holds seven distinct numeric assignments (`EPIC`, `A1`…`A6`), and each issue resolves to its
intended title in `OPEN` state. An empty or duplicated value means a create failed — stop rather than continuing
with a bad id.

---

### Task 3: Attach the children natively to the epic

**Files:**

- Modify: the epic's body (numbered task list)
- Modify: native sub-issue relationships

**Interfaces:**

- Consumes: `$EPIC`, `$A1`…`$A6`

- [ ] **Step 1: Replace the epic's Children section with the numbered task list**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
gh issue view "$EPIC" --repo "$R" --json body -q .body > /tmp/epic-body.md
python3 - "$A1" "$A2" "$A3" "$A4" "$A5" "$A6" <<'PY'
import sys, re, pathlib
a = sys.argv[1:7]
p = pathlib.Path("/tmp/epic-body.md")
new = (
    "## Children\n\n"
    f"- [ ] #{a[0]} — contract: `mfe-contract/v1`\n"
    f"- [ ] #{a[1]} — shell repo shape\n"
    f"- [ ] #{a[2]} — remote repo shape\n"
    f"- [ ] #{a[3]} — conformance check + CI gate\n"
    f"- [ ] #{a[4]} — bootstrap UI shape question\n"
    f"- [ ] #{a[5]} — composition-repo UI integration\n"
)
text = p.read_text()
text = re.sub(r"## Children\n\n(?:- .*\n)+", new, text, count=1)
p.write_text(text)
PY
gh issue edit "$EPIC" --repo "$R" --body-file /tmp/epic-body.md
```

- [ ] **Step 2: Dry-run the backfill and sanity-check the plan**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
development/skills/resolve-issue/scripts/backfill-sub-issues.zsh \
  --repo "$R" --epic "$EPIC" --dry-run
```

Expected: `would_add` contains exactly the six child numbers, `skipped_cross_repo` is `[]`. If `would_add` holds any
number that is not one of the six, **stop** — a parenthetical reference was parsed as a child declaration.

- [ ] **Step 3: Run the backfill live**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
development/skills/resolve-issue/scripts/backfill-sub-issues.zsh --repo "$R" --epic "$EPIC"
```

Expected: exit 0, `added` holds the six numbers, `failed` is `[]`.

- [ ] **Step 4: Verify natively**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
development/skills/resolve-issue/scripts/read-sub-issues.zsh --repo "$R" --epic "$EPIC" \
  | jq -c '{summary, open_children}'
```

Expected: `summary.total == 6`, `summary.completed == 0`, and `open_children` lists the six.

---

### Task 4: Declare the dependency edges

**Files:**

- Modify: native `blockedBy` relationships on `$EPIC`, `$A1`…`$A6`

**Interfaces:**

- Consumes: `$EPIC`, `$A1`…`$A6`

The edges from the design's §9 sequencing graph: the epic and A1 wait on #1059; A2 and A3 wait on A1 and #957; A4
waits on A1, A2, A3; A6 waits on #687, A2, A3. A5 has none.

- [ ] **Step 1: Write every edge, verifying each immediately**

The helper and its uses must be one invocation — a shell function does not survive between commands. Run the first
edge alone first: if the POST body shape is wrong it fails here, before eleven more attempts.

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env

block() {  # block <issue> <blocker>
  local issue="$1" blocker="$2" bid
  bid=$(gh api "repos/$R/issues/$blocker" --jq .id) || { echo "FAILED to resolve #$blocker"; return 1; }
  gh api -X POST "repos/$R/issues/$issue/dependencies/blocked_by" \
    -F issue_id="$bid" >/dev/null 2>&1
  # verify from the server regardless of the POST's reported status — an
  # already-present edge returns an error we should treat as success
  if gh api "repos/$R/issues/$issue/dependencies/blocked_by" --jq '.[].number' | grep -qx "$blocker"; then
    echo "ok: #$issue blockedBy #$blocker"
  else
    echo "VERIFY FAILED: #$issue not blocked by #$blocker"; return 1
  fi
}

block "$EPIC" 1059 || exit 1     # canary: proves the POST shape before the rest

block "$A1" 1059
block "$A2" "$A1"; block "$A2" 957
block "$A3" "$A1"; block "$A3" 957
block "$A4" "$A1"; block "$A4" "$A2"; block "$A4" "$A3"
block "$A6" 687;   block "$A6" "$A2"; block "$A6" "$A3"
```

Expected: twelve `ok:` lines. Any `VERIFY FAILED` means the edge did not land — stop and report, since a
silently-missing edge is exactly the drift the native-relationship contract exists to prevent. If the canary itself
fails, the endpoint shape is wrong and nothing after it is worth attempting.

- [ ] **Step 2: Confirm the graph is acyclic and reads correctly**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
for n in "$A1" "$A2" "$A3" "$A4" "$A5" "$A6"; do
  development/skills/resolve-issue/scripts/dependency-precheck.zsh --repo "$R" --issue "$n" \
    | jq -c "{issue: $n, decision, blockers: [.blockers[]? | {number, state}]}"
done
```

Expected: no `REJECT_CYCLE` anywhere. `REJECT_BLOCKED` is correct and expected while #1059 and #957 are open — that
is the sequencing working, not a fault.

---

### Task 5: Rewrite #1059 to the settled positions

**Files:**

- Modify: issue #1059 (title and body)

- [ ] **Step 1: Rewrite it**

```bash
R=timo-jakob/timos-claude-code-plugins
gh issue edit 1059 --repo "$R" \
  --title "fix(webui): record the SPA-shell + route-owned MFE positions, React default, and the mount contract" \
  --body "$(cat <<'EOF'
Part of the platform-positions epic #1058. Design:
`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md`.

## Type
fix

## Motivation

Three WebUI positions in this repo are out of step with the family's architecture, and they have already shaped
filed work. This issue records the corrected positions, each **as this family's own opinion with its own
rationale**, so a reader can evaluate them on their merits.

Note this issue's own scope changed on 2026-07-27: it previously proposed Web Components + import maps as the MFE
contract. That mechanism was reconsidered and replaced — see position 3 and the design doc's rejected-alternatives
section.

## The positions

**1. Every browser UI is a SPA shell; substantial UI splits into route-owned micro-frontends.** The shell owns the
outer route table, chrome, and session/auth. Each MFE owns a route subtree end-to-end. *Rationale:* it makes the UI
obey the same rule as the backend — one deployable per bounded context, independently releasable, held together by
a contract rather than a coordinated release. `ARCHITECTURE.md` already names "micro-UI" as a deployable artifact;
this makes it real.

**2. React + TypeScript is the default for any browser UI.** Angular is not scaffolded; an existing Angular asset
may participate by exporting the same contract. *Rationale:* one framework, one blessed path. A second framework's
tooling is speculative cost until something real needs it, and the contract is framework-agnostic at the boundary,
so admitting Angular later costs a plugin rather than a redesign.

**3. The MFE contract is an exported `mount(el, ctx)` / `unmount(el)` pair over an import-map-pinned ES module.**
Module Federation is rejected. *Rationale:* federation couples every remote to the shell's bundler and to a
negotiated set of shared dependency versions, so a remote cannot upgrade on its own schedule — and because remotes
deploy independently, that conflict surfaces in production rather than at build. The usual argument for federation
is avoiding a duplicated framework runtime; route ownership defuses it, since only one remote is mounted at a time.

Custom elements were the other serious contender and are recorded as rejected-with-reasons in the design doc:
route ownership demands rich typed context, which attributes and `CustomEvent` carry poorly, and global tag
registration turns version overlap into a hard error.

## Scope

- Record all three positions with rationale in `ARCHITECTURE.md`.
- Rewrite §2 of `docs/superpowers/specs/2026-07-10-webui-plugin-family-design.md`: it currently presents a
  symmetric Angular/React decision table with a tie-break toward Angular, and names Module Federation as blessed.
  Replace it with a pointer to the 2026-07-27 design and the positions above.
- Update `docs/reference/` where the positions are user-visible.

## Out of scope

Building any of it. The machinery is the MFE composition epic; the issue-level fallout (closures and rescopes) is
handled by its own filing pass.

## Acceptance criteria

- [ ] `ARCHITECTURE.md` states all three positions, each with its rationale, in the family's own words.
- [ ] Spec §2 no longer presents a symmetric framework table, a tie-break rule, or Module Federation as blessed.
- [ ] The rejected alternatives are recorded with reasons, so the decisions are re-evaluable rather than folklore.
- [ ] No private or confidential source is quoted, cited, or linked.
- [ ] `docs/reference/` is updated where these positions are user-visible.

## Dependencies

None. It blocks the MFE composition epic.
EOF
)"
```

- [ ] **Step 2: Verify**

```bash
R=timo-jakob/timos-claude-code-plugins
gh issue view 1059 --repo "$R" --json title,body \
  -q '"\(.title)\n---\nmount contract present: \(.body | test("mount\\(el, ctx\\)"))"'
```

Expected: the new title, and `mount contract present: true`.

---

### Task 6: Rescope #682 and detach the UI children

**Files:**

- Modify: issue #682 (title, body)
- Modify: native sub-issue relationships on #682

**Interfaces:**

- Consumes: `$EPIC` (named in #682's body as the new home for the UI work)

- [ ] **Step 1: Detach the four UI children**

`#686` becomes a standalone top-level epic. `#685`, `#954` and `#1043` are detached *before* they close, so #682's
`subIssuesSummary` never counts abandoned work as completed.

```bash
R=timo-jakob/timos-claude-code-plugins
for n in 685 686 954 1043; do
  cid=$(gh api "repos/$R/issues/$n" --jq .id)
  gh api -X DELETE "repos/$R/issues/682/sub_issue" -F sub_issue_id="$cid" >/dev/null \
    && echo "detached #$n" || echo "DETACH FAILED #$n"
done
```

- [ ] **Step 2: Verify the detachment**

```bash
R=timo-jakob/timos-claude-code-plugins
development/skills/resolve-issue/scripts/read-sub-issues.zsh --repo "$R" --epic 682 \
  | jq -c '{summary, open_children}'
```

Expected: `summary.total == 9` (13 minus the 4 detached), `completed == 4` (#683, #684, #688, #935), and
`open_children` is exactly `[687, 689, 936, 937, 944]`. If any of 685/686/954/1043 is still listed, the delete
failed — fix before closing anything.

- [ ] **Step 3: Retitle and rewrite #682**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
gh issue edit 682 --repo "$R" \
  --title "Epic: JavaScript foundation + API lifecycle + ops surface" \
  --body "$(cat <<EOF
## Type
feat

## Motivation

The non-UI foundation the WebUI work rests on: a TypeScript/JavaScript language plugin, a contract lifecycle that
lets a consumer generate against a producer's spec with no repo-to-repo dependency, and one standardized operations
surface across languages.

**Rescoped 2026-07-27.** This epic was originally "WebUI plugin family + API lifecycle" and carried the UI work
too. That grab-bag scope is part of why a position drift went unnoticed — the UI half was designed against
assumptions the rest of the epic never depended on. The UI work now lives in the MFE composition epic #$EPIC and in
#686; what remains here is exactly what this epic actually delivered and still owes.

## Hard rules carried throughout

- A repo MUST NEVER depend on another repo — only on published, versioned artifacts.
- API-first: specs are authored before implementations and are the authoritative artifact.
- Strict API semantic versioning, enforced mechanically, never by convention.
- gRPC internal, REST external.
- Minimize options: one blessed default per decision.

## Children

Delivered:

- [x] #683 — \`development-javascript\` language plugin
- [x] #684 — API lifecycle: versioned spec publish, semver gate, multi-major serving, deprecation
- [x] #688 — standardized ops surface: \`ops-api\` fragment + OpenTelemetry defaults
- [x] #935 — canonical ops-api implementation for non-Spring Java services

Remaining:

- [ ] #687 — \`development-composition\` topic plugin
- [ ] #689 — API styleguide: org Spectral ruleset content
- [ ] #936 — canonical ops-api implementation for Node services
- [ ] #937 — canonical ops-api implementation for Swift services
- [ ] #944 — API styleguide: pagination + header convention rules

## Moved out

- UI composition → epic #$EPIC
- \`development-react\` topic plugin → #686, now standalone
- Angular topic plugin → closed, deferred until a real Angular asset exists
- Framework recommendation heuristic → closed, replaced by the UI shape question

## Acceptance criteria

- [ ] Every remaining child is merged, or explicitly descoped with its reason recorded.
- [ ] A holistic run proves the contract lifecycle end to end: a producer publishes a spec, a consumer generates a
      typed client and mocks against it, and the semver gate blocks a breaking change.
- [ ] The ops surface is implemented for every language the family scaffolds a service in.

## Dependencies

None.
EOF
)"
```

- [ ] **Step 4: Verify**

```bash
R=timo-jakob/timos-claude-code-plugins
gh issue view 682 --repo "$R" --json title -q .title
```

Expected: `Epic: JavaScript foundation + API lifecycle + ops surface`.

---

### Task 7: Rewrite #957, #1062 and #960

**Files:**

- Modify: issues #957 (title + scope framing), #1062 (scope), #960 (one out-of-scope note)

- [ ] **Step 1: Retitle #957 and add the rescope note**

Its content survives intact — the jsdom test pyramid, testing-library setup, hooks ESLint overlay, and the
compose-don't-clobber layering rule are all shape-neutral. Only the "SPA app repo" framing and the `#954` pointer
change.

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
gh issue view 957 --repo "$R" --json body -q .body > /tmp/957.md
cat >> /tmp/957.md <<EOF

---

**Rescoped 2026-07-27.** Retitled from "blessed Vite SPA app repo" to the **common React overlay**. The family's UI
shape is now a SPA shell plus route-owned remotes (#1059), so this tier ships what both shapes share — the test
pyramid, the testing-library setup, the hooks ESLint overlay, and the compose-don't-clobber layering rule. The
shape-specific templates belong to the shell and remote children of epic #$EPIC.

The former "MFE app shape → #954" out-of-scope pointer is stale: #954 is closed, and the MFE shape is epic #$EPIC.
EOF
gh issue edit 957 --repo "$R" \
  --title "feat(development-react): bootstrap templates — common React overlay" \
  --body-file /tmp/957.md
```

- [ ] **Step 2: Extend #1062 to the static-asset container**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
gh issue view 1062 --repo "$R" --json body -q .body > /tmp/1062.md
cat >> /tmp/1062.md <<EOF

---

**Scope extended 2026-07-27.** The family's UI shapes — the shell and the remote (epic #$EPIC) — both build to a
**static asset bundle with no Node process at runtime**, so the blessed Node service image is the wrong base for
them. This issue must therefore cover two container paths, not one:

1. the Node **service** container (the original scope), and
2. the **static-asset** container serving a shell or a remote at its gateway path.

The second is what the composition repo pins by image tag and what the conformance check probes, so it is
load-bearing for the MFE work rather than a nice-to-have.
EOF
gh issue edit 1062 --repo "$R" --body-file /tmp/1062.md
```

- [ ] **Step 3: Correct #960's stale Angular note**

```bash
R=timo-jakob/timos-claude-code-plugins
gh issue view 960 --repo "$R" --json body -q .body > /tmp/960.md
cat >> /tmp/960.md <<'EOF'

---

**Note 2026-07-27.** The out-of-scope line "Angular equivalents — duplicated there later (#685 / #1037)" is stale:
Angular is deferred and #685 is closed. There is no Angular duplication pending, and no shared `development-webui`
layer is implied — these gates live in the React topic.
EOF
gh issue edit 960 --repo "$R" --body-file /tmp/960.md
```

- [ ] **Step 4: Verify all three**

```bash
R=timo-jakob/timos-claude-code-plugins
for n in 957 1062 960; do
  gh issue view "$n" --repo "$R" --json number,title,body \
    -q '"#\(.number) \(.title)\n   rescope note: \(.body | test("2026-07-27"))"'
done
```

Expected: #957 carries the new title, and all three report `rescope note: true`.

---

### Task 8: Close #954

**Files:**

- Modify: issue #954 (comment + close)

- [ ] **Step 1: Close it with a successor-pointing comment**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
gh issue close 954 --repo "$R" --comment "$(cat <<EOF
Closed 2026-07-27 — superseded, not deferred.

This issue scoped the blessed MFE app shape as **Module Federation host/remote repo shapes**. The family has since
rejected Module Federation: it couples every remote to the shell's bundler and to a negotiated set of shared
dependency versions, so a remote cannot upgrade on its own schedule, and because remotes deploy independently that
conflict surfaces in production rather than at build. The reasoning, including the alternatives weighed, is in
\`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md\` §7; the position is recorded by #1059.

The blessed shape is now an exported \`mount(el, ctx)\` / \`unmount(el)\` pair over an import-map-pinned ES module.

Closed rather than re-scoped because a rewrite would have retained nothing — the mechanism, the repo shapes, and
the acceptance criteria all change. The replacement work is epic #$EPIC, specifically the shell shape (#$A2) and
the remote shape (#$A3).
EOF
)"
```

- [ ] **Step 2: Verify**

```bash
gh issue view 954 --repo timo-jakob/timos-claude-code-plugins --json state,stateReason -q '"\(.state) \(.stateReason)"'
```

Expected: `CLOSED`.

---

### Task 9: Close #1043 and its nine test-case issues

**Files:**

- Modify: issues #1043, #1049–#1057 (comment + close)

- [ ] **Step 1: Close the parent story with its rationale**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
gh issue close 1043 --repo "$R" --comment "$(cat <<EOF
Closed 2026-07-27 — the question this story answers no longer exists.

This story was a bootstrap-time recommender choosing between Angular and React. The family now scaffolds exactly
one browser-UI framework: React + TypeScript is the default, and Angular is not scaffolded at all (#1059). A
recommender that chooses between two options when only one is supported is dead weight.

This is a real write-off: the story was READY, with a full \`story-spec/v1\` block and nine spun-out test-case
issues. It is closed anyway, because leaving a filed, ready issue encoding a reversed decision is how the wrong
thing gets built.

**What survives.** The gate conditions — no JavaScript in the stack, a Node-only repo, a shape already determined
by an existing marker — remain sound, and the script precedent (flags in, JSON out, distinct exit codes) carries
over. They are re-filed as #$A5, which asks the question the family actually has: browser UI? shell or remote? Its
tests differ from this story's, so the test-case issues close with it rather than being re-parented.

Test cases closed alongside: #1049–#1057.
EOF
)"
```

- [ ] **Step 2: Close the nine test-case issues**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
for n in 1049 1050 1051 1052 1053 1054 1055 1056 1057; do
  gh issue close "$n" --repo "$R" --comment \
    "Closed 2026-07-27 with its parent story #1043 — the Angular-vs-React recommendation axis is gone (#1059). The replacement story is #$A5, whose test cases differ." \
    && echo "closed #$n"
done
```

- [ ] **Step 3: Verify all ten are closed**

```bash
R=timo-jakob/timos-claude-code-plugins
for n in 1043 1049 1050 1051 1052 1053 1054 1055 1056 1057; do
  gh issue view "$n" --repo "$R" --json number,state -q '"#\(.number) \(.state)"'
done
```

Expected: ten `CLOSED` lines.

---

### Task 10: Close #685 and its six children

**Files:**

- Modify: issues #685, #1037–#1042 (comment + close)

- [ ] **Step 1: Close the six children first**

Children close first so the epic's closing comment describes a settled state.

```bash
R=timo-jakob/timos-claude-code-plugins
for n in 1037 1038 1039 1040 1041 1042; do
  gh issue close "$n" --repo "$R" --comment \
    "Closed 2026-07-27 with its parent epic #685 — Angular is deferred until a real Angular asset exists (#1059). Not rejected on its merits; simply not yet needed." \
    && echo "closed #$n"
done
```

- [ ] **Step 2: Close #685**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
gh issue close 685 --repo "$R" --comment "$(cat <<EOF
Closed 2026-07-27 — deferred, not rejected.

This epic scoped \`development-angular\` as a co-equal whole-app framework topic alongside React: its own bootstrap
app-repo templates, its own review panel, its own copy of the WebUI-generic quality gates, and an \`ng update\`
agent. That mirrored the \`development-java\` + \`development-spring\` layering onto the frontend.

The family's position is now that React + TypeScript is the default for any browser UI and Angular is not
scaffolded (#1059). An existing Angular asset can still participate — it exports the same \`mount\`/\`unmount\`
contract as any other remote (epic #$EPIC) — but building Angular-specific tooling before any such asset exists is
speculative cost.

**This is a deferral.** Nothing here was found wrong; it was found premature. If a real Angular asset arrives, this
epic is the record of what supporting it would take, and re-opening it is cheap. Note that a re-opened version
would be smaller: the duplicate WebUI-generic quality story (#1041) existed only because Angular was a co-equal app
framework, and a widget-scale Angular remote would not need its own app-repo templates (#1038).

Children closed alongside: #1037, #1038, #1039, #1040, #1041, #1042.
EOF
)"
```

- [ ] **Step 3: Verify**

```bash
R=timo-jakob/timos-claude-code-plugins
for n in 685 1037 1038 1039 1040 1041 1042; do
  gh issue view "$n" --repo "$R" --json number,state -q '"#\(.number) \(.state)"'
done
```

Expected: seven `CLOSED` lines.

---

### Task 11: Final consistency sweep

**Files:**

- Read-only verification across every touched issue

- [ ] **Step 1: Confirm the epic tree is what the design specifies**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
S=development/skills/resolve-issue/scripts
echo "=== #682 (foundation) ==="; "$S/read-sub-issues.zsh" --repo "$R" --epic 682 | jq -c '{summary, open_children}'
echo "=== #$EPIC (MFE composition) ==="; "$S/read-sub-issues.zsh" --repo "$R" --epic "$EPIC" | jq -c '{summary, open_children}'
echo "=== #686 (react, standalone) ==="; "$S/read-sub-issues.zsh" --repo "$R" --epic 686 | jq -c '{summary, open_children}'
echo "=== #1058 (positions) ==="; "$S/read-sub-issues.zsh" --repo "$R" --epic 1058 | jq -c '{summary, open_children}'
```

Expected: #682 → 9 total / 4 completed, open `[687, 689, 936, 937, 944]`. The MFE epic → 6 total / 0 completed.
Issue #686 → 4 open children, and #1058 → unchanged, with #1059 still open.

- [ ] **Step 2: Confirm nothing open still references a closed issue as a live dependency**

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
for n in 687 689 936 937 944 957 958 959 960 1062 "$A1" "$A2" "$A3" "$A4" "$A5" "$A6"; do
  development/skills/resolve-issue/scripts/dependency-precheck.zsh --repo "$R" --issue "$n" \
    | jq -c "{issue: $n, decision, open_blockers: [.blockers[]? | select(.state==\"OPEN\") | .number]}"
done
```

Expected: no `REJECT_CYCLE`. Every `REJECT_BLOCKED` names only genuinely open blockers.

- [ ] **Step 3: Confirm no open issue still names Module Federation or an Angular-vs-React choice**

```bash
R=timo-jakob/timos-claude-code-plugins
gh issue list --repo "$R" --state open --limit 200 --search "\"Module Federation\"" \
  --json number,title -q '.[] | "MF: #\(.number) \(.title)"'
gh issue list --repo "$R" --state open --limit 200 --search "Angular" \
  --json number,title -q '.[] | "NG: #\(.number) \(.title)"'
```

Expected: no `MF:` lines. Any `NG:` line must be an issue that mentions Angular only as the *deferred* case (for
example #1059 stating the position); anything scoping Angular *work* was missed and needs closing.

- [ ] **Step 4: Post the restructuring summary on #682**

The rescoped epic is where a reader will look for what happened, so the record belongs there.

```bash
R=timo-jakob/timos-claude-code-plugins
source .superpowers/sdd/2026-07-27-mfe-app-family-restructuring/ids.env
gh issue comment 682 --repo "$R" --body "$(cat <<EOF
## Restructured 2026-07-27

Design: \`docs/superpowers/specs/2026-07-27-mfe-app-family-design.md\`.

This epic is rescoped to the non-UI foundation it actually delivered — the JavaScript language plugin, the API
lifecycle, and the ops surface. The UI work moved out, because the WebUI half rested on two positions the family
has since reversed: Angular and React as co-equal whole-app frameworks, and Module Federation as the blessed
micro-frontend mechanism.

| Outcome | Issues |
| --- | --- |
| Filed | #$EPIC (epic) + #$A1, #$A2, #$A3, #$A4, #$A5, #$A6 |
| Rewritten | #1059 (positions), #957, #1062, #960 |
| Detached to standalone | #686 |
| Closed — deferred | #685 + #1037–#1042 |
| Closed — superseded | #954, #1043 + #1049–#1057 |
| Remaining here | #687, #689, #936, #937, #944 |

Of what remains, #687, #689 and #936 are ready to build as they stand.
EOF
)"
```

---

## Self-Review

**Spec coverage.** Every section of the design maps to a task: §2 positions → Task 5 (#1059); §3 contract → A1
(Task 2); §4.1/§4.2 repo shapes → A2/A3; §4.3 container path → Task 7 (#1062); §5 pinning → A6; §6 conformance →
A4; §7 rejected alternatives → recorded in #1059's body and #954's closing comment; §8 disposition → Tasks 5–10;
§9 structure → Tasks 3, 4 and 6.

**Gap found and closed.** The design did not say where #686 lives once #682 is rescoped, nor that abandoned
children must be *detached* rather than merely closed — closed sub-issues count as `completed`, which would have
made #682 report delivered work it abandoned. Task 6 handles both.

**Placeholder scan.** No TBD/TODO. The one deliberate two-phase artifact — the epic's Children section, filed by
title in Task 1 and replaced with numbers in Task 3 — has both states written out in full.

**Identifier consistency.** `$EPIC` and `$A1`…`$A6` are established in Tasks 1–2 and used consistently. `$A2`/`$A3`
appear in #954's closing comment and `$A5` in #1043's, both filed after those numbers exist. `block()` is defined
in Task 4 Step 1 before Step 2 uses it.

**Known ordering constraint.** Tasks 8–10 must run after Task 2, since their closing comments cite child numbers.
Task 6 Step 1 must run before Tasks 9 and 10, so detachment precedes closure.
