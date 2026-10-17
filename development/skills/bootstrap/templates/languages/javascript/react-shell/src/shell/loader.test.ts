// The shell's behaviour (#1124): the loader's ordered procedure, onNavigate, the
// leak checks and the zero-remotes case. Executed by the render-and-build smoke
// check (#1063); tests/react-shell-templates.bats pins each case title.

import { act, render, screen, waitFor } from "@testing-library/react";
import { createElement } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { MfeModule, PageContext } from "@{{NPM_SCOPE}}/mfe-contract";
import { createAuthContext } from "./auth";
import { createPageContext, defaultCapabilities } from "./context";
import { enterRoute, FALLBACK_MESSAGE, RouteLoader, type ImportRemote } from "./loader";
import { navigate, subscribe } from "./navigation";
import { matchRoute, type ShellRoute } from "./routes";
import { Shell } from "./Shell";

const ORDERS: ShellRoute = { prefix: "/orders", specifier: "orders-ui", label: "Orders" };
const BILLING: ShellRoute = { prefix: "/billing", specifier: "billing-ui", label: "Billing" };
const IMPORT_MAP = { imports: { "orders-ui": "/ui/orders-ui/remote.js", "billing-ui": "/ui/billing-ui/remote.js" } };

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

// A conforming remote that renders one heading, listens on window and cleans
// both up on unmount. `mount` can be held open with a deferred.
function fakeRemote(name: string, hold?: Promise<void>) {
  const onResize = () => undefined;
  const remote = {
    mount: vi.fn(async (el: HTMLElement, ctx: PageContext | object) => {
      window.addEventListener("resize", onResize);
      const heading = document.createElement("h1");
      heading.textContent = `${name} remote`;
      el.append(heading);
      if (hold) await hold;
      return void ctx;
    }),
    unmount: vi.fn((el: HTMLElement) => {
      window.removeEventListener("resize", onResize);
      el.replaceChildren();
    }),
  };
  return remote satisfies MfeModule;
}

function pageContext(signal: AbortSignal): PageContext {
  return createPageContext(defaultCapabilities(), signal, "/orders", navigate);
}

