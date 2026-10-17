// The application chrome (#1124): a minimal landmark layout around the outlet.

import type { MouseEvent, ReactNode, Ref } from "react";
import { navigate } from "./navigation";
import type { ShellRoute } from "./routes";

export interface ChromeProps {
  routes: readonly ShellRoute[];
  outletRef: Ref<HTMLDivElement>;
  children?: ReactNode;
}

// A plain left click navigates in place; a modifier or middle click keeps the
// browser's default (a new tab, a download).
function followLink(event: MouseEvent<HTMLAnchorElement>, path: string): void {
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  event.preventDefault();
  navigate(path);
}

export function Chrome({ routes, outletRef, children }: ChromeProps) {
  return (
    <>
      <header>
        <nav aria-label="Main">
          {routes.map((route) => (
            <a key={route.prefix} href={route.prefix} onClick={(event) => followLink(event, route.prefix)}>
              {route.label}
            </a>
          ))}
        </nav>
      </header>
      <main>
        <div ref={outletRef} data-shell-outlet="" />
        {children}
      </main>
    </>
  );
}
