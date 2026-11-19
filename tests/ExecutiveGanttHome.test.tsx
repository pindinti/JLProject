import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ExecutiveGanttHome } from "../src/ExecutiveGanttHome";
import type { ExecutiveProduct } from "../worker/executive-gantt";

const auth = vi.hoisted(() => ({ fetch: vi.fn() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: auth.fetch }));

const workspace = "e97c159e-3f7b-4e27-8b1e-38036bf47a3f";
const alternateWorkspace = "d441363c-bdde-4422-93d6-59b3868d29f4";
const projection: ExecutiveProduct[] = [
  { id: "current", name: "Current product", active: true, start: "2024-02-29", end: "2025-01-10",
    rootActivities: [{ id: "root", productId: "current", disciplineId: null, stageId: null,
      name: "Root activity", activityType: null, displayOrder: 0, plannedStart: "2024-02-29",
      plannedEnd: "2025-01-10", colorOverride: null, color: "#8D9A89" }],
    disciplines: [
      { id: "d1", productId: "current", name: "Architecture", shortCode: "A", color: "#123456",
        displayOrder: 0, start: "2024-12-30", end: "2025-01-03", stages: [
          { id: "s1", productId: "current", disciplineId: "d1", code: "EC", displayName: "Repeated stage",
            color: "#AA5577", displayOrder: 0, start: "2024-12-30", end: "2025-01-03",
            plannedStart: null, plannedEnd: null, dateSource: "derived", derivedStart: "2024-12-30", derivedEnd: "2025-01-03", activities: [] }
        ] },
      { id: "d2", productId: "current", name: "Engineering", shortCode: "E", color: "#654321",
        displayOrder: 1, start: "2025-01-01", end: "2025-01-04", stages: [
          { id: "s2", productId: "current", disciplineId: "d2", code: "EC", displayName: "Repeated stage",
            color: "#22AA88", displayOrder: 0, start: "2025-01-01", end: "2025-01-04",
            plannedStart: null, plannedEnd: null, dateSource: "derived", derivedStart: "2025-01-01", derivedEnd: "2025-01-04", activities: [] }
        ] }
    ],
    targets: [
      { id: "t1", productId: "current", name: "Target one", description: null, color: "#112233", displayOrder: 0,
        targetDate: "2025-01-02", operationalDate: null },
      { id: "t2", productId: "current", name: "Target two", description: null, color: "#445566", displayOrder: 1,
        targetDate: "2025-01-02", operationalDate: null }
    ] },
  { id: "archived", name: "Archived product", active: false, start: null, end: null,
    rootActivities: [], disciplines: [], targets: [] }
];

const response = (products: ExecutiveProduct[]) => new Response(JSON.stringify({ products }), { status: 200 });
const chart = () => screen.getByRole("table", { name: "Cronograma executivo" });

beforeEach(() => {
  auth.fetch.mockReset();
  auth.fetch.mockResolvedValue(response(projection));
});

