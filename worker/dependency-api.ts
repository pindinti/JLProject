import { SignJWT, jwtVerify } from "jose";
import { previewScheduleDependencies, type DependencyEdit, type DependencyEndpoint,
  type DependencyPreview } from "../domain/schedule-dependencies";
import { parseScheduleCivilDate } from "../domain/working-calendar";
import type { Identity } from "./auth";
import { authorizeWorkspace, type MembershipRepository } from "./authorization";
import type { WorkerEnvironment } from "./database";
import { createDependencyRepository, dependencyDateChangeLimit, type DependencyRepository,
  type DependencyWrite } from "./dependency-repository";

const path = /^\/api\/workspaces\/([^/]+)\/products\/([^/]+)\/dependencies(?:\/(preview|confirm))?$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const fingerprintPattern = /^[0-9a-f]{64}$/;
const tokenAudience = "jlproject-dependency-preview";
const rulesVersion = 1;
const tokenLifetimeSeconds = 300;
const maxBodyBytes = 8192;
const encoder = new TextEncoder();

type RepositoryFactory = (environment: WorkerEnvironment) => DependencyRepository;

function response(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

function failure(status: string): Response {
  switch (status) {
    case "forbidden": return response({ error: "Acesso não autorizado." }, 403);
    case "not_found": return response({ error: "Produto não encontrado." }, 404);
    case "invalid": return response({ error: "Dados ou justificativa inválidos." }, 400);
    case "too_large": return response({ code: status, error: "O cronograma excede o limite desta operação." }, 422);
    case "archived": return response({ code: status, error: "O produto está arquivado." }, 409);
    case "stale": return response({ code: status, error: "A prévia expirou ou o cronograma mudou. Gere uma nova prévia." }, 409);
    case "conflict": return response({ code: status, error: "Não foi possível confirmar a prévia. Atualize o cronograma." }, 409);
    default: return response({ error: "Serviço indisponível." }, 503);
  }
}

function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function shape(value: Record<string, unknown>, fields: readonly string[]): boolean {
  return Object.keys(value).length === fields.length && fields.every((field) => Object.hasOwn(value, field));
}

function id(value: unknown): string | null {
  return typeof value === "string" && uuid.test(value) ? value.toLowerCase() : null;
}

function version(value: unknown): value is string {
  return typeof value === "string" && /^(0|[1-9][0-9]{0,18})$/.test(value) && BigInt(value) <= 9223372036854775807n;
}

function endpoint(value: unknown, productId: string): DependencyEndpoint | null {
  const input = object(value);
  if (!input || !shape(input, ["id", "kind"])) return null;
  const entityId = id(input.id);
  return entityId && (input.kind === "activity" || input.kind === "stage")
    ? { productId, kind: input.kind, id: entityId } : null;
}

function editFrom(value: unknown, productId: string, edgeId: string): DependencyEdit | null {
  const input = object(value);
  if (!input) return null;
  switch (input.kind) {
    case "add_dependency": {
      const predecessor = endpoint(input.predecessor, productId);
      const successor = endpoint(input.successor, productId);
      return shape(input, ["kind", "predecessor", "successor"]) && predecessor && successor
        ? { kind: input.kind, dependency: { id: edgeId, predecessor, successor } } : null;
    }
    case "remove_dependency": {
      const dependencyId = id(input.dependencyId);
      return shape(input, ["kind", "dependencyId"]) && dependencyId ? { kind: input.kind, dependencyId } : null;
    }
    case "edit_dates": {
      const entity = endpoint(input.entity, productId);
      const dates = object(input.dates);
      if (!entity || !dates || !shape(input, ["kind", "entity", "dates"]) || !shape(dates, ["start", "end"])) return null;
      const { start, end } = dates;
      return (start === null || typeof start === "string" && parseScheduleCivilDate(start)) &&
        (end === null || typeof end === "string" && parseScheduleCivilDate(end))
        ? { kind: input.kind, entity, dates: { start, end } } : null;
    }
    case "edit_working_plan": {
      const entity = endpoint(input.entity, productId);
      const { start, duration } = input;
      return entity?.kind === "activity" && shape(input, ["kind", "entity", "start", "duration"]) &&
        typeof start === "string" && !!parseScheduleCivilDate(start) && typeof duration === "number" &&
        Number.isSafeInteger(duration) && duration >= 1 && duration <= 27393 ? { kind: input.kind, entity, start, duration } : null;
    }
    default: return null;
  }
}

async function readBody(request: Request): Promise<Record<string, unknown> | null> {
  if (request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase() !== "application/json" || !request.body) return null;
  const reader = request.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let length = 0;
  let body = "";
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) return object(JSON.parse(body + decoder.decode()));
      length += next.value.byteLength;
      if (length > maxBodyBytes) { await reader.cancel(); return null; }
      body += decoder.decode(next.value, { stream: true });
    }
  } catch { return null; }
  finally { reader.releaseLock(); }
}

async function previewDigest(preview: DependencyPreview): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(JSON.stringify(preview)));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function writeResponse(result: DependencyWrite): Response {
  if (result.status === "applied" || result.status === "replayed") return response(result, 200);
  return failure(result.status);
}

