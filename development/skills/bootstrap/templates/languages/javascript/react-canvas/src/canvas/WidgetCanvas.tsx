// The widget canvas (#1939): a responsive grid of widget instances the user adds,
// moves, resizes and removes. Each slot runs the shell's loader procedure on its
// own (#1124), so one widget failing never touches another, and the layout is kept
// through the injected CanvasStore — saved once per committed change.

import { useEffect, useRef, useState, type CSSProperties, type PointerEvent } from "react";
import type { GridSize, MfeModule, WidgetContext, WidgetManifest } from "@{{NPM_SCOPE}}/mfe-contract";
import { resolveSpecifier } from "../shell/import-map";
import { importRemote as defaultImportRemote, RouteLoader, type ImportRemote } from "../shell/loader";
import {
  addInstance,
  columnsFor,
  firstFreePosition,
  moveInstance,
  reconfigureInstance,
  removeInstance,
  renderedSpan,
  resizeInstance,
  type CanvasLayout,
  type WidgetInstance,
} from "./canvas";
import type { CanvasCapabilities } from "./store";
import { mountRefusal } from "./validate";
import { widgets as defaultWidgets, type CanvasWidget } from "./widgets";

export const NOT_SAVED_NOTICE = "The canvas layout was not saved.";
export const NOT_LOADED_NOTICE = "The canvas layout could not be loaded.";
const ROW_HEIGHT = 120;

/** The canvas's API beyond the UI: a config editor calls `reconfigure`. */
export interface CanvasApi {
  /** Validates `config`, then unmounts and remounts the instance with it; rejects with the reason. */
  reconfigure(id: string, config: unknown): Promise<void>;
}

export interface CanvasProps {
  /** The shell's capabilities plus the layout store. */
  capabilities: CanvasCapabilities;
  widgets?: readonly CanvasWidget[];
  /** How a widget's entry module is loaded; tests pass a fake. */
  importRemote?: ImportRemote;
  onApi?: (api: CanvasApi) => void;
}

interface SlotState {
  size: GridSize;
  config: unknown;
  manifest?: WidgetManifest;
  subscribers: Set<(size: GridSize) => void>;
}

interface Slot {
  state: SlotState;
  loader: RouteLoader;
}

interface Gesture {
  id: string;
  mode: "move" | "resize";
  x: number;
  y: number;
  from: WidgetInstance;
  /** The latest snapped preview; what the gesture commits when it ends. */
  to: WidgetInstance;
}

// A host-authored module that renders why an instance is not mounted. The widget's
// own module is never mounted; this one goes through the same procedure instead.
function reasonModule(reason: string): MfeModule {
  return {
    mount(el) {
      const message = document.createElement("p");
      message.setAttribute("role", "alert");
      message.textContent = reason;
      el.replaceChildren(message);
    },
    unmount(el) {
      el.replaceChildren();
    },
  };
}

