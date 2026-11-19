import { neon } from "@neondatabase/serverless";
import { rootActivityDefaultColor } from "../domain/schedule-workspace";
import type { WorkerEnvironment } from "./database";

export interface ExecutiveInterval { start: string | null; end: string | null }
export interface ExecutiveActivity {
  id: string; productId: string; disciplineId: string | null; stageId: string | null;
  name: string; activityType: string | null; displayOrder: number;
  plannedStart: string | null; plannedEnd: string | null;
  colorOverride: string | null; color: string;
}
export interface ExecutiveStage extends ExecutiveInterval {
  id: string; productId: string; disciplineId: string; code: string;
  displayName: string; color: string; displayOrder: number;
  plannedStart: string | null; plannedEnd: string | null;
  dateSource: "planned" | "derived";
  derivedStart: string | null; derivedEnd: string | null;
  activities: ExecutiveActivity[];
}
export interface ExecutiveDiscipline extends ExecutiveInterval {
  id: string; productId: string; name: string; shortCode: string;
  color: string; displayOrder: number; stages: ExecutiveStage[];
}
export interface ExecutiveTarget {
  id: string; productId: string; name: string; description: string | null;
  color: string; displayOrder: number;
  targetDate: string; operationalDate: string | null;
}
export interface ExecutiveProduct extends ExecutiveInterval {
  id: string; name: string; active: boolean;
  rootActivities: ExecutiveActivity[]; disciplines: ExecutiveDiscipline[]; targets: ExecutiveTarget[];
}
export interface ExecutiveGanttRepository {
  read(workspaceId: string): Promise<ExecutiveProduct[]>;
}

type Row = Record<string, unknown>;
export interface ExecutiveRows {
  products: Row[]; disciplines: Row[]; stages: Row[]; activities: Row[]; targets: Row[];
}
const value = (row: Row, key: string): string => String(row[key]);
const optional = (row: Row, key: string): string | null => row[key] == null ? null : String(row[key]);
const number = (row: Row, key: string): number => Number(row[key]);
const compareText = (left: string, right: string): number => left < right ? -1 : left > right ? 1 : 0;
const byOrder = (left: { displayOrder: number; id: string }, right: { displayOrder: number; id: string }) =>
  left.displayOrder - right.displayOrder || compareText(left.id, right.id);

function include(interval: ExecutiveInterval, activity: ExecutiveActivity): void {
  if (activity.plannedStart && (!interval.start || activity.plannedStart < interval.start))
    interval.start = activity.plannedStart;
  if (activity.plannedEnd && (!interval.end || activity.plannedEnd > interval.end))
    interval.end = activity.plannedEnd;
}

function includeBounds(interval: ExecutiveInterval, start: string | null, end: string | null): void {
  if (start && (!interval.start || start < interval.start)) interval.start = start;
  if (end && (!interval.end || end > interval.end)) interval.end = end;
}

