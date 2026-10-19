/* eslint-disable react-refresh/only-export-components -- this module's exports are
   the mfe-contract MfeModule (mount/unmount, manifest), not components, so fast refresh does not apply. */
// The page remote's entry module (#1125): its namespace is the remote's MfeModule
// (mfe-contract/v1). The shell imports it through the import map, then calls
// `mount` with a page context and, after any mount attempt, `unmount`. A page
// remote bundles its own React: the shell mounts one page remote at a time.

import { StrictMode, useSyncExternalStore, type MouseEvent } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { MfeModule, PageContext } from "@{{NPM_SCOPE}}/mfe-contract";
import { createRemoteRouter, type RemoteRouter } from "./router";

interface Mounted {
  router: RemoteRouter;
  root: Root | null;
}

const mounted = new WeakMap<HTMLElement, Mounted>();

function RemotePage({ ctx, router }: { ctx: PageContext; router: RemoteRouter }) {
  const local = useSyncExternalStore(router.subscribe, router.current);
  const follow = (event: MouseEvent<HTMLAnchorElement>) => {
    // Only a plain primary click is in-app; the browser keeps new-tab and new-window clicks.
    const modified = event.metaKey || event.ctrlKey || event.shiftKey || event.altKey;
    if (event.button !== 0 || modified || event.defaultPrevented) return;
    event.preventDefault();
    const { pathname, search, hash } = event.currentTarget;
    router.navigate(`${pathname}${search}${hash}`);
  };
  return (
    <main data-local-path={local}>
      <p>Hello, {ctx.auth.claims.displayName}</p>
      <nav>
        <a href={router.toOuter("/")} onClick={follow}>
          Home
        </a>
      </nav>
    </main>
  );
}

export const mount: MfeModule["mount"] = async (el, ctx) => {
  if (ctx.kind !== "page") throw new Error(`this remote is a page; it cannot mount as a ${ctx.kind}`);
  // Stop once the shell aborts: it unmounts after every attempt, so nothing is left behind.
  if (ctx.signal.aborted) return;
  const router = createRemoteRouter(ctx.basePath, (path) => ctx.onNavigate(path));
  // Register before rendering, so unmount finds and removes the router on a partial mount.
  const state: Mounted = { router, root: null };
  mounted.set(el, state);
  state.root = createRoot(el);
  state.root.render(
    <StrictMode>
      <RemotePage ctx={ctx} router={router} />
    </StrictMode>,
  );
};

export const unmount: MfeModule["unmount"] = (el) => {
  // Idempotent and safe on a partial mount: a second call finds nothing.
  const state = mounted.get(el);
  mounted.delete(el);
  state?.root?.unmount();
  state?.router.dispose();
};
