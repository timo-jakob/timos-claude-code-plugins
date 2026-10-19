// The shell-served `react-dom` module (#1939), /shared/react-dom.js. Named exports
// are listed because react-dom ships as CommonJS.

import * as ReactDOM from "react-dom";

export default ReactDOM;
export const {
  createPortal,
  flushSync,
  preconnect,
  prefetchDNS,
  preinit,
  preinitModule,
  preload,
  preloadModule,
  requestFormReset,
  unstable_batchedUpdates,
  useFormState,
  useFormStatus,
  version,
} = ReactDOM;
