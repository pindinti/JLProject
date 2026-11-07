import { neon } from "@neondatabase/serverless";
import type { MembershipRepository, WorkspaceMembership, WorkspaceRole } from "./authorization";
import type { WorkerEnvironment } from "./database";

export function createMembershipRepository(environment: WorkerEnvironment): MembershipRepository {
  if (!environment.DATABASE_URL) {
    throw new Error("Worker database configuration is missing.");
  }

  const sql = neon(environment.DATABASE_URL);

  return {
    async hasAnyActiveMembership(authUserId: string): Promise<boolean> {
      const rows = await sql`
        SELECT 1 AS ok
        FROM public.workspace_memberships AS membership
        INNER JOIN public.workspaces AS workspace ON workspace.id = membership.workspace_id
        WHERE membership.auth_user_id = ${authUserId}::uuid
          AND membership.active = true
        LIMIT 1
      `;
      return rows.length > 0;
    },

    async findMembership(authUserId: string, workspaceId: string): Promise<WorkspaceMembership | null> {
      const rows = await sql`
        SELECT membership.workspace_id::text AS "workspaceId",
               membership.role,
               membership.active
        FROM public.workspace_memberships AS membership
        INNER JOIN public.workspaces AS workspace ON workspace.id = membership.workspace_id
        WHERE membership.auth_user_id = ${authUserId}::uuid
          AND membership.workspace_id = ${workspaceId}::uuid
        LIMIT 1
      `;
      const row = rows[0];
      if (!row) return null;
      return {
        workspaceId: String(row["workspaceId"]),
        role: String(row["role"]) as WorkspaceRole,
        active: row["active"] === true
      };
    }
  };
}
