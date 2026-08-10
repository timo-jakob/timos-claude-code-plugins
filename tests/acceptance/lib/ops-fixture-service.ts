// The fixture SERVICE the Node ops-api acceptance cases (#936) run against.
//
// It is the adopter's half of the contract and nothing more: it imports the
// shipped payload exactly as `README.md` tells a service to, and wires one
// OpsConfig per scenario. Everything the cases assert therefore comes from the
// template, not from here — a fixture that reimplemented a route would prove
// nothing about the payload.
//
// $SCENARIO picks the wiring. The data is the story's own use_case: version
// 1.4.2, commit 9e11997, a deprecated major 1 sunsetting 2027-01-31 beside an
// active major 2, and the direct dependencies `orders-db` (hard) and
// `pricing-api` (soft).
import { serve, type Dependency, type DependencyHealthSource, type OpsConfig } from "./ops/opsApi.js";

/**
 * A snapshot-returning source, as the seam's contract requires: a hand-written
 * implementation must hand back a freshly built object every call rather than its
 * own live registry.
 */
function source(components: Record<string, Dependency>): DependencyHealthSource {
  return { components: () => structuredClone(components) };
}

const PRICING_API_DOWN: Record<string, Dependency> = {
  "pricing-api": {
    status: "down",
    kind: "soft",
    breaker: "open",
    since: "2026-08-10T09:12:44Z",
  },
};

const ORDERS_DB_DOWN: Record<string, Dependency> = {
  "orders-db": {
    status: "down",
    kind: "hard",
    breaker: "open",
    since: "2026-08-10T09:12:44Z",
  },
};

const scenario = process.env.SCENARIO ?? "unwired";
const config: OpsConfig = {};

switch (scenario) {
  // The seam left unwired — the state of every repo that has not adopted #1145.
  case "unwired":
    break;

  case "lifecycle":
    config.servedMajors = [
      { major: 1, lifecycle: "deprecated", sunset: "2027-01-31" },
      { major: 2, lifecycle: "active" },
    ];
    break;

  case "soft-down":
    config.dependencies = source(PRICING_API_DOWN);
    break;

  case "hard-down":
    config.dependencies = source(ORDERS_DB_DOWN);
    break;

  // A hard dependency is down while the service's own hook still claims "ok".
  // The components' FLOOR must win — under-reporting is the conformance failure.
  case "under-report":
    config.internalStatus = () => "ok";
    config.dependencies = source(ORDERS_DB_DOWN);
    break;

  // Malformed lifecycle tables — each must fail at STARTUP, before anything binds.
  case "deprecated-no-sunset":
    config.servedMajors = [{ major: 1, lifecycle: "deprecated" }];
    break;

  default:
    throw new Error(`ops fixture: unknown SCENARIO "${scenario}"`);
}

const running = await serve(config);
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => {
    void running.close().then(() => {
      process.exit(0);
    });
  });
}
// The readiness signal the harness waits on before curling anything.
console.log(`ops fixture listening scenario=${scenario}`);
