// The shell's auth module (#1326), driven against a fake provider: fetch serves
// /auth-config.json, the discovery document and the token endpoint, and a fake
// navigator records where the top-level page would be sent. Executed by the
// render-and-build smoke check (#1063); tests/react-shell-templates.bats pins
// each case title.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { INavigator } from "oidc-client-ts";
import { createAuthContext, createShellAuth, type AuthConfig } from "./auth";
import { createPageContext, defaultCapabilities } from "./context";

const ISSUER = "https://id.example.test/realms/acme";
const CONFIG: AuthConfig = {
  issuer: ISSUER,
  clientId: "acme-shell",
  redirectPath: "/auth/callback",
  scope: "openid profile organization",
};
const METADATA = {
  issuer: ISSUER,
  authorization_endpoint: `${ISSUER}/protocol/openid-connect/auth`,
  token_endpoint: `${ISSUER}/protocol/openid-connect/token`,
  end_session_endpoint: `${ISSUER}/protocol/openid-connect/logout`,
  jwks_uri: `${ISSUER}/protocol/openid-connect/certs`,
};

function base64url(value: object): string {
  return btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// An unsigned ID token: the client reads its claims for display only.
function idToken(nonce: string | null): string {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: ISSUER,
    aud: CONFIG.clientId,
    sub: "6f1c2a9e-priya",
    iat: now,
    exp: now + 300,
    name: "Priya Raman",
    organization: ["acme"],
    ...(nonce === null ? {} : { nonce }),
  };
  return `${base64url({ alg: "RS256", typ: "JWT" })}.${base64url(claims)}.sig`;
}

interface Provider {
  configFetches: number;
  tokenRequests: URLSearchParams[];
  navigations: string[];
  navigator: INavigator;
  /** Seconds each issued access token lives; below the renew margin forces a renewal. */
  expiresIn: number;
}

let provider: Provider;

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), { headers: { "Content-Type": "application/json" } });
}

function fakeProvider(): Provider {
  let issued = 0;
  const state: Provider = {
    configFetches: 0,
    tokenRequests: [],
    navigations: [],
    expiresIn: 300,
    navigator: {
      prepare: async () => ({
        // The page navigates away, so a real redirect never settles.
        navigate: async ({ url }) => {
          state.navigations.push(url);
          return new Promise(() => undefined);
        },
        close: () => undefined,
      }),
      callback: async () => undefined,
    },
  };
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input instanceof Request ? input.url : input);
      if (url === "/auth-config.json") {
        state.configFetches += 1;
        return json(CONFIG);
      }
      if (url === `${ISSUER}/.well-known/openid-configuration`) return json(METADATA);
      if (url === METADATA.token_endpoint) {
        const body = new URLSearchParams(String(init?.body ?? ""));
        state.tokenRequests.push(body);
        issued += 1;
        return json({
          access_token: `at-${issued}`,
          refresh_token: `rt-${issued}`,
          id_token: idToken(nonceOf(state)),
          token_type: "Bearer",
          expires_in: state.expiresIn,
        });
      }
      return new Response("", { status: 404 });
    }),
  );
  return state;
}

function nonceOf(state: Provider): string | null {
  const authorize = state.navigations.find((url) => url.startsWith(METADATA.authorization_endpoint));
  return authorize === undefined ? null : new URL(authorize).searchParams.get("nonce");
}

async function waitForNavigation(state: Provider, count: number): Promise<URL> {
  await vi.waitFor(() => expect(state.navigations.length).toBeGreaterThanOrEqual(count));
  return new URL(state.navigations[count - 1]);
}

// One page load that redirects to the provider, then the callback page load.
async function signInThroughCallback(state: Provider) {
  window.history.replaceState(null, "", "/orders/7?tab=open");
  void createShellAuth({ redirectNavigator: state.navigator }).signIn();
  const authorize = await waitForNavigation(state, 1);
  const stateParam = authorize.searchParams.get("state") ?? "";
  window.history.replaceState(null, "", `/auth/callback?code=code-123&state=${stateParam}`);
  const auth = createShellAuth({ redirectNavigator: state.navigator });
  await auth.signIn();
  return { auth, authorize };
}

