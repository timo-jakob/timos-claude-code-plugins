// The canvas's behaviour (#1939): persistence, the grid, move and resize, add and
// remove, config validation, the contract-major check, reconfigure, per-slot
// isolation and leaks. Executed by the render-and-build smoke check (#1063);
// tests/react-canvas-templates.bats pins each case title.

import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { createElement } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { GridSize, MfeModule, WidgetContext, WidgetManifest } from "@{{NPM_SCOPE}}/mfe-contract";
import { defaultCapabilities } from "../shell/context";
import { FALLBACK_MESSAGE, type ImportRemote } from "../shell/loader";
import { Canvas, NOT_LOADED_NOTICE, NOT_SAVED_NOTICE, type CanvasApi } from "./WidgetCanvas";
import {
  columnsFor,
  emptyLayout,
  firstFreePosition,
  moveInstance,
  renderedSpan,
  resizeInstance,
  type CanvasLayout,
  type WidgetInstance,
} from "./canvas";
import { createLocalStorageStore, type CanvasCapabilities, type CanvasStore } from "./store";
import { validateConfig } from "./validate";

const MANIFEST: WidgetManifest = {
  id: "orders-kpi",
  contractMajor: 1,
  configSchema: {
    type: "object",
    properties: { metric: { enum: ["open", "late"] } },
    additionalProperties: false,
  },
  size: { min: { cols: 1, rows: 1 }, max: { cols: 4, rows: 2 }, default: { cols: 2, rows: 1 } },
};

const IMPORT_MAP = {
  imports: {
    "orders-kpi": "/ui/orders-kpi/remote.js",
    clock: "/ui/clock/remote.js",
    "broken-kpi": "/ui/broken-kpi/remote.js",
    "no-manifest": "/ui/no-manifest/remote.js",
  },
};

function instance(overrides: Partial<WidgetInstance> = {}): WidgetInstance {
  return {
    id: "a",
    specifier: "orders-kpi",
    config: { metric: "late" },
    position: { col: 0, row: 0 },
    size: { cols: 2, rows: 1 },
    ...overrides,
  };
}

function layoutOf(...instances: WidgetInstance[]): CanvasLayout {
  return { version: 1, instances };
}

// A conforming widget that renders one heading and listens on window, cleaning
// both up on unmount. `mount` rejects when `fail` is set; a null manifest exports none.
function fakeWidget(name: string, manifest: WidgetManifest | null = MANIFEST, fail = false) {
  const onResize = () => undefined;
  const widget = {
    manifest: manifest ?? undefined,
    mount: vi.fn(async (el: HTMLElement, ctx: WidgetContext | object) => {
      window.addEventListener("resize", onResize);
      const heading = document.createElement("h1");
      heading.textContent = `${name} widget`;
      el.append(heading);
      if (fail) throw new Error(`${name} backend unavailable`);
      return void ctx;
    }),
    unmount: vi.fn((el: HTMLElement) => {
      window.removeEventListener("resize", onResize);
      el.replaceChildren();
    }),
  };
  return widget satisfies MfeModule;
}

function memoryStore(initial: CanvasLayout = emptyLayout()) {
  let saved = initial;
  const store = {
    load: vi.fn(async () => saved),
    save: vi.fn(async (layout: CanvasLayout) => {
      saved = layout;
    }),
  };
  return store satisfies CanvasStore;
}

function capabilitiesWith(store: CanvasStore): CanvasCapabilities {
  return { ...defaultCapabilities(), canvasStore: store };
}

function renderCanvas(store: CanvasStore, load: ImportRemote, extra: Record<string, unknown> = {}) {
  return render(createElement(Canvas, { capabilities: capabilitiesWith(store), importRemote: load, ...extra }));
}

function slot(id: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(`[data-canvas-slot="${id}"]`);
  if (found === null) throw new Error(`no slot ${id}`);
  return found;
}

