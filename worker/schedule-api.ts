import { authorizeWorkspace, type MembershipRepository } from "./authorization";
import { calculateWorkingDayEndDate } from "../domain/working-day-calculation";
import { detectCalendarImpact } from "../domain/calendar-impact";
import { createCalendarRepository, type CalendarRepository } from "./calendar-repository";
import type { Identity } from "./auth";
import type { WorkerEnvironment } from "./database";
import { createScheduleRepository, type ActivityInput, type ActivityMetadataInput, type WorkingActivityInput,
  type CalendarRescheduleProposal, type DeletionKind, type DisciplineInput, type HierarchyMoveInput, type Mutation,
  type ProductChangeHistoryCursor, type ScheduleRepository, type StageInput } from "./schedule-repository";

const prefix = /^\/api\/workspaces\/([^/]+)\/products\/([^/]+)\/(hierarchy|calendar-impact|calendar-reschedules|change-history|targets|disciplines|root-activities)(?:\/(.*))?$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const eventCursorId = /^[a-z][a-z0-9_-]*:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const color = /^#[0-9a-f]{6}$/i;
type Route = { workspaceId: string; productId: string; kind: "hierarchy" | "hierarchy_move" | "deletion_preview" | "deletion_execute" | "calendar_impact" | "calendar_impact_apply" | "calendar_reschedule_history" | "calendar_reschedule_reverse" | "product_change_history" | "targets" | "target" | "disciplines" | "stages" | "activities" | "root_activities" | "activity_dates" | "activity_history" | "activity_working_plan";
  disciplineId?: string; stageId?: string; activityId?: string; targetId?: string; operationId?: string;
  rootActivity?: true };
export type ScheduleRepositoryFactory = (environment: WorkerEnvironment) => ScheduleRepository;

function response(body: Record<string, unknown>, status: number) {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

function parseRoute(pathname: string): Route | null {
  const match = pathname.match(prefix);
  if (!match) return null;
  const [, workspaceId, productId, root, remainder] = match;
  if (root === "hierarchy") return remainder === "moves"
    ? { workspaceId, productId, kind: "hierarchy_move" }
    : remainder === "deletion-preview"
    ? { workspaceId, productId, kind: "deletion_preview" }
    : remainder === "deletions" ? { workspaceId, productId, kind: "deletion_execute" }
      : remainder ? null : { workspaceId, productId, kind: "hierarchy" };
  if (root === "calendar-impact") return remainder === "apply"
    ? { workspaceId, productId, kind: "calendar_impact_apply" }
    : remainder ? null : { workspaceId, productId, kind: "calendar_impact" };
  if (root === "calendar-reschedules") {
    if (remainder === "history") return { workspaceId, productId, kind: "calendar_reschedule_history" };
    const operation = remainder?.match(/^([^/]+)\/reverse$/);
    return operation ? { workspaceId, productId, kind: "calendar_reschedule_reverse",
      operationId: operation[1] } : null;
  }
  if (root === "change-history") return remainder
    ? null : { workspaceId, productId, kind: "product_change_history" };
  if (root === "targets") return !remainder ? { workspaceId, productId, kind: "targets" }
    : /^[^/]+$/.test(remainder) ? { workspaceId, productId, kind: "target", targetId: remainder } : null;
  if (root === "root-activities") {
    const parts = remainder?.split("/") ?? [];
    if (parts.length === 0) return { workspaceId, productId, kind: "root_activities" };
    if (parts.length === 1) return { workspaceId, productId, kind: "activities",
      activityId: parts[0], rootActivity: true };
    if (parts.length === 2 && ["dates", "date-history", "working-plan"].includes(parts[1]!))
      return { workspaceId, productId, kind: parts[1] === "dates" ? "activity_dates"
        : parts[1] === "date-history" ? "activity_history" : "activity_working_plan",
      activityId: parts[0], rootActivity: true };
    return null;
  }
  const parts = remainder?.split("/") ?? [];
  if (parts.length === 0) return { workspaceId, productId, kind: "disciplines" };
  if (parts.length === 1) return { workspaceId, productId, disciplineId: parts[0], kind: "disciplines" };
  if (parts[1] !== "stages") return null;
  if (parts.length === 2) return { workspaceId, productId, disciplineId: parts[0], kind: "stages" };
  if (parts.length === 3) return { workspaceId, productId, disciplineId: parts[0], stageId: parts[2], kind: "stages" };
  if (parts[3] !== "activities") return null;
  if (parts.length === 4) return { workspaceId, productId, disciplineId: parts[0], stageId: parts[2], kind: "activities" };
  if (parts.length === 5) return { workspaceId, productId, disciplineId: parts[0], stageId: parts[2], activityId: parts[4], kind: "activities" };
  if (parts.length === 6 && parts[5] === "dates")
    return { workspaceId, productId, disciplineId: parts[0], stageId: parts[2], activityId: parts[4], kind: "activity_dates" };
  if (parts.length === 6 && parts[5] === "date-history")
    return { workspaceId, productId, disciplineId: parts[0], stageId: parts[2], activityId: parts[4], kind: "activity_history" };
  if (parts.length === 6 && parts[5] === "working-plan")
    return { workspaceId, productId, disciplineId: parts[0], stageId: parts[2], activityId: parts[4], kind: "activity_working_plan" };
  return null;
}

function validCursorTimestamp(value: string): boolean {
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{6})Z$/);
  if (!match) return false;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, fraction] = match;
  const year = Number(yearText); const month = Number(monthText); const day = Number(dayText);
  const hour = Number(hourText); const minute = Number(minuteText); const second = Number(secondText);
  const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second, Number(fraction!.slice(0, 3))));
  return year >= 1900 && date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day && date.getUTCHours() === hour && date.getUTCMinutes() === minute &&
    date.getUTCSeconds() === second;
}

