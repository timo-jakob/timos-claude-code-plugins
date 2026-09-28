// Testing-library setup for a React app (development-react #957), registered via
// `setupFiles` in vitest.config.ts. It adds the jest-dom matchers
// (`toBeInTheDocument`, `toHaveTextContent`, …) to Vitest's `expect`, and unmounts
// whatever each test rendered — testing-library only cleans up automatically when
// Vitest `globals` are on, which the family's config leaves off.
import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

afterEach(() => cleanup());
