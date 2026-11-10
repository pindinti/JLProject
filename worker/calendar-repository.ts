import { neon } from "@neondatabase/serverless";
import type { CalendarException, CalendarExceptionInput, CalendarHistoryEntry } from "../domain/working-calendar";
import type { WorkerEnvironment } from "./database";

export type CalendarMutationStatus = "created" | "updated" | "removed" | "unchanged" |
  "stale" | "duplicate" | "not_found" | "denied" | "invalid";

export interface CalendarMutation {
  status: CalendarMutationStatus;
  version?: number;
}

export interface CalendarRepository {
  read(workspaceId: string, year: number): Promise<{ version: number; exceptions: CalendarException[] }>;
  readForCalculation(workspaceId: string): Promise<{ version: number; exceptions: CalendarException[] }>;
  history(workspaceId: string, beforeVersion: number | null):
    Promise<{ entries: CalendarHistoryEntry[]; nextBeforeVersion: number | null }>;
  change(workspaceId: string, actorId: string, operationId: string, expectedVersion: number,
    action: "create" | "update" | "remove", exceptionId: string | null,
    input: CalendarExceptionInput | null): Promise<CalendarMutation>;
}

function mapException(row: Record<string, unknown>): CalendarException {
  return {
    id: String(row["id"]), kind: row["kind"] as CalendarException["kind"],
    name: row["name"] === null ? null : String(row["name"]),
    municipality: row["municipality"] === null ? null : String(row["municipality"]),
    description: row["description"] === null ? null : String(row["description"]),
    startDate: String(row["start_date"]), endDate: String(row["end_date"]),
    version: Number(row["version"])
  };
}

function mapEventState(value: unknown): CalendarException | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? mapException(value as Record<string, unknown>) : null;
}

export function createCalendarRepository(environment: WorkerEnvironment): CalendarRepository {
  if (!environment.DATABASE_URL) throw new Error("Worker database configuration is missing.");
  const sql = neon(environment.DATABASE_URL);
  return {
    async read(workspaceId, year) {
      const start = `${year}-01-01`;
      const end = `${year}-12-31`;
      const rows = await sql`SELECT
          COALESCE((SELECT version FROM public.workspace_calendar_versions
            WHERE workspace_id = ${workspaceId}::uuid), 0) AS calendar_version,
          COALESCE((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.start_date, item.end_date, item.id)
            FROM public.workspace_calendar_exceptions AS item
            WHERE item.workspace_id = ${workspaceId}::uuid AND item.removed_at IS NULL
              AND item.start_date <= ${end}::date AND item.end_date >= ${start}::date),
            '[]'::jsonb) AS exceptions`;
      const exceptions = rows[0]?.["exceptions"];
      return { version: Number(rows[0]?.["calendar_version"] ?? 0),
        exceptions: Array.isArray(exceptions) ? exceptions.map((item) => mapException(item)) : [] };
    },
    async readForCalculation(workspaceId) {
      const rows = await sql`SELECT
          COALESCE((SELECT version FROM public.workspace_calendar_versions
            WHERE workspace_id = ${workspaceId}::uuid), 0) AS calendar_version,
          COALESCE((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.start_date, item.end_date, item.id)
            FROM public.workspace_calendar_exceptions AS item
            WHERE item.workspace_id = ${workspaceId}::uuid AND item.removed_at IS NULL),
            '[]'::jsonb) AS exceptions`;
      const exceptions = rows[0]?.["exceptions"];
      return { version: Number(rows[0]?.["calendar_version"] ?? 0),
        exceptions: Array.isArray(exceptions) ? exceptions.map((item) => mapException(item)) : [] };
    },
    async history(workspaceId, beforeVersion) {
      const rows = await sql`SELECT event.operation_id::text AS operation_id,
          event.calendar_version, event.action, event.before_state, event.after_state,
          event.changed_at, NULLIF(auth_user.name, '') AS actor_name
        FROM public.workspace_calendar_events AS event
        JOIN public.workspace_memberships AS member
          ON member.workspace_id = event.workspace_id AND member.auth_user_id = event.actor_id
        LEFT JOIN neon_auth."user" AS auth_user ON auth_user.id = member.auth_user_id
        WHERE event.workspace_id = ${workspaceId}::uuid
          AND (${beforeVersion}::bigint IS NULL OR event.calendar_version < ${beforeVersion}::bigint)
        ORDER BY event.calendar_version DESC LIMIT 51`;
      const entries = rows.slice(0, 50).map((row): CalendarHistoryEntry => {
        const after = mapEventState(row["after_state"]);
        if (!after) throw new Error("Invalid calendar history row.");
        return {
          operationId: String(row["operation_id"]), version: Number(row["calendar_version"]),
          action: row["action"] as CalendarHistoryEntry["action"],
          actorName: row["actor_name"] === null ? null : String(row["actor_name"]),
          changedAt: new Date(String(row["changed_at"])).toISOString(),
          before: mapEventState(row["before_state"]), after
        };
      });
      return { entries, nextBeforeVersion: rows.length > 50 ? entries[entries.length - 1].version : null };
    },
    async change(workspaceId, actorId, operationId, expectedVersion, action, exceptionId, input) {
      const rows = await sql`SELECT public.change_workspace_calendar(
        ${workspaceId}::uuid, ${actorId}::uuid, ${operationId}::uuid, ${expectedVersion}::bigint,
        ${action}, ${exceptionId}::uuid, ${input?.kind ?? null}, ${input?.name ?? null},
        ${input?.municipality ?? null}, ${input?.description ?? null},
        ${input?.startDate ?? null}::date, ${input?.endDate ?? null}::date
      ) AS result`;
      const result = rows[0]?.["result"] as Record<string, unknown> | undefined;
      const status = result?.["status"];
      if (status !== "created" && status !== "updated" && status !== "removed" &&
          status !== "unchanged" && status !== "stale" && status !== "duplicate" &&
          status !== "not_found" && status !== "denied" && status !== "invalid") {
        throw new Error("Unexpected calendar mutation result.");
      }
      const version = result?.["version"];
      return { status, ...(version === undefined ? {} : { version: Number(version) }) };
    }
  };
}
