import { civilFromDay, dayNumber, scheduleStageInterval } from "./schedule-workspace";
import {
  calendarRulesForYear, isNonWorkingDate, parseCivilDate, parseScheduleCivilDate,
  type CalendarExceptionDates,
} from "./working-calendar";
import { validateWorkingCalendarExceptions } from "./working-day-calculation";

export interface DependencyEndpoint {
  productId: string;
  kind: "activity" | "stage";
  id: string;
}

export interface FinishToStartDependency {
  id: string;
  predecessor: DependencyEndpoint;
  successor: DependencyEndpoint;
}

export interface DependencyDates {
  start: string | null;
  end: string | null;
}

type Planning = { mode: "manual" } |
  { mode: "working_days"; duration: number; calendarVersion: number };

export type DependencyEntity = DependencyEndpoint & {
  version: number;
  dates: DependencyDates;
} & ({ kind: "activity"; stageId: string | null; planning: Planning } | { kind: "stage" });

export interface DependencySnapshot {
  productId: string;
  scheduleVersion: string;
  calendar: { version: number; exceptions: readonly CalendarExceptionDates[] };
  /** Supply every active stage and activity, including all children used to derive stage dates. */
  entities: readonly DependencyEntity[];
  dependencies: readonly FinishToStartDependency[];
  targets: readonly { id: string; date: string }[];
}

export type DependencyEdit =
  /** Entering both activity dates explicitly selects manual planning. */
  | { kind: "edit_dates"; entity: DependencyEndpoint; dates: DependencyDates }
  | { kind: "edit_working_plan"; entity: DependencyEndpoint; start: string; duration: number }
  | { kind: "add_dependency"; dependency: FinishToStartDependency }
  | { kind: "remove_dependency"; dependencyId: string };

type DurationAssumption = { source: "saved_working_days" | "requested_working_days" | "counted_working_days";
  workingDays: number; calendarVersion: number };

interface DateChange {
  entity: DependencyEndpoint;
  source: "direct" | "cascade";
  before: DependencyDates;
  after: DependencyDates;
  planningBefore: Planning | null;
  planningAfter: Planning | null;
  duration: DurationAssumption | null;
}

interface DependencyConstraint {
  dependencyId: string;
  predecessor: DependencyEndpoint;
  earliestStart: string;
  previousEarliestStart: string | null;
  tightened: boolean;
}

interface AffectedEntity {
  entity: DependencyEndpoint;
  effectiveBefore: DependencyDates;
  effectiveAfter: DependencyDates;
  dateSourceBefore: "planned" | "derived";
  dateSourceAfter: "planned" | "derived";
  /** These incoming edges and child references can be followed through affectedEntities to explain paths. */
  constraints: DependencyConstraint[];
  changedChildren: DependencyEndpoint[];
}

type DependencyError = "invalid_endpoint" | "cross_product" | "mixed_endpoints" | "self_link" |
  "duplicate_dependency" | "dependency_not_found";

type Blocker =
  | { code: "invalid_calendar" | "invalid_snapshot" }
  | { code: "invalid_entity" | "invalid_edit" | "calendar_range" | "stage_requires_explicit_dates" |
      "incomplete_activity_dates" | "zero_working_days"; entity: DependencyEndpoint }
  | { code: DependencyError; dependencyId: string }
  | { code: "cycle"; path: DependencyEndpoint[] }
  | { code: "missing_boundary"; entity: DependencyEndpoint; dependencyId: string; boundary: "start" | "end" }
  | { code: "inbound_conflict"; entity: DependencyEndpoint; earliestStart: string; dependencyIds: string[] };

type Warning =
  | { code: "unverified_optional_days"; years: number[] }
  | { code: "existing_dependency_conflict"; entity: DependencyEndpoint; earliestStart: string; dependencyIds: string[] }
  | { code: "fixed_target_conflict"; entity: DependencyEndpoint; targetId: string; targetDate: string; proposedEnd: string }
  | { code: "stage_child_date_discrepancy"; stage: DependencyEndpoint; activity: DependencyEndpoint;
      boundary: "start" | "end"; stageDate: string; activityDate: string };

