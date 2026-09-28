// A shell mounting one remote into an outlet: a page on a route change, or a
// widget into a canvas slot. It honours the abort rule — unmount always runs
// after a mount attempt, whatever became of it.
import type {
  AuthContext,
  FlagContext,
  MfeContext,
  MfeModule,
  PageContext,
  ThemeTokens,
  WidgetContext,
} from '../index.js';
import * as ordersPage from './page-remote.js';
import * as ordersSummary from './widget-remote.js';

// A remote's module namespace IS its MfeModule: the shell takes `mount`,
// `unmount` and `manifest` from what the import resolves to, never from a
// default export. The two worked remotes are checked against that here.
export function loadRemote(url: string): Promise<MfeModule> {
  return import(url);
}
export const workedRemotes: MfeModule[] = [ordersPage, ordersSummary];

declare const auth: AuthContext;
declare const flags: FlagContext;
declare const theme: ThemeTokens;

// A mount attempt. `teardown` exists from the moment the attempt starts, so the
// shell can hold it while the mount is still loading.
export interface Mounted {
  /** Settles when mount does; rejects when mount rejects. */
  settled: Promise<void>;
  /** Run when the route or slot changes: aborts, waits, then unmounts. */
  teardown(): Promise<void>;
}

export function mountPage(
  remote: MfeModule,
  outlet: HTMLElement,
  basePath: string,
  controller: AbortController,
): Mounted {
  const base: MfeContext = { auth, flags, theme, signal: controller.signal };
  const ctx: PageContext = {
    ...base,
    kind: 'page',
    basePath,
    onNavigate: (path) => history.pushState(null, '', path),
  };
  return attempt(remote, outlet, ctx, controller);
}

export function mountWidget(
  remote: MfeModule,
  slot: HTMLElement,
  config: unknown,
  controller: AbortController,
): Mounted {
  // A widget states the major it targets; refuse one this shell does not
  // implement before mounting anything.
  const manifest = remote.manifest;
  if (!manifest || manifest.contractMajor !== 1) {
    throw new Error('not a mfe-contract/v1 widget');
  }
  const ctx: WidgetContext = {
    auth,
    flags,
    theme,
    signal: controller.signal,
    kind: 'widget',
    config,
    size: manifest.size.default,
    onResize: () => () => {},
  };
  return attempt(remote, slot, ctx, controller);
}

// Every path ends in unmount: a rejected mount unmounts at once, and teardown —
// aborting a mount still in flight, or ending a settled one — waits for the
// mount to settle and then unmounts. unmount runs at most once per attempt.
function attempt(
  remote: MfeModule,
  el: HTMLElement,
  ctx: PageContext | WidgetContext,
  controller: AbortController,
): Mounted {
  let unmounted: Promise<void> | undefined;
  const unmountOnce = () => (unmounted ??= Promise.resolve().then(() => remote.unmount(el)));
  const settled = Promise.resolve()
    .then(() => remote.mount(el, ctx))
    .catch(async (err: unknown) => {
      await unmountOnce();
      throw err;
    });
  const teardown = async () => {
    controller.abort();
    await settled.catch(() => {});
    await unmountOnce();
  };
  return { settled, teardown };
}
