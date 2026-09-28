import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

// Example component test (development-react #957) — the shape every component
// test in this repo follows: render through testing-library, query the way a user
// finds things (by role and accessible name), assert with a jest-dom matcher. It
// defines its own tiny component on purpose rather than testing Vite's App.tsx,
// whose content changes between create-vite releases. Replace it with real tests.
function Greeting({ name }: { name: string }) {
  return <h1>Hello, {name}!</h1>;
}

describe("Greeting", () => {
  it("renders the greeting as a heading", () => {
    render(<Greeting name="Ada" />);

    expect(screen.getByRole("heading", { name: "Hello, Ada!" })).toBeInTheDocument();
  });
});
