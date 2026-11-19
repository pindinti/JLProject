import type { ComparisonSchedule, ProductComparison } from "../worker/product-comparison";
import { scheduleStageInterval, type ScheduleStageInterval } from "./schedule-workspace";

const kinds = ["discipline", "stage", "activity", "target"] as const;
export type ComparisonKind = typeof kinds[number];
export type ComparisonStatus = "identical" | "different" | "only_a" | "only_b" | "ambiguous";
export interface ComparisonOverride {
  action: "pair" | "unlink";
  kind: ComparisonKind;
  aId: string;
  bId: string;
}

type Scalar = string | number | null;
type Location = { kind: "discipline" | "stage"; id: string; label: string };
interface ComparisonEntity {
  id: string;
  label: string;
  location: Location | null;
  values: Readonly<Record<string, Scalar>>;
  effectiveInterval?: ScheduleStageInterval;
}

export interface ComparisonRow {
  kind: ComparisonKind;
  status: ComparisonStatus;
  match: "suggested" | "manual" | null;
  a: ComparisonEntity | null;
  b: ComparisonEntity | null;
  differences: readonly { field: string; a: Scalar | Location; b: Scalar | Location }[];
  /** Opposite-side IDs for an ambiguous row. */
  candidateIds: readonly string[];
  children: ComparisonRow[];
}

export interface ScheduleComparisonResult {
  a: ComparisonSchedule["product"];
  b: ComparisonSchedule["product"];
  hierarchy: ComparisonRow[];
  targets: ComparisonRow[];
  summary: Record<ComparisonStatus | "suggested" | "manual", number>;
}

interface Item extends ComparisonEntity {
  kind: ComparisonKind;
  identityKey: string;
  displayOrder: number;
}

function itemKey(kind: ComparisonKind, id: string) {
  return `${kind}:${id}`;
}