export function Canvas({
  capabilities,
  widgets = defaultWidgets,
  importRemote = defaultImportRemote,
  onApi,
}: CanvasProps) {
  const store = capabilities.canvasStore;
  const [layout, setLayout] = useState<CanvasLayout | null>(null);
  const [columns, setColumns] = useState(() => columnsFor(window.innerWidth));
  const [preview, setPreview] = useState<WidgetInstance | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [selected, setSelected] = useState(widgets[0]?.specifier ?? "");
  const gridRef = useRef<HTMLDivElement>(null);
  const gesture = useRef<Gesture | null>(null);
  const slots = useRef(new Map<string, Slot>());
  // The layout is written to `latest` where it is set, so an operation never reads a stale one.
  const latest = useRef({ layout, capabilities, importRemote });

  useEffect(() => {
    latest.current.capabilities = capabilities;
    latest.current.importRemote = importRemote;
  });

  // A failed load leaves the layout null, so no change can be saved over the stored one.
  useEffect(() => {
    let active = true;
    store.load().then(
      (loaded) => {
        if (!active) return;
        latest.current.layout = loaded;
        setLayout(loaded);
      },
      () => active && setNotice(NOT_LOADED_NOTICE),
    );
    return () => {
      active = false;
    };
  }, [store]);

  useEffect(() => {
    const onWidth = () => setColumns(columnsFor(window.innerWidth));
    window.addEventListener("resize", onWidth);
    return () => window.removeEventListener("resize", onWidth);
  }, []);

  // Saved once per committed change; a failed save keeps the change in memory and says so.
  function commit(next: CanvasLayout): void {
    latest.current.layout = next;
    setLayout(next);
    store.save(next).then(
      () => setNotice(null),
      () => setNotice(NOT_SAVED_NOTICE),
    );
  }

  useEffect(() => {
    onApi?.({
      async reconfigure(id, config) {
        const current = latest.current.layout;
        const manifest = slots.current.get(id)?.state.manifest;
        const reason =
          manifest === undefined
            ? "the widget has not loaded; its config cannot be validated"
            : mountRefusal(manifest, config);
        if (current === null || reason !== null) throw new Error(reason ?? "the canvas has not loaded");
        commit(reconfigureInstance(current, id, config));
      },
    });
    // commit only closes over the store, which the layout effect already tracks
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [onApi, store]);

  async function add(widget: CanvasWidget): Promise<void> {
    try {
      const remote = await latest.current.importRemote(await resolveSpecifier(widget.specifier));
      const current = latest.current.layout;
      if (remote.manifest === undefined || current === null) throw new Error("no manifest");
      const size = remote.manifest.size.default;
      const position = firstFreePosition(current, size, columns);
      const added = { id: crypto.randomUUID(), specifier: widget.specifier, config: {}, position, size };
      commit(addInstance(current, added));
    } catch {
      setNotice(`The widget "${widget.label}" could not be added.`);
    }
  }

  async function remove(id: string): Promise<void> {
    await slots.current.get(id)?.loader.show(null);
    slots.current.delete(id);
    const current = latest.current.layout;
    if (current !== null) commit(removeInstance(current, id));
  }

  // One slot's loader, built once its outlet exists; the context reads the slot's latest state.
  function slotFor(instance: WidgetInstance, outlet: HTMLElement): Slot {
    const existing = slots.current.get(instance.id);
    if (existing !== undefined) return existing;
    const state: SlotState = { size: instance.size, config: instance.config, subscribers: new Set() };
    const load: ImportRemote = async (url) => {
      const remote = await latest.current.importRemote(url);
      if (remote.manifest === undefined) throw new Error(`${instance.specifier} exports no manifest`);
      state.manifest = remote.manifest;
      const reason = mountRefusal(remote.manifest, state.config);
      return reason === null ? remote : reasonModule(reason);
    };
    const context = (signal: AbortSignal): WidgetContext => {
      const { auth, flags, theme } = latest.current.capabilities;
      return {
        auth,
        flags,
        theme,
        signal,
        kind: "widget",
        config: state.config,
        get size() {
          return state.size;
        },
        onResize(cb) {
          state.subscribers.add(cb);
          return () => state.subscribers.delete(cb);
        },
      };
    };
    const slot: Slot = { state, loader: new RouteLoader(outlet, (_route, signal) => context(signal), load) };
    slots.current.set(instance.id, slot);
    return slot;
  }

  function startGesture(event: PointerEvent<HTMLElement>, instance: WidgetInstance, mode: Gesture["mode"]): void {
    event.currentTarget.setPointerCapture(event.pointerId);
    gesture.current = { id: instance.id, mode, x: event.clientX, y: event.clientY, from: instance, to: instance };
  }

  // Intermediate steps only move the preview; nothing is saved until the gesture ends.
  function moveGesture(event: PointerEvent<HTMLElement>): void {
    const g = gesture.current;
    const width = gridRef.current?.clientWidth ?? 0;
    if (g === null || width === 0) return;
    const dCol = Math.round((event.clientX - g.x) / (width / columns));
    const dRow = Math.round((event.clientY - g.y) / ROW_HEIGHT);
    const { position, size } = g.from;
    g.to =
      g.mode === "move"
        ? { ...g.from, position: { col: position.col + dCol, row: position.row + dRow } }
        : { ...g.from, size: { cols: size.cols + dCol, rows: size.rows + dRow } };
    setPreview(g.to);
  }

  // A cancelled pointer (a touch turned into a scroll) ends the gesture with no commit.
  function cancelGesture(): Gesture | null {
    const g = gesture.current;
    gesture.current = null;
    setPreview(null);
    return g;
  }

  // The one commit of a gesture. A rejected drop or resize restores the instance.
  function endGesture(): void {
    const g = cancelGesture();
    const current = latest.current.layout;
    if (g === null || current === null) return;
    if (g.mode === "move") {
      const next = moveInstance(current, g.id, g.to.position, columns);
      const moved = next.instances.find((instance) => instance.id === g.id)?.position;
      if (next === current || moved === undefined) return;
      if (moved.col === g.from.position.col && moved.row === g.from.position.row) return;
      commit(next);
      return;
    }
    const slot = slots.current.get(g.id)?.state;
    const bounds = slot?.manifest?.size ?? {
      min: { cols: 1, rows: 1 },
      max: { cols: columns, rows: Number.MAX_SAFE_INTEGER },
      default: g.from.size,
    };
    const next = resizeInstance(current, g.id, g.to.size, bounds, columns);
    const resized = next.instances.find((instance) => instance.id === g.id)?.size;
    if (next === current || resized === undefined) return;
    if (resized.cols === g.from.size.cols && resized.rows === g.from.size.rows) return;
    commit(next);
    if (slot !== undefined) {
      slot.size = resized;
      for (const cb of slot.subscribers) cb(resized);
    }
  }

  const chosen = widgets.find((widget) => widget.specifier === selected);
  const gridStyle: CSSProperties = {
    display: "grid",
    gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))`,
    gridAutoRows: `${ROW_HEIGHT}px`,
  };

  return (
    <section aria-label="Canvas">
      {notice !== null && <p role="status">{notice}</p>}
      <div>
        <select aria-label="Widget" value={selected} onChange={(event) => setSelected(event.target.value)}>
          {widgets.map((widget) => (
            <option key={widget.specifier} value={widget.specifier}>
              {widget.label}
            </option>
          ))}
        </select>
        <button
          type="button"
          disabled={chosen === undefined}
          onClick={() => {
            if (chosen !== undefined) void add(chosen);
          }}
        >
          Add
        </button>
      </div>
      <div ref={gridRef} data-canvas-grid="" style={gridStyle}>
        {(layout?.instances ?? []).map((instance) => {
          const onGrid = instance.position.col + instance.size.cols <= columns;
          return (
            <WidgetSlot
              key={instance.id}
              instance={preview?.id === instance.id ? preview : instance}
              columns={columns}
              onGrid={onGrid}
              attach={(outlet) => slotFor(instance, outlet)}
              config={instance.config}
              onRemove={() => void remove(instance.id)}
              onPointerDown={(event, mode) => {
                if (onGrid) startGesture(event, instance, mode);
              }}
              onPointerMove={moveGesture}
              onPointerUp={endGesture}
              onPointerCancel={() => void cancelGesture()}
            />
          );
        })}
      </div>
    </section>
  );
}

interface WidgetSlotProps {
  instance: WidgetInstance;
  columns: number;
  /** False when the saved box leaves this breakpoint's grid: the slot is auto-placed and takes no gesture. */
  onGrid: boolean;
  config: unknown;
  attach: (outlet: HTMLElement) => Slot;
  onRemove: () => void;
  onPointerDown: (event: PointerEvent<HTMLElement>, mode: Gesture["mode"]) => void;
  onPointerMove: (event: PointerEvent<HTMLElement>) => void;
  onPointerUp: () => void;
  onPointerCancel: () => void;
}

function WidgetSlot(props: WidgetSlotProps) {
  const {
    instance,
    columns,
    onGrid,
    config,
    attach,
    onRemove,
    onPointerDown,
    onPointerMove,
    onPointerUp,
    onPointerCancel,
  } = props;
  const outletRef = useRef<HTMLDivElement>(null);
  const slotRef = useRef<Slot | null>(null);
  const attachRef = useRef(attach);
  const configKey = JSON.stringify(config);

  useEffect(() => {
    attachRef.current = attach;
  });

  // A changed config remounts (the loader keys a mount on it); a move or a resize never does.
  useEffect(() => {
    const outlet = outletRef.current;
    if (outlet === null) return;
    const slot = attachRef.current(outlet);
    slotRef.current = slot;
    slot.state.config = config;
    void slot.loader.show({ prefix: `${instance.id}:${configKey}`, specifier: instance.specifier, label: instance.id });
    // config is read through configKey, its serialised form
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [instance.id, instance.specifier, configKey]);

  useEffect(() => () => void slotRef.current?.loader.show(null), []);

  const span = renderedSpan(instance.size, columns);
  const col = Math.min(instance.position.col, columns - span);
  const style: CSSProperties = onGrid
    ? { gridColumn: `${col + 1} / span ${span}`, gridRow: `${instance.position.row + 1} / span ${instance.size.rows}` }
    : { gridColumn: `span ${span}`, gridRow: `span ${instance.size.rows}` };
  const handlers = (mode: Gesture["mode"]) => ({
    onPointerDown: (event: PointerEvent<HTMLElement>) => onPointerDown(event, mode),
    onPointerMove,
    onPointerUp,
    onPointerCancel,
    style: { touchAction: "none" } satisfies CSSProperties,
  });
  return (
    <article data-canvas-slot={instance.id} style={style}>
      <header>
        <span role="button" tabIndex={-1} aria-label="Move" {...handlers("move")} />
        <button type="button" onClick={onRemove}>
          Remove
        </button>
      </header>
      <div ref={outletRef} data-canvas-outlet="" />
      <span role="button" tabIndex={-1} aria-label="Resize" {...handlers("resize")} />
    </article>
  );
}
