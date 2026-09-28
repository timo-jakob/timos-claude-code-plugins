// A route-owned page remote: the orders area, mounted at the prefix the shell
// delegates (e.g. /orders). Its module namespace is its MfeModule — `mount` and
// `unmount` are named exports.
import type { MfeModule } from '../index.js';

const cleanups = new WeakMap<HTMLElement, () => void>();

export const mount: MfeModule['mount'] = async (el, ctx) => {
  if (ctx.kind !== 'page') throw new Error('orders is a page remote');
  // ctx is PageContext from here on, with no cast.
  const list = document.createElement('ul');
  el.append(list);
  const onClick = () => ctx.onNavigate('/customers/42');
  list.addEventListener('click', onClick);
  // Register cleanup BEFORE the first await: unmount runs after any mount
  // attempt, including one aborted while the fetch below is in flight.
  cleanups.set(el, () => {
    list.removeEventListener('click', onClick);
    list.remove();
  });

  const token = await ctx.auth.getAccessToken();
  if (ctx.signal.aborted) return;
  const res = await fetch(`/api${ctx.basePath}`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: ctx.signal,
  });
  const orders: Array<{ id: string }> = await res.json();
  for (const order of orders) {
    const item = document.createElement('li');
    item.textContent = order.id;
    list.append(item);
  }
  list.dataset.greeting = `Hello, ${ctx.auth.claims.displayName}`;
  list.hidden = !ctx.flags.isEnabled('orders-list');
};

export const unmount: MfeModule['unmount'] = (el) => {
  // Idempotent and safe on a partial mount: a second call finds nothing.
  cleanups.get(el)?.();
  cleanups.delete(el);
};
