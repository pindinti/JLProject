import { describe, expect, it } from "vitest";
import { previewScheduleDependencies, type DependencyDates, type DependencyEndpoint, type DependencyEntity,
  type DependencySnapshot, type FinishToStartDependency } from "../domain/schedule-dependencies";

type Activity = Extract<DependencyEntity, { kind: "activity" }>;
type Stage = Extract<DependencyEntity, { kind: "stage" }>;
const productId = "product";
const dates = (start: string | null, end: string | null = start): DependencyDates => ({ start, end });
const nov = (day: number) => `2026-11-${String(day).padStart(2, "0")}`;
const ref = (entity: DependencyEndpoint): DependencyEndpoint => ({ productId: entity.productId, kind: entity.kind, id: entity.id });

function activity(id: string, start: number | null, end: number | null = start,
  stageId: string | null = null): Activity {
  return { id, productId, kind: "activity", version: 1, stageId,
    dates: dates(start === null ? null : nov(start), end === null ? null : nov(end)), planning: { mode: "manual" } };
}

function stage(id: string, start: number | null = null, end: number | null = start): Stage {
  return { id, productId, kind: "stage", version: 2,
    dates: dates(start === null ? null : nov(start), end === null ? null : nov(end)) };
}

function link(predecessor: DependencyEndpoint, successor: DependencyEndpoint,
  id = `${predecessor.id}-${successor.id}`): FinishToStartDependency {
  return { id, predecessor: ref(predecessor), successor: ref(successor) };
}

function snapshot(entities: DependencyEntity[], dependencies: FinishToStartDependency[] = []): DependencySnapshot {
  return { productId, scheduleVersion: "9007199254740993", entities, dependencies,
    calendar: { version: 3, exceptions: [] }, targets: [] };
}

