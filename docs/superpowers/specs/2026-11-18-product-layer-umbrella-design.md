# Product layer — umbrella (roles, projects, order)

Date: 2026-11-18. Status: draft for maintainer approval.

This is the map. Each project below gets its own design document when its turn
comes; project 1's is
[`2026-11-18-product-plugin-charter-design.md`](2026-11-18-product-plugin-charter-design.md).

## Why

The family today starts at "there is an issue". Nothing above that is written
down: why the product exists, what it deliberately does not do, and how the
maintainer's direction has changed. The cost shows in this repo's backlog — 918
open issues (375 `test-case`, 64 `review-residue`, 58 epics), a good share of
them already done, superseded, or no longer wanted. Deciding "no longer wanted"
by hand is slow, and no tool can do it, because the thing an issue would be
judged against exists only in the maintainer's head.

Every product roadmap reaches this point. So the answer is a reusable product
layer for any repo the family serves, not a one-off cleanup here.

## Three roles and what each owns

| Role | Owns | Talks to a human? |
|---|---|---|
| **Product manager** | the charter (purpose, background, values, scope, non-goals, dated direction changes) and the persona registry | yes — an interview |
| **Product owner** | stories defined from the functional and non-functional side, backlog hygiene, roadmap order | yes — about *what* and *why* only |
| **Architect** | architecture positions, UI and API styleguides | only when a gap appears: a "how" no position covers |

Implementation (`resolve-issue`, the review loop, the Approver) is unchanged and
sits underneath. It consumes the three roles' documents and asks none of them
"how".

Handovers:

1. The product manager's charter and personas are the yardstick for everything
   the product owner does.
2. A story passes a **product stage** (defined: who, why, use case, acceptance
   criteria, non-functional requirements, out of scope) before it may enter a
   **technical stage** (ready to build: surface, dependencies, size and
   splitting, test-case layout, contradictions with the code).
3. The technical stage runs unattended by default. It decides from positions and
   styleguides and records what it decided. It stops only for a gap, and the gap
   goes to the architect, never to the product owner.

## Where it lives

A new plugin named `product` — the first plugin in this marketplace that is not
`development-*`, on purpose: these are different roles, and a team can install
`product` without the development family. `define-personas` moves into it.
`development` then refers to `product` for a missing persona; that dependency is
accepted and documented.

## House rule for documents

Every document a product skill produces has one source — Markdown in the repo,
which the tools read — and is always rendered to **both PDF and ePub** for
people who do not read `.md` files. One shared renderer, one template, one look.
The rendered files are never edited; they are regenerated.

## The seven projects, in order

| # | Project | Delivers | Absorbs / touches |
|---|---|---|---|
| 1 | **Product plugin, charter, renderer** | `product` plugin; `define-personas` moved; `/product:define-charter` producing the `charter/v1` document with its dated direction log; the PDF + ePub renderer | — |
| 2 | **Issue types, idea capture, board** | the four filed types as `type:` labels and issue forms, wired by bootstrap; `/product:capture-idea`; the product's board created by bootstrap, its status derived from issue state | #672 (issue forms + status labels), #1171 (roadmap board) |
| 3 | **Backlog grooming** | `/product:groom-backlog`: every open issue sorted into keep / refine / close-as-done / close-as-superseded / close-as-no-longer-wanted, each close citing a merged PR, a later decision, a charter clause or — for an Enabler — the target architecture; `test-case` issues follow their parent story; long-parked Ideas listed for "analyse or drop"; a rendered grooming report; nothing closed without approval of the report | #673 (batch readiness audit) |
| 4 | **Linked reference documents** | a repo links its target architecture and UI/API styleguides (a pinned submodule of a docs repository the user owns); bootstrap wires the link and the binding lines; the target architecture carries its own dated change log, and a change opens Enabler work in every repo that links it; `resolve-issue` and the technical stage decide from the linked documents at the pinned version and record which clause decided; maintenance moves the pin by PR | #1626 (positions registry), bootstrap, maintenance |
| 5 | **Refinement split** | product stage in `product`, technical stage in `development`; a two-step readiness gate; architect gap routing; promoting an Idea starts the product stage | #2898 (decision rights), `story-readiness`, `refine-issue`, #1266 (personas as reasoning input) |
| 6 | **Roadmap and prioritisation** | one ordered roadmap of Features and Enablers; the architect's must-precede and must-by-date marks; the roadmap rendered as a document from the same data the board shows | #1171 (remaining views) |
| 7 | **Multi-repo delivery** | a product-level conductor that works a cross-repo epic through its member repos — parallel across repos, in sequence within one, ordered by declared dependencies — and runs the epic's end-to-end test at product level | `development-composition`, `resolve-issue`, #719 / #720 (composition deploy-test) |

Order rationale: everything needs 1 (the charter is the yardstick). 2 is small,
useful at once, and gives the groomer the types it sorts by. 3 is the immediate
pain. 4 comes before 5 because the technical stage is what reads the linked
documents. 6 is last because it orders what 3 leaves standing and uses the
stages 5 introduces. 7 needs the board from 2, the per-repo split from 5 and the
ordering from 6; until it lands, cross-repo work runs one repo at a time, as
today.

Between 1 and 3 there is one non-build step: the maintainer runs
`/product:define-charter` on this repo, so this repo's charter exists before the
groomer first runs here.

