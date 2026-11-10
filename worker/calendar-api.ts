import { calculateWorkingDayEndDate } from "../domain/working-day-calculation";
import { parseCivilDate, type CalendarExceptionInput, type CalendarExceptionKind } from "../domain/working-calendar";
import { authorizeWorkspace, type MembershipRepository } from "./authorization";
import type { Identity } from "./auth";
import { createCalendarRepository, type CalendarMutation, type CalendarRepository } from "./calendar-repository";
import type { WorkerEnvironment } from "./database";

const calendarPath = /^\/api\/workspaces\/([^/]+)\/calendar(?:\/(exceptions|history|working-day-preview)(?:\/([^/]+))?)?$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const exceptionKinds = new Set<CalendarExceptionKind>([
  "municipal_holiday", "collective_vacation", "company_shutdown"
]);

export type CalendarRepositoryFactory = (environment: WorkerEnvironment) => CalendarRepository;

function response(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

async function readBody(request: Request): Promise<Record<string, unknown> | null> {
  if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) return null;
  const text = await request.text();
  if (text.length > 2048) return null;
  try {
    const value: unknown = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value)
      ? value as Record<string, unknown> : null;
  } catch { return null; }
}

function validText(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.trim() === value && value.length >= 1 &&
    value.length <= maximum && !/\p{Cc}/u.test(value);
}

function parseException(body: Record<string, unknown>):
  { expectedVersion: number; input: CalendarExceptionInput } | null {
  const expectedVersion = body["expectedVersion"];
  if (!Number.isSafeInteger(expectedVersion) || Number(expectedVersion) < 0 ||
      Object.keys(body).some((key) => ![
        "expectedVersion", "kind", "name", "municipality", "description", "startDate", "endDate"
      ].includes(key))) return null;
  const kind = body["kind"];
  if (typeof kind !== "string" || !exceptionKinds.has(kind as CalendarExceptionKind)) return null;
  const startDate = body["startDate"];
  const endDate = body["endDate"];
  if (typeof startDate !== "string" || typeof endDate !== "string" ||
      !parseCivilDate(startDate) || !parseCivilDate(endDate) || endDate < startDate) return null;
  const duration = (Date.parse(`${endDate}T00:00:00Z`) - Date.parse(`${startDate}T00:00:00Z`)) / 86_400_000;
  if (duration > 365) return null;
  if (kind === "municipal_holiday") {
    if (startDate !== endDate || !validText(body["name"], 200) ||
        !validText(body["municipality"], 120) || body["description"] != null) return null;
    return { expectedVersion: Number(expectedVersion), input: {
      kind, name: body["name"], municipality: body["municipality"],
      description: null, startDate, endDate
    } };
  }
  if (!validText(body["description"], 500) || body["name"] != null || body["municipality"] != null)
    return null;
  return { expectedVersion: Number(expectedVersion), input: {
    kind: kind as CalendarExceptionKind, name: null, municipality: null,
    description: body["description"], startDate, endDate
  } };
}

function parseVersion(body: Record<string, unknown>): number | null {
  return Object.keys(body).length === 1 && Number.isSafeInteger(body["expectedVersion"]) &&
    Number(body["expectedVersion"]) >= 0 ? Number(body["expectedVersion"]) : null;
}

function mutationResponse(result: CalendarMutation): Response {
  if (result.status === "created") return response({ status: "created", version: result.version }, 201);
  if (result.status === "updated" || result.status === "removed" || result.status === "unchanged")
    return response({ status: result.status, version: result.version }, 200);
  if (result.status === "stale") return response({ code: "stale", error: "O calendário foi alterado. Atualize os dados e tente novamente." }, 409);
  if (result.status === "duplicate") return response({ code: "duplicate", error: "Já existe um feriado local para esta data e município." }, 409);
  if (result.status === "not_found") return response({ error: "Registro do calendário não encontrado." }, 404);
  if (result.status === "denied") return response({ error: "Acesso não autorizado." }, 403);
  return response({ error: "Dados do calendário inválidos." }, 400);
}

export function isCalendarRoute(pathname: string): boolean { return calendarPath.test(pathname); }

