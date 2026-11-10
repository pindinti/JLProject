import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CalendarException } from "../domain/working-calendar";
import { WorkingCalendar } from "../src/WorkingCalendar";

const auth = vi.hoisted(() => ({ authenticatedFetch: vi.fn() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: auth.authenticatedFetch }));

const workspace = { id: "e97c159e-3f7b-4e27-8b1e-38036bf47a3f", name: "JLProject", role: "admin" as const };
const base = `/api/workspaces/${workspace.id}/calendar`;
const holiday: CalendarException = {
  id: "e3aa998a-a2c3-4376-9105-90af0d1dbfe3", kind: "municipal_holiday",
  name: "Feriado sintético", municipality: "Cidade Teste", description: null,
  startDate: "2026-11-09", endDate: "2026-11-09", version: 1
};

beforeEach(() => { vi.clearAllMocks(); });

function readResponses(exceptions: CalendarException[] = []) {
  auth.authenticatedFetch.mockImplementation((path: string) => Promise.resolve(new Response(JSON.stringify(
    path.includes("/history")
      ? { history: { entries: [], nextBeforeVersion: null } }
      : { calendar: { version: 0, exceptions } }
  ), { status: 200 })));
}

describe("working calendar settings", () => {
  it("shows confirmed federal rules and warns when a future optional catalog is unpublished", async () => {
    readResponses();
    render(<WorkingCalendar workspace={workspace} onAccessLost={vi.fn()} initialYear={2026} />);
    expect(await screen.findByText("Dia do Servidor Público federal")).toBeInTheDocument();
    expect(screen.getByText("30/10/2026")).toBeInTheDocument();
    expect(screen.queryByText(/ainda não foram confirmados/)).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Próximo ano" }));
    expect(await screen.findByText(/pontos facultativos federais deste ano ainda não foram cadastrados/)).toBeInTheDocument();
    expect(screen.getByText("26/03/2027")).toBeInTheDocument();
  });

  it("lets an admin create, edit, and remove a local holiday through versioned requests", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    let version = 0;
    let exceptions: CalendarException[] = [];
    auth.authenticatedFetch.mockImplementation((path: string, options?: RequestInit) => {
      const method = options?.method ?? "GET";
      if (path.includes("/history")) return Promise.resolve(new Response(JSON.stringify({
        history: { entries: [], nextBeforeVersion: null }
      }), { status: 200 }));
      if (method === "GET") return Promise.resolve(new Response(JSON.stringify({ calendar: { version, exceptions } }), { status: 200 }));
      const body = JSON.parse(String(options?.body)) as Record<string, unknown>;
      if (method === "POST") {
        expect(body).toMatchObject({ expectedVersion: 0, kind: "municipal_holiday", name: holiday.name,
          municipality: holiday.municipality, startDate: "2026-11-09", endDate: "2026-11-09" });
        exceptions = [holiday];
      } else if (method === "PATCH") {
        expect(body).toMatchObject({ expectedVersion: 1, startDate: "2026-11-10", endDate: "2026-11-10" });
        exceptions = [{ ...holiday, startDate: "2026-11-10", endDate: "2026-11-10", version: 2 }];
      } else if (method === "DELETE") {
        expect(body).toEqual({ expectedVersion: 2 });
        exceptions = [];
      }
      version++;
      return Promise.resolve(new Response(JSON.stringify({ status: "updated", version }), { status: method === "POST" ? 201 : 200 }));
    });

    render(<WorkingCalendar workspace={workspace} onAccessLost={vi.fn()} initialYear={2026} />);
    await screen.findByText("Nenhum feriado local cadastrado para este ano.");
    fireEvent.click(screen.getByRole("button", { name: "Adicionar feriado local" }));
    fireEvent.change(screen.getByLabelText("Nome do feriado"), { target: { value: holiday.name } });
    fireEvent.change(screen.getByLabelText("Município"), { target: { value: holiday.municipality } });
    fireEvent.change(screen.getByLabelText("Data (DD/MM/AAAA)"), { target: { value: "09/11/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    expect(await screen.findByText("Feriado sintético")).toBeInTheDocument();
    expect(screen.getByText(/Nenhuma data do cronograma foi alterada/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Editar" }));
    fireEvent.change(screen.getByLabelText("Data (DD/MM/AAAA)"), { target: { value: "10/11/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    expect(await screen.findByText("Cidade Teste · 10/11/2026")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Remover" }));
    await waitFor(() => expect(screen.getByText("Nenhum feriado local cadastrado para este ano.")).toBeInTheDocument());
    expect(confirmation).toHaveBeenCalledWith("Remover “Feriado sintético” do calendário? O histórico será preservado.");
    expect(auth.authenticatedFetch).toHaveBeenCalledWith(`${base}/exceptions/${holiday.id}`,
      expect.objectContaining({ method: "DELETE" }));
    confirmation.mockRestore();
  });

  it("hides mutation controls from viewers and retains a visible error/retry state", async () => {
    auth.authenticatedFetch.mockImplementation((path: string) => Promise.resolve(new Response(JSON.stringify(
      path.includes("/history") ? { history: { entries: [], nextBeforeVersion: null } } : { error: "unavailable" }
    ), { status: path.includes("/history") ? 200 : 503 })));
    render(<WorkingCalendar workspace={{ ...workspace, role: "viewer" }} onAccessLost={vi.fn()} initialYear={2026} />);
    expect(await screen.findByText("Não foi possível carregar o calendário. Tente novamente.")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Adicionar feriado local" })).not.toBeInTheDocument();
    readResponses([holiday]);
    fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
    expect(await screen.findByText("Feriado sintético")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Editar" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Remover" })).not.toBeInTheDocument();
  });

  it("shows versioned before/after history and keeps a stale edit open for review", async () => {
    auth.authenticatedFetch.mockImplementation((path: string, options?: RequestInit) => {
      if (path.includes("/history")) return Promise.resolve(new Response(JSON.stringify({ history: {
        entries: [{ operationId: "bb111111-1111-4111-8111-111111111111", version: 1,
          action: "updated", actorName: "Test Admin", changedAt: "2026-11-09T13:00:00.000Z",
          before: { ...holiday, startDate: "2026-11-08", endDate: "2026-11-08" }, after: holiday }],
        nextBeforeVersion: null
      } }), { status: 200 }));
      if (options?.method === "PATCH") return Promise.resolve(new Response(JSON.stringify({ code: "stale" }), { status: 409 }));
      return Promise.resolve(new Response(JSON.stringify({ calendar: { version: 1, exceptions: [holiday] } }), { status: 200 }));
    });
    render(<WorkingCalendar workspace={workspace} onAccessLost={vi.fn()} initialYear={2026} />);
    expect(await screen.findByText("Test Admin", { exact: false })).toBeInTheDocument();
    expect(screen.getByText("Antes: Feriado sintético — Cidade Teste · 08/11/2026")).toBeInTheDocument();
    expect(screen.getByText("Depois: Feriado sintético — Cidade Teste · 09/11/2026")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Editar" }));
    fireEvent.change(screen.getByLabelText("Data (DD/MM/AAAA)"), { target: { value: "10/11/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    expect(await screen.findByText("O calendário foi alterado por outra pessoa. Confira os dados e tente novamente.")).toBeInTheDocument();
    expect(screen.getByLabelText("Data (DD/MM/AAAA)")).toHaveValue("10/11/2026");
  });

  it("rejects invalid civil dates locally without sending a mutation", async () => {
    readResponses();
    render(<WorkingCalendar workspace={workspace} onAccessLost={vi.fn()} initialYear={2026} />);
    await screen.findByText("Nenhum feriado local cadastrado para este ano.");
    fireEvent.click(screen.getByRole("button", { name: "Adicionar feriado local" }));
    fireEvent.change(screen.getByLabelText("Nome do feriado"), { target: { value: "Feriado sintético" } });
    fireEvent.change(screen.getByLabelText("Município"), { target: { value: "Cidade Teste" } });
    fireEvent.change(screen.getByLabelText("Data (DD/MM/AAAA)"), { target: { value: "29/02/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    expect(screen.getByText(/Confira os campos e informe datas válidas/)).toBeInTheDocument();
    expect(auth.authenticatedFetch.mock.calls.every((call) => call[1]?.method === undefined)).toBe(true);
  });

  it("shows safe errors for malformed successful API responses", async () => {
    auth.authenticatedFetch.mockResolvedValue(new Response(JSON.stringify({ products: [] }), { status: 200 }));
    render(<WorkingCalendar workspace={workspace} onAccessLost={vi.fn()} initialYear={2026} />);
    expect(await screen.findByText("Não foi possível carregar o calendário. Tente novamente.")).toBeInTheDocument();
    expect(await screen.findByText("Não foi possível carregar o histórico do calendário.")).toBeInTheDocument();
  });
});
