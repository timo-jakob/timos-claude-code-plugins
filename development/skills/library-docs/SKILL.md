---
name: library-docs
description: >
  Ensures the agent works from current, authoritative documentation for any
  library, framework, CLI tool, or API in scope — not stale training-data
  guesses. Use whenever writing, reviewing, or explaining code that involves
  external software, especially when version-specific behaviour matters.
---

# Working from current documentation

When the task involves an external library, framework, CLI tool, or API:

## 1. Decide whether you need to fetch

You don't need to fetch every time. Decide based on confidence:

- **Skip fetch** when all of these hold: the library is stable and widely used
  (React 18, Express 4, Lodash, `git`, `curl`), the version in question is
  well within training-data coverage, and the API surface you're touching is
  core / unchanged-for-years. Trust your training data. Note your assumption
  in a sentence so the user can correct you if you're wrong.
- **Fetch** when any of these hold: the library moves fast (Next.js, LangChain,
  Snyk CLI, BuildKit), the version-specific behaviour matters (e.g., a
  parameter that changed semantics in v3 vs v4), you're suggesting code that
  will be committed, the user explicitly mentions a version, or you're
  uncertain about the exact API name.

When in doubt, fetch. Cost is small; getting an API wrong is large.

## 2. Pick the cheapest authoritative source

In this order:

### CLI tools (`git`, `gh`, `docker`, `kubectl`, `npm`, `jq`, etc.)

Use the installed tool's own help — it's the actual version the user runs,
zero network cost, never stale relative to the binary.

```bash
gh help <subcommand>
git help <subcommand>
docker <command> --help
man <tool>
```

### Libraries and frameworks

1. Use `WebSearch` to find the official docs URL. Search for
   `<library-name> <topic> docs site:<expected-domain>` when you know the
   canonical domain (e.g., `site:react.dev`, `site:nextjs.org`,
   `site:docs.snyk.io`). Otherwise an open query is fine.
2. Use `WebFetch` with the official URL and a focused prompt describing
   exactly what you need to know. The prompt is processed against the page —
   keep it specific so the response stays small.

```
WebFetch(
  url="https://react.dev/reference/react/useEffect",
  prompt="Return the exact signature of useEffect including the cleanup function pattern and the dependency-array rules. Quote example code verbatim."
)
```

### Project-local source

If the library is vendored (`node_modules/`, `vendor/`, `Sources/Packages/`),
read its source directly. The local copy is authoritative for the version
the project actually uses — beats any docs site.

## 3. Trust hierarchy

When sources conflict, trust in this order, highest first:

1. The installed binary's `--help` / `man` page (CLI tools).
2. Source code of the locally vendored library.
3. The library's official documentation site (`react.dev`, `docs.python.org`,
   `pkg.go.dev`, the project's GitHub README at the pinned version tag).
4. The library's GitHub repo `README.md` or release notes for the version in
   use.
5. Stack Overflow / Medium / blogs. **Use only as a last resort**; many
   examples are stale or apply to older versions.

Never invent API surface. If you can't verify something, say "I'm not sure
about the exact signature of X — please confirm" instead of guessing.

## 4. Be skeptical of these signals

- Tutorial sites with publication dates older than the library's current
  major version → likely stale.
- Examples that mix syntax styles (e.g., `class extends Component` and hooks
  in the same snippet) → likely cobbled together.
- A doc page that 404s or redirects to `/latest` when the user mentioned a
  specific version → fetch the versioned URL explicitly.

## 5. Cite what you fetched

When you fetch documentation, briefly mention the source in your response
(e.g., "Per react.dev/reference/react/useEffect, …"). This lets the user
verify and shows you didn't guess.
