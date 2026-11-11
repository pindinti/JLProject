import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
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
    fireEvent.click(screen.getByRole("button", { name: "Abrir calendário para Data (DD/MM/AAAA)" }));
    const datePicker = await screen.findByRole("dialog", { name: "Escolher data para Data (DD/MM/AAAA)" });
    fireEvent.click(within(datePicker).getByRole("button", { name: "segunda-feira, 9 de novembro de 2026" }));
    expect(auth.authenticatedFetch.mock.calls.some(([, options]) => options?.method === "POST")).toBe(false);
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

  it("shows compact before/after history and keeps a stale edit open for review", async () => {
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
    await screen.findByText("Feriado sintético");
    expect(auth.authenticatedFetch.mock.calls.some(([path]) => String(path).includes("/history"))).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Ver log de alterações" }));
    const dialog = await screen.findByRole("dialog", { name: "Histórico do calendário" });
    expect(within(dialog).getByText(/Test Admin/)).toBeInTheDocument();
    expect(within(dialog).getByText("Alterado")).toBeInTheDocument();
    expect(within(dialog).queryByText("Versão 1")).not.toBeInTheDocument();
    const header = dialog.querySelector(".calendar-history__card-header");
    expect(header?.querySelector(".calendar-history__identity")).toHaveTextContent("Feriado sintético");
    expect(header?.querySelector(".calendar-history__identity")).toHaveTextContent("Test Admin");
    expect(header?.querySelector("time")).toHaveAttribute("dateTime", "2026-11-09T13:00:00.000Z");
    expect(header?.querySelector(".calendar-history__badge")).toHaveTextContent("Alterado");
    fireEvent.click(within(dialog).getByText("Ver detalhes"));
    expect(within(dialog).getByText("Feriado sintético — Cidade Teste · 08/11/2026")).toBeInTheDocument();
    expect(within(dialog).getByText("Feriado sintético — Cidade Teste · 09/11/2026")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Fechar histórico" }));
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

  it("discards a picker-selected working-calendar date when the form is canceled", async () => {
    readResponses();
    render(<WorkingCalendar workspace={workspace} onAccessLost={vi.fn()} initialYear={2026} />);
    await screen.findByText("Nenhum feriado local cadastrado para este ano.");
    fireEvent.click(screen.getByRole("button", { name: "Adicionar feriado local" }));
    fireEvent.click(screen.getByRole("button", { name: "Abrir calendário para Data (DD/MM/AAAA)" }));
    const datePicker = await screen.findByRole("dialog", { name: "Escolher data para Data (DD/MM/AAAA)" });
    fireEvent.click(within(datePicker).getByRole("button", { current: "date" }));
    fireEvent.click(screen.getByRole("button", { name: "Cancelar" }));
    expect(screen.queryByRole("textbox", { name: "Data (DD/MM/AAAA)" })).not.toBeInTheDocument();
    expect(auth.authenticatedFetch.mock.calls.some(([, options]) => options?.method === "POST" || options?.method === "PATCH"))
      .toBe(false);
  });

  it("shows safe errors for malformed successful API responses", async () => {
    auth.authenticatedFetch.mockResolvedValue(new Response(JSON.stringify({ products: [] }), { status: 200 }));
    render(<WorkingCalendar workspace={workspace} onAccessLost={vi.fn()} initialYear={2026} />);
    expect(await screen.findByText("Não foi possível carregar o calendário. Tente novamente.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Ver log de alterações" }));
    expect(await screen.findByText("Não foi possível carregar o histórico do calendário.")).toBeInTheDocument();
    auth.authenticatedFetch.mockResolvedValueOnce(new Response(JSON.stringify({
      history: { entries: [], nextBeforeVersion: null }
    }), { status: 200 }));
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Tentar novamente" }));
    expect(await screen.findByText("Nenhuma alteração do calendário registrada.")).toBeInTheDocument();
  });

  it("opens an empty read-only history dialog and restores focus after Escape", async () => {
    readResponses();
    render(<WorkingCalendar workspace={{ ...workspace, role: "viewer" }} onAccessLost={vi.fn()} initialYear={2026} />);
    await screen.findByText("Nenhum feriado local cadastrado para este ano.");
    const trigger = screen.getByRole("button", { name: "Ver log de alterações" });
    expect(auth.authenticatedFetch.mock.calls.some(([path]) => String(path).includes("/history"))).toBe(false);
    trigger.focus();
    fireEvent.click(trigger);
    const dialog = await screen.findByRole("dialog", { name: "Histórico do calendário" });
    expect(await within(dialog).findByText("Nenhuma alteração do calendário registrada.")).toBeInTheDocument();
    expect(dialog).toHaveAttribute("aria-modal", "true");
    fireEvent.keyDown(dialog, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    await waitFor(() => expect(trigger).toHaveFocus());
  });

  it("paginates newest-first create, update, and removal events with expandable snapshots", async () => {
    const closure: CalendarException = { ...holiday, id: "d3aa998a-a2c3-4376-9105-90af0d1dbfe3",
      kind: "company_shutdown", name: null, municipality: null, description: "Recesso sintético",
      startDate: "2026-12-24", endDate: "2026-12-31" };
    const entries = [
      { operationId: "a1111111-1111-4111-8111-111111111111", version: 3, action: "removed",
        actorName: "Test Admin", changedAt: "2026-11-10T15:00:00.000Z", before: holiday, after: holiday },
      { operationId: "b1111111-1111-4111-8111-111111111111", version: 2, action: "updated",
        actorName: "Test Editor", changedAt: "2026-11-09T15:00:00.000Z",
        before: { ...closure, endDate: "2026-12-30" }, after: closure },
      { operationId: "c1111111-1111-4111-8111-111111111111", version: 1, action: "created",
        actorName: "Test Admin", changedAt: "2026-11-08T15:00:00.000Z", before: null, after: closure }
    ];
    auth.authenticatedFetch.mockImplementation((path: string) => Promise.resolve(new Response(JSON.stringify(
      path.includes("/history") ? { history: path.includes("beforeVersion=2")
        ? { entries: [entries[2]], nextBeforeVersion: null }
        : { entries: entries.slice(0, 2), nextBeforeVersion: 2 } }
        : { calendar: { version: 3, exceptions: [] } }
    ), { status: 200 })));
    render(<WorkingCalendar workspace={workspace} onAccessLost={vi.fn()} initialYear={2026} />);
    await screen.findByText("Nenhum feriado local cadastrado para este ano.");
    fireEvent.click(screen.getByRole("button", { name: "Ver log de alterações" }));
    const dialog = await screen.findByRole("dialog", { name: "Histórico do calendário" });
    await waitFor(() => expect(dialog.querySelectorAll(".calendar-history > li")).toHaveLength(2));
    fireEvent.click(within(dialog).getByRole("button", { name: "Carregar alterações anteriores" }));
    await waitFor(() => expect(dialog.querySelectorAll(".calendar-history > li")).toHaveLength(3));
    const cards = [...dialog.querySelectorAll(".calendar-history > li")];
    expect(cards.map((card) => card.querySelector(".calendar-history__badge")?.textContent))
      .toEqual(["Removido", "Alterado", "Adicionado"]);
    expect(within(dialog).queryByText(/Versão \d+/)).not.toBeInTheDocument();
    expect(auth.authenticatedFetch).toHaveBeenCalledWith(`${base}/history?beforeVersion=2`, { cache: "no-store" });
    fireEvent.click(within(cards[0] as HTMLElement).getByText("Ver detalhes"));
    expect(within(cards[0] as HTMLElement).getByText(/Removido: Feriado sintético/)).toBeInTheDocument();
    fireEvent.click(within(cards[1] as HTMLElement).getByText("Ver detalhes"));
    expect(within(cards[1] as HTMLElement).getByText(/Recesso sintético · 24\/12\/2026 a 30\/12\/2026/)).toBeInTheDocument();
    expect(within(cards[1] as HTMLElement).getByText(/Recesso sintético · 24\/12\/2026 a 31\/12\/2026/)).toBeInTheDocument();
  });

  it("reports authorization loss when the history request is denied", async () => {
    const onAccessLost = vi.fn();
    auth.authenticatedFetch.mockImplementation((path: string) => Promise.resolve(
      path.includes("/history") ? new Response(null, { status: 403 })
        : new Response(JSON.stringify({ calendar: { version: 0, exceptions: [] } }), { status: 200 })
    ));
    render(<WorkingCalendar workspace={workspace} onAccessLost={onAccessLost} initialYear={2026} />);
    await screen.findByText("Nenhum feriado local cadastrado para este ano.");
    fireEvent.click(screen.getByRole("button", { name: "Ver log de alterações" }));
    await waitFor(() => expect(onAccessLost).toHaveBeenCalledOnce());
  });
});
