// The shell's auth module (#1326): the page's only token acquirer. A public
// client — the authorization-code flow with PKCE and no client secret — whose
// tokens live in JavaScript memory only. A reload therefore re-acquires through a
// top-level redirect that the provider's session answers, rather than restoring
// a token. In-page renewal rotates the refresh token, which stays in memory too,
// and nothing here runs a hidden-iframe renew. The PKCE code_verifier and state
// are not tokens: they sit in sessionStorage for the round-trip only, and the
// callback removes them. A remote receives `context` — a token accessor and
// display-only claims, never an authorization input — through
// ShellCapabilities.auth, and never calls the provider itself.

import type { AuthClaims, AuthContext } from "@{{NPM_SCOPE}}/mfe-contract";
import { InMemoryWebStorage, UserManager, WebStorageStateStore, type INavigator, type User } from "oidc-client-ts";

/** The provider settings each environment serves as /auth-config.json (#1128). It carries no secret. */
export interface AuthConfig {
  issuer: string;
  clientId: string;
  redirectPath: string;
  scope: string;
}

/** The shell's side of the session; a remote only ever sees `context`. */
export interface ShellAuth {
  readonly context: AuthContext;
  /** Joins the page's sign-in: completes a callback, or redirects the top-level page to the provider. */
  signIn(): Promise<void>;
  /** Discards the in-memory tokens, then sends the top-level page to the provider's end-session endpoint. */
  signOut(): Promise<void>;
}

export interface ShellAuthOptions {
  loadConfig?: () => Promise<AuthConfig>;
  /** How the top-level page is sent to the provider; tests pass a fake. */
  redirectNavigator?: INavigator;
}

const NO_CLAIMS: AuthClaims = Object.freeze({ sub: "", displayName: "", tenantId: "" });

// Renew this many seconds before the access token expires.
const RENEW_MARGIN_S = 30;

const CONFIG_FIELDS = ["issuer", "clientId", "redirectPath", "scope"] as const;

