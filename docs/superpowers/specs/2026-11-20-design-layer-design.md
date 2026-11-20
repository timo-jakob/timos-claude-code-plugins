# Design layer — component library support and feature mockups

Date: 2026-11-20. Status: draft for maintainer approval. Two epics that extend
the product layer umbrella
([`2026-11-18-product-layer-umbrella-design.md`](2026-11-18-product-layer-umbrella-design.md))
as its projects 8 and 9. They fill the "design agent" place in the Intent &
Synthesis part of the delivery loop.

Items marked **(my call)** were decided by the author of this document, not by
the maintainer; they are open to correction at review.

## Intent and why

A Feature that has passed the product stage says who it is for, why, the use
case, the acceptance criteria and the non-functional requirements. It does not
say what the user will see. Today the building agent decides that, limited only
by the UI styleguide, and the maintainer first sees the screen when it is built.

The maintainer wants to see **mockups of the result, filled with pseudo test
data, before anything is built** — and those mockups must meet the same criteria
as the real UI: the styleguide's tokens, its checklist and WCAG 2.2 AA.

Two things follow from "the same criteria":

- A mockup must be something the gates can run on, so it is code, not a picture.
- Its parts must be the parts the build will use, so they come from **a defined
  component library**. Without one, an agent invents a table or a button anew
  for every mockup and again for every view.

The family has no notion of a component library today. So this is two epics:
the family learns to support a declared component library (epic A), and then a
product skill composes mockups from it (epic B).

## Goals

1. A repo's linked styleguide can declare the component library its UIs are
   built from, and the family reads what that library offers from a generated
   index, not from its source.
2. A UI repo that declares a library is held to it: gates reject a hand-built
   replacement for a library component, a direct use of the library's internal
   building blocks, and any hard-coded brand value.
3. A view that needs a component the library lacks produces work for the
   library, not a one-off in the app.
4. The family can bootstrap the repo that *is* a component library, so the
   library is built with the normal pipeline.
5. A theme (colours, font, logo) is a file the tools read; mockups and tests
   never call a running theme service.
6. `/product:design-feature` produces, for a Feature with a UI, mockups of each
   affected view in each named state, with pseudo data, checked before a human
   sees them, and approved by a human.
7. A Feature with a UI cannot become ready to build without an approved mockup
   that still matches its files.
8. The build is compared against the approved mockup, and the mockup's pseudo
   data is the mocked data of the built view's default-view test.

## Non-goals

- Shipping a component library, a styleguide or a theme. The family ships the
  mechanism; each owner declares their own. Which base a library is built on
  (headless primitives, a full design system) is its owner's decision, and the
  family never names one.
- Building or calling a white-label service. The family reads theme files.
- Design-tool files (Figma and similar) as a source or a target.
- Pixel comparison between mockup and build.
- Mockups for anything but web UIs built with React. Other UI stacks keep
  today's behaviour.
- Checking each tenant's theme for contrast. That belongs where a theme is
  defined; the family ships the check script and uses it on the reference
  themes only.
- Interaction prototypes. A mockup shows states, it is not clickable beyond
  what the library components do on their own.

## Anti-goals (a failure even if it works)

- A mockup the maintainer approves that the build then cannot or does not
  reproduce.
- A mockup that passes review only in one theme because a colour, a font or a
  logo was written into it.
- An agent that, finding the library lacks a component, quietly builds one in
  the mockup or in the app.
- A human being shown a mockup that fails the styleguide, and having to find
  that out himself.
- Real personal data in pseudo data.
- A second source of truth: an approved picture that no longer matches the
  mockup's files, or a design sheet edited by hand.

## Approaches considered

**What a mockup is.** (a) The view built in the real app repo behind a preview
route; (b) a standalone page stored with the Feature's product documents;
(c) a generated image or a design-tool file. **Chosen: (b)**, by the
maintainer. (a) makes "same criteria" literally true but needs the frontend
checkout and toolchain, cannot run where a cross-repo Feature is filed, and
turns a rejected design into thrown-away product code. (c) cannot be checked
against tokens or WCAG.