describe("dependency previews", () => {
  it("applies a chain in topological order across stages, keeps slack, and exposes paths and confirmation tokens", () => {
    const left = stage("design");
    const right = stage("delivery");
    const a = activity("a", 3, 3, left.id);
    const b = activity("b", 4, 5, right.id);
    const c = activity("c", 6);
    const slack = activity("slack", 17);
    const independent = activity("independent", 4);
    const input = { ...snapshot([independent, right, c, a, left, b, slack], [link(b, c), link(a, slack), link(a, b)]),
      targets: [{ id: "contract", date: nov(10) }] };
    const edit = { kind: "edit_dates" as const, entity: ref(a), dates: dates(nov(3), nov(6)) };
    const original = structuredClone({ input, edit });
    const result = previewScheduleDependencies(input, edit);

    expect(result.status).toBe("ready");
    expect(result.blockers).toEqual([]);
    expect(result.dateChanges.map(({ entity, source, before, after }) => [entity.id, source, before, after])).toEqual([
      ["a", "direct", dates(nov(3)), dates(nov(3), nov(6))],
      ["b", "cascade", dates(nov(4), nov(5)), dates(nov(9), nov(10))],
      ["c", "cascade", dates(nov(6)), dates(nov(11))],
    ]);
    expect(result.affectedEntities).toEqual(expect.arrayContaining([
      expect.objectContaining({ entity: ref(b), constraints: [expect.objectContaining({ dependencyId: "a-b", predecessor: ref(a) })] }),
      expect.objectContaining({ entity: ref(c), constraints: [expect.objectContaining({ dependencyId: "b-c", predecessor: ref(b) })] }),
      expect.objectContaining({ entity: ref(slack), effectiveAfter: slack.dates }),
    ]));
    expect(result.affectedEntities.some(({ entity }) => entity.id === independent.id)).toBe(false);
    expect(result.warnings).toEqual([{ code: "fixed_target_conflict", entity: ref(c), targetId: "contract",
      targetDate: nov(10), proposedEnd: nov(11) }]);
    expect(result.confirmation).toMatchObject({ productId, scheduleVersion: input.scheduleVersion,
      calendarVersion: 3, edit, expectedEntityVersions: expect.arrayContaining([{ entity: ref(c), version: 1 }]) });
    expect({ input, edit }).toEqual(original);
    expect(previewScheduleDependencies({ ...input, entities: [...input.entities].reverse(),
      dependencies: [...input.dependencies].reverse() }, edit)).toEqual(result);
    result.dateChanges[0].after.start = nov(23);
    expect({ input, edit }).toEqual(original);
  });

  it("uses the most restrictive predecessor and records both incoming constraints", () => {
    const first = activity("first", 9);
    const second = activity("second", 12);
    const successor = activity("successor", 10);
    const result = previewScheduleDependencies(snapshot([first, second, successor], [link(first, successor)]),
      { kind: "add_dependency", dependency: link(second, successor) });

    expect(result.status).toBe("ready");
    expect(result.dateChanges[0]).toMatchObject({ after: dates(nov(13)),
      duration: { source: "counted_working_days", workingDays: 1, calendarVersion: 3 }, planningAfter: { mode: "manual" } });
    expect(result.affectedEntities[0].constraints).toMatchObject([
      { dependencyId: "first-successor", earliestStart: nov(10), tightened: false },
      { dependencyId: "second-successor", earliestStart: nov(13), tightened: true },
    ]);
  });

  it("waits for both branches of a cascade before proposing their shared successor", () => {
    const a = activity("a", 3);
    const b = activity("b", 4);
    const c = activity("c", 4, 5);
    const d = activity("d", 6);
    const result = previewScheduleDependencies(snapshot([d, c, b, a], [link(a, b), link(a, c), link(b, d), link(c, d)]),
      { kind: "edit_dates", entity: ref(a), dates: dates(nov(3), nov(6)) });

    expect(result.status).toBe("ready");
    expect(result.dateChanges.map(({ entity, after }) => [entity.id, after])).toEqual([
      ["a", dates(nov(3), nov(6))], ["b", dates(nov(9))], ["c", dates(nov(9), nov(10))], ["d", dates(nov(11))],
    ]);
    expect(result.affectedEntities.at(-1)?.constraints.map(({ earliestStart }) => earliestStart)).toEqual([nov(10), nov(11)]);
  });

  it("saves a satisfied link alone and removes it without moving the successor", () => {
    const a = activity("a", 9);
    const b = activity("b", 18);
    const dependency = link(a, b);
    const added = previewScheduleDependencies(snapshot([a, b]), { kind: "add_dependency", dependency });
    const removed = previewScheduleDependencies(snapshot([a, b], [dependency]),
      { kind: "remove_dependency", dependencyId: dependency.id });

    expect(added).toMatchObject({ status: "ready", dateChanges: [], dependencyChange: { kind: "add", dependency } });
    expect(removed).toMatchObject({ status: "ready", dateChanges: [], dependencyChange: { kind: "remove", dependency } });
  });

  it("reports a closed directed cycle without including downstream nodes in the cycle", () => {
    const a = activity("a", 3);
    const b = activity("b", 4);
    const c = activity("c", 5);
    const downstream = activity("after-cycle", 6);
    const result = previewScheduleDependencies(snapshot([a, b, c, downstream], [link(a, b), link(b, c), link(c, downstream)]),
      { kind: "add_dependency", dependency: link(c, a) });

    expect(result).toMatchObject({ status: "blocked", dateChanges: [], confirmation: null,
      blockers: [{ code: "cycle", path: [a, b, c, a].map(ref) }] });
  });

  it("rejects self-links, duplicate pairs and IDs, unknown endpoints, mixed links, and cross-product links", () => {
    const a = activity("a", 3);
    const b = activity("b", 4);
    const c = activity("c", 5);
    const s = stage("s", 4);
    const existing = link(a, b);
    const input = snapshot([a, b, c, s], [existing]);
    for (const [dependency, code] of [
      [link(a, a), "self_link"],
      [link(a, b, "other-id"), "duplicate_dependency"],
      [link(a, c, existing.id), "duplicate_dependency"],
      [link(a, activity("missing", 3)), "invalid_endpoint"],
      [link(a, s), "mixed_endpoints"],
      [link(a, { ...b, productId: "another-product" }), "cross_product"],
    ] as const) {
      expect(previewScheduleDependencies(input, { kind: "add_dependency", dependency })).toMatchObject({
        status: "blocked", confirmation: null, blockers: [{ code, dependencyId: dependency.id }],
      });
    }
  });

  it("keeps an existing conflict as a warning when the predecessor finishes earlier", () => {
    const a = activity("a", 9, 12);
    const b = activity("b", 10);
    const result = previewScheduleDependencies(snapshot([a, b], [link(a, b)]),
      { kind: "edit_dates", entity: ref(a), dates: dates(nov(9), nov(11)) });

    expect(result.status).toBe("ready");
    expect(result.dateChanges.map(({ entity }) => entity.id)).toEqual(["a"]);
    expect(result.warnings).toEqual([{ code: "existing_dependency_conflict", entity: ref(b),
      earliestStart: nov(12), dependencyIds: ["a-b"] }]);
  });

  it("blocks a direct edit against an inbound bound and leaves unrelated pre-existing conflicts alone", () => {
    const a = activity("a", 9);
    const b = activity("b", 10);
    const c = activity("c", 19);
    const d = activity("d", 18);
    const input = snapshot([a, b, c, d], [link(a, b), link(c, d)]);
    const blocked = previewScheduleDependencies(input, { kind: "edit_dates", entity: ref(b), dates: dates(nov(9)) });
    const unchanged = previewScheduleDependencies(input, { kind: "edit_dates", entity: ref(b), dates: b.dates });

    expect(blocked).toMatchObject({ status: "blocked", confirmation: null,
      dateChanges: [{ entity: ref(b), source: "direct", after: dates(nov(9)) }],
      blockers: [{ code: "inbound_conflict", entity: ref(b), earliestStart: nov(10), dependencyIds: ["a-b"] }], warnings: [] });
    expect(unchanged).toMatchObject({ status: "unchanged", blockers: [], warnings: [], confirmation: null });
  });

  it("keeps manual edits to unlinked activities within the civil-date range used by the existing editor", () => {
    const a = activity("a", 3);
    const b = activity("b", 5);
    const result = previewScheduleDependencies(snapshot([a, b]),
      { kind: "edit_dates", entity: ref(a), dates: dates("2025-12-31") });

    expect(result).toMatchObject({ status: "ready", dateChanges: [{ entity: ref(a), source: "direct",
      after: dates("2025-12-31"), duration: null }], blockers: [] });
  });

  it("uses the saved working duration and skips a holiday, weekend and workspace exception", () => {
    const a = activity("a", 19);
    const b: Activity = { ...activity("b", 16, 18), planning: { mode: "working_days", duration: 3, calendarVersion: 2 } };
    const input = { ...snapshot([a, b]), calendar: { version: 3, exceptions: [
      { kind: "municipal_holiday" as const, startDate: nov(23), endDate: nov(23) },
      { kind: "company_shutdown" as const, startDate: nov(25), endDate: nov(25) },
    ] } };
    const result = previewScheduleDependencies(input, { kind: "add_dependency", dependency: link(a, b) });

    expect(result).toMatchObject({ status: "ready", dateChanges: [{ entity: ref(b), after: dates(nov(24), nov(27)),
      duration: { source: "saved_working_days", workingDays: 3, calendarVersion: 3 },
      planningBefore: { mode: "working_days", duration: 3, calendarVersion: 2 },
      planningAfter: { mode: "working_days", duration: 3, calendarVersion: 3 } }] });
  });

  it("keeps both boundaries from moving earlier when an older working plan would compress under the current calendar", () => {
    const a = activity("a", 5);
    const b: Activity = { ...activity("b", 4, 11), planning: { mode: "working_days", duration: 2, calendarVersion: 2 } };
    const result = previewScheduleDependencies(snapshot([a, b]), { kind: "add_dependency", dependency: link(a, b) });

    expect(result).toMatchObject({ status: "ready", dateChanges: [{ after: dates(nov(10), nov(11)) }],
      affectedEntities: [{ constraints: [{ earliestStart: nov(6) }] }] });
  });

  it("marks an explicitly entered working-day plan as direct and warns about unverified optional days", () => {
    const a = activity("a", 3);
    const result = previewScheduleDependencies(snapshot([a]),
      { kind: "edit_working_plan", entity: ref(a), start: "2027-01-01", duration: 2 });

    expect(result).toMatchObject({ status: "ready", dateChanges: [{ source: "direct",
      after: dates("2027-01-01", "2027-01-05"), duration: { source: "requested_working_days", workingDays: 2 } }],
      calendar: { unverifiedOptionalYears: [2027] }, warnings: [{ code: "unverified_optional_days", years: [2027] }] });
  });

  it("treats entering manual dates for a working-day activity as an explicit planning change", () => {
    const a: Activity = { ...activity("a", 3, 4), planning: { mode: "working_days", duration: 2, calendarVersion: 3 } };
    const result = previewScheduleDependencies(snapshot([a]), { kind: "edit_dates", entity: ref(a), dates: a.dates });

    expect(result).toMatchObject({ status: "ready", dateChanges: [{ source: "direct", before: a.dates, after: a.dates,
      planningBefore: a.planning, planningAfter: { mode: "manual" }, duration: null }] });
  });

  it("blocks movement of a partially dated activity that has a usable start", () => {
    const a = activity("a", 9);
    const b = activity("b", 8, null);
    const result = previewScheduleDependencies(snapshot([a, b]), { kind: "add_dependency", dependency: link(a, b) });

    expect(result).toMatchObject({ status: "blocked", confirmation: null, dateChanges: [],
      blockers: [{ code: "incomplete_activity_dates", entity: ref(b) }] });
  });

  it("returns blockers for unsupported calendar dates, invalid exceptions, and manual spans with zero working days", () => {
    const a = activity("a", 9);
    const b = activity("b", 7, 8);
    const edit = { kind: "add_dependency" as const, dependency: link(a, b) };
    const latest = { ...a, dates: dates("2100-12-31") };
    const invalidCalendar = { ...snapshot([a, b]), calendar: { version: 3, exceptions: [
      { kind: "municipal_holiday" as const, startDate: nov(11), endDate: nov(12) },
    ] } };

    expect(previewScheduleDependencies(snapshot([a, b]), edit).blockers).toEqual([{ code: "zero_working_days", entity: ref(b) }]);
    expect(previewScheduleDependencies(snapshot([latest, b]), edit).blockers).toEqual([{ code: "calendar_range", entity: ref(a) }]);
    expect(previewScheduleDependencies(invalidCalendar, edit).blockers).toEqual([{ code: "invalid_calendar" }]);
  });
});