function outlet(id: string): HTMLElement {
  return slot(id).querySelector<HTMLElement>("[data-canvas-outlet]")!;
}

// One pointer gesture on a slot's handle; only the last step commits.
function drag(id: string, handle: "Move" | "Resize", steps: number[]) {
  const target = slot(id).querySelector<HTMLElement>(`[aria-label="${handle}"]`)!;
  fireEvent.pointerDown(target, { pointerId: 1, clientX: 0, clientY: 0 });
  for (const x of steps) fireEvent.pointerMove(target, { pointerId: 1, clientX: x, clientY: 0 });
  fireEvent.pointerUp(target, { pointerId: 1, clientX: steps.at(-1) ?? 0, clientY: 0 });
}

beforeEach(() => {
  window.localStorage.clear();
  vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify(IMPORT_MAP))));
  if (!("PointerEvent" in window)) {
    class PointerEventPolyfill extends MouseEvent {
      readonly pointerId: number;
      constructor(type: string, init: MouseEventInit & { pointerId?: number } = {}) {
        super(type, init);
        this.pointerId = init.pointerId ?? 1;
      }
    }
    vi.stubGlobal("PointerEvent", PointerEventPolyfill);
  }
  Element.prototype.setPointerCapture = vi.fn();
  // 12 columns of 100 px: one cell per 100 px of pointer travel
  vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(1200);
  Object.defineProperty(window, "innerWidth", { configurable: true, value: 1200 });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("persistence", () => {
  it("a missing, unparseable or non-version-1 entry loads as an empty canvas", async () => {
    const store = createLocalStorageStore("acme-corp/demo");
    expect(await store.load()).toEqual(emptyLayout());
    window.localStorage.setItem("acme-corp/demo:canvas:v1", "{not json");
    expect(await store.load()).toEqual(emptyLayout());
    window.localStorage.setItem("acme-corp/demo:canvas:v1", JSON.stringify({ version: 2, instances: [] }));
    expect(await store.load()).toEqual(emptyLayout());
    const blocked = () => { throw new DOMException("storage blocked", "SecurityError"); };
    await expect(createLocalStorageStore("acme-corp/demo", blocked).load()).rejects.toThrow("storage blocked");
  });

  it("after a reload every instance keeps its specifier, config, position and size", async () => {
    const layout = layoutOf(
      instance(),
      instance({ id: "b", specifier: "clock", config: {}, position: { col: 2, row: 0 }, size: { cols: 1, rows: 1 } }),
    );
    await createLocalStorageStore("acme-corp/demo").save(layout);
    expect(await createLocalStorageStore("acme-corp/demo").load()).toEqual(layout);
  });

  it("the canvas saves once per committed change and never during a drag", async () => {
    const store = memoryStore(layoutOf(instance()));
    const widget = fakeWidget("orders");
    renderCanvas(store, async () => widget);
    await waitFor(() => expect(widget.mount).toHaveBeenCalledTimes(1));
    drag("a", "Move", [0]);
    const target = slot("a").querySelector<HTMLElement>('[aria-label="Move"]')!;
    fireEvent.pointerDown(target, { pointerId: 1, clientX: 0, clientY: 0 });
    fireEvent.pointerMove(target, { pointerId: 1, clientX: 150, clientY: 0 });
    fireEvent.pointerMove(target, { pointerId: 1, clientX: 300, clientY: 0 });
    expect(store.save).not.toHaveBeenCalled();
    fireEvent.pointerUp(target, { pointerId: 1, clientX: 300, clientY: 0 });
    await waitFor(() => expect(store.save).toHaveBeenCalledTimes(1));
    expect(store.save.mock.calls[0][0].instances[0].position).toEqual({ col: 3, row: 0 });
  });

  it("a rejected load or save shows its notice, and a rejected save keeps the in-memory layout", async () => {
    const store = memoryStore(layoutOf(instance()));
    store.save.mockRejectedValue(new Error("quota exceeded"));
    const widget = fakeWidget("orders");
    renderCanvas(store, async () => widget);
    await waitFor(() => expect(widget.mount).toHaveBeenCalledTimes(1));
    drag("a", "Move", [300]);
    expect(await screen.findByText(NOT_SAVED_NOTICE)).toBeTruthy();
    expect(slot("a").style.gridColumn).toBe("4 / span 2");
    const unreadable = memoryStore();
    unreadable.load.mockRejectedValue(new Error("storage unavailable"));
    const failed = within(
      renderCanvas(unreadable, async () => widget, { widgets: [{ specifier: "orders-kpi", label: "Orders KPI" }] })
        .container,
    );
    expect(await screen.findByText(NOT_LOADED_NOTICE)).toBeTruthy();
    fireEvent.click(failed.getByRole("button", { name: "Add" }));
    // settle on either outcome of the add, so a save over the stored layout fails the next line
    const added = () => unreadable.save.mock.calls.length || failed.queryByText(/could not be added/);
    await waitFor(() => expect(added()).toBeTruthy());
    expect(unreadable.save).not.toHaveBeenCalled();
  });
});

