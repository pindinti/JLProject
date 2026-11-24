export interface StageLabelInput {
  label: string;
  discipline?: string;
  stageCode?: string | null;
  stageName?: string | null;
}

interface Label { text: string; abbreviation?: string }
const normalize = (value: string) => value.normalize("NFD").replace(/\p{M}/gu, "").toUpperCase();
const standard = new Map([
  ["ARQUITETURA", "ARQ"], ["PAISAGISMO", "PAIS"], ["LUMINOTECNICO", "LUM"],
  ["COMUNICACAO VISUAL", "CV"], ["IMAGENS DE VENDA", "IMG"], ["MAQUETE", "MAQ"], ["GARAGEM", "GAR"],
]);

export function printDisciplineAbbreviations(names: readonly string[]) {
  const used = new Set(standard.values());
  const result = new Map<string, string>();
  for (const name of [...new Set(names)].sort((a, b) => {
    const priority = Number(standard.has(normalize(b))) - Number(standard.has(normalize(a)));
    return priority || a.localeCompare(b, "pt-BR");
  })) {
    const canonical = normalize(name);
    const words = canonical.match(/[A-Z0-9]+/g) ?? [];
    const base = standard.get(canonical) ?? (words.length > 1
      ? words.map((word) => word[0]).join("").slice(0, 4)
      : words[0]?.slice(0, 3) ?? "DISC");
    let abbreviation = base;
    let suffix = 2;
    const reserved = standard.get(canonical) === base && ![...result.values()].includes(base);
    while (used.has(abbreviation) && !reserved) abbreviation = `${base}${suffix++}`;
    result.set(name, abbreviation);
    used.add(abbreviation);
  }
  return result;
}

export function printStageIdentities<T extends StageLabelInput>(stages: readonly T[], aliases: ReadonlyMap<string, string>,
  compact = false) {
  const counts = new Map<string, number>();
  const choices = new Map(stages.map((stage) => {
    const candidates: Label[] = [];
    const abbreviation = stage.discipline ? aliases.get(stage.discipline) : undefined;
    if (compact && abbreviation) {
      for (const text of new Set([stage.stageCode, stage.stageName])) {
        if (text) candidates.push({ text: `${abbreviation} · ${text}`, abbreviation });
      }
    }
    candidates.push({ text: stage.label });
    if (!compact && stage.discipline && stage.stageCode) {
      candidates.push({ text: `${stage.discipline} – ${stage.stageCode}` });
      if (abbreviation) candidates.push({ text: `${abbreviation} – ${stage.stageCode}`, abbreviation });
    }
    for (const text of new Set(candidates.map(({ text }) => normalize(text)))) {
      counts.set(text, (counts.get(text) ?? 0) + 1);
    }
    return [stage, candidates] as const;
  }));
  return new Map([...choices].map(([stage, candidates]) => {
    const unique = candidates.filter(({ text }) => counts.get(normalize(text)) === 1);
    return [stage, compact ? unique.slice(0, 1) : unique] as const;
  }));
}

export interface PrintStagePlot {
  left: number;
  width: number;
  lane: number;
  labels: readonly Label[];
  reference: number;
}

type PlacedStage<T extends PrintStagePlot> = T & {
  top: number;
  inside?: Label;
  outside?: Label & { left: number; width: number; leaderLeft: number };
  badge?: { left: number; width: number; anchor: number };
};

export const printStageLaneHeight = 5;
const referenceTrack = 5;
const leader = 1.5;

export function layoutPrintStageLabels<T extends PrintStagePlot>(plots: readonly T[], limit: number,
  measure: (text: string) => number, markerPositions: readonly number[] = [], addLabelLane = false) {
  let height = 0;
  const lanes = [...new Set(plots.map(({ lane }) => lane))].sort((a, b) => a - b);
  const widthOf = (label: string) => measure(label) + 1.6;
  const startOf = (bar: T) => Math.max(0, bar.left - (bar.width === 0 ? 0.175 : 0));
  const endOf = (bar: T) => Math.min(limit, bar.left + (bar.width || 0.175));
  function placeLane(bars: readonly T[], allowExtra = addLabelLane): PlacedStage<T>[] {
    const gaps = [
      { left: 0, right: startOf(bars[0]) },
      ...bars.map((bar, index) => ({ left: endOf(bar), right: index + 1 < bars.length ? startOf(bars[index + 1]) : limit })),
    ];
    const top = height;
    const placed = bars.map<PlacedStage<T>>((bar, index) => {
      const inside = bar.labels.find(({ text }) => widthOf(text) <= bar.width);
      if (inside) return { ...bar, inside, top };
      for (const label of bar.labels) {
        const width = widthOf(label.text);
        const after = gaps[index + 1];
        const before = gaps[index];
        const clear = (left: number, right: number) =>
          markerPositions.every((marker) => marker < left - 0.4 || marker > right + 0.4);
        if (after.left + leader + width <= after.right && clear(after.left, after.left + leader + width)) {
          const left = after.left + leader;
          const leaderLeft = after.left;
          after.left = left + width + leader;
          return { ...bar, top, outside: { ...label, left, width, leaderLeft } };
        }
        if (before.right - leader - width >= before.left && clear(before.right - leader - width, before.right)) {
          const left = before.right - leader - width;
          before.right = left - leader;
          return { ...bar, top, outside: { ...label, left, width, leaderLeft: left + width } };
        }
      }
      return { ...bar, top };
    });
    const references = placed.filter((bar) => !bar.inside && !bar.outside);
    if (allowExtra && bars.length > 1) {
      // Try one extra lane for a label collision before assigning a numbered key.
      const moving = new Set<number>();
      let occupied = 0;
      for (const bar of references) {
        const label = bar.labels[0];
        if (!label) continue;
        const width = widthOf(label.text) + leader;
        const start = startOf(bar);
        const end = endOf(bar);
        const clear = (left: number, right: number) => left >= occupied && right <= limit &&
          markerPositions.every((marker) => marker < left - 0.4 || marker > right + 0.4);
        if (start >= occupied && clear(end, end + width)) {
          moving.add(bar.reference);
          occupied = end + width + leader;
        } else if (clear(start - width, start)) {
          moving.add(bar.reference);
          occupied = end;
        }
      }
      if (moving.size && moving.size < bars.length) return [
        ...placeLane(bars.filter((bar) => !moving.has(bar.reference)), false),
        ...placeLane(bars.filter((bar) => moving.has(bar.reference)), false),
      ];
    }
    const badgeWidth = (bar: T) => widthOf(`#${bar.reference}`);
    let remaining = references.reduce((sum, bar) => sum + badgeWidth(bar) + 0.6, 0);
    if (remaining > limit && bars.length > 1) {
      const middle = Math.ceil(bars.length / 2);
      return [...placeLane(bars.slice(0, middle), false), ...placeLane(bars.slice(middle), false)];
    }
    height += printStageLaneHeight + (references.length ? referenceTrack : 0);
    let next = 0;
    return placed.map((bar) => {
      if (bar.inside || bar.outside) return bar;
      const width = Math.min(limit, badgeWidth(bar));
      const anchor = bar.left + bar.width / 2;
      const left = Math.max(next, Math.min(anchor - width / 2, limit - remaining));
      next = left + width + 0.6;
      remaining -= width + 0.6;
      return { ...bar, badge: { left, width, anchor } };
    });
  }
  const bars = lanes.flatMap((lane) => placeLane(plots.filter((bar) => bar.lane === lane)
    .sort((a, b) => a.left - b.left)));
  return { bars, height };
}