async function fetchAuthConfig(): Promise<AuthConfig> {
  const response = await fetch("/auth-config.json");
  if (!response.ok) throw new Error(`/auth-config.json: HTTP ${response.status}`);
  const body: unknown = await response.json();
  const fields = (body ?? {}) as Partial<Record<keyof AuthConfig, unknown>>;
  const config: Partial<AuthConfig> = {};
  for (const key of CONFIG_FIELDS) {
    const value = fields[key];
    if (typeof value !== "string" || value === "") throw new Error(`/auth-config.json: ${key} is not set`);
    config[key] = value;
  }
  return config as AuthConfig;
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

// Keycloak's `organization` claim in the shapes the services accept — a string, an array
// or an object: one tenant, else none. The shell reads only that default claim name.
function tenantOf(organization: unknown): string {
  if (Array.isArray(organization)) return organization.length === 1 ? text(organization[0]) : "";
  if (typeof organization === "object" && organization !== null) {
    const keys = Object.keys(organization);
    return keys.length === 1 ? keys[0] : "";
  }
  return text(organization);
}

function claimsOf(user: User): AuthClaims {
  const profile = user.profile;
  return Object.freeze({
    sub: profile.sub,
    displayName: text(profile.name) || text(profile.preferred_username),
    tenantId: tenantOf(profile.organization),
  });
}

// The page to return to after sign-in: a same-origin path, never an absolute URL.
function returnPath(state: unknown): string {
  return typeof state === "string" && state.startsWith("/") && !state.startsWith("//") ? state : "/";
}

export function createShellAuth(options: ShellAuthOptions = {}): ShellAuth {
  const loadConfig = options.loadConfig ?? fetchAuthConfig;
  let manager: Promise<{ config: AuthConfig; users: UserManager }> | undefined;
  let session: Promise<void> | undefined;
  let renewal: Promise<void> | undefined;
  let user: User | null = null;
  let claims = NO_CLAIMS;
  let signedOut = false;

  // Fetched once per page load; a failed fetch is not cached, so the next call fetches again.
  const getManager = () => {
    manager ??= loadConfig().then(
      (config) => {
        const users = new UserManager(
          {
            authority: config.issuer,
            client_id: config.clientId,
            redirect_uri: `${window.location.origin}${config.redirectPath}`,
            post_logout_redirect_uri: `${window.location.origin}/`,
            scope: config.scope,
            response_type: "code",
            redirectTarget: "top",
            userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
            stateStore: new WebStorageStateStore({ store: window.sessionStorage }),
            automaticSilentRenew: false,
            monitorSession: false,
          },
          options.redirectNavigator,
        );
        return { config, users };
      },
      (error: unknown) => {
        manager = undefined;
        throw error;
      },
    );
    return manager;
  };

  const hold = (next: User): void => {
    user = next;
    claims = claimsOf(next);
  };

  const start = async (): Promise<void> => {
    const { config, users } = await getManager();
    if (window.location.pathname === config.redirectPath) {
      // Leave the callback URL before handling it, so a failed callback is never re-run against
      // its consumed state; popstate tells the shell's router (navigation.ts) to re-match.
      const callback = window.location.href;
      window.history.replaceState(null, "", "/");
      const signedIn = await users.signinRedirectCallback(callback);
      hold(signedIn);
      window.history.replaceState(null, "", returnPath(signedIn.state));
      window.dispatchEvent(new PopStateEvent("popstate"));
      return;
    }
    const { pathname, search, hash } = window.location;
    // The page navigates away here, so this never settles in a browser.
    await users.signinRedirect({ state: `${pathname}${search}${hash}` });
  };

  const signIn = (): Promise<void> => {
    session ??= start().catch((error: unknown) => {
      session = undefined;
      throw error;
    });
    return session;
  };

  // Rotates the refresh token. Without one, or when the provider refuses it, the top-level
  // redirect re-acquires instead.
  const renew = async (current: User): Promise<void> => {
    const { users } = await getManager();
    const renewed = current.refresh_token === undefined ? null : await users.signinSilent().catch(() => null);
    if (signedOut) return;
    if (renewed === null) {
      session = undefined;
      await signIn();
      return;
    }
    hold(renewed);
  };

  const getAccessToken = async (): Promise<string> => {
    if (signedOut) throw new Error("signed out");
    if (user === null) await signIn();
    let current = user;
    const left = current?.expires_in;
    if (current !== null && left !== undefined && left <= RENEW_MARGIN_S) {
      renewal ??= renew(current).finally(() => {
        renewal = undefined;
      });
      await renewal;
      current = user;
    }
    if (signedOut || current === null) throw new Error("signed out");
    return current.access_token;
  };

  const context: AuthContext = Object.freeze({
    getAccessToken,
    get claims(): AuthClaims {
      return claims;
    },
  });

  const signOut = async (): Promise<void> => {
    signedOut = true;
    const idToken = user?.id_token;
    user = null;
    claims = NO_CLAIMS;
    const { users } = await getManager();
    await users.removeUser();
    await users.signoutRedirect({ id_token_hint: idToken });
  };

  return { context, signIn, signOut };
}

let page: ShellAuth | undefined;

/** The page's one session, created on first use; creating it does no I/O. */
function pageAuth(): ShellAuth {
  page ??= createShellAuth();
  return page;
}

/** What ShellCapabilities.auth carries: the page session's AuthContext. */
export function createAuthContext(): AuthContext {
  return pageAuth().context;
}

/** Starts the page's sign-in; src/main.tsx calls it once at page load. */
export function signIn(): Promise<void> {
  return pageAuth().signIn();
}

/** Page-wide sign-out: every AuthContext handed to a remote rejects from here on. */
export function signOut(): Promise<void> {
  return pageAuth().signOut();
}