**What a mockup is made of.** (a) Hand-written HTML styled from the token file;
(b) a composition of components from a declared library. **Chosen: (b)**, by
the maintainer: components come from a defined library. (a) was the first
proposal and was dropped — nothing would keep two mockups, or a mockup and its
build, from drawing the same control differently.

**What happens with no declared library.** (a) Fall back to hand-written HTML;
(b) stop and say a library must be declared. **Chosen: (b)** (my call), for the
reason (a) was dropped above.

**Where themes come from.** (a) The tools fetch a theme from the running
service; (b) themes are files. **Chosen: (b)** (my call): it works offline,
before a service exists, and in CI without credentials.

**Where the approved mockup lives.** (a) Images attached to the issue; (b) files
in the repo, linked from the issue. **Chosen: (b)** (my call): GitHub offers no
supported way for a tool to attach an image to an issue, and the build has to
read the mockup and its data later.

## Design

### Epic A — component library support

#### A1. Declaring a library

The styleguide a repo links (umbrella project 4, #3198) may carry one small
declaration naming the component library: the package name and the repository
it is developed in. A styleguide without it declares no library, and everything
in this document is then inactive for the repos that link it.

**What the family expects of a styleguide (my call).** The layout #3016–#3019
already assume is taken as fixed: the rules, a checklist whose items are tagged
`design`, `mechanical` or `review`, and a token file. Epic A's first child
writes that layout down as a small contract and adds two optional files to it:
the library declaration and the theme-role list (A6). #3016–#3019 are
prerequisites of epic A, not absorbed by it.

**One product, one styleguide, one library.** The repo a Feature is filed in —
the composition repo for a cross-repo Feature — links the styleguide itself, and
that link is the one `/product:design-feature` reads.

The library package itself ships three things the family reads:

- **the component index** (`component-index/v1`) — one generated file listing
  every public component with: its name and import, one line on what it is for,
  its properties (name, type, required), its named states and variants, the raw
  HTML elements it replaces (a button component replaces `button`), and the
  identifiers of its catalogue entries. It also lists the packages that are the
  library's **internal building blocks**, which apps must not import directly;
- **two reference themes** (A6), each valid against the styleguide's theme-role
  list — the styleguide alone is authoritative for which roles exist, and the
  library's build fails when a reference theme does not match it;
- where its **catalogue** (the static Storybook build) can be found, for people
  to browse; see A8 for a private library.

The index is generated by the library's build from its types and catalogue
entries and is never written by hand. The family ships a validator for the
contract. The contract and the validator are documented in `ARCHITECTURE.md`
like the existing `…/v1` contracts.

The version in force is the UI repo's ordinary dependency pin. Nothing new is
needed to move it: the existing vendor-PR triage already merges safe bumps and
routes majors to a human.

#### A2. Bootstrap for a UI repo

For a repo bootstrap detects as a web UI and whose linked styleguide declares a
library, bootstrap additionally:

- adds the library as a dependency;
- adds the binding lines to `CLAUDE.md`: compose views from library components;
  a missing component is a gap (A5), never a reason to build one locally;
- wires the gates in A3 into pre-commit and CI.

Idempotent, like the rest of bootstrap. Repos with no declared library are
unaffected.

#### A3. Gates

These extend the token lint gate (#3017) and follow its rule: every list is read
from the pinned library and styleguide at check time, never copied into the
consumer.

1. **No raw replaced elements.** A raw HTML element is rejected in app code when
   the index names a component that replaces it.
2. **No internal building blocks.** An import of a package the index lists as
   internal is rejected outside the library.
3. **No brand values.** Colour literals and font-family literals are rejected in
   CSS and in inline styles; colour and font come only from the theme's role
   variables. (Logos cannot be linted; they are a review item.)

**Warn or block (my call).** Like the accessibility gate (#3018), the three
gates have a per-repo switch, `warn | block`. A repo bootstrapped fresh gets
`block`. A repo that already has UI code gets `warn`: violations are annotated
on the PR and counted in the job summary, the build stays green, and the repo
flips to `block` when the count reaches zero. Without this, wiring the gates
into an existing app turns its CI red on the first run.

An app may still build **composites** — a view section made only of library
components. What it may not build is a **primitive**: anything with its own
interaction behaviour, focus handling or ARIA semantics **(my call)**.

#### A4. Review

The React review panel reads the index when a library is declared and reports:
a hand-built component where the index has a matching one; a local primitive
(A3); a logo or brand image referenced other than through the theme. It joins
the styleguide checklist check (#3019) and uses the panel's existing severity
rules.

#### A5. A missing component is a gap

When implementing or mocking a view needs a primitive the index does not have,
the run files an Enabler in the library's repository (named in the
declaration), describing the component, the view that needs it and the states
required, and marks the story or Feature as blocked by it. This is the
umbrella's gap rule: it goes to the architect, never to the product owner, and
an unattended run stops there for that story.

#### A6. Themes as files

The styleguide owns **the list of what a theme may set**, in a theme-role file
beside its token file: colour roles, the font family, shape overrides and logo
slots, plus the role pairs that must contrast (text role on its surface role).
The token file keeps the fixed values no theme may change; the two files do not
overlap.

**Modes.** The role file also lists the display modes a theme must cover (for
example light, dark and high contrast). A theme gives its values once per mode,
and validation and the contrast check run for every mode. A styleguide that
lists a single mode gets today's simple case. Which mode is active at runtime is
the application's business, not the family's. A **theme file** gives a value for each. The
family ships:

- a validator: a theme file sets every required role and nothing unknown;
- a contrast check over the declared pairs, against the WCAG 2.2 AA ratios.

The library ships two reference themes: a neutral one and a deliberately
different one (other hues, another font, another logo shape). Rendering in both
is how a hard-coded brand value shows up. A theme service, where one exists,
serves themes in the same shape and may reuse the same check; that is outside
these epics.

#### A7. Bootstrap for the library repo itself

A new bootstrap flavour, **component library**, for the repo that is the
library. On top of the JavaScript and React setup it adds:

- a Storybook catalogue, with every public component required to have entries
  for its named states;
- an accessibility scan on every catalogue entry, **blocking from the first
  day** (a library cannot be allowed a warn mode its consumers inherit);
- every entry rendered in both reference themes;
- the token gate and the brand-value gate;
- index generation and validation in CI, failing when the committed or
  published index does not match the code;
- publishing of the package, the index and the static catalogue on release.

How a repo declares itself to be a library is left to the builder.

#### A8. A private registry

Decided by the maintainer: his library is published privately on GitHub
Packages. The family stays general — it supports a library on the public npm
registry with no extra setup, and one on GitHub Packages as follows. Other
private registries are not supported until someone needs one.

Whether the library is private, and its scope, is part of the declaration (A1).
When it is:

- **The library repo** (A7) publishes from its release workflow with the
  workflow's own token and the package-write permission; no stored secret.
- **A UI repo** (A2) gets a committed npm configuration that maps the library's
  scope to GitHub Packages and reads the token from the environment — no token
  is ever written to a file in the repo. Its CI is given read access to the
  package. Bootstrap also configures the dependency bot with read access to the
  registry; without that the pin never moves and nothing reports why.
- **A local session** (`/product:design-feature`, a developer's install) reads
  a token from the macOS Keychain, the way the family's token-mint scripts
  already do. A missing or refused token is a clean stop naming the one command
  that fixes it.
- **The catalogue** of a private library is not hosted by the family. The
  static build is attached to each release; where the owner serves it for
  people to browse is his affair. No tool in these epics needs the hosted
  catalogue — they read the index from the installed package.

### Epic B — feature mockups

#### B1. The skill and the agent

`/product:design-feature <issue>` in the `product` plugin, with a
`mockup-designer` agent. The split is the family's usual one: the agent is a
function of one turn that returns drafts and questions and writes nothing; the
skill owns every file and GitHub write. The session is attended, like
`define-charter`.

Preconditions, each a clean stop with the reason when unmet:

- the issue is a Feature that has passed the product stage (umbrella project 5)
  and its definition names a UI;
- the linked styleguide declares a library (no fallback, see Approaches);
- the persona registry exists — pseudo data is written for the Feature's
  personas.

#### B2. What it produces

In the repo where the Feature is filed, in one directory per Feature under the
product documents:

| File | What it is |
|---|---|
| one **mockup source** per view | a React module that composes library components and takes the data as input; it imports nothing but the library and holds no logic beyond showing its states |
| one **data file** | the pseudo data, as named scenarios: `default`, and one per further state |
| **screenshots** | every view × state × variant × width (desktop and 320 px, the reflow width). The variants are the neutral reference theme in every mode, and the second reference theme in the first mode **(my call)** — enough to show each mode and to expose a hard-coded brand value without multiplying the pictures. The checks in B4 still run for both themes in every mode. |
| the **design sheet** | Markdown: the Feature, each view with its screenshots, the decisions taken in the session, the check results; rendered to PDF and ePub by the house renderer (#3204) |
| the **mockup record** (`mockup/v1`) | the issue, the library version and styleguide pin used, the views and states, each check's result, and the approval |

Screenshots and the design sheet are generated, never edited. Drafts are shown
in the browser only; screenshots are written to the repo once, at approval, so
rejected drafts leave no binary history **(my call)**.

**States:** the default view always, plus every state the acceptance criteria
name (empty, error, a permission the persona lacks, and so on).

**Pseudo data rules:** invented, never taken from a real system; plausible for
the persona; and deliberately awkward in at least one place per view — a very
long name, a missing optional value, enough rows to scroll — so the layout is
tested and not merely decorated **(my call)**.

**The library version** is the latest release when the session starts, recorded
in the mockup record; the build story must use that version or a later one
**(my call)**.

#### B3. The session

1. The agent reads the Feature, the personas, the styleguide, its patterns and
   the component index, and proposes **the list of views and states**. The
   human confirms or corrects the list before anything is drawn.
2. The agent drafts sources and data. A needed primitive the index lacks is a
   gap (A5): the session files it, says so, and continues with the other views.
   A Feature with an open gap **cannot be approved**: approval covers the whole
   Feature. The session ends parked — sources, data and a record marked
   `draft` are written, no screenshots — and a later run resumes from them
   once the library has the component **(my call)**.
3. The skill renders and runs the checks (B4). Failures go back to the agent;
   the human is shown only a draft that passes.
4. The skill opens the draft in the browser. The human corrects in words; the
   loop returns to step 2.
5. The human approves. The skill writes the screenshots, the design sheet and
   the record with the approval, and posts one comment on the issue linking the
   design sheet.

Like `define-charter`, the skill does not commit or push; the files land through
the normal PR flow.

#### B4. Checks before a human sees a draft

1. The source imports only the library.
2. The brand-value and token gates of A3, with the same configuration a UI repo
   gets.
3. An accessibility scan of every view × state × theme × width, with zero
   violations required.
4. The styleguide checklist's `design` items, each judged by the agent with a
   one-line reason, recorded in the mockup record.

Rendering and the mechanical checks are one script with bats tests; only the
checklist judgment is agent work. The script renders in a scratch workspace of
its own, into which it installs the library at the recorded version; it never
uses or changes the dependencies of the repo it runs in, which for a
composition repo has none **(my call)**.

#### B5. Approval and what voids it

The approval in the record is bound to a hash of the mockup sources and the data
file. The readiness gate of the technical stage (project 5) requires, for a
Feature whose definition names a UI, a record whose approval hash matches the
files as they are. Any later edit voids the approval and the Feature is no
longer ready. The record also carries a hash of the Feature's product-stage
prose as it was at approval; when that prose changes afterwards the gate
reports it as its own reason and the Feature is likewise not ready.

A change of mind — the Feature's definition changes, or the build finds the
mockup cannot be built as approved — is a question of *what*, so it goes to the
product owner and is settled by running `/product:design-feature` again.

#### B6. In the build

- The technical stage links the mockup directory from every child story that
  builds one of its views.
- `resolve-issue` copies the data file **and the approved default-state
  screenshots** into the building repo's test fixtures, noting the repo and
  commit they came from. The default-view test (#3018) uses the data file as
  its mocked data — mockup and test show the same thing — and its template
  gains one step: it saves a screenshot of the built default view at the same
  widths.
- The React review panel gains a **mockup conformance** check: it reads the two
  images, the built default view and the approved one, and judges them **(my
  call)**. A missing element, a
  different component, a changed order or hierarchy, or different label wording
  is a finding. Differences that only come from real data are not.

### Tests, docs, requirements

- Every script (index validator, theme validator, contrast check, render and
  check, record hash) has bats tests. The contracts are documented in
  `ARCHITECTURE.md`.
- The mockup-designer's quality cannot be pinned by text assertions. It gets a
  reference Feature in a fixture repo and is judged on that with
  `/development-claude-plugin:test`, outside the per-PR suite.
- Docs: a how-to for adopting a component library, a how-to for designing a
  Feature, reference pages for the three contracts, and an explanation page on
  the design step — filed under Intent & Synthesis in the manual's planned
  grouping by delivery-loop phase.
- The `product` plugin's requirements grow by Node, a headless browser and the
  accessibility scanner; a missing tool is reported with its install line, as
  the renderer does.

## Constraints

- macOS + Homebrew only, by design.
- Everything in this repo that illustrates the mechanism is invented. Nothing
  from a linked styleguide, a real component library or a real theme is copied
  into docs, tests, fixtures or examples.
- The family names no component technology. Every list a gate enforces comes
  from the declared library's index or the styleguide.
- Repos with no declared library, and UI repos that are not React, behave
  exactly as today.
- zsh for new scripts; anything checkable is a script with bats tests, not
  prose in a skill.

## Delivery

Two epics under the product super-epic (#3194).

**Epic A — component library support.** Depends on #3198 (the linked
styleguide). Extends #3017 and #3019. Children, in order:

1. The declaration, the `component-index/v1` contract and its validator.
2. Theme roles, theme files, the theme validator and the contrast check.
3. The three gates, generated from the index.
4. Bootstrap for a UI repo that declares a library, including registry access
   for CI and the dependency bot (A8).
5. The review check and gap filing.
6. The component-library bootstrap flavour, including publishing (A8).
7. How-to and reference pages.

**Epic B — feature mockups.** Depends on epic A, on umbrella project 5 (the
product stage and the two-step readiness gate) and on #3204 (the renderer).
Children, in order:

1. The `mockup/v1` record, its hash, and the render-and-check script.
2. `/product:design-feature` and the `mockup-designer` agent.
3. The readiness gate requires an approved, matching mockup.
4. The build side: fixture hand-over and the mockup conformance check.
5. The reference Feature and its behaviour test.
6. How-to, reference and explanation pages.

Epic A's children 1–3 and 6 need no product stage and can start as soon as
#3198 has landed.

## Left to the builder

- File names and locations inside the mockup directory and inside the library
  package; the exact fields of the three contracts beyond those named here.
- How a mockup page is bundled and served for rendering (a page-level catalogue
  entry or a plain bundler entry).
- Whether the review checks are new agents or additions to existing ones.
- How a repo declares itself a component library to bootstrap.
- Desktop screenshot width; the scanner's rule tags (the ones #3018 uses are
  the assumed set).
- Child-story boundaries, if the size check asks for a further split.

## To verify first (the design assumes these)

- A component index with properties, states and replaced elements can be
  generated dependably from a React library's types and catalogue entries.
- A lint rule can read its element and package lists from the installed library
  at check time, as the token gate reads the token file.
- A bundled mockup page renders, is scanned and is captured by a headless
  browser on a Mac with nothing but the Homebrew toolchain, offline once the
  library is in the package cache.
- The product stage (project 5) records whether a Feature has a UI in a form a
  gate can read.
- For GitHub Packages: which identity a consuming repo's CI reads a private
  package with (the workflow's own token after the package grants that repo
  access, or a token minted from one of the family's Apps), whether an App
  installation token can read packages at all, and the same for the dependency
  bot. The design assumes at least one of these works without a personal
  token stored as a repo secret.
- An issue can be filed in, and a "blocked by" link set to, another repository
  of the same owner by the family's bot identity — the same open point as
  umbrella project 7.
