# Ferrylane API styleguide

An invented page for the target-architecture validator's tests (#3353): the
repo-local page the fixture's `ref` clause TA-3 points at. The tests copy it to
`docs/architecture/api-styleguide.md` in a throwaway repo.

## Resource naming

Collection paths are plural nouns in kebab-case (`/sailing-slots`), and an
identifier is the next path segment, never a query parameter.
