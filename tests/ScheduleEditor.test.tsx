import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ScheduleEditor } from "../src/ScheduleEditor";
import { formatCivilDate, parseBrazilianDate } from "../src/civil-date";

const api = vi.hoisted(() => ({ fetch: vi.fn() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: api.fetch }));

const workspace = { id: "e97c159e-3f7b-4e27-8b1e-38036bf47a3f", name: "JLProject", role: "admin" as const };
const product = { id: "e3aa998a-a2c3-4376-9105-90af0d1dbfe3", name: "Synthetic product", active: true };
const activity = { id: "cd960302-0b68-4621-95ed-7d4f57f8eedc", stageId: "7130dfdf-452d-4bfc-8ad0-9cbf4db53747",
  name: "Synthetic activity", activityType: null, plannedStart: "2026-11-01", plannedEnd: "2026-11-08",
  displayOrder: 0, notes: null, version: 1 };
const stage = { id: activity.stageId, disciplineId: "bba53e18-f13f-4b2d-a02e-65a0d95627e6", code: "EC",
  color: "#336699", displayName: "Synthetic stage", displayOrder: 0, derivedStart: "2026-11-01",
  derivedEnd: "2026-11-08", version: 1, activities: [activity] };
const discipline = { id: stage.disciplineId, productId: product.id, name: "Synthetic discipline",
  shortCode: "ENG", color: "#225588", description: null, displayOrder: 0, version: 1, stages: [stage] };
const definitions = [{ id: "add2b76e-72b5-4a0a-b8e8-3bd095688a01", code: "EC", color: "#336699" }];

function json(value: unknown, status = 200) { return new Response(JSON.stringify(value), { status }); }
function setup(tree: { productId: string; disciplines: unknown[] } = { productId: product.id, disciplines: [discipline] }) {
  api.fetch.mockImplementation((path: string) => Promise.resolve(path.endsWith("/hierarchy")
    ? json({ hierarchy: tree }) : json({ stageDefinitions: definitions })));
}
function mount(role: "admin" | "editor" | "viewer" = "admin") {
  const onAccessLost = vi.fn();
  render(<ScheduleEditor workspace={{ ...workspace, role }} product={product}
    onBack={vi.fn()} onAccessLost={onAccessLost} />);
  return onAccessLost;
}

beforeEach(() => { vi.clearAllMocks(); setup(); });

