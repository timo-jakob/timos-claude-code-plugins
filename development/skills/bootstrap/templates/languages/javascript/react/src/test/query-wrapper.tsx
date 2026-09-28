import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";

// Test-only React Query provider (development-react #958). Pass it as
// testing-library's `wrapper` so a component under test can call a query hook:
//
//   render(<Orders />, { wrapper: QueryWrapper });
//
// Every render gets its own QueryClient, so no cached data leaks between tests.
// `retry: false` makes an MSW error handler fail the test at once instead of
// after React Query's three default retries, and a test never refetches because
// jsdom's window regained focus.
function createTestQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: { retry: false, refetchOnWindowFocus: false },
    },
  });
}

export function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(createTestQueryClient);
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}
