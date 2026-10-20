// The shell's one injection point and the PageContext it builds (#1124).

import type { AuthContext, FlagContext, PageContext, ThemeTokens } from "@{{NPM_SCOPE}}/mfe-contract";
import { createAuthContext } from "./auth";

/** Every host capability a remote receives, passed once as <Shell capabilities={…}>. */
export interface ShellCapabilities {
  auth: AuthContext;
  flags: FlagContext;
  theme: ThemeTokens;
}

/** The static defaults: no flag enabled, an empty theme, and the page's auth session (#1326). */
export function defaultCapabilities(): ShellCapabilities {
  return {
    auth: createAuthContext(),
    flags: { isEnabled: () => false, variant: () => undefined },
    theme: Object.freeze({}),
  };
}

/** Every field mfe-contract/v1 requires of a page remote's context. */
export function createPageContext(
  capabilities: ShellCapabilities,
  signal: AbortSignal,
  basePath: string,
  onNavigate: (path: string) => void,
): PageContext {
  return {
    auth: capabilities.auth,
    flags: capabilities.flags,
    theme: capabilities.theme,
    signal,
    kind: "page",
    basePath,
    onNavigate,
  };
}
