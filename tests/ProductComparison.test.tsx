import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ComparisonSchedule, ProductComparison } from "../worker/product-comparison";
import { ProductComparisonPage } from "../src/ProductComparison";
import { Products } from "../src/Products";

const auth = vi.hoisted(() => ({ fetch: vi.fn<(path: string, init?: RequestInit) => Promise<Response>>() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: auth.fetch }));

const workspace = { id: "e97c159e-3f7b-4e27-8b1e-38036bf47a3f", name: "Workspace", role: "viewer" as const };
const leftId = "e3aa998a-a2c3-4376-9105-90af0d1dbfe3";
const rightId = "d5555555-5555-4555-8555-555555555555";
const studyId = "a5555555-5555-4555-8555-555555555555";

function schedule(id: string, status: ComparisonSchedule["product"]["status"], name: string): ComparisonSchedule {
  return { product: { id, status, name, workspaceId: workspace.id, description: null,
    active: status !== "arquivado", version: 1, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z" },
  cursor: { historyWatermark: "4", scheduleVersion: "1" }, hierarchy: { productId: id, rootActivities: [], disciplines: [] }, targets: [] };
}

const current = schedule(leftId, "vigente", "Torre Norte");
const archived = schedule(rightId, "arquivado", "Torre Sul");
const study = schedule(studyId, "em_estudo", "Alternativa Leste");
const products = [current.product, archived.product, study.product];

function comparison(): ProductComparison {
  const left = structuredClone(current);
  const right = structuredClone(archived);
  for (const [side, prefix, end] of [[left, "left", "2028-03-01"], [right, "right", "2028-03-03"]] as const) {
    const id = side.product.id;
    side.hierarchy.disciplines.push({ id: `${prefix}-discipline`, productId: id, name: "Projeto",
      shortCode: "PR", color: "#888888", displayOrder: 0, description: null, version: 1,
      stages: [{ id: `${prefix}-stage`, disciplineId: `${prefix}-discipline`, displayName: "Detalhamento", code: "DE",
        color: "#888888", displayOrder: 0, version: 1, plannedStart: "2028-02-29", plannedEnd: null,
        derivedStart: "2028-02-28", derivedEnd: end,
        activities: [{ id: `${prefix}-activity`, stageId: `${prefix}-stage`, name: "Conferência",
          activityType: null, plannedStart: "2028-02-29", plannedEnd: end, displayOrder: 0, notes: null,
          colorOverride: null, version: 1, planningMode: "working_days", workingDayDuration: prefix === "left" ? 2 : 4,
          planningCalendarVersion: 3 }] }] });
    side.hierarchy.rootActivities.push({ id: `${prefix}-root`, stageId: null, name: "Abertura", activityType: null,
      plannedStart: null, plannedEnd: null, displayOrder: 0, notes: null, colorOverride: null,
      version: 1, planningMode: "manual", workingDayDuration: null, planningCalendarVersion: null });
    side.targets.push({ id: `${prefix}-target`, name: "Entrega", description: null, color: "#888888",
      targetDate: end, operationalDate: null, displayOrder: 0, version: 1 });
  }
  right.hierarchy.rootActivities.push({ ...right.hierarchy.rootActivities[0], id: "duplicate", displayOrder: 1 });
  left.hierarchy.rootActivities.push({ ...left.hierarchy.rootActivities[0], id: "left-only", name: "Reunião inicial", displayOrder: 1 });
  right.targets.push({ ...right.targets[0], id: "right-only", name: "Aprovação", displayOrder: 1 });
  return { left, right };
}

function openPage(overrides: Partial<React.ComponentProps<typeof ProductComparisonPage>> = {}) {
  return render(<ProductComparisonPage initialProductId={leftId} products={products} workspaceId={workspace.id}
    catalogState="ready" onAccessLost={vi.fn()} onBack={vi.fn()} onRetryCatalog={vi.fn()} {...overrides} />);
}

function chooseAndCompare(id = rightId) {
  fireEvent.change(screen.getByRole("combobox", { name: "Produto B" }), { target: { value: id } });
  fireEvent.click(screen.getByRole("button", { name: "Comparar" }));
}

function openPairing(label: string) {
  fireEvent.click(screen.getByRole("button", { name: `Parear ${label} do Produto A` }));
  return within(screen.getByRole("dialog", { name: "Parear itens" }));
}

function confirmPairing(label: string, candidateId: string) {
  const dialog = openPairing(label);
  fireEvent.change(dialog.getByRole("combobox", { name: "Item do Produto B" }), { target: { value: candidateId } });
  fireEvent.click(dialog.getByRole("button", { name: "Confirmar pareamento" }));
}

beforeEach(() => {
  auth.fetch.mockReset();
  window.history.replaceState(null, "", "/produtos");
});

describe("product comparison UI", () => {
  it("opens the read-only product action for a viewer, preselects A, and allows any distinct status in either slot", async () => {
    auth.fetch.mockImplementation(async (path) => {
      if (path.endsWith("/executive-gantt")) return Response.json({ products: [] });
      if (path.endsWith("/hierarchy")) return Response.json({ hierarchy: { disciplines: [] } });
      return Response.json({ products });
    });
    render(<Products workspace={workspace} userId={null} onAccessLost={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "Configurações do produto: Torre Norte" }));
    expect(screen.queryByText("Clonar produto")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("link", { name: "Comparar com outro produto" }));
    expect(window.location.pathname).toBe(`/produtos/${leftId}/comparar`);
    expect(await screen.findByRole("heading", { name: "Comparação de cronogramas" })).toHaveFocus();
    const a = await screen.findByRole("combobox", { name: "Produto A" });
    const b = screen.getByRole("combobox", { name: "Produto B" });
    expect(a).toHaveValue(leftId);
    expect(b).toHaveValue("");
    expect(within(b).getByRole("option", { name: /Torre Sul.*Arquivado/ })).toBeInTheDocument();
    expect(within(b).getByRole("option", { name: /Alternativa Leste.*Em estudo/ })).toBeInTheDocument();
    expect(within(b).queryByRole("option", { name: /Torre Norte/ })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Comparar" })).toBeDisabled();
    fireEvent.change(a, { target: { value: studyId } });
    expect(within(b).getByRole("option", { name: /Torre Norte.*Vigente/ })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Voltar aos produtos" }));
    expect(window.location.pathname).toBe("/produtos");
    expect(await screen.findByRole("link", { name: /Torre Norte/ })).toBeInTheDocument();
  });

  it("renders both products, hierarchical differences, civil dates, and separate targets without write controls", async () => {
    auth.fetch.mockResolvedValue(Response.json({ comparison: comparison() }));
    openPage();
    chooseAndCompare();
    expect(await screen.findByRole("heading", { name: "Torre Norte" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Torre Sul" })).toBeInTheDocument();
    expect(screen.getByText("Vigente", { selector: "span" })).toBeInTheDocument();
    expect(screen.getByText("Arquivado", { selector: "span" })).toBeInTheDocument();
    const hierarchy = screen.getByRole("table", { name: "Estrutura dos cronogramas" });
    expect(within(hierarchy).getByRole("columnheader", { name: "Produto A" })).toBeInTheDocument();
    expect(within(hierarchy).getByRole("columnheader", { name: "Produto B" })).toBeInTheDocument();
    expect(within(hierarchy).getByRole("rowheader", { name: /Disciplina Projeto/ })).toBeInTheDocument();
    expect(within(hierarchy).getByRole("rowheader", { name: /Etapa Detalhamento/ })).toBeInTheDocument();
    const activity = within(hierarchy).getByRole("rowheader", { name: /Atividade Conferência.*Local: Detalhamento/ });
    expect(activity).toBeInTheDocument();
    expect(within(activity.closest("tr")!).getAllByText("Valor diferente.")).toHaveLength(4);
    expect(within(hierarchy).getAllByText("29/02/2028").length).toBeGreaterThan(0);
    expect(within(hierarchy).getAllByText("Sem data").length).toBeGreaterThan(0);
    expect(within(hierarchy).getAllByText("Duração em dias úteis")).toHaveLength(2);
    expect(within(hierarchy).getByRole("rowheader", { name: /Atividade de Produto Reunião inicial Só em A/ })).toBeInTheDocument();
    expect(within(hierarchy).getAllByText("Correspondência indefinida")).toHaveLength(3);
    expect(within(screen.getByRole("table", { name: "Metas dos produtos" })).getByRole("rowheader", { name: /Aprovação Só em B/ })).toBeInTheDocument();
    expect(screen.getByText("Correspondências sugeridas")).toBeInTheDocument();
    expect(screen.getByText("Itens ambíguos")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /editar|salvar|arquivar/i })).not.toBeInTheDocument();
    const [path, init] = auth.fetch.mock.calls[0];
    expect(path).toBe(`/api/workspaces/${workspace.id}/product-comparison?leftProductId=${leftId}&rightProductId=${rightId}`);
    expect(init?.method ?? "GET").toBe("GET");
    expect(init?.body).toBeUndefined();
  });

  it("filters rows without dropping ancestry, and includes unmatched items in the differences filter", async () => {
    auth.fetch.mockResolvedValue(Response.json({ comparison: comparison() }));
    openPage();
    chooseAndCompare();
    const filter = await screen.findByRole("combobox", { name: "Exibir itens" });
    const hierarchy = screen.getByRole("table", { name: "Estrutura dos cronogramas" });
    expect(within(hierarchy).getAllByRole("rowheader", { name: /Ambíguo/ })).toHaveLength(3);
    fireEvent.change(filter, { target: { value: "differences" } });
    expect(within(hierarchy).getByRole("rowheader", { name: /Projeto.*Contexto do item/ })).toBeInTheDocument();
    expect(within(hierarchy).getByRole("rowheader", { name: /Reunião inicial Só em A/ })).toBeInTheDocument();
    expect(within(hierarchy).queryByRole("rowheader", { name: /Ambíguo/ })).not.toBeInTheDocument();
    fireEvent.change(filter, { target: { value: "ambiguous" } });
    expect(within(hierarchy).getAllByRole("rowheader", { name: /Ambíguo/ })).toHaveLength(3);
    expect(screen.getByText("Nenhum item corresponde ao filtro selecionado.")).toBeInTheDocument();
    expect(auth.fetch).toHaveBeenCalledTimes(1);
  });

  it("pairs ambiguous roots with distinct candidate labels, updates the active filter, and unlinks manual pairs locally", async () => {
    auth.fetch.mockResolvedValueOnce(Response.json({ comparison: comparison() }));
    openPage();
    chooseAndCompare();
    const filter = await screen.findByRole("combobox", { name: "Exibir itens" });
    fireEvent.change(filter, { target: { value: "ambiguous" } });
    const dialog = openPairing("Abertura");
    const picker = dialog.getByRole("combobox", { name: "Item do Produto B" });
    expect(dialog.getByRole("option", { name: /Atividade de Produto.*Abertura \(posição 1\)/ })).toBeInTheDocument();
    expect(dialog.getByRole("option", { name: /Atividade de Produto.*Abertura \(posição 2\)/ })).toBeInTheDocument();
    expect(dialog.queryByRole("option", { name: /Conferência|Aprovação/ })).not.toBeInTheDocument();
    const confirm = dialog.getByRole("button", { name: "Confirmar pareamento" });
    expect(confirm).toBeDisabled();
    fireEvent.change(picker, { target: { value: "right-root" } });
    fireEvent.click(confirm);
    await waitFor(() => expect(screen.getByText("Pareamento confirmado nesta comparação.")).toHaveFocus());
    expect(filter).toHaveValue("ambiguous");
    expect(screen.getByText("Itens ambíguos").nextElementSibling).toHaveTextContent("0");
    expect(screen.getByText("Pareamentos manuais").nextElementSibling).toHaveTextContent("1");
    fireEvent.change(filter, { target: { value: "all" } });
    expect(screen.getByRole("rowheader", { name: /Abertura Idêntico Confirmada manualmente/ })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Desvincular Abertura do Produto A" }));
    expect(screen.getByText("Correspondência desvinculada nesta comparação.")).toBeInTheDocument();
    expect(screen.getByText("Pareamentos manuais").nextElementSibling).toHaveTextContent("0");
    expect(screen.getByRole("button", { name: "Parear Abertura do Produto A" })).toBeInTheDocument();
    confirmPairing("Abertura", "right-root");
    expect(screen.getByText("Pareamentos manuais").nextElementSibling).toHaveTextContent("1");
    expect(auth.fetch).toHaveBeenCalledTimes(1);
    expect(auth.fetch.mock.calls[0][1]?.method ?? "GET").toBe("GET");
  });

  it("pairs renamed disciplines, stages and targets and compares an activity moved across levels", async () => {
    const fixture = comparison();
    const discipline = fixture.right.hierarchy.disciplines[0];
    const stage = discipline.stages[0];
    discipline.name = "Projeto revisado";
    stage.displayName = "Etapa revisada";
    stage.activities[0].name = "Reunião técnica";
    fixture.right.targets[0].name = "Entrega detalhada";
    auth.fetch.mockResolvedValueOnce(Response.json({ comparison: fixture }));
    openPage();
    chooseAndCompare();
    await screen.findByRole("table", { name: "Estrutura dos cronogramas" });
    confirmPairing("Projeto", discipline.id);
    confirmPairing("Detalhamento", stage.id);
    confirmPairing("Entrega", fixture.right.targets[0].id);
    const dialog = openPairing("Reunião inicial");
    expect(dialog.getByRole("option", { name: /Projeto revisado.*Etapa revisada.*Reunião técnica/ })).toBeInTheDocument();
    fireEvent.change(dialog.getByRole("combobox"), { target: { value: "right-activity" } });
    fireEvent.click(dialog.getByRole("button", { name: "Confirmar pareamento" }));
    const moved = screen.getByRole("rowheader", { name: /Reunião inicial Diferente Confirmada manualmente/ }).closest("tr")!;
    expect(within(moved).getAllByText("Local")).toHaveLength(2);
    expect(within(moved).getByText("Etapa revisada")).toBeInTheDocument();
    expect(screen.getByText("Pareamentos manuais").nextElementSibling).toHaveTextContent("4");
    expect(auth.fetch).toHaveBeenCalledTimes(1);
  });

  it.each(["right-target", "duplicate"])("rejects unavailable or wrong-kind candidate %s even if submitted", async (id) => {
    auth.fetch.mockResolvedValueOnce(Response.json({ comparison: comparison() }));
    openPage();
    chooseAndCompare();
    await screen.findByRole("table", { name: "Estrutura dos cronogramas" });
    confirmPairing("Abertura", "duplicate");
    const dialog = openPairing("Reunião inicial");
    const picker = dialog.getByRole<HTMLSelectElement>("combobox");
    expect([...picker.options].map(({ value }) => value)).toEqual(["", "right-root"]);
    picker.add(new Option("Invalid candidate", id));
    fireEvent.change(picker, { target: { value: id } });
    fireEvent.click(dialog.getByRole("button", { name: "Confirmar pareamento" }));
    expect(dialog.getByRole("alert")).toHaveTextContent("Não foi possível aplicar a decisão.");
    expect(screen.getByText("Pareamentos manuais").nextElementSibling).toHaveTextContent("1");
    expect(auth.fetch).toHaveBeenCalledTimes(1);
  });

  it("unlinks a suggestion immediately while preserving ancestor context for filtered descendants", async () => {
    auth.fetch.mockResolvedValueOnce(Response.json({ comparison: comparison() }));
    openPage();
    chooseAndCompare();
    const filter = await screen.findByRole("combobox", { name: "Exibir itens" });
    fireEvent.change(filter, { target: { value: "differences" } });
    fireEvent.click(screen.getByRole("button", { name: "Desvincular Conferência do Produto A" }));
    expect(screen.getByRole("rowheader", { name: /Conferência Só em A/ })).toBeInTheDocument();
    expect(screen.getByRole("rowheader", { name: /Conferência Só em B/ })).toBeInTheDocument();
    expect(screen.getByRole("rowheader", { name: /Projeto.*Contexto do item/ })).toBeInTheDocument();
    expect(auth.fetch).toHaveBeenCalledTimes(1);
  });

  it("uses the existing dialog keyboard trap and restores focus when Escape closes it", async () => {
    auth.fetch.mockResolvedValueOnce(Response.json({ comparison: comparison() }));
    openPage();
    chooseAndCompare();
    const trigger = await screen.findByRole("button", { name: "Parear Abertura do Produto A" });
    trigger.focus();
    fireEvent.click(trigger);
    const dialog = screen.getByRole("dialog", { name: "Parear itens" });
    expect(dialog).toHaveAttribute("aria-modal", "true");
    const close = within(dialog).getByRole("button", { name: "Fechar pareamento" });
    const cancel = within(dialog).getByRole("button", { name: "Cancelar" });
    expect(close).toHaveFocus();
    fireEvent.keyDown(close, { key: "Tab", shiftKey: true });
    expect(cancel).toHaveFocus();
    fireEvent.keyDown(cancel, { key: "Tab" });
    expect(close).toHaveFocus();
    fireEvent.keyDown(close, { key: "Escape" });
    await waitFor(() => expect(trigger).toHaveFocus());
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it.each([["Produto A", leftId], ["Produto B", rightId]])("discards decisions when %s changes, even if the same pair is reselected", async (side, previous) => {
    auth.fetch.mockImplementation(async () => Response.json({ comparison: comparison() }));
    openPage();
    chooseAndCompare();
    await screen.findByRole("table", { name: "Estrutura dos cronogramas" });
    confirmPairing("Abertura", "right-root");
    const select = screen.getByRole("combobox", { name: side });
    fireEvent.change(select, { target: { value: studyId } });
    expect(screen.queryByRole("table")).not.toBeInTheDocument();
    fireEvent.change(select, { target: { value: previous } });
    fireEvent.click(screen.getByRole("button", { name: "Comparar" }));
    expect(await screen.findByText("Pareamentos manuais")).toBeInTheDocument();
    expect(screen.getByText("Pareamentos manuais").nextElementSibling).toHaveTextContent("0");
    expect(auth.fetch).toHaveBeenCalledTimes(2);
  });

  it.each([[503, /Não foi possível carregar/], [404, /Um dos produtos não está disponível/], [422, /limite de 2\.000 itens/]])(
    "renders the %i failure and can retry", async (status, expected) => {
      auth.fetch.mockResolvedValueOnce(Response.json({ maxEntities: 2000 }, { status }))
        .mockResolvedValueOnce(Response.json({ comparison: { left: current, right: archived } }));
      openPage();
      chooseAndCompare();
      expect(await screen.findByRole("alert")).toHaveTextContent(expected);
      expect(screen.queryByRole("table")).not.toBeInTheDocument();
      fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
      expect(await screen.findByText("Os dois cronogramas estão vazios.")).toBeInTheDocument();
    }
  );

  it("marks a changed cursor stale on focus and refreshes the displayed snapshot only after user action", async () => {
    const latest = comparison();
    latest.right.cursor.scheduleVersion = "2";
    latest.right.product.name = "Torre Sul atualizada";
    auth.fetch.mockResolvedValueOnce(Response.json({ comparison: comparison() }))
      .mockResolvedValueOnce(Response.json({ comparison: latest })).mockResolvedValueOnce(Response.json({ comparison: latest }));
    openPage();
    chooseAndCompare();
    expect(await screen.findByRole("heading", { name: "Torre Sul" })).toBeInTheDocument();
    confirmPairing("Abertura", "right-root");
    openPairing("Reunião inicial");
    fireEvent(window, new Event("focus"));
    expect(await screen.findByText(/Há dados mais recentes/)).toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Desvincular Abertura do Produto A" })).toBeDisabled();
    expect(screen.getByRole("heading", { name: "Torre Sul" })).toBeInTheDocument();
    const refresh = screen.getByRole("button", { name: "Atualizar comparação" });
    expect(refresh).toHaveFocus();
    fireEvent.click(refresh);
    expect(await screen.findByRole("heading", { name: "Torre Sul atualizada" })).toBeInTheDocument();
    expect(screen.getByText("As decisões de pareamento foram limpas ao atualizar a comparação.")).toBeInTheDocument();
    expect(screen.getByText("Pareamentos manuais").nextElementSibling).toHaveTextContent("0");
    expect(screen.queryByText(/Há dados mais recentes/)).not.toBeInTheDocument();
  });

  it("announces loading, discards a superseded response, and delegates access loss", async () => {
    let finish!: (response: Response) => void;
    auth.fetch.mockImplementationOnce(() => new Promise<Response>((resolve) => { finish = resolve; }))
      .mockResolvedValueOnce(Response.json({}, { status: 403 }));
    const onAccessLost = vi.fn();
    openPage({ onAccessLost });
    chooseAndCompare();
    expect(await screen.findByRole("status")).toHaveTextContent("Carregando comparação");
    chooseAndCompare(studyId);
    await waitFor(() => expect(onAccessLost).toHaveBeenCalledOnce());
    expect(auth.fetch.mock.calls[0][1]?.signal?.aborted).toBe(true);
    await act(async () => { finish(Response.json({ comparison: comparison() })); });
    expect(screen.queryByRole("table")).not.toBeInTheDocument();
  });
});