describe("compact Executive Gantt Home", () => {
  it("renders a planned-only partial stage with a distinct source and timeline position", async () => {
    const planned = structuredClone(projection);
    const stage: ExecutiveProduct["disciplines"][number]["stages"][number] = {
      ...planned[0].disciplines[0].stages[0], id: "planned-only", displayName: "Planned only",
      start: "2030-02-28", end: null, plannedStart: "2030-02-28", plannedEnd: null,
      dateSource: "planned", derivedStart: null, derivedEnd: null, activities: []
    };
    planned[0].disciplines = [{ ...planned[0].disciplines[0], start: "2030-02-28", end: null, stages: [stage] }];
    planned[0].start = "2030-02-28";
    planned[0].end = null;
    auth.fetch.mockResolvedValue(response(planned));
    const { container } = render(<ExecutiveGanttHome workspaceId={workspace} onAccessLost={vi.fn()} />);
    await screen.findByRole("table", { name: "Cronograma executivo" });
    const marker = container.querySelector<HTMLElement>('[data-stage-id="planned-only"]')!;
    expect(marker).toHaveClass("executive-gantt__stage--partial", "executive-gantt__stage--planned");
    expect(marker).toHaveAttribute("data-date-source", "planned");
    expect(marker).toHaveAttribute("title", expect.stringContaining("Planejada para a etapa"));
    expect(marker).toHaveAttribute("title", expect.stringContaining("28/02/2030"));
    expect(container.querySelector('[data-product-id="current"]')).toHaveTextContent("28/02/2030");
  });

  it("shows one row per product with overlapping stage lanes, colors, and distinct disciplines", async () => {
    const { container } = render(<ExecutiveGanttHome workspaceId={workspace} onAccessLost={vi.fn()} />);
    expect(await screen.findByRole("table", { name: "Cronograma executivo" })).toBeInTheDocument();
    expect(within(chart()).getAllByRole("row")).toHaveLength(3);
    const current = container.querySelector<HTMLElement>('[data-product-id="current"]')!;
    expect(current).toHaveStyle({ height: "80px" });
    expect(current.querySelector(".executive-gantt__chart")).toHaveStyle({ height: "80px" });
    expect(current).toHaveTextContent("29/02/2024 – 10/01/2025");
    expect(current.querySelectorAll("[data-stage-id]")).toHaveLength(2);
    expect(current.querySelector('[data-stage-id="s1"]')).toHaveAttribute("data-lane", "0");
    expect(current.querySelector('[data-stage-id="s2"]')).toHaveAttribute("data-lane", "1");
    expect(current.querySelector('[data-stage-id="s1"]')).toHaveStyle({ backgroundColor: "#AA5577" });
    expect(current.querySelector('[data-stage-id="s2"]')).toHaveStyle({ backgroundColor: "#22AA88" });
    expect(current.querySelector('[data-stage-id="s1"]')).toHaveTextContent("A – EC");
    expect(current.querySelector('[data-stage-id="s2"]')).toHaveTextContent("E – EC");
    expect(current.querySelector('[data-stage-id="s1"]')).toHaveAttribute("title", expect.stringContaining("Architecture"));
    expect(current.querySelector('[data-stage-id="s1"]')).toHaveAttribute("title", expect.stringContaining("Repeated stage"));
    expect(current.querySelector('[data-stage-id="s2"]')).toHaveAttribute("title", expect.stringContaining("Engineering"));
    expect(current.querySelector('[data-stage-id="root"]')).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Abrir cronograma executivo" })).toBeDisabled();
  });

  it("clusters same-day targets, keeps their colors, and toggles targets", async () => {
    const { container } = render(<ExecutiveGanttHome workspaceId={workspace} onAccessLost={vi.fn()} />);
    await screen.findByRole("table", { name: "Cronograma executivo" });
    const cluster = container.querySelector<HTMLElement>('[data-target-date="2025-01-02"]')!;
    expect(cluster).toHaveTextContent("2");
    expect(cluster).toHaveAttribute("aria-label", expect.stringContaining("Target one"));
    expect(cluster.querySelectorAll(".executive-gantt__diamond")).toHaveLength(2);
    expect(cluster.querySelectorAll(".executive-gantt__diamond")[0]).toHaveStyle({ backgroundColor: "#112233" });
    expect(cluster.querySelectorAll(".executive-gantt__diamond")[1]).toHaveStyle({ backgroundColor: "#445566" });
    fireEvent.click(screen.getByLabelText("Mostrar metas"));
    expect(container.querySelector("[data-target-date]")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Mostrar arquivados")).not.toBeInTheDocument();
    expect(auth.fetch.mock.calls.filter(([path]) => String(path).endsWith("/executive-gantt")))
      .toEqual([[`/api/workspaces/${workspace}/executive-gantt`]]);
    await act(async () => { await Promise.resolve(); });
  });

  it("includes workspace calendar exceptions in non-working-day shading", async () => {
    auth.fetch.mockImplementation(async (path: string) => path.endsWith("/executive-gantt")
      ? response(projection)
      : new Response(JSON.stringify({ calendar: { version: 1, exceptions: [{ kind: "company_shutdown",
        startDate: "2026-11-16", endDate: "2026-11-16" }] } }), { status: 200 }));
    const { container } = render(<ExecutiveGanttHome workspaceId={workspace} onAccessLost={vi.fn()} />);
    await waitFor(() => expect([...container.querySelectorAll<HTMLElement>(".executive-gantt__nonworking span")]
      .some((band) => band.dataset.startDate! <= "2026-11-16" && band.dataset.endDate! >= "2026-11-16"))
      .toBe(true));
    expect(auth.fetch).toHaveBeenCalledWith(`/api/workspaces/${workspace}/calendar?year=2026`);
  });

  it("renders partial and missing stages without inventing a span and switches timeline scale", async () => {
    const partial = structuredClone(projection);
    partial[0].disciplines[0].stages.push({ ...partial[0].disciplines[0].stages[0], id: "partial",
      displayName: "Partial", start: "2025-01-10", end: null });
    partial[0].disciplines[0].stages.push({ ...partial[0].disciplines[0].stages[0], id: "missing",
      displayName: "Missing", start: null, end: null });
    auth.fetch.mockResolvedValue(response(partial));
    const { container } = render(<ExecutiveGanttHome workspaceId={workspace} onAccessLost={vi.fn()} />);
    await screen.findByRole("table", { name: "Cronograma executivo" });
    expect(container.querySelector('[data-stage-id="partial"]')).toHaveClass("executive-gantt__stage--partial");
    expect(container.querySelector('[data-stage-id="missing"]')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Mostrar 1 etapa adicional de Current product" }));
    expect(within(screen.getByRole("dialog")).getByText("Missing")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Fechar detalhes" }));
    const monthLeft = (container.querySelector('[data-stage-id="s1"]') as HTMLElement).style.left;
    const toolbar = screen.getByRole("toolbar", { name: "Controles do cronograma executivo" });
    expect(within(toolbar).queryByRole("combobox")).not.toBeInTheDocument();
    fireEvent.click(within(toolbar).getByRole("button", { name: "Semana" }));
    expect(within(toolbar).getByRole("button", { name: "Semana" })).toHaveAttribute("aria-pressed", "true");
    expect((container.querySelector('[data-stage-id="s1"]') as HTMLElement).style.left).not.toBe(monthLeft);
    expect(container.querySelector(".executive-gantt__today-line")).toBeInTheDocument();
    expect(container.querySelector(".executive-gantt__nonworking span")).toBeInTheDocument();
  });

  it("bounds a dense product row and gives keyboard access to every aggregated stage", async () => {
    const dense = structuredClone(projection);
    dense[0].disciplines[0].stages = Array.from({ length: 14 }, (_, index) => ({
      ...dense[0].disciplines[0].stages[0], id: `dense-${index}`, displayName: `Dense stage ${index}`,
      color: index % 2 ? "#BB8844" : "#446688", start: "2025-01-01", end: "2025-01-03"
    }));
    dense[0].disciplines = [dense[0].disciplines[0]];
    auth.fetch.mockResolvedValue(response(dense));
    const { container } = render(<ExecutiveGanttHome workspaceId={workspace} onAccessLost={vi.fn()} />);
    await screen.findByRole("table", { name: "Cronograma executivo" });
    const row = container.querySelector<HTMLElement>('[data-product-id="current"]')!;
    expect(row).toHaveStyle({ height: "80px" });
    expect(row.querySelectorAll("[data-stage-id]")).toHaveLength(2);
    expect(row.querySelector('[data-overflow-count="12"]')).toBeInTheDocument();
    const more = screen.getByRole("button", { name: "Mostrar 12 etapas adicionais de Current product" });
    fireEvent.click(more);
    const dialog = screen.getByRole("dialog", { name: "Outras etapas de Current product" });
    expect(dialog.querySelectorAll("[data-detail-stage-id]")).toHaveLength(12);
    for (let index = 2; index < 14; index++)
      expect(dialog.querySelector(`[data-detail-stage-id="dense-${index}"]`)).toBeInTheDocument();
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(more).toHaveFocus();
    fireEvent.click(row.querySelector<HTMLButtonElement>('[data-overflow-count="12"]')!);
    expect(screen.getByRole("dialog").querySelectorAll("[data-detail-stage-id]")).toHaveLength(12);
  });

  it("uses labeled short stage badges and keeps toolbar actions grouped on the right", async () => {
    const short = structuredClone(projection);
    short[0].disciplines[0].stages = [{ ...short[0].disciplines[0].stages[0],
      id: "short", displayName: "One day", start: "2025-01-10", end: "2025-01-10" }];
    short[0].disciplines = [short[0].disciplines[0]];
    auth.fetch.mockResolvedValue(response(short));
    const { container } = render(<ExecutiveGanttHome workspaceId={workspace} onAccessLost={vi.fn()} />);
    await screen.findByRole("table", { name: "Cronograma executivo" });
    const badge = container.querySelector<HTMLElement>('[data-stage-id="short"]')!;
    expect(badge).toHaveClass("executive-gantt__stage--short");
    expect(badge).toHaveTextContent("A – EC");
    expect(Number.parseFloat(badge.style.width)).toBeLessThan(28);
    expect(badge).toHaveAttribute("title", expect.stringContaining("Architecture"));
    expect(badge).toHaveAttribute("title", expect.stringContaining("One day"));
    expect(badge).toHaveAttribute("aria-label", badge.getAttribute("title"));
    const toolbar = screen.getByRole("toolbar", { name: "Controles do cronograma executivo" });
    const actions = toolbar.querySelector(".executive-gantt__toolbar-actions")!;
    expect(actions).toContainElement(screen.getByRole("button", { name: "Atualizar cronograma" }));
    expect(actions).toContainElement(screen.getByRole("button", { name: "Abrir cronograma executivo" }));
    expect(screen.getByRole("button", { name: "Abrir cronograma executivo" })).toBeDisabled();
  });

  it("handles loading, empty, error, manual refresh, and access loss", async () => {
    let resolve!: (value: Response) => void;
    auth.fetch.mockReturnValueOnce(new Promise((done) => { resolve = done; }));
    const onAccessLost = vi.fn();
    const { rerender } = render(<ExecutiveGanttHome workspaceId={workspace} onAccessLost={onAccessLost} />);
    expect(screen.getByRole("status")).toHaveTextContent("Carregando cronograma executivo");
    resolve(response([]));
    expect(await screen.findByText("Nenhum produto para mostrar no cronograma executivo.")).toBeInTheDocument();
    auth.fetch.mockResolvedValueOnce(new Response("", { status: 503 }));
    fireEvent.click(screen.getByRole("button", { name: "Atualizar cronograma" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível carregar o cronograma executivo");
    auth.fetch.mockResolvedValueOnce(new Response("", { status: 403 }));
    fireEvent.click(screen.getByRole("button", { name: "Atualizar cronograma" }));
    await waitFor(() => expect(onAccessLost).toHaveBeenCalledTimes(1));
    rerender(<ExecutiveGanttHome workspaceId={alternateWorkspace} onAccessLost={onAccessLost} />);
    await waitFor(() => expect(auth.fetch).toHaveBeenCalledWith(
      `/api/workspaces/${alternateWorkspace}/executive-gantt`));
  });

  it("discards a stale workspace response after switching workspaces", async () => {
    let resolveOld!: (value: Response) => void;
    auth.fetch.mockReturnValueOnce(new Promise((done) => { resolveOld = done; }))
      .mockResolvedValueOnce(response([]));
    const onAccessLost = vi.fn();
    const { rerender } = render(<ExecutiveGanttHome workspaceId={workspace} onAccessLost={onAccessLost} />);
    rerender(<ExecutiveGanttHome workspaceId={alternateWorkspace} onAccessLost={onAccessLost} />);
    expect(await screen.findByText("Nenhum produto para mostrar no cronograma executivo.")).toBeInTheDocument();
    resolveOld(response(projection));
    await waitFor(() => expect(screen.queryByRole("table", { name: "Cronograma executivo" })).not.toBeInTheDocument());
  });
});
