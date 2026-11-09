import { neon } from "@neondatabase/serverless";
import type { WorkerEnvironment } from "./database";

export interface DisciplineInput {
  name: string; shortCode: string; color: string; displayOrder: number; description: string | null;
}
export interface StageInput { code: string; color: string; displayName: string; displayOrder: number }
export interface ActivityInput {
  name: string; activityType: string | null; plannedStart: string | null;
  plannedEnd: string | null; displayOrder: number; notes: string | null;
}
export type ActivityMetadataInput = Omit<ActivityInput, "plannedStart" | "plannedEnd">;
export interface Discipline extends DisciplineInput { id: string; productId: string; version: number }
export interface Stage extends StageInput {
  id: string; disciplineId: string; version: number;
  derivedStart: string | null; derivedEnd: string | null;
}
export interface Activity extends ActivityInput { id: string; stageId: string; version: number }
export interface ScheduleHierarchy {
  productId: string;
  disciplines: (Discipline & { stages: (Stage & { activities: Activity[] })[] })[];
}
export interface StageDefinition { id: string; code: string; color: string }
export interface BusinessTarget { id: string; name: string; description: string | null; color: string;
  targetDate: string; operationalDate: string | null; displayOrder: number; version: number }
export interface TargetInput { name: string; description: string | null; targetDate: string; color: string }
export interface DateChange { operationId: string; changedAt: string;
  previousStart: string | null; previousEnd: string | null;
  newStart: string; newEnd: string; reason: string }
export type DateChangeResult = { status: "updated" | "unchanged"; activity: Activity } |
  { status: "not_found" | "stale" | "invalid" | "forbidden" };
export type Mutation<T> = { status: "ok"; value: T } |
  { status: "not_found" | "duplicate" | "stale" | "conflict" | "invalid" | "forbidden" };

export interface ScheduleRepository {
  listStageDefinitions(workspaceId: string): Promise<StageDefinition[]>;
  productExists(workspaceId: string, productId: string, activeOnly: boolean): Promise<boolean>;
  disciplineExists(workspaceId: string, productId: string, disciplineId: string, activeOnly: boolean): Promise<boolean>;
  stageExists(workspaceId: string, productId: string, disciplineId: string, stageId: string, activeOnly: boolean): Promise<boolean>;
  activityExists(workspaceId: string, productId: string, disciplineId: string, stageId: string,
    activityId: string, activeOnly: boolean): Promise<boolean>;
  listDisciplines(workspaceId: string, productId: string): Promise<Discipline[]>;
  createDiscipline(workspaceId: string, productId: string, actorId: string, input: DisciplineInput): Promise<Mutation<Discipline>>;
  updateDiscipline(workspaceId: string, productId: string, disciplineId: string, actorId: string, input: DisciplineInput, version: number): Promise<Mutation<Discipline>>;
  listStages(workspaceId: string, productId: string, disciplineId: string): Promise<Stage[]>;
  createStage(workspaceId: string, productId: string, disciplineId: string, actorId: string, input: StageInput): Promise<Mutation<Stage>>;
  updateStage(workspaceId: string, productId: string, disciplineId: string, stageId: string, actorId: string, input: StageInput, version: number): Promise<Mutation<Stage>>;
  listActivities(workspaceId: string, productId: string, disciplineId: string, stageId: string): Promise<Activity[]>;
  createActivity(workspaceId: string, productId: string, disciplineId: string, stageId: string, actorId: string, input: ActivityInput): Promise<Mutation<Activity>>;
  updateActivity(workspaceId: string, productId: string, disciplineId: string, stageId: string, activityId: string, actorId: string, input: ActivityMetadataInput, version: number): Promise<Mutation<Activity>>;
  changeActivityDates(workspaceId: string, productId: string, disciplineId: string, stageId: string,
    activityId: string, actorId: string, start: string, end: string, reason: string | null,
    version: number, operationId: string): Promise<DateChangeResult>;
  listActivityDateHistory(workspaceId: string, productId: string, disciplineId: string,
    stageId: string, activityId: string): Promise<DateChange[]>;
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
  return { id: text(row["id"]), stageId: text(row["stageId"]), name: text(row["name"]),
    activityType: nullable(row["activityType"]), plannedStart: nullable(row["plannedStart"]),
    plannedEnd: nullable(row["plannedEnd"]), displayOrder: Number(row["displayOrder"]),
    notes: nullable(row["notes"]), version: Number(row["version"]) };
}
function duplicate(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "23505";
}

