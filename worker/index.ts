import {
  type WorkerEnvironment,
  verifyDatabaseConnectivity
} from "./database";
import { verifyIdentity, type Identity } from "./auth";
import { authorizeWorkspace, type MembershipRepository } from "./authorization";
import { createMembershipRepository } from "./membership-repository";
import { createMemberAdminRepository, type MemberAdminRepository } from "./member-admin";
import { provisionDevelopmentAuthUser, type ProvisionResult } from "./neon-auth-users";
import type { WorkspaceRole } from "./authorization";
import { handleProductRequest, isProductRoute, type ProductRepositoryFactory } from "./product-api";
import { createProductRepository } from "./products";
import { handleScheduleRequest, isScheduleRoute, type ScheduleRepositoryFactory } from "./schedule-api";
import { createScheduleRepository } from "./schedule-repository";
import { handleImportRequest, isImportRoute, type ImportRepositoryFactory } from "./import-api";
import { createImportRepository } from "./import-repository";

const healthPath = "/api/health";
const databaseConnectivityPath = "/api/internal/database-connectivity";
const sessionPath = "/api/auth/session";
const workspaceMembershipPath = /^\/api\/workspaces\/([0-9a-f-]{36})\/membership$/i;
const workspacesPath = "/api/workspaces";
const membersPath = /^\/api\/workspaces\/([0-9a-f-]{36})\/memberships$/i;
const memberPath = /^\/api\/workspaces\/([0-9a-f-]{36})\/memberships\/([0-9a-f-]{36})$/i;
const stageCatalogPath = /^\/api\/workspaces\/([^/]+)\/stage-definitions$/;
const stageDefinitionColorPath = /^\/api\/workspaces\/([^/]+)\/stage-definitions\/([^/]+)$/i;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const hexColorPattern = /^#[0-9a-f]{6}$/i;

type IdentityVerifier = (request: Request, environment: WorkerEnvironment) => Promise<Identity | null>;
type MembershipRepositoryFactory = (environment: WorkerEnvironment) => MembershipRepository;
type MemberAdminRepositoryFactory = (environment: WorkerEnvironment) => MemberAdminRepository;
type AuthUserProvisioner = (email: string, environment: WorkerEnvironment) => Promise<ProvisionResult>;

function privateResponse(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store" }
  });
}

async function parseMembershipChange(request: Request): Promise<{ role: WorkspaceRole } | { active: boolean } | null> {
  if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) return null;
  const body = await request.text();
  if (body.length > 512) return null;
  let value: unknown;
  try { value = JSON.parse(body); } catch { return null; }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const fields = Object.keys(value);
  if (fields.length !== 1) return null;
  if (fields[0] === "role" && ["admin", "editor", "viewer"].includes((value as { role?: string }).role ?? "")) {
    return { role: (value as { role: WorkspaceRole }).role };
  }
  if (fields[0] === "active" && typeof (value as { active?: unknown }).active === "boolean") {
    return { active: (value as { active: boolean }).active };
  }
  return null;
}

async function parseNewMember(request: Request): Promise<{ email: string; role: WorkspaceRole } | null> {
  if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) return null;
  const text = await request.text();
  if (text.length > 512) return null;
  let value: unknown;
  try { value = JSON.parse(text); } catch { return null; }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const fields = Object.keys(value);
  if (fields.some((field) => field !== "email" && field !== "role") || !fields.includes("email")) return null;
  const input = value as { email?: unknown; role?: unknown };
  if (typeof input.email !== "string") return null;
  const email = input.email.trim().toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  const role = input.role ?? "editor";
  if (role !== "admin" && role !== "editor" && role !== "viewer") return null;
  return { email, role };
}

async function parseStageDefinitionColor(request: Request): Promise<{ color: string; expectedColor: string } | null> {
  if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) return null;
  const text = await request.text();
  if (text.length > 512) return null;
  let value: unknown;
  try { value = JSON.parse(text); } catch { return null; }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  if (Object.keys(body).length !== 2 || Object.keys(body).some((key) => key !== "color" && key !== "expectedColor") ||
      typeof body["color"] !== "string" || !hexColorPattern.test(body["color"]) ||
      typeof body["expectedColor"] !== "string" || !hexColorPattern.test(body["expectedColor"])) return null;
  return { color: body["color"].toUpperCase(), expectedColor: body["expectedColor"].toUpperCase() };
}

