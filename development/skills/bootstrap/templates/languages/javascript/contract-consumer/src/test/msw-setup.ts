// MSW wired into vitest so the WHOLE suite runs with no backend process. The
// handlers come straight from orval's generated `*.msw.ts` output — regenerated
// alongside the client, so the mocks can never drift from the pinned contract.
// This file is registered via `setupFiles` in vitest.config.ts.
//
// STARTER: after `npm run generate`, import each target's generated handler
// factory and spread it into `setupServer`. `getOrdersMock` is the factory for
// the seeded `orders` target (orval names it `get<Tag>Mock`).
import { afterAll, afterEach, beforeAll } from "vitest";
import { setupServer } from "msw/node";
import { getOrdersMock } from "../api/generated/orders/orders.msw";

// One server for the whole run, seeded with the generated handlers. Add more
// targets by spreading their `get<Tag>Mock()` here.
export const server = setupServer(...getOrdersMock());

// Fail loudly on any request the handlers don't cover — an unmocked call is a
// test that secretly needs a backend, which defeats the disjunct guarantee.
beforeAll(() => server.listen({ onUnhandledRequest: "error" }));
afterEach(() => server.resetHandlers());
afterAll(() => server.close());
