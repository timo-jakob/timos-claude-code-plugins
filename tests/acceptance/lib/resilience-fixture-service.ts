// The fixture SERVICE the Node resilience acceptance cases (#1145) run against.
//
// It is the adopter's half of the contract and nothing more: it wires the shipped
// ops-api payload and the shipped resilience payload together exactly as the
// resilience README's "wire it at startup" block tells a service to. Everything
// the cases assert therefore comes from the templates, not from here.
//
// One compiled entrypoint, two roles, so the harness builds ONE tree:
//
//   ROLE=upstream  a stand-in for the direct dependencies — GET /prices/<sku>
//                  (404 for a sku starting "missing-") and GET /orders/<id>. The
//                  cases KILL this process to take a dependency down, which is the
//                  real outage shape: connection refused, not a scripted 503.
//   ROLE=service   (default) the service: the ops surface on $OPS_PORT, and an app
//                  port ($APP_PORT) whose routes call the dependencies through the
//                  catalog, so curl can drive real traffic through the breakers.
//
// $SCENARIO picks the wiring: `wired` passes DependencyHealth as
// OpsConfig.dependencies; `unwired` leaves the seam unset (ops-api v1.0).
//
// The data is the story's own use_case: orders-db (hard) and pricing-api (soft).
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import { serve } from "./ops/opsApi.js";
import { DependencyCatalog, notADependency, type CallOptions } from "./resilience/dependencyCatalog.js";
import { DependencyHealth } from "./resilience/dependencyHealth.js";
import { PricingApiClient } from "./resilience/pricingApiClient.js";

function port(name: string): number {
  const raw = process.env[name];
  const value = Number(raw);
  if (raw === undefined || !Number.isInteger(value) || value <= 0) {
    throw new Error(`resilience fixture: ${name} must be a port, got "${raw ?? ""}"`);
  }
  return value;
}

function json(res: ServerResponse, code: number, body: unknown): void {
  const text = JSON.stringify(body);
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Content-Length", Buffer.byteLength(text));
  res.end(text);
}

function listen(handler: (req: IncomingMessage, res: ServerResponse) => void, at: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const server = createServer(handler);
    server.once("error", reject);
    server.listen(at, "127.0.0.1", () => resolve());
  });
}

// ---- ROLE=upstream ------------------------------------------------------------

async function upstream(): Promise<void> {
  // How many dependency requests actually ARRIVED — what "un-retried" is measured
  // against. /stats is the harness's, never called through the catalog.
  let served = 0;
  await listen((req, res) => {
    const path = req.url ?? "/";
    if (path === "/stats") {
      json(res, 200, { served });
      return;
    }
    const price = /^\/prices\/([^/?]+)$/.exec(path);
    if (price !== null) {
      served += 1;
      const sku = decodeURIComponent(price[1] ?? "");
      if (sku.startsWith("missing-")) {
        json(res, 404, { error: "no such sku", sku });
        return;
      }
      json(res, 200, { sku, cents: 1299, currency: "EUR" });
      return;
    }
    const order = /^\/orders\/([^/?]+)$/.exec(path);
    if (order !== null) {
      served += 1;
      json(res, 200, { id: order[1], status: "confirmed" });
      return;
    }
    json(res, path === "/healthz" ? 200 : 404, { path });
  }, port("UPSTREAM_PORT"));
  console.log("resilience fixture upstream listening");
}

// ---- ROLE=service -------------------------------------------------------------

/** The adopter's own orders-db client — the worked example's shape, a second time. */
class OrdersDbClient {
  readonly #catalog: DependencyCatalog;
  readonly #base: string;

  constructor(catalog: DependencyCatalog, base: string) {
    catalog.requireDeclared("orders-db");
    this.#catalog = catalog;
    this.#base = base;
  }

  order(id: string, options: CallOptions = {}): Promise<{ available: boolean; order?: unknown }> {
    return this.#catalog.call<{ available: boolean; order?: unknown }>(
      "orders-db",
      async (signal) => {
        const response = await fetch(`${this.#base}/orders/${encodeURIComponent(id)}`, { signal });
        if (response.status >= 400 && response.status < 500) {
          await response.body?.cancel();
          throw notADependency(new Error(`orders-db: status ${response.status}`));
        }
        if (!response.ok) {
          await response.body?.cancel();
          throw new Error(`orders-db: status ${response.status}`);
        }
        return { available: true, order: (await response.json()) as unknown };
      },
      () => ({ available: false }),
      options,
    );
  }
}

async function service(): Promise<void> {
  const scenario = process.env.SCENARIO ?? "wired";
  if (scenario !== "wired" && scenario !== "unwired") {
    throw new Error(`resilience fixture: unknown SCENARIO "${scenario}"`);
  }

  // The README's startup order, verbatim: load, health view BEFORE traffic, every
  // client claims its dependency, THEN the both-sides guard, THEN serve.
  const catalog = DependencyCatalog.load();
  const dependencies = new DependencyHealth(catalog);
  const pricing = new PricingApiClient(catalog);
  const orders = new OrdersDbClient(catalog, process.env.ORDERS_DB_URL ?? "");
  catalog.requireAllDeclaredGuarded();

  const running = await serve({
    gitSha: "9e11997",
    ...(scenario === "wired" ? { dependencies } : {}),
  });

  await listen((req, res) => {
    const path = req.url ?? "/";
    const price = /^\/price\/([^/?]+)$/.exec(path);
    const order = /^\/order\/([^/?]+)$/.exec(path);
    // The fallback RESOLVES, so neither route can reject on an outage — which is
    // exactly the claim tc-error-open-breaker-fast-fails-without-crashing makes.
    // The catch is for a programming error only, and answers rather than crashing.
    const work =
      price !== null
        ? pricing.price(decodeURIComponent(price[1] ?? "")).then((r) =>
            r.available ? { available: true, price: r.price } : { available: false },
          )
        : order !== null
          ? orders.order(decodeURIComponent(order[1] ?? ""))
          : undefined;
    if (work === undefined) {
      json(res, 404, { path });
      return;
    }
    work.then(
      (body) => json(res, 200, body),
      (err: unknown) => json(res, 500, { error: String(err) }),
    );
  }, port("APP_PORT"));

  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.on(signal, () => {
      void running.close().then(() => {
        process.exit(0);
      });
    });
  }
  // The readiness signal the harness waits on before curling anything.
  console.log(`resilience fixture listening scenario=${scenario}`);
}

if (process.env.ROLE === "upstream") {
  await upstream();
} else {
  await service();
}