describe("the grid", () => {
  it("the grid has 12, 8 and 4 columns, and a narrow span changes neither the saved size nor onResize", async () => {
    expect([columnsFor(1024), columnsFor(1023), columnsFor(640), columnsFor(639)]).toEqual([12, 8, 8, 4]);
    expect(renderedSpan({ cols: 6, rows: 1 }, 4)).toBe(4);
    const store = memoryStore(layoutOf(instance({ size: { cols: 4, rows: 1 } })));
    const widget = fakeWidget("orders");
    const resized = vi.fn();
    widget.mount.mockImplementation(async (_el, ctx) => {
      (ctx as WidgetContext).onResize(resized);
    });
    renderCanvas(store, async () => widget);
    await waitFor(() => expect(widget.mount).toHaveBeenCalledTimes(1));
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 500 });
    act(() => window.dispatchEvent(new Event("resize")));
    await waitFor(() => expect(slot("a").style.gridColumn).toBe("1 / span 4"));
    expect(resized).not.toHaveBeenCalled();
    expect(store.save).not.toHaveBeenCalled();
  });

  it("a drop snaps to whole cells and a drop onto another instance or off the grid is rejected", () => {
    const layout = layoutOf(instance(), instance({ id: "b", position: { col: 2, row: 0 } }));
    expect(moveInstance(layout, "a", { col: 0.6, row: 1.4 }, 12).instances[0].position).toEqual({ col: 1, row: 1 });
    expect(moveInstance(layout, "a", { col: 1, row: 0 }, 12)).toBe(layout);
    expect(moveInstance(layout, "a", { col: 11, row: 0 }, 12)).toBe(layout);
    expect(moveInstance(layout, "a", { col: -1, row: 0 }, 12)).toBe(layout);
  });

  it("resize clamps to the manifest bounds and the right edge, and rejects an overlap", () => {
    const lone = layoutOf(instance());
    expect(resizeInstance(lone, "a", { cols: 9, rows: 5 }, MANIFEST.size, 12).instances[0].size).toEqual({
      cols: 4,
      rows: 2,
    });
    const atEdge = layoutOf(instance({ position: { col: 10, row: 0 } }));
    expect(resizeInstance(atEdge, "a", { cols: 4, rows: 1 }, MANIFEST.size, 12).instances[0].size.cols).toBe(2);
    expect(resizeInstance(atEdge, "a", { cols: 2, rows: 1 }, MANIFEST.size, 4)).toBe(atEdge);
    const crowded = layoutOf(instance(), instance({ id: "b", position: { col: 2, row: 0 } }));
    expect(resizeInstance(crowded, "a", { cols: 3, rows: 1 }, MANIFEST.size, 12)).toBe(crowded);
  });

  it("a resize end calls onResize once with the new size and never remounts", async () => {
    const store = memoryStore(layoutOf(instance()));
    const widget = fakeWidget("orders");
    const resized = vi.fn<(size: GridSize) => void>();
    widget.mount.mockImplementation(async (_el, ctx) => {
      (ctx as WidgetContext).onResize(resized);
    });
    renderCanvas(store, async () => widget);
    await waitFor(() => expect(widget.mount).toHaveBeenCalledTimes(1));
    drag("a", "Resize", [50, 100]);
    await waitFor(() => expect(resized).toHaveBeenCalledTimes(1));
    expect(resized).toHaveBeenCalledWith({ cols: 3, rows: 1 });
    expect(widget.mount).toHaveBeenCalledTimes(1);
    expect(widget.unmount).not.toHaveBeenCalled();
    expect(store.save).toHaveBeenCalledTimes(1);
  });
});

