/* eslint-disable react-refresh/only-export-components -- this module's exports are
   the mfe-contract MfeModule (mount/unmount, manifest), not components, so fast refresh does not apply. */
// The widget remote's entry module (#1125): its namespace is the remote's MfeModule
// (mfe-contract/v1) — `manifest`, `mount` and `unmount` are named exports.
// Evaluating it only defines them, so a gallery may import it to read `manifest`.
// A widget owns no route: it reads its config and grid size from the context, and
// leaves the outer URL to the shell. React stays a bare import the shell's import
// map resolves, so every widget on a canvas shares the shell's one React.

import { createRoot, type Root } from "react-dom/client";
import type { GridSize, MfeModule } from "@{{NPM_SCOPE}}/mfe-contract";
import { manifest } from "./manifest";

export { manifest };

/** The config this widget accepts — the shape `manifest.configSchema` describes. */
export interface WidgetConfig {
  title?: string;
}

interface Mounted {
  root: Root | null;
  unsubscribe: (() => void) | null;
}

const mounted = new WeakMap<HTMLElement, Mounted>();

function isWidgetConfig(value: unknown): value is WidgetConfig {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  return !("title" in value) || typeof value.title === "string";
}

function Widget({ config, size }: { config: WidgetConfig; size: GridSize }) {
  return (
    <section data-layout={size.cols >= 2 ? "wide" : "compact"} data-cols={size.cols} data-rows={size.rows}>
      <h2>{config.title ?? manifest.id}</h2>
    </section>
  );
}

export const mount: MfeModule["mount"] = async (el, ctx) => {
  if (ctx.kind !== "widget") throw new Error(`this remote is a widget; it cannot mount as a ${ctx.kind}`);
  // The host validated config against configSchema; the widget still narrows `unknown` itself.
  const config = ctx.config;
  if (!isWidgetConfig(config)) throw new Error(`invalid ${manifest.id} config`);
  // Stop once the shell aborts: it unmounts after every attempt, so nothing is left behind.
  if (ctx.signal.aborted) return;
  // Register before subscribing or rendering, so unmount cleans up a partial mount.
  const state: Mounted = { root: null, unsubscribe: null };
  mounted.set(el, state);
  const root = createRoot(el);
  state.root = root;
  // A resize re-renders the same tree with the new size; it never remounts.
  state.unsubscribe = ctx.onResize((size) => root.render(<Widget config={config} size={size} />));
  root.render(<Widget config={config} size={ctx.size} />);
};

export const unmount: MfeModule["unmount"] = (el) => {
  // Idempotent and safe on a partial mount: a second call finds nothing.
  const state = mounted.get(el);
  mounted.delete(el);
  state?.unsubscribe?.();
  state?.root?.unmount();
};
