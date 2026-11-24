import { fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { PrintSchedule } from "../src/PrintSchedule";
import { printSchedule } from "../src/print-dialog";

describe("print schedule document", () => {
  it("fits a long timeline to one width while preserving vertical pagination and a common scale", () => {
    const rows = Array.from({ length: 55 }, (_, index) => ({ key: String(index), label: `Stage ${index}`,
      kind: "stage", depth: 1, start: "2020-01-01", end: "2027-12-31" }));
    const { container } = render(<PrintSchedule title="Fit" rows={rows} milestones={[]} today="2026-06-01" fit="width" />);
    expect(container.querySelector(".print-document")).toHaveAttribute("data-print-density-warning", "true");
    const pages = [...container.querySelectorAll(".print-page")];
    expect(pages.length).toBeGreaterThan(1);
    expect(new Set(pages.map((page) => page.querySelector(".print-page__range")?.textContent)).size).toBe(1);
    expect(container.querySelectorAll(".print-table__row")).toHaveLength(55);
  });

  it("does not extend the selected period for hidden global or product-owned milestones", () => {
    const { container } = render(<PrintSchedule title="Fit" rows={[{
      key: "product", label: "Product", kind: "product", depth: 0, start: "2026-01-01", end: "2026-01-31",
      milestones: [{ id: "owned", name: "Hidden owned milestone", date: "2030-01-01", color: "#123456" }],
    }]} milestones={[{ id: "global", name: "Hidden milestone", date: "2032-01-01", color: "#654321" }]}
      today="2026-01-15" showMilestones={false} />);
    expect(container.querySelectorAll(".print-page")).toHaveLength(1);
    expect(container.querySelector(".print-page__range")).toHaveTextContent("01/01/2026");
    expect(container.querySelector(".print-page__range")).toHaveTextContent("31/01/2026");
    expect(container).not.toHaveTextContent("Hidden milestone");
  });

  it("fits all rows and milestone overflow to one logical sheet and clips visual dates only", () => {
    const rows = Array.from({ length: 55 }, (_, index) => ({ key: String(index), label: `Stage ${index}`,
      kind: "stage", depth: 1, start: "2026-01-01", end: "2026-12-31" }));
    const { container, rerender } = render(<PrintSchedule title="Fit" rows={rows}
      startDate="2026-02-01" endDate="2026-02-28" milestones={[
        { id: "outside", name: "Out-of-range target", date: "2026-03-01", color: "#123456" },
      ]} today="2026-02-05" fit="single" />);
    expect(container.querySelectorAll(".print-page")).toHaveLength(1);
    expect(container.querySelectorAll(".print-single-content .print-table__row")).toHaveLength(55);
    expect(container.querySelector(".print-single-content .print-event-continuation")).toHaveTextContent("Out-of-range target");
    expect(container.querySelector(".print-table__date")).toHaveTextContent("01/01/2026");
    expect(container.querySelector<HTMLElement>(".print-table__bar")?.style.width).toBe("268mm");
    expect(container.querySelector(".print-table__today")).toBeInTheDocument();
    rerender(<PrintSchedule title="Fit" rows={rows} startDate="2026-02-01" endDate="2026-02-28" milestones={[
      { id: "shown", name: "Hidden target", date: "2026-02-20", color: "#123456" },
    ]} today="2026-02-05" showToday={false} showMilestones={false} fit="single" />);
    expect(container).not.toHaveTextContent("Hidden target");
    expect(container.querySelector(".print-table__today")).not.toBeInTheDocument();
  });

  it("measures a one-sheet draft before printing and lets the user accept a below-threshold scale", () => {
    const measure = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      return this.matches(".print-single-content") ? new DOMRect(0, 0, 400 * 96 / 25.4, 552 * 96 / 25.4) : new DOMRect();
    });
    const print = vi.spyOn(window, "print").mockImplementation(() => {
      expect(document.body.querySelector(".print-single-content")).toHaveStyle({ transform: "scale(0.5)" });
    });
    function PrintButton() {
      const [printing, setPrinting] = useState(false);
      return <>
        <button onClick={() => printSchedule(setPrinting)}>Check print</button>
        <button onClick={() => printSchedule(setPrinting, true)}>Proceed</button>
        {printing && <PrintSchedule title="Fit" rows={[
          { key: "p", label: "Product", kind: "product", depth: 0, start: null, end: null },
        ]} milestones={[]} today="2026-01-01" fit="single" />}
      </>;
    }
    try {
      render(<PrintButton />);
      fireEvent.click(screen.getByRole("button", { name: "Check print" }));
      expect(print).not.toHaveBeenCalled();
      expect(document.body).not.toHaveClass("printing-schedule");
      expect(document.querySelector(".print-document")).toBeNull();
      fireEvent.click(screen.getByRole("button", { name: "Proceed" }));
      expect(print).toHaveBeenCalledOnce();
    } finally {
      measure.mockRestore();
      print.mockRestore();
    }
  });
  it("scopes identical milestones to their owning product and keeps a milestone-only date interval", () => {
    const rows = ["first", "second", "third"].map((key, index) => ({
      key, label: key, kind: "product", depth: 0, start: "2026-01-01", end: "2029-01-01",
      bars: [{ key: `${key}-dated`, label: "Arquitetura – Executivo", discipline: "Arquitetura", stageCode: "EX",
        start: "2026-01-01", end: "2026-03-30", color: "#123456", lane: 0 }],
      milestones: index < 2 ? [{ id: `${key}-event`, name: "Entrega", date: "2028-12-30",
        color: index === 0 ? "#123456" : "#654321" }] : [],
    }));
    const { container } = render(<PrintSchedule executiveProducts title="Executive" rows={rows}
      milestones={[]} today="2026-02-01" />);
    expect(container.querySelectorAll(".print-table > .print-event-band")).toHaveLength(0);
    const labels = [...container.querySelectorAll<HTMLElement>(".print-event")];
    expect(labels).toHaveLength(2);
    expect(labels.map((label) => label.closest<HTMLElement>("[data-print-row]")?.dataset.printRow))
      .toEqual(["first", "second"]);
    expect(labels.map((label) => label.textContent)).toEqual(["Entrega · 30/12/2028", "Entrega · 30/12/2028"]);
    const guides = [...container.querySelectorAll<HTMLElement>(".print-table__marker")];
    expect(guides.map((guide) => guide.closest<HTMLElement>("[data-print-row]")?.dataset.printRow))
      .toEqual(["first", "second"]);
    expect(guides[0].style.borderColor).not.toBe(guides[1].style.borderColor);
    expect(container.querySelectorAll('[data-print-row="third"]')).toHaveLength(1);
    expect(container).toHaveTextContent("ARQ · EX");
  });

  it("counts owned milestone bands in vertical pagination without splitting ordinary products", () => {
    const rows = Array.from({ length: 6 }, (_, index) => ({
      key: `p${index}`, label: `Product ${index}`, kind: "product", depth: 0, start: "2026-01-01", end: "2026-12-31",
      bars: [{ key: `b${index}`, label: "Arquitetura – Projeto Executivo", discipline: "Arquitetura",
        stageCode: "PEX", start: "2026-01-01", end: "2026-11-01", color: "#52694D", lane: 0 }],
      milestones: Array.from({ length: 6 }, (_, event) => ({ id: `e${index}-${event}`,
        name: `Entrega ${event}`, date: "2026-09-01", color: "#52694D" })),
    }));
    const { container } = render(<PrintSchedule executiveProducts title="Executive" rows={rows}
      milestones={[]} today="2027-01-01" />);
    expect(container.querySelectorAll(".print-page").length).toBeGreaterThan(1);
    const printedRows = [...container.querySelectorAll<HTMLElement>("[data-print-row]")];
    expect(printedRows.map((row) => row.dataset.printRow)).toEqual(rows.map(({ key }) => key));
    for (const row of printedRows) {
      expect(row).toHaveTextContent("ARQ · PEX");
      expect(row).toHaveTextContent("Entrega 5");
      expect(row.querySelectorAll(".print-table__marker")).toHaveLength(1);
    }
  });

  it("continues a very dense owned milestone list under its product name without repeating names", () => {
    const milestones = Array.from({ length: 110 }, (_, index) => ({
      id: `e${index}`, name: `Marco ${index} – ${"identificação completa ".repeat(5)}`.trim(),
      date: "2026-06-01", color: "#52694D",
    }));
    const { container } = render(<PrintSchedule executiveProducts title="Executive" rows={[
      { key: "p", label: "Product X", kind: "product", depth: 0, start: null, end: null, milestones },
    ]} milestones={[]} today="2026-07-01" />);
    expect(container.querySelectorAll("[data-print-row]")).toHaveLength(1);
    const sections = [...container.querySelectorAll(".print-event-continuation")];
    expect(sections.length).toBeGreaterThan(1);
    for (const section of sections) expect(section.querySelector("h2")).toHaveTextContent("Marcos e metas — Product X");
    const names = [...container.querySelectorAll(".print-event > span, .print-event-continuation strong")]
      .map((element) => element.textContent).sort();
    expect(names).toEqual(milestones.map(({ name }) => name).sort());
  });

  it("prints an owned milestone label once on an oversized product with stage continuations", () => {
    const bars = Array.from({ length: 54 }, (_, lane) => ({
      key: `b${lane}`, label: `Stage ${lane}`, lane, color: "#52694D",
      start: "2026-01-01", end: "2026-02-15",
    }));
    const { container } = render(<PrintSchedule executiveProducts title="Executive" rows={[
      { key: "p", label: "Dense product", kind: "product", depth: 0, start: null, end: null, bars,
        milestones: [{ id: "release", name: "Entrega", date: "2026-01-20", color: "#123456" }] },
    ]} milestones={[]} today="2026-07-01" />);
    expect(container.querySelectorAll(".print-page").length).toBeGreaterThan(1);
    expect(container.querySelectorAll(".print-event")).toHaveLength(1);
    expect(container.querySelectorAll(".print-table__marker").length).toBeGreaterThan(1);
    expect(container.querySelectorAll(".print-table__bar--stage")).toHaveLength(54);
  });
  it("uses the wider Executive Products plot and prints one legend outside it for multiple products", () => {
    const rows = ["first", "second"].map((key) => ({
      key, label: key, kind: "product", depth: 0, start: "2026-01-01", end: "2026-01-10",
      bars: [
        { key: `${key}-dated`, label: "Arquitetura – Estudo preliminar", discipline: "Arquitetura", stageCode: "EP",
          start: "2026-01-02", end: "2026-01-04", color: "#123456", dateSource: "planned" as const, lane: 0 },
        { key: `${key}-undated`, label: "Garagem – Executivo", lane: 0, color: "#123456", start: null, end: null },
      ],
    }));
    const { container } = render(<PrintSchedule executiveProducts title="Executive" rows={rows}
      milestones={[]} today="2026-02-01" />);
    expect(container.querySelectorAll(".print-table--executive-products .print-table__row")).toHaveLength(2);
    expect(container.querySelectorAll(".print-table__date")).toHaveLength(0);
    expect(container.querySelector(".print-table__label")).toHaveTextContent("01/01/2026 – 10/01/2026");
    const bars = [...container.querySelectorAll<HTMLElement>(".print-table__bar")];
    expect(bars).toHaveLength(2);
    for (const bar of bars) {
      expect(bar).toHaveTextContent("ARQ · EP");
      expect(bar.style.left).toBe("34mm");
      expect(bar.style.width).toBe("102mm");
      expect(bar).toHaveStyle({ backgroundColor: "#123456" });
      expect(bar).toHaveAttribute("data-date-source", "planned");
    }
    expect(container.querySelectorAll(".print-table__chart .print-table__bar-notes")).toHaveLength(0);
    expect(container.querySelector(".print-table__bar-notes")).toHaveTextContent("Etapas sem data: Garagem – Executivo");
    expect(container.querySelectorAll(".print-executive-key")).toHaveLength(1);
    expect(container.querySelector(".print-executive-key")).toHaveTextContent("Siglas: ARQ = Arquitetura");
  });
  it("uses measured wrapped rows to fill the sheet before adding a continuation", () => {
    const px = (mm: number) => mm * 96 / 25.4;
    const measure = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      if (this.matches(".print-table__row")) return new DOMRect(0, 0, px(400), px(5.5));
      if (this.matches(".print-table__head")) return new DOMRect(0, px(35), px(400), px(7));
      if (this.matches(".print-page__footer")) return new DOMRect(0, px(280), px(400), px(6));
      return new DOMRect();
    });
    const rows = Array.from({ length: 40 }, (_, index) => ({
      key: String(index), kind: "activity", depth: 3, label: `Narrow glyphs in activity ${index} for this schedule`,
      start: "2026-01-01", end: "2026-01-31",
    }));
    function PrintButton() {
      const [printing, setPrinting] = useState(false);
      return <><button onClick={() => printSchedule(setPrinting)}>Print</button>
        {printing && <PrintSchedule title="Product" rows={rows} milestones={[]} today="2026-02-01" />}</>;
    }
    const print = vi.spyOn(window, "print").mockImplementation(() => {
      expect(document.body.querySelectorAll(".print-page")).toHaveLength(1);
      expect(document.body.querySelectorAll(".print-table__row")).toHaveLength(40);
    });
    try {
      render(<PrintButton />);
      fireEvent.click(screen.getByRole("button", { name: "Print" }));
      expect(print).toHaveBeenCalledOnce();
    } finally {
      print.mockRestore();
      measure.mockRestore();
    }
  });

  it("shows both short edge months, labels today, and retains stage date sources", () => {
    const { container } = render(<PrintSchedule title="Product"
      startDate="2026-01-31" endDate="2026-05-01" today="2026-03-01" milestones={[]} rows={[
        { key: "1", kind: "stage", depth: 2, label: "Planned", start: "2026-01-31", end: "2026-03-31", dateSource: "planned" },
        { key: "2", kind: "stage", depth: 2, label: "Derived", start: "2026-04-01", end: "2026-05-01", dateSource: "derived" },
        { key: "3", kind: "stage", depth: 2, label: "Derived boundary", start: null, end: "2026-05-01",
          dateSource: "derived", color: "#123456" },
      ]} />);
    expect(container.querySelector(".print-table__head strong")).toHaveTextContent("Cronograma");
    const track = container.querySelector(".print-table__timeline");
    expect(track).toHaveTextContent("01/2026");
    expect(track).toHaveTextContent("05/2026");
    expect(track?.querySelector(".print-table__today-label")).toHaveTextContent("Hoje");
    expect(container.querySelector(".print-table__bar[data-date-source='planned']")).toBeInTheDocument();
    expect(container.querySelector(".print-table__bar[data-date-source='derived']")).toBeInTheDocument();
    expect(container.querySelector(".print-table__boundary[data-date-source='derived']"))
      .toHaveStyle({ borderColor: "#123456" });
  });
  it("labels normal milestones on the schedule sheet and stacks same-day names", () => {
    const milestones = [
      { id: "m1", name: "First milestone", date: "2026-01-01", color: "#52694D" },
      { id: "m2", name: "Second milestone", date: "2026-01-01", color: "#123456" },
    ];
    const { container } = render(<PrintSchedule title="Product" detail="Cronograma ativo" rows={[
      { key: "undated", label: "Undated activity", kind: "activity", depth: 1, start: null, end: null },
    ]} milestones={milestones} startDate="2026-01-01" endDate="2026-12-31" today="2026-11-24" />);
    expect(container.querySelectorAll(".print-page")).toHaveLength(1);
    expect(container.querySelector(".print-event-continuation")).not.toBeInTheDocument();
    const labels = [...container.querySelectorAll<HTMLElement>(".print-event")];
    expect(labels.map((label) => label.querySelector("span")?.textContent)).toEqual(milestones.map(({ name }) => name));
    expect(labels[0]).toHaveTextContent("01/01/2026");
    expect(new Set(labels.map((label) => label.style.top)).size).toBe(2);
    expect(container.querySelectorAll(".print-table__marker")).toHaveLength(1);
    expect((container.querySelector<HTMLElement>(".print-event__guide")?.style.left))
      .toBe(container.querySelector<HTMLElement>(".print-table__marker")?.style.left);
    expect(container).toHaveTextContent("Undated activity");
    expect(container).toHaveTextContent("Cronograma ativo");
  });

  it("only sends excess milestone names to continuation sheets", () => {
    const milestones = Array.from({ length: 65 }, (_, index) => ({ id: `m${index}`,
      name: `Management milestone ${index + 1}`, date: "2026-01-01", color: "#52694D" }));
    const { container } = render(<PrintSchedule title="Product schedule" rows={[
      { key: "product", label: "Product schedule", kind: "product", depth: 0,
        start: "2026-01-01", end: "2026-01-01", hasChildren: false }
    ]} milestones={milestones} startDate="2026-01-01" endDate="2026-01-01" today="2026-11-24" />);
    expect(container.querySelectorAll(".print-page").length).toBeGreaterThan(1);
    expect(container.querySelectorAll(".print-table__row")).toHaveLength(1);
    expect(container.querySelectorAll(".print-event-continuation").length).toBeGreaterThan(0);
    expect(container.querySelector(".print-table__marker b")).toHaveTextContent("+");
    expect([...container.querySelectorAll(".print-event span, .print-event-continuation strong")]
      .map((element) => element.textContent).sort()).toEqual(milestones.map(({ name }) => name).sort());
    expect(container.querySelectorAll(".print-page__footer")).toHaveLength(container.querySelectorAll(".print-page").length);
  });

  it("continues a densely packed product while keeping all stage bars and full labels", () => {
    const bars = Array.from({ length: 54 }, (_, lane) => ({
      key: String(lane), label: `Discipline – Stage ${lane}`, lane, color: "#52694D",
      start: "2026-01-01", end: "2026-02-15",
    }));
    const { container } = render(<PrintSchedule title="Executive" rows={[
      { key: "p", label: "Product", kind: "product", depth: 0, start: "2026-01-01", end: "2026-02-15", bars },
    ]} milestones={[]} today="2026-11-24" />);
    const pages = [...container.querySelectorAll(".print-page")];
    expect(pages.length).toBeGreaterThan(1);
    for (const page of pages) {
      expect(page.querySelector(".print-table__label")).toHaveTextContent("Product");
      expect(page.querySelector(".print-page__footer")).toBeInTheDocument();
      expect(page.querySelectorAll(".print-table__bar--stage").length).toBeLessThanOrEqual(44);
    }
    expect([...container.querySelectorAll(".print-table__bar--stage")].map((bar) => bar.textContent))
      .toEqual(bars.map(({ label }) => label));
  });

  it("connects a narrow stage bar directly to its full external label and keeps undated stages off the timeline", () => {
    const { container } = render(<PrintSchedule title="Executive" rows={[
      { key: "p", label: "Product", kind: "product", depth: 0, start: "2026-01-01", end: "2026-03-01", bars: [
        { key: "s", label: "Discipline – A narrow stage", lane: 0, color: "#52694D", start: "2026-02-05", end: "2026-02-05" },
        { key: "u", label: "Discipline – Undated stage", lane: 0, color: "#52694D", start: null, end: null },
      ] },
    ]} milestones={[]} today="2026-11-24" />);
    expect(container.querySelector(".print-table__bar--stage")).toBeEmptyDOMElement();
    expect(container.querySelector(".print-stage__callout")).toHaveTextContent("Discipline – A narrow stage");
    expect(container.querySelector(".print-stage__leader")).toBeInTheDocument();
    expect(container.querySelector(".print-table__bar-notes")).toHaveTextContent("Etapas sem data: Discipline – Undated stage");
    expect(container.querySelectorAll(".print-stage")).toHaveLength(1);
  });

  it("prints multiple packed products with unique references for same-color dense stages", () => {
    const rows = ["first", "second", "third", "fourth"].map((key) => ({
      key, label: key, kind: "product", depth: 0, start: "2026-01-01", end: "2026-12-31",
      bars: Array.from({ length: 12 }, (_, lane) => ({
        key: `${key}-${lane}`, label: "Same discipline – Same stage", lane, color: "#52694D",
        start: "2026-04-01", end: "2026-04-01",
      })),
    }));
    const { container } = render(<PrintSchedule title="Executive" rows={rows} milestones={[]} today="2027-01-01" />);
    expect(container.querySelectorAll(".print-page").length).toBeGreaterThan(1);
    expect(container.querySelectorAll(".print-table__row")).toHaveLength(4);
    const badges = [...container.querySelectorAll(".print-stage__badge")].map((badge) => badge.textContent);
    expect(new Set(badges).size).toBe(48);
    const entries = [...container.querySelectorAll(".print-table__bar-notes strong")].map((entry) => entry.textContent);
    expect(entries).toEqual(badges);
    expect(container.querySelectorAll(".print-stage__reference-leaders line")).toHaveLength(48);
  });

  it("keeps a common physical scale across dates and preserves vertical continuation", () => {
    const rows = Array.from({ length: 48 }, (_, index) => ({
      key: String(index), label: `Activity ${index}`, kind: "activity", depth: 1,
      start: "2020-01-01", end: "2026-01-09",
    }));
    const { container } = render(<PrintSchedule title="Product" rows={rows} milestones={[]}
      startDate="2020-01-01" endDate="2026-01-09" today="2026-11-24" />);
    const pages = [...container.querySelectorAll(".print-page")];
    const byRange = new Map<string, Element[]>();
    for (const page of pages) {
      const range = page.querySelector(".print-page__range")!.textContent!;
      byRange.set(range, [...(byRange.get(range) ?? []), page]);
    }
    expect(byRange.size).toBeGreaterThan(1);
    for (const intervalPages of byRange.values()) {
      expect(intervalPages.length).toBeGreaterThan(1);
      expect(intervalPages.flatMap((page) => [...page.querySelectorAll(".print-table__label")]
        .map((cell) => cell.textContent))).toEqual(rows.map(({ label }) => label));
    }
    expect(parseFloat(pages.at(-1)!.querySelector<HTMLElement>(".print-table__bar")!.style.width)).toBeLessThan(268);
  });
});
