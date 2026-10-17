// The auth seam (#1124). A stub only: the authorization-code flow with PKCE,
// token storage, silent renewal and sign-out are #1326's, which replaces the
// `auth` capability passed to <Shell capabilities={…}> without touching the
// loader.

import type { AuthClaims, AuthContext } from "@{{NPM_SCOPE}}/mfe-contract";

const NO_CLAIMS: AuthClaims = Object.freeze({ sub: "", displayName: "", tenantId: "" });

export function createAuthContext(): AuthContext {
  return {
    getAccessToken: () => Promise.reject(new Error("no auth provider")),
    claims: NO_CLAIMS,
  };
}
