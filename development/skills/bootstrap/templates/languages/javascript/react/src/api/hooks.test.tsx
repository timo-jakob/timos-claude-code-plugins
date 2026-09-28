import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { QueryWrapper } from "../test/query-wrapper";
import { selectOrderSummaries, useGetOrders } from "./index";

// Example hook test (development-react #958): a component calls a generated
// React Query hook through the ACL barrel, and the request is answered by the
// generated MSW handlers src/test/msw-setup.ts registers — no backend process
// anywhere. msw-setup.ts fails any unmocked request, and the wrapper's
// `retry: false` fails an erroring one at once.
//
// STARTER: after `npm run generate`, point it at one of your spec's hooks. Keep
// importing from the barrel, never from `./generated/`.
function OrderCount() {
  const { data, isError, isSuccess } = useGetOrders({ query: { select: selectOrderSummaries } });
  if (isError) return <p role="alert">Could not load orders</p>;
  if (!isSuccess) return <p>Loading…</p>;
  return <p role="status">{data.length} orders</p>;
}

describe("useGetOrders", () => {
  it("loads orders from the generated MSW handlers (no backend running)", async () => {
    render(<OrderCount />, { wrapper: QueryWrapper });

    // the mock's payload is generated, so assert the shape, not a count
    expect(await screen.findByRole("status")).toHaveTextContent(/^\d+ orders$/);
  });
});