export interface DependencyPreview {
  status: "ready" | "blocked" | "unchanged";
  dateChanges: DateChange[];
  affectedEntities: AffectedEntity[];
  dependencyChange: { kind: "add" | "remove"; dependency: FinishToStartDependency } | null;
  calendar: { version: number; unverifiedOptionalYears: number[] };
  blockers: Blocker[];
  warnings: Warning[];
  confirmation: { productId: string; scheduleVersion: string; calendarVersion: number;
    edit: DependencyEdit; expectedEntityVersions: { entity: DependencyEndpoint; version: number }[] } | null;
}

function key({ kind, id }: DependencyEndpoint): string { return `${kind}:${id}`; }

function endpoint({ productId, kind, id }: DependencyEndpoint): DependencyEndpoint {
  return { productId, kind, id };
}

function sameDates(left: DependencyDates, right: DependencyDates): boolean {
  return left.start === right.start && left.end === right.end;
}

export interface DependencyBoundaryState {
  predecessorFinish: string | null;
  successorStart: string | null;
  earliestStart: string | null;
}

function violatesDependencyStart(start: string | null, earliest: string | null): boolean {
  return start !== null && earliest !== null && start < earliest;
}

/** Ordinary edits may improve a standing conflict. A reviewed preview retains its stricter inbound rule. */
export function assessDependencyBoundaryChange(before: DependencyBoundaryState, after: DependencyBoundaryState):
  "missing_boundary" | "calendar_range" | "finish_to_start" | null {
  if (before.predecessorFinish === after.predecessorFinish && before.successorStart === after.successorStart) return null;
  if (before.predecessorFinish && !after.predecessorFinish || before.successorStart && !after.successorStart) return "missing_boundary";
  if (!after.predecessorFinish || !after.successorStart) return null;
  if (!after.earliestStart) return "calendar_range";
  if (violatesDependencyStart(after.successorStart, after.earliestStart) &&
      (!before.successorStart || !before.earliestStart ||
        dayNumber(after.earliestStart) - dayNumber(after.successorStart) >
        dayNumber(before.earliestStart) - dayNumber(before.successorStart))) return "finish_to_start";
  return null;
}

function validDates({ start, end }: DependencyDates): boolean {
  return (start === null || !!parseScheduleCivilDate(start)) &&
    (end === null || !!parseScheduleCivilDate(end)) && (!start || !end || start <= end);
}

function validDuration(duration: number): boolean {
  return Number.isSafeInteger(duration) && duration >= 1 && duration <= 27393;
}

function compareIds(left: { id: string }, right: { id: string }): number {
  return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
}

function createCalendar(exceptions: readonly CalendarExceptionDates[]) {
  const classifications = new Map<string, boolean>();
  const years = new Map<number, boolean>();
  const lowerBounds = new Map<string, string | null>();
  const maximumDay = dayNumber("2100-12-31");

  function isWorking(date: string): boolean {
    const saved = classifications.get(date);
    if (saved !== undefined) return saved;
    const year = Number(date.slice(0, 4));
    if (!years.has(year)) years.set(year, calendarRulesForYear(year).optionalDaysVerified);
    const working = !isNonWorkingDate(date, exceptions);
    classifications.set(date, working);
    return working;
  }

  function place(start: string, duration: number, minimumEnd = start): { start: string; end: string } | null {
    if (!parseCivilDate(start) || !parseCivilDate(minimumEnd)) return null;
    const workingDates: string[] = [];
    for (let day = dayNumber(start); day <= maximumDay; day++) {
      const date = civilFromDay(day);
      if (!isWorking(date)) continue;
      workingDates.push(date);
      // The last N working dates give the earliest valid placement with this finish.
      if (workingDates.length >= duration && date >= minimumEnd) {
        return { start: workingDates[workingDates.length - duration], end: date };
      }
    }
    return null;
  }

  return {
    place,
    lowerBound(finish: string): string | null {
      if (!parseCivilDate(finish)) return null;
      const saved = lowerBounds.get(finish);
      if (saved !== undefined) return saved;
      const bound = place(civilFromDay(dayNumber(finish) + 1), 1)?.start ?? null;
      lowerBounds.set(finish, bound);
      return bound;
    },
    count(start: string, end: string): number | null {
      if (!parseCivilDate(start) || !parseCivilDate(end)) return null;
      let count = 0;
      const endDay = dayNumber(end);
      for (let day = dayNumber(start); day <= endDay; day++) {
        if (isWorking(civilFromDay(day))) count++;
      }
      return count;
    },
    unverifiedYears: () => [...years].filter(([, verified]) => !verified).map(([year]) => year).sort((a, b) => a - b),
  };
}

