// A canvas widget remote: an orders summary tile. Its module namespace is its
// MfeModule — `manifest`, `mount` and `unmount` are named exports. Evaluating
// this module only defines them, so a gallery may import it to read `manifest`.
import type { GridSize, MfeModule, WidgetManifest } from '../index.js';

export const manifest: WidgetManifest = {
  id: 'orders-summary',
  contractMajor: 1,
  configSchema: {
    type: 'object',
    properties: { region: { type: 'string' } },
    required: ['region'],
  },
  size: {
    min: { cols: 1, rows: 1 },
    max: { cols: 4, rows: 2 },
    default: { cols: 2, rows: 1 },
  },
};

const cleanups = new WeakMap<HTMLElement, () => void>();

function isOrdersConfig(value: unknown): value is { region: string } {
  return typeof value === 'object' && value !== null && 'region' in value && typeof value.region === 'string';
}

function render(tile: HTMLElement, size: GridSize): void {
  tile.dataset.layout = size.cols >= 2 ? 'wide' : 'compact';
}

export const mount: MfeModule['mount'] = async (el, ctx) => {
  if (ctx.kind !== 'widget') throw new Error('orders-summary is a widget');
  // ctx is WidgetContext from here on, with no cast. The host validated
  // config against configSchema; the widget still narrows `unknown` itself.
  if (!isOrdersConfig(ctx.config)) throw new Error('invalid orders-summary config');
  const { region } = ctx.config;
  const tile = document.createElement('section');
  tile.style.setProperty('--accent', ctx.theme['--brand-accent'] ?? 'inherit');
  el.append(tile);
  render(tile, ctx.size);
  const unsubscribe = ctx.onResize((size) => render(tile, size));
  cleanups.set(el, () => {
    unsubscribe();
    tile.remove();
  });

  const token = await ctx.auth.getAccessToken();
  if (ctx.signal.aborted) return;
  const res = await fetch(`/api/orders/summary?region=${encodeURIComponent(region)}`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: ctx.signal,
  });
  tile.textContent = String((await res.json()).total);
};

export const unmount: MfeModule['unmount'] = (el) => {
  // Idempotent and safe on a partial mount: a second call finds nothing.
  cleanups.get(el)?.();
  cleanups.delete(el);
};
