// orval input transformer — carries the contract's deprecation signal through to
// the consumer's editor and CI (development-javascript #707). It runs before
// generation (wired as `input.override.transformer` in orval.config.ts).
//
// For every operation the spec marks `deprecated: true`, it prepends a
// deprecation notice — including the `x-sunset` date from the #695 producer
// convention when present — to the operation's `description`. orval renders that
// description into the generated client method's JSDoc, next to the `@deprecated`
// tag it already emits for deprecated operations. So:
//   - `@typescript-eslint/no-deprecated` warns at EVERY call site of a dying
//     operation the moment a Renovate spec-package bump lands (migration pressure
//     with zero coordination), and
//   - the sunset date rides in the generated method's `@deprecated` JSDoc, where
//     it shows on editor hover and in the committed generated diff.
// (orval emits a BARE `@deprecated` tag from the boolean, so the date lands in
// the surrounding JSDoc description, not inside the tag text — i.e. it is visible
// on hover / in the source, not necessarily in the bare ESLint message string.)
//
// Fully generator-driven: no hand-written `@deprecated` anywhere. Editing the
// spec's `deprecated`/`x-sunset` is the only input; regeneration does the rest.
//
// Assumes path items are INLINE operations (not `$ref` path-item references) at
// transform time — orval bundles/derefs the input before generation, so this
// holds in the normal flow.

const HTTP_METHODS = new Set([
  "get",
  "put",
  "post",
  "delete",
  "options",
  "head",
  "patch",
  "trace",
]);

/**
 * @param {object} spec  the parsed OpenAPI document (mutated in place)
 * @returns {object}     the same document, with deprecated operations annotated
 */
export default (spec) => {
  for (const pathItem of Object.values(spec?.paths ?? {})) {
    if (!pathItem || typeof pathItem !== "object") continue;
    for (const [method, op] of Object.entries(pathItem)) {
      if (!HTTP_METHODS.has(method)) continue;
      if (!op || op.deprecated !== true) continue;
      const sunset = op["x-sunset"];
      const notice = sunset
        ? `Deprecated; scheduled for removal after ${sunset}.`
        : "Deprecated.";
      // Lead with the notice so it heads the generated JSDoc; keep any existing
      // description. Idempotent: gate on the exact prepended forms THIS transformer
      // produces — the sunset marker, the bare "Deprecated. " prefix, or the
      // description being exactly "Deprecated." — so re-running never
      // double-prefixes. A human-authored description like "Deprecated endpoint;
      // use /v2." matches none of these (no period-space, not the sunset marker),
      // so it still correctly receives the notice rather than being mistaken for
      // an already-annotated one.
      // Known narrow edge: a hand-authored description that itself begins
      // "Deprecated. " on a sunset op looks already-annotated, so its date isn't
      // prepended. Closing it fully needs a sentinel marker that would pollute the
      // generated JSDoc; the shape-match is the deliberate trade-off (far narrower
      // than the bare-"Deprecated" collision it replaced).
      const SUNSET_MARKER = "Deprecated; scheduled for removal after";
      const BARE_PREFIX = "Deprecated. ";
      const already =
        op.description === "Deprecated." ||
        op.description?.startsWith(SUNSET_MARKER) ||
        op.description?.startsWith(BARE_PREFIX);
      if (!already) {
        op.description = op.description ? `${notice} ${op.description}` : notice;
      }
    }
  }
  return spec;
};