describe("schedule editor", () => {
  it("loads ordered hierarchy, Brazilian dates, derived dates, and collapses rows", async () => {
    mount();
    expect(screen.getByRole("status")).toHaveTextContent("Carregando cronograma");
    expect(await screen.findByText("Synthetic activity")).toBeInTheDocument();
    expect(screen.getAllByText("01/11/2026 a 08/11/2026")).toHaveLength(2);
    fireEvent.click(screen.getByRole("button", { name: "Synthetic discipline (ENG)" }));
    expect(screen.queryByText("Synthetic activity")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Synthetic discipline (ENG)" })).toHaveAttribute("aria-expanded", "false");
  });

  it("shows empty groups and gives viewers read-only access", async () => {
    setup({ productId: product.id, disciplines: [{ ...discipline, stages: [{ ...stage, activities: [], derivedStart: null, derivedEnd: null }] }] });
    mount("viewer");
    expect(await screen.findByText("Nenhuma atividade cadastrada nesta etapa.")).toBeInTheDocument();
    expect(screen.getByText("Sem data a Sem data")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Adicionar atividade" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Editar etapa" })).not.toBeInTheDocument();
    expect(api.fetch).not.toHaveBeenCalledWith(expect.stringContaining("stage-definitions"));
  });

  it("creates a discipline with ordered metadata", async () => {
    mount("editor");
    fireEvent.click(await screen.findByRole("button", { name: "Adicionar disciplina" }));
    fireEvent.change(screen.getByLabelText("Nome da disciplina"), { target: { value: "Nova disciplina" } });
    fireEvent.change(screen.getByLabelText("Código da disciplina"), { target: { value: "NEW" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      `/api/workspaces/${workspace.id}/products/${product.id}/disciplines`,
      expect.objectContaining({ method: "POST", body: expect.stringContaining('"shortCode":"NEW"') })
    ));
  });

  it("confirms a discipline metadata edit with its current version", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Editar disciplina" }));
    fireEvent.change(screen.getByLabelText("Ordem de exibição"), { target: { value: "3" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/disciplines/${discipline.id}`),
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"version":1') })
    ));
    expect(confirmation).toHaveBeenCalled();
    confirmation.mockRestore();
  });

  it("selects a shared stage definition and preserves its color", async () => {
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Adicionar etapa" }));
    fireEvent.change(screen.getByLabelText("Código compartilhado da etapa"), { target: { value: definitions[0].id } });
    expect(screen.getByText("Cor compartilhada: #336699")).toBeInTheDocument();
    expect(screen.queryByLabelText("Cor")).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Nome da etapa"), { target: { value: "Nova etapa" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/disciplines/${discipline.id}/stages`),
      expect.objectContaining({ method: "POST", body: expect.stringContaining('"color":"#336699"') })
    ));
  });

  it("edits a stage using its shared definition and version", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Editar etapa" }));
    expect(screen.getByRole("combobox", { name: "Código compartilhado da etapa" })).toHaveValue(definitions[0].id);
    fireEvent.change(screen.getByLabelText("Nome da etapa"), { target: { value: "Etapa atualizada" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/stages/${stage.id}`),
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"version":1') })
    ));
    confirmation.mockRestore();
  });

  it("validates activity dates and sends ISO civil dates only on creation", async () => {
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Adicionar atividade" }));
    fireEvent.change(screen.getByLabelText("Nome da atividade"), { target: { value: "Nova atividade" } });
    fireEvent.change(screen.getByLabelText("Início planejado"), { target: { value: "31/02/2026" } });
    fireEvent.change(screen.getByLabelText("Fim planejado"), { target: { value: "08/11/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    expect(screen.getByRole("alert")).toHaveTextContent("Informe as duas datas");
    fireEvent.change(screen.getByLabelText("Início planejado"), { target: { value: "01/11/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(api.fetch).toHaveBeenCalledWith(
      expect.stringContaining(`/stages/${stage.id}/activities`),
      expect.objectContaining({ method: "POST", body: expect.stringContaining('"plannedStart":"2026-11-01"') })
    ));
  });

  it("keeps existing activity dates read-only and confirms metadata edits", async () => {
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    mount();
    fireEvent.click(await screen.findByRole("button", { name: "Editar atividade" }));
    expect(screen.getByText(/As datas existentes são somente leitura/)).toBeInTheDocument();
    expect(screen.queryByLabelText("Início planejado")).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Nome da atividade"), { target: { value: "Atualizada" } });
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(confirmation).toHaveBeenCalled());
    const mutation = api.fetch.mock.calls.find(([path, options]) => path.endsWith(`/activities/${activity.id}`) && options?.method === "PATCH");
    expect(mutation?.[1].body).toContain('"version":1');
    expect(mutation?.[1].body).not.toContain("plannedStart");
    confirmation.mockRestore();
  });

  it("shows retry after load failure and safe conflict feedback", async () => {
    api.fetch.mockResolvedValueOnce(new Response("", { status: 503 }))
      .mockResolvedValueOnce(json({ stageDefinitions: definitions }));
    mount();
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível carregar o cronograma");
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
    fireEvent.click(await screen.findByRole("button", { name: "Adicionar disciplina" }));
    fireEvent.change(screen.getByLabelText("Nome da disciplina"), { target: { value: "Nova" } });
    fireEvent.change(screen.getByLabelText("Código da disciplina"), { target: { value: "N" } });
    api.fetch.mockResolvedValueOnce(json({ error: "private detail" }, 409));
    fireEvent.click(screen.getByRole("button", { name: "Salvar" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Este item foi alterado");
    expect(screen.getByRole("alert")).not.toHaveTextContent("private detail");
    expect(screen.getAllByRole("button", { name: "Atualizar dados" })).toHaveLength(2);
  });

  it("reports missing hierarchy and rechecks access loss", async () => {
    api.fetch.mockResolvedValueOnce(json({}, 404)).mockResolvedValueOnce(json({ stageDefinitions: definitions }));
    const onAccessLost = mount();
    expect(await screen.findByRole("alert")).toHaveTextContent("Cronograma não encontrado");
    expect(onAccessLost).not.toHaveBeenCalled();
  });

  it("does not render hierarchy after unauthorized API access", async () => {
    api.fetch.mockResolvedValueOnce(json({}, 401)).mockResolvedValueOnce(json({ stageDefinitions: definitions }));
    const onAccessLost = mount();
    await waitFor(() => expect(onAccessLost).toHaveBeenCalledOnce());
    expect(screen.queryByText("Synthetic activity")).not.toBeInTheDocument();
  });
});

describe("civil dates", () => {
  it("formats without timezone conversion and rejects invalid Brazilian dates", () => {
    expect(formatCivilDate("2026-11-01")).toBe("01/11/2026");
    expect(parseBrazilianDate("01/11/2026")).toBe("2026-11-01");
    expect(parseBrazilianDate("29/02/2028")).toBe("2028-02-29");
    expect(parseBrazilianDate("29/02/2026")).toBeNull();
    expect(parseBrazilianDate("2026-11-01")).toBeNull();
  });
});