describe("adding and removing", () => {
  it("adding places the manifest's default size at the first free row-major position with config {}", async () => {
    const store = memoryStore(layoutOf(instance({ id: "b", specifier: "clock", size: { cols: 1, rows: 1 } })));
    const widget = fakeWidget("orders");
    renderCanvas(store, async () => widget, { widgets: [{ specifier: "orders-kpi", label: "Orders KPI" }] });
    await waitFor(() => expect(store.load).toHaveBeenCalled());
    fireEvent.click(await screen.findByRole("button", { name: "Add" }));
    await waitFor(() => expect(store.save).toHaveBeenCalledTimes(1));
    const added = store.save.mock.calls[0][0].instances[1];
    expect(added).toMatchObject({ specifier: "orders-kpi", config: {}, position: { col: 1, row: 0 } });
    expect(added.size).toEqual(MANIFEST.size.default);
    expect(() => firstFreePosition(emptyLayout(), { cols: 6, rows: 1 }, 4)).toThrow(RangeError);
  });

  it("removing tears the slot down, then drops the instance from the layout", async () => {
    const order: string[] = [];
    const store = memoryStore(layoutOf(instance()));
    store.save.mockImplementation(async () => {
      order.push("save");
    });
    const widget = fakeWidget("orders");
    widget.unmount.mockImplementation((el: HTMLElement) => {
      order.push("unmount");
      el.replaceChildren();
    });
    renderCanvas(store, async () => widget);
    await waitFor(() => expect(widget.mount).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    await waitFor(() => expect(order).toEqual(["unmount", "save"]));
    expect(store.save.mock.calls[0][0].instances).toEqual([]);
  });
});

describe("validation and the remount rules", () => {
  it("validation supports the subset and fails closed on any other keyword", () => {
    const schema = {
      type: "object",
      required: ["metric"],
      properties: {
        metric: { type: "string", enum: ["open", "late"] },
        limit: { type: "integer", minimum: 1, maximum: 50 },
        label: { type: "string", minLength: 1, maxLength: 20 },
        tags: { type: "array", items: { type: "string" } },
        mode: { const: "compact" },
      },
      additionalProperties: false,
    };
    expect(validateConfig(schema, { metric: "late", limit: 5, label: "Late", tags: ["eu"], mode: "compact" })).toEqual(
      { ok: true },
    );
    expect(validateConfig(schema, {})).toMatchObject({ ok: false, path: "$.metric", rule: "required" });
    expect(validateConfig(schema, { metric: "late", limit: 99 })).toMatchObject({ rule: "maximum" });
    expect(validateConfig(schema, { metric: "late", extra: 1 })).toMatchObject({ rule: "additionalProperties" });
    expect(validateConfig(schema, { metric: "late", tags: [1] })).toMatchObject({ path: "$.tags[0]", rule: "type" });
    expect(validateConfig({ pattern: "^a" }, "a")).toMatchObject({ reason: "unsupported", keyword: "pattern" });
    expect(validateConfig({ additionalProperties: {} }, {})).toMatchObject({ reason: "unsupported" });
  });

  it("an invalid config stays in the layout unmounted, its slot naming the path and rule", async () => {
    const store = memoryStore(layoutOf(instance({ config: { metric: "overdue" } })));
    const widget = fakeWidget("orders");
    renderCanvas(store, async () => widget);
    await waitFor(() => expect(outlet("a").textContent).toContain('fails "enum" at $.metric'));
    expect(widget.mount).not.toHaveBeenCalled();
    expect(store.save).not.toHaveBeenCalled();
  });

  it("an instance targeting another contract major stays unmounted, its slot naming both majors", async () => {
    const store = memoryStore(layoutOf(instance()));
    const widget = fakeWidget("orders", { ...MANIFEST, contractMajor: 2 });
    renderCanvas(store, async () => widget);
    await waitFor(() => expect(outlet("a").textContent).toContain("major 2"));
    expect(outlet("a").textContent).toContain("major 1");
    expect(widget.mount).not.toHaveBeenCalled();
  });

  it("reconfigure unmounts, then remounts with the new config", async () => {
    const store = memoryStore(layoutOf(instance()));
    const widget = fakeWidget("orders");
    let api: CanvasApi | undefined;
    renderCanvas(store, async () => widget, { onApi: (given: CanvasApi) => (api = given) });
    await waitFor(() => expect(widget.mount).toHaveBeenCalledTimes(1));
    await act(async () => {
      await api!.reconfigure("a", { metric: "open" });
    });
    await waitFor(() => expect(widget.mount).toHaveBeenCalledTimes(2));
    expect(widget.unmount).toHaveBeenCalledTimes(1);
    expect((widget.mount.mock.calls[1][1] as WidgetContext).config).toEqual({ metric: "open" });
    await expect(api!.reconfigure("a", { metric: "overdue" })).rejects.toThrow('fails "enum"');
  });
});

describe("isolation and leaks", () => {
  it("an import failure, a missing manifest or a rejecting mount shows the fallback in that slot only", async () => {
    const healthy = fakeWidget("orders");
    const rejecting = fakeWidget("broken", MANIFEST, true);
    const bare = fakeWidget("bare", null);
    const load = vi.fn<ImportRemote>(async (url) => {
      if (url.includes("broken")) return rejecting;
      if (url.includes("no-manifest")) return bare;
      return healthy;
    });
    const store = memoryStore(
      layoutOf(
        instance(),
        instance({ id: "b", specifier: "missing-ui", position: { col: 2, row: 0 } }),
        instance({ id: "c", specifier: "no-manifest", position: { col: 4, row: 0 } }),
        instance({ id: "d", specifier: "broken-kpi", position: { col: 6, row: 0 } }),
      ),
    );
    renderCanvas(store, load);
    for (const id of ["b", "c", "d"]) {
      await waitFor(() => expect(outlet(id).textContent).toBe(FALLBACK_MESSAGE));
    }
    expect(outlet("a").textContent).toBe("orders widget");
    expect(healthy.unmount).not.toHaveBeenCalled();
  });

  it("after a slot unmounts it has 0 child nodes and window listener calls balance", async () => {
    const add = vi.spyOn(window, "addEventListener");
    const remove = vi.spyOn(window, "removeEventListener");
    const store = memoryStore(layoutOf(instance()));
    const widget = fakeWidget("orders");
    const view = renderCanvas(store, async () => widget);
    await waitFor(() => expect(widget.mount).toHaveBeenCalledTimes(1));
    const el = outlet("a");
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    await waitFor(() => expect(widget.unmount).toHaveBeenCalledTimes(1));
    expect(el.childNodes.length).toBe(0);
    view.unmount();
    expect(add.mock.calls.length).toBe(remove.mock.calls.length);
  });
});
