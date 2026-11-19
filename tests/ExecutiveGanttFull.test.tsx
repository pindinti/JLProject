import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ExecutiveGanttFull } from "../src/ExecutiveGanttFull";
import type { ExecutiveProduct } from "../worker/executive-gantt";

const auth = vi.hoisted(() => ({ fetch: vi.fn() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: auth.fetch }));

const workspace = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const otherWorkspace = "d441363c-bdde-4422-93d6-59b3868d29f4";
const product: ExecutiveProduct = {
  id: "p", name: "Product A", active: true, start: "2024-02-29", end: "2024-03-05",
  rootActivities: [{ id: "root", productId: "p", disciplineId: null, stageId: null,
    name: "Root activity", activityType: null, displayOrder: 0,
    plannedStart: "2024-02-29", plannedEnd: "2024-03-05", colorOverride: null, color: "#668899" }],
  disciplines: ["d1", "d2"].map((id, index) => ({ id, productId: "p",
    name: `Discipline ${index + 1}`, shortCode: `D${index + 1}`, color: "#445566",
    displayOrder: index, start: "2024-03-01", end: "2024-03-04", stages: [{
      id: `s${index}`, productId: "p", disciplineId: id, code: "EC", displayName: "Same stage",
      color: index ? "#BB3366" : "#33AA88", displayOrder: 0,
      start: index ? "2024-03-02" : "2024-03-01", end: index ? "2024-03-04" : "2024-03-03",
      plannedStart: null, plannedEnd: null, dateSource: "derived",
      derivedStart: index ? "2024-03-02" : "2024-03-01", derivedEnd: index ? "2024-03-04" : "2024-03-03",
      activities: [{ id: `a${index}`, productId: "p", disciplineId: id, stageId: `s${index}`,
        name: `Activity ${index}`, activityType: null, displayOrder: 0,
        plannedStart: "2024-03-02", plannedEnd: "2024-03-03", colorOverride: null, color: "#99AABB" }] }] })),
  targets: [{ id: "t1", productId: "p", name: "Milestone one", description: "First description",
    color: "#123456", displayOrder: 0, targetDate: "2024-03-02", operationalDate: null },
  { id: "t2", productId: "p", name: "Milestone two", description: null,
    color: "#654321", displayOrder: 1, targetDate: "2024-03-02", operationalDate: null }]
};
const archived: ExecutiveProduct = { id: "archived", name: "Archived product", active: false,
  start: null, end: null, rootActivities: [], disciplines: [], targets: [] };
const response = (products: ExecutiveProduct[]) => new Response(JSON.stringify({ products }), { status: 200 });
const props = { workspaceId: workspace, onAccessLost: vi.fn(), onBack: vi.fn(), onOpenProduct: vi.fn() };

beforeEach(() => {
  auth.fetch.mockReset();
  props.onAccessLost.mockReset();
  props.onBack.mockReset();
  props.onOpenProduct.mockReset();
  auth.fetch.mockImplementation(async (path: string) => path.endsWith("/executive-gantt")
    ? response([product, archived])
    : new Response(JSON.stringify({ calendar: { version: 1, exceptions: [] } }), { status: 200 }));
});

