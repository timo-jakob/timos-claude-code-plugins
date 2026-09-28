/**
 * mfe-contract/v1 — the shell↔remote mount contract.
 *
 * The one boundary a SPA shell and its micro-frontends compile against. A remote
 * is an ES module whose entry satisfies `MfeModule`; the shell resolves it through
 * an import map and calls `mount` / `unmount`. Two remote shapes are admitted —
 * the route-owned **page** and the canvas **widget** — and both are the same
 * `MfeModule`, told apart by `ctx.kind`.
 *
 * Types only: nothing here exists at runtime, so depending on this package is a
 * build-time dependency and never couples one repo to another at runtime.
 *
 * Normative home: the `mfe-contract/v1` section of the family's ARCHITECTURE.md,
 * https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md
 * — that section, not this file's comments, is authoritative where they differ.
 */

/** A widget's extent in integer grid units. Never pixels. */
export interface GridSize {
  cols: number;
  rows: number;
}

/**
 * Tenant theme tokens: CSS custom-property values keyed by property name, so a
 * remote is white-labelled without a rebuild. A capability the host satisfies,
 * not a theming library.
 */
export type ThemeTokens = Readonly<Record<string, string>>;

/**
 * Feature-flag evaluation. A capability the host satisfies, not a vendor SDK —
 * the remote never learns which flag service answers it.
 */
export interface FlagContext {
  isEnabled(key: string): boolean;
  /** The variant assigned to `key`, or `undefined` when the flag has none. */
  variant(key: string): string | undefined;
}

/** The display-only identity claims a remote may render. */
export interface AuthClaims {
  readonly sub: string;
  readonly displayName: string;
  readonly tenantId: string;
}

/**
 * Identity, as a remote is allowed to see it.
 *
 * Follows the family's identity position (ARCHITECTURE.md, "Identity and
 * authorization — OIDC at the edge, claims as the only input", #1186):
 *
 * - The shell owns auth acquisition for the whole page (#1326); a remote never
 *   runs a login flow of its own.
 * - The shell holds the token in memory only, never in `localStorage` or
 *   `sessionStorage`. So there is no token field here: `getAccessToken` is async
 *   so the shell can refresh behind it, and a remote asks for a token at the
 *   point of use rather than holding one it could persist.
 * - Claims are the server's authorization input. No claim here drives a
 *   client-side authorization decision, which is why no role or permission claim
 *   is exposed: the claims are for display only.
 */
export interface AuthContext {
  /** A current access token for calling the remote's own backend. */
  getAccessToken(): Promise<string>;
  /** Display-only claims. Never an authorization input. */
  readonly claims: AuthClaims;
}

/** Given to every micro-frontend, whichever shape it takes. */
export interface MfeContext {
  /** Identity and a token accessor. Never a raw long-lived secret. */
  auth: AuthContext;
  /** Feature-flag evaluation. */
  flags: FlagContext;
  /** Tenant theme tokens. */
  theme: ThemeTokens;
  /**
   * Aborted by the shell when the mount is no longer wanted — the route or slot
   * changed while it was loading. See `MfeModule`'s abort rule for what `mount`
   * must then do and what the shell does afterwards.
   */
  signal: AbortSignal;
}

/** A route-owned page: owns a route subtree end-to-end. */
export interface PageContext extends MfeContext {
  kind: 'page';
  /** Route prefix the shell has delegated; the remote's router mounts here. */
  basePath: string;
  /** Asks the shell to change the outer URL. */
  onNavigate(path: string): void;
}

/** A canvas widget: one instance in a slot on a host-owned canvas. */
export interface WidgetContext extends MfeContext {
  kind: 'widget';
  /**
   * This instance's saved configuration, already validated by the host against
   * `WidgetManifest.configSchema`. Opaque to the host otherwise; the widget
   * narrows it itself.
   */
  config: unknown;
  /** Current size in grid units. */
  size: GridSize;
  /**
   * Subscribes to user resizes, reported in grid units — pixels are the widget's
   * own business (it observes its container). Returns the unsubscribe function.
   * A resize never remounts; a reconfiguration does.
   */
  onResize(cb: (size: GridSize) => void): () => void;
}

/** What a widget declares about itself before it is ever mounted. */
export interface WidgetManifest {
  /** Stable widget type id, unique within a gallery. */
  id: string;
  /** The `mfe-contract` major this widget targets. */
  contractMajor: number;
  /** JSON Schema the host validates a saved instance's `config` against. */
  configSchema: object;
  /** Size constraints in grid units: the user resizes within min..max. */
  size: {
    min: GridSize;
    max: GridSize;
    default: GridSize;
  };
}

/**
 * The shape a remote's entry module must satisfy — one type for both shapes.
 * The module's namespace IS the `MfeModule`: `mount`, `unmount` and, for a
 * widget, `manifest` are named exports, and the shell reads them from the
 * imported module itself — never from a default export.
 *
 * **Abort rule.** The shell ALWAYS calls `unmount(el)` after any `mount` attempt,
 * whether that mount resolved, rejected, or was aborted through `ctx.signal`,
 * and it calls it once that `mount` has settled. Therefore `unmount` must be
 * idempotent and safe on a partial mount, and `mount` must stop its work and
 * settle once it observes the abort. *Rationale:* on fast route or slot
 * changes, a mount that never completed has still attached DOM and
 * subscriptions. A rule that skipped `unmount` for an unsettled mount would leak
 * exactly those, so cleanup belongs to the one call that always runs.
 */
export interface MfeModule {
  /** Renders into `el`. Narrow `ctx` on `ctx.kind` — no cast is needed. */
  mount(el: HTMLElement, ctx: PageContext | WidgetContext): void | Promise<void>;
  /** Tears down whatever `mount` attached, however far it got. Idempotent. */
  unmount(el: HTMLElement): void | Promise<void>;
  /**
   * Widgets only: the widget's manifest, published as a module export.
   *
   * *Rationale:* an export stays in lockstep with the code it describes, so
   * there is no second artifact that can drift from it. The accepted cost is
   * that a gallery loads each widget's entry module to read its manifest. That
   * cost is bounded by a rule on every entry module: evaluating it has no side
   * effect beyond defining its exports, so loading one to read `manifest` never
   * mounts or renders anything.
   */
  manifest?: WidgetManifest;
}
