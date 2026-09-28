// Deliberately NON-conforming remotes. Each `@ts-expect-error` pins a contract
// violation tsc must reject. tsc also fails on an UNUSED `@ts-expect-error`, so
// if the contract ever stopped rejecting one of these, `tsc --noEmit` would go
// red — this file cannot pass vacuously.
import type { MfeModule, WidgetManifest } from '../index.js';

// A remote with no unmount: cleanup would never run.
// @ts-expect-error — `unmount` is required by MfeModule
export const noUnmount: MfeModule = {
  mount() {},
};

export const unnarrowed: MfeModule = {
  mount(_el, ctx) {
    // @ts-expect-error — `size` exists only on WidgetContext; narrow on ctx.kind first
    void ctx.size;
    // @ts-expect-error — `basePath` exists only on PageContext; narrow on ctx.kind first
    void ctx.basePath;
  },
  unmount() {},
};

export const authorizesClientSide: MfeModule = {
  mount(_el, ctx) {
    // @ts-expect-error — no role claim is exposed: claims never drive authorization
    void ctx.auth.claims.roles;
    // @ts-expect-error — no permission claim is exposed either
    void ctx.auth.claims.permissions;
    // @ts-expect-error — no token field: the token is fetched at the point of use
    void ctx.auth.accessToken;
  },
  unmount() {},
};

export const syncToken: MfeModule = {
  mount(_el, ctx) {
    // @ts-expect-error — getAccessToken is async; it returns Promise<string>
    const token: string = ctx.auth.getAccessToken();
    void token;
  },
  unmount() {},
};

// @ts-expect-error — a manifest must declare its size constraints
export const sizelessManifest: WidgetManifest = {
  id: 'orders-summary',
  contractMajor: 1,
  configSchema: {},
};

export const wrongKind: MfeModule = {
  mount(_el, ctx) {
    // @ts-expect-error — 'dialog' is not an admitted remote shape
    if (ctx.kind === 'dialog') return;
  },
  unmount() {},
};