function dependencyOrder(entities: ReadonlyMap<string, DependencyEntity>,
  incoming: ReadonlyMap<string, FinishToStartDependency[]>, children: ReadonlyMap<string, DependencyEntity[]>):
  { order: string[] } | { cycle: DependencyEndpoint[] } {
  const predecessors = new Map<string, string[]>();
  const successors = new Map<string, string[]>();
  const remaining = new Map<string, number>();
  const order: string[] = [];
  for (const id of entities.keys()) {
    const parents = [...(incoming.get(id) ?? []).map((edge) => key(edge.predecessor)), ...(children.get(id) ?? []).map(key)];
    predecessors.set(id, parents);
    remaining.set(id, parents.length);
    if (parents.length === 0) order.push(id);
    for (const parent of parents) {
      const next = successors.get(parent) ?? [];
      next.push(id);
      successors.set(parent, next);
    }
  }
  for (let index = 0; index < order.length; index++) {
    for (const successor of successors.get(order[index]) ?? []) {
      const count = remaining.get(successor)! - 1;
      remaining.set(successor, count);
      if (count === 0) order.push(successor);
    }
  }
  if (order.length === entities.size) return { order };

  const route: string[] = [];
  let id = [...remaining].find(([, count]) => count > 0)![0];
  const visited = new Map<string, number>();
  while (!visited.has(id)) {
    visited.set(id, route.length);
    route.push(id);
    id = predecessors.get(id)!.find((parent) => remaining.get(parent)! > 0)!;
  }
  return { cycle: [...route.slice(visited.get(id)), id].reverse().map((item) => endpoint(entities.get(item)!)) };
}

function stageInterval(dates: DependencyDates, children: readonly DependencyDates[]) {
  let derivedStart: string | null = null;
  let derivedEnd: string | null = null;
  for (const child of children) {
    if (child.start && (!derivedStart || child.start < derivedStart)) derivedStart = child.start;
    if (child.end && (!derivedEnd || child.end > derivedEnd)) derivedEnd = child.end;
  }
  return scheduleStageInterval({ plannedStart: dates.start, plannedEnd: dates.end, derivedStart, derivedEnd });
}

type EffectiveDates = ReturnType<typeof stageInterval>;

function effectiveDates(entity: DependencyEntity, dates: DependencyDates, children: readonly DependencyDates[]): EffectiveDates {
  return entity.kind === "stage" ? stageInterval(dates, children) : { ...dates, source: "planned" };
}

function snapshotGraph(snapshot: DependencySnapshot, edit: DependencyEdit, blockers: Blocker[]) {
  const entities = new Map<string, DependencyEntity>();
  const children = new Map<string, DependencyEntity[]>();
  const incoming = new Map<string, FinishToStartDependency[]>();
  const ids = new Set<string>();
  const pairs = new Map<string, Set<string>>();

  for (const entity of [...snapshot.entities].sort((left, right) => compareIds(left, right) ||
      Number(left.kind === "stage") - Number(right.kind === "stage"))) {
    const id = key(entity);
    if (!entity.id || entity.productId !== snapshot.productId || entities.has(id) || !validDates(entity.dates) ||
        !Number.isSafeInteger(entity.version) || entity.version < 1 ||
        (entity.kind === "activity" && entity.planning.mode === "working_days" &&
          (!validDuration(entity.planning.duration) || !Number.isSafeInteger(entity.planning.calendarVersion) ||
            entity.planning.calendarVersion < 0 || entity.planning.calendarVersion > snapshot.calendar.version ||
            !entity.dates.start || !parseCivilDate(entity.dates.start) ||
            !entity.dates.end || !parseCivilDate(entity.dates.end)))) {
      blockers.push({ code: "invalid_entity", entity: endpoint(entity) });
    } else entities.set(id, entity);
  }
  for (const entity of entities.values()) {
    if (entity.kind !== "activity" || entity.stageId === null) continue;
    const stage = key({ productId: entity.productId, kind: "stage", id: entity.stageId });
    if (!entities.has(stage)) {
      blockers.push({ code: "invalid_entity", entity: endpoint(entity) });
      continue;
    }
    const members = children.get(stage) ?? [];
    members.push(entity);
    children.set(stage, members);
  }

  const removed = edit.kind === "remove_dependency"
    ? snapshot.dependencies.find((edge) => edge.id === edit.dependencyId) : undefined;
  if (edit.kind === "remove_dependency" && !removed) {
    blockers.push({ code: "dependency_not_found", dependencyId: edit.dependencyId });
  }
  const dependencies = edit.kind === "add_dependency" ? [...snapshot.dependencies, edit.dependency] : [...snapshot.dependencies];
  for (const edge of dependencies.sort(compareIds)) {
    const { id: dependencyId, predecessor, successor } = edge;
    const from = key(predecessor);
    const to = key(successor);
    const seen = pairs.get(from) ?? new Set<string>();
    let code: DependencyError | undefined;
    if (predecessor.productId !== snapshot.productId || successor.productId !== snapshot.productId) code = "cross_product";
    else if (!dependencyId || !entities.has(from) || !entities.has(to)) code = "invalid_endpoint";
    else if (predecessor.kind !== successor.kind) code = "mixed_endpoints";
    else if (from === to) code = "self_link";
    else if (ids.has(dependencyId) || seen.has(to)) code = "duplicate_dependency";
    if (code) {
      blockers.push({ code, dependencyId });
      continue;
    }
    ids.add(dependencyId);
    seen.add(to);
    pairs.set(from, seen);
    if (edge === removed) continue;
    const edges = incoming.get(to) ?? [];
    edges.push(edge);
    incoming.set(to, edges);
  }

  const dependencyChange = edit.kind === "add_dependency" ? { kind: "add" as const, dependency: edit.dependency }
    : removed ? { kind: "remove" as const, dependency: removed } : null;
  return { entities, children, incoming, dependencyChange };
}

