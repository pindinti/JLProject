import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Products } from "../src/Products";

const auth = vi.hoisted(() => ({ fetch: vi.fn() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: auth.fetch }));
vi.mock("../src/ScheduleEditor", () => ({ ScheduleEditor: ({ onBack }: { onBack: () => void }) =>
  <button type="button" onClick={onBack}>Voltar aos produtos</button> }));

const workspace = { id: "e97c159e-3f7b-4e27-8b1e-38036bf47a3f", name: "Synthetic workspace", role: "viewer" as const };
const product = { id: "e3aa998a-a2c3-4376-9105-90af0d1dbfe3", workspaceId: workspace.id,
  name: "Synthetic product", description: null, active: true, version: 1 };

beforeEach(() => {
  window.history.replaceState(null, "", "/produtos");
  auth.fetch.mockReset();
  auth.fetch.mockImplementation(async (path: string) => {
    if (path.endsWith("/executive-gantt")) return new Response(JSON.stringify({ products: [] }), { status: 200 });
    if (path.endsWith("/hierarchy")) return new Response(JSON.stringify({ hierarchy: { disciplines: [] } }), { status: 200 });
    return new Response(JSON.stringify({ products: [product] }), { status: 200 });
  });
});

describe("Home Executive Gantt integration", () => {
  it("keeps product-card navigation and refreshes the projection after returning from a schedule", async () => {
    render(<Products workspace={workspace} userId={null} onAccessLost={vi.fn()} />);
    expect(await screen.findByRole("link", { name: /Synthetic product/ })).toBeInTheDocument();
    await waitFor(() => expect(auth.fetch.mock.calls.filter(([path]) => String(path).endsWith("/executive-gantt")))
      .toHaveLength(1));
    fireEvent.click(screen.getByRole("link", { name: /Synthetic product/ }));
    expect(window.location.pathname).toBe(`/produtos/${product.id}/cronograma`);
    fireEvent.click(screen.getByRole("button", { name: "Voltar aos produtos" }));
    expect(window.location.pathname).toBe("/produtos");
    await waitFor(() => expect(auth.fetch.mock.calls.filter(([path]) => String(path).endsWith("/executive-gantt")))
      .toHaveLength(2));
    expect(screen.getByRole("link", { name: /Synthetic product/ })).toBeInTheDocument();
  });
});