export function assembleExecutiveGantt(rows: ExecutiveRows): ExecutiveProduct[] {
  const products = new Map<string, ExecutiveProduct>();
  const disciplines = new Map<string, ExecutiveDiscipline>();
  const stages = new Map<string, ExecutiveStage>();
  for (const row of rows.products) {
    const product: ExecutiveProduct = { id: value(row, "id"), name: value(row, "name"),
      active: row["active"] === true, start: null, end: null,
      rootActivities: [], disciplines: [], targets: [] };
    products.set(product.id, product);
  }
  for (const row of rows.disciplines) {
    const product = products.get(value(row, "productId"));
    if (!product) continue;
    const discipline: ExecutiveDiscipline = { id: value(row, "id"), productId: product.id,
      name: value(row, "name"), shortCode: value(row, "shortCode"), color: value(row, "color"),
      displayOrder: number(row, "displayOrder"), start: null, end: null, stages: [] };
    disciplines.set(discipline.id, discipline);
    product.disciplines.push(discipline);
  }
  for (const row of rows.stages) {
    const discipline = disciplines.get(value(row, "disciplineId"));
    if (!discipline || discipline.productId !== value(row, "productId")) continue;
    const stage: ExecutiveStage = { id: value(row, "id"), productId: discipline.productId,
      disciplineId: discipline.id, code: value(row, "code"), displayName: value(row, "displayName"),
      color: value(row, "color"), displayOrder: number(row, "displayOrder"),
      plannedStart: optional(row, "plannedStart"), plannedEnd: optional(row, "plannedEnd"),
      dateSource: row["plannedStart"] != null || row["plannedEnd"] != null ? "planned" : "derived",
      derivedStart: null, derivedEnd: null, start: null, end: null, activities: [] };
    stages.set(stage.id, stage);
    discipline.stages.push(stage);
  }
  for (const row of rows.activities) {
    const product = products.get(value(row, "productId"));
    if (!product) continue;
    const disciplineId = optional(row, "disciplineId");
    const stageId = optional(row, "stageId");
    const stage = stageId ? stages.get(stageId) : null;
    if (stageId ? !stage || stage.productId !== product.id || stage.disciplineId !== disciplineId
      : disciplineId !== null) continue;
    const colorOverride = optional(row, "colorOverride");
    const activity: ExecutiveActivity = { id: value(row, "id"), productId: product.id,
      disciplineId, stageId, name: value(row, "name"), activityType: optional(row, "activityType"),
      displayOrder: number(row, "displayOrder"), plannedStart: optional(row, "plannedStart"),
      plannedEnd: optional(row, "plannedEnd"), colorOverride,
      color: colorOverride ?? stage?.color ?? rootActivityDefaultColor };
    if (stage) {
      stage.activities.push(activity);
      const derived = { start: stage.derivedStart, end: stage.derivedEnd };
      include(derived, activity);
      stage.derivedStart = derived.start;
      stage.derivedEnd = derived.end;
      const discipline = disciplines.get(stage.disciplineId)!;
      include(discipline, activity);
    } else product.rootActivities.push(activity);
    include(product, activity);
  }
  for (const stage of stages.values()) {
    stage.start = stage.dateSource === "planned" ? stage.plannedStart : stage.derivedStart;
    stage.end = stage.dateSource === "planned" ? stage.plannedEnd : stage.derivedEnd;
    const discipline = disciplines.get(stage.disciplineId);
    const product = products.get(stage.productId);
    if (discipline) includeBounds(discipline, stage.start, stage.end);
    if (product) includeBounds(product, stage.start, stage.end);
  }
  for (const row of rows.targets) {
    const product = products.get(value(row, "productId"));
    if (!product) continue;
    product.targets.push({ id: value(row, "id"), productId: product.id, name: value(row, "name"),
      description: optional(row, "description"),
      color: value(row, "color"), displayOrder: number(row, "displayOrder"),
      targetDate: value(row, "targetDate"), operationalDate: optional(row, "operationalDate") });
  }
  for (const product of products.values()) {
    product.rootActivities.sort(byOrder);
    product.disciplines.sort(byOrder);
    product.targets.sort(byOrder);
    for (const discipline of product.disciplines) {
      discipline.stages.sort(byOrder);
      for (const stage of discipline.stages) stage.activities.sort(byOrder);
    }
  }
  return [...products.values()].sort((left, right) =>
    Number(right.active) - Number(left.active) || compareText(left.name, right.name) || compareText(left.id, right.id));
}