beforeEach(() => {
  window.history.replaceState(null, "", "/");
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(JSON.stringify(IMPORT_MAP))),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("routes, navigation and context", () => {
  it("matchRoute picks the longest prefix at a path-segment boundary, else null", () => {
    const table = [ORDERS, { prefix: "/orders/archive", specifier: "archive-ui", label: "Archive" }];
    expect(matchRoute("/orders", table)).toBe(ORDERS);
    expect(matchRoute("/orders/7", table)).toBe(ORDERS);
    expect(matchRoute("/orders/archive/2", table)?.specifier).toBe("archive-ui");
    expect(matchRoute("/ordersx", table)).toBeNull();
    expect(matchRoute("/billing", table)).toBeNull();
  });

  it("navigate pushes the path and notifies subscribers, and popstate notifies too", () => {
    const seen: string[] = [];
    const unsubscribe = subscribe((path) => seen.push(path));
    navigate("/orders/7");
    expect(window.location.pathname).toBe("/orders/7");
    window.dispatchEvent(new PopStateEvent("popstate"));
    unsubscribe();
    navigate("/billing");
    expect(seen).toEqual(["/orders/7", "/orders/7"]);
  });

  it("createPageContext carries every PageContext field with the static defaults", async () => {
    const controller = new AbortController();
    const onNavigate = vi.fn();
    const ctx = createPageContext(defaultCapabilities(), controller.signal, "/orders", onNavigate);
    expect(ctx.kind).toBe("page");
    expect(ctx.basePath).toBe("/orders");
    expect(ctx.signal).toBe(controller.signal);
    expect(ctx.flags.isEnabled("new-checkout")).toBe(false);
    expect(ctx.flags.variant("new-checkout")).toBeUndefined();
    expect(Object.isFrozen(ctx.theme)).toBe(true);
    expect(Object.keys(ctx.theme)).toEqual([]);
    expect(Object.isFrozen(ctx.auth.claims)).toBe(true);
    expect(ctx.auth.claims).toEqual({ sub: "", displayName: "", tenantId: "" });
    await expect(createAuthContext().getAccessToken()).rejects.toThrow("no auth provider");
    ctx.onNavigate("/billing");
    expect(onNavigate).toHaveBeenCalledWith("/billing");
  });
});

describe("import-map resolution", () => {
  it("fetches /importmap.json at most once and rejects an unknown specifier by name", async () => {
    vi.resetModules();
    const { resolveSpecifier } = await import("./import-map");
    await expect(resolveSpecifier("orders-ui")).resolves.toBe("/ui/orders-ui/remote.js");
    await expect(resolveSpecifier("billing-ui")).resolves.toBe("/ui/billing-ui/remote.js");
    await expect(resolveSpecifier("payments-ui")).rejects.toThrow("payments-ui");
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(fetch).toHaveBeenCalledWith("/importmap.json");
  });

  it("does not cache a failed fetch, so the next resolve fetches again", async () => {
    vi.resetModules();
    const { resolveSpecifier } = await import("./import-map");
    vi.mocked(fetch).mockResolvedValueOnce(new Response("", { status: 503 }));
    await expect(resolveSpecifier("orders-ui")).rejects.toThrow("HTTP 503");
    await expect(resolveSpecifier("orders-ui")).resolves.toBe("/ui/orders-ui/remote.js");
  });
});

describe("the loader's ordered procedure", () => {
  it("(a) entering a route builds a fresh signal and imports the resolved module", async () => {
    const outlet = document.createElement("div");
    const remote = fakeRemote("orders");
    const load = vi.fn<ImportRemote>(async () => remote);
    const signals: AbortSignal[] = [];
    const attempt = enterRoute(outlet, "orders-ui", (signal) => {
      signals.push(signal);
      return pageContext(signal);
    }, load);
    await attempt.settled;
    expect(load).toHaveBeenCalledWith("/ui/orders-ui/remote.js");
    expect(signals).toHaveLength(1);
    expect(signals[0].aborted).toBe(false);
    expect(remote.mount).toHaveBeenCalledWith(outlet, expect.objectContaining({ signal: signals[0], kind: "page" }));
  });

  it("(b) leaving before the import settles aborts and never mounts or unmounts", async () => {
    const outlet = document.createElement("div");
    const remote = fakeRemote("orders");
    const imported = deferred<MfeModule>();
    const attempt = enterRoute(outlet, "orders-ui", pageContext, () => imported.promise);
    const left = attempt.leave();
    imported.resolve(remote);
    await left;
    expect(remote.mount).not.toHaveBeenCalled();
    expect(remote.unmount).not.toHaveBeenCalled();
  });

  it("(c) leaving after mount aborts, waits for mount to settle, then unmounts exactly once", async () => {
    const outlet = document.createElement("div");
    const held = deferred<void>();
    const remote = fakeRemote("orders", held.promise);
    let signal: AbortSignal | undefined;
    const attempt = enterRoute(outlet, "orders-ui", (s) => {
      signal = s;
      return pageContext(s);
    }, async () => remote);
    await vi.waitFor(() => expect(remote.mount).toHaveBeenCalled());
    const left = attempt.leave();
    expect(signal?.aborted).toBe(true);
    await Promise.resolve();
    expect(remote.unmount).not.toHaveBeenCalled();
    held.resolve();
    await left;
    expect(remote.unmount).toHaveBeenCalledTimes(1);
    expect(remote.unmount).toHaveBeenCalledWith(outlet);
  });

  it("(c) a mount that rejects on its own is unmounted once and the outlet shows the fallback", async () => {
    const outlet = document.createElement("div");
    const held = deferred<void>();
    const remote = fakeRemote("orders", held.promise);
    const attempt = enterRoute(outlet, "orders-ui", pageContext, async () => remote);
    held.reject(new Error("orders backend unavailable"));
    await attempt.settled;
    expect(remote.unmount).toHaveBeenCalledTimes(1);
    expect(outlet.textContent).toBe(FALLBACK_MESSAGE);
    await attempt.leave();
    expect(remote.unmount).toHaveBeenCalledTimes(1);
  });

  it("an import that fails shows the fallback and calls no unmount", async () => {
    const outlet = document.createElement("div");
    const remote = fakeRemote("orders");
    const attempt = enterRoute(outlet, "payments-ui", pageContext, async () => remote);
    await attempt.settled;
    expect(outlet.textContent).toBe(FALLBACK_MESSAGE);
    expect(remote.mount).not.toHaveBeenCalled();
    await attempt.leave();
    expect(remote.unmount).not.toHaveBeenCalled();
  });

  it("(d) the next route waits for the previous attempt, so a stale remote is never mounted", async () => {
    const outlet = document.createElement("div");
    const held = deferred<void>();
    const orders = fakeRemote("orders", held.promise);
    const billing = fakeRemote("billing");
    const load = vi.fn<ImportRemote>(async (url) => (url.includes("orders") ? orders : billing));
    const loader = new RouteLoader(outlet, (route, signal) => createPageContext(defaultCapabilities(), signal,
      route.prefix, navigate), load);
    void loader.show(ORDERS);
    await vi.waitFor(() => expect(orders.mount).toHaveBeenCalled());
    const shown = loader.show(BILLING);
    await Promise.resolve();
    expect(billing.mount).not.toHaveBeenCalled();
    held.resolve();
    await shown;
    expect(orders.unmount).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => expect(billing.mount).toHaveBeenCalledTimes(1));
    expect(outlet.textContent).toBe("billing remote");
  });
});

describe("leaks", () => {
  it("after unmount the outlet has 0 child nodes and window listener calls balance", async () => {
    const outlet = document.createElement("div");
    const add = vi.spyOn(window, "addEventListener");
    const remove = vi.spyOn(window, "removeEventListener");
    const attempt = enterRoute(outlet, "orders-ui", pageContext, async () => fakeRemote("orders"));
    await attempt.settled;
    expect(outlet.childNodes.length).toBe(1);
    await attempt.leave();
    expect(outlet.childNodes.length).toBe(0);
    expect(add.mock.calls.length).toBe(remove.mock.calls.length);
  });
});