export async function handleRequest(
  request: Request,
  environment: WorkerEnvironment = {},
  identityVerifier: IdentityVerifier = verifyIdentity,
  membershipRepositoryFactory: MembershipRepositoryFactory = createMembershipRepository,
  memberAdminRepositoryFactory: MemberAdminRepositoryFactory = createMemberAdminRepository,
  productRepositoryFactory: ProductRepositoryFactory = createProductRepository,
  scheduleRepositoryFactory: ScheduleRepositoryFactory = createScheduleRepository,
  importRepositoryFactory: ImportRepositoryFactory = createImportRepository,
  authUserProvisioner: AuthUserProvisioner = provisionDevelopmentAuthUser
): Promise<Response> {
  const url = new URL(request.url);

  if (request.method === "GET" && url.pathname === healthPath) {
    return Response.json(
      { status: "ok" },
      {
        headers: {
          "Cache-Control": "no-store"
        }
      }
    );
  }

  const workspaceMatch = url.pathname.match(workspaceMembershipPath);
  const membersMatch = url.pathname.match(membersPath);
  const memberMatch = url.pathname.match(memberPath);
  const productRoute = isProductRoute(url.pathname);
  const scheduleRoute = isScheduleRoute(url.pathname);
  const importRoute = isImportRoute(url.pathname);
  const stageCatalogMatch = url.pathname.match(stageCatalogPath);
  const stageDefinitionColorMatch = url.pathname.match(stageDefinitionColorPath);
  const protectedRoute = request.method === "GET" &&
    (url.pathname === sessionPath || url.pathname === workspacesPath || workspaceMatch || membersMatch) ||
    request.method === "POST" && !!membersMatch ||
    request.method === "PATCH" && (!!memberMatch || !!stageDefinitionColorMatch) ||
    productRoute || scheduleRoute || importRoute || !!stageCatalogMatch || !!stageDefinitionColorMatch;
  if (protectedRoute) {
    const origin = request.headers.get("Origin");
    if (origin && origin !== url.origin) {
      return privateResponse({ error: "Origem não permitida." }, 403);
    }
    if (!environment.NEON_AUTH_BASE_URL) {
      return privateResponse({ error: "Serviço indisponível." }, 503);
    }

    let identity: Identity | null;
    try {
      identity = await identityVerifier(request, environment);
    } catch {
      return privateResponse({ error: "Serviço indisponível." }, 503);
    }
    if (!identity) {
      return privateResponse({ error: "Sessão inválida ou expirada." }, 401);
    }

    try {
      const repository = membershipRepositoryFactory(environment);
      if (url.pathname === sessionPath) {
        if (!(await repository.hasAnyActiveMembership(identity.subject))) {
          return privateResponse({ error: "Acesso pendente." }, 403);
        }
        return privateResponse({ status: "authorized" }, 200);
      }

      if (url.pathname === workspacesPath) {
        if (!(await repository.hasAnyActiveMembership(identity.subject))) {
          return privateResponse({ error: "Acesso não autorizado." }, 403);
        }
        const workspaces = await memberAdminRepositoryFactory(environment).listOwnWorkspaces(identity.subject);
        return privateResponse({ workspaces }, 200);
      }

      if (productRoute) {
        return await handleProductRequest(request, identity, repository, environment, productRepositoryFactory);
      }

      if (importRoute) {
        return await handleImportRequest(request, identity, repository, environment, importRepositoryFactory);
      }

      if (stageDefinitionColorMatch) {
        const [, workspaceId, definitionId] = stageDefinitionColorMatch;
        if (!uuidPattern.test(workspaceId) || !uuidPattern.test(definitionId))
          return privateResponse({ error: "Identificador inválido." }, 400);
        if (request.method !== "PATCH") return privateResponse({ error: "Método não permitido." }, 405);
        const membership = await authorizeWorkspace(identity, workspaceId, "edit", repository);
        if (!membership) return privateResponse({ error: "Acesso não autorizado." }, 403);
        const input = await parseStageDefinitionColor(request);
        if (!input) return privateResponse({ error: "Cor inválida." }, 400);
        const result = await scheduleRepositoryFactory(environment).updateStageDefinitionColor(
          membership.workspaceId, definitionId.toLowerCase(), input.expectedColor, input.color);
        if (result.status === "not_found") return privateResponse({ error: "Definição de etapa não encontrada." }, 404);
        if (result.status === "stale") return privateResponse({ error: "A cor foi alterada. Atualize os dados e tente novamente." }, 409);
        return privateResponse({ stageDefinition: result.value }, 200);
      }

      if (stageCatalogMatch) {
        if (!uuidPattern.test(stageCatalogMatch[1])) return privateResponse({ error: "Identificador inválido." }, 400);
        const membership = await authorizeWorkspace(identity, stageCatalogMatch[1], "read", repository);
        if (!membership) return privateResponse({ error: "Acesso não autorizado." }, 403);
        if (request.method !== "GET") return privateResponse({ error: "Método não permitido." }, 405);
        const stageDefinitions = await scheduleRepositoryFactory(environment).listStageDefinitions(membership.workspaceId);
        return privateResponse({ stageDefinitions }, 200);
      }

      if (scheduleRoute) {
        return await handleScheduleRequest(request, identity, repository, environment, scheduleRepositoryFactory);
      }

      if (membersMatch || memberMatch) {
        const workspaceId = (membersMatch ?? memberMatch)![1];
        if (!uuidPattern.test(workspaceId) || (memberMatch && !uuidPattern.test(memberMatch[2]))) {
          return privateResponse({ error: "Dados inválidos." }, 400);
        }
        const membership = await authorizeWorkspace(identity, workspaceId, "manage", repository);
        if (!membership) return privateResponse({ error: "Acesso não autorizado." }, 403);
        const adminRepository = memberAdminRepositoryFactory(environment);
        if (request.method === "GET") {
          const memberships = await adminRepository.listMembers(identity.subject, membership.workspaceId);
          return privateResponse({ memberships }, 200);
        }
        if (request.method === "POST" && membersMatch) {
          const input = await parseNewMember(request);
          if (!input) return privateResponse({ error: "E-mail ou perfil inválido." }, 400);
          let userId = await adminRepository.findAuthUserIdByEmail(input.email);
          if (!userId) {
            const provision = await authUserProvisioner(input.email, environment);
            if (provision.kind === "created") userId = provision.userId;
            else if (provision.kind === "conflict") userId = await adminRepository.findAuthUserIdByEmail(input.email);
            else return privateResponse({ error: "Não foi possível adicionar o usuário. Tente novamente." }, 503);
          }
          if (!userId) return privateResponse({ error: "Não foi possível adicionar o usuário. Tente novamente." }, 503);
          const result = await adminRepository.addMember(identity.subject, membership.workspaceId, userId, input.role);
          if (result === "denied") return privateResponse({ error: "Acesso não autorizado." }, 403);
          if (result === "duplicate") return privateResponse({ error: "Este usuário já pertence ao espaço de trabalho." }, 409);
          if (result !== "added") return privateResponse({ error: "Não foi possível adicionar o usuário. Tente novamente." }, 503);
          return privateResponse({ status: "created" }, 201);
        }
        const change = await parseMembershipChange(request);
        if (!change) return privateResponse({ error: "Dados inválidos." }, 400);
        const result = await adminRepository.updateMember(
          identity.subject, membership.workspaceId, memberMatch![2].toLowerCase(), change
        );
        if (result === "denied") return privateResponse({ error: "Acesso não autorizado." }, 403);
        if (result === "not_found") return privateResponse({ error: "Não encontrado." }, 404);
        if (result === "last_admin") return privateResponse({ error: "É necessário manter um administrador ativo." }, 409);
        if (result !== "updated") return privateResponse({ error: "Dados inválidos." }, 400);
        return privateResponse({ status: "updated" }, 200);
      }

      const membership = await authorizeWorkspace(identity, workspaceMatch![1], "read", repository);
      if (!membership) {
        return privateResponse({ error: "Acesso não autorizado." }, 403);
      }
      return privateResponse({ workspaceId: membership.workspaceId, role: membership.role }, 200);
    } catch {
      return privateResponse({ error: "Serviço indisponível." }, 503);
    }
  }

  if (
    request.method === "GET" &&
    url.pathname === databaseConnectivityPath &&
    environment.JLPROJECT_ENV === "development"
  ) {
    try {
      const isConnected = await verifyDatabaseConnectivity(environment);

      return Response.json(
        { status: isConnected ? "ok" : "unavailable" },
        {
          status: isConnected ? 200 : 503,
          headers: {
            "Cache-Control": "no-store"
          }
        }
      );
    } catch {
      return Response.json(
        { status: "unavailable" },
        {
          status: 503,
          headers: {
            "Cache-Control": "no-store"
          }
        }
      );
    }
  }

  return Response.json({ error: "Não encontrado" }, { status: 404 });
}

export default {
  fetch(request: Request, environment: WorkerEnvironment): Promise<Response> {
    return handleRequest(request, environment);
  }
};