function decodeHistoryCursor(value: string): ProductChangeHistoryCursor | null {
  const separator = value.indexOf("~");
  if (separator < 1 || separator !== value.lastIndexOf("~")) return null;
  const occurredAt = value.slice(0, separator);
  const eventId = value.slice(separator + 1);
  return validCursorTimestamp(occurredAt) && eventCursorId.test(eventId) ? { occurredAt, eventId } : null;
}

function encodeHistoryCursor(cursor: ProductChangeHistoryCursor): string {
  return `${cursor.occurredAt}~${cursor.eventId}`;
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

function hierarchyMoveInput(value: Record<string, unknown>): HierarchyMoveInput | null {
  if (!only(value, ["kind", "targetId", "expectedVersion", "destinationDisciplineId",
    "destinationStageId", "destinationIndex", "expectedSourceOrder", "expectedDestinationOrder"])) return null;
  const kind = value["kind"];
  const targetId = value["targetId"];
  const expectedVersion = value["expectedVersion"];
  const destinationDisciplineId = value["destinationDisciplineId"];
  const destinationStageId = value["destinationStageId"];
  const destinationIndex = value["destinationIndex"];
  const expectedSourceOrder = value["expectedSourceOrder"];
  const expectedDestinationOrder = value["expectedDestinationOrder"];
  if ((kind !== "activity" && kind !== "stage" && kind !== "discipline") ||
      typeof targetId !== "string" || !uuid.test(targetId) ||
      !Number.isSafeInteger(expectedVersion) || Number(expectedVersion) < 1 ||
      !Number.isSafeInteger(destinationIndex) || Number(destinationIndex) < 0 ||
      (destinationDisciplineId !== null &&
        (typeof destinationDisciplineId !== "string" || !uuid.test(destinationDisciplineId))) ||
      (destinationStageId !== null &&
        (typeof destinationStageId !== "string" || !uuid.test(destinationStageId))) ||
      !Array.isArray(expectedSourceOrder) || !Array.isArray(expectedDestinationOrder) ||
      expectedSourceOrder.length > 1000 || expectedDestinationOrder.length > 1000) return null;
  const sourceIds = expectedSourceOrder.filter((id): id is string => typeof id === "string" && uuid.test(id));
  const destinationIds = expectedDestinationOrder.filter((id): id is string => typeof id === "string" && uuid.test(id));
  if (sourceIds.length !== expectedSourceOrder.length || destinationIds.length !== expectedDestinationOrder.length ||
      new Set(sourceIds.map((id) => id.toLowerCase())).size !== sourceIds.length ||
      new Set(destinationIds.map((id) => id.toLowerCase())).size !== destinationIds.length) return null;
  if (kind === "discipline" && (destinationDisciplineId !== null || destinationStageId !== null) ||
      kind === "stage" && (destinationDisciplineId === null || destinationStageId !== null) ||
      kind === "activity" && ((destinationDisciplineId === null) !== (destinationStageId === null))) return null;
  return { kind, targetId: targetId.toLowerCase(), expectedVersion: Number(expectedVersion),
    destinationDisciplineId: destinationDisciplineId?.toLowerCase() ?? null,
    destinationStageId: destinationStageId?.toLowerCase() ?? null,
    destinationIndex: Number(destinationIndex),
    expectedSourceOrder: sourceIds.map((id) => id.toLowerCase()),
    expectedDestinationOrder: destinationIds.map((id) => id.toLowerCase()) };
}
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
function dateChangeInput(value: Record<string, unknown>):
  { start: string; end: string; reason: string | null; version: number } | null {
  if (!only(value, ["plannedStart", "plannedEnd", "reason", "version"]) ||
      !civilDate(value["plannedStart"]) || !civilDate(value["plannedEnd"]) ||
      value["plannedStart"] > value["plannedEnd"] || !version(value["version"])) return null;
  const rawReason = value["reason"];
  const reason = rawReason === undefined || rawReason === null || rawReason === ""
    ? null : label(rawReason, 2000);
  if (reason === null && rawReason !== undefined && rawReason !== null && rawReason !== "") return null;
  if (reason && reason.length < 10) return null;
  return { start: value["plannedStart"], end: value["plannedEnd"], reason,
    version: value["version"] as number };
}
function activityInput(value: Record<string, unknown>, editing: boolean, allowColorOnCreate = false):
  { input: ActivityInput | ActivityMetadataInput; version?: number;
    workingPlan?: { start: string; duration: number; calendarVersion: number } } | null {
  const keys = ["name", "activityType", "displayOrder", "notes", ...(editing || allowColorOnCreate ? ["colorOverride"] : []),
    ...(editing ? ["version"] : ["plannedStart", "plannedEnd", "planningMode", "workingDays", "calendarVersion"])];
  if (!only(value, keys)) return null;
  const name = label(value["name"], 300);
  const activityType = optional(value["activityType"], 80);
  const notes = optional(value["notes"], 4000);
  if (!name || activityType === undefined || notes === undefined || !order(value["displayOrder"]) ||
      (editing && !version(value["version"]))) return null;
  const colorOverride = value["colorOverride"];
  if ((editing || allowColorOnCreate) && colorOverride !== undefined && colorOverride !== null &&
      !color.test(String(colorOverride))) return null;
  const metadata = { name, activityType, displayOrder: value["displayOrder"] as number, notes,
    ...( (editing || allowColorOnCreate) && colorOverride !== undefined
      ? { colorOverride: colorOverride === null ? null : String(colorOverride).toUpperCase() } : {}) };
  if (editing) return { input: metadata, version: value["version"] as number };
  const planningMode = value["planningMode"] ?? "manual";
  if (planningMode === "working_days") {
    const start = value["plannedStart"];
    const duration = value["workingDays"];
    const calendarVersion = value["calendarVersion"];
    if (!civilDate(start) || value["plannedEnd"] !== undefined ||
        !Number.isSafeInteger(duration) || Number(duration) < 1 || Number(duration) > 27393 ||
        !Number.isSafeInteger(calendarVersion) || Number(calendarVersion) < 0) return null;
    return { input: { ...metadata, plannedStart: start, plannedEnd: null },
      workingPlan: { start, duration: Number(duration), calendarVersion: Number(calendarVersion) } };
  }
  if ((planningMode !== "manual") || value["workingDays"] !== undefined || value["calendarVersion"] !== undefined)
    return null;
  const start = value["plannedStart"] ?? null;
  const end = value["plannedEnd"] ?? null;
  if ((start === null) !== (end === null) ||
      (start !== null && (!civilDate(start) || !civilDate(end) || start > end))) return null;
  return { input: { ...metadata, plannedStart: start as string | null, plannedEnd: end as string | null } };
}

function workingPlanInput(value: Record<string, unknown>): {
  start: string; duration: number; calendarVersion: number; reason: string; version: number
} | null {
  if (!only(value, ["startDate", "workingDays", "calendarVersion", "reason", "version"]) ||
      !civilDate(value["startDate"]) || !Number.isSafeInteger(value["workingDays"]) ||
      Number(value["workingDays"]) < 1 || Number(value["workingDays"]) > 27393 ||
      !Number.isSafeInteger(value["calendarVersion"]) || Number(value["calendarVersion"]) < 0 ||
      !version(value["version"])) return null;
  const reason = label(value["reason"], 2000);
  if (!reason || reason.length < 10) return null;
  return { start: value["startDate"], duration: Number(value["workingDays"]),
    calendarVersion: Number(value["calendarVersion"]), reason, version: Number(value["version"]) };
}

function calendarRescheduleInput(value: Record<string, unknown>):
  { calendarVersion: number; reason: string; selections: { activityId: string; version: number }[] } | null {
  if (!only(value, ["calendarVersion", "reason", "selections"]) ||
      !Number.isSafeInteger(value["calendarVersion"]) || Number(value["calendarVersion"]) < 1 ||
      !Array.isArray(value["selections"]) || value["selections"].length < 1 ||
      value["selections"].length > 50) return null;
  const reason = label(value["reason"], 2000);
  if (!reason || reason.length < 10) return null;
  const selections = value["selections"] as unknown[];
  const seen = new Set<string>();
  const parsed: { activityId: string; version: number }[] = [];
  for (const selection of selections) {
    if (!selection || typeof selection !== "object" || Array.isArray(selection)) return null;
    const item = selection as Record<string, unknown>;
    if (!only(item, ["activityId", "version"]) || typeof item["activityId"] !== "string" ||
        !uuid.test(item["activityId"]) || !version(item["version"])) return null;
    const activityId = item["activityId"].toLowerCase();
    if (seen.has(activityId)) return null;
    seen.add(activityId);
    parsed.push({ activityId, version: item["version"] as number });
  }
  return { calendarVersion: Number(value["calendarVersion"]), reason, selections: parsed };
}

function targetInput(value: Record<string, unknown>, editing: boolean):
  { input: { name: string; description: string | null; targetDate: string; color: string };
    version?: number; reason?: string | null } | null {
  const keys = ["name", "description", "targetDate", "color", ...(editing ? ["version", "reason"] : [])];
  if (!only(value, keys)) return null;
  const name = label(value["name"], 200);
  const description = optional(value["description"], 2000);
  if (!name || description === undefined || !civilDate(value["targetDate"]) || !color.test(String(value["color"])) ||
      (editing && !version(value["version"]))) return null;
  const rawReason = value["reason"];
  const reason = rawReason === undefined || rawReason === null || rawReason === "" ? null : label(rawReason, 2000);
  if (reason === null && rawReason !== undefined && rawReason !== null && rawReason !== "") return null;
  if (reason && reason.length < 10) return null;
  return { input: { name, description, targetDate: value["targetDate"], color: String(value["color"]).toUpperCase() },
    ...(editing ? { version: value["version"] as number, reason } : {}) };
}

function mutation<T>(result: Mutation<T>, noun: string, created = false): Response {
  if (result.status === "ok") return response({ [noun]: result.value }, created ? 201 : 200);
  if (result.status === "not_found") return response({ error: "Não encontrado." }, 404);
  if (result.status === "duplicate") return response({ error: "Já existe um item com esse nome ou código." }, 409);
  if (result.status === "invalid") return response({ error: "Informe uma justificativa válida para alterar a data." }, 400);
  if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
  if (result.status === "stale_calendar") return response({ error: "O calendário mudou. Recalcule a previsão e tente novamente.", code: "stale_calendar" }, 409);
  if (result.status === "conflict") return response({ error: "O código da etapa já possui outra cor neste espaço de trabalho." }, 409);
  return response({ error: "O item foi alterado. Atualize os dados e tente novamente." }, 409);
}
function targetMutation(result: Mutation<unknown>, created = false): Response {
  if (result.status === "ok") return response({ target: result.value }, created ? 201 : 200);
  if (result.status === "not_found") return response({ error: "Meta não encontrada." }, 404);
  if (result.status === "duplicate") return response({ error: "Já existe uma meta com esse nome neste produto." }, 409);
  if (result.status === "invalid") return response({ error: "Informe dados válidos e uma justificativa adequada para alterar a data." }, 400);
  if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
  return response({ error: "A meta foi alterada. Atualize os dados e tente novamente." }, 409);
}

export async function handleScheduleRequest(request: Request, identity: Identity,
  memberships: MembershipRepository, environment: WorkerEnvironment,
  factory: ScheduleRepositoryFactory = createScheduleRepository,
  calendarFactory: (environment: WorkerEnvironment) => CalendarRepository = createCalendarRepository): Promise<Response> {
  const route = parseRoute(new URL(request.url).pathname);
  if (!route) return response({ error: "Não encontrado." }, 404);
  const ids = [route.workspaceId, route.productId, route.disciplineId, route.stageId,
    route.activityId, route.targetId, route.operationId]
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
  const activityDisciplineId = route.rootActivity ? null : disciplineId!;
  const activityStageId = route.rootActivity ? null : stageId!;
  const repository = factory(environment);
  if (!(await repository.productExists(ws, productId, write))) return response({ error: "Não encontrado." }, 404);
  if (disciplineId && !(await repository.disciplineExists(ws, productId, disciplineId, write)))
    return response({ error: "Não encontrado." }, 404);
  if (stageId && !(await repository.stageExists(ws, productId, disciplineId!, stageId, write)))
    return response({ error: "Não encontrado." }, 404);
  if ((route.kind === "activity_dates" || route.kind === "activity_history" ||
      route.kind === "activity_working_plan") && activityId &&
      !(await repository.activityExists(ws, productId, activityDisciplineId, activityStageId, activityId, write)))
    return response({ error: "Não encontrado." }, 404);

  if (route.kind === "hierarchy" && request.method === "GET") {
    const hierarchy = await repository.getHierarchy(ws, productId);
    return hierarchy ? response({ hierarchy }, 200) : response({ error: "Não encontrado." }, 404);
  }
  if (route.kind === "hierarchy_move" && request.method === "POST") {
    const value = await body(request);
    const input = value && hierarchyMoveInput(value);
    if (!input) return response({ error: "Informe um movimento de hierarquia válido." }, 400);
    try {
      const operationId = crypto.randomUUID();
      const result = await repository.moveHierarchyItem(ws, productId, identity.subject, operationId, input);
      if (result.status === "moved")
        return response({ changed: true, operationId, version: result.version }, 200);
      if (result.status === "unchanged")
        return response({ changed: false, version: result.version }, 200);
      if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
      if (result.status === "not_found") return response({ error: "Item ou destino não encontrado." }, 404);
      if (result.status === "invalid") return response({ error: "Movimento de hierarquia inválido." }, 400);
      if (result.status === "duplicate")
        return response({ error: "A disciplina de destino já possui esta etapa." }, 409);
      return response({ error: "A estrutura foi alterada. Atualize os dados e tente novamente." }, 409);
    } catch {
      return response({ error: "Não foi possível mover o item. Nenhuma alteração foi confirmada." }, 503);
    }
  }
  if (route.kind === "deletion_preview" && request.method === "GET") {
    if (membership.role === "viewer") return response({ error: "Acesso não autorizado." }, 403);
    const params = new URL(request.url).searchParams;
    const kind = params.get("kind");
    const targetId = params.get("targetId");
    if (params.size !== 2 || !["activity", "stage", "discipline"].includes(kind ?? "") ||
        !targetId || !uuid.test(targetId))
      return response({ error: "Informe um item válido para a prévia de exclusão." }, 400);
    try {
      const result = await repository.previewDeletion(ws, productId, identity.subject,
        kind as DeletionKind, targetId.toLowerCase());
      if (result.status === "ok") return response({ counts: result.counts, fingerprint: result.fingerprint }, 200);
      if (result.status === "not_found") return response({ error: "Item não encontrado." }, 404);
      if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
      return response({ error: "Consulta inválida." }, 400);
    } catch { return response({ error: "Não foi possível consultar o impacto da exclusão." }, 503); }
  }
  if (route.kind === "deletion_execute" && request.method === "POST") {
    const value = await body(request);
    const kind = value?.["kind"];
    const targetId = value?.["targetId"];
    const fingerprint = value?.["fingerprint"];
    const reason = value && label(value["reason"], 2000);
    if (!value || !only(value, ["kind", "targetId", "fingerprint", "reason"]) ||
        !["activity", "stage", "discipline"].includes(String(kind)) ||
        typeof targetId !== "string" || !uuid.test(targetId) ||
        typeof fingerprint !== "string" || !/^[0-9a-f]{32}$/.test(fingerprint) ||
        !reason || reason.length < 10)
      return response({ error: "Informe um item, uma prévia atual e uma justificativa de pelo menos 10 caracteres." }, 400);
    try {
      const result = await repository.deleteSubtree(ws, productId, identity.subject,
        crypto.randomUUID(), kind as DeletionKind, targetId.toLowerCase(), fingerprint, reason);
      if (result.status === "deleted") return response({ operationId: result.operationId, counts: result.counts }, 200);
      if (result.status === "not_found") return response({ error: "Item não encontrado." }, 404);
      if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
      if (result.status === "stale") return response({ error: "A estrutura mudou. Atualize a prévia e tente novamente." }, 409);
      return response({ error: "Solicitação inválida." }, 400);
    } catch { return response({ error: "Não foi possível excluir o item. Nenhuma alteração foi confirmada." }, 503); }
  }
  if (route.kind === "calendar_impact" && request.method === "GET") {
    if (new URL(request.url).search) return response({ error: "Consulta inválida." }, 400);
    try {
      const calendar = await calendarFactory(environment).readForCalculation(ws);
      const plans = await repository.listWorkingPlans(ws, productId);
      const impacts = plans.flatMap((plan) => {
        const impact = detectCalendarImpact(plan, calendar.version, calendar.exceptions);
        return impact ? [impact] : [];
      });
      return response({ calendarVersion: calendar.version, impacts }, 200);
    } catch { return response({ error: "Não foi possível verificar o impacto do calendário." }, 503); }
  }
  if (route.kind === "calendar_reschedule_history" && request.method === "GET") {
    if (new URL(request.url).search) return response({ error: "Consulta inválida." }, 400);
    try {
      const result = await repository.listCalendarRescheduleHistory(ws, productId, identity.subject);
      if (result.status === "ok") return response({ operations: result.operations }, 200);
      if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
      if (result.status === "not_found") return response({ error: "Não encontrado." }, 404);
      return response({ error: "Não foi possível consultar o histórico." }, 400);
    } catch { return response({ error: "Não foi possível carregar o histórico de reprogramações." }, 503); }
  }
  if (route.kind === "product_change_history" && request.method === "GET") {
    const params = new URL(request.url).searchParams;
    const allowed = new Set(["limit", "cursor"]);
    if ([...params.keys()].some((key) => !allowed.has(key)) ||
        params.getAll("limit").length > 1 || params.getAll("cursor").length > 1 ||
        (params.has("limit") && !/^\d{1,3}$/.test(params.get("limit") ?? "")) ||
        (params.has("cursor") && (params.get("cursor") ?? "").length > 256))
      return response({ error: "Parâmetros de paginação inválidos." }, 400);
    const limit = params.has("limit") ? Number(params.get("limit")) : 25;
    const cursorValue = params.get("cursor");
    const cursor = cursorValue === null ? null : decodeHistoryCursor(cursorValue);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100 ||
        (cursorValue !== null && !cursor))
      return response({ error: "Parâmetros de paginação inválidos." }, 400);
    try {
      const result = await repository.listProductChangeHistory(ws, productId, identity.subject,
        limit, cursor);
      if (result.status === "ok") return response({ events: result.events,
        nextCursor: result.nextCursor ? encodeHistoryCursor(result.nextCursor) : null }, 200);
      if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
      if (result.status === "not_found") return response({ error: "Não encontrado." }, 404);
      return response({ error: "Consulta inválida." }, 400);
    } catch { return response({ error: "Não foi possível carregar o histórico do produto." }, 503); }
  }
  if (route.kind === "calendar_impact_apply" && request.method === "POST") {
    const value = await body(request);
    const parsed = value && calendarRescheduleInput(value);
    if (!parsed) return response({ error: "Selecione atividades válidas e informe uma justificativa de pelo menos 10 caracteres." }, 400);
    try {
      const calendar = await calendarFactory(environment).readForCalculation(ws);
      if (calendar.version !== parsed.calendarVersion)
        return response({ error: "O calendário mudou. Atualize a prévia e tente novamente." }, 409);
      const plans = await repository.listWorkingPlans(ws, productId);
      const byId = new Map(plans.map((plan) => [plan.id.toLowerCase(), plan]));
      const proposals: CalendarRescheduleProposal[] = [];
      for (const selection of parsed.selections) {
        const plan = byId.get(selection.activityId);
        if (!plan) return response({ error: "A atividade selecionada não está disponível para reagendamento." }, 409);
        if (plan.version !== selection.version)
          return response({ error: "A atividade foi alterada. Atualize a prévia e tente novamente." }, 409);
        const impact = detectCalendarImpact(plan, calendar.version, calendar.exceptions);
        if (!impact || impact.impact !== "date_change")
          return response({ error: "A seleção não contém uma alteração de data. Atualize a prévia." }, 409);
        proposals.push({ activityId: impact.activityId, disciplineId: impact.disciplineId,
          stageId: impact.stageId, expectedVersion: impact.activityVersion,
          startDate: impact.currentStartDate, currentEndDate: impact.currentEndDate,
          proposedEndDate: impact.proposedEndDate, workingDays: impact.workingDays,
          savedCalendarVersion: impact.savedCalendarVersion });
      }
      const result = await repository.applyCalendarReschedule(ws, productId, identity.subject,
        crypto.randomUUID(), calendar.version, parsed.reason, proposals);
      if (result.status === "updated") return response({ changedCount: result.count, operationId: result.operationId }, 200);
      if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
      if (result.status === "not_found") return response({ error: "Produto ou atividade não encontrado." }, 404);
      if (result.status === "invalid") return response({ error: "Seleção ou justificativa inválida." }, 400);
      return response({ error: "O calendário ou uma atividade mudou. Atualize a prévia e tente novamente." }, 409);
    } catch { return response({ error: "Não foi possível reagendar as atividades. Tente novamente." }, 503); }
  }
  if (route.kind === "calendar_reschedule_reverse" && request.method === "POST") {
    if (new URL(request.url).search) return response({ error: "Consulta inválida." }, 400);
    const value = await body(request);
    const reason = value && only(value, ["reason"]) ? label(value["reason"], 2000) : null;
    if (!reason || reason.length < 10)
      return response({ error: "Informe uma justificativa de pelo menos 10 caracteres." }, 400);
    try {
      const result = await repository.reverseCalendarReschedule(ws, productId, identity.subject,
        route.operationId!.toLowerCase(), crypto.randomUUID(), reason);
      if (result.status === "reversed") return response({ reversedCount: result.count,
        originalOperationId: result.originalOperationId, operationId: result.operationId }, 200);
      if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
      if (result.status === "not_found") return response({ error: "Reprogramação não encontrada." }, 404);
      if (result.status === "already_reversed") return response({ error: "Esta reprogramação já foi revertida.",
        code: "already_reversed" }, 409);
      if (result.status === "stale") return response({ error: "Uma atividade foi alterada após a reprogramação.",
        code: "activity_changed", activityId: result.activityId }, 409);
      return response({ error: "Solicitação de reversão inválida." }, 400);
    } catch { return response({ error: "Não foi possível reverter a reprogramação. Tente novamente." }, 503); }
  }
  if (route.kind === "targets" && request.method === "GET") {
    return response({ targets: await repository.listTargets(ws, productId) }, 200);
  }
  if (route.kind === "targets" && request.method === "POST") {
    const value = await body(request); const parsed = value && targetInput(value, false);
    if (!parsed) return response({ error: "Informe nome, data e cor válidos." }, 400);
    try { return targetMutation(await repository.createTarget(ws, productId, identity.subject, parsed.input), true); }
    catch { return response({ error: "Não foi possível salvar a meta. Tente novamente." }, 503); }
  }
  if (route.kind === "target" && route.targetId && request.method === "PATCH") {
    const value = await body(request); const parsed = value && targetInput(value, true);
    if (!parsed || parsed.version === undefined) return response({ error: "Informe dados válidos para a meta." }, 400);
    let result;
    try {
      result = await repository.updateTarget(ws, productId, route.targetId.toLowerCase(), identity.subject,
        parsed.input, parsed.version, parsed.reason ?? null, crypto.randomUUID());
    } catch { return response({ error: "Não foi possível salvar a meta. Tente novamente." }, 503); }
    return targetMutation(result);
  }
  if (route.kind === "target" && route.targetId && request.method === "DELETE") {
    const value = await body(request);
    if (!value || !only(value, ["version"]) || !version(value["version"]))
      return response({ error: "Atualize os dados da meta antes de excluí-la." }, 400);
    try {
      return targetMutation(await repository.deleteTarget(ws, productId, route.targetId.toLowerCase(), identity.subject,
        value["version"] as number, crypto.randomUUID()));
    } catch { return response({ error: "Não foi possível excluir a meta. Tente novamente." }, 503); }
  }
  if (route.kind === "activity_history" && request.method === "GET" && activityId) {
    return response({ changes: await repository.listActivityDateHistory(ws, productId,
      activityDisciplineId, activityStageId, activityId) }, 200);
  }
  if (route.kind === "activity_dates" && request.method === "PATCH" && activityId) {
    const value = await body(request); const parsed = value && dateChangeInput(value);
    if (!parsed) return response({ error: "Datas ou justificativa inválidas." }, 400);
    const result = await repository.changeActivityDates(ws, productId, activityDisciplineId,
      activityStageId, activityId,
      identity.subject, parsed.start, parsed.end, parsed.reason, parsed.version, crypto.randomUUID());
    if (result.status === "forbidden") return response({ error: "Acesso não autorizado." }, 403);
    if (result.status === "not_found") return response({ error: "Não encontrado." }, 404);
    if (result.status === "stale") return response({ error: "A atividade foi alterada. Atualize os dados e tente novamente." }, 409);
    if (result.status === "invalid") return response({ error: "Datas ou justificativa inválidas." }, 400);
    if ("activity" in result) return response({ activity: result.activity, changed: result.status === "updated" }, 200);
    return response({ error: "Serviço indisponível." }, 503);
  }
  if (route.kind === "activity_working_plan" && request.method === "PATCH" && activityId) {
    const value = await body(request);
    const parsed = value && workingPlanInput(value);
    if (!parsed) return response({ error: "Informe data, duraÃ§Ã£o e justificativa vÃ¡lidas." }, 400);
    try {
      const calendar = await calendarFactory(environment).readForCalculation(ws);
      if (parsed.calendarVersion !== calendar.version)
        return response({ error: "O calendÃ¡rio mudou. Recalcule a previsÃ£o e tente novamente.", code: "calendar_conflict" }, 409);
      let calculation;
      try { calculation = calculateWorkingDayEndDate(parsed.start, parsed.duration, calendar.exceptions); }
      catch { return response({ error: "A data e a duração excedem o período de calendário disponível." }, 400); }
      const result = await repository.changeActivityWorkingPlan(ws, productId, activityDisciplineId,
        activityStageId, activityId,
        identity.subject, parsed.start, calculation.endDate, parsed.duration, calendar.version,
        parsed.reason, parsed.version, crypto.randomUUID());
      if (result.status === "forbidden") return response({ error: "Acesso nÃ£o autorizado." }, 403);
      if (result.status === "not_found") return response({ error: "NÃ£o encontrado." }, 404);
      if (result.status === "stale" || result.status === "stale_calendar")
        return response({ error: "A atividade ou o calendÃ¡rio mudou. Recalcule e tente novamente.", code: result.status }, 409);
      if (result.status === "invalid") return response({ error: "Informe dados e justificativa vÃ¡lidos." }, 400);
      if (result.status !== "updated" && result.status !== "unchanged")
        return response({ error: "NÃ£o foi possÃ­vel salvar o planejamento. Tente novamente." }, 503);
      return response({ activity: result.activity, changed: result.status === "updated", calculation }, 200);
    } catch { return response({ error: "NÃ£o foi possÃ­vel salvar o planejamento. Tente novamente." }, 503); }
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
  if (route.kind === "root_activities") {
    if (request.method === "GET")
      return response({ rootActivities: await repository.listRootActivities(ws, productId) }, 200);
    if (request.method === "POST") {
      const value = await body(request); const parsed = value && activityInput(value, false, true);
      if (!parsed) return response({ error: "Dados invÃ¡lidos." }, 400);
      if (!parsed.workingPlan)
        return mutation(await repository.createActivity(ws, productId, null, null, identity.subject,
          parsed.input as ActivityInput), "activity", true);
      try {
        const calendar = await calendarFactory(environment).readForCalculation(ws);
        if (parsed.workingPlan.calendarVersion !== calendar.version)
          return response({ error: "O calendÃ¡rio mudou. Recalcule a previsÃ£o e tente novamente.", code: "calendar_conflict" }, 409);
        let calculation;
        try { calculation = calculateWorkingDayEndDate(parsed.workingPlan.start,
          parsed.workingPlan.duration, calendar.exceptions); }
        catch { return response({ error: "A data e a duraÃ§Ã£o excedem o perÃ­odo de calendÃ¡rio disponÃ­vel." }, 400); }
        const workingInput: WorkingActivityInput = {
          ...(parsed.input as ActivityInput), plannedStart: parsed.workingPlan.start,
          plannedEnd: calculation.endDate, workingDays: parsed.workingPlan.duration,
          calendarVersion: calendar.version
        };
        return mutation(await repository.createWorkingActivity(ws, productId, null, null,
          identity.subject, workingInput), "activity", true);
      } catch { return response({ error: "NÃ£o foi possÃ­vel calcular ou salvar a atividade. Tente novamente." }, 503); }
    }
  }
  if (route.kind === "activities" && route.rootActivity && activityId && request.method === "PATCH") {
    const value = await body(request); const parsed = value && activityInput(value, true);
    if (!parsed || !parsed.version) return response({ error: "Dados invÃ¡lidos." }, 400);
    return mutation(await repository.updateActivity(ws, productId, null, null, activityId,
      identity.subject, parsed.input as ActivityMetadataInput, parsed.version), "activity");
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
      if (parsed.workingPlan) {
        try {
          const calendar = await calendarFactory(environment).readForCalculation(ws);
          if (parsed.workingPlan.calendarVersion !== calendar.version)
            return response({ error: "O calendário mudou. Recalcule a previsão e tente novamente.", code: "calendar_conflict" }, 409);
          let calculation;
          try { calculation = calculateWorkingDayEndDate(parsed.workingPlan.start,
            parsed.workingPlan.duration, calendar.exceptions); }
          catch { return response({ error: "A data e a duração excedem o período de calendário disponível." }, 400); }
          const workingInput: WorkingActivityInput = {
            ...(parsed.input as ActivityInput), plannedStart: parsed.workingPlan.start,
            plannedEnd: calculation.endDate, workingDays: parsed.workingPlan.duration,
            calendarVersion: calendar.version
          };
          const created = await repository.createWorkingActivity(ws, productId, disciplineId, stageId,
            identity.subject, workingInput);
          if (created.status === "invalid")
            return response({ error: "Dados do planejamento em dias úteis inválidos." }, 400);
          return mutation(created, "activity", true);
        } catch { return response({ error: "Não foi possível calcular ou salvar a atividade. Tente novamente." }, 503); }
      }
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
