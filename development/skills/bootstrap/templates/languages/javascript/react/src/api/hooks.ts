// React Query binding (development-react #958) — part of the anti-corruption
// layer, so it may reach into `./generated/` where app code may not. orval
// generates the TanStack Query hooks alongside the operation functions and the
// MSW handlers (`client: "react-query"` in orval.config.ts); this module only
// decides which of them app code sees.
//
// RE-EXPORT, never wrap. A generated hook for an operation the spec marks
// `deprecated: true` carries a `@deprecated` JSDoc, and a re-export keeps the
// symbol — and that JSDoc — intact, so `@typescript-eslint/no-deprecated` warns
// at the component that calls it. A wrapper (`export function useOrders() {
// return useGetOrders(); }`) would swallow the warning into its own body.
//
// STARTER: after `npm run generate`, re-export your spec's hooks. `orders` is
// the seeded example target name; rename it with the rest of the scaffold.
export { useGetOrders } from "./generated/orders/orders";

import type { Order } from "./generated/orders/orders.schemas";
import type { OrderSummary } from "./client";

/**
 * One worked, domain-mapped seam, the hook-side twin of client.ts's
 * `fetchOrderSummaries`: pass it as the query's `select` so a component gets the
 * app's own domain shape while still calling the generated hook itself.
 *
 *   const { data } = useGetOrders({ query: { select: selectOrderSummaries } });
 *
 * It takes the same response shape `fetchOrderSummaries` maps; if your generated
 * operation returns an envelope instead, adapt both seams together.
 */
export function selectOrderSummaries(orders: Order[]): OrderSummary[] {
  return orders.map((o) => ({ id: String(o.id), total: o.total ?? 0 }));
}