export async function handleCalendarRequest(
  request: Request, identity: Identity, memberships: MembershipRepository,
  environment: WorkerEnvironment, repositoryFactory: CalendarRepositoryFactory = createCalendarRepository
): Promise<Response> {
  const url = new URL(request.url);
  const match = url.pathname.match(calendarPath);
  if (!match) return response({ error: "Não encontrado." }, 404);
  const [, workspaceId, section, exceptionId] = match;
  if (!uuidPattern.test(workspaceId) || (exceptionId && !uuidPattern.test(exceptionId)))
    return response({ error: "Identificador inválido." }, 400);
  const permission = request.method === "GET" ? "read" : "manage";
  const membership = await authorizeWorkspace(identity, workspaceId, permission, memberships);
  if (!membership) return response({ error: "Acesso não autorizado." }, 403);
  const repository = repositoryFactory(environment);
  const scope = membership.workspaceId;

  if (!section && request.method === "GET") {
    if (url.searchParams.getAll("year").length !== 1 ||
        [...url.searchParams.keys()].some((key) => key !== "year"))
      return response({ error: "Ano inválido." }, 400);
    const yearText = url.searchParams.get("year");
    if (!yearText || !/^\d{4}$/.test(yearText)) return response({ error: "Ano inválido." }, 400);
    const year = Number(yearText);
    if (year < 2026 || year > 2100) return response({ error: "Ano inválido." }, 400);
    const calendar = await repository.read(scope, year);
    return response({ calendar }, 200);
  }
  if (section === "working-day-preview" && !exceptionId && request.method === "GET") {
    if (url.searchParams.getAll("startDate").length !== 1 ||
        url.searchParams.getAll("workingDays").length !== 1 ||
        [...url.searchParams.keys()].some((key) => key !== "startDate" && key !== "workingDays"))
      return response({ error: "Informe uma data e uma duração válidas." }, 400);
    const startDate = url.searchParams.get("startDate") ?? "";
    const workingDaysText = url.searchParams.get("workingDays") ?? "";
    const workingDays = Number(workingDaysText);
    if (!parseCivilDate(startDate) || !/^\d+$/.test(workingDaysText) ||
        !Number.isSafeInteger(workingDays) || workingDays < 1 || workingDays > 27393) {
      return response({ error: "Informe uma data e uma duração válidas." }, 400);
    }
    try {
      const calendar = await repository.readForCalculation(scope);
      const calculation = calculateWorkingDayEndDate(startDate, workingDays, calendar.exceptions);
      return response({ preview: { ...calculation, calendarVersion: calendar.version } }, 200);
    } catch { return response({ error: "Não foi possível calcular a previsão. Confira a data e a duração." }, 400); }
  }
  if (section === "history" && !exceptionId && request.method === "GET") {
    if (url.searchParams.getAll("beforeVersion").length > 1 ||
        [...url.searchParams.keys()].some((key) => key !== "beforeVersion"))
      return response({ error: "Consulta inválida." }, 400);
    const text = url.searchParams.get("beforeVersion");
    const beforeVersion = text === null ? null : Number(text);
    if (text !== null && (!/^\d+$/.test(text) || !Number.isSafeInteger(beforeVersion) || Number(beforeVersion) < 1))
      return response({ error: "Consulta inválida." }, 400);
    const history = await repository.history(scope, beforeVersion);
    return response({ history }, 200);
  }
  if (section === "exceptions" && !exceptionId && request.method === "POST") {
    const body = await readBody(request);
    const parsed = body && parseException(body);
    if (!parsed) return response({ error: "Dados do calendário inválidos." }, 400);
    return mutationResponse(await repository.change(scope, identity.subject, crypto.randomUUID(),
      parsed.expectedVersion, "create", null, parsed.input));
  }
  if (section === "exceptions" && exceptionId && request.method === "PATCH") {
    const body = await readBody(request);
    const parsed = body && parseException(body);
    if (!parsed) return response({ error: "Dados do calendário inválidos." }, 400);
    return mutationResponse(await repository.change(scope, identity.subject, crypto.randomUUID(),
      parsed.expectedVersion, "update", exceptionId.toLowerCase(), parsed.input));
  }
  if (section === "exceptions" && exceptionId && request.method === "DELETE") {
    const body = await readBody(request);
    const version = body && parseVersion(body);
    if (version === null) return response({ error: "Dados do calendário inválidos." }, 400);
    return mutationResponse(await repository.change(scope, identity.subject, crypto.randomUUID(),
      version, "remove", exceptionId.toLowerCase(), null));
  }
  return response({ error: "Método não permitido." }, 405);
}
