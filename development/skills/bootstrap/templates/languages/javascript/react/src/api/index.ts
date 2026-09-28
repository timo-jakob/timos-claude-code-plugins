// Public surface of the anti-corruption layer — REACT variant (development-react
// #958). Supersedes the contract-consumer `src/api/index.ts` by composition: it
// keeps that barrel's `./client` seam and adds the React Query binding. App code
// imports from `src/api` (this file) — never from `src/api/generated`.
export * from "./client";
export * from "./hooks";