function directChange(entity: DependencyEntity, edit: Extract<DependencyEdit, { entity: DependencyEndpoint }>,
  calendar: ReturnType<typeof createCalendar>, version: number, blockers: Blocker[]): DateChange | null {
  const ref = endpoint(entity);
  const before = entity.kind === "activity" ? entity.planning : null;
  let after: Planning | null = before;
  let dates: DependencyDates;
  let duration: DurationAssumption | null = null;
  if (edit.kind === "edit_working_plan") {
    if (entity.kind !== "activity" || !validDuration(edit.duration) || !parseScheduleCivilDate(edit.start)) {
      blockers.push({ code: "invalid_edit", entity: ref });
      return null;
    }
    const placement = calendar.place(edit.start, edit.duration);
    if (!placement) {
      blockers.push({ code: "calendar_range", entity: ref });
      return null;
    }
    dates = { start: edit.start, end: placement.end };
    after = { mode: "working_days", duration: edit.duration, calendarVersion: version };
    duration = { source: "requested_working_days", workingDays: edit.duration, calendarVersion: version };
  } else {
    dates = edit.dates;
    if (!validDates(dates) || (entity.kind === "activity" && (!dates.start || !dates.end))) {
      blockers.push({ code: "invalid_edit", entity: ref });
      return null;
    }
    if (entity.kind === "activity" && before?.mode === "working_days") after = { mode: "manual" };
  }
  const samePlan = before === after || (before?.mode === "working_days" && after?.mode === "working_days" &&
    before.duration === after.duration && before.calendarVersion === after.calendarVersion);
  if (sameDates(entity.dates, dates) && samePlan) return null;
  return { entity: ref, source: "direct", before: entity.dates, after: dates, planningBefore: before, planningAfter: after, duration };
}

function cascadeChange(entity: DependencyEntity, earliestStart: string, calendar: ReturnType<typeof createCalendar>,
  version: number, blockers: Blocker[]): DateChange | null {
  const ref = endpoint(entity);
  const { start, end } = entity.dates;
  if (!start || !end) {
    blockers.push({ code: entity.kind === "stage" ? "stage_requires_explicit_dates" : "incomplete_activity_dates", entity: ref });
    return null;
  }
  const plan = entity.kind === "activity" ? entity.planning : null;
  const workingDays = plan?.mode === "working_days" ? plan.duration : calendar.count(start, end);
  const after = workingDays ? calendar.place(earliestStart, workingDays, end) : null;
  if (!after || !workingDays) {
    blockers.push({ code: workingDays === 0 ? "zero_working_days" : "calendar_range", entity: ref });
    return null;
  }
  return { entity: ref, source: "cascade", before: entity.dates, after, planningBefore: plan,
    planningAfter: plan?.mode === "working_days" ? { ...plan, calendarVersion: version } : plan,
    duration: { source: plan?.mode === "working_days" ? "saved_working_days" : "counted_working_days",
      workingDays, calendarVersion: version } };
}

