// Where the canvas layout is kept (#1939). The store reaches the canvas through the
// same capabilities object the shell takes, extended by type intersection, so a
// server-side store can replace the localStorage default without touching the canvas.

import type { ShellCapabilities } from "../shell/context";
import { emptyLayout, type CanvasLayout } from "./canvas";

export interface CanvasStore {
  load(): Promise<CanvasLayout>;
  save(layout: CanvasLayout): Promise<void>;
}

export type CanvasCapabilities = ShellCapabilities & { canvasStore: CanvasStore };

function isLayout(value: unknown): value is CanvasLayout {
  const candidate = value as Partial<CanvasLayout> | null;
  return typeof candidate === "object" && candidate !== null && candidate.version === 1
    && Array.isArray(candidate.instances);
}

/**
 * Reads and writes `<app>:canvas:v1`. A missing, unparseable or non-version-1 entry
 * loads as an empty canvas, which the next save overwrites.
 */
export function createLocalStorageStore(app: string, storage: () => Storage = () => window.localStorage): CanvasStore {
  const key = `${app}:canvas:v1`;
  return {
    async load(): Promise<CanvasLayout> {
      const raw = storage().getItem(key);
      if (raw === null) return emptyLayout();
      try {
        const parsed: unknown = JSON.parse(raw);
        return isLayout(parsed) ? parsed : emptyLayout();
      } catch {
        return emptyLayout();
      }
    },
    async save(layout: CanvasLayout): Promise<void> {
      storage().setItem(key, JSON.stringify(layout));
    },
  };
}

/** The shell's capabilities plus this app's localStorage store. */
export function withCanvasStore(capabilities: ShellCapabilities): CanvasCapabilities {
  return { ...capabilities, canvasStore: createLocalStorageStore("{{PROJECT_SLUG}}") };
}
