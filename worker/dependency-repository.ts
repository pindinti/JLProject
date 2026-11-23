import { NeonDbError, neon } from "@neondatabase/serverless";
import type { DependencyPreview, DependencySnapshot, FinishToStartDependency } from "../domain/schedule-dependencies";
import type { WorkerEnvironment } from "./database";

export interface DependencyScope { workspaceId: string; productId: string; actorId: string }

interface DependencyGraph {
  productId: string;
  status: "vigente" | "em_estudo" | "arquivado";
  cursor: { scheduleVersion: string; historyWatermark: string };
  edges: FinishToStartDependency[];
}

type ReadFailure = { status: "forbidden" | "not_found" | "too_large" | "archived" };
type GraphRead = { status: "ok"; graph: DependencyGraph } | ReadFailure;
type SnapshotRead = { status: "ok"; snapshot: DependencySnapshot; fingerprint: string } | ReadFailure;

export interface DependencyConfirmation {
  operationId: string;
  scheduleVersion: string;
  justification: string;
}

export interface DependencyCommit extends DependencyConfirmation {
  fingerprint: string;
  calendarVersion: number;
  dependencyChange: DependencyPreview["dependencyChange"];
  dateChanges: (DependencyPreview["dateChanges"][number] & { expectedVersion: number })[];
}

type WriteFailure = { status: "forbidden" | "not_found" | "stale" | "archived" | "conflict" | "invalid" };
type Applied = { status: "applied" | "replayed"; operationId: string; scheduleVersion: string };
export type DependencyWrite = Applied | WriteFailure;

export interface DependencyRepository {
  readGraph(scope: DependencyScope): Promise<GraphRead>;
  readSnapshot(scope: DependencyScope): Promise<SnapshotRead>;
  readReceipt(scope: DependencyScope, operation: DependencyConfirmation): Promise<DependencyWrite | { status: "missing" }>;
  confirm(scope: DependencyScope, operation: DependencyCommit): Promise<DependencyWrite>;
}

export const dependencyDateChangeLimit = 50;

export function createDependencyRepository(environment: WorkerEnvironment): DependencyRepository {
  if (!environment.DATABASE_URL) throw new Error("Worker database configuration is missing.");
  const sql = neon(environment.DATABASE_URL);
  // The SQL routines are the only database entry points and stay inaccessible to the Worker in 4B.2.
  function read({ workspaceId, productId, actorId }: DependencyScope, graphOnly: boolean) {
    return sql`SELECT public.read_schedule_dependencies(${workspaceId}::uuid, ${productId}::uuid,
      ${actorId}::uuid, ${graphOnly}) AS result`;
  }

  return {
    async readGraph(scope) {
      const [row] = await read(scope, true);
      return row.result as GraphRead;
    },
    async readSnapshot(scope) {
      const [row] = await read(scope, false);
      return row.result as SnapshotRead;
    },
    async readReceipt({ workspaceId, productId, actorId }, operation) {
      const [row] = await sql`SELECT public.read_schedule_dependency_receipt(${workspaceId}::uuid, ${productId}::uuid,
        ${actorId}::uuid, ${operation.operationId}::uuid, ${operation.scheduleVersion}::bigint,
        ${operation.justification}) AS result`;
      return row.result as DependencyWrite | { status: "missing" };
    },
    async confirm({ workspaceId, productId, actorId }, operation) {
      try {
        const [row] = await sql`SELECT public.confirm_schedule_dependencies(${workspaceId}::uuid, ${productId}::uuid,
          ${actorId}::uuid, ${operation.operationId}::uuid, ${operation.scheduleVersion}::bigint,
          ${operation.calendarVersion}::bigint, ${operation.fingerprint}, ${operation.justification},
          ${JSON.stringify(operation.dateChanges)}::jsonb, ${JSON.stringify(operation.dependencyChange)}::jsonb) AS result`;
        return row.result as DependencyWrite;
      } catch (error) {
        if (error instanceof NeonDbError && (error.code === "40001" || error.code === "40P01")) return { status: "stale" };
        throw error;
      }
    }
  };
}
