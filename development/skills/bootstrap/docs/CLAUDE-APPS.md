# Claude Apps — registration and identity

Reference for the two GitHub App identities used by the Claude Approver and Maintenance pipelines.

**⚠️ Architecture Change (Epic #476):** The **Claude Approver App** is no
longer CI-driven via GitHub Actions. It is now **user-invoked locally** via
`/development-python:approve` (and the other language plugins' `approve`
skills), with tokens minted by `mint-approver-token.zsh`. This eliminates
platform lock-in and lets users work with any AI coding assistant. Full
design: [APPROVER-APP.md](APPROVER-APP.md).

## The two App identities

| Identity | GitHub App slug pattern | Invocation | Purpose |
| --- | --- | --- | --- |
| **Claude Approver** | `claude-approver-<owner>` | User skill (`/approve`) | Posts pull-request reviews (`APPROVE` / `REQUEST_CHANGES` / commenting). Invoked locally by user when ready to review, never by GitHub Actions. Its `pull_request_review` calls satisfy branch protection's one-approval requirement. |
| **Claude Maintenance** | `claude-maintenance-<owner>` | Orchestrator (`/development:maintenance`) | Opens pull requests + pushes commits on behalf of `/development:maintenance`. Distinct identity so the Approver's anti-rubber-stamp gate (*PR author ≠ Approver identity*) fires correctly on machine-authored PRs. |

The two identities are not a stylistic split — they are **load-bearing
for the Approver's anti-rubber-stamp gate**. If both maintenance and
review ran under one bot, the Approver could end up reviewing PRs the
same bot authored, and the gate that prevents self-approval would
either misfire or have to be turned off. Keeping the identities
distinct removes the question entirely.

## Permissions

Permissions are minimal-by-default. Both Apps register with
**webhook deactivated** — Approver and Maintenance are both driven by
locally minted installation tokens at runtime, not by webhook events;
turning the webhook on would add a delivery destination we don't use.

### Claude Approver

| Scope | Level | Why |
| --- | --- | --- |
| `pull_requests` | write | Post reviews. |
| `contents` | **write** | **Makes the App's `APPROVE` *count*.** GitHub tallies an approval toward a branch's `required_approving_review_count` only from a reviewer who **can push to the repo**, and push access *is* the Contents permission — not Pull requests. With `contents:read` the review posts but `authorCanPushToRepository=false`, so a green + approved PR stays `reviewDecision=REVIEW_REQUIRED` / `mergeStateStatus=BLOCKED` and never auto-merges (#418). Also reads the PR diff. The Approver never pushes — `main` stays PR-protected, so the bot can't write to a protected branch; the grant only confers the "counts as an approval" property. |
| `issues` | read | Read the linked issue body for `feat:` PRs (per the Approver's per-PR-type criteria). |
| `actions` | read | Read GitHub Actions workflow runs and their conclusions (the "everything green" gate). |
| `checks` | read | Read check runs from third-party integrations (Sonar, Snyk, CodeQL) that don't post via Actions. |
| `security_events` | read | Verify Code Scanning alert states (e.g. "is CodeQL alert #N fixed at this head?") under the App's own identity when reviewing security-fix PRs. Without it those reads 403 (`Resource not accessible by integration`) and the approver agent falls back to the user's `gh` auth for the read-only query (#654). Same re-accept dance as #418 for existing installations. |
| `metadata` | read | Required default for every App. |

> **Upgrading an existing Approver install to `contents:write` (#418).** A
> permission *increase* on an already-installed App is **not** applied by
> re-running `register-claude-apps.zsh` — GitHub requires the user to
> **re-accept** the new grant per installation. On a repo whose Approver
> predates this change: App settings → **Permissions → Contents: Read &
> write → Save**, then **github.com/settings/installations → Claude Approver →
> Configure → accept the permission update**, and re-trigger the Approver on a
> fresh head SHA. `install-claude-apps.zsh --verify` flags an Approver still on
> the old read-only grant.

### Claude Maintenance

| Scope | Level | Why |
| --- | --- | --- |
| `contents` | write | Push commits and create branches. |
| `pull_requests` | write | Open and edit PRs. |
| `issues` | write | Close issues from PR descriptions (`Closes #N` is the convention codified in repo memory). |
| `workflows` | write | Push branches that add/edit/delete `.github/workflows/*` files (#750). Without it GitHub rejects any such bot push **wholesale**. Workflow-file PRs go through the same review path as every other change — the Approver's `ci:`/`build:` risk-register lens on app repos, human approval on plugin repos — so a separate user-authored detour buys no extra safety. |
| `actions` | read | Check workflow status before merging. |
| `checks` | read | Same as Approver — third-party check runs. |
| `metadata` | read | Required default. |

> **Upgrading an existing Maintenance install to `workflows: write` (#750).**
> Same dance as the Approver's #418 `contents:write` upgrade — a permission
> *increase* on an already-installed App is **not** applied by re-running
> `register-claude-apps.zsh`; the user must **re-accept** the new grant per
> installation. On a repo whose Maintenance App predates this change: App
> settings → **Permissions → Workflows: Read and write → Save**, then
> **github.com/settings/installations → Claude Maintenance → Configure →
> accept the permission update**. `install-claude-apps.zsh --verify` flags a
> Maintenance App still on the old grant. Until re-accepted, a bot push
> touching a workflow file is rejected and `/development:open-pr` falls back
> to the user-authored path for that run.

Explicitly **not granted**:

- Org administration scopes (members, secrets, settings) on either App.

## Registration

### Manifest flow (primary)

`register-claude-apps.zsh` uses the [GitHub App Manifest
flow](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest):

1. The script generates a manifest JSON describing each App
   (name, URL, permissions, no webhook).
2. The script writes a tiny HTML page to a temp file containing
   an auto-submitting form POSTing the manifest to
   `https://github.com/settings/apps/new?state=<state>` (with `--org`,
   `https://github.com/organizations/<slug>/settings/apps/new?state=<state>`).
3. The script starts a one-shot Python HTTP listener on
   `127.0.0.1:18923` to catch the redirect.
4. The script opens the HTML page in the browser (`open <file>`).
5. The browser auto-submits the form. GitHub shows a confirmation
   page; the user clicks **Create GitHub App**.
6. GitHub redirects to `http://localhost:18923/callback?code=<temp>&state=<state>`.
7. The listener captures `code` + `state`, returns a small "App
   created — return to your terminal" HTML, and exits.
8. The script POSTs the code to `POST /app-manifests/<code>/conversions`,
   which returns the App ID, slug, private key (PEM), and webhook
   secret. We store the ID + slug; we keep the PEM in Keychain; we
   discard the webhook secret (no webhooks).

This runs once per App. Re-running the script with both Apps already
present is a no-op (prints status). If only one App is present, the
script only walks the flow for the missing one.

### Owners: personal account or organisation (#1682)

Every App pair belongs to an **owner** — your personal login, or an
organisation. A machine can hold one entry per owner, so a personal pair
and an organisation pair live side by side; registering one never
touches the other.

- **Personal** (the default): the manifest is POSTed to
  `https://github.com/settings/apps/new` and the Apps are named
  `<app>-<login>`.
- **Organisation** — `register-claude-apps.zsh --org <slug>`: the
  manifest is POSTed to
  `https://github.com/organizations/<slug>/settings/apps/new`, the Apps
  are named `<app>-<slug>`, and the entry records
  `owner_scope: "organization"`. A user-owned private App cannot be
  installed on an organisation at all, which is why an organisation needs
  its own pair. **Until #1683**, `install-claude-apps.zsh`, the mint
  scripts and the bootstrap probes still use only the personal pair, so
  an organisation pair is registered but not yet installed or minted by
  bootstrap.

  Creating an App under an organisation needs **organisation-owner
  rights**. The script says so before the browser opens and checks
  `gh api orgs/<slug>/memberships/<login>`: a membership that is not an
  active `admin`, or no membership at all, stops the run there instead of
  failing on GitHub's page. When the API cannot answer (a token without
  `read:org`, say) it warns and continues — GitHub still refuses a
  non-owner in the browser.

**Registering a subset** — `--apps <app>[,<app>]` registers only the
named Apps (default: both). `--apps claude-maintenance` is the
**writer-only** registration, for an owner that wants no Approver; its
registry entry then holds only `claude_maintenance`.

```sh
register-claude-apps.zsh                                    # personal pair
register-claude-apps.zsh --org acme-corp                    # acme-corp's pair
register-claude-apps.zsh --org acme-corp --apps claude-maintenance   # writer only
register-claude-apps.zsh --list                             # every owner
```

`--list` shows every owner with its scope and the Apps it has.
`--import`, `--reset` and `--print-manifest` act on one owner: the
organisation with `--org <slug>`, your personal login without it.

The redirect listener has a **5-minute timeout** — if the user takes
longer than that to click Create, the script exits cleanly with a
"timeout; re-run when ready" message. No state survives on disk.

### Manual fallback

When the manifest flow can't run (browser sandbox issues, restricted
network, you prefer to see the App creation page directly), use the
manual flow:

1. Open `https://github.com/settings/apps/new` in your browser — or,
   for an organisation, `https://github.com/organizations/<slug>/settings/apps/new`.
2. Fill in the App name (use `claude-approver-<owner>` or
   `claude-maintenance-<owner>`, where the owner is your login or the
   organisation slug, so it matches the manifest's convention).
3. Homepage URL: any URL you control (the App's profile page link;
   we don't use it functionally).
4. **Uncheck "Webhook → Active".**
5. Set the permissions from the table above.
6. Click **Create GitHub App**.
7. On the App's settings page, scroll to **Private keys** and click
   **Generate a private key** — a `.pem` file downloads.
8. Note the **App ID** at the top of the settings page.
9. Hand the credentials to the script:

   ```sh
   register-claude-apps.zsh --import claude-approver \
     --app-id 123456 --pem ~/Downloads/claude-approver.private-key.pem
   ```

   The `--import` mode skips the manifest flow entirely and just
   stores credentials the user already obtained. Add `--org <slug>` to
   file them under an organisation.

### Re-running the script

The script is idempotent, per owner:

- If the selected Apps are registered for the owner (entries present
  in `~/.config/claude-plugins/apps.json` *and* their private keys are
  in Keychain), it prints the current state and exits.
- If only some are registered, it walks the manifest flow for the
  rest.
- `--reset <name> [--org <slug>]` clears a single App's entries
  (config + Keychain) for one owner so it can be re-registered. Useful
  after a name collision or a key rotation. An owner left with no App
  is dropped from the registry.

## Credential storage

### Schema: `~/.config/claude-plugins/apps.json`

Created with mode `0700` on the directory, `0600` on the file.

The registry is keyed by **owner** (schema 2, #1682). Each owner's entry
records its scope and **only the Apps that exist for it** — a
writer-only owner has just `claude_maintenance`:

```json
{
  "schema_version": 2,
  "owners": {
    "timo-jakob": {
      "owner_scope": "user",
      "claude_approver": {
        "app_id": 123456,
        "client_id": "Iv1.abcdef0123456789",
        "slug": "claude-approver-timo-jakob",
        "owner_login": "timo-jakob",
        "owner_scope": "user",
        "registered_at": "2026-06-06T12:34:56Z"
      },
      "claude_maintenance": {
        "app_id": 123457,
        "client_id": "Iv1.9876543210fedcba",
        "slug": "claude-maintenance-timo-jakob",
        "owner_login": "timo-jakob",
        "owner_scope": "user",
        "registered_at": "2026-06-06T12:35:42Z"
      }
    },
    "acme-corp": {
      "owner_scope": "organization",
      "claude_maintenance": {
        "app_id": 234567,
        "client_id": "Iv1.0123456789abcdef",
        "slug": "claude-maintenance-acme-corp",
        "owner_login": "acme-corp",
        "owner_scope": "organization",
        "registered_at": "2026-09-22T09:00:00Z"
      }
    }
  },
  "alias_owner": "timo-jakob",
  "claude_approver":    { "…": "alias of owners[\"timo-jakob\"].claude_approver" },
  "claude_maintenance": { "…": "alias of owners[\"timo-jakob\"].claude_maintenance" }
}
```

**Compatibility aliases.** The top-level `claude_approver` /
`claude_maintenance` keys, and the legacy Keychain items
`claude-plugins.<app>`, mirror owner entries. They exist because the
consumers — the mint scripts, `install-claude-apps.zsh` and the bootstrap
probes — still read them; #1683 moves those consumers onto the per-owner
registry (resolving the owner from the repository) and removes the
aliases. Each alias records its owner (`owner_login`), and only that
owner's successful register, import or reset sets, rotates or removes
it. An **absent** alias is taken only by `alias_owner` — one personal
login: the legacy pair's owner after a migration, otherwise the first
personal login whose run succeeds. Any other login (after a `gh auth`
switch, say) takes none and says so, and an organisation only ever holds
an alias a schema-1 file already recorded for it.
`install-claude-apps.zsh`'s `slug` / `client_id` backfill (below) also
writes only the alias until then, so the next alias sync can undo it —
which costs one repeated `GET /app` lookup, nothing more.

Owner keys are lower-cased (GitHub logins and organisation slugs are
case-insensitive), so `--org Acme-Corp` and `--org acme-corp` name one
owner. A command whose scope contradicts an owner's recorded
`owner_scope` — `--org <your-own-login>`, say — is refused.

App IDs, Client IDs, and slugs are not secrets. The file is mode `0600`
anyway to keep all per-user config in one consistent posture.

### Migration from schema 1

Before #1682, `apps.json` held one pair at the top level
(`schema_version: 1`, no `owners`). The first invocation of any
`register-claude-apps.zsh` subcommand (bar `--help`) migrates it in
place, non-destructively:

1. The original is copied to `apps.json.v1.bak` beside it (never
   overwritten, so it always holds the pre-migration file).
2. Each Keychain key is copied from `claude-plugins.<app>` to the
   owner-qualified `claude-plugins.<owner>.<app>` (an owner-qualified key
   that already exists is kept). A legacy key that is simply absent is
   reported, and the entry is filed without one — add it with `--import`.
3. Each entry is filed under its recorded `owner_login` in `owners` —
   the current `gh` login when none was recorded — and `schema_version`
   becomes `2`. The top-level keys and the legacy Keychain items stay,
   as the aliases above, each stamped with the owner it was filed under;
   the first personal entry's owner becomes `alias_owner`.

The config is written last, so a run that cannot **read** a legacy key
(a locked Keychain, a denied prompt) stops before writing it, leaving
the file un-migrated for the next run to retry. A file that already has
`owners` is left alone — the migration is idempotent.

`client_id` (#223) may be empty or absent on entries created by the
`--import` flow or by older versions; `install-claude-apps.zsh`
backfills it (together with `slug`) from `GET /app` when it has to
resolve a missing slug. Nothing consumes it yet — the numeric
`app_id` remains a valid JWT issuer and a valid `client-id` input for
`actions/create-github-app-token@v3` — it is captured so no manual
lookup is needed if GitHub ever drops numeric-ID acceptance.

### Private keys: macOS Keychain

Each PEM is stored as a generic password:

- Service: `claude-plugins.<owner>.<app>` — e.g.
  `claude-plugins.timo-jakob.claude-approver`,
  `claude-plugins.acme-corp.claude-maintenance`
- Account: `private-key`
- Password: the full PEM contents, including the
  `-----BEGIN/END RSA PRIVATE KEY-----` lines

The legacy service names `claude-plugins.claude-approver` /
`claude-plugins.claude-maintenance` are the Keychain half of the
compatibility aliases above — which owner's key each holds is decided
there — and are removed by #1683.

This matches the pattern `automate-private.sh` already uses for the
SonarQube admin password. Retrieval:

```sh
security find-generic-password \
  -s claude-plugins.timo-jakob.claude-approver \
  -a private-key -w
```

(`-w` prints the password to stdout; the script consumes it directly
when minting App tokens, never writing it to a disk file.)

### Why not keep the PEM on disk

A `.pem` file on disk is a plaintext private key. Even with `0600`
permissions, every backup, every `tar`, every developer-tools sweep
can see it. Keychain encrypts at rest, integrates with the login
session, and matches how the bootstrap already handles the Sonar
admin password. One pattern, one place to look.

## Per-repo installation

Once registered, each App is *installed* on individual repos via
`/development:bootstrap --claude-approver true` (which delegates to
`install-claude-apps.zsh`). That flow:

1. Reads App IDs from `apps.json`.
2. Installs both Apps on the current repo via the browser install flow.
3. Stores **no repo secrets or variables** (#476/#498). Both identities
   mint their installation tokens locally from the Keychain
   (`mint-approver-token.zsh` / `mint-maintenance-token.zsh`), so the
   private keys never leave the machine and nothing repo-side holds
   credentials.

**Repos installed before epic #476** may still carry the CI-era
config (`CLAUDE_*_PRIVATE_KEY` / `ANTHROPIC_API_KEY` secrets,
`CLAUDE_*_APP_ID` / `CLAUDE_APPROVER_AUTHOR_ALLOWLIST` variables).
Nothing consumes them anymore; `install-claude-apps.zsh --verify --fix`
deletes the unambiguous ones (it skips any name a workflow file still
references, and never auto-deletes `ANTHROPIC_API_KEY`).

## Rotation

GitHub Apps can have multiple active private keys at once, so
rotation is non-disruptive:

1. Generate a new key in the App's settings page.
2. Run `register-claude-apps.zsh --import <name> --app-id <id> --pem <new-pem-path> [--org <slug>]`.
   The script replaces the owner's Keychain entry and updates
   `registered_at`.
3. There is nothing repo-side to update (#498): tokens are minted from
   the Keychain, so every subsequent mint uses the new key immediately.
4. Delete the old key from the App's settings page.

Old keys keep working until they're revoked, so there is no
narrow rollover window.

## Writer identity for plugin repos (`/development:open-pr`)

A Claude-plugin repo is the origin of every other repo, so it has **no
AI Approver** — a human reviews. But GitHub blocks you from approving a
PR you authored, so Claude's PRs in these repos must be authored by a
*machine* identity that you can then approve.

That writer is the **Claude Maintenance App, reused** — it already has
`contents:write` + `pull_requests:write` and a local token-minting path
(`mint-maintenance-token.zsh` → Keychain key → 1-hour installation
token), so no new App is registered. Install it on a plugin repo with:

```bash
install-claude-apps.zsh --writer-only   # Maintenance App only; no Approver, no ANTHROPIC_API_KEY, no repo secrets
```

Then `/development:open-pr` mints the writer token, pushes the branch as
the bot, opens the PR as `claude-maintenance-<login>[bot]`, and arms
squash auto-merge with branch deletion. You review and approve; GitHub
merges it. The repo's merge settings (squash-only, `allow_auto_merge`,
`delete_branch_on_merge`) are configured by `branch-protection.sh`
during bootstrap.

## Testing the registration flow

End-to-end testing genuinely creates GitHub Apps under your account,
so it has side effects. The script supports a few non-destructive
testing modes:

- `register-claude-apps.zsh --print-manifest claude-approver [--org <slug>]`
  — emits the manifest JSON for inspection without registering anything
  or opening any browser tab (without `--org` it asks `gh` for your
  login, its only network call).
- `register-claude-apps.zsh --list` — prints every owner with the Apps
  registered for it, their IDs and slugs; no network calls.

Manual end-to-end test:

1. Ensure no entries in `apps.json` (`mv ~/.config/claude-plugins/apps.json{,.bak}`).
2. Run the script.
3. Confirm both browser tabs open, click through both flows.
4. Verify `apps.json` shows both entries under `owners.<your-login>`.
5. Verify `security find-generic-password -s claude-plugins.<your-login>.claude-approver -a private-key -w` prints a PEM.
6. Visit `https://github.com/settings/apps` and confirm both Apps exist with the expected permissions.

For routine development, prefer `--print-manifest` plus the `--import`
fallback — it lets you verify the script's storage and config-handling
without burning two real Apps each iteration.