describe("D065 stage dependency dates", () => {
  it("propagates a child-derived finish through a stage link and moves only the explicit successor stage", () => {
    const from = stage("from");
    const to = stage("to", 5, 6);
    const a = activity("a", 3, 4, from.id);
    const other = activity("other", 3, 5, from.id);
    const child = activity("child", 5, 6, to.id);
    const result = previewScheduleDependencies(snapshot([from, to, a, other, child], [link(from, to)]),
      { kind: "edit_dates", entity: ref(a), dates: dates(nov(3), nov(6)) });

    expect(result.status).toBe("ready");
    expect(result.dateChanges.map(({ entity, source, after }) => [entity.id, source, after])).toEqual([
      ["a", "direct", dates(nov(3), nov(6))], ["to", "cascade", dates(nov(9), nov(10))],
    ]);
    expect(result.affectedEntities).toContainEqual(expect.objectContaining({ entity: ref(from),
      dateSourceAfter: "derived", effectiveBefore: dates(nov(3), nov(5)), effectiveAfter: dates(nov(3), nov(6)),
      changedChildren: [ref(a)] }));
    expect(result.warnings).toContainEqual({ code: "stage_child_date_discrepancy", stage: ref(to), activity: ref(child),
      boundary: "start", stageDate: nov(9), activityDate: nov(5) });
  });

  it("keeps an explicit stage finish independent when a child moves beyond it", () => {
    const from = stage("from", 3, 5);
    const to = stage("to", 6);
    const child = activity("child", 4, 5, from.id);
    const result = previewScheduleDependencies(snapshot([from, to, child], [link(from, to)]),
      { kind: "edit_dates", entity: ref(child), dates: dates(nov(4), nov(9)) });

    expect(result.status).toBe("ready");
    expect(result.dateChanges.map(({ entity }) => entity.id)).toEqual(["child"]);
    expect(result.affectedEntities).toContainEqual(expect.objectContaining({ entity: ref(from),
      dateSourceAfter: "planned", effectiveBefore: from.dates, effectiveAfter: from.dates, changedChildren: [ref(child)] }));
  });

  it("uses the explicit finish of a partial stage without borrowing the missing start from a child", () => {
    const from = stage("from", null, 6);
    const to = stage("to", 9);
    const child = activity("child", 4, 12, from.id);
    const result = previewScheduleDependencies(snapshot([from, to, child]),
      { kind: "add_dependency", dependency: link(from, to) });

    expect(result).toMatchObject({ status: "ready", dateChanges: [],
      affectedEntities: [{ constraints: [{ earliestStart: nov(9) }] }] });
  });

  it("blocks missing boundaries instead of filling them from child dates or adjusting other dates", () => {
    const from = stage("from", 3, null);
    const to = stage("to", null, 9);
    const child = activity("child", 4, 5, from.id);
    const other = activity("other", 8, 9, to.id);
    const result = previewScheduleDependencies(snapshot([from, to, child, other]),
      { kind: "add_dependency", dependency: link(from, to) });

    expect(result).toMatchObject({ status: "blocked", dateChanges: [], confirmation: null, blockers: [
      { code: "missing_boundary", entity: ref(from), dependencyId: "from-to", boundary: "end" },
      { code: "missing_boundary", entity: ref(to), dependencyId: "from-to", boundary: "start" },
    ] });
  });

  it("blocks a direct edit that clears the required explicit finish on an existing outgoing link", () => {
    const from = stage("from", 3, 5);
    const to = stage("to", 6);
    const child = activity("child", 4, 5, from.id);
    const result = previewScheduleDependencies(snapshot([from, to, child], [link(from, to)]),
      { kind: "edit_dates", entity: ref(from), dates: dates(nov(3), null) });

    expect(result).toMatchObject({ status: "blocked", confirmation: null, blockers: [
      { code: "missing_boundary", entity: ref(from), dependencyId: "from-to", boundary: "end" },
    ] });
  });

  it("blocks derived and partial successor moves while allowing already valid boundaries", () => {
    const from = stage("from", 6);
    const derived = stage("derived");
    const partial = stage("partial", 5, null);
    const child = activity("child", 5, 6, derived.id);
    const input = snapshot([from, derived, partial, child]);

    for (const successor of [derived, partial]) {
      expect(previewScheduleDependencies(input, { kind: "add_dependency", dependency: link(from, successor) })).toMatchObject({
        status: "blocked", dateChanges: [], confirmation: null,
        blockers: [{ code: "stage_requires_explicit_dates", entity: ref(successor) }],
      });
    }
    const earlier = stage("from", 4);
    const valid = previewScheduleDependencies(snapshot([earlier, partial]),
      { kind: "add_dependency", dependency: link(earlier, partial) });
    expect(valid).toMatchObject({ status: "ready", dateChanges: [], blockers: [] });
  });

  it("reevaluates a derived successor constraint when a child is explicitly moved earlier", () => {
    const from = stage("from", 6);
    const to = stage("to");
    const child = activity("child", 9, 10, to.id);
    const result = previewScheduleDependencies(snapshot([from, to, child], [link(from, to)]),
      { kind: "edit_dates", entity: ref(child), dates: dates(nov(5), nov(10)) });

    expect(result).toMatchObject({ status: "blocked", confirmation: null,
      dateChanges: [{ entity: ref(child), source: "direct" }],
      blockers: [{ code: "stage_requires_explicit_dates", entity: ref(to) }] });
  });

  it("does not plan a downstream cascade using a blocked stage's proposed dates", () => {
    const from = stage("from", 6);
    const blocked = stage("blocked", 9);
    const downstream = stage("downstream", 10);
    const result = previewScheduleDependencies(snapshot([from, blocked, downstream], [link(from, blocked), link(blocked, downstream)]),
      { kind: "edit_dates", entity: ref(blocked), dates: dates(nov(5), nov(11)) });

    expect(result).toMatchObject({ status: "blocked", confirmation: null,
      dateChanges: [{ entity: ref(blocked), source: "direct" }],
      blockers: [{ code: "inbound_conflict", entity: ref(blocked) }] });
  });
});