/** Previews one user operation against a current product snapshot. A blocked result is never confirmable. */
export function previewScheduleDependencies(snapshot: DependencySnapshot, edit: DependencyEdit): DependencyPreview {
  const { version } = snapshot.calendar;
  const result: DependencyPreview = { status: "blocked", dateChanges: [], affectedEntities: [], dependencyChange: null,
    calendar: { version, unverifiedOptionalYears: [] }, blockers: [], warnings: [], confirmation: null };
  const { blockers, warnings } = result;
  try {
    validateWorkingCalendarExceptions(snapshot.calendar.exceptions);
    if (!Number.isSafeInteger(version) || version < 0) throw new RangeError("Invalid calendar version.");
  } catch {
    blockers.push({ code: "invalid_calendar" });
    return result;
  }
  if (!snapshot.productId || !/^\d+$/.test(snapshot.scheduleVersion) ||
      snapshot.targets.some(({ date }) => !parseScheduleCivilDate(date))) {
    blockers.push({ code: "invalid_snapshot" });
    return result;
  }
  const { entities, children, incoming, dependencyChange } = snapshotGraph(snapshot, edit, blockers);
  if (blockers.length) return result;
  const ordered = dependencyOrder(entities, incoming, children);
  if ("cycle" in ordered) {
    blockers.push({ code: "cycle", path: ordered.cycle });
    return result;
  }

  const calendar = createCalendar(snapshot.calendar.exceptions);
  const before = new Map<string, EffectiveDates>();
  const after = new Map<string, EffectiveDates>();
  const blocked = new Set<string>();
  const consulted = new Set<string>();
  let requested: DateChange | null = null;
  if ("entity" in edit) {
    const entity = entities.get(key(edit.entity));
    if (!entity || edit.entity.productId !== snapshot.productId) {
      blockers.push({ code: "invalid_edit", entity: endpoint(edit.entity) });
      return result;
    }
    requested = directChange(entity, edit, calendar, version, blockers);
  }
  result.dependencyChange = dependencyChange;
  const targets = [...snapshot.targets].sort(compareIds);
  for (const id of ordered.order) {
    const entity = entities.get(id)!;
    const ref = endpoint(entity);
    const members = children.get(id) ?? [];
    const memberBefore = members.map((member) => before.get(key(member))!);
    const memberAfter = members.map((member) => after.get(key(member))!);
    const original = effectiveDates(entity, entity.dates, memberBefore);
    let change = requested && key(requested.entity) === id ? requested : null;
    let proposed = effectiveDates(entity, change?.after ?? entity.dates, memberAfter);
    const changedChildren = members.filter((_, index) => !sameDates(memberBefore[index], memberAfter[index]));
    const nodeBlockerCount = blockers.length;
    const edges = incoming.get(id) ?? [];
    const newlyAdded = (edge: FinishToStartDependency) => dependencyChange?.kind === "add" && edge === dependencyChange.dependency;
    const boundaryChanged = (edge: FinishToStartDependency) =>
      before.get(key(edge.predecessor))!.end !== after.get(key(edge.predecessor))!.end;
    const assess = change || !sameDates(original, proposed) || edges.some((edge) => newlyAdded(edge) || boundaryChanged(edge));
    const constraints: DependencyConstraint[] = [];
    if (assess) {
      consulted.add(id);
      members.forEach((member) => consulted.add(key(member)));
      for (const edge of edges) {
        const predecessor = key(edge.predecessor);
        consulted.add(predecessor);
        children.get(predecessor)?.forEach((member) => consulted.add(key(member)));
        if (blocked.has(predecessor)) continue;
        const finish = after.get(predecessor)!.end;
        const previousFinish = before.get(predecessor)!.end;
        if (!finish || !proposed.start) {
          if (!finish) blockers.push({ code: "missing_boundary", entity: endpoint(edge.predecessor),
            dependencyId: edge.id, boundary: "end" });
          if (!proposed.start) blockers.push({ code: "missing_boundary", entity: ref, dependencyId: edge.id, boundary: "start" });
          continue;
        }
        const earliest = calendar.lowerBound(finish);
        if (!earliest) {
          blockers.push({ code: "calendar_range", entity: endpoint(edge.predecessor) });
          continue;
        }
        const previousEarliestStart = !newlyAdded(edge) && previousFinish ? calendar.lowerBound(previousFinish) : null;
        constraints.push({ dependencyId: edge.id, predecessor: endpoint(edge.predecessor), earliestStart: earliest,
          previousEarliestStart, tightened: newlyAdded(edge) || !previousFinish ||
            (finish > previousFinish && (!previousEarliestStart || earliest > previousEarliestStart)) });
      }

      const start = proposed.start;
      const violations = constraints.filter(({ earliestStart }) => violatesDependencyStart(start, earliestStart));
      const earliestStart = violations.map((item) => item.earliestStart).sort().at(-1);
      if (earliestStart && blockers.length === nodeBlockerCount && !edges.some((edge) => blocked.has(key(edge.predecessor)))) {
        const dependencyIds = violations.filter((item) => item.earliestStart === earliestStart).map((item) => item.dependencyId);
        const tightened = violations.some((item) => item.tightened);
        const worsenedByChildren = proposed.source === "derived" && proposed.start !== original.start &&
          (!original.start || (start !== null && start < original.start));
        if (change) blockers.push({ code: "inbound_conflict", entity: ref, earliestStart, dependencyIds });
        else if (tightened || worsenedByChildren) {
          change = cascadeChange(entity, earliestStart, calendar, version, blockers);
          if (change) proposed = effectiveDates(entity, change.after, memberAfter);
        } else warnings.push({ code: "existing_dependency_conflict", entity: ref, earliestStart, dependencyIds });
      }
    }

    const dependsOnBlockedDates = edges.some((edge) => blocked.has(key(edge.predecessor))) ||
      (proposed.source === "derived" && members.some((member) => blocked.has(key(member))));
    if (blockers.length > nodeBlockerCount || dependsOnBlockedDates) blocked.add(id);
    const writtenDates = change?.after;
    if (change) result.dateChanges.push(change);
    if (assess || changedChildren.length > 0) {
      consulted.add(id);
      changedChildren.forEach((member) => consulted.add(key(member)));
      result.affectedEntities.push({ entity: ref, effectiveBefore: { start: original.start, end: original.end },
        effectiveAfter: { start: proposed.start, end: proposed.end }, dateSourceBefore: original.source,
        dateSourceAfter: proposed.source, constraints, changedChildren: changedChildren.map(endpoint) });
    }
    if (writtenDates && entity.kind === "stage" && proposed.source === "planned") {
      members.forEach((member, index) => {
        const { start: childStart, end: childEnd } = memberAfter[index];
        if (proposed.start && childStart && childStart < proposed.start) {
          warnings.push({ code: "stage_child_date_discrepancy", stage: ref, activity: endpoint(member),
            boundary: "start", stageDate: proposed.start, activityDate: childStart });
        }
        if (proposed.end && childEnd && childEnd > proposed.end) {
          warnings.push({ code: "stage_child_date_discrepancy", stage: ref, activity: endpoint(member),
            boundary: "end", stageDate: proposed.end, activityDate: childEnd });
        }
      });
    }
    if (proposed.end && (!original.end || proposed.end > original.end)) {
      for (const target of targets) {
        if (proposed.end > target.date && (!original.end || original.end <= target.date)) {
          warnings.push({ code: "fixed_target_conflict", entity: ref, targetId: target.id, targetDate: target.date, proposedEnd: proposed.end });
        }
      }
    }
    before.set(id, original);
    after.set(id, proposed);
  }

  const unverifiedYears = calendar.unverifiedYears();
  result.calendar.unverifiedOptionalYears = unverifiedYears;
  if (unverifiedYears.length) warnings.push({ code: "unverified_optional_days", years: unverifiedYears });
  if (dependencyChange) {
    consulted.add(key(dependencyChange.dependency.predecessor));
    consulted.add(key(dependencyChange.dependency.successor));
  }
  if (blockers.length === 0) {
    result.status = result.dateChanges.length || dependencyChange ? "ready" : "unchanged";
    if (result.status === "ready") {
      result.confirmation = { productId: snapshot.productId, scheduleVersion: snapshot.scheduleVersion,
        calendarVersion: version, edit, expectedEntityVersions: [...consulted].sort().map((id) => {
          const entity = entities.get(id)!;
          return { entity: endpoint(entity), version: entity.version };
        }) };
    }
  }
  return structuredClone(result);
}
