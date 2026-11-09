import { act, fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { makeTimeline, timelinePosition, type ScheduleTree } from "../domain/schedule-workspace";
import { ScheduleWorkspace } from "../src/ScheduleWorkspace";

const tree: ScheduleTree = { disciplines: [{ id: "discipline", name: "Synthetic discipline",
  shortCode: "SD", color: "#225588", displayOrder: 0,
  stages: [{ id: "stage", displayName: "Synthetic stage", code: "EC", color: "#336699",
    displayOrder: 0, derivedStart: "2026-11-01", derivedEnd: "2028-01-17",
    activities: [{ id: "activity", name: "Synthetic activity", plannedStart: "2026-11-01",
      plannedEnd: "2028-01-17", displayOrder: 0 }] }] }] };
const targets = [{ id: "target", name: "Synthetic target", targetDate: "2026-11-07",
  operationalDate: null, displayOrder: 0 }];

function mount() {
  return render(<ScheduleWorkspace product={{ id: "product", name: "Synthetic product" }} tree={tree}
    targets={targets} openDisciplines={new Set(["discipline"])} openStages={new Set(["stage"])}
    canEdit onToggle={vi.fn()} onEdit={vi.fn()} onAdd={vi.fn()} onHistory={vi.fn()} />);
}

describe("schedule workspace refinements", () => {
  it("keeps one visible horizontal scrollbar outside the long vertical row scroller", () => {
    const { container } = mount();
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
    fireEvent.change(screen.getByLabelText("Escala"), { target: { value: "month" } });
    expect(container.querySelector<HTMLElement>(".timeline-selected-column")!.dataset.date).toBe("2026-11-08");
    expect(container.querySelector<HTMLElement>(".timeline-selected-column")!.style.width).toBe("4px");
    fireEvent.keyDown(header, { key: "ArrowRight" });
    expect(screen.getByRole("status")).toHaveTextContent("09/11/2026");
    fireEvent.click(screen.getByRole("button", { name: "Limpar data selecionada" }));
    expect(container.querySelector(".timeline-selected-column")).not.toBeInTheDocument();
    expect(container.querySelector(".timeline-today-line")).toBeInTheDocument();
    expect(container.querySelector(".timeline-target-line")).toBeInTheDocument();
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
