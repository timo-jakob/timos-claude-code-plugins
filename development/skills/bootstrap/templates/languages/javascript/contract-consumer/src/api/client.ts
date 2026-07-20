// Anti-corruption layer (ACL) — the ONLY module app code imports from for API
// access. It owns two things the generated client deliberately does not:
//   1. the client's runtime CONFIGURATION (base URL, auth/interceptor seam), and
//   2. hand-written, intention-revealing MAPPINGS from the generated wire types
//      to the app's own domain shapes.
// App code imports from `src/api` (see index.ts) and NEVER reaches into
// `src/api/generated/*` — the ESLint boundary rule (eslint.config.js) enforces
// that as a hard gate.
//
// This file is a STARTER with one worked seam. After `npm run generate` has
// produced `src/api/generated/`, replace the illustrative import + mapping below
// with your spec's actual operation and schema. Keep the *shape* — a generated
// call in, a domain type out — so the boundary stays meaningful.

// The generated fetch client + types land under generated/<target>/ once
// `npm run generate` runs. `orders` is the seeded example target name.
import { getOrders } from "./generated/orders/orders";
import type { Order } from "./generated/orders/orders.schemas";

/** Runtime configuration the ACL applies to every call (extend as needed). */
export const apiConfig = {
  baseUrl: "/api",
} as const;

/** The app's own domain shape — intentionally NOT the generated wire type. */
export interface OrderSummary {
  id: string;
  total: number;
}

/**
 * One worked seam: call the generated client and map its wire response into the
 * app's domain shape. App code calls this, never `getOrders` directly.
 */
export async function fetchOrderSummaries(): Promise<OrderSummary[]> {
  const orders = await getOrders();
  return orders.map((o: Order) => ({ id: String(o.id), total: o.total ?? 0 }));
}
