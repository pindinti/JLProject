import { authorizeWorkspace, type MembershipRepository } from "./authorization";
import type { Identity } from "./auth";
import type { WorkerEnvironment } from "./database";
import { createScheduleRepository, type ActivityInput, type ActivityMetadataInput,
  type DisciplineInput, type Mutation, type ScheduleRepository, type StageInput } from "./schedule-repository";

const prefix = /^\/api\/workspaces\/([^/]+)\/products\/([^/]+)\/(hierarchy|targets|disciplines)(?:\/(.*))?$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const color = /^#[0-9a-f]{6}$/i;
type Route = { workspaceId: string; productId: string; kind: "hierarchy" | "targets" | "disciplines" | "stages" | "activities";
  disciplineId?: string; stageId?: string; activityId?: string };
export type ScheduleRepositoryFactory = (environment: WorkerEnvironment) => ScheduleRepository;

function response(body: Record<string, unknown>, status: number) {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

function parseRoute(pathname: string): Route | null {
  const match = pathname.match(prefix);
  if (!match) return null;
  const [, workspaceId, productId, root, remainder] = match;
  if (root === "hierarchy") return remainder ? null : { workspaceId, productId, kind: "hierarchy" };
  if (root === "targets") return remainder ? null : { workspaceId, productId, kind: "targets" };
  const parts = remainder?.split("/") ?? [];
  if (parts.length === 0) return { workspaceId, productId, kind: "disciplines" };
  if (parts.length === 1) return { workspaceId, productId, disciplineId: parts[0], kind: "disciplines" };
  if (parts[1] !== "stages") return null;
  if (parts.length === 2) return { workspaceId, productId, disciplineId: parts[0], kind: "stages" };
  if (parts.length === 3) return { workspaceId, productId, disciplineId: parts[0], stageId: parts[2], kind: "stages" };
  if (parts[3] !== "activities") return null;
  if (parts.length === 4) return { workspaceId, productId, disciplineId: parts[0], stageId: parts[2], kind: "activities" };
  if (parts.length === 5) return { workspaceId, productId, disciplineId: parts[0], stageId: parts[2], activityId: parts[4], kind: "activities" };
  return null;
}

export function isScheduleRoute(pathname: string): boolean { return parseRoute(pathname) !== null; }

async function body(request: Request): Promise<Record<string, unknown> | null> {
  if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) return null;
  const length = Number(request.headers.get("Content-Length") ?? 0);
  if (length > 8192) return null;
  const raw = await request.text();
  if (raw.length > 8192) return null;
  try {
    const value: unknown = JSON.parse(raw);
    return value && typeof value === "object" && !Array.isArray(value)
      ? value as Record<string, unknown> : null;
  } catch { return null; }
}
const only = (value: Record<string, unknown>, keys: string[]) =>
  Object.keys(value).every((key) => keys.includes(key));
const label = (value: unknown, max: number): string | null => {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  return normalized.length > 0 && normalized.length <= max &&
    !Array.from(normalized).some((character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127)
    ? normalized : null;
};
const optional = (value: unknown, max: number): string | null | undefined => {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value !== "string") return undefined;
  const normalized = value.trim();
  return normalized.length <= max &&
    !Array.from(normalized).some((character) => character.charCodeAt(0) === 0 || character.charCodeAt(0) === 127)
    ? normalized || null : undefined;
};
const order = (value: unknown): value is number =>
  Number.isSafeInteger(value) && Number(value) >= 0 && Number(value) <= 1000000;
const version = (value: unknown): value is number =>
  Number.isSafeInteger(value) && Number(value) > 0;

function disciplineInput(value: Record<string, unknown>, editing: boolean): { input: DisciplineInput; version?: number } | null {
  if (!only(value, ["name", "shortCode", "color", "displayOrder", "description", ...(editing ? ["version"] : [])])) return null;
  const name = label(value["name"], 200);
  const shortCode = label(value["shortCode"], 24);
  const description = optional(value["description"], 2000);
  if (!name || !shortCode || description === undefined || !color.test(String(value["color"])) || !order(value["displayOrder"]) ||
      (editing && !version(value["version"]))) return null;
  return { input: { name, shortCode, color: String(value["color"]).toUpperCase(),
    displayOrder: value["displayOrder"] as number, description },
    ...(editing ? { version: value["version"] as number } : {}) };
}
function stageInput(value: Record<string, unknown>, editing: boolean): { input: StageInput; version?: number } | null {
  if (!only(value, ["code", "color", "displayName", "displayOrder", ...(editing ? ["version"] : [])])) return null;
  const code = label(value["code"], 24);
  const displayName = label(value["displayName"], 200);
  if (!code || !displayName || !color.test(String(value["color"])) || !order(value["displayOrder"]) ||
      (editing && !version(value["version"]))) return null;
  return { input: { code, color: String(value["color"]).toUpperCase(),
    displayName, displayOrder: value["displayOrder"] as number },
    ...(editing ? { version: value["version"] as number } : {}) };
}

function civilDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^[1-9][0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= days[month - 1];
}
function activityInput(value: Record<string, unknown>, editing: boolean):
  { input: ActivityInput | ActivityMetadataInput; version?: number } | null {
  const keys = ["name", "activityType", "displayOrder", "notes",
    ...(editing ? ["version"] : ["plannedStart", "plannedEnd"])];
  if (!only(value, keys)) return null;
  const name = label(value["name"], 300);
  const activityType = optional(value["activityType"], 80);
  const notes = optional(value["notes"], 4000);
  if (!name || activityType === undefined || notes === undefined || !order(value["displayOrder"]) ||
      (editing && !version(value["version"]))) return null;
  const metadata = { name, activityType, displayOrder: value["displayOrder"] as number, notes };
  if (editing) return { input: metadata, version: value["version"] as number };
  const start = value["plannedStart"] ?? null;
  const end = value["plannedEnd"] ?? null;
  if ((start === null) !== (end === null) ||
      (start !== null && (!civilDate(start) || !civilDate(end) || start > end))) return null;
  return { input: { ...metadata, plannedStart: start as string | null, plannedEnd: end as string | null } };
}

