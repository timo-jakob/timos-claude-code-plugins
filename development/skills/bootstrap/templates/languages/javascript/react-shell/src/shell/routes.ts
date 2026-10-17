// The shell's outer route table (#1124): a path prefix maps to one page remote.
// Nested routing belongs to the remote, beneath the basePath the shell delegates,
// so this is a prefix match and needs no router library.

export interface ShellRoute {
  /** The path prefix the remote owns, e.g. "/orders". */
  prefix: string;
  /** The bare specifier /importmap.json resolves to the remote's entry URL. */
  specifier: string;
  /** The navigation link's text. */
  label: string;
}

/** Empty by default: a plain SPA is a shell with zero remotes. */
export const routes: readonly ShellRoute[] = [];

function trimSlash(prefix: string): string {
  return prefix.length > 1 && prefix.endsWith("/") ? prefix.slice(0, -1) : prefix;
}

/**
 * The route whose prefix is the longest match for `pathname` at a path-segment
 * boundary — "/orders" matches "/orders" and "/orders/7", never "/ordersx" — or
 * null when nothing matches.
 */
export function matchRoute(pathname: string, table: readonly ShellRoute[]): ShellRoute | null {
  let best: ShellRoute | null = null;
  let bestLength = -1;
  for (const route of table) {
    const prefix = trimSlash(route.prefix);
    const hit = prefix === "/" || pathname === prefix || pathname.startsWith(`${prefix}/`);
    if (hit && prefix.length > bestLength) {
      best = route;
      bestLength = prefix.length;
    }
  }
  return best;
}
