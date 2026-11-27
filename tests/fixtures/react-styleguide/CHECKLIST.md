# Checklist

Yes/no criteria for a platform UI. Each item carries one tag:

- `design` — checked on the mockup or design spec, **before** anything is built.
- `mechanical` — checked by a tool in CI.
- `review` — checked by a reviewer (a person or the review panel) on the change.

Items link to the rule in [STYLEGUIDE.md](STYLEGUIDE.md) they come from.

## Design

- [ ] [design] The view's default state is named in the spec and shows content without any interaction. ([rule](STYLEGUIDE.md#defaults-and-clicks))
- [ ] [design] Clicks to the view's main answer are counted in the spec; the target is zero. ([rule](STYLEGUIDE.md#defaults-and-clicks))
- [ ] [design] The layout follows a pattern in `patterns/` or the spec says why not. ([rule](STYLEGUIDE.md#spacing-and-alignment))
- [ ] [design] Text contrast is at least 4.5:1 (1.4.3). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] Large text, UI components and focus indicators have at least 3:1 contrast (1.4.11). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] Colour is never the only signal; severity and status carry a label or symbol (1.4.1). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] Every target is at least 24×24 px or has enough spacing around it (2.5.8). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] Focus is visible and never hidden by sticky or overlay content (2.4.7, 2.4.11). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] The keyboard path through the default view and every action is defined, in a logical order (2.1.1, 2.4.3). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] The layout reflows at 320 px width and text resizes to 200 % without loss (1.4.10, 1.4.4). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] Every control has a label or accessible name; headings describe the structure (1.3.1, 2.4.6, 4.1.2). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] No interaction is drag-only (2.5.7). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] Users never re-enter data they already gave in the same flow (3.3.7). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [design] Help, if offered, is in the same place on every view (3.2.6). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))

## Mechanical

- [ ] [mechanical] Margins, paddings and gaps use only `0` or `--platform-space-*` / `--platform-widget-gap` tokens, in stylesheets and inline styles. ([rule](STYLEGUIDE.md#spacing-and-alignment))
- [ ] [mechanical] Corner radius, font size, line height and font weight use only `--platform-*` tokens. ([rule](STYLEGUIDE.md#deviations-from-material-3))
- [ ] [mechanical] Every `--platform-*` token referenced exists in the pinned `styleguide/tokens/tokens.json` or the theme. ([rule](STYLEGUIDE.md#spacing-and-alignment))
- [ ] [mechanical] The automated WCAG 2.2 A + AA scan (axe) reports no violations on the default view. ([rule](STYLEGUIDE.md#base-and-precedence))
- [ ] [mechanical] A test loads each view with data and asserts content is visible without any interaction. ([rule](STYLEGUIDE.md#defaults-and-clicks))

## Review

- [ ] [review] Edges of stacked regions line up; controls in a row share a baseline and a height. ([rule](STYLEGUIDE.md#spacing-and-alignment))
- [ ] [review] The widget adds no outer padding; the shell's card owns it. ([rule](STYLEGUIDE.md#spacing-and-alignment))
- [ ] [review] There is at most one primary action per view. ([rule](STYLEGUIDE.md#buttons-and-actions))
- [ ] [review] Button labels are a verb (plus noun), in sentence case. ([rule](STYLEGUIDE.md#buttons-and-actions))
- [ ] [review] Texts are in sentence case; empty states say what is empty and why. ([rule](STYLEGUIDE.md#writing))
- [ ] [review] Returning to the default view takes one click; detail opens in place with a visible way back. ([rule](STYLEGUIDE.md#defaults-and-clicks))
- [ ] [review] The keyboard path works as designed and focus order is logical (2.1.1, 2.4.3). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [review] At 320 px width and 200 % text the view keeps all content and function (1.4.10, 1.4.4). ([rule](STYLEGUIDE.md#accessibility-in-the-design-step))
- [ ] [review] Every component follows Material 3 anatomy and usage, or the deviation is listed in STYLEGUIDE.md. ([rule](STYLEGUIDE.md#deviations-from-material-3))
- [ ] [review] Any WCAG 2.2 AA violation is a finding, even while the CI accessibility gate only warns. ([rule](STYLEGUIDE.md#base-and-precedence))