function storedValues(): string[] {
  const values: string[] = [document.cookie];
  for (const store of [window.localStorage, window.sessionStorage]) {
    for (let i = 0; i < store.length; i += 1) values.push(store.getItem(store.key(i) ?? "") ?? "");
  }
  return values;
}

beforeEach(() => {
  window.localStorage.clear();
  window.sessionStorage.clear();
  window.history.replaceState(null, "", "/");
  provider = fakeProvider();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("the shell's auth module", () => {
  it("signs in with the authorization-code flow and PKCE as a public client, with no client secret", async () => {
    const { auth, authorize } = await signInThroughCallback(provider);
    expect(authorize.origin + authorize.pathname).toBe(METADATA.authorization_endpoint);
    expect(authorize.searchParams.get("response_type")).toBe("code");
    expect(authorize.searchParams.get("code_challenge_method")).toBe("S256");
    expect(authorize.searchParams.get("code_challenge")).toBeTruthy();
    expect(authorize.searchParams.has("client_secret")).toBe(false);
    const exchange = provider.tokenRequests[0];
    expect(exchange.get("grant_type")).toBe("authorization_code");
    expect(exchange.get("code_verifier")).toBeTruthy();
    expect(exchange.has("client_secret")).toBe(false);
    await expect(auth.context.getAccessToken()).resolves.toBe("at-1");
  });

  it("after sign-in and the callback no storage area holds a token", async () => {
    const indexedDb = { open: vi.fn() };
    vi.stubGlobal("indexedDB", indexedDb);
    const { auth } = await signInThroughCallback(provider);
    const token = await auth.context.getAccessToken();
    for (const value of storedValues()) {
      expect(value).not.toContain(token);
      expect(value).not.toContain("rt-1");
    }
    expect(indexedDb.open).not.toHaveBeenCalled();
  });

  it("the callback removes the PKCE code_verifier and state from sessionStorage", async () => {
    window.history.replaceState(null, "", "/orders");
    void createShellAuth({ redirectNavigator: provider.navigator }).signIn();
    const authorize = await waitForNavigation(provider, 1);
    expect(window.sessionStorage.length).toBe(1);
    expect(window.localStorage.length).toBe(0);
    window.history.replaceState(null, "", `/auth/callback?code=code-123&state=${authorize.searchParams.get("state")}`);
    await createShellAuth({ redirectNavigator: provider.navigator }).signIn();
    expect(window.sessionStorage.length).toBe(0);
  });

  it("the callback returns to the page that started the sign-in", async () => {
    const popstate = vi.fn();
    window.addEventListener("popstate", popstate);
    await signInThroughCallback(provider);
    window.removeEventListener("popstate", popstate);
    expect(`${window.location.pathname}${window.location.search}`).toBe("/orders/7?tab=open");
    expect(popstate).toHaveBeenCalledTimes(1);
  });

  it("after a reload the shell re-acquires by a top-level redirect instead of restoring a token", async () => {
    await signInThroughCallback(provider);
    window.history.replaceState(null, "", "/orders");
    const reloaded = createShellAuth({ redirectNavigator: provider.navigator });
    const pending = reloaded.context.getAccessToken();
    const authorize = await waitForNavigation(provider, 2);
    expect(authorize.origin + authorize.pathname).toBe(METADATA.authorization_endpoint);
    expect(authorize.searchParams.has("prompt")).toBe(false);
    expect(provider.tokenRequests).toHaveLength(1);
    const settled = vi.fn();
    void pending.then(settled, settled);
    await Promise.resolve();
    expect(settled).not.toHaveBeenCalled();
  });

  it("an expiring token is renewed with the refresh token, and the rotated refresh token stays in memory", async () => {
    provider.expiresIn = 10;
    const { auth } = await signInThroughCallback(provider);
    await expect(auth.context.getAccessToken()).resolves.toBe("at-2");
    expect(provider.tokenRequests[1].get("grant_type")).toBe("refresh_token");
    expect(provider.tokenRequests[1].get("refresh_token")).toBe("rt-1");
    await expect(auth.context.getAccessToken()).resolves.toBe("at-3");
    expect(provider.tokenRequests[2].get("refresh_token")).toBe("rt-2");
    for (const value of storedValues()) expect(value).not.toContain("rt-");
  });

  it("renewal never runs a hidden-iframe silent renew", async () => {
    provider.expiresIn = 10;
    const created = vi.spyOn(document, "createElement");
    const { auth } = await signInThroughCallback(provider);
    await auth.context.getAccessToken();
    expect(created.mock.calls.filter(([tag]) => String(tag).toLowerCase() === "iframe")).toHaveLength(0);
    expect(document.querySelectorAll("iframe")).toHaveLength(0);
    expect(provider.navigations).toHaveLength(1);
  });

  it("fetches /auth-config.json once per page load and reads issuer, clientId, redirectPath and scope", async () => {
    const auth = createShellAuth({ redirectNavigator: provider.navigator });
    void auth.signIn();
    void auth.signIn();
    void auth.context.getAccessToken();
    const authorize = await waitForNavigation(provider, 1);
    expect(provider.configFetches).toBe(1);
    expect(authorize.origin + authorize.pathname).toBe(METADATA.authorization_endpoint);
    expect(authorize.searchParams.get("client_id")).toBe("acme-shell");
    expect(authorize.searchParams.get("redirect_uri")).toBe(`${window.location.origin}/auth/callback`);
    expect(authorize.searchParams.get("scope")).toBe("openid profile organization");
  });

  it("an unset /auth-config.json field rejects getAccessToken instead of redirecting", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(json({ ...CONFIG, clientId: "" }));
    const auth = createShellAuth({ redirectNavigator: provider.navigator });
    await expect(auth.context.getAccessToken()).rejects.toThrow("/auth-config.json: clientId is not set");
    expect(provider.navigations).toHaveLength(0);
  });

  it("the shipped /auth-config.json placeholder is rejected, never sent to a provider", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(json({ issuer: "", clientId: "", redirectPath: "", scope: "" }));
    const auth = createShellAuth({ redirectNavigator: provider.navigator });
    await expect(auth.signIn()).rejects.toThrow("/auth-config.json: issuer is not set");
    expect(provider.navigations).toHaveLength(0);
  });

  it("the AuthContext a remote receives exposes only getAccessToken and frozen display-only claims", async () => {
    const { auth } = await signInThroughCallback(provider);
    expect(Object.keys(auth.context)).toEqual(["getAccessToken", "claims"]);
    expect(Object.isFrozen(auth.context)).toBe(true);
    expect(Object.isFrozen(auth.context.claims)).toBe(true);
    expect(auth.context.claims).toEqual({ sub: "6f1c2a9e-priya", displayName: "Priya Raman", tenantId: "acme" });
    const ctx = createPageContext(defaultCapabilities(), new AbortController().signal, "/orders", () => undefined);
    expect(ctx.auth).toBe(createAuthContext());
  });

  it("signOut drops the tokens, so a handed-out getAccessToken rejects, then ends the provider session", async () => {
    const { auth } = await signInThroughCallback(provider);
    const handed = auth.context;
    await expect(handed.getAccessToken()).resolves.toBe("at-1");
    void auth.signOut();
    await expect(handed.getAccessToken()).rejects.toThrow("signed out");
    expect(handed.claims).toEqual({ sub: "", displayName: "", tenantId: "" });
    const endSession = await waitForNavigation(provider, 2);
    expect(endSession.origin + endSession.pathname).toBe(METADATA.end_session_endpoint);
    expect(endSession.searchParams.get("id_token_hint")).toBeTruthy();
    expect(endSession.searchParams.get("post_logout_redirect_uri")).toBe(`${window.location.origin}/`);
  });
});
