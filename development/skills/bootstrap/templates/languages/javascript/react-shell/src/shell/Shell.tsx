// The SPA shell (#1124): the chrome, the outer route table and the loader. When no
// route matches it renders its children — the app's own App — so a plain SPA is a
// shell with zero remotes.

import { useEffect, useRef, useState, type ReactNode } from "react";
import { Chrome } from "./Chrome";
import { createPageContext, type ShellCapabilities } from "./context";
import { importRemote as defaultImportRemote, RouteLoader, type ImportRemote } from "./loader";
import { navigate, subscribe } from "./navigation";
import { matchRoute, routes as defaultRoutes, type ShellRoute } from "./routes";

export interface ShellProps {
  /** The one injection point for auth, flags and theme (#1326 replaces auth here). */
  capabilities: ShellCapabilities;
  routes?: readonly ShellRoute[];
  /** How a remote's entry module is loaded; tests pass a fake. */
  importRemote?: ImportRemote;
  children?: ReactNode;
}

export function Shell({
  capabilities,
  routes = defaultRoutes,
  importRemote = defaultImportRemote,
  children,
}: ShellProps) {
  const outletRef = useRef<HTMLDivElement>(null);
  const [showChildren, setShowChildren] = useState(() => matchRoute(window.location.pathname, routes) === null);
  // One loader per outlet for the shell's lifetime, so a re-run effect (StrictMode,
  // new props) queues behind the previous run's teardown instead of racing it.
  const loaderRef = useRef<RouteLoader | null>(null);
  const latest = useRef({ capabilities, importRemote });

  useEffect(() => {
    latest.current = { capabilities, importRemote };
  });

  useEffect(() => {
    const outlet = outletRef.current;
    if (outlet === null) return;
    loaderRef.current ??= new RouteLoader(
      outlet,
      (route, signal) => createPageContext(latest.current.capabilities, signal, route.prefix, navigate),
      (url) => latest.current.importRemote(url),
    );
    const loader = loaderRef.current;
    let active = true;
    const sync = (path: string): void => {
      const route = matchRoute(path, routes);
      if (route !== null) setShowChildren(false);
      void loader.show(route).then(() => {
        if (active && route === null) setShowChildren(true);
      });
    };
    sync(window.location.pathname);
    const unsubscribe = subscribe(sync);
    return () => {
      active = false;
      unsubscribe();
      void loader.show(null);
    };
  }, [routes]);

  return (
    <Chrome routes={routes} outletRef={outletRef}>
      {showChildren ? children : null}
    </Chrome>
  );
}
