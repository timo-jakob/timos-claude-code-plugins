// The widget remote's manifest (#1125): what the widget declares about itself
// before it is ever mounted. Framework-free, so a gallery reads it without React.
// The canvas validates each saved instance's config against `configSchema` with
// a JSON-Schema subset (#1939), and the user resizes within `size.min..max`.

import type { WidgetManifest } from "@{{NPM_SCOPE}}/mfe-contract";

export const manifest: WidgetManifest = {
  id: "{{PROJECT_SLUG}}",
  contractMajor: 1,
  configSchema: {
    type: "object",
    properties: { title: { type: "string" } },
    additionalProperties: false,
  },
  size: {
    min: { cols: 1, rows: 1 },
    max: { cols: 4, rows: 3 },
    default: { cols: 2, rows: 1 },
  },
};
