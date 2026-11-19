import { neon } from "@neondatabase/serverless";
import type { WorkerEnvironment } from "./database";
import { mapProduct, type Product } from "./products";
import {
  assembleHierarchy, mapBusinessTarget, queryHierarchyRows, queryRootActivityRows, queryTargetRows,
  type BusinessTarget, type ScheduleHierarchy
} from "./schedule-repository";

export const comparisonEntityLimit = 2000;

export interface ComparisonSchedule {
  product: Product;
  cursor: { scheduleVersion: string; historyWatermark: string };
  hierarchy: ScheduleHierarchy;
  targets: BusinessTarget[];
}

export interface ProductComparison {
  left: ComparisonSchedule;
  right: ComparisonSchedule;
}

type ComparisonResult = { status: "ok"; comparison: ProductComparison } |
  { status: "not_found" | "too_large" };

export async function readProductComparison(environment: WorkerEnvironment, workspaceId: string,
  actorId: string, leftId: string, rightId: string): Promise<ComparisonResult> {
  if (!environment.DATABASE_URL) throw new Error("Worker database configuration is missing.");
  const sql = neon(environment.DATABASE_URL);
  const rowLimit = comparisonEntityLimit + 1;
  const [products, leftRows, leftRoots, leftTargets, rightRows, rightRoots, rightTargets] = await sql.transaction([
    sql`SELECT p.id::text AS id, p.workspace_id::text AS "workspaceId", p.name, p.description,
      p.active, p.planning_classification AS "planningClassification", p.version,
      p.created_at AS "createdAt", p.updated_at AS "updatedAt",
      schedule_cursor.schedule_version::text AS "scheduleVersion",
      schedule_cursor.history_watermark::text AS "historyWatermark"
      FROM public.products AS p
      CROSS JOIN LATERAL public.read_product_schedule_cursor(p.workspace_id, p.id, ${actorId}::uuid) AS schedule_cursor
      WHERE p.workspace_id = ${workspaceId}::uuid AND p.id IN (${leftId}::uuid, ${rightId}::uuid)`,
    queryHierarchyRows(sql, workspaceId, leftId, rowLimit),
    queryRootActivityRows(sql, workspaceId, leftId, rowLimit),
    queryTargetRows(sql, workspaceId, leftId, rowLimit),
    queryHierarchyRows(sql, workspaceId, rightId, rowLimit),
    queryRootActivityRows(sql, workspaceId, rightId, rowLimit),
    queryTargetRows(sql, workspaceId, rightId, rowLimit)
  ], { isolationLevel: "RepeatableRead", readOnly: true });

  const leftProduct = products.find((row) => row["id"] === leftId && row["workspaceId"] === workspaceId);
  const rightProduct = products.find((row) => row["id"] === rightId && row["workspaceId"] === workspaceId);
  if (!leftProduct || !rightProduct) return { status: "not_found" };
  // Each hierarchy row represents a distinct leaf, except for the empty-product sentinel.
  if ([leftRows, leftRoots, leftTargets, rightRows, rightRoots, rightTargets].some((rows) => rows.length >= rowLimit))
    return { status: "too_large" };

  const left = assembleHierarchy(leftId, leftRows, leftRoots);
  const right = assembleHierarchy(rightId, rightRows, rightRoots);
  if (!left || !right) throw new Error("Inconsistent product comparison snapshot.");
  const count = (hierarchy: ScheduleHierarchy) => hierarchy.rootActivities.length +
    hierarchy.disciplines.reduce((total, discipline) => total + 1 +
      discipline.stages.reduce((subtotal, stage) => subtotal + 1 + stage.activities.length, 0), 0);
  if (count(left) + count(right) + leftTargets.length + rightTargets.length > comparisonEntityLimit)
    return { status: "too_large" };

  const schedule = (row: Record<string, unknown>, hierarchy: ScheduleHierarchy,
    targetRows: Record<string, unknown>[]): ComparisonSchedule => {
    const { scheduleVersion, historyWatermark } = row;
    if (typeof scheduleVersion !== "string" || typeof historyWatermark !== "string")
      throw new Error("Invalid schedule cursor.");
    return { product: mapProduct(row), cursor: { scheduleVersion, historyWatermark },
      hierarchy, targets: targetRows.map(mapBusinessTarget) };
  };
  return { status: "ok", comparison: {
    left: schedule(leftProduct, left, leftTargets), right: schedule(rightProduct, right, rightTargets)
  } };
}