export function createExecutiveGanttRepository(environment: WorkerEnvironment): ExecutiveGanttRepository {
  if (!environment.DATABASE_URL) throw new Error("Worker database configuration is missing.");
  const sql = neon(environment.DATABASE_URL);
  return {
    async read(workspaceId) {
      const [products, disciplines, stages, activities, targets] = await sql.transaction([
        sql`SELECT id::text AS id, name, active FROM public.products
          WHERE workspace_id = ${workspaceId}::uuid AND active = true
            AND planning_classification = 'vigente' ORDER BY name, id`,
        sql`SELECT id::text AS id, product_id::text AS "productId", name,
          short_code AS "shortCode", color, display_order AS "displayOrder"
          FROM public.product_disciplines WHERE workspace_id = ${workspaceId}::uuid
          AND deleted_at IS NULL AND product_id IN (SELECT id FROM public.products
            WHERE workspace_id = ${workspaceId}::uuid AND active AND planning_classification = 'vigente')
          ORDER BY product_id, display_order, id`,
        sql`SELECT s.id::text AS id, s.product_id::text AS "productId",
          s.discipline_id::text AS "disciplineId", d.code, d.color,
          s.display_name AS "displayName", s.display_order AS "displayOrder",
          to_char(s.planned_start, 'YYYY-MM-DD') AS "plannedStart",
          to_char(s.planned_end, 'YYYY-MM-DD') AS "plannedEnd"
          FROM public.discipline_stages AS s
          JOIN public.product_disciplines AS pd ON pd.id = s.discipline_id
            AND pd.workspace_id = s.workspace_id AND pd.product_id = s.product_id AND pd.deleted_at IS NULL
          JOIN public.stage_definitions AS d ON d.id = s.definition_id AND d.workspace_id = s.workspace_id
          WHERE s.workspace_id = ${workspaceId}::uuid AND s.deleted_at IS NULL
            AND s.product_id IN (SELECT id FROM public.products WHERE workspace_id = ${workspaceId}::uuid
              AND active AND planning_classification = 'vigente')
          ORDER BY s.product_id, s.discipline_id, s.display_order, s.id`,
        sql`SELECT a.id::text AS id, a.product_id::text AS "productId",
          a.discipline_id::text AS "disciplineId", a.stage_id::text AS "stageId",
          a.name, a.activity_type AS "activityType",
          to_char(a.planned_start, 'YYYY-MM-DD') AS "plannedStart",
          to_char(a.planned_end, 'YYYY-MM-DD') AS "plannedEnd",
          a.color_override AS "colorOverride", a.display_order AS "displayOrder"
          FROM public.stage_activities AS a
          LEFT JOIN public.discipline_stages AS s ON s.id = a.stage_id
            AND s.workspace_id = a.workspace_id AND s.product_id = a.product_id AND s.deleted_at IS NULL
          LEFT JOIN public.product_disciplines AS d ON d.id = a.discipline_id
            AND d.workspace_id = a.workspace_id AND d.product_id = a.product_id AND d.deleted_at IS NULL
          WHERE a.workspace_id = ${workspaceId}::uuid AND a.deleted_at IS NULL
            AND a.product_id IN (SELECT id FROM public.products WHERE workspace_id = ${workspaceId}::uuid
              AND active AND planning_classification = 'vigente')
            AND ((a.stage_id IS NULL AND a.discipline_id IS NULL)
              OR (s.id IS NOT NULL AND d.id IS NOT NULL AND s.discipline_id = d.id))
          ORDER BY a.product_id, a.discipline_id NULLS FIRST, a.stage_id NULLS FIRST,
            a.display_order, a.id`,
        sql`SELECT id::text AS id, product_id::text AS "productId", name, description, color,
          display_order AS "displayOrder", to_char(target_date, 'YYYY-MM-DD') AS "targetDate",
          to_char(operational_date, 'YYYY-MM-DD') AS "operationalDate"
          FROM public.business_targets WHERE workspace_id = ${workspaceId}::uuid
            AND deleted_at IS NULL AND product_id IN (SELECT id FROM public.products
              WHERE workspace_id = ${workspaceId}::uuid AND active AND planning_classification = 'vigente')
          ORDER BY product_id, display_order, id`
      ], { isolationLevel: "RepeatableRead", readOnly: true });
      return assembleExecutiveGantt({ products, disciplines, stages, activities, targets });
    }
  };
}
