// The widget remote's behaviour (#1125): the manifest, the entry's mount/unmount
// contract, config narrowing, sizing and leaks. Executed by the render-and-build
// smoke check (#1063); tests/react-remote-templates.bats pins each case title.

import { act } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { GridSize, PageContext, WidgetContext } from "@{{NPM_SCOPE}}/mfe-contract";
import { manifest as manifestModule } from "./manifest";
import { manifest, mount, unmount } from "./entry";

function widgetContext(overrides: Partial<WidgetContext> = {}): WidgetContext {
  return {
    kind: "widget",
    config: {},
    size: { cols: 2, rows: 1 },
    onResize: () => () => {},
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

function pageContext(): PageContext {
  const { auth, flags, theme, signal } = widgetContext();
  return { auth, flags, theme, signal, kind: "page", basePath: "/orders", onNavigate: () => {} };
}

/** A context whose onResize the test drives, counting subscriptions. */
function resizable() {
  const subscribers = new Set<(size: GridSize) => void>();
  const unsubscribe = vi.fn();
  const ctx = widgetContext({
    onResize(cb) {
      subscribers.add(cb);
      return () => {
        unsubscribe();
        subscribers.delete(cb);
      };
    },
  });
  const resize = (size: GridSize) => {
    for (const cb of subscribers) cb(size);
  };
  return { ctx, resize, unsubscribe, subscribers };
}

let el: HTMLElement;

beforeEach(() => {
  el = document.createElement("div");
  document.body.append(el);
});

afterEach(async () => {
  await act(async () => unmount(el));
  el.remove();
  vi.restoreAllMocks();
});

describe("widget manifest", () => {
  it("the manifest has contractMajor 1, an object configSchema and min <= default <= max", () => {
    expect(manifest.contractMajor).toBe(1);
    expect(typeof manifest.configSchema).toBe("object");
    expect(manifest.configSchema).not.toBeNull();
    for (const axis of ["cols", "rows"] as const) {
      expect(manifest.size.min[axis]).toBeLessThanOrEqual(manifest.size.default[axis]);
      expect(manifest.size.default[axis]).toBeLessThanOrEqual(manifest.size.max[axis]);
    }
  });

  it("entry.tsx re-exports the manifest, and evaluating it only defines its exports", async () => {
    vi.resetModules();
    const listen = vi.spyOn(window, "addEventListener");
    const before = document.body.innerHTML;
    const entry = await import("./entry");
    expect(Object.keys(entry).sort()).toEqual(["manifest", "mount", "unmount"]);
    expect(entry.manifest).toEqual(manifestModule);
    expect(document.body.innerHTML).toBe(before);
    expect(listen).not.toHaveBeenCalled();
  });
});

describe("widget entry", () => {
  it("mount rejects a page context and renders nothing", async () => {
    await expect(mount(el, pageContext())).rejects.toThrow("widget");
    expect(el.childNodes).toHaveLength(0);
  });

  it("mount stops its work once ctx.signal aborts", async () => {
    const controller = new AbortController();
    controller.abort();
    const { ctx, subscribers } = resizable();
    await act(async () => mount(el, { ...ctx, signal: controller.signal }));
    expect(el.childNodes).toHaveLength(0);
    expect(subscribers.size).toBe(0);
  });

  it("mount narrows ctx.config and rejects a config that fails the narrowing", async () => {
    for (const config of [null, "title", [], { title: 3 }]) {
      await expect(mount(el, widgetContext({ config }))).rejects.toThrow("config");
      expect(el.childNodes).toHaveLength(0);
    }
    await act(async () => mount(el, widgetContext({ config: { title: "Late orders" } })));
    expect(el.querySelector("h2")?.textContent).toBe("Late orders");
  });

  it("mount renders for ctx.size and re-renders on onResize without a remount", async () => {
    const { ctx, resize } = resizable();
    await act(async () => mount(el, { ...ctx, size: { cols: 1, rows: 1 } }));
    const section = el.querySelector("section");
    expect(section?.dataset.layout).toBe("compact");
    await act(async () => resize({ cols: 3, rows: 2 }));
    expect(el.querySelector("section")).toBe(section);
    expect(section?.dataset.layout).toBe("wide");
    expect(section?.dataset.cols).toBe("3");
    expect(section?.dataset.rows).toBe("2");
  });

  it("the widget neither reads nor writes history or location", async () => {
    const push = vi.spyOn(window.history, "pushState");
    const replace = vi.spyOn(window.history, "replaceState");
    const before = window.location.href;
    const { ctx, resize } = resizable();
    await act(async () => mount(el, ctx));
    await act(async () => resize({ cols: 4, rows: 3 }));
    await act(async () => unmount(el));
    expect(push).not.toHaveBeenCalled();
    expect(replace).not.toHaveBeenCalled();
    expect(window.location.href).toBe(before);
  });

  it("unmount calls the onResize unsubscribe, is idempotent, and leaves 0 child nodes", async () => {
    await act(async () => unmount(el));
    const { ctx, unsubscribe, subscribers } = resizable();
    await act(async () => mount(el, ctx));
    expect(subscribers.size).toBe(1);
    await act(async () => unmount(el));
    await act(async () => unmount(el));
    expect(unsubscribe).toHaveBeenCalledTimes(1);
    expect(subscribers.size).toBe(0);
    expect(el.childNodes).toHaveLength(0);
  });
});
