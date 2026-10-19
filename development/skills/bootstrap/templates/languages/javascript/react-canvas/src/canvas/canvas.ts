// The canvas layout model (#1939): instances on a grid of whole cells, changed only
// through pure operations. An operation never mutates its input; one the grid
// refuses returns the input layout itself, so `next === layout` means "rejected".

import type { GridSize, WidgetManifest } from "@{{NPM_SCOPE}}/mfe-contract";

/** The mfe-contract major this host mounts; a widget targeting another one is never mounted. */
export const CONTRACT_MAJOR = 1;

export interface GridPosition {
  col: number;
  row: number;
}

export interface WidgetInstance {
  id: string;
  /** The bare specifier /importmap.json resolves to the widget's entry URL. */
  specifier: string;
  /** Validated against the widget's `manifest.configSchema` before every mount. */
  config: unknown;
  position: GridPosition;
  size: GridSize;
}

export interface CanvasLayout {
  version: 1;
  instances: WidgetInstance[];
}

export function emptyLayout(): CanvasLayout {
  return { version: 1, instances: [] };
}

/** 12 columns at >= 1024 px, 8 at >= 640 px, 4 below. Rows grow as needed. */
export function columnsFor(width: number): number {
  if (width >= 1024) return 12;
  if (width >= 640) return 8;
  return 4;
}

/** The rendered column span at a breakpoint; the saved size is never changed by it. */
export function renderedSpan(size: GridSize, columns: number): number {
  return Math.min(size.cols, columns);
}

function overlaps(a: GridPosition, aSize: GridSize, b: GridPosition, bSize: GridSize): boolean {
  return (
    a.col < b.col + bSize.cols && b.col < a.col + aSize.cols && a.row < b.row + bSize.rows && b.row < a.row + aSize.rows
  );
}

/** True when the box lies on the grid and overlaps no instance other than `exceptId`. */
export function fits(
  layout: CanvasLayout,
  position: GridPosition,
  size: GridSize,
  columns: number,
  exceptId?: string,
): boolean {
  if (position.col < 0 || position.row < 0 || position.col + size.cols > columns) return false;
  return layout.instances.every(
    (other) => other.id === exceptId || !overlaps(position, size, other.position, other.size),
  );
}

/** The first free position for `size` in row-major order; a size wider than the grid has none. */
export function firstFreePosition(layout: CanvasLayout, size: GridSize, columns: number): GridPosition {
  if (size.cols > columns) throw new RangeError(`a ${size.cols}-column widget does not fit ${columns} columns`);
  for (let row = 0; ; row++) {
    for (let col = 0; col + size.cols <= columns; col++) {
      if (fits(layout, { col, row }, size, columns)) return { col, row };
    }
  }
}

export function addInstance(layout: CanvasLayout, instance: WidgetInstance): CanvasLayout {
  return { version: 1, instances: [...layout.instances, instance] };
}

export function removeInstance(layout: CanvasLayout, id: string): CanvasLayout {
  return { version: 1, instances: layout.instances.filter((instance) => instance.id !== id) };
}

function replace(layout: CanvasLayout, id: string, change: (instance: WidgetInstance) => WidgetInstance): CanvasLayout {
  return {
    version: 1,
    instances: layout.instances.map((instance) => (instance.id === id ? change(instance) : instance)),
  };
}

/** A drop snaps to whole cells; one that overlaps another instance or leaves the grid is rejected. */
export function moveInstance(layout: CanvasLayout, id: string, position: GridPosition, columns: number): CanvasLayout {
  const instance = layout.instances.find((candidate) => candidate.id === id);
  const snapped = { col: Math.round(position.col), row: Math.round(position.row) };
  if (instance === undefined || !fits(layout, snapped, instance.size, columns, id)) return layout;
  return replace(layout, id, (current) => ({ ...current, position: snapped }));
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

/** Clamps each axis to the manifest's bounds and the grid's right edge; an overlap is rejected. */
export function resizeInstance(
  layout: CanvasLayout,
  id: string,
  size: GridSize,
  bounds: WidgetManifest["size"],
  columns: number,
): CanvasLayout {
  const instance = layout.instances.find((candidate) => candidate.id === id);
  if (instance === undefined) return layout;
  const maxCols = Math.min(bounds.max.cols, columns - instance.position.col);
  if (maxCols < bounds.min.cols) return layout;
  const clamped: GridSize = {
    cols: clamp(Math.round(size.cols), bounds.min.cols, maxCols),
    rows: clamp(Math.round(size.rows), bounds.min.rows, bounds.max.rows),
  };
  if (!fits(layout, instance.position, clamped, columns, id)) return layout;
  return replace(layout, id, (current) => ({ ...current, size: clamped }));
}

/** The one way a config changes; the canvas validates it, then unmounts and remounts the instance. */
export function reconfigureInstance(layout: CanvasLayout, id: string, config: unknown): CanvasLayout {
  return replace(layout, id, (current) => ({ ...current, config }));
}