// Deliberately unregistered in the Worker router until writer compatibility and migration approval.
export async function handleDependencyRequest(request: Request, identity: Identity | null,
  memberships: MembershipRepository, environment: WorkerEnvironment,
  factory: RepositoryFactory = createDependencyRepository): Promise<Response> {
  const url = new URL(request.url);
  const match = url.pathname.match(path);
  if (!match) return failure("not_found");
  const origin = request.headers.get("Origin");
  if (origin && origin !== url.origin) return response({ error: "Origem não permitida." }, 403);
  if (!identity) return response({ error: "Sessão inválida ou expirada." }, 401);
  const workspaceId = id(match[1]);
  const productId = id(match[2]);
  const action = match[3];
  if (!workspaceId || !productId || url.search) return failure("invalid");
  if (request.method !== (action ? "POST" : "GET")) return response({ error: "Método não permitido." }, 405);

  try {
    const member = await authorizeWorkspace(identity, workspaceId, action ? "edit" : "read", memberships);
    if (!member) return failure("forbidden");
    const scope = { workspaceId, productId, actorId: identity.subject.toLowerCase() };
    const repository = factory(environment);
    if (!action) {
      const graph = await repository.readGraph(scope);
      return graph.status === "ok" ? response({ graph: graph.graph }, 200) : failure(graph.status);
    }

    const signingKey = environment.DEPENDENCY_PREVIEW_SIGNING_KEY;
    if (!signingKey || encoder.encode(signingKey).byteLength < 32) return failure("unavailable");
    const key = encoder.encode(signingKey);
    const input = await readBody(request);
    if (!input) return failure("invalid");
    if (action === "preview") {
      const edgeId = crypto.randomUUID();
      const edit = editFrom(input.edit, productId, edgeId);
      if (!edit || !version(input.scheduleVersion)) return failure("invalid");
      const fields = ["edit", "scheduleVersion"];
      if ("entity" in edit) {
        fields.push("entityVersion");
        if (typeof input.entityVersion !== "number" || !Number.isSafeInteger(input.entityVersion) || input.entityVersion < 1)
          return failure("invalid");
      }
      if (!shape(input, fields)) return failure("invalid");
      const read = await repository.readSnapshot(scope);
      if (read.status !== "ok") return failure(read.status);
      if (read.snapshot.scheduleVersion !== input.scheduleVersion) return failure("stale");
      if ("entity" in edit && read.snapshot.entities.find((item) =>
        item.kind === edit.entity.kind && item.id === edit.entity.id)?.version !== input.entityVersion) return failure("stale");
      const preview = previewScheduleDependencies(read.snapshot, edit);
      if (preview.dateChanges.length > dependencyDateChangeLimit) return failure("too_large");
      if (preview.status !== "ready" || !preview.confirmation) return response({ preview }, 200);
      const token = await new SignJWT({ workspaceId, productId, rulesVersion, intent: input.edit, edgeId,
        fingerprint: read.fingerprint, digest: await previewDigest(preview), scheduleVersion: input.scheduleVersion,
        calendarVersion: read.snapshot.calendar.version })
        .setProtectedHeader({ alg: "HS256" }).setAudience(tokenAudience).setSubject(scope.actorId)
        .setJti(crypto.randomUUID()).setIssuedAt().setExpirationTime(`${tokenLifetimeSeconds}s`).sign(key);
      return response({ preview, token }, 200);
    }

    if (!shape(input, ["token", "justification"]) || typeof input.token !== "string" ||
        typeof input.justification !== "string") return failure("invalid");
    const justification = input.justification.trim();
    if (justification.length < 10 || justification.length > 2000 || /\p{Cc}/u.test(justification))
      return failure("invalid");
    const claims = await jwtVerify(input.token, key, { algorithms: ["HS256"], audience: tokenAudience,
      subject: scope.actorId, requiredClaims: ["exp", "iat", "jti"] }).then(({ payload }) => payload, () => null);
    if (!claims || claims.workspaceId !== workspaceId || claims.productId !== productId || claims.rulesVersion !== rulesVersion ||
        !version(claims.scheduleVersion) || typeof claims.calendarVersion !== "number" ||
        !Number.isSafeInteger(claims.calendarVersion) || claims.calendarVersion < 0 ||
        typeof claims.fingerprint !== "string" || !fingerprintPattern.test(claims.fingerprint) ||
        typeof claims.digest !== "string" || !fingerprintPattern.test(claims.digest)) return failure("stale");
    const operationId = id(claims.jti);
    const edgeId = id(claims.edgeId);
    const edit = edgeId && editFrom(claims.intent, productId, edgeId);
    if (!operationId || !edit) return failure("stale");
    const operation = { operationId, scheduleVersion: claims.scheduleVersion, justification };
    const receipt = await repository.readReceipt(scope, operation);
    if (receipt.status !== "missing") return writeResponse(receipt);
    const read = await repository.readSnapshot(scope);
    if (read.status !== "ok") return failure(read.status);
    if (read.fingerprint !== claims.fingerprint || read.snapshot.scheduleVersion !== claims.scheduleVersion ||
        read.snapshot.calendar.version !== claims.calendarVersion) {
      // A concurrent confirmation may have committed after the first receipt read.
      const latest = await repository.readReceipt(scope, operation);
      return latest.status === "missing" ? failure("stale") : writeResponse(latest);
    }
    const preview = previewScheduleDependencies(read.snapshot, edit);
    if (preview.status !== "ready" || !preview.confirmation || await previewDigest(preview) !== claims.digest)
      return failure("stale");
    if (preview.dateChanges.length > dependencyDateChangeLimit) return failure("too_large");
    const versions = new Map(preview.confirmation.expectedEntityVersions.map(({ entity, version }) =>
      [`${entity.kind}:${entity.id}`, version]));
    const dateChanges = preview.dateChanges.map((change) => {
      const expectedVersion = versions.get(`${change.entity.kind}:${change.entity.id}`);
      if (expectedVersion === undefined) throw new Error("Missing version in reviewed dependency preview.");
      return { ...change, expectedVersion };
    });
    return writeResponse(await repository.confirm(scope, { ...operation, calendarVersion: claims.calendarVersion,
      fingerprint: claims.fingerprint, dependencyChange: preview.dependencyChange, dateChanges }));
  } catch { return failure("unavailable"); }
}