describe("full Executive Gantt", () => {
  it("shows planned full and partial intervals with their source at stage detail level", async () => {
    const planned = structuredClone(product);
    const stage = { ...planned.disciplines[1].stages[0], id: "planned-only", displayName: "Planned only",
      start: "2030-02-28", end: "2030-03-02", plannedStart: "2030-02-28", plannedEnd: "2030-03-02",
      dateSource: "planned" as const, derivedStart: null, derivedEnd: null, activities: [] };
    const partial = { ...stage, id: "planned-partial", start: null, end: "2030-03-05",
      plannedStart: null, plannedEnd: "2030-03-05" };
    planned.disciplines[1] = { ...planned.disciplines[1], start: "2030-02-28", end: "2030-03-05",
      stages: [stage, partial] };
    planned.start = "2024-02-29";
    planned.end = "2030-03-05";
    auth.fetch.mockResolvedValue(response([planned, archived]));
    const { container } = render(<ExecutiveGanttFull {...props} />);
    await screen.findByRole("table", { name: "Cronograma executivo" });
    fireEvent.click(screen.getByRole("button", { name: "Etapas" }));
    const bar = container.querySelector<HTMLElement>('[data-row-key="stage:planned-only"] [data-entity-id="planned-only"]')!;
    const marker = container.querySelector<HTMLElement>('[data-row-key="stage:planned-partial"] [data-entity-id="planned-partial"]')!;
    expect(bar).toHaveAttribute("data-date-source", "planned");
    expect(bar).toHaveClass("executive-full__bar--planned");
    expect(bar).toHaveAttribute("title", expect.stringContaining("28/02/2030"));
    expect(marker).toHaveClass("executive-full__bar--partial", "executive-full__bar--planned");
    expect(marker).toHaveAttribute("data-date-source", "planned");
  });

  it("defaults to products and month and keeps detail independent from temporal zoom", async () => {
    const { container } = render(<ExecutiveGanttFull {...props} />);
    const table = await screen.findByRole("table", { name: "Cronograma executivo" });
    expect(within(table).getAllByRole("row")).toHaveLength(3);
    expect(screen.getByRole("button", { name: "Produtos" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: "Mês" })).toHaveAttribute("aria-pressed", "true");
    const stageBars = container.querySelectorAll('[data-stage-id="s0"], [data-stage-id="s1"]');
    expect(stageBars).toHaveLength(2);
    expect(stageBars[0]).toHaveStyle({ backgroundColor: "#33AA88" });
    expect(stageBars[1]).toHaveStyle({ backgroundColor: "#BB3366" });
    expect(stageBars[0]).toHaveTextContent("Discipline 1 – Same stage");
    expect(stageBars[0]).toHaveAttribute("title", expect.stringContaining("Discipline 1"));
    expect(stageBars[0]).toHaveAttribute("title", expect.stringContaining("Same stage"));
    expect(Number.parseFloat((stageBars[0] as HTMLElement).style.width)).toBeLessThan(28);
    expect(container.querySelector('[data-row-key="product:p"]')).toHaveTextContent("29/02/2024");
    fireEvent.click(screen.getByRole("button", { name: "Etapas" }));
    expect(within(table).getAllByRole("row")).toHaveLength(7);
    expect(screen.getByRole("button", { name: "Mês" })).toHaveAttribute("aria-pressed", "true");
    fireEvent.click(screen.getByRole("button", { name: "Dia" }));
    expect(screen.getByRole("button", { name: "Etapas" })).toHaveAttribute("aria-pressed", "true");
    fireEvent.click(screen.getByRole("button", { name: "Atividades" }));
    expect(screen.getByRole("button", { name: "Dia" })).toHaveAttribute("aria-pressed", "true");
    expect(container.querySelector('[data-row-key="activity:root"]')).toHaveTextContent("Atividade de Produto");
    expect(container.querySelector('[data-entity-id="root"]')).toHaveAttribute("aria-label", expect.stringContaining("29/02/2024"));
    expect(container.querySelector('[data-row-key="activity:a0"]')).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Produtos" }));
    expect(within(table).getAllByRole("row")).toHaveLength(3);
    expect(container.querySelectorAll('[data-stage-id]')).toHaveLength(2);
    expect(container.querySelector('[data-stage-id="s0"]')).toHaveAttribute("data-lane", "0");
    expect(container.querySelector('[data-stage-id="s1"]')).toHaveAttribute("data-lane", "1");
    expect(container.querySelector('[data-entity-id="root"]')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Atualizar cronograma" }));
    await waitFor(() => expect(auth.fetch.mock.calls.filter(([path]) =>
      String(path).endsWith("/executive-gantt"))).toHaveLength(2));
  });

  it("filters disciplines, collapses groups, and navigates to a product", async () => {
    const { container } = render(<ExecutiveGanttFull {...props} />);
    await screen.findByRole("table", { name: "Cronograma executivo" });
    fireEvent.click(screen.getByRole("button", { name: "Etapas" }));
    expect(screen.queryByLabelText("Mostrar arquivados")).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Disciplina"), { target: { value: "d2" } });
    expect(container.querySelector('[data-row-key="stage:s0"]')).not.toBeInTheDocument();
    expect(container.querySelector('[data-row-key="stage:s1"]')).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Expandir ou recolher Product A" }));
    expect(container.querySelector('[data-row-key="discipline:d2"]')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Expandir tudo" }));
    expect(container.querySelector('[data-row-key="discipline:d2"]')).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Abrir cronograma do produto Product A" }));
    expect(props.onOpenProduct).toHaveBeenCalledWith("p");
    fireEvent.click(screen.getByRole("button", { name: "Voltar aos produtos" }));
    expect(props.onBack).toHaveBeenCalledOnce();
    fireEvent.click(screen.getByRole("button", { name: "Limpar filtros" }));
    expect(container.querySelector('[data-row-key="product:archived"]')).toBeInTheDocument();
  });

  it("clusters same-day milestones with descriptions and toggles visibility", async () => {
    const { container } = render(<ExecutiveGanttFull {...props} />);
    await screen.findByRole("table", { name: "Cronograma executivo" });
    const marker = container.querySelector<HTMLElement>('[data-target-date="2024-03-02"]')!;
    expect(marker).toHaveTextContent("2");
    expect(marker).toHaveAttribute("title", expect.stringContaining("First description"));
    expect(marker.querySelectorAll("i")[0]).toHaveStyle({ backgroundColor: "#123456" });
    fireEvent.click(marker);
    expect(within(screen.getByRole("dialog")).getByText("First description")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Fechar detalhes" }));
    fireEvent.click(screen.getByLabelText("Mostrar metas"));
    expect(container.querySelector('[data-target-date]')).not.toBeInTheDocument();
  });

  it("handles empty, failed, unauthorized, refreshed, and changed-workspace responses", async () => {
    auth.fetch.mockResolvedValueOnce(response([]));
    const first = render(<ExecutiveGanttFull {...props} />);
    expect(await screen.findByText("Nenhum produto para mostrar no cronograma executivo.")).toBeInTheDocument();
    first.unmount();
    auth.fetch.mockResolvedValueOnce(new Response(null, { status: 500 }));
    const failed = render(<ExecutiveGanttFull {...props} />);
    expect(await screen.findByRole("alert")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Tentar novamente" }));
    expect(await screen.findByRole("table", { name: "Cronograma executivo" })).toBeInTheDocument();
    failed.unmount();
    auth.fetch.mockResolvedValueOnce(new Response(null, { status: 403 }));
    render(<ExecutiveGanttFull {...props} />);
    await waitFor(() => expect(props.onAccessLost).toHaveBeenCalledOnce());
    await act(async () => { await Promise.resolve(); });
  });

  it("invalidates old workspace data before displaying a new workspace", async () => {
    const first = render(<ExecutiveGanttFull {...props} />);
    await screen.findByRole("table", { name: "Cronograma executivo" });
    const next = { ...props, workspaceId: otherWorkspace };
    auth.fetch.mockImplementation((path: string) => path.includes(otherWorkspace)
      ? new Promise(() => {}) : Promise.resolve(response([product])));
    first.rerender(<ExecutiveGanttFull {...next} />);
    expect(screen.queryByRole("table")).not.toBeInTheDocument();
    expect(screen.getByRole("status")).toBeInTheDocument();
    await waitFor(() => expect(auth.fetch).toHaveBeenCalledWith(
      `/api/workspaces/${otherWorkspace}/executive-gantt`));
  });
});
