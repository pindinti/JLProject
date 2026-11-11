import { neon } from "@neondatabase/serverless";
import type { CalendarImpactCandidate } from "../domain/calendar-impact";
import type { WorkerEnvironment } from "./database";

export interface DisciplineInput {
  name: string; shortCode: string; color: string; displayOrder: number; description: string | null;
}
export interface StageInput { code: string; color: string; displayName: string; displayOrder: number }
export interface ActivityInput {
  name: string; activityType: string | null; plannedStart: string | null;
  plannedEnd: string | null; displayOrder: number; notes: string | null;
  colorOverride?: string | null;
}
export interface WorkingActivityInput extends ActivityInput {
  workingDays: number;
  calendarVersion: number;
}
export type ActivityMetadataInput = Omit<ActivityInput, "plannedStart" | "plannedEnd"> & {
  colorOverride?: string | null;
};
export interface Discipline extends DisciplineInput { id: string; productId: string; version: number }
export interface Stage extends StageInput {
  id: string; disciplineId: string; version: number;
  derivedStart: string | null; derivedEnd: string | null;
}
export interface Activity extends ActivityInput {
  id: string; stageId: string | null; version: number;
  colorOverride: string | null;
  planningMode: "manual" | "working_days";
  workingDayDuration: number | null;
  planningCalendarVersion: number | null;
}
export interface ScheduleHierarchy {
  productId: string;
  rootActivities: Activity[];
  disciplines: (Discipline & { stages: (Stage & { activities: Activity[] })[] })[];
}
export interface StageDefinition { id: string; code: string; color: string }
export type StageDefinitionColorMutation = { status: "ok"; value: StageDefinition } |
  { status: "not_found" } | { status: "stale" };
export interface BusinessTarget { id: string; name: string; description: string | null; color: string;
  targetDate: string; operationalDate: string | null; displayOrder: number; version: number }
export interface TargetInput { name: string; description: string | null; targetDate: string; color: string }
export interface DateChange { operationId: string; changedAt: string;
  previousStart: string | null; previousEnd: string | null;
  newStart: string; newEnd: string; reason: string }
export type DateChangeResult = { status: "updated" | "unchanged"; activity: Activity } |
  { status: "not_found" | "stale" | "invalid" | "forbidden" };
export type WorkingPlanResult = { status: "updated" | "unchanged"; activity: Activity } |
  { status: "not_found" | "stale" | "stale_calendar" | "invalid" | "forbidden" };
export interface CalendarRescheduleProposal {
  activityId: string; disciplineId: string | null; stageId: string | null; expectedVersion: number;
  startDate: string; currentEndDate: string; proposedEndDate: string;
  workingDays: number; savedCalendarVersion: number;
}
export type CalendarRescheduleResult = { status: "updated"; count: number; operationId: string } |
  { status: "not_found" | "stale" | "stale_calendar" | "invalid" | "forbidden" };
export type CalendarRescheduleReversalResult =
  { status: "reversed"; count: number; operationId: string; originalOperationId: string } |
  { status: "stale"; activityId: string } |
  { status: "not_found" | "already_reversed" | "invalid" | "forbidden" };
export interface CalendarRescheduleHistoryActivity {
  activityId: string; name: string | null; previousStart: string; previousEnd: string;
  newStart: string; newEnd: string; currentStart: string | null; currentEnd: string | null;
}
export interface CalendarRescheduleHistoryOperation {
  operationId: string; changedAt: string; actorName: string | null; reason: string;
  status: "eligible" | "already_reversed" | "conflict";
  reversal: { changedAt: string; actorName: string | null; reason: string } | null;
  activities: CalendarRescheduleHistoryActivity[];
}
export type CalendarRescheduleHistoryResult = { status: "ok"; operations: CalendarRescheduleHistoryOperation[] } |
  { status: "not_found" | "forbidden" | "invalid" };
export type ProductChangeEventType = "product_created" | "schedule_imported" | "activity_dates_changed" |
  "business_target_date_changed" | "calendar_rescheduled" | "calendar_reschedule_reversed" |
  "schedule_hierarchy_deleted" | "hierarchy_moved";
export interface ProductChangeHistoryCursor { occurredAt: string; eventId: string }
export interface ProductChangeHistoryItem {
  kind: string; id: string; name: string | null;
  hierarchy?: { scope?: string; discipline?: string | null; stage?: string | null };
}
export interface ProductChangeEvent {
  id: string; occurredAt: string; actorId: string; actorName: string | null;
  eventType: ProductChangeEventType; item: ProductChangeHistoryItem | null;
  justification: string | null; before: Record<string, unknown> | null;
  after: Record<string, unknown> | null; affectedItems: Array<Record<string, unknown>>;
}
export type ProductChangeHistoryResult = { status: "ok"; events: ProductChangeEvent[];
  nextCursor: ProductChangeHistoryCursor | null } | { status: "not_found" | "forbidden" | "invalid" };
export type Mutation<T> = { status: "ok"; value: T } |
  { status: "not_found" | "duplicate" | "stale" | "stale_calendar" | "conflict" | "invalid" | "forbidden" };
export type DeletionKind = "activity" | "stage" | "discipline";
export interface DeletionCounts { disciplines: number; stages: number; activities: number }
export type DeletionPreview = { status: "ok"; fingerprint: string; counts: DeletionCounts } |
  { status: "not_found" | "invalid" | "forbidden" };
export type DeletionResult = { status: "deleted"; operationId: string; counts: DeletionCounts } |
  { status: "not_found" | "invalid" | "forbidden" | "stale" };
export type HierarchyItemKind = "activity" | "stage" | "discipline";
export interface HierarchyMoveInput {
  kind: HierarchyItemKind;
  targetId: string;
  expectedVersion: number;
  destinationDisciplineId: string | null;
  destinationStageId: string | null;
  destinationIndex: number;
  expectedSourceOrder: string[];
  expectedDestinationOrder: string[];
}
export type HierarchyMoveResult =
  { status: "moved"; operationId: string; version: number } |
  { status: "unchanged"; version: number } |
  { status: "not_found" | "invalid" | "forbidden" | "stale" | "conflict" | "duplicate" };

