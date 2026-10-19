// The page remote's nested router (#1125). The shell delegates a route prefix,
// `basePath`, and this remote owns everything beneath it. Framework-free: the
// router never assumes it is mounted at the origin root, so every path it
// produces carries `basePath`, and a path outside the prefix is handed back to
// the shell through `onNavigate` rather than written to `history` or `location`.

import type { PageContext } from "@{{NPM_SCOPE}}/mfe-contract";

/** A path the remote produces or receives, always absolute from the origin. */
export type OuterPath = string;

export interface RemoteRouter {
  /** The delegated prefix, without a trailing slash (`""` for the origin root). */
  readonly basePath: string;
  /** `pathname` relative to `basePath` (`/orders/7` → `/7`), or `null` outside it. */
  toLocal(pathname: string): string | null;
  /** The outer path of a remote-local path (`/7` → `/orders/7`). */
  toOuter(local: string): OuterPath;
  /** The current remote-local path, `/` when the location is outside `basePath`. */
  current(): string;
  /** Inside `basePath`: `history.pushState`. Outside it: `onNavigate`, and nothing else. */
  navigate(path: OuterPath): void;
  /** Fires on an in-prefix `navigate` and on `popstate`. Returns the unsubscribe. */
  subscribe(cb: (local: string) => void): () => void;
  /** Removes the `popstate` listener and every subscriber. Idempotent. */
  dispose(): void;
}

function normalizeBase(basePath: string): string {
  const trimmed = basePath.replace(/\/+$/, "");
  return trimmed === "" || trimmed.startsWith("/") ? trimmed : `/${trimmed}`;
}

export function createRemoteRouter(basePath: string, onNavigate: PageContext["onNavigate"]): RemoteRouter {
  const base = normalizeBase(basePath);
  const subscribers = new Set<(local: string) => void>();

  const toLocal = (pathname: string): string | null => {
    if (pathname === base || pathname === `${base}/`) return "/";
    if (pathname.startsWith(`${base}/`)) return pathname.slice(base.length);
    return null;
  };
  const toOuter = (local: string): OuterPath => {
    const path = local.startsWith("/") ? local : `/${local}`;
    if (path === "/") return base === "" ? "/" : base;
    return `${base}${path}`;
  };
  const current = (): string => toLocal(window.location.pathname) ?? "/";
  const notify = (local: string): void => {
    for (const cb of [...subscribers]) cb(local);
  };
  const onPopState = (): void => {
    const local = toLocal(window.location.pathname);
    if (local !== null) notify(local);
  };
  window.addEventListener("popstate", onPopState);

  return {
    basePath: base,
    toLocal,
    toOuter,
    current,
    navigate(path) {
      const local = toLocal(path.replace(/[?#].*$/, ""));
      if (local === null) {
        onNavigate(path);
        return;
      }
      window.history.pushState(null, "", path);
      notify(local);
    },
    subscribe(cb) {
      subscribers.add(cb);
      return () => {
        subscribers.delete(cb);
      };
    },
    dispose() {
      window.removeEventListener("popstate", onPopState);
      subscribers.clear();
    },
  };
}
