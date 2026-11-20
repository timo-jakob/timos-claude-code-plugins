// house.typ — the one Typst template every product document is rendered with
// (#3204). A pandoc template: pandoc fills the template variables, Typst builds
// the PDF. There are no options: A4, Typst's own built-in fonts (the render
// passes --ignore-system-fonts, so macOS and CI produce the same pages).
//
// Variables render-document.zsh sets: title, repo, date, version, stamp, and
// draft (present only when the source has uncommitted changes).

#let ink = rgb("#1f2a37")
#let accent = rgb("#1d4e89")
#let muted = rgb("#5b6675")

#set document(title: [$title$])
#set page(
  paper: "a4",
  margin: (x: 25mm, top: 25mm, bottom: 28mm),
  footer: context [
    #set text(size: 8pt, fill: muted)
    $repo$ · $stamp$ #h(1fr) #counter(page).display("1 / 1", both: true)
  ],
)
#set text(font: "Libertinus Serif", size: 10.5pt, fill: ink, lang: "en")
#set par(justify: true, leading: 0.7em, spacing: 1.1em)
#show raw: set text(font: "DejaVu Sans Mono", size: 0.85em)
#show link: set text(fill: accent)
#set heading(numbering: none)
#show heading: set text(fill: accent, hyphenate: false)
#show heading.where(level: 1): it => block(above: 1.6em, below: 1em, text(size: 1.6em, it))
#show heading.where(level: 2): it => block(above: 1.4em, below: 0.8em, text(size: 1.25em, it))
#set table(inset: 6pt, stroke: (x, y) => if y == 0 { (bottom: 0.6pt + muted) } else { none })
#show quote.where(block: true): it => block(
  inset: (left: 1em, y: 0.3em),
  stroke: (left: 2pt + muted.lighten(50%)),
  it.body,
)

#let horizontalrule = line(length: 100%, stroke: 0.5pt + muted)
#let horizontalRule = horizontalrule
#let divider = if "divider" in std { divider } else { horizontalrule }

// A GitHub alert (`> [!IMPORTANT]` …) in the source becomes one of these.
#let callout(kind, title, body) = {
  let colors = (
    note: rgb("#1d4e89"),
    tip: rgb("#2f6f3e"),
    important: rgb("#6b3fa0"),
    warning: rgb("#9a6700"),
    caution: rgb("#b42318"),
  )
  let c = colors.at(kind, default: accent)
  block(
    width: 100%,
    inset: (x: 1em, y: 0.8em),
    radius: 3pt,
    fill: c.lighten(92%),
    stroke: (left: 3pt + c),
    breakable: true,
  )[
    #text(weight: "bold", fill: c, size: 0.85em, upper(title))
    #body
  ]
}

$if(highlighting-definitions)$
$highlighting-definitions$
$endif$

#set smartquote(enabled: false)

// The cover.
#page(footer: context [
  #set text(size: 8pt, fill: muted)
  $repo$ · $stamp$
])[
  #v(30%)
  #text(size: 11pt, fill: muted, upper[$repo$])
  #v(0.6em)
  #block(text(size: 26pt, weight: "bold", fill: accent, hyphenate: false)[$title$])
  #v(1.2em)
  #line(length: 40%, stroke: 1pt + accent)
  #v(1.2em)
  #text(size: 11pt)[$date$] \
  #text(size: 11pt, fill: muted)[Version $version$]
$if(draft)$
  #v(2em)
  #block(
    inset: (x: 1em, y: 0.5em),
    stroke: 1.5pt + rgb("#b42318"),
    text(size: 18pt, weight: "bold", fill: rgb("#b42318"), tracking: 0.2em)[DRAFT],
  )
  #text(size: 9pt, fill: muted)[The source has uncommitted changes.]
$endif$
]

#outline(title: [Contents], depth: 2)
#pagebreak(weak: true)

$body$
