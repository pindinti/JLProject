import type { Identity } from "./auth";

export type WorkspaceRole = "admin" | "editor" | "viewer";
export type WorkspacePermission = "read" | "edit" | "manage";

export interface WorkspaceMembership {
  workspaceId: string;
  role: WorkspaceRole;
  active: boolean;
}

export interface MembershipRepository {
  hasAnyActiveMembership(authUserId: string): Promise<boolean>;
  findMembership(authUserId: string, workspaceId: string): Promise<WorkspaceMembership | null>;
}

export interface ResourceWorkspaceResolver {
  findWorkspaceId(resourceId: string): Promise<string | null>;
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function hasPermission(role: string, permission: WorkspacePermission): boolean {
  if (role === "admin") return true;
  if (role === "editor") return permission === "read" || permission === "edit";
  if (role === "viewer") return permission === "read";
  return false;
}

export async function authorizeWorkspace(
  identity: Identity,
  workspaceId: string,
  permission: WorkspacePermission,
  repository: MembershipRepository
): Promise<WorkspaceMembership | null> {
  if (!uuidPattern.test(identity.subject) || !uuidPattern.test(workspaceId)) return null;
  const normalizedWorkspaceId = workspaceId.toLowerCase();
  const membership = await repository.findMembership(identity.subject, normalizedWorkspaceId);
  if (
    !membership ||
    membership.workspaceId !== normalizedWorkspaceId ||
    !membership.active ||
    !hasPermission(membership.role, permission)
  ) return null;
  return membership;
}

export async function authorizeResource(
  identity: Identity,
  workspaceId: string,
  resourceId: string,
  permission: WorkspacePermission,
  repository: MembershipRepository,
  resolver: ResourceWorkspaceResolver
): Promise<WorkspaceMembership | null> {
  if (!uuidPattern.test(workspaceId) || !uuidPattern.test(resourceId)) return null;
  const membership = await authorizeWorkspace(identity, workspaceId, permission, repository);
  if (!membership) return null;
  const ownerWorkspaceId = await resolver.findWorkspaceId(resourceId);
  if (ownerWorkspaceId !== membership.workspaceId) return null;
  return membership;
}
