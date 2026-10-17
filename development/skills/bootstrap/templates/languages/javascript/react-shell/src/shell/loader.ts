// The shell side of mfe-contract/v1's abort rule (#1124). For each route the
// shell enters:
//   (a) enter — a fresh AbortController's signal goes into the PageContext, the
//       specifier is resolved through /importmap.json and the module imported;
//   (b) leave before the import settles — abort; mount is never called, so
//       there is no unmount;
//   (c) leave after mount was called — abort, wait for mount to settle, then
//       unmount(outlet) exactly once; a mount that rejects on its own is
//       followed at once by exactly one unmount and a fallback message;
//   (d) serialise — the next route's attempt starts only after the previous
//       one has finished, so a stale remote is never mounted.
// An import that fails makes no mount attempt: the fallback shows, no unmount.

import type { MfeModule, PageContext } from "@{{NPM_SCOPE}}/mfe-contract";
import { resolveSpecifier } from "./import-map";
import type { ShellRoute } from "./routes";

/** Loads a remote's entry module; its namespace is its MfeModule — named exports, never a default. */
export type ImportRemote = (url: string) => Promise<MfeModule>;

export const importRemote: ImportRemote = (url) => import(/* @vite-ignore */ url);

export const FALLBACK_MESSAGE = "This part of the page could not be loaded.";

export interface Attempt {
  /** Settles once the import and any mount attempt have settled. */
  readonly settled: Promise<void>;
  /** Leave the route: abort, wait for the attempt, and unmount once if mount was called. */
  leave(): Promise<void>;
}

function showFallback(outlet: HTMLElement): void {
  const message = document.createElement("p");
  message.setAttribute("role", "alert");
  message.textContent = FALLBACK_MESSAGE;
  outlet.replaceChildren(message);
}

export function enterRoute(
  outlet: HTMLElement,
  specifier: string,
  buildContext: (signal: AbortSignal) => PageContext,
  load: ImportRemote = importRemote,
): Attempt {
  const controller = new AbortController();
  const ctx = buildContext(controller.signal);
  let remote: MfeModule | undefined;
  let mountCalled = false;
  let unmounted: Promise<void> | undefined;

  // At most once, and the outlet is left empty whatever unmount did.
  const unmountOnce = (): Promise<void> => {
    unmounted ??= Promise.resolve()
      .then(() => remote?.unmount(outlet))
      .catch(() => undefined)
      .then(() => outlet.replaceChildren());
    return unmounted;
  };

  const settled = (async (): Promise<void> => {
    let loaded: MfeModule;
    try {
      loaded = await load(await resolveSpecifier(specifier));
    } catch {
      if (!controller.signal.aborted) showFallback(outlet);
      return;
    }
    if (controller.signal.aborted) return; // (b)
    remote = loaded;
    mountCalled = true;
    try {
      await loaded.mount(outlet, ctx);
    } catch {
      if (controller.signal.aborted) return; // (c): leave() unmounts
      await unmountOnce();
      showFallback(outlet);
    }
  })();

  return {
    settled,
    async leave(): Promise<void> {
      controller.abort();
      await settled;
      if (mountCalled) await unmountOnce();
      outlet.replaceChildren();
    },
  };
}

/** Drives one outlet: a route change tears the current attempt down before the next enters. */
export class RouteLoader {
  private readonly outlet: HTMLElement;
  private readonly buildContext: (route: ShellRoute, signal: AbortSignal) => PageContext;
  private readonly load: ImportRemote;
  private current: Attempt | null = null;
  private currentPrefix: string | null = null;
  private queue: Promise<void> = Promise.resolve();

  constructor(
    outlet: HTMLElement,
    buildContext: (route: ShellRoute, signal: AbortSignal) => PageContext,
    load: ImportRemote = importRemote,
  ) {
    this.outlet = outlet;
    this.buildContext = buildContext;
    this.load = load;
  }

  /** Show `route` (null: no remote). The same prefix remounts nothing; resolves once done. */
  show(route: ShellRoute | null): Promise<void> {
    const prefix = route === null ? null : route.prefix;
    if (prefix === this.currentPrefix) return this.queue;
    this.currentPrefix = prefix;
    this.queue = this.queue.then(async () => {
      if (this.current !== null) await this.current.leave();
      this.current =
        route === null
          ? null
          : enterRoute(this.outlet, route.specifier, (signal) => this.buildContext(route, signal), this.load);
    });
    return this.queue;
  }
}