function mutation<T>(result: Mutation<T>, noun: string, created = false): Response {
  if (result.status === "ok") return response({ [noun]: result.value }, created ? 201 : 200);
  if (result.status === "not_found") return response({ error: "Não encontrado." }, 404);
  if (result.status === "duplicate") return response({ error: "Já existe um item com esse nome ou código." }, 409);
  if (result.status === "conflict") return response({ error: "O código da etapa já possui outra cor neste espaço de trabalho." }, 409);
  return response({ error: "O item foi alterado. Atualize os dados e tente novamente." }, 409);
}

export async function handleScheduleRequest(request: Request, identity: Identity,
  memberships: MembershipRepository, environment: WorkerEnvironment,
  factory: ScheduleRepositoryFactory = createScheduleRepository): Promise<Response> {
  const route = parseRoute(new URL(request.url).pathname);
  if (!route) return response({ error: "Não encontrado." }, 404);
  const ids = [route.workspaceId, route.productId, route.disciplineId, route.stageId, route.activityId]
    .filter((item): item is string => item !== undefined);
  if (ids.some((item) => !uuid.test(item))) return response({ error: "Identificador inválido." }, 400);
  const write = request.method !== "GET";
  const membership = await authorizeWorkspace(identity, route.workspaceId, write ? "edit" : "read", memberships);
  if (!membership) return response({ error: "Acesso não autorizado." }, 403);
  const ws = membership.workspaceId;
  const productId = route.productId.toLowerCase();
  const disciplineId = route.disciplineId?.toLowerCase();
  const stageId = route.stageId?.toLowerCase();
  const activityId = route.activityId?.toLowerCase();
  const repository = factory(environment);
  if (!(await repository.productExists(ws, productId, write))) return response({ error: "Não encontrado." }, 404);
  if (disciplineId && !(await repository.disciplineExists(ws, productId, disciplineId, write)))
    return response({ error: "Não encontrado." }, 404);
  if (stageId && !(await repository.stageExists(ws, productId, disciplineId!, stageId, write)))
    return response({ error: "Não encontrado." }, 404);

  if (route.kind === "hierarchy" && request.method === "GET") {
    const hierarchy = await repository.getHierarchy(ws, productId);
    return hierarchy ? response({ hierarchy }, 200) : response({ error: "Não encontrado." }, 404);
  }
  if (route.kind === "targets" && request.method === "GET") {
    return response({ targets: await repository.listTargets(ws, productId) }, 200);
  }
  if (route.kind === "disciplines") {
    if (request.method === "GET" && !disciplineId) return response({ disciplines: await repository.listDisciplines(ws, productId) }, 200);
    if (request.method === "POST" && !disciplineId) {
      const value = await body(request); const parsed = value && disciplineInput(value, false);
      if (!parsed) return response({ error: "Dados inválidos." }, 400);
      return mutation(await repository.createDiscipline(ws, productId, identity.subject, parsed.input), "discipline", true);
    }
    if (request.method === "PATCH" && disciplineId) {
      const value = await body(request); const parsed = value && disciplineInput(value, true);
      if (!parsed || !parsed.version) return response({ error: "Dados inválidos." }, 400);
      return mutation(await repository.updateDiscipline(ws, productId, disciplineId, identity.subject, parsed.input, parsed.version), "discipline");
    }
  }
  if (route.kind === "stages" && disciplineId) {
    if (request.method === "GET" && !stageId) return response({ stages: await repository.listStages(ws, productId, disciplineId) }, 200);
    if (request.method === "POST" && !stageId) {
      const value = await body(request); const parsed = value && stageInput(value, false);
      if (!parsed) return response({ error: "Dados inválidos." }, 400);
      return mutation(await repository.createStage(ws, productId, disciplineId, identity.subject, parsed.input), "stage", true);
    }
    if (request.method === "PATCH" && stageId) {
      const value = await body(request); const parsed = value && stageInput(value, true);
      if (!parsed || !parsed.version) return response({ error: "Dados inválidos." }, 400);
      return mutation(await repository.updateStage(ws, productId, disciplineId, stageId, identity.subject, parsed.input, parsed.version), "stage");
    }
  }
  if (route.kind === "activities" && disciplineId && stageId) {
    if (request.method === "GET" && !activityId) return response({ activities: await repository.listActivities(ws, productId, disciplineId, stageId) }, 200);
    if (request.method === "POST" && !activityId) {
      const value = await body(request); const parsed = value && activityInput(value, false);
      if (!parsed) return response({ error: "Dados inválidos." }, 400);
      return mutation(await repository.createActivity(ws, productId, disciplineId, stageId, identity.subject,
        parsed.input as ActivityInput), "activity", true);
    }
    if (request.method === "PATCH" && activityId) {
      const value = await body(request); const parsed = value && activityInput(value, true);
      if (!parsed || !parsed.version) return response({ error: "Dados inválidos." }, 400);
      return mutation(await repository.updateActivity(ws, productId, disciplineId, stageId, activityId,
        identity.subject, parsed.input as ActivityMetadataInput, parsed.version), "activity");
    }
  }
  return response({ error: "Método não permitido." }, 405);
}