function collect(schedule: ComparisonSchedule): Item[] {
  const items: Item[] = [];
  const addActivity = (activity: ComparisonSchedule["hierarchy"]["rootActivities"][number], location: Location | null) => {
    const { id, name, activityType, displayOrder, plannedStart, plannedEnd, planningMode,
      workingDayDuration, planningCalendarVersion } = activity;
    items.push({ kind: "activity", id, label: name, location, displayOrder,
      identityKey: JSON.stringify([name, activityType]),
      values: { name, activityType, displayOrder, plannedStart, plannedEnd, planningMode,
        workingDayDuration, planningCalendarVersion } });
  };

  for (const activity of schedule.hierarchy.rootActivities) addActivity(activity, null);
  for (const discipline of schedule.hierarchy.disciplines) {
    const { id, name, shortCode, displayOrder, description } = discipline;
    items.push({ kind: "discipline", id, label: name, location: null, displayOrder,
      identityKey: JSON.stringify([shortCode, name]), values: { name, shortCode, displayOrder, description } });
    for (const stage of discipline.stages) {
      const { code, displayName, plannedStart, plannedEnd, derivedStart, derivedEnd } = stage;
      const effectiveInterval = scheduleStageInterval(stage);
      items.push({ kind: "stage", id: stage.id, label: displayName,
        location: { kind: "discipline", id, label: name }, displayOrder: stage.displayOrder,
        identityKey: JSON.stringify([code, displayName]), effectiveInterval,
        values: { code, displayName, displayOrder: stage.displayOrder,
          plannedStart, plannedEnd, derivedStart, derivedEnd, dateSource: effectiveInterval.source } });
      for (const activity of stage.activities)
        addActivity(activity, { kind: "stage", id: stage.id, label: displayName });
    }
  }

  for (const target of schedule.targets) {
    const { id, name, displayOrder, description, targetDate, operationalDate } = target;
    items.push({ kind: "target", id, label: name, location: null, displayOrder,
      identityKey: name, values: { name, displayOrder, description, targetDate, operationalDate } });
  }
  return items.sort((a, b) => a.displayOrder - b.displayOrder || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

const key = (item: Item | Location) => itemKey(item.kind, item.id);

function entity(item: Item | null): ComparisonEntity | null {
  if (!item) return null;
  const { id, label, location, values, effectiveInterval } = item;
  return { id, label, location, values, ...(effectiveInterval ? { effectiveInterval } : {}) };
}

/** Builds A/B correspondence from one snapshot pair. Overrides apply only to this call. */
export function compareProductSchedules(snapshot: ProductComparison,
  overrides: readonly ComparisonOverride[] = []): ScheduleComparisonResult {
  const a = collect(snapshot.left);
  const b = collect(snapshot.right);
  const aIndex = new Map(a.map((item) => [key(item), item]));
  const bIndex = new Map(b.map((item) => [key(item), item]));
  const matches = new Map<string, { item: Item; origin: "suggested" | "manual" }>();
  const pairedB = new Set<string>();
  const unlinks = new Map<string, Set<string>>();
  const aCandidates = new Map<string, readonly string[]>();
  const bCandidates = new Map<string, readonly string[]>();

  const pair = (aItem: Item, bItem: Item, origin: "suggested" | "manual") => {
    matches.set(key(aItem), { item: bItem, origin });
    pairedB.add(key(bItem));
  };
  for (const { action, kind, aId, bId } of overrides) {
    const aItem = aIndex.get(itemKey(kind, aId));
    const bItem = bIndex.get(itemKey(kind, bId));
    if (!aItem || !bItem) throw new Error("Comparison override must reference existing entities of the same kind.");
    const aKey = key(aItem);
    const bKey = key(bItem);
    if (action === "pair") {
      if (matches.has(aKey) || pairedB.has(bKey)) throw new Error("Comparison override pairs an entity more than once.");
      pair(aItem, bItem, "manual");
    } else if (action === "unlink") {
      const excluded = unlinks.get(aKey) ?? new Set<string>();
      excluded.add(bKey);
      unlinks.set(aKey, excluded);
    } else {
      throw new Error("Invalid comparison override action.");
    }
  }
  for (const [aKey, match] of matches) {
    if (unlinks.get(aKey)?.has(key(match.item))) throw new Error("Comparison overrides both pair and unlink the same entities.");
  }

  for (const kind of kinds) {
    const groups = new Map<string, { a: Item[]; b: Item[] }>();
    const group = (item: Item, locationInB: string | null, side: "a" | "b") => {
      const groupKey = JSON.stringify([locationInB, item.identityKey]);
      const bucket = groups.get(groupKey) ?? { a: [], b: [] };
      bucket[side].push(item);
      groups.set(groupKey, bucket);
    };
    for (const item of a) {
      if (item.kind !== kind || matches.has(key(item))) continue;
      const parent = item.location ? matches.get(key(item.location)) : undefined;
      if (!item.location || parent) group(item, parent ? key(parent.item) : null, "a");
    }
    for (const item of b) {
      if (item.kind === kind && !pairedB.has(key(item))) group(item, item.location ? key(item.location) : null, "b");
    }
    for (const bucket of groups.values()) {
      if (!bucket.a.length || !bucket.b.length) continue;
      if (bucket.a.length === 1 && bucket.b.length === 1) {
        const [aItem] = bucket.a;
        const [bItem] = bucket.b;
        if (!unlinks.get(key(aItem))?.has(key(bItem))) pair(aItem, bItem, "suggested");
        continue;
      }
      const allA = bucket.a.map((item) => item.id);
      const allB = bucket.b.map((item) => item.id);
      const excludedA = new Map<string, Set<string>>();
      for (const item of bucket.a) {
        const excluded = unlinks.get(key(item));
        const candidates = excluded ? bucket.b.filter((candidate) => {
          if (!excluded.has(key(candidate))) return true;
          const exclusions = excludedA.get(candidate.id) ?? new Set<string>();
          exclusions.add(item.id);
          excludedA.set(candidate.id, exclusions);
          return false;
        }).map((candidate) => candidate.id) : allB;
        if (candidates.length) aCandidates.set(key(item), candidates);
      }
      for (const item of bucket.b) {
        const excluded = excludedA.get(item.id);
        const candidates = excluded ? allA.filter((id) => !excluded.has(id)) : allA;
        if (candidates.length) bCandidates.set(key(item), candidates);
      }
    }
  }

  const result: ScheduleComparisonResult = { a: snapshot.left.product, b: snapshot.right.product, hierarchy: [], targets: [],
    summary: { identical: 0, different: 0, only_a: 0, only_b: 0, ambiguous: 0, suggested: 0, manual: 0 } };
  const aRows = new Map<string, ComparisonRow>();
  const bRows = new Map<string, ComparisonRow>();
  function addRow(itemA: Item | null, itemB: Item | null, origin: ComparisonRow["match"], candidateIds: readonly string[]) {
    const item = itemA ?? itemB!;
    const differences: ComparisonRow["differences"][number][] = [];
    if (itemA && itemB) {
      for (const [field, value] of Object.entries(itemA.values)) {
        if (value !== itemB.values[field]) differences.push({ field, a: value, b: itemB.values[field] });
      }
      const aParent = itemA.location ? matches.get(key(itemA.location))?.item : null;
      if ((aParent ? key(aParent) : aParent) !== (itemB.location ? key(itemB.location) : null))
        differences.push({ field: "location", a: itemA.location, b: itemB.location });
    }
    const status = itemA && itemB ? differences.length ? "different" : "identical" :
      candidateIds.length ? "ambiguous" : itemA ? "only_a" : "only_b";
    const row: ComparisonRow = { kind: item.kind, status, match: origin, a: entity(itemA), b: entity(itemB),
      differences, candidateIds, children: [] };
    if (itemA) aRows.set(key(itemA), row);
    if (itemB) bRows.set(key(itemB), row);
    result.summary[status]++;
    if (origin) result.summary[origin]++;
    if (item.kind === "target") result.targets.push(row);
    else if (!item.location) result.hierarchy.push(row);
    else (itemA ? aRows : bRows).get(key(item.location))!.children.push(row);
  }

  // A hosts paired rows, including moves. B-only rows stay under their B parent.
  for (const kind of kinds) {
    for (const item of a) {
      if (item.kind !== kind) continue;
      const match = matches.get(key(item));
      addRow(item, match?.item ?? null, match?.origin ?? null, aCandidates.get(key(item)) ?? []);
    }
    for (const item of b) {
      if (item.kind === kind && !pairedB.has(key(item))) addRow(null, item, null, bCandidates.get(key(item)) ?? []);
    }
  }
  return result;
}
