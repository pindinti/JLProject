import { act, fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { makeTimeline, timelinePosition, type ScheduleTarget, type ScheduleTree } from "../domain/schedule-workspace";
import { ScheduleWorkspace } from "../src/ScheduleWorkspace";

const tree: ScheduleTree = { disciplines: [{ id: "discipline", name: "Synthetic discipline",
  shortCode: "SD", color: "#225588", displayOrder: 0,
  stages: [{ id: "stage", displayName: "Synthetic stage", code: "EC", color: "#336699",
    displayOrder: 0, derivedStart: "2026-11-01", derivedEnd: "2028-01-17",
    activities: [{ id: "activity", name: "Synthetic activity", plannedStart: "2026-11-01",
      plannedEnd: "2028-01-17", displayOrder: 0 }] }] }] };
const targets = [{ id: "target", name: "Synthetic target", targetDate: "2026-11-07",
  description: null, color: "#AA4557", operationalDate: null, displayOrder: 0, version: 1 }];

function mount(canEdit = true) {
  return render(<ScheduleWorkspace product={{ id: "product", name: "Synthetic product" }} tree={tree}
    targets={targets} openDisciplines={new Set(["discipline"])} openStages={new Set(["stage"])}
    canEdit={canEdit} onToggle={vi.fn()} onEdit={vi.fn()} onAdd={vi.fn()} onHistory={vi.fn()}
    onAddDiscipline={vi.fn()} onRefresh={vi.fn()}
    onCreateTarget={vi.fn(async (value) => ({ id: "created", ...value, operationalDate: null, displayOrder: 1, version: 1 }))}
    onUpdateTarget={vi.fn(async (target, value) => ({ ...target, ...value, version: target.version + 1 }))}
    onDeleteTarget={vi.fn(async () => undefined)} />);
}

describe("schedule workspace refinements", () => {
  it("keeps one visible horizontal scrollbar outside the long vertical row scroller", () => {
    const { container } = mount();
    expect(container.querySelector(".schedule-workspace")).toHaveAttribute("data-density", "compact");
    expect([...container.querySelectorAll<HTMLElement>(".workspace-table-row")].map((row) => row.dataset.rowKey?.split(":")[0]))
      .toEqual(["product", "discipline", "stage", "activity"]);
    expect([...container.querySelectorAll<HTMLElement>(".workspace-table-row")].map((row) => row.dataset.rowKey))
      .toEqual([...container.querySelectorAll<HTMLElement>(".workspace-chart-row")].map((row) => row.dataset.rowKey));
    expect(container.querySelector(".timeline-target-label")).toHaveTextContent("Synthetic target");
    expect(container.querySelector<HTMLElement>(".timeline-target-label")!.title).toContain("Synthetic target");
    expect(container.querySelector(".timeline-target-line")).toHaveStyle({ borderColor: "#AA4557" });
    expect(container.querySelector(".timeline-bar.bar-activity")).toHaveStyle({ backgroundColor: "#336699" });
    const body = container.querySelector<HTMLElement>(".workspace-body")!;
    const footer = container.querySelector<HTMLElement>(".workspace-scrollbar-row")!;
    const scrollbar = container.querySelector<HTMLElement>(".workspace-horizontal-scroll")!;
    const header = container.querySelector<HTMLElement>(".workspace-timeline-header")!;
    const chart = container.querySelector<HTMLElement>(".workspace-chart-scroll")!;
    expect(body.contains(footer)).toBe(false);
    const today = container.querySelector<HTMLElement>(".timeline-today-line")!.dataset.date!;
    expect(container.querySelector(".workspace-horizontal-content"))
      .toHaveStyle({ width: `${makeTimeline(tree, targets, "week", today).width}px` });
    body.scrollTop = 300;
    scrollbar.scrollLeft = 240;
    fireEvent.scroll(scrollbar);
    expect(header.scrollLeft).toBe(240);
    expect(chart.scrollLeft).toBe(240);
    expect(body.scrollTop).toBe(300);
    chart.scrollLeft = 360;
    fireEvent.scroll(chart);
    expect(scrollbar.scrollLeft).toBe(360);
    expect(header.scrollLeft).toBe(360);
    const split = container.querySelector<HTMLElement>(".workspace-split")!;
    expect(split.style.getPropertyValue("--table-width")).toBe("50%");
    fireEvent.keyDown(screen.getByRole("separator"), { key: "ArrowRight" });
    expect(split.style.getPropertyValue("--table-width")).toBe("55%");
    expect(container.querySelectorAll(".workspace-divider-header, .workspace-divider, .workspace-divider-footer")).toHaveLength(3);
  });

  it("selects exact dates from header and empty grid while keeping bars selectable", () => {
    const { container } = mount();
    const header = container.querySelector<HTMLElement>(".workspace-timeline-header")!;
    const chart = container.querySelector<HTMLElement>(".workspace-chart-scroll")!;
    vi.spyOn(header, "getBoundingClientRect").mockReturnValue({ left: 10 } as DOMRect);
    vi.spyOn(chart, "getBoundingClientRect").mockReturnValue({ left: 10 } as DOMRect);
    const today = container.querySelector<HTMLElement>(".timeline-today-line")!.dataset.date!;
    const scale = makeTimeline(tree, targets, "week", today);
    const left = timelinePosition(scale, "2026-11-07");
    fireEvent.click(header, { clientX: left + 11 });
    expect(screen.getByRole("status")).toHaveTextContent("Data selecionada: 07/11/2026");
    const selection = container.querySelector<HTMLElement>(".timeline-selected-column")!;
    expect(selection.dataset.date).toBe("2026-11-07");
    expect(selection.style.left).toBe(`${left}px`);
    expect(container.querySelector<HTMLElement>(".timeline-target-line")!.style.left).toBe(selection.style.left);
    expect(container.querySelector<HTMLElement>(".timeline-today-line")!.style.left)
      .toBe(`${timelinePosition(scale, today)}px`);
    fireEvent.click(chart, { clientX: left + scale.dayWidth + 11 });
    expect(screen.getByRole("status")).toHaveTextContent("08/11/2026");
    fireEvent.click(container.querySelector(".timeline-bar.bar-activity")!);
    expect(screen.getByRole("status")).toHaveTextContent("08/11/2026");
    expect(container.querySelector(".workspace-table-row.row-activity")).toHaveClass("selected");
    fireEvent.click(screen.getByRole("button", { name: "Mês" }));
    expect(screen.getByRole("button", { name: "Mês" })).toHaveAttribute("aria-pressed", "true");
    expect(container.querySelector<HTMLElement>(".timeline-selected-column")!.dataset.date).toBe("2026-11-08");
    expect(container.querySelector<HTMLElement>(".timeline-selected-column")!.style.width).toBe("4px");
    fireEvent.keyDown(header, { key: "ArrowRight" });
    expect(screen.getByRole("status")).toHaveTextContent("09/11/2026");
    fireEvent.click(screen.getByRole("button", { name: "Limpar data selecionada" }));
    expect(container.querySelector(".timeline-selected-column")).not.toBeInTheDocument();
    expect(container.querySelector(".timeline-today-line")).toBeInTheDocument();
    expect(container.querySelector(".timeline-target-line")).toBeInTheDocument();
  });

  it("centers and selects the São Paulo date without changing schedule view state", () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date("2026-11-07T02:00:00Z"));
      const { container } = mount();
      const chart = container.querySelector<HTMLElement>(".workspace-chart-scroll")!;
      const scrollbar = container.querySelector<HTMLElement>(".workspace-horizontal-scroll")!;
      const body = container.querySelector<HTMLElement>(".workspace-body")!;
      Object.defineProperty(chart, "clientWidth", { configurable: true, value: 400 });
      Object.defineProperty(scrollbar, "clientWidth", { configurable: true, value: 400 });
      Object.defineProperty(scrollbar, "scrollWidth", { configurable: true, value: 3000 });

      fireEvent.click(screen.getByRole("button", { name: "Synthetic activity" }));
      body.scrollTop = 63;
      fireEvent.click(screen.getByRole("button", { name: "Mês" }));
      fireEvent.click(screen.getByRole("button", { name: "Ir para hoje" }));

      expect(screen.getByRole("status")).toHaveTextContent("Data selecionada: 06/11/2026");
      expect(container.querySelector<HTMLElement>(".timeline-selected-column")?.dataset.date).toBe("2026-11-06");
      expect(container.querySelector<HTMLElement>(".timeline-today-line")?.dataset.date).toBe("2026-11-06");
      expect(screen.getByRole("button", { name: "Mês" })).toHaveAttribute("aria-pressed", "true");
      expect(body.scrollTop).toBe(63);
      expect(container.querySelector('.workspace-table-row[data-row-key="activity:activity"]')).toHaveClass("selected");
      expect(container.querySelectorAll(".workspace-table-row")).toHaveLength(4);
      expect(container.querySelectorAll('.workspace-expand[aria-expanded="true"]')).toHaveLength(3);

      const selectedColumn = container.querySelector<HTMLElement>(".timeline-selected-column")!;
      const todayLine = container.querySelector<HTMLElement>(".timeline-today-line")!;
      const selectedCenter = Number.parseFloat(todayLine.style.left) + Number.parseFloat(selectedColumn.style.width) / 2;
      expect(Math.abs(scrollbar.scrollLeft + chart.clientWidth / 2 - selectedCenter)).toBeLessThanOrEqual(1);
      expect(container.querySelector<HTMLElement>(".workspace-timeline-header")!.scrollLeft).toBe(scrollbar.scrollLeft);
      expect(chart.scrollLeft).toBe(scrollbar.scrollLeft);
    } finally { vi.useRealTimers(); }
  });

  it("keeps row selection on single click and opens the contextual editor on double click", () => {
    const onEdit = vi.fn();
    const onAdd = vi.fn();
    const { container } = render(<ScheduleWorkspace product={{ id: "product", name: "Synthetic product" }} tree={tree}
      targets={targets} openDisciplines={new Set(["discipline"])} openStages={new Set(["stage"])} canEdit
      onToggle={vi.fn()} onEdit={onEdit} onAdd={onAdd} onHistory={vi.fn()} onAddDiscipline={vi.fn()} onRefresh={vi.fn()}
      onCreateTarget={vi.fn()} onUpdateTarget={vi.fn()} onDeleteTarget={vi.fn()} />);
    const name = screen.getByRole("button", { name: "Synthetic activity" });

    fireEvent.click(name);
    expect(container.querySelector('.workspace-table-row[data-row-key="activity:activity"]')).toHaveClass("selected");
    expect(onEdit).not.toHaveBeenCalled();

    fireEvent.doubleClick(name);
    expect(onEdit).toHaveBeenCalledWith(expect.objectContaining({ kind: "activity", id: "activity" }));
    fireEvent.doubleClick(container.querySelector('.workspace-table-row[data-row-key="activity:activity"] .workspace-date-cell')!);
    expect(onEdit).toHaveBeenCalledTimes(2);

    expect(screen.getByRole("button", { name: "Editar atividade" }).querySelector("svg")).toHaveAttribute("aria-hidden", "true");
    expect(screen.getByRole("button", { name: "Adicionar etapa" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Adicionar atividade" })).toBeInTheDocument();
    const productRow = container.querySelector<HTMLElement>('[data-row-key="product:product"]')!;
    const activityRow = container.querySelector<HTMLElement>('[data-row-key="activity:activity"]')!;
    expect(within(productRow).queryByRole("button", { name: /Editar|Adicionar/ })).not.toBeInTheDocument();
    expect(within(activityRow).queryByRole("button", { name: /Adicionar/ })).not.toBeInTheDocument();
    const disciplineNameCell = container.querySelector('[data-row-key="discipline:discipline"] .workspace-name-cell')!;
    const childOrder = [...disciplineNameCell.children].map((child) => (child as HTMLElement).className);
    expect(childOrder.indexOf("workspace-expand")).toBeLessThan(childOrder.indexOf("workspace-inline-actions"));
    expect(childOrder.indexOf("workspace-inline-actions")).toBeLessThan(childOrder.indexOf("workspace-row-name"));
    expect(container.querySelectorAll(".workspace-row-actions")).toHaveLength(0);
  });

  it("opens a create dialog from the toolbar with the selected date and creates a synthetic milestone", async () => {
    const onCreate = vi.fn(async (value: { name: string; description: string | null; targetDate: string; color: string }) =>
      ({ id: "created", ...value, operationalDate: null, displayOrder: 1, version: 1 }));
    const { container } = render(<ScheduleWorkspace product={{ id: "product", name: "Synthetic product" }} tree={tree}
      targets={targets} openDisciplines={new Set(["discipline"])} openStages={new Set(["stage"])} canEdit
      onToggle={vi.fn()} onEdit={vi.fn()} onAdd={vi.fn()} onHistory={vi.fn()} onAddDiscipline={vi.fn()} onRefresh={vi.fn()} onCreateTarget={onCreate}
      onUpdateTarget={vi.fn(async (target, value) => ({ ...target, ...value, version: 2 }))}
      onDeleteTarget={vi.fn(async () => undefined)} />);
    const header = container.querySelector<HTMLElement>(".workspace-timeline-header")!;
    vi.spyOn(header, "getBoundingClientRect").mockReturnValue({ left: 0 } as DOMRect);
    const today = container.querySelector<HTMLElement>(".timeline-today-line")!.dataset.date!;
    const scale = makeTimeline(tree, targets, "week", today);
    fireEvent.click(header, { clientX: timelinePosition(scale, "2026-11-08") + 1 });
    fireEvent.click(screen.getByRole("button", { name: "Adicionar marco" }));
    expect(screen.getByLabelText("Data")).toHaveValue("08/11/2026");
    fireEvent.change(screen.getByLabelText("Nome"), { target: { value: "Marco sintético" } });
    fireEvent.submit(screen.getByRole("dialog"));
    await act(async () => { await Promise.resolve(); });
    expect(onCreate).toHaveBeenCalledWith({ name: "Marco sintético", description: null,
      targetDate: "2026-11-08", color: "#AA4557" });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("opens existing targets for viewer inspection without mutation controls", () => {
    const { container } = mount(false);
    fireEvent.click(container.querySelector(".timeline-target-line")!);
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(screen.getByLabelText("Nome")).toHaveValue("Synthetic target");
    expect(screen.getByLabelText("Nome")).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Salvar meta" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Excluir meta" })).not.toBeInTheDocument();
  });

  it("requires an audit reason for date edits and confirms synthetic target deletion", async () => {
    const onUpdate = vi.fn(async (target: ScheduleTarget, value: { name: string; description: string | null;
      targetDate: string; color: string; reason: string | null }) => ({ ...target, ...value, version: 2 }));
    const onDelete = vi.fn(async () => undefined);
    const first = render(<ScheduleWorkspace product={{ id: "product", name: "Synthetic product" }} tree={tree} targets={targets}
      openDisciplines={new Set(["discipline"])} openStages={new Set(["stage"])} canEdit
      onToggle={vi.fn()} onEdit={vi.fn()} onAdd={vi.fn()} onHistory={vi.fn()} onAddDiscipline={vi.fn()} onRefresh={vi.fn()} onCreateTarget={vi.fn()}
      onUpdateTarget={onUpdate} onDeleteTarget={onDelete} />);
    fireEvent.click(first.container.querySelector(".timeline-target-label")!);
    fireEvent.change(screen.getByLabelText("Data"), { target: { value: "08/11/2026" } });
    fireEvent.submit(screen.getByRole("dialog"));
    expect(await screen.findByRole("alert")).toHaveTextContent("justificativa com pelo menos 10 caracteres");
    expect(onUpdate).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText("Justificativa da alteração da data"),
      { target: { value: "Synthetic date adjustment" } });
    fireEvent.submit(screen.getByRole("dialog"));
    await act(async () => { await Promise.resolve(); });
    expect(onUpdate).toHaveBeenCalledWith(targets[0], expect.objectContaining({
      targetDate: "2026-11-08", reason: "Synthetic date adjustment"
    }));

    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
    const second = render(<ScheduleWorkspace product={{ id: "product", name: "Synthetic product" }} tree={tree} targets={targets}
      openDisciplines={new Set(["discipline"])} openStages={new Set(["stage"])} canEdit
      onToggle={vi.fn()} onEdit={vi.fn()} onAdd={vi.fn()} onHistory={vi.fn()} onAddDiscipline={vi.fn()} onRefresh={vi.fn()} onCreateTarget={vi.fn()}
      onUpdateTarget={onUpdate} onDeleteTarget={onDelete} />);
    fireEvent.click(second.container.querySelector(".timeline-target-label")!);
    fireEvent.click(within(second.container).getByRole("button", { name: "Excluir meta" }));
    await act(async () => { await Promise.resolve(); });
    expect(confirm).toHaveBeenCalledWith(expect.stringContaining("Synthetic target"));
    expect(onDelete).toHaveBeenCalledWith(targets[0]);
    confirm.mockRestore();
  });

  it("updates the Today marker when São Paulo reaches a new calendar date", () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date("2026-11-07T02:59:50Z"));
      const { container } = mount();
      expect(container.querySelector<HTMLElement>(".timeline-today-line")!.dataset.date).toBe("2026-11-06");
      act(() => { vi.advanceTimersByTime(30_000); });
      expect(container.querySelector<HTMLElement>(".timeline-today-line")!.dataset.date).toBe("2026-11-07");
    } finally { vi.useRealTimers(); }
  });
});
