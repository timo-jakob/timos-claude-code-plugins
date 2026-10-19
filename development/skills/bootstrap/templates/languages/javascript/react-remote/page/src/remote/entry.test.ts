// The page remote's behaviour (#1125): the entry's mount/unmount contract and the
// nested router. Executed by the render-and-build smoke check (#1063);
// tests/react-remote-templates.bats pins each case title.

import { act } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { PageContext, WidgetContext } from "@{{NPM_SCOPE}}/mfe-contract";
import { mount, unmount } from "./entry";
import { createRemoteRouter } from "./router";

function pageContext(overrides: Partial<PageContext> = {}): PageContext {
  return {
    kind: "page",
    basePath: "/orders",
    onNavigate: vi.fn(),
    auth: {
      getAccessToken: async () => "token",
      claims: { sub: "user-1", displayName: "Ada", tenantId: "tenant-1" },
    },
    flags: { isEnabled: () => false, variant: () => undefined },
    theme: {},
    signal: new AbortController().signal,
    ...overrides,
  };
}

function widgetContext(): WidgetContext {
  const { auth, flags, theme, signal } = pageContext();
  return {
    auth,
    flags,
    theme,
    signal,
    kind: "widget",
    config: {},
    size: { cols: 1, rows: 1 },
    onResize: () => () => {},
  };
}

let el: HTMLElement;

beforeEach(() => {
  window.history.replaceState(null, "", "/orders");
  el = document.createElement("div");
  document.body.append(el);
});

afterEach(async () => {
  await act(async () => unmount(el));
  el.remove();
  vi.restoreAllMocks();
});

describe("page entry", () => {
  it("mount rejects a widget context and renders nothing", async () => {
    await expect(mount(el, widgetContext())).rejects.toThrow("page");
    expect(el.childNodes).toHaveLength(0);
  });

  it("mount stops its work once ctx.signal aborts", async () => {
    const controller = new AbortController();
    controller.abort();
    const listen = vi.spyOn(window, "addEventListener");
    await act(async () => mount(el, pageContext({ signal: controller.signal })));
    expect(el.childNodes).toHaveLength(0);
    expect(listen).not.toHaveBeenCalledWith("popstate", expect.any(Function));
  });

  it("unmount is idempotent, safe on a partial mount, and leaves 0 child nodes", async () => {
    await act(async () => unmount(el));
    await act(async () => mount(el, pageContext()));
    expect(el.childNodes.length).toBeGreaterThan(0);
    await act(async () => unmount(el));
    await act(async () => unmount(el));
    expect(el.childNodes).toHaveLength(0);
  });

  it("after unmount the popstate listener is removed and listener calls balance", async () => {
    const listen = vi.spyOn(window, "addEventListener");
    const unlisten = vi.spyOn(window, "removeEventListener");
    await act(async () => mount(el, pageContext()));
    await act(async () => unmount(el));
    const popstate = (spy: typeof listen) => spy.mock.calls.filter(([type]) => type === "popstate").length;
    expect(popstate(listen)).toBe(1);
    expect(popstate(unlisten)).toBe(popstate(listen));
  });
});

describe("page router", () => {
  it("toLocal strips basePath at a path-segment boundary", () => {
    const router = createRemoteRouter("/orders", vi.fn());
    expect(router.toLocal("/orders")).toBe("/");
    expect(router.toLocal("/orders/")).toBe("/");
    expect(router.toLocal("/orders/7")).toBe("/7");
    expect(router.toLocal("/orders-archive/7")).toBeNull();
    expect(router.toLocal("/")).toBeNull();
    router.dispose();
  });

  it("every path the router produces is prefixed with basePath, never the origin root", async () => {
    const router = createRemoteRouter("/orders/", vi.fn());
    expect(router.toOuter("/")).toBe("/orders");
    expect(router.toOuter("/7")).toBe("/orders/7");
    expect(router.toOuter("7")).toBe("/orders/7");
    router.dispose();
    await act(async () => mount(el, pageContext()));
    expect(el.querySelector("a")?.getAttribute("href")).toBe("/orders");
  });

  it("a modified link click is left to the browser and calls neither pushState nor onNavigate", async () => {
    const ctx = pageContext();
    await act(async () => mount(el, ctx));
    const push = vi.spyOn(window.history, "pushState");
    const click = new MouseEvent("click", { bubbles: true, cancelable: true, metaKey: true });
    const link = el.querySelector("a");
    expect(link).not.toBeNull();
    link!.dispatchEvent(click);
    expect(click.defaultPrevented).toBe(false);
    expect(push).not.toHaveBeenCalled();
    expect(ctx.onNavigate).not.toHaveBeenCalled();
  });

  it("navigate inside basePath calls history.pushState and notifies subscribers", () => {
    const onNavigate = vi.fn();
    const router = createRemoteRouter("/orders", onNavigate);
    const push = vi.spyOn(window.history, "pushState");
    const seen = vi.fn();
    router.subscribe(seen);
    router.navigate("/orders/7");
    expect(push).toHaveBeenCalledWith(null, "", "/orders/7");
    expect(seen).toHaveBeenCalledWith("/7");
    expect(router.current()).toBe("/7");
    router.navigate("/orders?status=open#top");
    expect(push).toHaveBeenLastCalledWith(null, "", "/orders?status=open#top");
    expect(onNavigate).not.toHaveBeenCalled();
    router.dispose();
  });

  it("navigate outside basePath calls onNavigate and neither pushState nor a location write", () => {
    const onNavigate = vi.fn();
    const router = createRemoteRouter("/orders", onNavigate);
    const push = vi.spyOn(window.history, "pushState");
    const replace = vi.spyOn(window.history, "replaceState");
    const before = window.location.href;
    router.navigate("/customers/42");
    expect(onNavigate).toHaveBeenCalledWith("/customers/42");
    expect(push).not.toHaveBeenCalled();
    expect(replace).not.toHaveBeenCalled();
    expect(window.location.href).toBe(before);
    router.dispose();
  });

  it("subscribe fires on popstate and its unsubscribe stops it", () => {
    const router = createRemoteRouter("/orders", vi.fn());
    const seen = vi.fn();
    const stop = router.subscribe(seen);
    window.history.replaceState(null, "", "/orders/9");
    window.dispatchEvent(new PopStateEvent("popstate"));
    expect(seen).toHaveBeenCalledWith("/9");
    stop();
    window.dispatchEvent(new PopStateEvent("popstate"));
    expect(seen).toHaveBeenCalledTimes(1);
    router.dispose();
  });
});
