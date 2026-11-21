# Write and send your product charter

A product charter says what your product is for, who it serves, what wins when goals conflict, what it builds, what it
deliberately does not build, and how that direction has changed. `/product:define-charter`, from the `product` plugin,
writes it with you as `docs/product/charter.md` and renders it to a PDF and an ePub you can send to someone who will
never open the repository.

This page takes you from installing the tools to holding a sendable PDF.

## Install the two rendering tools

The charter is rendered with pandoc (both formats) and Typst (the PDF engine). Install both from Homebrew:

```sh
brew install pandoc typst
```

The renderer needs pandoc 3.14 or newer and Typst 0.15.1 or newer. When either is missing or too old, the skill still
writes the charter, then stops before rendering and prints the same `brew install pandoc typst` line. Nothing is
half-rendered.

You also need the `product` plugin loaded ([Install and use the plugins](install-and-use-plugins.md)). It works with
`development` not installed.

## Run the skill

In the repository the charter belongs to, start a Claude Code session and run:

```text
/product:define-charter
```

The skill decides for itself whether it is creating a charter or updating one: it creates one when
`docs/product/charter.md` does not exist yet, and updates it when it does. You never pick a mode.

Before the first question, it reads what the repository already says about the product: the README, the explanation
pages under `docs/`, the persona registry, the positions in `ARCHITECTURE.md`, `.maintenance.yml`, the titles of open
and recently closed epics, and the issues closed as *not planned*. That last source is the best evidence of what the
product decided not to do.

## What the interview asks

Each turn, the `charter-definer` agent shows you what it found and proposes entries, each marked with the evidence it
came from: a value, a thing the product builds, a thing it deliberately does not build. You confirm, correct or
reject them. It asks only what the evidence cannot answer:

- **Purpose** — why the product exists and what problem it removes.
- **Audience** — who it serves. Each audience is a persona id from your registry (`docs/personas.md`); the charter
  links the registry and never redefines a persona. When the audience needs a persona the registry lacks, or there is
  no registry, the skill tells you to run `/product:define-personas` and carries on without it. When you update a
  charter that already names personas and the registry cannot be found, the charter will not validate until the
  registry is back or those entries are retired by a direction change; the skill tells you so before the interview.
- **Values in conflict** — when two goals pull apart, which one wins.
- **What is out, and why** — every non-goal carries its reason.
- **What has changed** — earlier direction changes. When it finds one in the history it proposes it as a back-dated
  entry, and asks you for any date the evidence does not give. It never invents a date.

It challenges rather than transcribes. If the open epics contradict a non-goal you stated, it says so and asks which
one is true. It asks nothing about tooling, file layout or where files go: the plugin decides those.

When you are happy with the draft, the skill shows you the exact charter and waits for your approval. Nothing is
written before you approve.

## Record a direction change later

A charter is meant to change. When the product changes course, run the skill again and open with the change:

```text
/product:define-charter we now also serve teams that host on their own servers
```

In one turn the agent drafts a dated entry for the *Direction changes* log, names the entries the change retires,
rewrites and adds, and shows you the result. Entries are never deleted and their ids never change: one that no longer
holds is retired by the change, so the log stays a true record of how the direction moved. The newest change comes
first.

## Where the files land

| File | What it is | Committed? |
| --- | --- | --- |
| `docs/product/charter.md` | The charter: prose you own, plus a generated `charter/v1` block that tools read | Yes, through a normal PR |
| `dist/product/charter.pdf` | The rendered PDF | No |
| `dist/product/charter.epub` | The rendered ePub | No |

The skill writes to your working tree only. It validates the charter, renders it, and adds `dist/product/` to
`.gitignore` when that subtree is not already ignored. It never commits, pushes or opens a PR: you review the diff and
ship it like any other change.

The generated block carries a hash of the prose. If someone later edits the prose by hand, the next run notices that
the block is stale and rebuilds it from the prose, so the prose always wins.

## DRAFT versus the sendable copy

The PDF the skill renders is a **DRAFT**, and its cover says so. The skill renders straight after writing, and the
file is not committed yet, so the PDF cannot name the commit it came from.

Once `docs/product/charter.md` and any appendix it lists are committed, render it once more from the repository root.
The cover keeps the DRAFT mark while the charter or one of its appendices has uncommitted changes. The skill's
closing report prints this command with the script's full path filled in:

```sh
"<product plugin directory>/scripts/render-document.zsh" docs/product/charter.md
```

That full path contains the plugin's version, so after a plugin update take the command from a fresh run's report.
It needs no other arguments: the title comes from the charter itself. This copy has no DRAFT mark, its cover carries
the commit's short SHA, after the newest direction-change id when the log has one, and every page's footer carries
the commit and its date.
That is the copy to send: anyone holding it can trace it back to the exact text it came from.

## Add the nav entry in a repository with a docs site

If your repository has a `mkdocs.yml`, the charter is a new docs page that the nav does not list yet, and a strict
build that reports omitted pages as warnings fails on it. The skill reminds you in its closing report but never edits
your site configuration. Add one line under your existing `nav:` yourself, in the same PR as the charter:

```yaml
  - Product charter: product/charter.md
```

## One product across several repositories

A product has one charter, however many repositories implement it. Run `/product:define-charter` in the shared docs
repository, the one the implementing repositories link as a git submodule. The charter lives there, and every linked
repository finds it through the link.

Run in an implementing repository that has no charter of its own, the skill looks in its submodules too. When it finds
the charter in one, it tells you where the charter lives and stops without writing anything, so a second charter
never appears. It also stops without writing, and tells you why, when a declared submodule that could hold the charter
or the persona registry is not initialised yet (it prints the `git submodule update --init` line to run first), and
when `docs/product/charter.md` lies inside a submodule's directory: the repository that submodule links owns the
charter.

## Related

- [Install and use the plugins](install-and-use-plugins.md)
- [Plugin overview — `product`](../reference/plugins.md#product)
- [How the plugins work — personas](../explanation/how-the-plugins-work.md#personas-who-a-story-serves)
