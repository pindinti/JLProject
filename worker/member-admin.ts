import { neon } from "@neondatabase/serverless";
import type { WorkspaceRole } from "./authorization";
import type { WorkerEnvironment } from "./database";

export interface WorkspaceSummary {
  id: string;
  name: string;
  role: WorkspaceRole;
}

export interface MemberSummary {
  id: string;
  name: string;
  email: string;
  role: WorkspaceRole;
  active: boolean;
}

export type UpdateResult = "updated" | "denied" | "not_found" | "last_admin" | "invalid";

export interface MemberAdminRepository {
  listOwnWorkspaces(authUserId: string): Promise<WorkspaceSummary[]>;
  listMembers(authUserId: string, workspaceId: string): Promise<MemberSummary[]>;
  updateMember(authUserId: string, workspaceId: string, membershipId: string,
    change: { role: WorkspaceRole } | { active: boolean }): Promise<UpdateResult>;
}

export function createMemberAdminRepository(environment: WorkerEnvironment): MemberAdminRepository {
  if (!environment.DATABASE_URL) throw new Error("Worker database configuration is missing.");
  const sql = neon(environment.DATABASE_URL);

  return {
    async listOwnWorkspaces(authUserId) {
      const rows = await sql`
        SELECT workspace.id::text AS id, workspace.name, membership.role
        FROM public.workspace_memberships AS membership
        JOIN public.workspaces AS workspace ON workspace.id = membership.workspace_id
        WHERE membership.auth_user_id = ${authUserId}::uuid AND membership.active = true
        ORDER BY workspace.name, workspace.id
      `;
      return rows.map((row) => ({
        id: String(row["id"]), name: String(row["name"]), role: row["role"] as WorkspaceRole
      }));
    },
    async listMembers(authUserId, workspaceId) {
      const rows = await sql`
        SELECT membership.id::text AS id, auth_user.name, auth_user.email,
               membership.role, membership.active
        FROM public.workspace_memberships AS membership
        JOIN neon_auth."user" AS auth_user ON auth_user.id = membership.auth_user_id
        WHERE membership.workspace_id = ${workspaceId}::uuid
          AND EXISTS (
            SELECT 1 FROM public.workspace_memberships AS actor
            WHERE actor.workspace_id = ${workspaceId}::uuid
              AND actor.auth_user_id = ${authUserId}::uuid
              AND actor.role = 'admin' AND actor.active = true
          )
        ORDER BY auth_user.name, membership.id
      `;
      return rows.map((row) => ({
        id: String(row["id"]), name: String(row["name"]), email: String(row["email"]),
        role: row["role"] as WorkspaceRole, active: row["active"] === true
      }));
    },
    async updateMember(authUserId, workspaceId, membershipId, change) {
      const role = "role" in change ? change.role : null;
      const active = "active" in change ? change.active : null;
      const rows = await sql`
        SELECT public.update_workspace_membership(
          ${authUserId}::uuid, ${workspaceId}::uuid, ${membershipId}::uuid,
          ${role}::text, ${active}::boolean
        ) AS result
      `;
      return rows[0]?.["result"] as UpdateResult;
    }
  };
}
