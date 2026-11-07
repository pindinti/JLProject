import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { App } from "../src/App";

describe("App", () => {
  it("renders the Portuguese foundation shell", () => {
    render(<App />);

    expect(screen.getByText("JLProject")).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { name: "Gerenciamento de Projetos" })
    ).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("Sistema em desenvolvimento");
  });
});
