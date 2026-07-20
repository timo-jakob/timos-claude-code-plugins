// Public surface of the anti-corruption layer. App code imports from
// `src/api` (this file) — never from `src/api/generated`. Re-export only the
// hand-written seams you want app code to use; the generated client stays an
// implementation detail behind the boundary.
export * from "./client";