export interface ScheduleRepository {
  moveHierarchyItem(workspaceId: string, productId: string, actorId: string,
    operationId: string, input: HierarchyMoveInput): Promise<HierarchyMoveResult>;
  previewDeletion(workspaceId: string, productId: string, actorId: string,
    kind: DeletionKind, targetId: string): Promise<DeletionPreview>;
  deleteSubtree(workspaceId: string, productId: string, actorId: string,
    operationId: string, kind: DeletionKind, targetId: string,
    fingerprint: string, reason: string): Promise<DeletionResult>;
  listStageDefinitions(workspaceId: string): Promise<StageDefinition[]>;
  updateStageDefinitionColor(workspaceId: string, definitionId: string, expectedColor: string,
    color: string): Promise<StageDefinitionColorMutation>;
  productExists(workspaceId: string, productId: string, activeOnly: boolean): Promise<boolean>;
  disciplineExists(workspaceId: string, productId: string, disciplineId: string, activeOnly: boolean): Promise<boolean>;
  stageExists(workspaceId: string, productId: string, disciplineId: string, stageId: string, activeOnly: boolean): Promise<boolean>;
  activityExists(workspaceId: string, productId: string, disciplineId: string | null, stageId: string | null,
    activityId: string, activeOnly: boolean): Promise<boolean>;
  listDisciplines(workspaceId: string, productId: string): Promise<Discipline[]>;
  createDiscipline(workspaceId: string, productId: string, actorId: string, input: DisciplineInput): Promise<Mutation<Discipline>>;
  updateDiscipline(workspaceId: string, productId: string, disciplineId: string, actorId: string, input: DisciplineInput, version: number): Promise<Mutation<Discipline>>;
  listStages(workspaceId: string, productId: string, disciplineId: string): Promise<Stage[]>;
  createStage(workspaceId: string, productId: string, disciplineId: string, actorId: string, input: StageInput): Promise<Mutation<Stage>>;
  updateStage(workspaceId: string, productId: string, disciplineId: string, stageId: string, actorId: string, input: StageInput, version: number): Promise<Mutation<Stage>>;
  listActivities(workspaceId: string, productId: string, disciplineId: string, stageId: string): Promise<Activity[]>;
  listRootActivities(workspaceId: string, productId: string): Promise<Activity[]>;
  listWorkingPlans(workspaceId: string, productId: string): Promise<CalendarImpactCandidate[]>;
  applyCalendarReschedule(workspaceId: string, productId: string, actorId: string,
    operationId: string, calendarVersion: number, reason: string,
    proposals: CalendarRescheduleProposal[]): Promise<CalendarRescheduleResult>;
  reverseCalendarReschedule(workspaceId: string, productId: string, actorId: string,
    originalOperationId: string, operationId: string, reason: string): Promise<CalendarRescheduleReversalResult>;
  listCalendarRescheduleHistory(workspaceId: string, productId: string, actorId: string):
    Promise<CalendarRescheduleHistoryResult>;
  listProductChangeHistory(workspaceId: string, productId: string, actorId: string, limit: number,
    cursor: ProductChangeHistoryCursor | null): Promise<ProductChangeHistoryResult>;
  createActivity(workspaceId: string, productId: string, disciplineId: string | null, stageId: string | null, actorId: string, input: ActivityInput): Promise<Mutation<Activity>>;
  createWorkingActivity(workspaceId: string, productId: string, disciplineId: string | null, stageId: string | null,
    actorId: string, input: WorkingActivityInput): Promise<Mutation<Activity>>;
  updateActivity(workspaceId: string, productId: string, disciplineId: string | null, stageId: string | null, activityId: string, actorId: string, input: ActivityMetadataInput, version: number): Promise<Mutation<Activity>>;
  changeActivityDates(workspaceId: string, productId: string, disciplineId: string | null, stageId: string | null,
    activityId: string, actorId: string, start: string, end: string, reason: string | null,
    version: number, operationId: string): Promise<DateChangeResult>;
  changeActivityWorkingPlan(workspaceId: string, productId: string, disciplineId: string | null, stageId: string | null,
    activityId: string, actorId: string, start: string, end: string, workingDays: number,
    calendarVersion: number, reason: string | null, version: number,
    operationId: string): Promise<WorkingPlanResult>;
  listActivityDateHistory(workspaceId: string, productId: string, disciplineId: string | null,
    stageId: string | null, activityId: string): Promise<DateChange[]>;
  getHierarchy(workspaceId: string, productId: string): Promise<ScheduleHierarchy | null>;
  listTargets(workspaceId: string, productId: string): Promise<BusinessTarget[]>;
  createTarget(workspaceId: string, productId: string, actorId: string, input: TargetInput): Promise<Mutation<BusinessTarget>>;
  updateTarget(workspaceId: string, productId: string, targetId: string, actorId: string,
    input: TargetInput, version: number, reason: string | null, operationId: string): Promise<Mutation<BusinessTarget>>;
  deleteTarget(workspaceId: string, productId: string, targetId: string, actorId: string,
    version: number, operationId: string): Promise<Mutation<BusinessTarget>>;
}

const text = (value: unknown) => String(value);
const nullable = (value: unknown) => value === null || value === undefined ? null : String(value);
const productChangeEventTypes = new Set<ProductChangeEventType>([
  "product_created", "schedule_imported", "activity_dates_changed", "business_target_date_changed",
  "calendar_rescheduled", "calendar_reschedule_reversed", "schedule_hierarchy_deleted", "hierarchy_moved"
]);

function jsonRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : null;
}

function productChangeEvent(value: unknown): ProductChangeEvent {
  const event = jsonRecord(value);
  if (!event || typeof event["id"] !== "string" || typeof event["occurredAt"] !== "string" ||
      typeof event["actorId"] !== "string" ||
      (event["actorName"] !== null && typeof event["actorName"] !== "string") ||
      typeof event["eventType"] !== "string" ||
      !productChangeEventTypes.has(event["eventType"] as ProductChangeEventType) ||
      (event["justification"] !== null && typeof event["justification"] !== "string") ||
      !Array.isArray(event["affectedItems"])) throw new Error("Invalid product change history event.");
  let item: ProductChangeHistoryItem | null = null;
  if (event["item"] !== null) {
    const rawItem = jsonRecord(event["item"]);
    const rawHierarchy = rawItem && rawItem["hierarchy"] !== undefined
      ? jsonRecord(rawItem["hierarchy"]) : null;
    if (!rawItem || typeof rawItem["kind"] !== "string" || typeof rawItem["id"] !== "string" ||
        (rawItem["name"] !== null && typeof rawItem["name"] !== "string") ||
        (rawItem["hierarchy"] !== undefined && !rawHierarchy) ||
        (rawHierarchy?.["scope"] !== undefined && typeof rawHierarchy["scope"] !== "string"))
      throw new Error("Invalid product change history item.");
    item = { kind: rawItem["kind"], id: rawItem["id"], name: rawItem["name"] as string | null,
      ...(rawHierarchy ? { hierarchy: {
        ...(rawHierarchy["scope"] === undefined ? {} : { scope: rawHierarchy["scope"] as string }),
        ...(rawHierarchy["discipline"] === undefined ? {} : { discipline: nullable(rawHierarchy["discipline"]) }),
        ...(rawHierarchy["stage"] === undefined ? {} : { stage: nullable(rawHierarchy["stage"]) })
      } } : {}) };
  }
  const before = event["before"] === null ? null : jsonRecord(event["before"]);
  const after = event["after"] === null ? null : jsonRecord(event["after"]);
  if ((event["before"] !== null && !before) || (event["after"] !== null && !after) ||
      event["item"] === undefined || event["before"] === undefined || event["after"] === undefined)
    throw new Error("Invalid product change history details.");
  return { id: event["id"], occurredAt: event["occurredAt"], actorId: event["actorId"],
    actorName: event["actorName"] as string | null, eventType: event["eventType"] as ProductChangeEventType,
    item, justification: event["justification"] as string | null, before, after,
    affectedItems: event["affectedItems"].map((entry) => {
      const record = jsonRecord(entry);
      if (!record) throw new Error("Invalid product change history affected item.");
      return record;
    }) };
}

