import { cleanup, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { PrintSchedule } from "../src/PrintSchedule";
import { printSchedule } from "../src/print-dialog";

const originalTitle = "JLProject";

afterEach(() => {
  vi.restoreAllMocks();
  cleanup();
  document.title = originalTitle;
});

function printDocument(title: string, today: string, executive = false, fit?: "width" | "single") {
  const view = render(<div />);
  return () => printSchedule((active) => view.rerender(active
    ? <PrintSchedule title={title} today={today} executive={executive} fit={fit}
      rows={[{ key: "p", label: title, kind: "product", depth: 0,
        start: "2026-11-01", end: "2026-11-30" }]} milestones={[]} />
    : <div />), true);
}

describe("schedule print title", () => {
  it.each([
    ["Multi 05 Beach", "JLProject_crono_Multi_05_Beach_24_11_2026"],
    ["  São__Paulo / Torre:*? \"A\"<>|.PDF.pdf  ", "JLProject_crono_São_Paulo_Torre_A_24_11_2026"],
    ["<>|", "JLProject_crono_produto_24_11_2026"],
  ])("uses the issue date and a safe product name for %s", (product, expected) => {
    document.title = originalTitle;
    const nativePrint = vi.spyOn(window, "print").mockImplementation(() => {
      expect(document.title).toBe(expected);
      expect(document.querySelector(".print-document")).toHaveTextContent("Emitido em: 24/11/2026");
    });

    expect(printDocument(product, "2026-11-24")()).toBe(true);
    expect(nativePrint).toHaveBeenCalledOnce();
    expect(document.title).toBe(originalTitle);
  });

  it("restores the title on native dialog close and uses fresh metadata for consecutive jobs", () => {
    document.title = originalTitle;
    const titles: string[] = [];
    vi.spyOn(window, "print").mockImplementation(() => { titles.push(document.title); });

    printDocument("Multi 05 Beach", "2026-11-24", false, "single")();
    expect(document.title).toBe(originalTitle);
    printDocument("Executive view at any detail level", "2026-11-25", true, "width")();
    expect(document.title).toBe(originalTitle);
    printDocument("Another Product", "2026-11-26")();
    expect(document.title).toBe(originalTitle);
    expect(titles).toEqual([
      "JLProject_crono_Multi_05_Beach_24_11_2026",
      "JLProject_crono_executivo_25_11_2026",
      "JLProject_crono_Another_Product_26_11_2026",
    ]);
  });

  it("restores the original title and removes print output when native printing throws", () => {
    document.title = "JLProject - Schedule";
    vi.spyOn(window, "print").mockImplementation(() => {
      expect(document.title).toBe("JLProject_crono_Product_24_11_2026");
      throw new Error("Native printing failed");
    });

    expect(printDocument("Product", "2026-11-24")).toThrow("Native printing failed");
    expect(document.title).toBe("JLProject - Schedule");
    expect(document.querySelector(".print-document")).toBeNull();
    expect(document.body).not.toHaveClass("printing-schedule");
  });
});