## No charter, no guessing

Any product skill that needs the charter and finds none offers to define it
then and there — or, in a repo that links a shared docs repository, says to run
`/product:define-charter` there. No product skill proceeds on an assumed
direction.

## Issue types

Four types are filed by people:

| Type | What it is | Judged against | Owner |
|---|---|---|---|
| **Feature** | something a user can see or do | charter and personas | product owner |
| **Enabler** | work no user sees, which keeps or moves the product on its target architecture | target architecture | architect |
| **Bug** | it does not do what was specified | the story it breaks | product owner |
| **Idea** | a thought, not yet analysed | nothing yet | whoever had it |

`epic` remains a container for any type. `test-case` and `review-residue` remain
what the pipeline files itself.

The types are `type:` labels plus issue forms, because that works identically on
personal and organisation accounts. GitHub's native issue types are not used:
this repo's account offers only Task, Bug and Feature, and whether a personal
account can add its own is unverified — project 2's design settles it.

## Ideas

`/product:capture-idea` files an Idea from a sentence or two: no interview, no
readiness gate. An Idea is invisible to the roadmap and to `resolve-issue` until
it is promoted. Promoting starts the product stage and ends in a Feature, an
Enabler, or a drop.

## The technical roadmap

There is one backlog and one roadmap. Technical topics are in it as Enablers.
They differ from Features in where they come from and what judges them: a
Feature exists because of the charter, an Enabler because the target
architecture says so or has changed (a service mesh moving from one data-plane
model to another, say). The target architecture therefore keeps the same kind of
dated change log as the charter, and an entry there is what opens the migration
work. The groomer never weighs an Enabler against the charter.

**Who orders:** the product owner orders everything. The architect can mark an
Enabler *must precede X* or *must be done by a date* (an end of support, for
example), and the product owner cannot override that mark.

## Boards

Bootstrap creates one GitHub Project per product — spanning all its repos for a
multi-repo product — and the product and development skills keep it current.
The rule from #1171 holds throughout: **every status is derived from issue
state; nobody moves a card by hand.**

One status runs across all types, each step arriving with the project that
introduces it: *To analyse* (an Idea) → *Defined* (product stage passed) →
*Ready* (technical stage passed) → *In progress* → *In test* → *Done*.

Views by context: an **Ideas inbox**; the product owner's **backlog** by type
and stage; the architect's **Enablers** with their marks and open gaps; the
developer's **ready / running / stopped for a human**; the stakeholder's
**roadmap** of epics.

Two things are known and one is open. Known: a user-level Project cannot be
written with the default workflow token, so a token with project access is a
prerequisite (#1171); and the board is a view, never a second source of truth.
Open: whether views can be created through the API or need a one-time template
copy — project 2's design settles it.

## Whose architecture decides

The family's own architecture positions are the **default**. A repo that links a
target architecture is declaring its own, and where the linked documents say
something different, they win. Anyone using the plugins sets their own target
architecture this way; the family ships none but its defaults. A "how" that
neither the linked documents nor a default covers is the gap that goes to the
architect.

The linked documents belong to their owner and may be private. Nothing from a
linked repository is ever copied into this public repo — not into docs, tests,
fixtures or examples. Everything here that illustrates the mechanism is
invented.

## One product, one or many repos

A product can be a single repo (this one) or many repos sharing one docs
repository. Charter and personas exist **once per product**: in the repo itself
for a single-repo product, in the shared docs repository for a multi-repo one,
where each implementing repo sees them through its link.

## Working across a product's repos

Frontend and backend live in separate repos, so a product is usually many repos.
Which ones is already declared: the composition repo's `.claude-workspace.yaml`
lists the members. That repo is the product's home for work, as the shared docs
repository is its home for documents:

| Lives in | What |
|---|---|
| the composition repo | product-level issues — cross-repo Features and epics, and Ideas that belong to no single repo; the starting point of the product-level conductor |
| the shared docs repository | documents only — charter, personas, target architecture, styleguides; no issues |
| each member repo | the stories that change that repo |

**From one Feature to per-repo stories.** A cross-repo Feature is filed once, in
the composition repo, as an epic. The technical stage splits it into one child
story per repo it touches, each filed in its own repo, linked to the epic, with
the dependencies between them declared natively ("blocked by"). The split
always puts the API contract change first as its own small story, so the
backend implementation and the frontend can then be built in parallel against
it rather than one after the other.

**How it is worked.** The conductor reads the Ready items from the board and
their dependencies, and runs one `resolve-issue` chain per repo: chains in
different repos in parallel, stories within one repo in sequence, a story
starting only when everything that blocks it has merged. Each chain is its own
session in that repo's checkout, under that repo's rules, gate and Approver —
nothing about building a single repo changes. When all of an epic's children
have merged, the epic gets its end-to-end test at product level and is promoted.

Open, for project 7's design to verify first: that GitHub's native sub-issue
and dependency links hold across repos of one owner.

## How the work is delivered

Each project becomes an epic in this repo, its children refined with
`/development:refine-issue` and built with `/development:resolve-issue` — the
family builds itself. This umbrella becomes the super-epic that links the seven.

## Not in this layer

- Changing how implementation, review or approval work.
- Market research, pricing, analytics — the product manager role here covers
  direction and audience, nothing more.
- Any platform other than macOS + Homebrew for running the skills locally.