function discipline(row: Record<string, unknown>): Discipline {
  return { id: text(row["id"]), productId: text(row["productId"]),
    name: text(row["name"]), shortCode: text(row["shortCode"]), color: text(row["color"]),
    displayOrder: Number(row["displayOrder"]), description: nullable(row["description"]),
    version: Number(row["version"]) };
}
function stage(row: Record<string, unknown>): Stage {
  return { id: text(row["id"]), disciplineId: text(row["disciplineId"]),
    code: text(row["code"]), color: text(row["color"]), displayName: text(row["displayName"]),
    displayOrder: Number(row["displayOrder"]), version: Number(row["version"]),
    derivedStart: nullable(row["derivedStart"]), derivedEnd: nullable(row["derivedEnd"]) };
}
function activity(row: Record<string, unknown>): Activity {
  return { id: text(row["id"]), stageId: nullable(row["stageId"]), name: text(row["name"]),
    activityType: nullable(row["activityType"]), plannedStart: nullable(row["plannedStart"]),
    plannedEnd: nullable(row["plannedEnd"]), displayOrder: Number(row["displayOrder"]),
    notes: nullable(row["notes"]), colorOverride: nullable(row["colorOverride"]), version: Number(row["version"]),
    planningMode: row["planningMode"] === "working_days" ? "working_days" : "manual",
    workingDayDuration: row["workingDayDuration"] == null ? null : Number(row["workingDayDuration"]),
    planningCalendarVersion: row["planningCalendarVersion"] == null
      ? null : Number(row["planningCalendarVersion"]) };
}
function duplicate(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "23505";
}

export function assembleHierarchy(productId: string, rows: Record<string, unknown>[],
  rootRows: Record<string, unknown>[] = []): ScheduleHierarchy | null {
  if (!rows[0]) return null;
  const hierarchy: ScheduleHierarchy = { productId, rootActivities: rootRows.map(activity), disciplines: [] };
  type HierarchyDiscipline = ScheduleHierarchy["disciplines"][number];
  type HierarchyStage = HierarchyDiscipline["stages"][number];
  const disciplines = new Map<string, HierarchyDiscipline>();
  const stages = new Map<string, HierarchyStage>();
  for (const row of rows) {
    if (row["disciplineId"] === null) continue;
    const disciplineId = text(row["disciplineId"]);
    let currentDiscipline = disciplines.get(disciplineId);
    if (!currentDiscipline) {
      currentDiscipline = { id: disciplineId, productId,
        name: text(row["disciplineName"]), shortCode: text(row["disciplineCode"]),
        color: text(row["disciplineColor"]), displayOrder: Number(row["disciplineOrder"]),
        description: nullable(row["disciplineDescription"]), version: Number(row["disciplineVersion"]), stages: [] };
      disciplines.set(disciplineId, currentDiscipline);
      hierarchy.disciplines.push(currentDiscipline);
    }
    if (row["stageId"] === null) continue;
    const stageId = text(row["stageId"]);
    let currentStage = stages.get(stageId);
    if (!currentStage) {
      currentStage = { id: stageId, disciplineId, code: text(row["stageCode"]),
        color: text(row["stageColor"]), displayName: text(row["stageName"]),
        displayOrder: Number(row["stageOrder"]), version: Number(row["stageVersion"]),
        derivedStart: null, derivedEnd: null, activities: [] };
      stages.set(stageId, currentStage);
      currentDiscipline.stages.push(currentStage);
    }
    if (row["activityId"] === null) continue;
    const item: Activity = { id: text(row["activityId"]), stageId,
      name: text(row["activityName"]), activityType: nullable(row["activityType"]),
      plannedStart: nullable(row["plannedStart"]), plannedEnd: nullable(row["plannedEnd"]),
      displayOrder: Number(row["activityOrder"]), notes: nullable(row["activityNotes"]),
      colorOverride: nullable(row["activityColorOverride"]), version: Number(row["activityVersion"]),
      planningMode: row["planningMode"] === "working_days" ? "working_days" : "manual",
      workingDayDuration: row["workingDayDuration"] == null ? null : Number(row["workingDayDuration"]),
      planningCalendarVersion: row["planningCalendarVersion"] == null
        ? null : Number(row["planningCalendarVersion"]) };
    currentStage.activities.push(item);
    if (item.plannedStart && (!currentStage.derivedStart || item.plannedStart < currentStage.derivedStart))
      currentStage.derivedStart = item.plannedStart;
    if (item.plannedEnd && (!currentStage.derivedEnd || item.plannedEnd > currentStage.derivedEnd))
      currentStage.derivedEnd = item.plannedEnd;
  }
  return hierarchy;
}