describe("the shell", () => {
  const app = () => createElement("p", null, "app home");

  it("onNavigate to another prefix tears down the current remote and mounts the matched one", async () => {
    const orders = fakeRemote("orders");
    const billing = fakeRemote("billing");
    const load = vi.fn<ImportRemote>(async (url) => (url.includes("orders") ? orders : billing));
    window.history.replaceState(null, "", "/orders/7");
    render(createElement(Shell, { capabilities: defaultCapabilities(), routes: [ORDERS, BILLING],
      importRemote: load }, app()));
    await waitFor(() => expect(orders.mount).toHaveBeenCalledTimes(1));
    const ctx = orders.mount.mock.calls[0][1] as PageContext;
    expect(ctx.basePath).toBe("/orders");
    act(() => ctx.onNavigate("/billing"));
    expect(window.location.pathname).toBe("/billing");
    await waitFor(() => expect(billing.mount).toHaveBeenCalledTimes(1));
    expect(orders.unmount).toHaveBeenCalledTimes(1);
  });

  it("onNavigate within the same prefix remounts nothing", async () => {
    const orders = fakeRemote("orders");
    window.history.replaceState(null, "", "/orders");
    render(createElement(Shell, { capabilities: defaultCapabilities(), routes: [ORDERS],
      importRemote: async () => orders }, app()));
    await waitFor(() => expect(orders.mount).toHaveBeenCalledTimes(1));
    const ctx = orders.mount.mock.calls[0][1] as PageContext;
    await act(async () => {
      ctx.onNavigate("/orders/7");
    });
    expect(window.location.pathname).toBe("/orders/7");
    await new Promise((settle) => setTimeout(settle, 0));
    expect(orders.unmount).not.toHaveBeenCalled();
    expect(orders.mount).toHaveBeenCalledTimes(1);
  });

  it("onNavigate to no route renders the shell's children after teardown", async () => {
    const orders = fakeRemote("orders");
    window.history.replaceState(null, "", "/orders");
    render(createElement(Shell, { capabilities: defaultCapabilities(), routes: [ORDERS],
      importRemote: async () => orders }, app()));
    await waitFor(() => expect(orders.mount).toHaveBeenCalledTimes(1));
    expect(screen.queryByText("app home")).toBeNull();
    const ctx = orders.mount.mock.calls[0][1] as PageContext;
    act(() => ctx.onNavigate("/settings"));
    expect(await screen.findByText("app home")).toBeTruthy();
    expect(orders.unmount).toHaveBeenCalledTimes(1);
  });

  it("navigating from no route to a remote route hides the shell's children", async () => {
    const orders = fakeRemote("orders");
    render(createElement(Shell, { capabilities: defaultCapabilities(), routes: [ORDERS],
      importRemote: async () => orders }, app()));
    expect(await screen.findByText("app home")).toBeTruthy();
    act(() => navigate("/orders"));
    await waitFor(() => expect(orders.mount).toHaveBeenCalledTimes(1));
    expect(screen.queryByText("app home")).toBeNull();
  });

  it("a no-route resolve that lands after a newer remote navigation leaves the children hidden", async () => {
    const held = deferred<void>();
    const orders = fakeRemote("orders", held.promise);
    const billing = fakeRemote("billing");
    const load = vi.fn<ImportRemote>(async (url) => (url.includes("orders") ? orders : billing));
    window.history.replaceState(null, "", "/orders");
    render(createElement(Shell, { capabilities: defaultCapabilities(), routes: [ORDERS, BILLING],
      importRemote: load }, app()));
    await waitFor(() => expect(orders.mount).toHaveBeenCalledTimes(1));
    act(() => navigate("/settings")); // its teardown waits on the held orders mount
    act(() => navigate("/billing"));
    await act(async () => {
      held.resolve();
    });
    await waitFor(() => expect(billing.mount).toHaveBeenCalledTimes(1));
    await act(async () => {
      await new Promise((settle) => setTimeout(settle, 0));
    });
    expect(screen.queryByText("app home")).toBeNull();
  });

  it("with zero routes the shell renders its children and never fetches /importmap.json or imports", async () => {
    const load = vi.fn<ImportRemote>();
    vi.resetModules(); // a fresh import-map cache, which the loader cases above have filled
    const { Shell: FreshShell } = await import("./Shell");
    render(createElement(FreshShell, { capabilities: defaultCapabilities(), importRemote: load }, app()));
    expect(await screen.findByText("app home")).toBeTruthy();
    expect(screen.getByRole("banner")).toBeTruthy();
    expect(screen.getByRole("navigation")).toBeTruthy();
    expect(screen.getByRole("main")).toBeTruthy();
    expect(fetch).not.toHaveBeenCalled();
    expect(load).not.toHaveBeenCalled();
  });
});
