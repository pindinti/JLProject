import { describe, expect, it } from "vitest";
import { layoutPrintStageLabels, printDisciplineAbbreviations, printStageIdentities } from "../src/print-stage-labels";

const measure = (text: string) => text.length;

describe("executive print stage labels", () => {
  it("keeps compact identifiers stable, reusing the stage name when a code is ambiguous", () => {
    const first = { label: "Arquitetura – Anteprojeto", discipline: "Arquitetura", stageCode: "A", stageName: "Anteprojeto" };
    const second = { ...first, label: "Arquitetura – Alvará", stageName: "Alvará" };
    const third = { ...first, stageCode: "EP", stageName: "Estudo preliminar" };
    const labels = printStageIdentities([first, second, third], printDisciplineAbbreviations(["Arquitetura"]), true);
    expect(labels.get(first)).toEqual([{ text: "ARQ · Anteprojeto", abbreviation: "ARQ" }]);
    expect(labels.get(second)).toEqual([{ text: "ARQ · Alvará", abbreviation: "ARQ" }]);
    expect(labels.get(third)).toEqual([{ text: "ARQ · EP", abbreviation: "ARQ" }]);
  });

  it("keeps a callout clear of milestones and adds a lane only for a blocked label", () => {
    const labels = [{ text: "ARQ · EP" }];
    const plots = [
      { left: 0, width: 19, lane: 0, labels, reference: 1 },
      { left: 20, width: 2, lane: 0, labels, reference: 2 },
      { left: 24, width: 30, lane: 0, labels, reference: 3 },
    ];
    const layout = layoutPrintStageLabels(plots, 70, measure, [28], true);
    const short = layout.bars.find(({ reference }) => reference === 2)!;
    expect(short).toMatchObject({ left: 20, width: 2, top: 5 });
    expect(short.outside?.left).toBeLessThan(20);
    expect(layout.bars.filter((bar) => bar.badge)).toHaveLength(0);
    expect(layout.height).toBe(10);
  });
  it("chooses the most descriptive label that fits, then an adjacent callout", () => {
    const stage = { label: "Arquitetura – Estudo preliminar", discipline: "Arquitetura", stageCode: "EP" };
    const labels = printStageIdentities([stage], printDisciplineAbbreviations(["Arquitetura"])).get(stage)!;
    const result = layoutPrintStageLabels([40, 20, 12, 2].map((width, lane) =>
      ({ left: 10, width, lane, labels, reference: lane + 1 })), 80, measure);
    expect(result.bars.map((bar) => bar.inside?.text)).toEqual([
      stage.label, "Arquitetura – EP", "ARQ – EP", undefined,
    ]);
    expect(result.bars[3].outside).toMatchObject({ text: stage.label, leaderLeft: 12 });
    expect(result.height).toBe(20);
  });

  it("does not assign the same alias to custom disciplines or abbreviate ambiguous stage codes", () => {
    const aliases = printDisciplineAbbreviations(["Arquitetura", "Arquivo", "Arquivamento", "Comunicação Visual"]);
    expect(aliases.get("Arquitetura")).toBe("ARQ");
    expect(aliases.get("Comunicação Visual")).toBe("CV");
    expect(new Set(aliases.values()).size).toBe(4);
    const first = { label: "Arquitetura – Revisão pública", discipline: "Arquitetura", stageCode: "R" };
    const second = { ...first, label: "Arquitetura – Revisão técnica" };
    const identities = printStageIdentities([first, second], aliases);
    expect(identities.get(first)).toEqual([{ text: first.label }]);
    expect(identities.get(second)).toEqual([{ text: second.label }]);
  });

  it("keeps dense reference badges disjoint, inside the timeline and attached to their exact bar", () => {
    const plots = Array.from({ length: 20 }, (_, index) => ({
      left: index * 3, width: 3, lane: 0, labels: [], reference: index + 98,
    }));
    const result = layoutPrintStageLabels(plots, 60, measure);
    expect(result.height).toBeGreaterThan(10);
    const ends = new Map<number, number>();
    for (const bar of result.bars) {
      expect(bar.badge!.anchor).toBe(bar.left + bar.width / 2);
      expect(bar.badge!.left).toBeGreaterThanOrEqual(ends.get(bar.top) ?? 0);
      expect(bar.badge!.left + bar.badge!.width).toBeLessThanOrEqual(60);
      ends.set(bar.top, bar.badge!.left + bar.badge!.width);
    }
    expect(result.bars.map(({ reference }) => reference)).toEqual(plots.map(({ reference }) => reference));
  });
});