export function createScheduleRepository(environment: WorkerEnvironment): ScheduleRepository {
  if (!environment.DATABASE_URL) throw new Error("Worker database configuration is missing.");
  const sql = neon(environment.DATABASE_URL);

  async function productExists(ws: string, productId: string, activeOnly: boolean) {
    const rows = await sql`SELECT 1 FROM public.products
      WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid
        AND (${activeOnly} = false OR active = true) LIMIT 1`;
    return rows.length > 0;
  }
  async function disciplineExists(ws: string, productId: string, disciplineId: string, activeOnly: boolean) {
    const rows = await sql`SELECT 1 FROM public.product_disciplines AS d
      JOIN public.products AS p ON p.id = d.product_id AND p.workspace_id = d.workspace_id
      WHERE d.workspace_id = ${ws}::uuid AND d.product_id = ${productId}::uuid
        AND d.id = ${disciplineId}::uuid AND d.deleted_at IS NULL
        AND (${activeOnly} = false OR p.active = true) LIMIT 1`;
    return rows.length > 0;
  }
  async function stageExists(ws: string, productId: string, disciplineId: string, stageId: string, activeOnly: boolean) {
    const rows = await sql`SELECT 1 FROM public.discipline_stages AS s
      JOIN public.products AS p ON p.id = s.product_id AND p.workspace_id = s.workspace_id
      JOIN public.product_disciplines AS d ON d.id = s.discipline_id AND d.deleted_at IS NULL
      WHERE s.workspace_id = ${ws}::uuid AND s.product_id = ${productId}::uuid
        AND s.discipline_id = ${disciplineId}::uuid AND s.id = ${stageId}::uuid
        AND s.deleted_at IS NULL
        AND (${activeOnly} = false OR p.active = true) LIMIT 1`;
    return rows.length > 0;
  }
  async function activityExists(ws: string, productId: string, disciplineId: string | null,
    stageId: string | null, activityId: string, activeOnly: boolean) {
    const rows = await sql`SELECT 1 FROM public.stage_activities AS a
      JOIN public.products AS p ON p.id = a.product_id AND p.workspace_id = a.workspace_id
      WHERE a.workspace_id = ${ws}::uuid AND a.product_id = ${productId}::uuid
        AND a.discipline_id IS NOT DISTINCT FROM ${disciplineId}::uuid
        AND a.stage_id IS NOT DISTINCT FROM ${stageId}::uuid
        AND a.id = ${activityId}::uuid AND a.deleted_at IS NULL
        AND ((a.discipline_id IS NULL AND a.stage_id IS NULL) OR EXISTS (
          SELECT 1 FROM public.discipline_stages AS s
          JOIN public.product_disciplines AS d ON d.id = s.discipline_id
            AND d.workspace_id = s.workspace_id AND d.product_id = s.product_id
          WHERE s.id = a.stage_id AND s.discipline_id = a.discipline_id
            AND s.workspace_id = a.workspace_id AND s.product_id = a.product_id
            AND s.deleted_at IS NULL AND d.deleted_at IS NULL))
        AND (${activeOnly} = false OR p.active = true) LIMIT 1`;
    return rows.length > 0;
  }
  async function listDisciplines(ws: string, productId: string): Promise<Discipline[]> {
    const rows = await sql`SELECT id::text AS id, product_id::text AS "productId", name,
      short_code AS "shortCode", color, display_order AS "displayOrder", description, version
      FROM public.product_disciplines WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
        AND deleted_at IS NULL
      ORDER BY display_order, id`;
    return rows.map(discipline);
  }
  async function findDiscipline(ws: string, productId: string, disciplineId: string) {
    const rows = await sql`SELECT id::text AS id, product_id::text AS "productId", name,
      short_code AS "shortCode", color, display_order AS "displayOrder", description, version
      FROM public.product_disciplines WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
        AND id = ${disciplineId}::uuid AND deleted_at IS NULL LIMIT 1`;
    return rows[0] ? discipline(rows[0]) : null;
  }
  async function listStages(ws: string, productId: string, disciplineId: string): Promise<Stage[]> {
    const rows = await sql`SELECT s.id::text AS id, s.discipline_id::text AS "disciplineId",
      def.code, def.color, s.display_name AS "displayName", s.display_order AS "displayOrder",
      s.version, to_char(min(a.planned_start), 'YYYY-MM-DD') AS "derivedStart",
      to_char(max(a.planned_end), 'YYYY-MM-DD') AS "derivedEnd"
      FROM public.discipline_stages AS s
      JOIN public.stage_definitions AS def ON def.id = s.definition_id AND def.workspace_id = s.workspace_id
      LEFT JOIN public.stage_activities AS a ON a.stage_id = s.id AND a.workspace_id = s.workspace_id
        AND a.deleted_at IS NULL
      WHERE s.workspace_id = ${ws}::uuid AND s.product_id = ${productId}::uuid
        AND s.discipline_id = ${disciplineId}::uuid AND s.deleted_at IS NULL
      GROUP BY s.id, def.id ORDER BY s.display_order, s.id`;
    return rows.map(stage);
  }
  async function findStage(ws: string, productId: string, disciplineId: string, stageId: string) {
    const rows = await sql`SELECT s.id::text AS id, s.discipline_id::text AS "disciplineId",
      def.code, def.color, s.display_name AS "displayName", s.display_order AS "displayOrder",
      s.version, to_char(min(a.planned_start), 'YYYY-MM-DD') AS "derivedStart",
      to_char(max(a.planned_end), 'YYYY-MM-DD') AS "derivedEnd"
      FROM public.discipline_stages AS s
      JOIN public.stage_definitions AS def ON def.id = s.definition_id AND def.workspace_id = s.workspace_id
      LEFT JOIN public.stage_activities AS a ON a.stage_id = s.id AND a.workspace_id = s.workspace_id
        AND a.deleted_at IS NULL
      WHERE s.workspace_id = ${ws}::uuid AND s.product_id = ${productId}::uuid
        AND s.discipline_id = ${disciplineId}::uuid AND s.id = ${stageId}::uuid AND s.deleted_at IS NULL
      GROUP BY s.id, def.id LIMIT 1`;
    return rows[0] ? stage(rows[0]) : null;
  }
  async function listActivities(ws: string, productId: string, disciplineId: string, stageId: string): Promise<Activity[]> {
    const rows = await sql`SELECT id::text AS id, stage_id::text AS "stageId", name,
      activity_type AS "activityType", to_char(planned_start, 'YYYY-MM-DD') AS "plannedStart",
      to_char(planned_end, 'YYYY-MM-DD') AS "plannedEnd", display_order AS "displayOrder", notes,
      color_override AS "colorOverride", version,
      planning_mode AS "planningMode", working_day_duration AS "workingDayDuration",
      planning_calendar_version AS "planningCalendarVersion"
      FROM public.stage_activities
      WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
        AND discipline_id = ${disciplineId}::uuid AND stage_id = ${stageId}::uuid
        AND deleted_at IS NULL
      ORDER BY display_order, id`;
    return rows.map(activity);
  }
  async function listRootActivities(ws: string, productId: string): Promise<Activity[]> {
    const rows = await sql`SELECT id::text AS id, NULL::text AS "stageId", name,
      activity_type AS "activityType", to_char(planned_start, 'YYYY-MM-DD') AS "plannedStart",
      to_char(planned_end, 'YYYY-MM-DD') AS "plannedEnd", display_order AS "displayOrder", notes,
      color_override AS "colorOverride", version, planning_mode AS "planningMode",
      working_day_duration AS "workingDayDuration",
      planning_calendar_version AS "planningCalendarVersion"
      FROM public.stage_activities
      WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
        AND discipline_id IS NULL AND stage_id IS NULL AND deleted_at IS NULL
      ORDER BY display_order, id`;
    return rows.map(activity);
  }
  async function findActivity(ws: string, productId: string, disciplineId: string | null,
    stageId: string | null, activityId: string) {
    const rows = await sql`SELECT id::text AS id, stage_id::text AS "stageId", name,
      activity_type AS "activityType", to_char(planned_start, 'YYYY-MM-DD') AS "plannedStart",
      to_char(planned_end, 'YYYY-MM-DD') AS "plannedEnd", display_order AS "displayOrder", notes,
      color_override AS "colorOverride", version,
      planning_mode AS "planningMode", working_day_duration AS "workingDayDuration",
      planning_calendar_version AS "planningCalendarVersion"
      FROM public.stage_activities
      WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
        AND discipline_id IS NOT DISTINCT FROM ${disciplineId}::uuid
        AND stage_id IS NOT DISTINCT FROM ${stageId}::uuid
        AND id = ${activityId}::uuid AND deleted_at IS NULL LIMIT 1`;
    return rows[0] ? activity(rows[0]) : null;
  }

  return {
    async moveHierarchyItem(ws, productId, actorId, operationId, input) {
      const rows = await sql`SELECT public.move_schedule_item(
        ${ws}::uuid, ${productId}::uuid, ${actorId}::uuid, ${operationId}::uuid,
        ${input.kind}, ${input.targetId}::uuid, ${input.expectedVersion}::bigint,
        ${input.destinationDisciplineId}::uuid, ${input.destinationStageId}::uuid,
        ${input.destinationIndex}, ${JSON.stringify(input.expectedSourceOrder)}::jsonb,
        ${JSON.stringify(input.expectedDestinationOrder)}::jsonb) AS result`;
      const result = rows[0]?.["result"] as { status?: string; version?: number } | undefined;
      if (!result || !["moved", "unchanged", "not_found", "invalid", "forbidden", "stale",
        "conflict", "duplicate"].includes(result.status ?? ""))
        throw new Error("Unexpected hierarchy movement result.");
      if (result.status === "moved")
        return { status: "moved", operationId, version: Number(result.version) };
      if (result.status === "unchanged")
        return { status: "unchanged", version: Number(result.version) };
      return { status: result.status as "not_found" | "invalid" | "forbidden" | "stale" |
        "conflict" | "duplicate" };
    },
    async previewDeletion(ws, productId, actorId, kind, targetId) {
      const rows = await sql`SELECT public.preview_schedule_deletion(
        ${ws}::uuid, ${productId}::uuid, ${actorId}::uuid, ${kind}, ${targetId}::uuid) AS result`;
      const result = rows[0]?.["result"] as DeletionPreview | undefined;
      if (result?.status === "ok") return { status: "ok", fingerprint: result.fingerprint,
        counts: result.counts };
      if (result && ["not_found", "invalid", "forbidden"].includes(result.status))
        return { status: result.status as "not_found" | "invalid" | "forbidden" };
      throw new Error("Unexpected deletion preview result.");
    },
    async deleteSubtree(ws, productId, actorId, operationId, kind, targetId, fingerprint, reason) {
      const rows = await sql`SELECT public.delete_schedule_subtree(
        ${ws}::uuid, ${productId}::uuid, ${actorId}::uuid, ${operationId}::uuid,
        ${kind}, ${targetId}::uuid, ${fingerprint}, ${reason}) AS result`;
      const result = rows[0]?.["result"] as DeletionResult | undefined;
      if (result?.status === "deleted") return { status: "deleted", operationId, counts: result.counts };
      if (result && ["not_found", "invalid", "forbidden", "stale"].includes(result.status))
        return { status: result.status as "not_found" | "invalid" | "forbidden" | "stale" };
      throw new Error("Unexpected deletion result.");
    },
    async listStageDefinitions(ws) {
      const rows = await sql`SELECT id::text AS id, code, color FROM public.stage_definitions
        WHERE workspace_id = ${ws}::uuid ORDER BY lower(code), id`;
      return rows.map((row) => ({ id: text(row["id"]), code: text(row["code"]), color: text(row["color"]) }));
    },
    async updateStageDefinitionColor(ws, definitionId, expectedColor, color) {
      const rows = await sql`UPDATE public.stage_definitions
        SET color = ${color}
        WHERE workspace_id = ${ws}::uuid AND id = ${definitionId}::uuid
          AND upper(color) = upper(${expectedColor})
        RETURNING id::text AS id, code, color`;
      if (rows[0]) return { status: "ok", value: {
        id: text(rows[0]["id"]), code: text(rows[0]["code"]), color: text(rows[0]["color"])
      } };
      const existing = await sql`SELECT 1 AS found FROM public.stage_definitions
        WHERE workspace_id = ${ws}::uuid AND id = ${definitionId}::uuid LIMIT 1`;
      return { status: existing[0] ? "stale" : "not_found" };
    },
    productExists, disciplineExists, stageExists, activityExists,
    listDisciplines,
    async createDiscipline(ws, productId, actorId, input) {
      const rows = await sql`WITH locked_product AS MATERIALIZED (
        SELECT workspace_id, id FROM public.products
        WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid AND active = true
        FOR UPDATE
      )
      INSERT INTO public.product_disciplines
        (workspace_id, product_id, name, short_code, color, display_order, description, created_by, updated_by)
        SELECT p.workspace_id, p.id, ${input.name}, ${input.shortCode}, ${input.color},
          ${input.displayOrder}, ${input.description}, ${actorId}::uuid, ${actorId}::uuid
        FROM locked_product AS p
        ON CONFLICT DO NOTHING RETURNING id::text AS id`;
      if (!rows[0]) return { status: await productExists(ws, productId, true) ? "duplicate" : "not_found" };
      const value = await findDiscipline(ws, productId, text(rows[0]["id"]));
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async updateDiscipline(ws, productId, disciplineId, actorId, input, version) {
      try {
        const rows = await sql`WITH locked_product AS MATERIALIZED (
          SELECT id FROM public.products
          WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid AND active = true
          FOR UPDATE
        )
        UPDATE public.product_disciplines AS d
          SET name = ${input.name}, short_code = ${input.shortCode}, color = ${input.color},
            description = ${input.description},
            updated_by = ${actorId}::uuid, updated_at = now(), version = d.version + 1
          WHERE d.workspace_id = ${ws}::uuid AND d.product_id = ${productId}::uuid
            AND d.id = ${disciplineId}::uuid AND d.version = ${version}
            AND d.display_order = ${input.displayOrder}
            AND EXISTS (SELECT 1 FROM locked_product)
          RETURNING d.id::text AS id`;
        if (!rows[0]) return { status: await findDiscipline(ws, productId, disciplineId) ? "stale" : "not_found" };
        const value = await findDiscipline(ws, productId, disciplineId);
        return value ? { status: "ok", value } : { status: "not_found" };
      } catch (error) { if (duplicate(error)) return { status: "duplicate" }; throw error; }
    },
    listStages,
    async createStage(ws, productId, disciplineId, actorId, input) {
      const rows = await sql`SELECT public.create_discipline_stage(
        ${ws}::uuid, ${productId}::uuid, ${disciplineId}::uuid, ${actorId}::uuid,
        ${input.code}, ${input.color}, ${input.displayName}, ${input.displayOrder}) AS result`;
      const result = text(rows[0]?.["result"]);
      if (result === "not_found" || result === "duplicate" || result === "conflict") return { status: result };
      const value = await findStage(ws, productId, disciplineId, result);
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async updateStage(ws, productId, disciplineId, stageId, actorId, input, version) {
      const rows = await sql`SELECT public.update_discipline_stage(
        ${ws}::uuid, ${productId}::uuid, ${disciplineId}::uuid, ${stageId}::uuid,
        ${actorId}::uuid, ${input.code}, ${input.color}, ${input.displayName},
        ${input.displayOrder}, ${version}::bigint) AS result`;
      const result = text(rows[0]?.["result"]);
      if (result !== "updated") return { status: result as "not_found" | "duplicate" | "stale" | "conflict" };
      const value = await findStage(ws, productId, disciplineId, stageId);
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    listActivities,
    listRootActivities,
    async listWorkingPlans(ws, productId) {
      const rows = await sql`SELECT id::text AS id, discipline_id::text AS "disciplineId",
        stage_id::text AS "stageId", version,
        to_char(planned_start, 'YYYY-MM-DD') AS "plannedStart",
        to_char(planned_end, 'YYYY-MM-DD') AS "plannedEnd",
        working_day_duration AS "workingDayDuration",
        planning_calendar_version AS "planningCalendarVersion"
        FROM public.stage_activities
        WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
          AND planning_mode = 'working_days' AND deleted_at IS NULL
        ORDER BY id`;
      return rows.map((row): CalendarImpactCandidate => ({
        id: text(row["id"]), disciplineId: nullable(row["disciplineId"]),
        stageId: nullable(row["stageId"]), version: Number(row["version"]),
        planningMode: "working_days", plannedStart: nullable(row["plannedStart"]),
        plannedEnd: nullable(row["plannedEnd"]),
        workingDayDuration: row["workingDayDuration"] == null ? null : Number(row["workingDayDuration"]),
        planningCalendarVersion: row["planningCalendarVersion"] == null
          ? null : Number(row["planningCalendarVersion"])
      }));
    },
    async applyCalendarReschedule(ws, productId, actorId, operationId, calendarVersion, reason, proposals) {
      const rows = await sql`SELECT public.apply_calendar_reschedule(
        ${ws}::uuid, ${productId}::uuid, ${actorId}::uuid, ${operationId}::uuid,
        ${calendarVersion}::bigint, ${reason}, ${JSON.stringify(proposals)}::jsonb) AS result`;
      const result = rows[0]?.["result"] as { status?: string; count?: number } | undefined;
      if (result?.status === "updated" && result.count === proposals.length)
        return { status: "updated", count: result.count, operationId };
      if (result && ["not_found", "stale", "stale_calendar", "invalid", "forbidden"].includes(result.status ?? ""))
        return { status: result.status as "not_found" | "stale" | "stale_calendar" | "invalid" | "forbidden" };
      throw new Error("Unexpected calendar reschedule result.");
    },
    async reverseCalendarReschedule(ws, productId, actorId, originalOperationId, operationId, reason) {
      const rows = await sql`SELECT public.reverse_calendar_reschedule(
        ${ws}::uuid, ${productId}::uuid, ${actorId}::uuid,
        ${originalOperationId}::uuid, ${operationId}::uuid, ${reason}) AS result`;
      const result = rows[0]?.["result"] as { status?: string; count?: number; activityId?: string } | undefined;
      if (result?.status === "reversed" && Number.isSafeInteger(result.count) && Number(result.count) > 0)
        return { status: "reversed", count: Number(result.count), operationId, originalOperationId };
      if (result?.status === "stale" && typeof result.activityId === "string")
        return { status: "stale", activityId: result.activityId };
      if (result && ["not_found", "already_reversed", "invalid", "forbidden"].includes(result.status ?? ""))
        return { status: result.status as "not_found" | "already_reversed" | "invalid" | "forbidden" };
      throw new Error("Unexpected calendar reversal result.");
    },
    async listCalendarRescheduleHistory(ws, productId, actorId) {
      const rows = await sql`SELECT public.list_calendar_reschedule_history(
        ${ws}::uuid, ${productId}::uuid, ${actorId}::uuid) AS result`;
      const result = rows[0]?.["result"] as {
        status?: string; operations?: Array<Record<string, unknown>>
      } | undefined;
      if (result?.status !== "ok") {
        if (result && ["not_found", "forbidden", "invalid"].includes(result.status ?? ""))
          return { status: result.status as "not_found" | "forbidden" | "invalid" };
        throw new Error("Unexpected calendar reschedule history result.");
      }
      if (!Array.isArray(result.operations)) throw new Error("Invalid calendar reschedule history result.");
      const actorIds = new Set<string>();
      for (const item of result.operations) {
        if (typeof item["actorId"] === "string") actorIds.add(item["actorId"]);
        const reversal = item["reversal"];
        if (reversal && typeof reversal === "object" && typeof (reversal as Record<string, unknown>)["actorId"] === "string")
          actorIds.add((reversal as Record<string, unknown>)["actorId"] as string);
      }
      const actorNames = new Map<string, string>();
      if (actorIds.size > 0) {
        const names = await sql`SELECT member.auth_user_id::text AS id,
            NULLIF(auth_user.name, '') AS name
          FROM public.workspace_memberships AS member
          JOIN neon_auth."user" AS auth_user ON auth_user.id = member.auth_user_id
          WHERE member.workspace_id = ${ws}::uuid`;
        for (const row of names) {
          if (row["name"] !== null && row["name"] !== undefined)
            actorNames.set(text(row["id"]), text(row["name"]));
        }
      }
      const operations = result.operations.map((item): CalendarRescheduleHistoryOperation => {
        if (typeof item["operationId"] !== "string" || typeof item["changedAt"] !== "string" ||
            typeof item["actorId"] !== "string" || typeof item["reason"] !== "string" ||
            !["eligible", "already_reversed", "conflict"].includes(String(item["status"])) ||
            !Array.isArray(item["activities"])) throw new Error("Invalid calendar reschedule history operation.");
        const rawReversal = item["reversal"];
        let reversal: CalendarRescheduleHistoryOperation["reversal"] = null;
        if (rawReversal !== null) {
          if (!rawReversal || typeof rawReversal !== "object") throw new Error("Invalid reversal history record.");
          const value = rawReversal as Record<string, unknown>;
          if (typeof value["changedAt"] !== "string" || typeof value["actorId"] !== "string" ||
              typeof value["reason"] !== "string") throw new Error("Invalid reversal history record.");
          reversal = { changedAt: value["changedAt"], actorName: actorNames.get(value["actorId"]) ?? null,
            reason: value["reason"] };
        }
        const activities = item["activities"].map((raw): CalendarRescheduleHistoryActivity => {
          if (!raw || typeof raw !== "object") throw new Error("Invalid activity history record.");
          const value = raw as Record<string, unknown>;
          if (["activityId", "previousStart", "previousEnd", "newStart", "newEnd"]
            .some((key) => typeof value[key] !== "string") ||
            (value["name"] !== null && typeof value["name"] !== "string") ||
            (value["currentStart"] !== null && typeof value["currentStart"] !== "string") ||
            (value["currentEnd"] !== null && typeof value["currentEnd"] !== "string"))
            throw new Error("Invalid activity history record.");
          return { activityId: value["activityId"] as string, name: value["name"] as string | null,
            previousStart: value["previousStart"] as string, previousEnd: value["previousEnd"] as string,
            newStart: value["newStart"] as string, newEnd: value["newEnd"] as string,
            currentStart: value["currentStart"] as string | null, currentEnd: value["currentEnd"] as string | null };
        });
        return { operationId: item["operationId"] as string, changedAt: item["changedAt"] as string,
          actorName: actorNames.get(item["actorId"] as string) ?? null,
          reason: item["reason"] as string, status: item["status"] as CalendarRescheduleHistoryOperation["status"],
          reversal, activities };
      });
      return { status: "ok", operations };
    },
    async listProductChangeHistory(ws, productId, actorId, limit, cursor) {
      const rows = await sql`SELECT public.list_product_change_history(
        ${ws}::uuid, ${productId}::uuid, ${actorId}::uuid, ${limit}::integer,
        ${cursor?.occurredAt ?? null}::timestamptz, ${cursor?.eventId ?? null}::text) AS result`;
      const result = rows[0]?.["result"] as {
        status?: string; events?: unknown[]; nextCursor?: Record<string, unknown> | null
      } | undefined;
      if (result?.status !== "ok") {
        if (result && ["not_found", "forbidden", "invalid"].includes(result.status ?? ""))
          return { status: result.status as "not_found" | "forbidden" | "invalid" };
        throw new Error("Unexpected product change history result.");
      }
      if (!Array.isArray(result.events)) throw new Error("Invalid product change history result.");
      let nextCursor: ProductChangeHistoryCursor | null = null;
      if (result.nextCursor !== null) {
        const rawCursor = result.nextCursor;
        if (!rawCursor || typeof rawCursor["occurredAt"] !== "string" ||
            typeof rawCursor["eventId"] !== "string") throw new Error("Invalid product change history cursor.");
        nextCursor = { occurredAt: rawCursor["occurredAt"], eventId: rawCursor["eventId"] };
      }
      const events = result.events.map(productChangeEvent);
      const actorIds = [...new Set(events.map((event) => event.actorId))];
      const actorNames = new Map<string, string>();
      if (actorIds.length > 0) {
        const actorIdsJson = JSON.stringify(actorIds);
        const nameRows = await sql`
          WITH page_actors AS (
            SELECT value::uuid AS id
            FROM jsonb_array_elements_text(${actorIdsJson}::jsonb) AS actor_entries(value)
          )
          SELECT member.auth_user_id::text AS id, NULLIF(auth_user.name, '') AS name
          FROM page_actors AS page_actor
          JOIN public.workspace_memberships AS member ON member.workspace_id = ${ws}::uuid
            AND member.auth_user_id = page_actor.id
          JOIN neon_auth."user" AS auth_user ON auth_user.id = member.auth_user_id
        `;
        for (const row of nameRows) {
          if (typeof row["id"] === "string" && typeof row["name"] === "string")
            actorNames.set(row["id"], row["name"]);
        }
      }
      for (let index = 1; index < events.length; index += 1) {
        const previous = events[index - 1]!;
        const current = events[index]!;
        if (previous.occurredAt < current.occurredAt ||
            (previous.occurredAt === current.occurredAt && previous.id <= current.id))
          throw new Error("Product change history is not ordered newest first.");
      }
      return { status: "ok", events: events.map((event) => ({ ...event,
        actorName: actorNames.get(event.actorId) ?? null })), nextCursor };
    },
    async createActivity(ws, productId, disciplineId, stageId, actorId, input) {
      const rows = await sql`WITH locked_product AS MATERIALIZED (
        SELECT workspace_id, id FROM public.products
        WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid AND active = true
        FOR UPDATE
      )
      INSERT INTO public.stage_activities
        (workspace_id, product_id, discipline_id, stage_id, name, activity_type,
         planned_start, planned_end, display_order, notes, color_override, created_by, updated_by)
        SELECT p.workspace_id, p.id, s.discipline_id, s.id,
          ${input.name}, ${input.activityType}, ${input.plannedStart}::date,
          ${input.plannedEnd}::date, ${input.displayOrder}, ${input.notes}, ${input.colorOverride ?? null},
          ${actorId}::uuid, ${actorId}::uuid
        FROM locked_product AS p
        LEFT JOIN public.discipline_stages AS s ON s.workspace_id = p.workspace_id
          AND s.product_id = p.id AND s.discipline_id = ${disciplineId}::uuid
          AND s.id = ${stageId}::uuid AND s.deleted_at IS NULL
        WHERE (${disciplineId}::uuid IS NULL AND ${stageId}::uuid IS NULL) OR
          (s.id IS NOT NULL AND ${disciplineId}::uuid IS NOT NULL AND ${stageId}::uuid IS NOT NULL)
        RETURNING id::text AS id`;
      if (!rows[0]) return { status: "not_found" };
      const value = await findActivity(ws, productId, disciplineId, stageId, text(rows[0]["id"]));
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async createWorkingActivity(ws, productId, disciplineId, stageId, actorId, input) {
      const rows = await sql`WITH created AS MATERIALIZED (SELECT public.create_activity_with_working_plan(
        ${ws}::uuid, ${productId}::uuid, ${disciplineId}::uuid, ${stageId}::uuid,
        ${actorId}::uuid, ${input.name}, ${input.activityType}, ${input.plannedStart}::date,
        ${input.plannedEnd}::date, ${input.displayOrder}, ${input.notes},
        ${input.workingDays}, ${input.calendarVersion}::bigint) AS result),
      colored AS (
        UPDATE public.stage_activities AS a SET color_override = ${input.colorOverride ?? null}
        FROM created AS c
        WHERE ${input.colorOverride != null} AND c.result->>'status' = 'created'
          AND a.id = (c.result->>'id')::uuid AND a.workspace_id = ${ws}::uuid
          AND a.product_id = ${productId}::uuid
        RETURNING a.id
      )
      SELECT c.result AS result, (SELECT count(*) FROM colored) AS color_updates FROM created AS c`;
      const result = rows[0]?.["result"] as { status?: string; id?: string } | undefined;
      if (!result || !["created", "not_found", "forbidden", "stale_calendar", "invalid"].includes(result.status ?? ""))
        throw new Error("Unexpected working-day activity creation result.");
      if (result.status !== "created" || !result.id)
        return { status: result.status as "not_found" | "forbidden" | "stale_calendar" | "invalid" };
      const value = await findActivity(ws, productId, disciplineId, stageId, result.id);
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async updateActivity(ws, productId, disciplineId, stageId, activityId, actorId, input, version) {
      const rows = await sql`WITH locked_product AS MATERIALIZED (
        SELECT id FROM public.products
        WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid AND active = true
        FOR UPDATE
      )
      UPDATE public.stage_activities AS a
        SET name = ${input.name}, activity_type = ${input.activityType},
          notes = ${input.notes},
          color_override = CASE WHEN ${input.colorOverride === undefined} THEN a.color_override
            ELSE ${input.colorOverride ?? null} END,
          updated_by = ${actorId}::uuid, updated_at = now(), version = a.version + 1
        WHERE a.workspace_id = ${ws}::uuid AND a.product_id = ${productId}::uuid
          AND a.discipline_id IS NOT DISTINCT FROM ${disciplineId}::uuid
          AND a.stage_id IS NOT DISTINCT FROM ${stageId}::uuid
          AND a.id = ${activityId}::uuid AND a.version = ${version}
          AND a.display_order = ${input.displayOrder}
          AND EXISTS (SELECT 1 FROM locked_product)
        RETURNING a.id::text AS id`;
      if (!rows[0]) return { status: await findActivity(ws, productId, disciplineId, stageId, activityId) ? "stale" : "not_found" };
      const value = await findActivity(ws, productId, disciplineId, stageId, activityId);
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async changeActivityDates(ws, productId, disciplineId, stageId, activityId, actorId,
      start, end, reason, version, operationId) {
      const rows = await sql`WITH locked_product AS MATERIALIZED (
        SELECT id FROM public.products
        WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid AND active = true
        FOR UPDATE
      )
      SELECT public.change_activity_dates(
        ${ws}::uuid, ${productId}::uuid, ${disciplineId}::uuid, ${stageId}::uuid,
        ${activityId}::uuid, ${actorId}::uuid, ${operationId}::uuid,
        ${start}::date, ${end}::date, ${reason}, ${version}::bigint) AS result
      FROM locked_product`;
      if (!rows[0]) return { status: "not_found" };
      const result = rows[0]?.["result"] as { status?: string } | undefined;
      if (!result || !["updated", "unchanged", "not_found", "stale", "invalid", "forbidden"].includes(result.status ?? ""))
        throw new Error("Unexpected date change result.");
      if (result.status !== "updated" && result.status !== "unchanged")
        return { status: result.status as "not_found" | "stale" | "invalid" | "forbidden" };
      const value = await findActivity(ws, productId, disciplineId, stageId, activityId);
      return value ? { status: result.status, activity: value } : { status: "not_found" };
    },
    async changeActivityWorkingPlan(ws, productId, disciplineId, stageId, activityId, actorId,
      start, end, workingDays, calendarVersion, reason, version, operationId) {
      const rows = await sql`WITH locked_product AS MATERIALIZED (
        SELECT id FROM public.products
        WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid AND active = true
        FOR UPDATE
      )
      SELECT public.change_activity_planning(
        ${ws}::uuid, ${productId}::uuid, ${disciplineId}::uuid, ${stageId}::uuid,
        ${activityId}::uuid, ${actorId}::uuid, ${operationId}::uuid, 'working_days',
        ${start}::date, ${end}::date, ${workingDays}, ${calendarVersion}::bigint,
        ${reason}, ${version}::bigint) AS result
      FROM locked_product`;
      if (!rows[0]) return { status: "not_found" };
      const result = rows[0]?.["result"] as { status?: string } | undefined;
      if (!result || !["updated", "unchanged", "not_found", "stale", "stale_calendar", "invalid", "forbidden"].includes(result.status ?? ""))
        throw new Error("Unexpected working-day activity result.");
      if (result.status !== "updated" && result.status !== "unchanged")
        return { status: result.status as "not_found" | "stale" | "stale_calendar" | "invalid" | "forbidden" };
      const value = await findActivity(ws, productId, disciplineId, stageId, activityId);
      return value ? { status: result.status, activity: value } : { status: "not_found" };
    },
    async listActivityDateHistory(ws, productId, _disciplineId, _stageId, activityId) {
      const rows = await sql`SELECT operation_id::text AS "operationId",
        to_char(changed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS "changedAt",
        to_char(previous_start, 'YYYY-MM-DD') AS "previousStart",
        to_char(previous_end, 'YYYY-MM-DD') AS "previousEnd",
        to_char(new_start, 'YYYY-MM-DD') AS "newStart",
        to_char(new_end, 'YYYY-MM-DD') AS "newEnd", reason
        FROM public.activity_date_changes
        WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
          AND activity_id = ${activityId}::uuid
        ORDER BY changed_at DESC, operation_id DESC`;
      return rows.map((row) => ({ operationId: text(row["operationId"]),
        changedAt: text(row["changedAt"]), previousStart: nullable(row["previousStart"]),
        previousEnd: nullable(row["previousEnd"]), newStart: text(row["newStart"]),
        newEnd: text(row["newEnd"]), reason: text(row["reason"]) }));
    },
    async getHierarchy(ws, productId) {
      const rows = await sql`SELECT p.id::text AS "productId",
        d.id::text AS "disciplineId", d.name AS "disciplineName",
        d.short_code AS "disciplineCode", d.color AS "disciplineColor",
        d.display_order AS "disciplineOrder", d.description AS "disciplineDescription",
        d.version AS "disciplineVersion",
        s.id::text AS "stageId", def.code AS "stageCode", def.color AS "stageColor",
        s.display_name AS "stageName", s.display_order AS "stageOrder", s.version AS "stageVersion",
        a.id::text AS "activityId", a.name AS "activityName", a.activity_type AS "activityType",
        to_char(a.planned_start, 'YYYY-MM-DD') AS "plannedStart",
        to_char(a.planned_end, 'YYYY-MM-DD') AS "plannedEnd",
        a.display_order AS "activityOrder", a.notes AS "activityNotes",
        a.color_override AS "activityColorOverride", a.version AS "activityVersion",
        a.planning_mode AS "planningMode", a.working_day_duration AS "workingDayDuration",
        a.planning_calendar_version AS "planningCalendarVersion"
        FROM public.products AS p
        LEFT JOIN public.product_disciplines AS d ON d.product_id = p.id AND d.workspace_id = p.workspace_id
          AND d.deleted_at IS NULL
        LEFT JOIN public.discipline_stages AS s ON s.discipline_id = d.id AND s.workspace_id = p.workspace_id
          AND s.deleted_at IS NULL
        LEFT JOIN public.stage_definitions AS def ON def.id = s.definition_id AND def.workspace_id = p.workspace_id
        LEFT JOIN public.stage_activities AS a ON a.stage_id = s.id AND a.workspace_id = p.workspace_id
          AND a.deleted_at IS NULL
        WHERE p.workspace_id = ${ws}::uuid AND p.id = ${productId}::uuid
        ORDER BY d.display_order, d.id, s.display_order, s.id, a.display_order, a.id`;
      if (!rows[0]) return null;
      const rootRows = await sql`SELECT id::text AS id, NULL::text AS "stageId", name,
        activity_type AS "activityType", to_char(planned_start, 'YYYY-MM-DD') AS "plannedStart",
        to_char(planned_end, 'YYYY-MM-DD') AS "plannedEnd", display_order AS "displayOrder", notes,
        color_override AS "colorOverride", version, planning_mode AS "planningMode",
        working_day_duration AS "workingDayDuration",
        planning_calendar_version AS "planningCalendarVersion"
        FROM public.stage_activities
        WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
          AND discipline_id IS NULL AND stage_id IS NULL AND deleted_at IS NULL
        ORDER BY display_order, id`;
      return assembleHierarchy(productId, rows, rootRows);
    },
    async listTargets(ws, productId) {
      const rows = await sql`SELECT id::text AS id, name,
        description, color,
        to_char(target_date, 'YYYY-MM-DD') AS "targetDate",
        to_char(operational_date, 'YYYY-MM-DD') AS "operationalDate",
        display_order AS "displayOrder", version
        FROM public.business_targets
        WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
          AND deleted_at IS NULL
        ORDER BY display_order, id`;
      return rows.map((row) => ({ id: text(row["id"]), name: text(row["name"]),
        description: nullable(row["description"]), color: text(row["color"]),
        targetDate: text(row["targetDate"]), operationalDate: nullable(row["operationalDate"]),
        displayOrder: Number(row["displayOrder"]), version: Number(row["version"]) }));
    },
    async createTarget(ws, productId, actorId, input) {
      try {
        const rows = await sql`WITH locked_product AS MATERIALIZED (
          SELECT workspace_id, id FROM public.products
          WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid AND active = true
          FOR UPDATE
        )
        INSERT INTO public.business_targets
          (workspace_id, product_id, name, description, color, target_date, source_external_id,
           source_row, display_order, created_by)
          SELECT p.workspace_id, p.id, ${input.name}, ${input.description}, ${input.color},
            ${input.targetDate}::date, NULL, NULL,
            (SELECT COALESCE(max(display_order) + 1, 0) FROM public.business_targets
              WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid), ${actorId}::uuid
          FROM locked_product AS p
          RETURNING id::text AS id`;
        if (!rows[0]) return { status: "not_found" };
        const value = (await this.listTargets(ws, productId)).find((target) => target.id === text(rows[0]["id"]));
        return value ? { status: "ok", value } : { status: "not_found" };
      } catch (error) { if (duplicate(error)) return { status: "duplicate" }; throw error; }
    },
    async updateTarget(ws, productId, targetId, actorId, input, version, reason, operationId) {
      let rows;
      try {
        rows = await sql`WITH locked_product AS MATERIALIZED (
          SELECT id FROM public.products
          WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid AND active = true
          FOR UPDATE
        )
        SELECT public.update_business_target(
          ${ws}::uuid, ${productId}::uuid, ${targetId}::uuid, ${actorId}::uuid,
          ${operationId}::uuid, ${input.name}, ${input.description}, ${input.color},
          ${input.targetDate}::date, ${version}::bigint, ${reason}) AS result
        FROM locked_product`;
      } catch (error) { if (duplicate(error)) return { status: "duplicate" }; throw error; }
      if (!rows[0]) return { status: "not_found" };
      const result = text(rows[0]?.["result"]);
      if (result !== "updated") return { status: result as "not_found" | "stale" | "duplicate" };
      const value = (await this.listTargets(ws, productId)).find((target) => target.id === targetId);
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async deleteTarget(ws, productId, targetId, actorId, version, operationId) {
      const rows = await sql`WITH locked_product AS MATERIALIZED (
        SELECT id FROM public.products
        WHERE workspace_id = ${ws}::uuid AND id = ${productId}::uuid AND active = true
        FOR UPDATE
      )
      SELECT public.delete_business_target(
        ${ws}::uuid, ${productId}::uuid, ${targetId}::uuid, ${actorId}::uuid,
        ${operationId}::uuid, ${version}::bigint) AS result
      FROM locked_product`;
      if (!rows[0]) return { status: "not_found" };
      const result = text(rows[0]?.["result"]);
      return result === "deleted" ? { status: "ok", value: { id: targetId } as BusinessTarget }
        : { status: result as "not_found" | "stale" };
    }
  };
}