export function assembleHierarchy(productId: string, rows: Record<string, unknown>[]): ScheduleHierarchy | null {
  if (!rows[0]) return null;
  const hierarchy: ScheduleHierarchy = { productId, disciplines: [] };
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
      version: Number(row["activityVersion"]) };
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
        AND d.id = ${disciplineId}::uuid AND (${activeOnly} = false OR p.active = true) LIMIT 1`;
    return rows.length > 0;
  }
  async function stageExists(ws: string, productId: string, disciplineId: string, stageId: string, activeOnly: boolean) {
    const rows = await sql`SELECT 1 FROM public.discipline_stages AS s
      JOIN public.products AS p ON p.id = s.product_id AND p.workspace_id = s.workspace_id
      WHERE s.workspace_id = ${ws}::uuid AND s.product_id = ${productId}::uuid
        AND s.discipline_id = ${disciplineId}::uuid AND s.id = ${stageId}::uuid
        AND (${activeOnly} = false OR p.active = true) LIMIT 1`;
    return rows.length > 0;
  }
  async function activityExists(ws: string, productId: string, disciplineId: string,
    stageId: string, activityId: string, activeOnly: boolean) {
    const rows = await sql`SELECT 1 FROM public.stage_activities AS a
      JOIN public.products AS p ON p.id = a.product_id AND p.workspace_id = a.workspace_id
      WHERE a.workspace_id = ${ws}::uuid AND a.product_id = ${productId}::uuid
        AND a.discipline_id = ${disciplineId}::uuid AND a.stage_id = ${stageId}::uuid
        AND a.id = ${activityId}::uuid AND (${activeOnly} = false OR p.active = true) LIMIT 1`;
    return rows.length > 0;
  }
  async function listDisciplines(ws: string, productId: string): Promise<Discipline[]> {
    const rows = await sql`SELECT id::text AS id, product_id::text AS "productId", name,
      short_code AS "shortCode", color, display_order AS "displayOrder", description, version
      FROM public.product_disciplines WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
      ORDER BY display_order, id`;
    return rows.map(discipline);
  }
  async function findDiscipline(ws: string, productId: string, disciplineId: string) {
    const rows = await sql`SELECT id::text AS id, product_id::text AS "productId", name,
      short_code AS "shortCode", color, display_order AS "displayOrder", description, version
      FROM public.product_disciplines WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
        AND id = ${disciplineId}::uuid LIMIT 1`;
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
      WHERE s.workspace_id = ${ws}::uuid AND s.product_id = ${productId}::uuid
        AND s.discipline_id = ${disciplineId}::uuid
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
      WHERE s.workspace_id = ${ws}::uuid AND s.product_id = ${productId}::uuid
        AND s.discipline_id = ${disciplineId}::uuid AND s.id = ${stageId}::uuid
      GROUP BY s.id, def.id LIMIT 1`;
    return rows[0] ? stage(rows[0]) : null;
  }
  async function listActivities(ws: string, productId: string, disciplineId: string, stageId: string): Promise<Activity[]> {
    const rows = await sql`SELECT id::text AS id, stage_id::text AS "stageId", name,
      activity_type AS "activityType", to_char(planned_start, 'YYYY-MM-DD') AS "plannedStart",
      to_char(planned_end, 'YYYY-MM-DD') AS "plannedEnd", display_order AS "displayOrder", notes, version
      FROM public.stage_activities
      WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
        AND discipline_id = ${disciplineId}::uuid AND stage_id = ${stageId}::uuid
      ORDER BY display_order, id`;
    return rows.map(activity);
  }
  async function findActivity(ws: string, productId: string, disciplineId: string, stageId: string, activityId: string) {
    const rows = await sql`SELECT id::text AS id, stage_id::text AS "stageId", name,
      activity_type AS "activityType", to_char(planned_start, 'YYYY-MM-DD') AS "plannedStart",
      to_char(planned_end, 'YYYY-MM-DD') AS "plannedEnd", display_order AS "displayOrder", notes, version
      FROM public.stage_activities
      WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
        AND discipline_id = ${disciplineId}::uuid AND stage_id = ${stageId}::uuid
        AND id = ${activityId}::uuid LIMIT 1`;
    return rows[0] ? activity(rows[0]) : null;
  }

  return {
    async listStageDefinitions(ws) {
      const rows = await sql`SELECT id::text AS id, code, color FROM public.stage_definitions
        WHERE workspace_id = ${ws}::uuid ORDER BY lower(code), id`;
      return rows.map((row) => ({ id: text(row["id"]), code: text(row["code"]), color: text(row["color"]) }));
    },
    productExists, disciplineExists, stageExists, activityExists,
    listDisciplines,
    async createDiscipline(ws, productId, actorId, input) {
      const rows = await sql`INSERT INTO public.product_disciplines
        (workspace_id, product_id, name, short_code, color, display_order, description, created_by, updated_by)
        SELECT p.workspace_id, p.id, ${input.name}, ${input.shortCode}, ${input.color},
          ${input.displayOrder}, ${input.description}, ${actorId}::uuid, ${actorId}::uuid
        FROM public.products AS p WHERE p.workspace_id = ${ws}::uuid AND p.id = ${productId}::uuid AND p.active = true
        ON CONFLICT DO NOTHING RETURNING id::text AS id`;
      if (!rows[0]) return { status: await productExists(ws, productId, true) ? "duplicate" : "not_found" };
      const value = await findDiscipline(ws, productId, text(rows[0]["id"]));
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async updateDiscipline(ws, productId, disciplineId, actorId, input, version) {
      try {
        const rows = await sql`UPDATE public.product_disciplines AS d
          SET name = ${input.name}, short_code = ${input.shortCode}, color = ${input.color},
            display_order = ${input.displayOrder}, description = ${input.description},
            updated_by = ${actorId}::uuid, updated_at = now(), version = d.version + 1
          WHERE d.workspace_id = ${ws}::uuid AND d.product_id = ${productId}::uuid
            AND d.id = ${disciplineId}::uuid AND d.version = ${version}
            AND EXISTS (SELECT 1 FROM public.products AS p WHERE p.id = d.product_id AND p.active = true)
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
    async createActivity(ws, productId, disciplineId, stageId, actorId, input) {
      const rows = await sql`INSERT INTO public.stage_activities
        (workspace_id, product_id, discipline_id, stage_id, name, activity_type,
         planned_start, planned_end, display_order, notes, created_by, updated_by)
        SELECT s.workspace_id, s.product_id, s.discipline_id, s.id,
          ${input.name}, ${input.activityType}, ${input.plannedStart}::date,
          ${input.plannedEnd}::date, ${input.displayOrder}, ${input.notes},
          ${actorId}::uuid, ${actorId}::uuid
        FROM public.discipline_stages AS s JOIN public.products AS p ON p.id = s.product_id
        WHERE s.workspace_id = ${ws}::uuid AND s.product_id = ${productId}::uuid
          AND s.discipline_id = ${disciplineId}::uuid AND s.id = ${stageId}::uuid AND p.active = true
        RETURNING id::text AS id`;
      if (!rows[0]) return { status: "not_found" };
      const value = await findActivity(ws, productId, disciplineId, stageId, text(rows[0]["id"]));
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async updateActivity(ws, productId, disciplineId, stageId, activityId, actorId, input, version) {
      const rows = await sql`UPDATE public.stage_activities AS a
        SET name = ${input.name}, activity_type = ${input.activityType},
          display_order = ${input.displayOrder}, notes = ${input.notes},
          updated_by = ${actorId}::uuid, updated_at = now(), version = a.version + 1
        WHERE a.workspace_id = ${ws}::uuid AND a.product_id = ${productId}::uuid
          AND a.discipline_id = ${disciplineId}::uuid AND a.stage_id = ${stageId}::uuid
          AND a.id = ${activityId}::uuid AND a.version = ${version}
          AND EXISTS (SELECT 1 FROM public.products AS p WHERE p.id = a.product_id AND p.active = true)
        RETURNING a.id::text AS id`;
      if (!rows[0]) return { status: await findActivity(ws, productId, disciplineId, stageId, activityId) ? "stale" : "not_found" };
      const value = await findActivity(ws, productId, disciplineId, stageId, activityId);
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async changeActivityDates(ws, productId, disciplineId, stageId, activityId, actorId,
      start, end, reason, version, operationId) {
      const rows = await sql`SELECT public.change_activity_dates(
        ${ws}::uuid, ${productId}::uuid, ${disciplineId}::uuid, ${stageId}::uuid,
        ${activityId}::uuid, ${actorId}::uuid, ${operationId}::uuid,
        ${start}::date, ${end}::date, ${reason}, ${version}::bigint) AS result`;
      const result = rows[0]?.["result"] as { status?: string } | undefined;
      if (!result || !["updated", "unchanged", "not_found", "stale", "invalid", "forbidden"].includes(result.status ?? ""))
        throw new Error("Unexpected date change result.");
      if (result.status !== "updated" && result.status !== "unchanged")
        return { status: result.status as "not_found" | "stale" | "invalid" | "forbidden" };
      const value = await findActivity(ws, productId, disciplineId, stageId, activityId);
      return value ? { status: result.status, activity: value } : { status: "not_found" };
    },
    async listActivityDateHistory(ws, productId, disciplineId, stageId, activityId) {
      const rows = await sql`SELECT operation_id::text AS "operationId",
        to_char(changed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS "changedAt",
        to_char(previous_start, 'YYYY-MM-DD') AS "previousStart",
        to_char(previous_end, 'YYYY-MM-DD') AS "previousEnd",
        to_char(new_start, 'YYYY-MM-DD') AS "newStart",
        to_char(new_end, 'YYYY-MM-DD') AS "newEnd", reason
        FROM public.activity_date_changes
        WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid
          AND discipline_id = ${disciplineId}::uuid AND stage_id = ${stageId}::uuid
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
        a.display_order AS "activityOrder", a.notes AS "activityNotes", a.version AS "activityVersion"
        FROM public.products AS p
        LEFT JOIN public.product_disciplines AS d ON d.product_id = p.id AND d.workspace_id = p.workspace_id
        LEFT JOIN public.discipline_stages AS s ON s.discipline_id = d.id AND s.workspace_id = p.workspace_id
        LEFT JOIN public.stage_definitions AS def ON def.id = s.definition_id AND def.workspace_id = p.workspace_id
        LEFT JOIN public.stage_activities AS a ON a.stage_id = s.id AND a.workspace_id = p.workspace_id
        WHERE p.workspace_id = ${ws}::uuid AND p.id = ${productId}::uuid
        ORDER BY d.display_order, d.id, s.display_order, s.id, a.display_order, a.id`;
      return assembleHierarchy(productId, rows);
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
        const rows = await sql`INSERT INTO public.business_targets
          (workspace_id, product_id, name, description, color, target_date, source_external_id,
           source_row, display_order, created_by)
          SELECT p.workspace_id, p.id, ${input.name}, ${input.description}, ${input.color},
            ${input.targetDate}::date, NULL, NULL,
            (SELECT COALESCE(max(display_order) + 1, 0) FROM public.business_targets
              WHERE workspace_id = ${ws}::uuid AND product_id = ${productId}::uuid), ${actorId}::uuid
          FROM public.products AS p WHERE p.workspace_id = ${ws}::uuid AND p.id = ${productId}::uuid AND p.active
          RETURNING id::text AS id`;
        if (!rows[0]) return { status: "not_found" };
        const value = (await this.listTargets(ws, productId)).find((target) => target.id === text(rows[0]["id"]));
        return value ? { status: "ok", value } : { status: "not_found" };
      } catch (error) { if (duplicate(error)) return { status: "duplicate" }; throw error; }
    },
    async updateTarget(ws, productId, targetId, actorId, input, version, reason, operationId) {
      let rows;
      try {
        rows = await sql`SELECT public.update_business_target(
          ${ws}::uuid, ${productId}::uuid, ${targetId}::uuid, ${actorId}::uuid,
          ${operationId}::uuid, ${input.name}, ${input.description}, ${input.color},
          ${input.targetDate}::date, ${version}::bigint, ${reason}) AS result`;
      } catch (error) { if (duplicate(error)) return { status: "duplicate" }; throw error; }
      const result = text(rows[0]?.["result"]);
      if (result !== "updated") return { status: result as "not_found" | "stale" | "duplicate" };
      const value = (await this.listTargets(ws, productId)).find((target) => target.id === targetId);
      return value ? { status: "ok", value } : { status: "not_found" };
    },
    async deleteTarget(ws, productId, targetId, actorId, version, operationId) {
      const rows = await sql`SELECT public.delete_business_target(
        ${ws}::uuid, ${productId}::uuid, ${targetId}::uuid, ${actorId}::uuid,
        ${operationId}::uuid, ${version}::bigint) AS result`;
      const result = text(rows[0]?.["result"]);
      return result === "deleted" ? { status: "ok", value: { id: targetId } as BusinessTarget }
        : { status: result as "not_found" | "stale" };
    }
  };
}
