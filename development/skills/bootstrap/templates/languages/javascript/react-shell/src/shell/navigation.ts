// Outer navigation for the shell (#1124). A remote's own in-prefix pushState is
// not observed here, so navigating inside a remote's subtree never remounts it;
// outward navigation reaches the shell through the context's onNavigate.

type Listener = (path: string) => void;

const listeners = new Set<Listener>();

function notify(): void {
  const path = window.location.pathname;
  for (const listener of [...listeners]) listener(path);
}

/** Push `path` onto the history, then notify every subscriber. */
export function navigate(path: string): void {
  window.history.pushState(null, "", path);
  notify();
}

/** Call `cb` on every navigate and popstate; returns the unsubscribe function. */
export function subscribe(cb: Listener): () => void {
  listeners.add(cb);
  if (listeners.size === 1) window.addEventListener("popstate", notify);
  return () => {
    listeners.delete(cb);
    if (listeners.size === 0) window.removeEventListener("popstate", notify);
  };
}
